#!/usr/bin/env bash
# Mac-side launcher. This script is intentionally run as a child Bash process;
# failures here must never terminate the user's interactive zsh shell.
set -Eeuo pipefail

BRANCH="performance2/p5-multicore"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_REPO="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

ROOT="/root/mohsen"
P5="$ROOT/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
CLIENT_HOST="tinyman"

TAG="P5_PLUS_SWEEP50_5RUNS_$(date +%Y%m%d_%H%M%S)"
TMPREF="refs/heads/__${TAG}"
BUNDLE="/tmp/${TAG}.bundle"
REMOTE_BUNDLE="/tmp/${TAG}.bundle"

LOG="/root/${TAG}.log"
PID="/root/${TAG}.pid"
DONE="/root/${TAG}.DONE"
FAILED="/root/${TAG}.FAILED"
SUMMARY="/root/${TAG}.summary.txt"
OUT="$P5/matrix_results/$TAG"
REMOTE_HELPER="$P5/run_p5_plus_sweep50_5x5_from_idex.sh"

cleanup_local() {
    git -C "$LOCAL_REPO" update-ref -d "$TMPREF" 2>/dev/null || true
    rm -f -- "$BUNDLE"
}
trap cleanup_local EXIT INT TERM

printf '%s\n' "======================================================================"
printf '%s\n' "P5 PLUS — 50 CONFIG x 5 RUN x 5 DOWNLOAD SWEEP"
printf 'TAG=%s\n' "$TAG"
printf 'LOCAL_REPO=%s\n' "$LOCAL_REPO"
printf '%s\n' "PLUS only | monitor + short fixed | recorders enabled"
printf '%s\n' "======================================================================"

# Clean known GreenQUIC/P5/P7 processes before touching the remote checkout.
for host in idex tinyman; do
    echo "================ CLEANING $host ================"
    ssh "$host" '
        cd /root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads
        python3 ./safe_cleanup_p5_bottleneck_processes.py || true
        python3 ./safe_cleanup_p5_bottleneck_processes.py --check
    '
done

echo "================ MAC: PREPARE EXACT BRANCH ================"
git -C "$LOCAL_REPO" fetch origin "$BRANCH"
SHA="$(git -C "$LOCAL_REPO" rev-parse "origin/$BRANCH")"
echo "SHA=$SHA"

git -C "$LOCAL_REPO" update-ref "$TMPREF" "$SHA"
git -C "$LOCAL_REPO" bundle create "$BUNDLE" "$TMPREF"
git -C "$LOCAL_REPO" bundle verify "$BUNDLE"

for host in idex tinyman; do
    echo "================ SYNC $host ================"
    scp "$BUNDLE" "$host:$REMOTE_BUNDLE"
    ssh "$host" "
        set -e
        cd '$ROOT'
        git reset --hard
        git fetch '$REMOTE_BUNDLE' '$TMPREF'
        git checkout -B '$BRANCH' FETCH_HEAD
        ACTUAL=\$(git rev-parse HEAD)
        echo HEAD=\$ACTUAL
        test \"\$ACTUAL\" = '$SHA'
        rm -f '$REMOTE_BUNDLE'

        cd '$P5'
        python3 ./enable_p5_claim_recording_gate.py ./gq_common_p5.sh
        grep -Fq 'GREENQUIC-P5-CLAIM-RECORDER-AFFINITY-V1' ./gq_common_p5.sh

        test -f ./run_p5_plus_sweep50_5x5_from_idex.sh
        test -f ./p5_plus_sweep50_5x5.py
        test -x '$ROOT/msquic/build-greenquic-p5/bin/Release/quicinterop'
        test -x '$ROOT/msquic/build-greenquic-p5/bin/Release/quicinteropserver'
        grep -aFq -- 'GreenQUIC-P5-SEQUENCE-V2' '$ROOT/msquic/build-greenquic-p5/bin/Release/quicinterop'
        grep -aFq -- 'GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0' '$ROOT/msquic/build-greenquic-p5/bin/Release/quicinterop'
        echo '[preflight] PASS'
    "
done

echo "================ START DETACHED SWEEP ON IDEX ================"
ssh idex "
    set -e
    rm -f '$LOG' '$PID' '$DONE' '$FAILED' '$SUMMARY'
    mkdir -p '$OUT'

    nohup setsid env \
        TAG='$TAG' \
        OUT='$OUT' \
        SUMMARY='$SUMMARY' \
        DONE='$DONE' \
        FAILED='$FAILED' \
        CLIENT_HOST='$CLIENT_HOST' \
        CLIENT_DIR='$P5' \
        bash '$REMOTE_HELPER' \
        >'$LOG' 2>&1 </dev/null &

    echo \$! > '$PID'
    sleep 5
    RUNPID=\$(cat '$PID')

    if kill -0 \"\$RUNPID\" 2>/dev/null; then
        echo 'REMOTE START OK'
        echo REMOTE_PID=\$RUNPID
    else
        echo 'ERROR: remote sweep exited during startup'
        echo '---------------- LOG ----------------'
        cat '$LOG' || true
        exit 1
    fi
"

cat <<EOF
======================================================================
P5 PLUS SWEEP STARTED
SHA=$SHA
TAG=$TAG

50 configurations x 5 runs/config x 5 downloads/run
250 P5 workloads / 1250 downloads

PID=$PID
LOG=$LOG
SUMMARY=$SUMMARY
RESULTS=$OUT

LIVE:
ssh idex 'tail -n +1 -F $LOG'

STATUS / FINAL TABLE:
ssh idex 'if test -f $DONE; then echo DONE; cat $SUMMARY; elif test -f $FAILED; then echo FAILED; cat $FAILED; tail -150 $LOG; else echo RUNNING; tail -50 $LOG; fi'

After REMOTE START OK, the Mac is no longer required. You may close Terminal,
close the laptop lid, or disconnect the Mac.
======================================================================
EOF
