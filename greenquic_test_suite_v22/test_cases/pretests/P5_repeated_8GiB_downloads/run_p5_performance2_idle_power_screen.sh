#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
CLIENT_HOST="${CLIENT_HOST:-tinyman}"
RUNS="${P5_P2_RUNS:-1}"
DOWNLOADS="${P5_P2_DOWNLOADS:-3}"
STAMP="${STAMP:-$(date +%Y%m%d_%H%M%S)}"
RESULT_ROOT="${RESULT_ROOT:-/tmp/P5_P2_IDLE_POWER_SCREEN_${STAMP}}"
MATRIX_ROOT="${MATRIX_ROOT:-$HERE/matrix_results/P5_P2_IDLE_POWER_SCREEN_${STAMP}}"
CHART_STYLE="${P5_P2_CHART_STYLE:-both}"
SEED="${P5_P2_SEED:-20260806}"
CLIENT_BIN=/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop
BUILD_HELPER="$HERE/build_p5_performance2.sh"
PROFILES=(baseline sharded_512 sharded_1024 sharded_2048 rx_prefetch sharded_rxprefetch)

[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: P5_P2_RUNS must be positive" >&2; exit 2; }
[[ "$DOWNLOADS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: P5_P2_DOWNLOADS must be positive" >&2; exit 2; }
mkdir -p "$RESULT_ROOT/logs" "$MATRIX_ROOT"
SUMMARY="$RESULT_ROOT/idle_power_summary.tsv"
printf 'profile\tworkload\tmode\tn\tmean_active_gbps\tsd_active_gbps\tmin_active_gbps\tmax_active_gbps\trc\n' > "$SUMMARY"
STATUS="$RESULT_ROOT/status.env"
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

profile_env() {
    case "$1" in
        baseline)           echo 'P5_P2_TX_HANDOFF=shared P5_P2_TX_PRODUCER_RING_SIZE=1024 P5_P2_RX_PREFETCH=0 P5_P2_UDP_SEG=0 P5_P2_UDP_SEG_MAX=4 P5_P2_DIAG_INTERVAL_US=0' ;;
        sharded_512)        echo 'P5_P2_TX_HANDOFF=sharded P5_P2_TX_PRODUCER_RING_SIZE=512 P5_P2_RX_PREFETCH=0 P5_P2_UDP_SEG=0 P5_P2_UDP_SEG_MAX=4 P5_P2_DIAG_INTERVAL_US=0' ;;
        sharded_1024)       echo 'P5_P2_TX_HANDOFF=sharded P5_P2_TX_PRODUCER_RING_SIZE=1024 P5_P2_RX_PREFETCH=0 P5_P2_UDP_SEG=0 P5_P2_UDP_SEG_MAX=4 P5_P2_DIAG_INTERVAL_US=0' ;;
        sharded_2048)       echo 'P5_P2_TX_HANDOFF=sharded P5_P2_TX_PRODUCER_RING_SIZE=2048 P5_P2_RX_PREFETCH=0 P5_P2_UDP_SEG=0 P5_P2_UDP_SEG_MAX=4 P5_P2_DIAG_INTERVAL_US=0' ;;
        rx_prefetch)        echo 'P5_P2_TX_HANDOFF=shared P5_P2_TX_PRODUCER_RING_SIZE=1024 P5_P2_RX_PREFETCH=1 P5_P2_UDP_SEG=0 P5_P2_UDP_SEG_MAX=4 P5_P2_DIAG_INTERVAL_US=0' ;;
        sharded_rxprefetch) echo 'P5_P2_TX_HANDOFF=sharded P5_P2_TX_PRODUCER_RING_SIZE=1024 P5_P2_RX_PREFETCH=1 P5_P2_UDP_SEG=0 P5_P2_UDP_SEG_MAX=4 P5_P2_DIAG_INTERVAL_US=0' ;;
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

echo "P5 PERFORMANCE2 IDLE+POWER SCREEN"
echo "profiles=${PROFILES[*]}"
echo "runs=$RUNS downloads=$DOWNLOADS chart_style=$CHART_STYLE seed=$SEED"

for profile in "${PROFILES[@]}"; do
    echo
    echo "======================================================================"
    echo "PROFILE=$profile"
    echo "======================================================================"
    P2_SPEC="$(profile_env "$profile")"
    P2_ENV="P5_BUILD_REUSE=1 P5_P2_DIAG_DURATION_MS=3000 $P2_SPEC"
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

printf 'FAILURES=%s\n' "$FAILURES" >> "$STATUS"
echo
echo "======================================================================"
echo "IDLE+POWER SCREEN SUMMARY"
echo "======================================================================"
column -t -s $'\t' "$SUMMARY" 2>/dev/null || cat "$SUMMARY"
echo "RESULT_ROOT=$RESULT_ROOT"
echo "MATRIX_ROOT=$MATRIX_ROOT"
echo "FAILURES=$FAILURES"
exit 0
