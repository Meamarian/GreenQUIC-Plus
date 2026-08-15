#!/usr/bin/env bash
set -Eeuo pipefail

BRANCH="performance/p5-max-goodput"
P5_RUNS="${P5_FINAL_RUNS:-6}"
P5_DOWNLOADS="${P5_FINAL_DOWNLOADS:-5}"
P7_RUNS="${P7_FINAL_RUNS:-6}"
P7_DOWNLOADS="${P7_FINAL_DOWNLOADS:-5}"
SEED="${P5_FINAL_SEED:-20260806}"

[[ "$P5_RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: P5_FINAL_RUNS must be positive" >&2; exit 2; }
[[ "$P5_DOWNLOADS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: P5_FINAL_DOWNLOADS must be positive" >&2; exit 2; }
[[ "$P7_RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: P7_FINAL_RUNS must be positive" >&2; exit 2; }
[[ "$P7_DOWNLOADS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: P7_FINAL_DOWNLOADS must be positive" >&2; exit 2; }

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$HERE/../../../.." && pwd)"
P5="/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
P7="/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline"
TAG="$(date +%Y%m%d_%H%M%S)"
BUNDLE="/tmp/GreenQUIC_FINAL_P5_P7_${TAG}.bundle"
REMOTE_BUNDLE="/tmp/GreenQUIC_FINAL_P5_P7_${TAG}.bundle"
EXPORT_REMOTE="/tmp/P5_P7_FINAL_EXPORT_${TAG}"
EXPORT_LOCAL="$HOME/Downloads/P5_P7_FINAL_EXPORT_${TAG}"
P5_MON="$P5/matrix_results/idle_monitor_normal_${TAG}"
P5_PWR="$P5/matrix_results/main_power_friendly_${TAG}"
P5_SHORT="$P5/matrix_results/main_normal_short_8GiB_${TAG}"
P7_OUT="$P7/matrix_results/P7_MAIN_linux_6runs_${TAG}"
P7_LOG="/root/P7_MAIN_${TAG}.log"
BUILD_LOG_I="/tmp/P5_FINAL_BUILD_IDEX_${TAG}.log"
BUILD_LOG_T="/tmp/P5_FINAL_BUILD_TINYMAN_${TAG}.log"

PERF_ENV="P5_BUILD_REUSE=1 P5_SUPER_CACHE=128 P5_SUPER_RX_BURST=32 P5_SUPER_TX_BURST=16 P5_SUPER_RING_SIZE=4096 P5_SUPER_RING_SYNC=legacy P5_SUPER_DRAIN_BURSTS=2 P5_SUPER_DRAIN_THRESHOLD=0 P5_SUPER_MTU=0 P5_SUPER_SKIP_OFF_RINGCOUNT=0 P5_SUPER_DEBUG_COUNTERS=1 P5_SUPER_TRANSFER_WINDOW=1 P5_SUPER_TRACE_RINGCOUNT=1 P5_SUPER_TX_META=mbuf P5_SUPER_RX_META=mbuf P5_SUPER_TX_LOCK_MODE=single_owner P5_SUPER_CAP_DIAG=1"

cd "$REPO_ROOT"
trap 'rm -f "$BUNDLE"' EXIT

printf '%s\n' \
    "======================================================================" \
    "FINAL P5 + P7 SUITE" \
    "P5: 3 profiles, runs=$P5_RUNS, downloads=$P5_DOWNLOADS" \
    "P7: runs=$P7_RUNS, downloads=$P7_DOWNLOADS" \
    "P5 performance: cache128 RX32 TX16 ring4096 drain2 TX/RX mbuf metadata single TX-owner" \
    "All zipping and SCP happen only after all four tests have been attempted." \
    "======================================================================"

if [ -n "$(git status --porcelain)" ]; then
    echo "Saving Mac working-tree changes..."
    git stash push -u -m "pre-final-p5-p7-${TAG}"
fi

git fetch origin main "$BRANCH"
EXPECTED="$(git rev-parse "origin/$BRANCH")"
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git checkout "$BRANCH"
else
    git checkout -b "$BRANCH" "origin/$BRANCH"
fi
git reset --hard "origin/$BRANCH"
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

ssh idex "cd '$P5' && bash -n ./build_p5_super_performance.sh && python3 -m py_compile ./apply_p5_super_performance.py ./apply_p5_super_packet_counter_guard.py && command -v zip >/dev/null && test -x /root/run_p7.sh && echo 'IDEX FINAL PREFLIGHT PASS'"
ssh idex "ssh root@tinyman \"cd '$P5' && bash -n ./build_p5_super_performance.sh && python3 -m py_compile ./apply_p5_super_performance.py ./apply_p5_super_packet_counter_guard.py && echo 'TINYMAN FINAL PREFLIGHT PASS'\""

echo "======================================================================"
echo "BUILDING FINAL P5 PERFORMANCE DATAPATH ON BOTH HOSTS"
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
    echo "ERROR: P5 performance build failed: idex=$BRC_I tinyman=$BRC_T"
    tail -120 "$BUILD_LOG_I" || true
    tail -120 "$BUILD_LOG_T" || true
    exit 50
fi

echo "======================================================================"
echo "RUNNING ALL TESTS; EXPORT IS DELAYED UNTIL THE END"
echo "======================================================================"

set +e
ssh idex "P5='$P5' P7='$P7' P5_MON='$P5_MON' P5_PWR='$P5_PWR' P5_SHORT='$P5_SHORT' P7_OUT='$P7_OUT' P7_LOG='$P7_LOG' P5_RUNS='$P5_RUNS' P5_DOWNLOADS='$P5_DOWNLOADS' P7_RUNS='$P7_RUNS' P7_DOWNLOADS='$P7_DOWNLOADS' SEED='$SEED' bash -s" <<'REMOTE'
set -u

run_p5() {
    local output="$1"
    shift
    cd "$P5" || return 90
    bash ./run_matrix_with_sheet.sh \
        --chart-style both \
        --client-host tinyman \
        --client-dir "$P5" \
        --client-bin /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop \
        --downloads "$P5_DOWNLOADS" \
        --gap-seconds 5 \
        --server-cooldown-seconds 5 \
        --between-tests-seconds 0 \
        --cstate-cpu 19 \
        --runs "$P5_RUNS" \
        --mode-order balanced \
        --seed "$SEED" \
        --output-dir "$output" \
        --env ENABLE_RECORD=1 \
        --env GQ_LOG_LEVEL=0 \
        "$@"
}

echo "=== 1/4 P5 IDLE_MONITOR_NORMAL ==="
run_p5 "$P5_MON" \
    --env GQ_IDLE_MODE_OVERRIDE=monitor \
    --env GQ_IDLE_FALLBACK_OVERRIDE=short
RC1=$?
echo "P5 IDLE_MONITOR_NORMAL RC=$RC1"

echo "=== 2/4 P5 POWER_FRIENDLY ==="
run_p5 "$P5_PWR" \
    --env ENABLE_FREQ=1 \
    --env ENABLE_SLEEP=1 \
    --env GQ_IDLE_MODE_OVERRIDE=epoll \
    --env GQ_IDLE_FALLBACK_OVERRIDE=short
RC2=$?
echo "P5 POWER_FRIENDLY RC=$RC2"

echo "=== 3/4 P5 NORMAL_SHORT_8GiB ==="
run_p5 "$P5_SHORT" \
    --env GQ_IDLE_MODE_OVERRIDE=short \
    --env GQ_IDLE_FALLBACK_OVERRIDE=short \
    --env REQUEST_PATH=/file_8G.bin \
    --env PAYLOAD_BYTES=8589934592
RC3=$?
echo "P5 NORMAL_SHORT_8GiB RC=$RC3"

echo "=== 4/4 P7 LINUX UDP BASELINE ==="
RUN_TAG="${P7_OUT##*_6runs_}"
/root/run_p7.sh \
    --chart-style both \
    --log-level 0 \
    --downloads "$P7_DOWNLOADS" \
    --gap-seconds 5 \
    --runs "$P7_RUNS" \
    --pre-cooldown-seconds 5 \
    --post-cooldown-seconds 5 \
    --between-runs-seconds 5 \
    --dataplane-cpu 19 \
    --quic-cpus 21,22,23,24 \
    --pin-irq 1 \
    --pin-quic 1 \
    --disable-rps 1 \
    --nic-offloads native \
    --record-quic-cpus 0 \
    --enable-record 1 \
    --rapl-interval-ms 6 \
    --freq-interval-ms 1 \
    --require-rapl 1 \
    --stop-irqbalance 1 \
    --mtu 1500 \
    --output-dir "$P7_OUT" \
    2>&1 | tee "$P7_LOG"
RC4=${PIPESTATUS[0]}
echo "P7 LINUX RC=$RC4"

echo "TEST_RC P5_MONITOR=$RC1 P5_POWER=$RC2 P5_SHORT=$RC3 P7_LINUX=$RC4"
printf '%s %s %s %s\n' "$RC1" "$RC2" "$RC3" "$RC4" > "/tmp/P5_P7_FINAL_RC_${RUN_TAG}.txt"
exit 0
REMOTE
REMOTE_SUITE_RC=$?
set -e

echo "======================================================================"
echo "ALL TEST ATTEMPTS FINISHED; NOW ZIP EXACT RESULT FOLDERS"
echo "======================================================================"

ssh idex "P5_MON='$P5_MON' P5_PWR='$P5_PWR' P5_SHORT='$P5_SHORT' P7_OUT='$P7_OUT' P7_LOG='$P7_LOG' EXPORT_REMOTE='$EXPORT_REMOTE' TAG='$TAG' bash -s" <<'REMOTE'
set -euo pipefail
mkdir -p "$EXPORT_REMOTE"
zip_folder() {
    local src="$1" name="$2"
    if [ ! -d "$src" ]; then
        echo "WARNING: missing result folder: $src"
        return 0
    fi
    local parent base
    parent="$(dirname "$src")"
    base="$(basename "$src")"
    (cd "$parent" && zip -qr "$EXPORT_REMOTE/${name}.zip" "$base")
    echo "CREATED $EXPORT_REMOTE/${name}.zip"
}
zip_folder "$P5_MON" "$(basename "$P5_MON")"
zip_folder "$P5_PWR" "$(basename "$P5_PWR")"
zip_folder "$P5_SHORT" "$(basename "$P5_SHORT")"
if [ -d "$P7_OUT" ]; then
    P7ZIP="$EXPORT_REMOTE/$(basename "$P7_OUT").zip"
    (cd "$(dirname "$P7_OUT")" && zip -qr "$P7ZIP" "$(basename "$P7_OUT")")
    if [ -f "$P7_LOG" ]; then
        zip -qj "$P7ZIP" "$P7_LOG"
    fi
    echo "CREATED $P7ZIP"
else
    echo "WARNING: missing P7 result folder: $P7_OUT"
fi
printf '%s\n' "$P5_MON" "$P5_PWR" "$P5_SHORT" "$P7_OUT" > "$EXPORT_REMOTE/source_paths.txt"
ls -lh "$EXPORT_REMOTE"
REMOTE

echo "======================================================================"
echo "SCP ALL ZIP FILES TO MAC DOWNLOADS"
echo "======================================================================"
mkdir -p "$EXPORT_LOCAL"
scp "idex:${EXPORT_REMOTE}/"*.zip "$EXPORT_LOCAL/" || true
scp "idex:${EXPORT_REMOTE}/source_paths.txt" "$EXPORT_LOCAL/" || true
cp "$BUILD_LOG_I" "$EXPORT_LOCAL/build_idex.log" 2>/dev/null || true
cp "$BUILD_LOG_T" "$EXPORT_LOCAL/build_tinyman.log" 2>/dev/null || true

echo "======================================================================"
echo "DONE"
echo "Mac export: $EXPORT_LOCAL"
echo "P5 monitor: $P5_MON"
echo "P5 power:   $P5_PWR"
echo "P5 short:   $P5_SHORT"
echo "P7 Linux:   $P7_OUT"
echo "Remote suite wrapper RC=$REMOTE_SUITE_RC"
echo "8 GiB PAYLOAD_BYTES=8589934592"
echo "======================================================================"
