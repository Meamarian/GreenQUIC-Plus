#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$HERE/../../../.." && pwd)"
BUILD="$HERE/build_p5_super_performance.sh"
MATRIX="$HERE/run_matrix_from_idex.sh"
ANALYZE="$HERE/analyze_p5_claim_proof.py"
GATE="$HERE/enable_p5_claim_recording_gate.py"
CLEAN="$HERE/safe_cleanup_p5_bottleneck_processes.py"

RUNS="${P5_CLAIM_RUNS:-2}"
DOWNLOADS="${P5_CLAIM_DOWNLOADS:-3}"
GAP="${P5_CLAIM_GAP_SECONDS:-5}"
COOLDOWN="${P5_CLAIM_COOLDOWN_SECONDS:-5}"
BETWEEN="${P5_CLAIM_BETWEEN_TESTS_SECONDS:-5}"
EQ_PCT="${P5_CLAIM_RECORDING_EQ_PCT:-2.0}"
MECH_PCT="${P5_CLAIM_MECHANISM_PCT:-2.0}"
PUB_MIN_RUNS="${P5_CLAIM_PUBLICATION_MIN_RUNS:-6}"
TAG="${P5_CLAIM_TAG:-$(date +%Y%m%d_%H%M%S)}"
ROOT="${P5_CLAIM_OUTPUT_ROOT:-$HERE/matrix_results/P5_ONECORE_CLAIM_${RUNS}r_${DOWNLOADS}d_${TAG}}"

[[ "$RUNS" =~ ^[1-9][0-9]*$ && "$DOWNLOADS" =~ ^[2-9][0-9]*$ ]] || {
    echo "ERROR: P5_CLAIM_RUNS must be positive and P5_CLAIM_DOWNLOADS must be >=2" >&2; exit 2;
}
for f in "$BUILD" "$MATRIX" "$ANALYZE" "$GATE" "$CLEAN"; do
    [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 2; }
done
bash -n "$MATRIX"
python3 -m py_compile "$ANALYZE" "$GATE"
python3 "$GATE" --self-test

mkdir -p "$ROOT"
MANIFEST="$ROOT/BINARY_MANIFEST.tsv"
printf 'checkpoint\thost\tartifact\tsha256\tpath\n' >"$MANIFEST"

SUPER_ENV=(
    P5_BUILD_REUSE=1
    P5_SUPER_CACHE=128
    P5_SUPER_RX_BURST=32
    P5_SUPER_TX_BURST=16
    P5_SUPER_RING_SIZE=4096
    P5_SUPER_RING_SYNC=legacy
    P5_SUPER_DRAIN_BURSTS=2
    P5_SUPER_DRAIN_THRESHOLD=0
    P5_SUPER_MTU=0
    P5_SUPER_SKIP_OFF_RINGCOUNT=0
    P5_SUPER_DEBUG_COUNTERS=1
    P5_SUPER_TRANSFER_WINDOW=1
    P5_SUPER_TRACE_RINGCOUNT=1
    P5_SUPER_TX_META=mbuf
    P5_SUPER_RX_META=mbuf
    P5_SUPER_TX_LOCK_MODE=single_owner
    P5_SUPER_CAP_DIAG=1
)

cleanup_both() {
    python3 "$CLEAN" || true
    ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman \
        "cd '$HERE' && python3 '$CLEAN' || true" || true
}

python3 "$GATE" "$HERE/gq_common_p5.sh"
ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman \
    "cd '$HERE' && python3 ./enable_p5_claim_recording_gate.py ./gq_common_p5.sh"

echo "===== ONE-CORE CLAIM PREBUILD: exact historical Super configuration ====="
cleanup_both
env "${SUPER_ENV[@]}" bash "$BUILD" 2>&1 | tee "$ROOT/build_idex.log"
remote_env=''
printf -v remote_env '%q ' "${SUPER_ENV[@]}"
ssh -o BatchMode=yes -o ConnectTimeout=30 root@tinyman \
    "cd '$HERE' && env $remote_env bash ./build_p5_super_performance.sh" \
    2>&1 | tee "$ROOT/build_tinyman.log"

SBIN="$REPO_ROOT/msquic/build-greenquic-p5/bin/Release/quicinteropserver"
CBIN="$REPO_ROOT/msquic/build-greenquic-p5/bin/Release/quicinterop"

for bin in "$SBIN" "$CBIN"; do
    test -x "$bin"
    grep -aFq -- 'GREENQUIC-P5-SUPER-PERF-V2' "$bin"
done
ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman \
    "grep -aFq -- GREENQUIC-P5-SUPER-PERF-V2 '$CBIN' && grep -aFq -- GREENQUIC-P5-SUPER-PERF-V2 '$SBIN'"

snapshot_hashes() {
    local checkpoint="$1" bin artifact linked
    for artifact in server client; do
        if [[ "$artifact" == server ]]; then bin="$SBIN"; else bin="$CBIN"; fi
        [[ -x "$bin" ]] || { echo "ERROR: missing $bin" >&2; exit 2; }
        printf '%s\tidex\t%s\t%s\t%s\n' \
            "$checkpoint" "$artifact" "$(sha256sum "$bin" | awk '{print $1}')" "$bin" >>"$MANIFEST"
    done
    linked="$(ldd "$CBIN" 2>/dev/null | awk '$1 ~ /^libmsquic\.so/ && $2=="=>" {print $3; exit}')"
    if [[ -n "$linked" && -r "$linked" ]]; then
        printf '%s\tidex\tlibmsquic\t%s\t%s\n' \
            "$checkpoint" "$(sha256sum "$linked" | awk '{print $1}')" "$linked" >>"$MANIFEST"
    fi

    ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman "bash -s" -- "$checkpoint" "$SBIN" "$CBIN" <<'EOS' >>"$MANIFEST"
set -Eeuo pipefail
checkpoint="$1"; sbin="$2"; cbin="$3"
for artifact in server client; do
    if [[ "$artifact" == server ]]; then bin="$sbin"; else bin="$cbin"; fi
    test -x "$bin"
    printf '%s\ttinyman\t%s\t%s\t%s\n' "$checkpoint" "$artifact" "$(sha256sum "$bin" | awk '{print $1}')" "$bin"
done
linked="$(ldd "$cbin" 2>/dev/null | awk '$1 ~ /^libmsquic\.so/ && $2=="=>" {print $3; exit}')"
if [[ -n "$linked" && -r "$linked" ]]; then
    printf '%s\ttinyman\tlibmsquic\t%s\t%s\n' "$checkpoint" "$(sha256sum "$linked" | awk '{print $1}')" "$linked"
fi
EOS
}

snapshot_hashes pretraffic

run_matrix() {
    local label="$1" disable_recorders="$2" enable_freq="$3" enable_sleep="$4" idle_mode="$5"
    local out="$ROOT/$label"
    echo
    echo "======================================================================"
    echo "ONE-CORE CLAIM CASE=$label recorders_disabled=$disable_recorders freq=$enable_freq sleep=$enable_sleep idle=$idle_mode"
    echo "======================================================================"
    cleanup_both
    snapshot_hashes "before_${label}"
    bash "$MATRIX" \
        --runs "$RUNS" \
        --downloads "$DOWNLOADS" \
        --gap-seconds "$GAP" \
        --server-cooldown-seconds "$COOLDOWN" \
        --between-tests-seconds "$BETWEEN" \
        --mode-order balanced \
        --seed 20260818 \
        --client-bin "$CBIN" \
        --output-dir "$out" \
        --env ENABLE_RECORD=1 \
        --env GQ_CLAIM_DISABLE_ACTIVE_RECORDERS="$disable_recorders" \
        --env GQ_LOG_LEVEL=0 \
        --env ENABLE_FREQ="$enable_freq" \
        --env ENABLE_SLEEP="$enable_sleep" \
        --env GQ_IDLE_MODE_OVERRIDE="$idle_mode" \
        --env GQ_IDLE_FALLBACK_OVERRIDE=short \
        --env ENABLE_MULTICORE=0 \
        --env SERVER_DPDK_LCORES=19 \
        --env CLIENT_DPDK_LCORES=19 \
        --env SERVER_TX_OWNER_LCORE=19 \
        --env CLIENT_TX_OWNER_LCORE=19 \
        --env SERVER_QUIC_CPUS=21,22,23,24 \
        --env CLIENT_QUIC_CPUS=21,22,23,24 \
        --env MSQUIC_EXECUTION_PROFILE=max_throughput \
        --env GQ_INTEROP_SERVER_BIN="$SBIN" \
        --env GQ_INTEROP_CLIENT_BIN="$CBIN" \
        --env GQ_POST_TRANSFER_WAIT_S="$COOLDOWN"
    snapshot_hashes "after_${label}"
}

run_matrix full_recorders_on  0 1 1 monitor
run_matrix full_recorders_off 1 1 1 monitor
run_matrix nopwr_recorders_off 1 0 0 off
run_matrix nopwr_recorders_on  0 0 0 off
run_matrix freq_only_recorders_on  0 1 0 off
run_matrix sleep_only_recorders_on 0 0 1 monitor

cleanup_both
python3 "$ANALYZE" \
    --root "$ROOT" \
    --downloads "$DOWNLOADS" \
    --equivalence-pct "$EQ_PCT" \
    --mechanism-pct "$MECH_PCT" \
    --publication-min-runs "$PUB_MIN_RUNS" \
    --dpdk-lcore 19 \
    --quic-cpus 21,22,23,24

cat >"$ROOT/CLAIM_SUITE_CONFIG.env" <<EOF2
runs=$RUNS
downloads=$DOWNLOADS
gap_seconds=$GAP
cooldown_seconds=$COOLDOWN
between_tests_seconds=$BETWEEN
recording_equivalence_pct=$EQ_PCT
mechanism_screen_pct=$MECH_PCT
publication_min_runs=$PUB_MIN_RUNS
payload_bytes_per_download=8589934592
dpdk_lcore=19
quic_cpus=21,22,23,24
enable_multicore=0
execution_profile=max_throughput
historical_idle_mode=monitor
historical_idle_fallback=short
historical_plus_steady_d2plus_gbps=10.486178
historical_off_steady_d2plus_gbps=9.423551
same_binary_required=1
same_mode_schedule_seed=20260818
active_recorder_gate=GQ_CLAIM_DISABLE_ACTIVE_RECORDERS
boundary_rapl_kept_constant=1
super_cache=128
super_rx_burst=32
super_tx_burst=16
super_ring_size=4096
super_drain_bursts=2
super_tx_meta=mbuf
super_rx_meta=mbuf
super_tx_lock_mode=single_owner
EOF2

echo "P5 ONE-CORE CLAIM-PROOF SUITE COMPLETE: $ROOT"
