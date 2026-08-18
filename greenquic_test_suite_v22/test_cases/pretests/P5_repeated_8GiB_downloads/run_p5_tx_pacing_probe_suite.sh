#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$HERE/../../../.." && pwd)"
BUILD="$HERE/build_p5_tx_pacing_probe.sh"
CASE="$HERE/run_p5_singlecore_mode_case.sh"
SUM="$HERE/summarize_p5_tx_pacing_probe.py"
CLEAN="$HERE/safe_cleanup_p5_bottleneck_processes.py"
REC_GATE="$HERE/enable_p5_claim_recording_gate.py"

RUNS="${P5_PACING_RUNS:-1}"
DOWNLOADS="${P5_PACING_DOWNLOADS:-3}"
TAG="${P5_PACING_TAG:-$(date +%Y%m%d_%H%M%S)}"
ROOT="${P5_PACING_OUTPUT_ROOT:-$HERE/matrix_results/P5_TX_PACING_1D_${DOWNLOADS}d_${RUNS}r_${TAG}}"
CACHE="/tmp/P5_TX_PACING_CACHE_${TAG}"
ACTIVE="$REPO_ROOT/msquic/build-greenquic-p5/bin/Release"
CLIENT_BIN="$ACTIVE/quicinterop"
TRAFFIC_STARTED=0

[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: P5_PACING_RUNS must be positive" >&2; exit 2; }
[[ "$DOWNLOADS" =~ ^[2-9][0-9]*$ ]] || { echo "ERROR: P5_PACING_DOWNLOADS must be >=2 for D2+ steady goodput" >&2; exit 2; }
for f in "$BUILD" "$CASE" "$SUM" "$CLEAN" "$REC_GATE" "$HERE/apply_p5_tx_pacing_probe.py"; do
    [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 2; }
done
bash -n "$BUILD" "$CASE"
python3 -m py_compile "$SUM" "$REC_GATE" "$HERE/apply_p5_tx_pacing_probe.py" "$HERE/make_p5_single_mode_controller.py"
python3 "$HERE/apply_p5_tx_pacing_probe.py" --self-test
python3 "$REC_GATE" --self-test
python3 "$HERE/make_p5_single_mode_controller.py" --self-test
mkdir -p "$ROOT/build_logs" "$CACHE"

cleanup_both() {
    python3 "$CLEAN" || true
    ssh -o BatchMode=yes -o ConnectTimeout=12 root@tinyman \
        "cd '$HERE' && python3 '$CLEAN' || true" || true
}

# Keep ENABLE_RECORD=1 so the normal P5 controller/bundler remains unchanged,
# but disable only the active sampler processes. The claim-proof suite separately
# establishes that this recorder gate does not alter runtime INI or compiled
# bytes before this low-perturbation bottleneck probe is used for mechanism work.
python3 "$REC_GATE" "$HERE/gq_common_p5.sh"
ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman \
    "cd '$HERE' && python3 ./enable_p5_claim_recording_gate.py ./gq_common_p5.sh"

cache_local_release() {
    local profile="$1" dst="$CACHE/$profile"
    rm -rf "$dst"; mkdir -p "$dst"
    cp -a "$ACTIVE/." "$dst/"
    test -x "$dst/quicinterop" -a -x "$dst/quicinteropserver"
    (cd "$dst" && sha256sum quicinterop quicinteropserver >SHA256SUMS)
}

cache_remote_release() {
    local profile="$1"
    ssh -o BatchMode=yes -o ConnectTimeout=20 root@tinyman "bash -s" -- \
        "$profile" "$CACHE" "$ACTIVE" <<'EOS'
set -Eeuo pipefail
profile="$1"; cache="$2"; active="$3"; dst="$cache/$profile"
rm -rf "$dst"; mkdir -p "$dst"; cp -a "$active/." "$dst/"
test -x "$dst/quicinterop" -a -x "$dst/quicinteropserver"
(cd "$dst" && sha256sum quicinterop quicinteropserver >SHA256SUMS)
EOS
}

build_cache_profile() {
    local profile="$1" backoff="$2" sleep_us="$3"
    (( TRAFFIC_STARTED == 0 )) || {
        echo "ERROR: compiler invocation attempted after traffic started: $profile" >&2
        exit 99
    }
    echo "===== PREBUILD+CACHE $profile backoff_ns=$backoff sleep_us=$sleep_us ====="
    cleanup_both
    P5_TX_PACING_BACKOFF_NS="$backoff" P5_TX_PACING_SLEEP_US="$sleep_us" \
        bash "$BUILD" 2>&1 | tee "$ROOT/build_logs/${profile}_idex.log"
    ssh -o BatchMode=yes -o ConnectTimeout=30 root@tinyman \
        "cd '$HERE' && P5_TX_PACING_BACKOFF_NS='$backoff' P5_TX_PACING_SLEEP_US='$sleep_us' \
         bash ./build_p5_tx_pacing_probe.sh" \
        2>&1 | tee "$ROOT/build_logs/${profile}_tinyman.log"
    cache_local_release "$profile"
    cache_remote_release "$profile"
}

activate_local_profile() {
    local profile="$1" src="$CACHE/$profile" next="${ACTIVE}.p5-pacing-next"
    test -x "$src/quicinterop" -a -x "$src/quicinteropserver"
    rm -rf "$next"; mkdir -p "$next"; cp -a "$src/." "$next/"
    rm -rf "$ACTIVE"; mv "$next" "$ACTIVE"
    (cd "$ACTIVE" && sha256sum -c "$src/SHA256SUMS")
}

activate_remote_profile() {
    local profile="$1"
    ssh -o BatchMode=yes -o ConnectTimeout=20 root@tinyman "bash -s" -- \
        "$profile" "$CACHE" "$ACTIVE" <<'EOS'
set -Eeuo pipefail
profile="$1"; cache="$2"; active="$3"; src="$cache/$profile"; next="${active}.p5-pacing-next"
test -x "$src/quicinterop" -a -x "$src/quicinteropserver"
rm -rf "$next"; mkdir -p "$next"; cp -a "$src/." "$next/"
rm -rf "$active"; mv "$next" "$active"
(cd "$active" && sha256sum -c "$src/SHA256SUMS")
EOS
}

# ---------------------------------------------------------------------------
# BUILD PHASE. All compiler work finishes before the first measured packet.
# ---------------------------------------------------------------------------
build_cache_profile p0_no_backoff 0 0
build_cache_profile p1_busy_250ns 250 0
build_cache_profile p2_busy_500ns 500 0
build_cache_profile p3_busy_1000ns 1000 0
build_cache_profile p4_sleep_1us 0 1

BASE_SERVER_SHA="$(awk '{print $1}' "$CACHE/p0_no_backoff/SHA256SUMS" | head -1)"
BASE_CLIENT_SHA="$(ssh -o BatchMode=yes root@tinyman "awk '{print \$1}' '$CACHE/p0_no_backoff/SHA256SUMS' | head -1")"
[[ -n "$BASE_SERVER_SHA" && -n "$BASE_CLIENT_SHA" ]] || { echo "ERROR: baseline cache hashes unavailable" >&2; exit 2; }

TRAFFIC_STARTED=1
echo "P5 TX PACING: TRAFFIC PHASE STARTED; compilation is now forbidden."

run_case() {
    local profile="$1" dir="$ROOT/$profile"
    cleanup_both
    # Intervention is server-only. The client is fixed to the exact zero-backoff
    # binary in every case so ACK/RX/client TX changes cannot explain a gain.
    activate_local_profile "$profile"
    activate_remote_profile p0_no_backoff
    mkdir -p "$dir"
    echo "===== ONE-CORE PACING CASE $profile (server=$profile client=p0_no_backoff) ====="
    bash "$CASE" \
        --mode off \
        --runs "$RUNS" \
        --downloads "$DOWNLOADS" \
        --gap-seconds 5 \
        --server-cooldown-seconds 5 \
        --between-tests-seconds 5 \
        --client-bin "$CLIENT_BIN" \
        --output-dir "$dir" \
        --env ENABLE_MULTICORE=0 \
        --env SERVER_DPDK_LCORES=19 \
        --env CLIENT_DPDK_LCORES=19 \
        --env SERVER_TX_OWNER_LCORE=19 \
        --env CLIENT_TX_OWNER_LCORE=19 \
        --env SERVER_QUIC_CPUS=21,22,23,24 \
        --env CLIENT_QUIC_CPUS=21,22,23,24 \
        --env MSQUIC_EXECUTION_PROFILE=max_throughput \
        --env ENABLE_RECORD=1 \
        --env GQ_CLAIM_DISABLE_ACTIVE_RECORDERS=1 \
        --env GQ_LOG_LEVEL=0 \
        --env GQ_IDLE_MODE_OVERRIDE=monitor \
        --env GQ_IDLE_FALLBACK_OVERRIDE=short
}

run_case p0_no_backoff
run_case p1_busy_250ns
run_case p2_busy_500ns
run_case p3_busy_1000ns
run_case p4_sleep_1us

cleanup_both
python3 "$SUM" --root "$ROOT"

cat >"$ROOT/TX_PACING_CONFIG.env" <<EOF2
runs=$RUNS
downloads_per_run=$DOWNLOADS
connections=1
payload_bytes_per_download=8589934592
dpdk_lcores=19
quic_cpus=21,22,23,24
execution_profile=max_throughput
mode=off
historical_super_reference=cache128_rx32_tx16_ring4096_drain2_mbufmeta_singleowner
historical_idle_profile=monitor_short
active_recorders=disabled_via_recorder_only_gate
server_only_intervention=1
client_profile=p0_no_backoff
compile_after_traffic_start=forbidden
busy_wait_cases_do_not_scheduler_yield=1
sleep_1us_case_may_scheduler_yield=1
baseline_server_quicinterop_sha256=$BASE_SERVER_SHA
baseline_client_quicinterop_sha256=$BASE_CLIENT_SHA
EOF2

echo "P5 ONE-CORE TX PACING PROBE COMPLETE: $ROOT"
