#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$HERE/../../../.." && pwd)"
BUILD="$HERE/build_p5_11g_candidate.sh"
CASE="$HERE/run_p5_singlecore_mode_case.sh"
ANALYZE="$HERE/analyze_p5_11g_target.py"
CLEAN="$HERE/safe_cleanup_p5_bottleneck_processes.py"
GATE="$HERE/enable_p5_claim_recording_gate.py"

SCREEN_RUNS="${P5_11G_SCREEN_RUNS:-1}"
SCREEN_DLS="${P5_11G_SCREEN_DOWNLOADS:-3}"
VALID_RUNS="${P5_11G_VALIDATE_RUNS:-6}"
VALID_DLS="${P5_11G_VALIDATE_DOWNLOADS:-6}"
TARGET="${P5_11G_TARGET_GBPS:-11.0}"
ACTIVE_RECORDERS="${P5_11G_ACTIVE_RECORDERS:-1}"
RECORDER_CPU="${P5_11G_RECORDER_CPU:-auto}"
TAG="${P5_11G_TAG:-$(date +%Y%m%d_%H%M%S)}"
ROOT="${P5_11G_OUTPUT_ROOT:-$HERE/matrix_results/P5_11G_TARGET_1D_${TAG}}"
CACHE="/tmp/P5_11G_CACHE_${TAG}"
ACTIVE="$REPO_ROOT/msquic/build-greenquic-p5/bin/Release"
TRAFFIC_STARTED=0

[[ "$SCREEN_RUNS" =~ ^[1-9][0-9]*$ && "$VALID_RUNS" =~ ^[1-9][0-9]*$ && \
   "$SCREEN_DLS" =~ ^[2-9][0-9]*$ && "$VALID_DLS" =~ ^[2-9][0-9]*$ ]] || {
    echo 'ERROR: invalid run/download counts' >&2
    exit 2
}
[[ "$ACTIVE_RECORDERS" == 0 || "$ACTIVE_RECORDERS" == 1 ]] || {
    echo 'ERROR: P5_11G_ACTIVE_RECORDERS must be 0 or 1' >&2
    exit 2
}
if [[ "$ACTIVE_RECORDERS" == 1 ]]; then
    DISABLE_ACTIVE_RECORDERS=0
    ACTIVE_RECORDERS_LABEL=enabled_pinned
else
    DISABLE_ACTIVE_RECORDERS=1
    ACTIVE_RECORDERS_LABEL=disabled_via_claim_gate
fi
for f in "$BUILD" "$CASE" "$ANALYZE" "$CLEAN" "$GATE"; do
    [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 2; }
done
bash -n "$BUILD" "$CASE"
python3 -m py_compile "$ANALYZE" "$GATE"
python3 "$GATE" --self-test
mkdir -p "$ROOT/build_logs" "$CACHE"
MANIFEST="$ROOT/PREBUILT_BINARY_MANIFEST.tsv"
printf 'profile\thost\tartifact\tsha256\n' >"$MANIFEST"

cleanup_both() {
    python3 "$CLEAN"
    python3 "$CLEAN" --check
    ssh -o BatchMode=yes -o ConnectTimeout=12 root@tinyman \
        "cd '$HERE' && python3 '$CLEAN' && python3 '$CLEAN' --check"
}

python3 "$GATE" "$HERE/gq_common_p5.sh"
ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman \
    "cd '$HERE' && python3 ./enable_p5_claim_recording_gate.py ./gq_common_p5.sh"

cache_local() {
    local profile="$1" dst="$CACHE/$profile"
    rm -rf "$dst"
    mkdir -p "$dst"
    cp -a "$ACTIVE/." "$dst/"
    test -x "$dst/quicinterop" -a -x "$dst/quicinteropserver"
    (cd "$dst" && sha256sum quicinterop quicinteropserver >SHA256SUMS)
    while read -r sha artifact; do
        printf '%s\tidex\t%s\t%s\n' "$profile" "$artifact" "$sha" >>"$MANIFEST"
    done <"$dst/SHA256SUMS"
}

cache_remote() {
    local profile="$1"
    ssh -o BatchMode=yes -o ConnectTimeout=20 root@tinyman "bash -s" -- \
        "$profile" "$CACHE" "$ACTIVE" <<'EOS' >>"$MANIFEST"
set -Eeuo pipefail
profile="$1"; cache="$2"; active="$3"; dst="$cache/$profile"
rm -rf "$dst"
mkdir -p "$dst"
cp -a "$active/." "$dst/"
test -x "$dst/quicinterop" -a -x "$dst/quicinteropserver"
(cd "$dst" && sha256sum quicinterop quicinteropserver >SHA256SUMS)
while read -r sha artifact; do
    printf '%s\ttinyman\t%s\t%s\n' "$profile" "$artifact" "$sha"
done <"$dst/SHA256SUMS"
EOS
}

build_cache() {
    local profile="$1" build_profile="$2" drain="$3"
    (( TRAFFIC_STARTED == 0 )) || {
        echo "ERROR: compiler invocation attempted after traffic started: $profile" >&2
        exit 99
    }
    echo "===== PREBUILD $profile profile=$build_profile drain=$drain ====="
    cleanup_both
    P5_11G_PROFILE="$build_profile" P5_11G_DRAIN="$drain" \
        bash "$BUILD" 2>&1 | tee "$ROOT/build_logs/${profile}_idex.log"
    ssh -o BatchMode=yes -o ConnectTimeout=30 root@tinyman \
        "cd '$HERE' && P5_11G_PROFILE='$build_profile' P5_11G_DRAIN='$drain' bash ./build_p5_11g_candidate.sh" \
        2>&1 | tee "$ROOT/build_logs/${profile}_tinyman.log"
    cache_local "$profile"
    cache_remote "$profile"
}

activate() {
    local profile="$1" next="${ACTIVE}.p5-11g-next"
    cleanup_both
    test -x "$CACHE/$profile/quicinterop" -a -x "$CACHE/$profile/quicinteropserver"
    rm -rf "$next"
    mkdir -p "$next"
    cp -a "$CACHE/$profile/." "$next/"
    rm -rf "$ACTIVE"
    mv "$next" "$ACTIVE"
    (cd "$ACTIVE" && sha256sum -c "$CACHE/$profile/SHA256SUMS")

    ssh -o BatchMode=yes -o ConnectTimeout=20 root@tinyman "bash -s" -- \
        "$profile" "$CACHE" "$ACTIVE" <<'EOS'
set -Eeuo pipefail
profile="$1"; cache="$2"; active="$3"; next="${active}.p5-11g-next"
test -x "$cache/$profile/quicinterop" -a -x "$cache/$profile/quicinteropserver"
rm -rf "$next"
mkdir -p "$next"
cp -a "$cache/$profile/." "$next/"
rm -rf "$active"
mv "$next" "$active"
(cd "$active" && sha256sum -c "$cache/$profile/SHA256SUMS")
EOS
}

# All compiler work finishes before the first measured packet.
build_cache super_d2 super 2
build_cache p2_d2 p2 2
build_cache p2_d5 p2 5
TRAFFIC_STARTED=1
echo 'P5 11G: TRAFFIC PHASE STARTED; compilation is now forbidden.'

# Match the current optimized P5 measurement environment. 11G cases still
# change their documented candidate knobs (binary profile, empty-poll thresholds,
# active sleep level), but observer placement/timing/CPU mapping stays identical.
COMMON=(
    --env ENABLE_MULTICORE=0
    --env SERVER_DPDK_LCORES=19
    --env CLIENT_DPDK_LCORES=19
    --env SERVER_TX_OWNER_LCORE=19
    --env CLIENT_TX_OWNER_LCORE=19
    --env SERVER_QUIC_CPUS=21,22,23,24
    --env CLIENT_QUIC_CPUS=21,22,23,24
    --env MSQUIC_EXECUTION_PROFILE=max_throughput
    --env ENABLE_RECORD=1
    --env GQ_CLAIM_DISABLE_ACTIVE_RECORDERS="$DISABLE_ACTIVE_RECORDERS"
    --env GQ_CLAIM_RECORDER_CPU="$RECORDER_CPU"
    --env GQ_LOG_LEVEL=0
    --env ENABLE_FREQ=1
    --env ENABLE_SLEEP=1
    --env ENABLE_PAUSE=1
    --env KEEP_PAUSE_ITERATIONS=1
    --env SHORT_PAUSE_ITERATIONS=1
    --env GQ_IDLE_MODE_OVERRIDE=monitor
    --env GQ_IDLE_FALLBACK_OVERRIDE=short
    --env GQ_POST_TRANSFER_WAIT_S=0
)

run_plus() {
    local name="$1" profile="$2" runs="$3" downloads="$4" rx="$5" tx="$6" active_min="$7"
    activate "$profile"
    mkdir -p "$ROOT/$name"
    echo "===== 11G CASE $name profile=$profile rxempty=$rx txempty=$tx active_min=$active_min recorders=$ACTIVE_RECORDERS_LABEL recorder_cpu=$RECORDER_CPU ====="
    bash "$CASE" \
        --mode plus \
        --runs "$runs" \
        --downloads "$downloads" \
        --gap-seconds 5 \
        --server-cooldown-seconds 5 \
        --between-tests-seconds 5 \
        --client-bin "$ACTIVE/quicinterop" \
        --output-dir "$ROOT/$name" \
        "${COMMON[@]}" \
        --env RX_EMPTY_POLLS="$rx" \
        --env TX_EMPTY_POLLS="$tx" \
        --env ACTIVE_TRANSFER_SLEEP_MIN_LEVEL="$active_min"
}

SPEC="$ROOT/SCREEN_CASES.tsv"
printf 'case\tbinary_profile\trx_empty_polls\ttx_empty_polls\tactive_transfer_sleep_min_level\n' >"$SPEC"
add_screen() {
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >>"$SPEC"
    run_plus "$1" "$2" "$SCREEN_RUNS" "$SCREEN_DLS" "$3" "$4" "$5"
}

add_screen s0_super_default super_d2 50000 50000 4
add_screen s1_p2_default p2_d2 50000 50000 4
add_screen s2_p2_drain5_default p2_d5 50000 50000 4
add_screen s3_p2_e25k p2_d2 25000 25000 4
add_screen s4_p2_e10k p2_d2 10000 10000 4
add_screen s5_p2_e5k p2_d2 5000 5000 4
add_screen s6_p2_e10k_active2 p2_d2 10000 10000 2
add_screen s7_p2d5_e10k_active2 p2_d5 10000 10000 2

python3 "$ANALYZE" \
    --root "$ROOT" --phase screen --downloads "$SCREEN_DLS" --target-gbps "$TARGET"
# shellcheck disable=SC1090
source "$ROOT/WINNER.env"

echo "===== 11G PAIRED VALIDATION winner=$winner_case repetitions=$VALID_RUNS ====="
mkdir -p "$ROOT/validation"
for ((rep=1; rep<=VALID_RUNS; rep++)); do
    printf -v r '%02d' "$rep"
    if (( rep % 2 == 1 )); then
        echo "--- validation pair $r order=reference,winner ---"
        run_plus "validation/rep${r}_super_reference" super_d2 1 "$VALID_DLS" 50000 50000 4
        run_plus "validation/rep${r}_winner" "$winner_binary_profile" 1 "$VALID_DLS" \
            "$winner_rx_empty_polls" "$winner_tx_empty_polls" "$winner_active_transfer_sleep_min_level"
    else
        echo "--- validation pair $r order=winner,reference ---"
        run_plus "validation/rep${r}_winner" "$winner_binary_profile" 1 "$VALID_DLS" \
            "$winner_rx_empty_polls" "$winner_tx_empty_polls" "$winner_active_transfer_sleep_min_level"
        run_plus "validation/rep${r}_super_reference" super_d2 1 "$VALID_DLS" 50000 50000 4
    fi
done

python3 "$ANALYZE" \
    --root "$ROOT" --phase validation --downloads "$VALID_DLS" \
    --target-gbps "$TARGET" --robust-min-runs 6

if [[ "$ACTIVE_RECORDERS" == 1 ]]; then
    find "$ROOT" -type f -name '*_affinity.txt' -print >"$ROOT/RECORDER_AFFINITY_FILES.txt"
    test -s "$ROOT/RECORDER_AFFINITY_FILES.txt" || {
        echo 'ERROR: active recorders requested but no recorder-affinity evidence was produced' >&2
        exit 3
    }
fi

cat >"$ROOT/11G_CONFIG.env" <<EOF2
target_gbps=$TARGET
screen_runs=$SCREEN_RUNS
screen_downloads=$SCREEN_DLS
validation_runs=$VALID_RUNS
validation_downloads=$VALID_DLS
dpdk_lcore=19
quic_cpus=21,22,23,24
connections=1
gap_seconds=5
server_cooldown_seconds=5
between_tests_seconds=5
mode=plus
active_recorders=$ACTIVE_RECORDERS_LABEL
recorder_cpu=$RECORDER_CPU
idle_mode=monitor
idle_fallback=short
pause_enabled=1
post_transfer_wait_s=0
historical_plus_steady_d2plus_gbps=10.486178
screen_is_directional_only=1
validation_order=alternating_paired_reference_winner
validation_mean_required_for_11g_pass=1
validation_90pct_ci_lower_bound_required_for_robust_pass=1
robust_min_runs=6
compile_after_traffic_start=forbidden
EOF2

cleanup_both
echo "P5 ONE-CORE 11G TARGET SUITE COMPLETE: $ROOT"
