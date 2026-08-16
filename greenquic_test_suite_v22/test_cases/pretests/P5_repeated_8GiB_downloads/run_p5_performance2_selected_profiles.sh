#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
CLIENT_HOST="${CLIENT_HOST:-tinyman}"
P2_PROFILE="${P5_P2_PROFILE:-${1:-}}"
[[ -n "$P2_PROFILE" ]] || { echo "ERROR: choose a P2 profile explicitly after screening" >&2; exit 2; }
RUNS="${P5_P2_RUNS:-6}"
DOWNLOADS="${P5_P2_DOWNLOADS:-5}"
STAMP="${STAMP:-$(date +%Y%m%d_%H%M%S)}"
RESULT_ROOT="${RESULT_ROOT:-/tmp/P5_PERFORMANCE2_SELECTED_${STAMP}_${P2_PROFILE}}"
MATRIX_ROOT="${MATRIX_ROOT:-$HERE/matrix_results/P5_PERFORMANCE2_SELECTED_${STAMP}_${P2_PROFILE}}"
CHART_STYLE="${P5_P2_CHART_STYLE:-both}"
SEED="${P5_P2_SEED:-20260806}"
BUILD_HELPER="$HERE/build_p5_performance2.sh"
CLIENT_BIN=/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop

[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: runs must be positive" >&2; exit 2; }
[[ "$DOWNLOADS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: downloads must be positive" >&2; exit 2; }
mkdir -p "$RESULT_ROOT/logs" "$MATRIX_ROOT"

case "$P2_PROFILE" in
    baseline)               HANDOFF=shared;  PRING=1024; RXPREF=0; UDPSEG=0; UDPMAX=4; DIAG=0 ;;
    diag_100ms)             HANDOFF=shared;  PRING=1024; RXPREF=0; UDPSEG=0; UDPMAX=4; DIAG=100000 ;;
    sharded_512)            HANDOFF=sharded; PRING=512;  RXPREF=0; UDPSEG=0; UDPMAX=4; DIAG=0 ;;
    sharded_1024)           HANDOFF=sharded; PRING=1024; RXPREF=0; UDPSEG=0; UDPMAX=4; DIAG=0 ;;
    sharded_2048)           HANDOFF=sharded; PRING=2048; RXPREF=0; UDPSEG=0; UDPMAX=4; DIAG=0 ;;
    rx_prefetch)            HANDOFF=shared;  PRING=1024; RXPREF=1; UDPSEG=0; UDPMAX=4; DIAG=0 ;;
    udp_seg2)               HANDOFF=shared;  PRING=1024; RXPREF=0; UDPSEG=1; UDPMAX=2; DIAG=0 ;;
    udp_seg4)               HANDOFF=shared;  PRING=1024; RXPREF=0; UDPSEG=1; UDPMAX=4; DIAG=0 ;;
    udp_seg8)               HANDOFF=shared;  PRING=1024; RXPREF=0; UDPSEG=1; UDPMAX=8; DIAG=0 ;;
    sharded_rxprefetch)     HANDOFF=sharded; PRING=1024; RXPREF=1; UDPSEG=0; UDPMAX=4; DIAG=0 ;;
    sharded_udp4)           HANDOFF=sharded; PRING=1024; RXPREF=0; UDPSEG=1; UDPMAX=4; DIAG=0 ;;
    all_p2)                 HANDOFF=sharded; PRING=1024; RXPREF=1; UDPSEG=1; UDPMAX=4; DIAG=0 ;;
    *) echo "ERROR: unknown P5_P2_PROFILE=$P2_PROFILE" >&2; exit 2 ;;
esac

P2_ENV="P5_BUILD_REUSE=1 P5_P2_TX_HANDOFF=$HANDOFF P5_P2_TX_PRODUCER_RING_SIZE=$PRING P5_P2_RX_PREFETCH=$RXPREF P5_P2_UDP_SEG=$UDPSEG P5_P2_UDP_SEG_MAX=$UDPMAX P5_P2_DIAG_INTERVAL_US=$DIAG P5_P2_DIAG_DURATION_MS=3000"

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
    printf 'RESTORE_IDEX=%s\nRESTORE_TINYMAN=%s\n' "$r1" "$r2" >> "$RESULT_ROOT/status.env"
    set -e
}
trap restore_native EXIT INT TERM

echo "P5 PERFORMANCE2 SELECTED PROFILE VALIDATION"
echo "profile=$P2_PROFILE handoff=$HANDOFF pring=$PRING rxpref=$RXPREF udpseg=$UDPSEG udpmax=$UDPMAX diag_us=$DIAG"
echo "runs=$RUNS downloads=$DOWNLOADS chart_style=$CHART_STYLE seed=$SEED"

clean_local
clean_client

set +e
(cd "$HERE" && env $P2_ENV bash "$BUILD_HELPER" >"$RESULT_ROOT/logs/build_idex.log" 2>&1) & p1=$!
ssh -n root@"$CLIENT_HOST" "cd '$HERE' && env $P2_ENV bash '$BUILD_HELPER'" >"$RESULT_ROOT/logs/build_tinyman.log" 2>&1 & p2=$!
wait "$p1"; B1=$?
wait "$p2"; B2=$?
set -e
printf 'BUILD_IDEX=%s\nBUILD_TINYMAN=%s\n' "$B1" "$B2" > "$RESULT_ROOT/status.env"
if (( B1 != 0 || B2 != 0 )); then
    echo "ERROR: build failed idex=$B1 tinyman=$B2" >&2
    tail -100 "$RESULT_ROOT/logs/build_idex.log" || true
    tail -100 "$RESULT_ROOT/logs/build_tinyman.log" || true
    exit 20
fi

grep -aFq -- 'GREENQUIC-P5-PERFORMANCE2-V1' "$CLIENT_BIN"
ssh -n root@"$CLIENT_HOST" "grep -aFq -- 'GREENQUIC-P5-PERFORMANCE2-V1' '$CLIENT_BIN'"

SUMMARY="$RESULT_ROOT/selected_profiles_summary.tsv"
printf 'profile\tmode\tn\tmean_active_gbps\tsd_active_gbps\tmin_active_gbps\tmax_active_gbps\trc\tuso_requested\tuso_active\n' > "$SUMMARY"
FAILURES=0

summarize_case() {
    local label="$1" out="$2" log="$3" rc="$4"
    python3 - "$label" "$out" "$log" "$rc" "$UDPSEG" "$SUMMARY" <<'PY'
import csv, re, statistics, sys
from pathlib import Path
label, out, log, rc, udpseg, summary = sys.argv[1:]
client = Path(out) / 'tables' / 'client_all_runs.csv'
vals = {'off': [], 'basic': [], 'plus': []}
if client.is_file():
    with client.open(newline='', encoding='utf-8', errors='replace') as f:
        for row in csv.DictReader(f):
            mode = row.get('run__greenquic_mode', '')
            raw = row.get('greenquic_p5_workload_summary__aggregate_goodput_excluding_gaps', '')
            m = re.search(r'([0-9]+(?:\.[0-9]+)?)', raw)
            if mode in vals and m:
                vals[mode].append(float(m.group(1)))
text = Path(log).read_text(errors='replace') if Path(log).is_file() else ''
active = re.findall(r'\[P5-PERF2-USO\].*?requested=1 active=([01])', text)
uso_active = 'NA' if udpseg != '1' else ('1' if active and all(x == '1' for x in active) else '0')
with open(summary, 'a', newline='') as f:
    for mode in ('off','basic','plus'):
        v = vals[mode]
        n = len(v)
        mean = statistics.mean(v) if v else None
        sd = statistics.stdev(v) if len(v) > 1 else (0.0 if len(v) == 1 else None)
        fmt = lambda x: 'NA' if x is None else f'{x:.6f}'
        f.write('\t'.join([label, mode, str(n), fmt(mean), fmt(sd), fmt(min(v) if v else None), fmt(max(v) if v else None), str(rc), udpseg, uso_active]) + '\n')
PY
}

run_case() {
    local label="$1"; shift
    local out="$MATRIX_ROOT/$label"
    local log="$RESULT_ROOT/logs/${label}.log"
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
    summarize_case "$label" "$out" "$log" "$rc"
    printf '%s_RC=%s\n' "$(printf '%s' "$label" | tr '[:lower:]' '[:upper:]')" "$rc" >> "$RESULT_ROOT/status.env"
    if (( rc != 0 )); then FAILURES=$((FAILURES + 1)); fi
    sleep 10
}

run_case idle_monitor_normal \
    --env GQ_IDLE_MODE_OVERRIDE=monitor \
    --env GQ_IDLE_FALLBACK_OVERRIDE=short

run_case power_friendly \
    --env ENABLE_FREQ=1 \
    --env ENABLE_SLEEP=1 \
    --env GQ_IDLE_MODE_OVERRIDE=epoll \
    --env GQ_IDLE_FALLBACK_OVERRIDE=short

run_case normal_short_8GiB \
    --env GQ_IDLE_MODE_OVERRIDE=short \
    --env GQ_IDLE_FALLBACK_OVERRIDE=short \
    --env REQUEST_PATH=/file_8G.bin \
    --env PAYLOAD_BYTES=8589934592

printf 'FAILURES=%s\n' "$FAILURES" >> "$RESULT_ROOT/status.env"
echo
echo "SELECTED PROFILE SUMMARY"
column -t -s $'\t' "$SUMMARY" 2>/dev/null || cat "$SUMMARY"
echo "RESULT_ROOT=$RESULT_ROOT"
echo "MATRIX_ROOT=$MATRIX_ROOT"
echo "FAILURES=$FAILURES"
exit 0
