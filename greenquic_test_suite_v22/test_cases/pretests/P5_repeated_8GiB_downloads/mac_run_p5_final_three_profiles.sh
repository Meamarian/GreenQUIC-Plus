#!/usr/bin/env bash
set -Eeuo pipefail

BRANCH="performance/p5-max-goodput"
DOWNLOADS="${P5_FINAL_DOWNLOADS:-3}"
RUNS="${P5_FINAL_RUNS:-1}"
SEED="${P5_FINAL_SEED:-20260806}"

[[ "$DOWNLOADS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: P5_FINAL_DOWNLOADS must be positive" >&2; exit 2; }
[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: P5_FINAL_RUNS must be positive" >&2; exit 2; }

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$HERE/../../../.." && pwd)"
P5="/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
STAMP="$(date +%Y%m%d_%H%M%S)"
BUNDLE="/tmp/GreenQUIC_P5_FINAL_${STAMP}.bundle"
REMOTE_BUNDLE="/tmp/GreenQUIC_P5_FINAL_${STAMP}.bundle"
FINAL_ROOT="$P5/matrix_results/P5_FINAL_PLUS_PERF_${STAMP}"
LOCAL="$HOME/Downloads/P5_FINAL_PLUS_PERF_${STAMP}"
BUILD_LOG_I="/tmp/P5_FINAL_BUILD_IDEX_${STAMP}.log"
BUILD_LOG_T="/tmp/P5_FINAL_BUILD_TINYMAN_${STAMP}.log"

PERF_ENV="P5_BUILD_REUSE=1 P5_SUPER_CACHE=128 P5_SUPER_RX_BURST=32 P5_SUPER_TX_BURST=16 P5_SUPER_RING_SIZE=4096 P5_SUPER_RING_SYNC=legacy P5_SUPER_DRAIN_BURSTS=2 P5_SUPER_DRAIN_THRESHOLD=0 P5_SUPER_MTU=0 P5_SUPER_SKIP_OFF_RINGCOUNT=0 P5_SUPER_DEBUG_COUNTERS=1 P5_SUPER_TRANSFER_WINDOW=1 P5_SUPER_TRACE_RINGCOUNT=1 P5_SUPER_TX_META=mbuf P5_SUPER_RX_META=mbuf P5_SUPER_TX_LOCK_MODE=single_owner P5_SUPER_CAP_DIAG=1"

cd "$REPO_ROOT"
trap 'rm -f "$BUNDLE"' EXIT

echo "======================================================================"
echo "P5 FINAL THREE PROFILE RUN"
echo "downloads=$DOWNLOADS runs=$RUNS seed=$SEED"
echo "performance=cache128 txburst16 drain2 metadata-in-mbuf TX/RX single-TX-owner"
echo "GreenQUIC policy/thresholds/hints are not changed by this script."
echo "======================================================================"

if [ -n "$(git status --porcelain)" ]; then
    echo "Saving Mac working-tree changes..."
    git stash push -u -m "pre-p5-final-${STAMP}"
fi

git fetch origin main "$BRANCH"
EXPECTED="$(git rev-parse "origin/$BRANCH")"

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git checkout "$BRANCH"
else
    git checkout -b "$BRANCH" "origin/$BRANCH"
fi
git reset --hard "origin/$BRANCH"

echo
git log -1 --format='MAC HEAD=%H%nSUBJECT=%s'

IDEX_HEAD="$(ssh idex 'git -C /root/mohsen rev-parse HEAD 2>/dev/null || true')"
TINY_HEAD="$(ssh idex 'ssh root@tinyman "git -C /root/mohsen rev-parse HEAD 2>/dev/null || true"' 2>/dev/null || true)"
BASE=""
if [ -n "$IDEX_HEAD" ] && [ "$IDEX_HEAD" = "$TINY_HEAD" ] && git cat-file -e "$IDEX_HEAD^{commit}" 2>/dev/null && git merge-base --is-ancestor "$IDEX_HEAD" "$EXPECTED"; then
    BASE="$IDEX_HEAD"
fi

rm -f "$BUNDLE"
if [ -n "$BASE" ] && [ "$BASE" = "$EXPECTED" ]; then
    if PARENT="$(git rev-parse "$EXPECTED^" 2>/dev/null)"; then
        git bundle create "$BUNDLE" "$BRANCH" "^$PARENT"
    else
        git bundle create "$BUNDLE" "$BRANCH"
    fi
elif [ -n "$BASE" ]; then
    echo "Creating incremental bundle from server HEAD $BASE"
    git bundle create "$BUNDLE" "$BRANCH" "^$BASE"
else
    echo "Server HEADs are not a common known ancestor; creating full branch bundle."
    git bundle create "$BUNDLE" "$BRANCH"
fi
ls -lh "$BUNDLE"

if ssh idex 'ps -eo args= | grep -Eq "[r]un_p5_super_performance_sweep(_v[23])?\.sh|[m]ac_run_p5_final_three_profiles\.sh|[r]un_cache128_ring_sweep\.sh|[r]un_cache128_isolated_feature_sweep\.sh"'; then
    echo "ERROR: another P5 performance/final run is still active on idex."
    ssh idex 'ps -eo pid=,args= | grep -E "[r]un_p5_super_performance_sweep(_v[23])?\.sh|[m]ac_run_p5_final_three_profiles\.sh|[r]un_cache128_ring_sweep\.sh|[r]un_cache128_isolated_feature_sweep\.sh"'
    exit 40
fi

scp "$BUNDLE" "idex:$REMOTE_BUNDLE"
ssh idex "scp '$REMOTE_BUNDLE' root@tinyman:'$REMOTE_BUNDLE'"

ssh idex "EXPECTED='$EXPECTED' BRANCH='$BRANCH' BUNDLE='$REMOTE_BUNDLE' bash -s" <<'REMOTE'
set -euo pipefail
cd /root/mohsen
git reset --hard
git fetch "$BUNDLE" "refs/heads/$BRANCH"
git checkout -B "$BRANCH" FETCH_HEAD
test "$(git rev-parse HEAD)" = "$EXPECTED"
echo "IDEX:"
git log -1 --format='HEAD=%H%nSUBJECT=%s'
REMOTE

ssh idex "ssh root@tinyman \"EXPECTED='$EXPECTED' BRANCH='$BRANCH' BUNDLE='$REMOTE_BUNDLE' bash -s\"" <<'REMOTE'
set -euo pipefail
cd /root/mohsen
git reset --hard
git fetch "$BUNDLE" "refs/heads/$BRANCH"
git checkout -B "$BRANCH" FETCH_HEAD
test "$(git rev-parse HEAD)" = "$EXPECTED"
echo "TINYMAN:"
git log -1 --format='HEAD=%H%nSUBJECT=%s'
REMOTE

ssh idex "cd '$P5' && bash -n ./build_p5_super_performance.sh && python3 -m py_compile ./apply_p5_super_performance.py ./apply_p5_super_packet_counter_guard.py && echo 'IDEX FINAL PREFLIGHT PASS'"
ssh idex "ssh root@tinyman \"cd '$P5' && bash -n ./build_p5_super_performance.sh && python3 -m py_compile ./apply_p5_super_performance.py ./apply_p5_super_packet_counter_guard.py && echo 'TINYMAN FINAL PREFLIGHT PASS'\""

echo
echo "======================================================================"
echo "BUILDING VERIFIED PLUS-THROUGHPUT DATAPATH ON BOTH HOSTS"
echo "======================================================================"

set +e
ssh idex "cd '$P5' && env $PERF_ENV bash ./build_p5_super_performance.sh" >"$BUILD_LOG_I" 2>&1 &
BPID_I=$!
ssh idex "ssh root@tinyman \"cd '$P5' && env $PERF_ENV bash ./build_p5_super_performance.sh\"" >"$BUILD_LOG_T" 2>&1 &
BPID_T=$!
wait "$BPID_I"; BRC_I=$?
wait "$BPID_T"; BRC_T=$?
set -e

if [ "$BRC_I" -ne 0 ] || [ "$BRC_T" -ne 0 ]; then
    echo "ERROR: performance build failed: idex=$BRC_I tinyman=$BRC_T"
    echo "--- IDEX BUILD TAIL ---"; tail -120 "$BUILD_LOG_I" || true
    echo "--- TINYMAN BUILD TAIL ---"; tail -120 "$BUILD_LOG_T" || true
    exit 50
fi

grep -F 'GREENQUIC-P5-SUPER-PERF-V2' "$BUILD_LOG_I" | tail -1 || true
grep -F 'GREENQUIC-P5-SUPER-PERF-V2' "$BUILD_LOG_T" | tail -1 || true

echo
echo "======================================================================"
echo "RUNNING FINAL THREE PROFILES"
echo "======================================================================"

set +e
ssh idex "P5='$P5' FINAL_ROOT='$FINAL_ROOT' DOWNLOADS='$DOWNLOADS' RUNS='$RUNS' SEED='$SEED' bash -s" <<'REMOTE'
set -euo pipefail
cd "$P5"
mkdir -p "$FINAL_ROOT"

run_common() {
    local output="$1"
    shift
    bash ./run_matrix_with_sheet.sh \
        --chart-style both \
        --client-host tinyman \
        --client-dir "$P5" \
        --client-bin /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop \
        --downloads "$DOWNLOADS" \
        --gap-seconds 5 \
        --server-cooldown-seconds 5 \
        --between-tests-seconds 0 \
        --cstate-cpu 19 \
        --runs "$RUNS" \
        --mode-order balanced \
        --seed "$SEED" \
        --output-dir "$output" \
        --env ENABLE_RECORD=1 \
        --env GQ_LOG_LEVEL=0 \
        "$@"
}

echo "=== 1/3 IDLE_MONITOR_NORMAL ==="
run_common "$FINAL_ROOT/01_idle_monitor_normal" \
    --env GQ_IDLE_MODE_OVERRIDE=monitor \
    --env GQ_IDLE_FALLBACK_OVERRIDE=short

echo "=== 2/3 POWER_FRIENDLY ==="
run_common "$FINAL_ROOT/02_power_friendly" \
    --env ENABLE_FREQ=1 \
    --env ENABLE_SLEEP=1 \
    --env GQ_IDLE_MODE_OVERRIDE=epoll \
    --env GQ_IDLE_FALLBACK_OVERRIDE=short

echo "=== 3/3 NORMAL_SHORT_8GiB ==="
run_common "$FINAL_ROOT/03_normal_short_8GiB" \
    --env GQ_IDLE_MODE_OVERRIDE=short \
    --env GQ_IDLE_FALLBACK_OVERRIDE=short \
    --env REQUEST_PATH=/file_8G.bin \
    --env PAYLOAD_BYTES=8589934592
REMOTE
RUN_RC=$?
set -e

echo
echo "======================================================================"
echo "COPYING FINAL RESULTS TO MAC"
echo "======================================================================"
mkdir -p "$LOCAL"
if ssh idex "test -d '$FINAL_ROOT'"; then
    scp -r "idex:${FINAL_ROOT}/." "$LOCAL/" || true
fi
cp "$BUILD_LOG_I" "$LOCAL/build_idex.log" 2>/dev/null || true
cp "$BUILD_LOG_T" "$LOCAL/build_tinyman.log" 2>/dev/null || true

echo
echo "======================================================================"
echo "FINAL RESULT LOCATION"
echo "======================================================================"
echo "Mac:  $LOCAL"
echo "idex: $FINAL_ROOT"
echo "RUN RC=$RUN_RC"
echo "Performance build used on both endpoints: cache128, RX32, TX16, ring4096, drain2, TX/RX mbuf metadata, single TX owner."
echo "8 GiB payload bytes = 8589934592."
echo "======================================================================"

exit "$RUN_RC"
