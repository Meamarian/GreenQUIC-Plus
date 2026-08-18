#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$HERE/../../../.." && pwd)"
BUILD="$HERE/build_p5_arch_profile.sh"
CASE="$HERE/run_p5_arch_case_diag.sh"
SUM="$HERE/summarize_p5_arch_sweep.py"
CLEAN="$HERE/safe_cleanup_p5_bottleneck_processes.py"
PATCH="$HERE/enable_p5_arch_runtime_config.py"
ONE="$HERE/enable_p5_arch_single_owner_validation.py"
VERIFY="$HERE/verify_p5_arch_effective_config.py"
VALIDATOR="$HERE/../../../common/bin/validate_v22_config.py"

RUNS="${P5_ARCH_RUNS:-2}"
CONNS="${P5_ARCH_CONNECTIONS:-4}"
TAG="${P5_ARCH_TAG:-$(date +%Y%m%d_%H%M%S)}"
ROOT="${P5_ARCH_OUTPUT_ROOT:-$HERE/matrix_results/P5_ARCH_BOTTLENECK_${CONNS}c_${RUNS}r_${TAG}}"
CACHE="/tmp/P5_ARCH_BINARY_CACHE_${TAG}"
ACTIVE="$REPO_ROOT/msquic/build-greenquic-p5/bin/Release"
TRAFFIC_STARTED=0

[[ "$RUNS" =~ ^[1-9][0-9]*$ && "$CONNS" =~ ^[2-9][0-9]*$ ]] || {
    echo 'ERROR: invalid P5_ARCH_RUNS/P5_ARCH_CONNECTIONS' >&2; exit 2;
}
for f in "$BUILD" "$CASE" "$SUM" "$CLEAN" "$PATCH" "$ONE" "$VERIFY" "$VALIDATOR"; do
    [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 2; }
done
for shf in "$BUILD" "$CASE" "$HERE/run_p5_arch_off_case.sh"; do bash -n "$shf"; done
python3 -m py_compile \
    "$SUM" "$PATCH" "$ONE" "$VERIFY" \
    "$HERE/thread_topology_sampler.py" "$HERE/quic_cpu_activity_sampler.py" \
    "$HERE/analyze_p5_bottleneck_case.py" "$HERE/cpu_busy_sampler.py"
python3 "$HERE/test_p5_performance2_transform.py"
python3 "$HERE/test_p5_performance2_v2_transform.py"
python3 "$PATCH" --self-test
python3 "$ONE" --self-test

mkdir -p "$ROOT/build_logs" "$CACHE"
STATUS="$ROOT/CASE_STATUS.tsv"
MANIFEST="$ROOT/PREBUILT_BINARY_MANIFEST.tsv"
printf 'case\tbuild_profile\ttraffic_rc\tcontroller_rc\tanalysis_rc\teffective_config_rc\n' >"$STATUS"
printf 'profile\thost\tartifact\tsha256\n' >"$MANIFEST"

# Patch only the experiment checkout. Both patches are idempotent. The first
# exposes AFFINITIZE and exact architecture runtime evidence; the second permits
# F/N to exercise the multicore-instrumented source path with one DPDK owner.
python3 "$PATCH" "$HERE/gq_common_p5.sh"
python3 "$ONE" "$VALIDATOR"
ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman \
    "cd '$HERE' && \
     python3 ./enable_p5_arch_runtime_config.py ./gq_common_p5.sh && \
     python3 ./enable_p5_arch_single_owner_validation.py ../../../common/bin/validate_v22_config.py"

cleanup_both() {
    echo '--- safe cleanup IDEX ---'
    python3 "$CLEAN" || true
    echo '--- safe cleanup Tinyman ---'
    ssh -o BatchMode=yes -o ConnectTimeout=12 root@tinyman \
        "cd '$HERE' && python3 '$CLEAN' || true" || true
}

cache_local_release() {
    local profile="$1" dst="$CACHE/$profile"
    rm -rf "$dst"; mkdir -p "$dst"
    cp -a "$ACTIVE/." "$dst/"
    test -x "$dst/quicinterop" -a -x "$dst/quicinteropserver"
    (cd "$dst" && sha256sum quicinterop quicinteropserver >SHA256SUMS)
    while read -r sha file; do
        printf '%s\tidex\t%s\t%s\n' "$profile" "$file" "$sha" >>"$MANIFEST"
    done <"$dst/SHA256SUMS"
}

cache_remote_release() {
    local profile="$1"
    ssh -o BatchMode=yes -o ConnectTimeout=20 root@tinyman "bash -s" -- \
        "$profile" "$CACHE" "$ACTIVE" <<'EOS' >>"$MANIFEST"
set -Eeuo pipefail
profile="$1"; cache="$2"; active="$3"; dst="$cache/$profile"
rm -rf "$dst"; mkdir -p "$dst"; cp -a "$active/." "$dst/"
test -x "$dst/quicinterop" -a -x "$dst/quicinteropserver"
(cd "$dst" && sha256sum quicinterop quicinteropserver >SHA256SUMS)
while read -r sha file; do
    printf '%s\ttinyman\t%s\t%s\n' "$profile" "$file" "$sha"
done <"$dst/SHA256SUMS"
EOS
}

build_cache_profile() {
    local profile="$1"; shift
    ((TRAFFIC_STARTED == 0)) || {
        echo "ERROR: compiler invocation attempted after traffic started: $profile" >&2
        exit 99
    }
    echo "===== PREBUILD+CACHE $profile $* ====="
    cleanup_both
    if (($#)); then
        env "$@" bash "$BUILD" 2>&1 | tee "$ROOT/build_logs/${profile}_idex.log"
    else
        bash "$BUILD" 2>&1 | tee "$ROOT/build_logs/${profile}_idex.log"
    fi

    local q='' remote=''
    if (($#)); then
        printf -v q '%q ' "$@"
        remote="env $q bash ./build_p5_arch_profile.sh"
    else
        remote="bash ./build_p5_arch_profile.sh"
    fi
    ssh -o BatchMode=yes -o ConnectTimeout=30 root@tinyman \
        "cd '$HERE' && $remote" 2>&1 | tee "$ROOT/build_logs/${profile}_tinyman.log"

    cache_local_release "$profile"
    cache_remote_release "$profile"
}

activate_profile() {
    local profile="$1" src="$CACHE/$profile" next="${ACTIVE}.p5-arch-next"
    cleanup_both
    test -x "$src/quicinterop" -a -x "$src/quicinteropserver"
    rm -rf "$next"; mkdir -p "$next"; cp -a "$src/." "$next/"
    rm -rf "$ACTIVE"; mv "$next" "$ACTIVE"
    (cd "$ACTIVE" && sha256sum -c "$src/SHA256SUMS")

    ssh -o BatchMode=yes -o ConnectTimeout=20 root@tinyman "bash -s" -- \
        "$profile" "$CACHE" "$ACTIVE" <<'EOS'
set -Eeuo pipefail
profile="$1"; cache="$2"; active="$3"; src="$cache/$profile"; next="${active}.p5-arch-next"
test -x "$src/quicinterop" -a -x "$src/quicinteropserver"
rm -rf "$next"; mkdir -p "$next"; cp -a "$src/." "$next/"
rm -rf "$active"; mv "$next" "$active"
(cd "$active" && sha256sum -c "$src/SHA256SUMS")
EOS
}

# ---------------------------------------------------------------------------
# BUILD PHASE. ALL compiler work must finish before A starts.
# ---------------------------------------------------------------------------
build_cache_profile baseline
build_cache_profile ring_mp P5_SUPER_RING_SYNC=mp
build_cache_profile ring_rts P5_SUPER_RING_SYNC=rts
build_cache_profile sharded P5_P2_TX_HANDOFF=sharded P5_P2_SHARD_ACTIVE_MASK=1
build_cache_profile udpseg P5_P2_UDP_SEG=1 P5_P2_UDP_SEG_MAX=4

# Verify the reference binary used by B and P is literally one cache object.
BASELINE_IDEX_SHA="$(awk -F'\t' '$1=="baseline" && $2=="idex" && $3=="quicinterop"{print $4}' "$MANIFEST")"
BASELINE_TINY_SHA="$(awk -F'\t' '$1=="baseline" && $2=="tinyman" && $3=="quicinterop"{print $4}' "$MANIFEST")"
[[ -n "$BASELINE_IDEX_SHA" && -n "$BASELINE_TINY_SHA" ]] || {
    echo 'ERROR: baseline binary hashes missing after cache build' >&2; exit 2;
}

TRAFFIC_STARTED=1
printf 'P5 ARCH: TRAFFIC PHASE STARTED; compiler invocation is now forbidden.\n'

run_case() {
    local name="$1" profile="$2" dpdk="$3" quic="$4" part="$5" execp="$6" aff="$7"; shift 7
    local dir="$ROOT/$name" rc=125 cr='' ar='' vrc=125 pmap='' multi=''
    mkdir -p "$dir"
    echo "===== CASE $name PROFILE=$profile DPDK=$dpdk QUIC=$quic partition=$part exec=$execp aff=$aff ====="
    activate_profile "$profile"

    set +e
    bash "$CASE" \
        --case-name "$name" --runs "$RUNS" --connections "$CONNS" \
        --dpdk-lcores "$dpdk" --quic-cpus "$quic" \
        --partition-style "$part" --execution-profile "$execp" \
        --affinitize "$aff" --output-dir "$dir" "$@"
    rc=$?
    set -e

    if [[ -f "$dir/ARCH_CASE_STATUS.env" ]]; then
        cr="$(awk -F= '$1=="controller_rc"{print $2}' "$dir/ARCH_CASE_STATUS.env" | tail -1)"
        ar="$(awk -F= '$1=="analysis_rc"{print $2}' "$dir/ARCH_CASE_STATUS.env" | tail -1)"
        pmap="$(awk -F= '$1=="partition_map"{print substr($0,index($0,"=")+1)}' "$dir/ARCH_CASE_STATUS.env" | tail -1)"
        multi="$(awk -F= '$1=="enable_multicore"{print $2}' "$dir/ARCH_CASE_STATUS.env" | tail -1)"
        if [[ -n "$pmap" && ( "$multi" == 0 || "$multi" == 1 ) ]]; then
            set +e
            python3 "$VERIFY" \
                --case-dir "$dir" --dpdk-lcores "$dpdk" --quic-cpus "$quic" \
                --partition-map "$pmap" --affinitize "$aff" \
                --execution-profile "$execp" --enable-multicore "$multi"
            vrc=$?
            set -e
        fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$name" "$profile" "$rc" "$cr" "$ar" "$vrc" >>"$STATUS"
    ((rc==0)) || echo "WARN: $name traffic rc=$rc; continuing so remaining raw evidence is preserved" >&2
}

cat >"$ROOT/SWEEP_DESIGN.txt" <<EOF2
P5 architecture bottleneck localization V2 -- cases A-P
All five binary profiles were built and cached on IDEX and Tinyman BEFORE A.
No compiler invocation is permitted after the traffic phase starts.
Profile activation copies cached Release bytes into the canonical runtime path and verifies SHA256.
P reuses the exact baseline cache object used by B; it is an end-of-run drift/thermal control, not a rebuild.
F/N use one DPDK owner while retaining the architecture-instrumented queue/statistics source path. The runtime validator labels this a single-owner control and explicitly forbids interpreting it as multicore scaling.

A  2D/4Q AFF=0
B  2D/4Q AFF=1 reference
C  2D/1Q AFF=1
D  2D/2Q AFF=1
E  2D/8Q AFF=1
F  1D/4Q AFF=1 single-owner control
G  4D/4Q AFF=1
H  4D/8Q AFF=1
I  2D/4Q low_latency
J  2D/4Q all partitions -> first DPDK owner
K  2D/4Q grouped partition map
L  2D/4Q MP ring profile
M  2D/4Q RTS ring profile
N  1D/4Q sharded per-producer SPSC handoff, single-owner control
O  2D/4Q experimental UDP segmentation profile; runtime capability evidence still required
P  exact cached B baseline repeated at end
EOF2

run_case A_2D_4Q_noaff baseline 19,20 21,22,23,24 balanced max_throughput 0
run_case B_2D_4Q_aff baseline 19,20 21,22,23,24 balanced max_throughput 1
run_case C_2D_1Q_aff baseline 19,20 21 balanced max_throughput 1
run_case D_2D_2Q_aff baseline 19,20 21,22 balanced max_throughput 1
run_case E_2D_8Q_aff baseline 19,20 21,22,23,24,25,26,27,28 balanced max_throughput 1
run_case F_1D_4Q_aff baseline 19 21,22,23,24 balanced max_throughput 1
run_case G_4D_4Q_aff baseline 17,18,19,20 21,22,23,24 balanced max_throughput 1
run_case H_4D_8Q_aff baseline 17,18,19,20 21,22,23,24,25,26,27,28 balanced max_throughput 1
run_case I_2D_4Q_lowlat baseline 19,20 21,22,23,24 balanced low_latency 1
run_case J_2D_4Q_allfirst baseline 19,20 21,22,23,24 all_first max_throughput 1
run_case K_2D_4Q_grouped baseline 19,20 21,22,23,24 grouped max_throughput 1
run_case L_2D_4Q_ring_mp ring_mp 19,20 21,22,23,24 balanced max_throughput 1
run_case M_2D_4Q_ring_rts ring_rts 19,20 21,22,23,24 balanced max_throughput 1
run_case N_1D_4Q_sharded sharded 19 21,22,23,24 balanced max_throughput 1
run_case O_2D_4Q_udpseg udpseg 19,20 21,22,23,24 balanced max_throughput 1
run_case P_2D_4Q_aff_repeat baseline 19,20 21,22,23,24 balanced max_throughput 1

cleanup_both
python3 "$SUM" --root "$ROOT" || echo 'WARN: summary failed; raw case evidence preserved' >&2

# Postcondition: B and P were both activated from the same immutable baseline cache.
cat >"$ROOT/NO_MID_SWEEP_BUILD_PROOF.env" <<EOF2
traffic_started=$TRAFFIC_STARTED
compiler_after_traffic_start=forbidden
baseline_idex_quicinterop_sha256=$BASELINE_IDEX_SHA
baseline_tinyman_quicinterop_sha256=$BASELINE_TINY_SHA
B_profile=baseline
P_profile=baseline
B_P_exact_cached_baseline=1
EOF2

echo "P5 ARCH BOTTLENECK SWEEP V2 COMPLETE RESULTS=$ROOT STATUS=$STATUS"
