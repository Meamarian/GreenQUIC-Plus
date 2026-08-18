#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$HERE/../../../.." && pwd)"
BUILD="$HERE/build_p5_super_performance.sh"
CASE="$HERE/run_p5_singlecore_mode_case.sh"
ANALYZE="$HERE/analyze_p5_gap_causality.py"
CLEAN="$HERE/safe_cleanup_p5_bottleneck_processes.py"

RUNS="${P5_GAP_RUNS:-1}"
DOWNLOADS="${P5_GAP_DOWNLOADS:-3}"
BETWEEN="${P5_GAP_BETWEEN_TESTS_SECONDS:-5}"
COOLDOWN="${P5_GAP_EDGE_COOLDOWN_SECONDS:-5}"
SIGNAL_PP="${P5_GAP_SIGNAL_PP:-5.0}"
TAG="${P5_GAP_TAG:-$(date +%Y%m%d_%H%M%S)}"
ROOT="${P5_GAP_OUTPUT_ROOT:-$HERE/matrix_results/P5_GAP_CAUSALITY_1D_${DOWNLOADS}d_${RUNS}r_${TAG}}"

[[ "$RUNS" =~ ^[1-9][0-9]*$ && "$DOWNLOADS" =~ ^[2-9][0-9]*$ ]] || {
    echo "ERROR: P5_GAP_RUNS must be positive and P5_GAP_DOWNLOADS must be >=2" >&2; exit 2;
}
for f in "$BUILD" "$CASE" "$ANALYZE" "$CLEAN"; do [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 2; }; done
bash -n "$CASE"; python3 -m py_compile "$ANALYZE"; mkdir -p "$ROOT"

SUPER_ENV=(
    P5_BUILD_REUSE=1 P5_SUPER_CACHE=128 P5_SUPER_RX_BURST=32 P5_SUPER_TX_BURST=16
    P5_SUPER_RING_SIZE=4096 P5_SUPER_RING_SYNC=legacy P5_SUPER_DRAIN_BURSTS=2
    P5_SUPER_DRAIN_THRESHOLD=0 P5_SUPER_MTU=0 P5_SUPER_SKIP_OFF_RINGCOUNT=0
    P5_SUPER_DEBUG_COUNTERS=1 P5_SUPER_TRANSFER_WINDOW=1 P5_SUPER_TRACE_RINGCOUNT=1
    P5_SUPER_TX_META=mbuf P5_SUPER_RX_META=mbuf P5_SUPER_TX_LOCK_MODE=single_owner P5_SUPER_CAP_DIAG=1
)
cleanup_both(){
    python3 "$CLEAN" || true
    ssh -o BatchMode=yes -o ConnectTimeout=12 root@tinyman "cd '$HERE' && python3 '$CLEAN' || true" || true
}

echo "===== GAP-CAUSALITY PREBUILD: historical one-core Super profile ====="
cleanup_both
env "${SUPER_ENV[@]}" bash "$BUILD" 2>&1 | tee "$ROOT/build_idex.log"
remote_env=''; printf -v remote_env '%q ' "${SUPER_ENV[@]}"
ssh -o BatchMode=yes -o ConnectTimeout=30 root@tinyman "cd '$HERE' && env $remote_env bash ./build_p5_super_performance.sh" 2>&1 | tee "$ROOT/build_tinyman.log"

SBIN="$REPO_ROOT/msquic/build-greenquic-p5/bin/Release/quicinteropserver"
CBIN="$REPO_ROOT/msquic/build-greenquic-p5/bin/Release/quicinterop"
test -x "$SBIN" -a -x "$CBIN"
MANIFEST="$ROOT/BINARY_MANIFEST.tsv"; printf 'checkpoint\thost\tartifact\tsha256\n' >"$MANIFEST"
snapshot_hashes(){
    local checkpoint="$1"
    printf '%s\tidex\tserver\t%s\n' "$checkpoint" "$(sha256sum "$SBIN" | awk '{print $1}')" >>"$MANIFEST"
    printf '%s\tidex\tclient\t%s\n' "$checkpoint" "$(sha256sum "$CBIN" | awk '{print $1}')" >>"$MANIFEST"
    ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman "bash -s" -- "$checkpoint" "$SBIN" "$CBIN" <<'EOS' >>"$MANIFEST"
set -Eeuo pipefail
checkpoint="$1"; sbin="$2"; cbin="$3"
printf '%s\ttinyman\tserver\t%s\n' "$checkpoint" "$(sha256sum "$sbin" | awk '{print $1}')"
printf '%s\ttinyman\tclient\t%s\n' "$checkpoint" "$(sha256sum "$cbin" | awk '{print $1}')"
EOS
}
snapshot_hashes pretraffic

run_one(){
    local gap="$1" mode="$2" label="gap${gap}_${mode}" out="$ROOT/gap${gap}_${mode}"
    cleanup_both
    echo "===== GAP CAUSALITY case=$label mode=$mode gap=${gap}s ====="
    bash "$CASE" --mode "$mode" --runs "$RUNS" --downloads "$DOWNLOADS" --gap-seconds "$gap" \
        --server-cooldown-seconds "$COOLDOWN" --between-tests-seconds "$BETWEEN" --client-bin "$CBIN" --output-dir "$out" \
        --env ENABLE_MULTICORE=0 --env SERVER_DPDK_LCORES=19 --env CLIENT_DPDK_LCORES=19 \
        --env SERVER_TX_OWNER_LCORE=19 --env CLIENT_TX_OWNER_LCORE=19 \
        --env SERVER_QUIC_CPUS=21,22,23,24 --env CLIENT_QUIC_CPUS=21,22,23,24 \
        --env MSQUIC_EXECUTION_PROFILE=max_throughput --env ENABLE_RECORD=1 --env GQ_LOG_LEVEL=0 \
        --env ENABLE_FREQ=1 --env ENABLE_SLEEP=1 --env GQ_IDLE_MODE_OVERRIDE=monitor --env GQ_IDLE_FALLBACK_OVERRIDE=short
}

# Alternate within-gap order to reduce a simple monotonic drift bias.
run_one 0 off; run_one 0 plus
run_one 1 plus; run_one 1 off
run_one 5 off; run_one 5 plus
snapshot_hashes posttraffic
cleanup_both

python3 - "$MANIFEST" <<'PY'
import csv,sys
rows=list(csv.DictReader(open(sys.argv[1]),delimiter='\t')); by={}
for r in rows: by.setdefault((r['host'],r['artifact']),set()).add(r['sha256'])
bad={k:v for k,v in by.items() if len(v)!=1}
if bad: raise SystemExit(f'ERROR: binary bytes changed during gap suite: {bad}')
print('P5 GAP BINARY INVARIANCE PASS')
PY
python3 "$ANALYZE" --root "$ROOT" --downloads "$DOWNLOADS" --signal-pp "$SIGNAL_PP"
cat >"$ROOT/GAP_CAUSALITY_CONFIG.env" <<EOF2
runs=$RUNS
downloads_per_run=$DOWNLOADS
payload_bytes_per_download=8589934592
gaps_seconds=0,1,5
dpdk_lcore=19
quic_cpus=21,22,23,24
enable_multicore=0
execution_profile=max_throughput
mode_comparison=off_vs_plus
active_recorders=enabled
idle_mode=monitor
idle_fallback=short
historical_super_reference=cache128_rx32_tx16_ring4096_drain2_mbufmeta_singleowner
historical_plus_steady_d2plus_gbps=10.486178
historical_off_steady_d2plus_gbps=9.423551
signal_threshold_percentage_points=$SIGNAL_PP
EOF2
echo "P5 ONE-CORE GAP CAUSALITY SUITE COMPLETE: $ROOT"
