#!/usr/bin/env bash
set -Eeuo pipefail

BRANCH=performance2/p5-multicore
RUNS="${P5_BOTTLENECK_RUNS:-2}"
CONNECTIONS="${P5_BOTTLENECK_CONNECTIONS:-4}"
TAG="${P5_BOTTLENECK_TAG:-$(date +%Y%m%d_%H%M%S)}"
P5=/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads
RESULT_ROOT="$P5/matrix_results/P5_BOTTLENECK_SWEEP_V2_${CONNECTIONS}c_${RUNS}r_${TAG}"
REMOTE_RUNNER="/tmp/P5_BOTTLENECK_${TAG}.sh"
REMOTE_LOG="/root/P5_BOTTLENECK_${TAG}.log"
REMOTE_STATE="/tmp/P5_BOTTLENECK_${TAG}.state"
REMOTE_FULL="/root/P5_BOTTLENECK_FULL_${TAG}.tar.gz"
REMOTE_SHARE="/root/P5_BOTTLENECK_SHARE_${TAG}.tar.gz"
LOCAL_MAC_LOG="$HOME/Downloads/P5_BOTTLENECK_${TAG}.mac.log"
LOCAL_LIVE="$HOME/Downloads/P5_BOTTLENECK_${TAG}.remote-live.log"
LOCAL_TERMINAL="$HOME/Downloads/P5_BOTTLENECK_${TAG}.terminal.log"
LOCAL_FULL="$HOME/Downloads/P5_BOTTLENECK_FULL_${TAG}.tar.gz"
LOCAL_SHARE="$HOME/Downloads/P5_BOTTLENECK_SHARE_${TAG}.tar.gz"
LOCAL_EXPORT="$HOME/Downloads/P5_BOTTLENECK_EXPORT_${TAG}"
SSH=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3)

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

retry() {
    local rc
    while true; do
        if "$@"; then
            return 0
        else
            rc=$?
        fi
        if (( rc == 255 )); then
            log 'SSH/SCP lost; retrying in 5 s'
            sleep 5
        else
            return "$rc"
        fi
    done
}

tiny() {
    local command="$1" quoted
    printf -v quoted '%q' "$command"
    retry ssh "${SSH[@]}" idex \
        "ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman $quoted"
}

[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo 'ERROR: invalid runs' >&2; exit 2; }
[[ "$CONNECTIONS" =~ ^[2-9][0-9]*$ ]] || { echo 'ERROR: connections must be >=2' >&2; exit 2; }

if [[ "${1:-}" == --detach ]]; then
    shift
    nohup caffeinate -dimsu env \
        P5_BOTTLENECK_RUNS="$RUNS" \
        P5_BOTTLENECK_CONNECTIONS="$CONNECTIONS" \
        P5_BOTTLENECK_TAG="$TAG" \
        bash "$0" --foreground >"$LOCAL_MAC_LOG" 2>&1 </dev/null &
    pid=$!
    disown "$pid" 2>/dev/null || true
    echo "STARTED P5 BOTTLENECK SWEEP V2 PID=$pid"
    echo "TAG=$TAG"
    echo "MAC_LOG=$LOCAL_MAC_LOG"
    echo "REMOTE_LIVE_LOG=$LOCAL_LIVE"
    echo "FINAL_TERMINAL_LOG=$LOCAL_TERMINAL"
    echo "FULL_RESULTS=$LOCAL_FULL"
    echo "SHARE_RESULTS=$LOCAL_SHARE"
    echo "16 controlled P5/OFF cases (A-P); failures are preserved and later cases continue."
    exit 0
fi

[[ "${1:-}" == --foreground ]] && shift || true
[[ $# -eq 0 ]] || { echo "ERROR: unknown args $*" >&2; exit 2; }

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
SHA="$(git -C "$REPO" rev-parse HEAD)"
CURRENT_BRANCH="$(git -C "$REPO" branch --show-current)"
[[ "$CURRENT_BRANCH" == "$BRANCH" ]] || {
    echo "ERROR: branch=$CURRENT_BRANCH expected=$BRANCH" >&2
    exit 2
}
[[ -z "$(git -C "$REPO" status --porcelain --untracked-files=no)" ]] || {
    echo 'ERROR: tracked local changes present' >&2
    exit 2
}

BASE_CLEAN="$HERE/safe_cleanup_greenquic_processes.py"
BN_CLEAN="$HERE/safe_cleanup_p5_bottleneck_processes.py"
[[ -f "$BASE_CLEAN" && -f "$BN_CLEAN" ]] || {
    echo 'ERROR: cleanup helpers missing' >&2
    exit 2
}

# FIRST REMOTE ACTION: install the ancestry-safe cleaner and clean both endpoints.
REMOTE_CLEAN_DIR="/tmp/gq_bn_clean_${TAG}"
log 'installing safe bottleneck cleaner on IDEX + Tinyman'
retry ssh "${SSH[@]}" idex "mkdir -p '$REMOTE_CLEAN_DIR'"
retry scp "${SSH[@]}" "$BASE_CLEAN" "$BN_CLEAN" "idex:$REMOTE_CLEAN_DIR/"
retry ssh "${SSH[@]}" idex \
    "ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman 'mkdir -p $REMOTE_CLEAN_DIR'; scp -q -o BatchMode=yes -o ConnectTimeout=15 '$REMOTE_CLEAN_DIR/'*.py root@tinyman:'$REMOTE_CLEAN_DIR/'"

clean_idex() {
    local marker="/tmp/gqbn_${TAG}_idex.done"
    local logfile="/tmp/gqbn_${TAG}_idex.log"
    retry ssh "${SSH[@]}" idex \
        "rm -f '$marker' '$logfile'; nohup setsid python3 '$REMOTE_CLEAN_DIR/safe_cleanup_p5_bottleneck_processes.py' --marker '$marker' >'$logfile' 2>&1 </dev/null & echo CLEAN_PID=\$!"
    while ! ssh "${SSH[@]}" idex "test -f '$marker'" >/dev/null 2>&1; do
        sleep 1
    done
    retry ssh "${SSH[@]}" idex \
        "cat '$logfile'; test \"\$(cat '$marker')\" = PASS; cd '$REMOTE_CLEAN_DIR' && python3 ./safe_cleanup_p5_bottleneck_processes.py --check"
}

clean_tinyman() {
    local marker="/tmp/gqbn_${TAG}_tiny.done"
    local logfile="/tmp/gqbn_${TAG}_tiny.log"
    tiny "rm -f '$marker' '$logfile'; nohup setsid python3 '$REMOTE_CLEAN_DIR/safe_cleanup_p5_bottleneck_processes.py' --marker '$marker' >'$logfile' 2>&1 </dev/null & echo CLEAN_PID=\$!"
    while ! tiny "test -f '$marker'" >/dev/null 2>&1; do
        sleep 1
    done
    tiny "cat '$logfile'; test \"\$(cat '$marker')\" = PASS; cd '$REMOTE_CLEAN_DIR' && python3 ./safe_cleanup_p5_bottleneck_processes.py --check"
}

log 'cleaning IDEX'
clean_idex
log 'cleaning Tinyman'
clean_tinyman
log 'SAFE CLEANUP PASS: IDEX + Tinyman'

# Exact Mac commit -> IDEX -> Tinyman via bundle. No GitHub credentials needed remotely.
BUNDLE="$(mktemp "${TMPDIR:-/tmp}/gq_bn.XXXXXX.bundle")"
REMOTE_BUNDLE="/tmp/gq_bn_${TAG}.bundle"
TMP_REMOTE=''
trap 'rm -f "$BUNDLE" "${TMP_REMOTE:-}"' EXIT

git -C "$REPO" bundle create "$BUNDLE" "$BRANCH"
retry scp "${SSH[@]}" "$BUNDLE" "idex:$REMOTE_BUNDLE"
retry ssh "${SSH[@]}" idex \
    "cd /root/mohsen && git reset --hard && git fetch '$REMOTE_BUNDLE' '$BRANCH' && git checkout -B '$BRANCH' FETCH_HEAD && git reset --hard FETCH_HEAD"
retry ssh "${SSH[@]}" idex \
    "scp -q -o BatchMode=yes -o ConnectTimeout=15 '$REMOTE_BUNDLE' root@tinyman:'$REMOTE_BUNDLE'"
tiny "cd /root/mohsen && git reset --hard && git fetch '$REMOTE_BUNDLE' '$BRANCH' && git checkout -B '$BRANCH' FETCH_HEAD && git reset --hard FETCH_HEAD"

IDEX_SHA="$(retry ssh "${SSH[@]}" idex 'cd /root/mohsen && git rev-parse HEAD')"
TINY_SHA="$(tiny 'cd /root/mohsen && git rev-parse HEAD')"
[[ "$IDEX_SHA" == "$SHA" && "$TINY_SHA" == "$SHA" ]] || {
    echo "ERROR SHA local=$SHA idex=$IDEX_SHA tinyman=$TINY_SHA" >&2
    exit 2
}
log "synced all hosts @ $SHA"

# Traffic-free preflight and exact 16-case contract.
retry ssh "${SSH[@]}" idex \
    "cd '$P5' && bash -n ./run_p5_bottleneck_sweep_v2.sh && bash -n ./run_p5_bottleneck_case_diag.sh && bash -n ./run_p5_parallel_off_case.sh && bash -n ./build_p5_bottleneck_profile.sh && python3 -m py_compile ./summarize_p5_bottleneck_sweep_v2.py ./analyze_p5_bottleneck_case.py ./cpu_busy_sampler.py ./quic_cpu_activity_sampler.py ./apply_p5_bottleneck_txq.py"
CASE_COUNT="$(retry ssh "${SSH[@]}" idex "cd '$P5' && grep -Ec '^run_case [A-P]_' ./run_p5_bottleneck_sweep_v2.sh")"
EXTRA_COUNT="$(retry ssh "${SSH[@]}" idex "cd '$P5' && grep -Ec '^run_case [Q-T]_' ./run_p5_bottleneck_sweep_v2.sh || true")"
[[ "$CASE_COUNT" == 16 && "$EXTRA_COUNT" == 0 ]] || {
    echo "ERROR: sweep contract expected 16 A-P cases and no Q-T cases; got cases=$CASE_COUNT extras=$EXTRA_COUNT" >&2
    exit 2
}
log 'P5 bottleneck static preflight PASS: exactly 16 A-P cases'

TMP_REMOTE="$(mktemp "${TMPDIR:-/tmp}/gq_bn_remote.XXXXXX.sh")"
cat > "$TMP_REMOTE" <<'REMOTE'
#!/usr/bin/env bash
set +e
P5="$1"
RUNS="$2"
CONNS="$3"
TAG="$4"
OUT="$5"
STATE="$6"
FULL="$7"
SHARE="$8"
rm -f "$STATE.DONE" "$STATE.RC" "$FULL" "$SHARE"
echo "P5 BOTTLENECK REMOTE START tag=$TAG runs=$RUNS connections=$CONNS commit=$(git -C /root/mohsen rev-parse HEAD 2>/dev/null)"
cd "$P5" || { echo 98 > "$STATE.RC"; touch "$STATE.DONE"; exit 0; }
env \
    P5_BOTTLENECK_RUNS="$RUNS" \
    P5_BOTTLENECK_CONNECTIONS="$CONNS" \
    P5_BOTTLENECK_TAG="$TAG" \
    P5_BOTTLENECK_OUTPUT_ROOT="$OUT" \
    bash ./run_p5_bottleneck_sweep_v2.sh
RC=$?
echo "$RC" > "$STATE.RC"
echo "P5 BOTTLENECK SWEEP PROCESS RC=$RC"
if [[ -d "$OUT" ]]; then
    echo "Packaging full result archive..."
    tar -C "$(dirname "$OUT")" -czf "$FULL" "$(basename "$OUT")"
    echo "FULL_ARCHIVE_RC=$? path=$FULL"
    echo "Packaging share result archive (raw unified runs excluded)..."
    tar -C "$(dirname "$OUT")" --exclude='*/runs/*' -czf "$SHARE" "$(basename "$OUT")"
    echo "SHARE_ARCHIVE_RC=$? path=$SHARE"
else
    echo "WARN result root missing: $OUT"
fi
touch "$STATE.DONE"
echo "P5 BOTTLENECK REMOTE COMPLETE"
exit 0
REMOTE

bash -n "$TMP_REMOTE"
retry scp "${SSH[@]}" "$TMP_REMOTE" "idex:$REMOTE_RUNNER"
LAUNCH_OUT="$(retry ssh "${SSH[@]}" idex \
    "chmod 0700 '$REMOTE_RUNNER'; nohup setsid bash '$REMOTE_RUNNER' '$P5' '$RUNS' '$CONNECTIONS' '$TAG' '$RESULT_ROOT' '$REMOTE_STATE' '$REMOTE_FULL' '$REMOTE_SHARE' >'$REMOTE_LOG' 2>&1 </dev/null & pid=\$!; echo \$pid >'$REMOTE_STATE.PID'; echo REMOTE_PID=\$pid")"
echo "$LAUNCH_OUT"
REMOTE_PID="$(printf '%s\n' "$LAUNCH_OUT" | sed -n 's/^REMOTE_PID=//p' | tail -1)"
[[ "$REMOTE_PID" =~ ^[0-9]+$ ]] || { echo 'ERROR: cannot parse remote PID' >&2; exit 2; }
log "remote 16-case sweep detached PID=$REMOTE_PID"

: > "$LOCAL_LIVE"
while true; do
    if ssh "${SSH[@]}" idex "test -f '$REMOTE_STATE.DONE'" >/dev/null 2>&1; then
        break
    fi
    LOCAL_LINES="$(wc -l < "$LOCAL_LIVE" | tr -d '[:space:]')"
    START_LINE=$((LOCAL_LINES + 1))
    log "LIVE REMOTE LOG resume=$START_LINE"
    set +e
    ssh "${SSH[@]}" idex \
        "touch '$REMOTE_LOG'; tail -n +$START_LINE -F --pid='$REMOTE_PID' '$REMOTE_LOG'" | tee -a "$LOCAL_LIVE"
    STREAM_RC=${PIPESTATUS[0]}
    set -e
    if (( STREAM_RC == 255 )); then
        log 'live SSH lost; remote continues; reconnecting'
        sleep 5
    else
        sleep 1
    fi
done

LOCAL_LINES="$(wc -l < "$LOCAL_LIVE" | tr -d '[:space:]')"
START_LINE=$((LOCAL_LINES + 1))
ssh "${SSH[@]}" idex "sed -n '${START_LINE},\$p' '$REMOTE_LOG'" 2>/dev/null | tee -a "$LOCAL_LIVE" || true

mkdir -p "$LOCAL_EXPORT"
retry scp "${SSH[@]}" "idex:$REMOTE_LOG" "$LOCAL_TERMINAL"
if ssh "${SSH[@]}" idex "test -f '$REMOTE_SHARE'" >/dev/null 2>&1; then
    retry scp "${SSH[@]}" "idex:$REMOTE_SHARE" "$LOCAL_SHARE"
fi
if ssh "${SSH[@]}" idex "test -f '$REMOTE_FULL'" >/dev/null 2>&1; then
    retry scp "${SSH[@]}" "idex:$REMOTE_FULL" "$LOCAL_FULL"
fi
for file in BOTTLENECK_SWEEP_SUMMARY.txt BOTTLENECK_SWEEP_SUMMARY.csv CASE_STATUS.tsv SWEEP_DESIGN.txt; do
    if ssh "${SSH[@]}" idex "test -f '$RESULT_ROOT/$file'" >/dev/null 2>&1; then
        retry scp "${SSH[@]}" "idex:$RESULT_ROOT/$file" "$LOCAL_EXPORT/$file"
    fi
done
if ssh "${SSH[@]}" idex "test -f '$REMOTE_STATE.RC'" >/dev/null 2>&1; then
    retry scp "${SSH[@]}" "idex:$REMOTE_STATE.RC" "$LOCAL_EXPORT/sweep_process_rc.txt"
fi

log 'AUTO-SCP COMPLETE'
echo "TERMINAL_LOG=$LOCAL_TERMINAL"
echo "LIVE_LOG=$LOCAL_LIVE"
echo "SHARE_ARCHIVE=$LOCAL_SHARE"
echo "FULL_ARCHIVE=$LOCAL_FULL"
echo "SUMMARY_DIR=$LOCAL_EXPORT"
[[ -f "$LOCAL_EXPORT/BOTTLENECK_SWEEP_SUMMARY.txt" ]] && cat "$LOCAL_EXPORT/BOTTLENECK_SWEEP_SUMMARY.txt" || true
