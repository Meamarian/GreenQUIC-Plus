#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
CLIENT_HOST="${CLIENT_HOST:-tinyman}"
RUNS="${P5_P2_RUNS:-1}"
DOWNLOADS="${P5_P2_DOWNLOADS:-3}"
STAMP="${STAMP:-$(date +%Y%m%d_%H%M%S)}"
RESULT_ROOT="${RESULT_ROOT:-/tmp/P5_P2_PLUS_IDLE_COMBO_${STAMP}}"
MATRIX_ROOT="${MATRIX_ROOT:-$HERE/matrix_results/P5_P2_PLUS_IDLE_COMBO_${STAMP}}"
SEED="${P5_P2_SEED:-20260806}"
CLIENT_BIN=/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop
BUILD_HELPER="$HERE/build_p5_performance2.sh"

# Baseline is deliberately repeated in the same screen to control for run/day drift.
# Five candidate combinations then exercise only PLUS + idle_monitor_normal.
PROFILES=(
    baseline
    winner_recheck
    tx16_counter_rx4
    tx16_counter_rx2
    tx8_counter_rx2
    max_combo
)

[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: P5_P2_RUNS must be positive" >&2; exit 2; }
[[ "$DOWNLOADS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: P5_P2_DOWNLOADS must be positive" >&2; exit 2; }
mkdir -p "$RESULT_ROOT/logs" "$MATRIX_ROOT"
SUMMARY="$RESULT_ROOT/plus_idle_combo_summary.tsv"
RANKING="$RESULT_ROOT/plus_idle_combo_vs_baseline.tsv"
STATUS="$RESULT_ROOT/status.env"
printf 'profile\tn\tmean_active_gbps\tsd_active_gbps\tmin_active_gbps\tmax_active_gbps\trc\n' > "$SUMMARY"
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

PLUS_CORE="$HERE/.run_matrix_plus_core_${STAMP}_$$.sh"
PLUS_WRAPPER="$HERE/.run_matrix_plus_wrapper_${STAMP}_$$.sh"

prepare_plus_wrapper() {
    cp "$HERE/run_matrix_from_idex_core.sh" "$PLUS_CORE"
    cp "$HERE/run_matrix_from_idex.sh" "$PLUS_WRAPPER"
    python3 - "$PLUS_CORE" "$PLUS_WRAPPER" <<'PY'
from pathlib import Path
import sys
core = Path(sys.argv[1])
wrapper = Path(sys.argv[2])
text = core.read_text(encoding='utf-8')
old = 'modes = ("off", "basic", "plus")'
if text.count(old) != 1:
    raise SystemExit(f'ERROR: PLUS-only schedule anchor count={text.count(old)}')
text = text.replace(old, 'modes = ("plus",)', 1)
old_total = 'TOTAL_TESTS=$((RUNS * 3))'
if text.count(old_total) != 1:
    raise SystemExit(f'ERROR: TOTAL_TESTS anchor count={text.count(old_total)}')
text = text.replace(old_total, 'TOTAL_TESTS=$RUNS', 1)
text = text.replace('position=$position/3', 'position=$position/1')
text = text.replace('POSITION $position/3', 'POSITION $position/1')
core.write_text(text, encoding='utf-8')

w = wrapper.read_text(encoding='utf-8')
old_core = 'CORE="$HERE/run_matrix_from_idex_core.sh"'
new_core = f'CORE="$HERE/{core.name}"'
if w.count(old_core) != 1:
    raise SystemExit(f'ERROR: wrapper CORE anchor count={w.count(old_core)}')
w = w.replace(old_core, new_core, 1)
wrapper.write_text(w, encoding='utf-8')
PY
    chmod 0700 "$PLUS_CORE" "$PLUS_WRAPPER"
    bash -n "$PLUS_CORE" "$PLUS_WRAPPER"
}

restore_native() {
    set +e
    rm -f "$PLUS_CORE" "$PLUS_WRAPPER"
    (cd "$HERE" && P5_STATIC_PROFILE=native P5_BUILD_REUSE=1 bash ./build_p5_client.sh >"$RESULT_ROOT/restore_idex.log" 2>&1) & p1=$!
    ssh -n root@"$CLIENT_HOST" "cd '$HERE' && P5_STATIC_PROFILE=native P5_BUILD_REUSE=1 bash ./build_p5_client.sh" >"$RESULT_ROOT/restore_tinyman.log" 2>&1 & p2=$!
    wait "$p1"; r1=$?
    wait "$p2"; r2=$?
    printf 'RESTORE_IDEX=%s\nRESTORE_TINYMAN=%s\n' "$r1" "$r2" >> "$STATUS"
    set -e
}
trap restore_native EXIT INT TERM

profile_env() {
    local common='P5_P2_DIAG_INTERVAL_US=0 P5_P2_DIAG_DURATION_MS=3000 P5_P2_TX_HANDOFF=shared P5_P2_TX_PRODUCER_RING_SIZE=1024 P5_P2_RX_PREFETCH=0 P5_P2_UDP_SEG=0 P5_P2_UDP_SEG_MAX=4 P5_P2_RX_PIPE_PREFETCH=0 P5_P2_SHARD_ACTIVE_MASK=0 P5_P2_TX_ALLOC_BATCH=1 P5_P2_TX_ENQUEUE_COUNTER=1 P5_P2_TX_META_ZERO=1'
    case "$1" in
        baseline)
            echo "$common"
            ;;
        # Recheck the current n=1 winner: alloc16 + no counter + reduced metadata zero + RX pipeline4.
        winner_recheck)
            echo "$common P5_P2_TX_ALLOC_BATCH=16 P5_P2_TX_ENQUEUE_COUNTER=0 P5_P2_TX_META_ZERO=0 P5_P2_RX_PIPE_PREFETCH=4"
            ;;
        # Remove reduced-zeroing from the winner to test whether it helps or hurts the RX4 synergy.
        tx16_counter_rx4)
            echo "$common P5_P2_TX_ALLOC_BATCH=16 P5_P2_TX_ENQUEUE_COUNTER=0 P5_P2_TX_META_ZERO=1 P5_P2_RX_PIPE_PREFETCH=4"
            ;;
        # Strong TX pair plus the individually strong RX pipeline2 path.
        tx16_counter_rx2)
            echo "$common P5_P2_TX_ALLOC_BATCH=16 P5_P2_TX_ENQUEUE_COUNTER=0 P5_P2_TX_META_ZERO=1 P5_P2_RX_PIPE_PREFETCH=2"
            ;;
        # Batch8 was the strongest standalone allocator; combine it with no-counter + RX2.
        tx8_counter_rx2)
            echo "$common P5_P2_TX_ALLOC_BATCH=8 P5_P2_TX_ENQUEUE_COUNTER=0 P5_P2_TX_META_ZERO=1 P5_P2_RX_PIPE_PREFETCH=2"
            ;;
        # Aggressive combination of the strongest-looking independent families, while keeping safe full TX zeroing.
        max_combo)
            echo "$common P5_P2_TX_HANDOFF=sharded P5_P2_SHARD_ACTIVE_MASK=1 P5_P2_TX_ALLOC_BATCH=16 P5_P2_TX_ENQUEUE_COUNTER=0 P5_P2_TX_META_ZERO=1 P5_P2_RX_PIPE_PREFETCH=4"
            ;;
        *) return 2 ;;
    esac
}

summarize_case() {
    local profile="$1" out="$2" rc="$3"
    python3 - "$profile" "$out" "$rc" "$SUMMARY" <<'PY'
import csv, re, statistics, sys
from pathlib import Path
profile, out, rc, summary = sys.argv[1:]
vals = []
client = Path(out) / 'tables' / 'client_all_runs.csv'
if client.is_file():
    with client.open(newline='', encoding='utf-8', errors='replace') as f:
        for row in csv.DictReader(f):
            if row.get('mode') != 'plus' and row.get('run__greenquic_mode') != 'plus':
                continue
            raw = row.get('greenquic_p5_workload_summary__aggregate_goodput_excluding_gaps', '')
            m = re.search(r'([0-9]+(?:\.[0-9]+)?)', raw)
            if m:
                vals.append(float(m.group(1)))
mean = statistics.mean(vals) if vals else None
sd = statistics.stdev(vals) if len(vals) > 1 else (0.0 if len(vals) == 1 else None)
fmt = lambda x: 'NA' if x is None else f'{x:.6f}'
with open(summary, 'a', encoding='utf-8') as f:
    f.write('\t'.join([
        profile, str(len(vals)), fmt(mean), fmt(sd),
        fmt(min(vals) if vals else None), fmt(max(vals) if vals else None), str(rc)
    ]) + '\n')
PY
}

write_ranking() {
    python3 - "$SUMMARY" "$RANKING" <<'PY'
import csv, sys
from pathlib import Path
src, dst = map(Path, sys.argv[1:])
rows = list(csv.DictReader(src.open(encoding='utf-8'), delimiter='\t'))
base_row = next((r for r in rows if r['profile'] == 'baseline'), None)
base = float(base_row['mean_active_gbps']) if base_row and base_row['mean_active_gbps'] != 'NA' else None
with dst.open('w', encoding='utf-8', newline='') as f:
    w = csv.writer(f, delimiter='\t')
    w.writerow(['profile','mean_active_gbps','baseline_gbps','delta_gbps','delta_pct','rc'])
    for r in rows:
        try:
            value = float(r['mean_active_gbps'])
            if base is None:
                raise ValueError
        except ValueError:
            w.writerow([r['profile'],r['mean_active_gbps'],'NA','NA','NA',r['rc']])
            continue
        delta = value - base
        pct = delta / base * 100.0 if base else 0.0
        w.writerow([r['profile'],f'{value:.6f}',f'{base:.6f}',f'{delta:+.6f}',f'{pct:+.3f}',r['rc']])
PY
}

prepare_plus_wrapper

echo "P5 PERFORMANCE2 PLUS-ONLY IDLE-MONITOR COMBINATION SCREEN"
echo "profiles=${PROFILES[*]}"
echo "runs=$RUNS downloads=$DOWNLOADS seed=$SEED"
echo "mode=plus workload=idle_monitor_normal"

for profile in "${PROFILES[@]}"; do
    echo
    echo "======================================================================"
    echo "PROFILE=$profile"
    echo "======================================================================"
    P2_SPEC="$(profile_env "$profile")"
    P2_ENV="P5_BUILD_REUSE=1 $P2_SPEC"
    key="$(printf '%s' "$profile" | tr '[:lower:]' '[:upper:]')"
    printf '%s_ENV=%q\n' "$key" "$P2_ENV" >> "$STATUS"

    clean_local
    clean_client
    set +e
    (cd "$HERE" && env $P2_ENV bash "$BUILD_HELPER" >"$RESULT_ROOT/logs/${profile}__build_idex.log" 2>&1) & p1=$!
    ssh -n root@"$CLIENT_HOST" "cd '$HERE' && env $P2_ENV bash '$BUILD_HELPER'" >"$RESULT_ROOT/logs/${profile}__build_tinyman.log" 2>&1 & p2=$!
    wait "$p1"; b1=$?
    wait "$p2"; b2=$?
    set -e
    printf '%s_BUILD_IDEX=%s\n%s_BUILD_TINYMAN=%s\n' "$key" "$b1" "$key" "$b2" >> "$STATUS"
    if (( b1 != 0 || b2 != 0 )); then
        echo "BUILD FAILED profile=$profile idex=$b1 tinyman=$b2"
        FAILURES=$((FAILURES + 1))
        summarize_case "$profile" "$MATRIX_ROOT/$profile/idle_monitor_normal" 90
        continue
    fi

    out="$MATRIX_ROOT/$profile/idle_monitor_normal"
    log="$RESULT_ROOT/logs/${profile}__plus_idle_monitor.log"
    mkdir -p "$out"
    clean_local
    clean_client
    set +e
    bash "$PLUS_WRAPPER" \
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
        --env GQ_IDLE_MODE_OVERRIDE=monitor \
        --env GQ_IDLE_FALLBACK_OVERRIDE=short \
        >"$log" 2>&1
    rc=$?
    set -e
    if ! grep -q "SUCCESS: all $RUNS/$RUNS P5 workloads completed" "$log" 2>/dev/null; then
        rc=$(( rc == 0 ? 91 : rc ))
    fi
    summarize_case "$profile" "$out" "$rc"
    printf '%s__PLUS_IDLE_MONITOR_RC=%s\n' "$key" "$rc" >> "$STATUS"
    if (( rc != 0 )); then FAILURES=$((FAILURES + 1)); fi
    sleep 10
done

write_ranking
printf 'FAILURES=%s\n' "$FAILURES" >> "$STATUS"

echo
echo "======================================================================"
echo "PLUS-ONLY IDLE-MONITOR SUMMARY"
echo "======================================================================"
column -t -s $'\t' "$SUMMARY" 2>/dev/null || cat "$SUMMARY"
echo
echo "=== DELTA VS SAME-SCREEN BASELINE ==="
column -t -s $'\t' "$RANKING" 2>/dev/null || cat "$RANKING"
echo "RESULT_ROOT=$RESULT_ROOT"
echo "MATRIX_ROOT=$MATRIX_ROOT"
echo "FAILURES=$FAILURES"
(( FAILURES == 0 ))
