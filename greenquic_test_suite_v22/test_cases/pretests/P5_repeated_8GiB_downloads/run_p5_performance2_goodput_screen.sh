#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
CLIENT_HOST="${CLIENT_HOST:-tinyman}"
RUNS="${P5_P2_RUNS:-1}"
DOWNLOADS="${P5_P2_DOWNLOADS:-3}"
STAMP="${STAMP:-$(date +%Y%m%d_%H%M%S)}"
RESULT_ROOT="${RESULT_ROOT:-/tmp/P5_P2_GOODPUT_SCREEN_${STAMP}}"
MATRIX_ROOT="${MATRIX_ROOT:-$HERE/matrix_results/P5_P2_GOODPUT_SCREEN_${STAMP}}"
CHART_STYLE="${P5_P2_CHART_STYLE:-both}"
SEED="${P5_P2_SEED:-20260806}"
CLIENT_BIN=/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop
BUILD_HELPER="$HERE/build_p5_performance2.sh"
PROFILES=(
    baseline
    txalloc_8
    txalloc_16
    txalloc_32
    no_tx_enqueue_counter
    no_tx_meta_zero
    rxpipe_2
    rxpipe_4
    sharded_1024
    sharded_1024_mask
    txalloc16_no_counter
    txalloc16_no_zero
    lean_tx
    lean_tx_rxpipe4
    lean_tx_sharded1024_mask
)

[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: P5_P2_RUNS must be positive" >&2; exit 2; }
[[ "$DOWNLOADS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: P5_P2_DOWNLOADS must be positive" >&2; exit 2; }
mkdir -p "$RESULT_ROOT/logs" "$MATRIX_ROOT"
SUMMARY="$RESULT_ROOT/goodput_screen_summary.tsv"
RANKING="$RESULT_ROOT/goodput_screen_vs_baseline.tsv"
STATUS="$RESULT_ROOT/status.env"
printf 'profile\tworkload\tmode\tn\tmean_active_gbps\tsd_active_gbps\tmin_active_gbps\tmax_active_gbps\trc\n' > "$SUMMARY"
: > "$STATUS"
FAILURES=0

clean_local() {
    set +e
    for p in /proc/[0-9]*; do
        pid="${p##*/}"
        exe="$(readlink -f "$p/exe" 2>/dev/null || true)"
        case "$exe" in */quicinterop|*/quicinteropserver) kill -TERM "$pid" 2>/dev/null || true;; esac
    done
    sleep 1
    for p in /proc/[0-9]*; do
        pid="${p##*/}"
        exe="$(readlink -f "$p/exe" 2>/dev/null || true)"
        case "$exe" in */quicinterop|*/quicinteropserver) kill -KILL "$pid" 2>/dev/null || true;; esac
    done
    if ! fuser /var/run/dpdk/rte/config >/dev/null 2>&1; then rm -rf /var/run/dpdk/rte; fi
    set -e
}

clean_client() {
    ssh -n root@"$CLIENT_HOST" 'bash -s' <<'CLEAN'
set +e
for p in /proc/[0-9]*; do
    pid="${p##*/}"
    exe="$(readlink -f "$p/exe" 2>/dev/null || true)"
    case "$exe" in */quicinterop|*/quicinteropserver) kill -TERM "$pid" 2>/dev/null || true;; esac
done
sleep 1
for p in /proc/[0-9]*; do
    pid="${p##*/}"
    exe="$(readlink -f "$p/exe" 2>/dev/null || true)"
    case "$exe" in */quicinterop|*/quicinteropserver) kill -KILL "$pid" 2>/dev/null || true;; esac
done
if ! fuser /var/run/dpdk/rte/config >/dev/null 2>&1; then rm -rf /var/run/dpdk/rte; fi
CLEAN
}

restore_native() {
    set +e
    (cd "$HERE" && P5_STATIC_PROFILE=native P5_BUILD_REUSE=1 bash ./build_p5_client.sh >"$RESULT_ROOT/restore_idex.log" 2>&1) & p1=$!
    ssh -n root@"$CLIENT_HOST" "cd '$HERE' && P5_STATIC_PROFILE=native P5_BUILD_REUSE=1 bash ./build_p5_client.sh" >"$RESULT_ROOT/restore_tinyman.log" 2>&1 & p2=$!
    wait "$p1"; r1=$?
    wait "$p2"; r2=$?
    printf 'RESTORE_IDEX=%s\nRESTORE_TINYMAN=%s\n' "$r1" "$r2" >> "$STATUS"
    set -e
}
trap restore_native EXIT INT TERM

# V2 screens each new optimization independently. The old all-at-once sharding/RX-prefetch/USO
# combinations remain excluded; sharded_1024 is repeated only as the control for the new active-mask variant.
profile_env() {
    local common='P5_P2_TX_HANDOFF=shared P5_P2_TX_PRODUCER_RING_SIZE=1024 P5_P2_RX_PREFETCH=0 P5_P2_UDP_SEG=0 P5_P2_UDP_SEG_MAX=4 P5_P2_DIAG_INTERVAL_US=0 P5_P2_RX_PIPE_PREFETCH=0 P5_P2_SHARD_ACTIVE_MASK=0'
    case "$1" in
        baseline)                    echo "$common P5_P2_TX_ALLOC_BATCH=1  P5_P2_TX_ENQUEUE_COUNTER=1 P5_P2_TX_META_ZERO=1" ;;
        txalloc_8)                   echo "$common P5_P2_TX_ALLOC_BATCH=8  P5_P2_TX_ENQUEUE_COUNTER=1 P5_P2_TX_META_ZERO=1" ;;
        txalloc_16)                  echo "$common P5_P2_TX_ALLOC_BATCH=16 P5_P2_TX_ENQUEUE_COUNTER=1 P5_P2_TX_META_ZERO=1" ;;
        txalloc_32)                  echo "$common P5_P2_TX_ALLOC_BATCH=32 P5_P2_TX_ENQUEUE_COUNTER=1 P5_P2_TX_META_ZERO=1" ;;
        no_tx_enqueue_counter)       echo "$common P5_P2_TX_ALLOC_BATCH=1  P5_P2_TX_ENQUEUE_COUNTER=0 P5_P2_TX_META_ZERO=1" ;;
        no_tx_meta_zero)             echo "$common P5_P2_TX_ALLOC_BATCH=1  P5_P2_TX_ENQUEUE_COUNTER=1 P5_P2_TX_META_ZERO=0" ;;
        rxpipe_2)                    echo "$common P5_P2_TX_ALLOC_BATCH=1  P5_P2_TX_ENQUEUE_COUNTER=1 P5_P2_TX_META_ZERO=1 P5_P2_RX_PIPE_PREFETCH=2" ;;
        rxpipe_4)                    echo "$common P5_P2_TX_ALLOC_BATCH=1  P5_P2_TX_ENQUEUE_COUNTER=1 P5_P2_TX_META_ZERO=1 P5_P2_RX_PIPE_PREFETCH=4" ;;
        sharded_1024)                echo "$common P5_P2_TX_HANDOFF=sharded P5_P2_TX_ALLOC_BATCH=1 P5_P2_TX_ENQUEUE_COUNTER=1 P5_P2_TX_META_ZERO=1" ;;
        sharded_1024_mask)           echo "$common P5_P2_TX_HANDOFF=sharded P5_P2_SHARD_ACTIVE_MASK=1 P5_P2_TX_ALLOC_BATCH=1 P5_P2_TX_ENQUEUE_COUNTER=1 P5_P2_TX_META_ZERO=1" ;;
        txalloc16_no_counter)        echo "$common P5_P2_TX_ALLOC_BATCH=16 P5_P2_TX_ENQUEUE_COUNTER=0 P5_P2_TX_META_ZERO=1" ;;
        txalloc16_no_zero)           echo "$common P5_P2_TX_ALLOC_BATCH=16 P5_P2_TX_ENQUEUE_COUNTER=1 P5_P2_TX_META_ZERO=0" ;;
        lean_tx)                     echo "$common P5_P2_TX_ALLOC_BATCH=16 P5_P2_TX_ENQUEUE_COUNTER=0 P5_P2_TX_META_ZERO=0" ;;
        lean_tx_rxpipe4)             echo "$common P5_P2_TX_ALLOC_BATCH=16 P5_P2_TX_ENQUEUE_COUNTER=0 P5_P2_TX_META_ZERO=0 P5_P2_RX_PIPE_PREFETCH=4" ;;
        lean_tx_sharded1024_mask)    echo "$common P5_P2_TX_HANDOFF=sharded P5_P2_SHARD_ACTIVE_MASK=1 P5_P2_TX_ALLOC_BATCH=16 P5_P2_TX_ENQUEUE_COUNTER=0 P5_P2_TX_META_ZERO=0" ;;
        *) return 2 ;;
    esac
}

summarize_case() {
    local profile="$1" workload="$2" out="$3" rc="$4"
    python3 - "$profile" "$workload" "$out" "$rc" "$SUMMARY" <<'PY'
import csv, re, statistics, sys
from pathlib import Path
profile, workload, out, rc, summary = sys.argv[1:]
vals = {'off': [], 'basic': [], 'plus': []}
client = Path(out) / 'tables' / 'client_all_runs.csv'
if client.is_file():
    with client.open(newline='', encoding='utf-8', errors='replace') as f:
        for row in csv.DictReader(f):
            mode = row.get('run__greenquic_mode', '')
            raw = row.get('greenquic_p5_workload_summary__aggregate_goodput_excluding_gaps', '')
            m = re.search(r'([0-9]+(?:\.[0-9]+)?)', raw)
            if mode in vals and m:
                vals[mode].append(float(m.group(1)))
with open(summary, 'a', encoding='utf-8') as f:
    for mode in ('off','basic','plus'):
        v = vals[mode]
        n = len(v)
        mean = statistics.mean(v) if v else None
        sd = statistics.stdev(v) if len(v) > 1 else (0.0 if len(v) == 1 else None)
        fmt = lambda x: 'NA' if x is None else f'{x:.6f}'
        f.write('\t'.join([
            profile, workload, mode, str(n), fmt(mean), fmt(sd),
            fmt(min(v) if v else None), fmt(max(v) if v else None), str(rc)
        ]) + '\n')
PY
}

run_workload() {
    local profile="$1" workload="$2"
    shift 2
    local out="$MATRIX_ROOT/$profile/$workload"
    local log="$RESULT_ROOT/logs/${profile}__${workload}.log"
    mkdir -p "$(dirname "$out")"
    clean_local
    clean_client
    set +e
    bash "$HERE/run_matrix_with_sheet.sh" \
        --chart-style "$CHART_STYLE" \
        --client-host "$CLIENT_HOST" \
        --client-dir "$HERE" \
        --client-bin "$CLIENT_BIN" \
        --downloads "$DOWNLOADS" \
        --gap-seconds 5 \
        --server-cooldown-seconds 5 \
        --between-tests-seconds 0 \
        --cstate-cpu 19 \
        --runs "$RUNS" \
        --mode-order balanced \
        --seed "$SEED" \
        --output-dir "$out" \
        --env ENABLE_RECORD=1 \
        --env GQ_LOG_LEVEL=0 \
        "$@" >"$log" 2>&1
    rc=$?
    set -e
    if ! grep -R -q "SUCCESS: all $((RUNS * 3))/$((RUNS * 3)) P5 workloads completed" "$out" "$log" 2>/dev/null; then
        rc=$(( rc == 0 ? 91 : rc ))
    fi
    summarize_case "$profile" "$workload" "$out" "$rc"
    printf '%s__%s_RC=%s\n' "$(printf '%s' "$profile" | tr '[:lower:]' '[:upper:]')" "$(printf '%s' "$workload" | tr '[:lower:]' '[:upper:]')" "$rc" >> "$STATUS"
    if (( rc != 0 )); then FAILURES=$((FAILURES + 1)); fi
}

write_ranking() {
    python3 - "$SUMMARY" "$RANKING" <<'PY'
import csv, sys
from pathlib import Path
src, dst = map(Path, sys.argv[1:])
rows = list(csv.DictReader(src.open(encoding='utf-8'), delimiter='\t'))
base = {}
for r in rows:
    if r['profile'] == 'baseline' and r['mean_active_gbps'] != 'NA':
        base[(r['workload'], r['mode'])] = float(r['mean_active_gbps'])
with dst.open('w', encoding='utf-8', newline='') as f:
    w = csv.writer(f, delimiter='\t')
    w.writerow(['profile','workload','mode','mean_active_gbps','baseline_gbps','delta_gbps','delta_pct','rc'])
    for r in rows:
        try:
            value = float(r['mean_active_gbps'])
            b = base[(r['workload'], r['mode'])]
        except (ValueError, KeyError):
            w.writerow([r['profile'],r['workload'],r['mode'],r['mean_active_gbps'],'NA','NA','NA',r['rc']])
            continue
        delta = value - b
        pct = (delta / b * 100.0) if b else 0.0
        w.writerow([r['profile'],r['workload'],r['mode'],f'{value:.6f}',f'{b:.6f}',f'{delta:+.6f}',f'{pct:+.3f}',r['rc']])
PY
}

echo "P5 PERFORMANCE2 V2 GOODPUT SCREEN"
echo "profiles=${PROFILES[*]}"
echo "runs=$RUNS downloads=$DOWNLOADS chart_style=$CHART_STYLE seed=$SEED"
echo "workloads=idle_monitor_normal,power_friendly"

for profile in "${PROFILES[@]}"; do
    echo
    echo "======================================================================"
    echo "PROFILE=$profile"
    echo "======================================================================"
    P2_SPEC="$(profile_env "$profile")"
    P2_ENV="P5_BUILD_REUSE=1 P5_P2_DIAG_DURATION_MS=3000 $P2_SPEC"
    printf '%s_ENV=%q\n' "$(printf '%s' "$profile" | tr '[:lower:]' '[:upper:]')" "$P2_ENV" >> "$STATUS"
    clean_local
    clean_client
    set +e
    (cd "$HERE" && env $P2_ENV bash "$BUILD_HELPER" >"$RESULT_ROOT/logs/${profile}__build_idex.log" 2>&1) & p1=$!
    ssh -n root@"$CLIENT_HOST" "cd '$HERE' && env $P2_ENV bash '$BUILD_HELPER'" >"$RESULT_ROOT/logs/${profile}__build_tinyman.log" 2>&1 & p2=$!
    wait "$p1"; B1=$?
    wait "$p2"; B2=$?
    set -e
    printf '%s_BUILD_IDEX=%s\n%s_BUILD_TINYMAN=%s\n' "$(printf '%s' "$profile" | tr '[:lower:]' '[:upper:]')" "$B1" "$(printf '%s' "$profile" | tr '[:lower:]' '[:upper:]')" "$B2" >> "$STATUS"
    if (( B1 != 0 || B2 != 0 )); then
        echo "BUILD FAILED profile=$profile idex=$B1 tinyman=$B2"
        FAILURES=$((FAILURES + 2))
        continue
    fi

    run_workload "$profile" idle_monitor_normal \
        --env GQ_IDLE_MODE_OVERRIDE=monitor \
        --env GQ_IDLE_FALLBACK_OVERRIDE=short
    sleep 10

    run_workload "$profile" power_friendly \
        --env ENABLE_FREQ=1 \
        --env ENABLE_SLEEP=1 \
        --env GQ_IDLE_MODE_OVERRIDE=epoll \
        --env GQ_IDLE_FALLBACK_OVERRIDE=short
    sleep 10
done

write_ranking
printf 'FAILURES=%s\n' "$FAILURES" >> "$STATUS"
echo
echo "======================================================================"
echo "PERFORMANCE2 V2 GOODPUT SCREEN SUMMARY"
echo "======================================================================"
column -t -s $'\t' "$SUMMARY" 2>/dev/null || cat "$SUMMARY"
echo
echo "=== DELTA VS BASELINE ==="
column -t -s $'\t' "$RANKING" 2>/dev/null || cat "$RANKING"
echo "RESULT_ROOT=$RESULT_ROOT"
echo "MATRIX_ROOT=$MATRIX_ROOT"
echo "FAILURES=$FAILURES"
exit 0
