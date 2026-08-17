#!/usr/bin/env bash
set -Eeuo pipefail

BRANCH=performance2/p5-multicore
RUNS="${P5_BOTTLENECK_RUNS:-2}"
CONNECTIONS="${P5_BOTTLENECK_CONNECTIONS:-4}"
TAG="${P5_BOTTLENECK_TAG:-$(date +%Y%m%d_%H%M%S)}"
ROOT=/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads
RESULT_ROOT="$ROOT/matrix_results/P5_BOTTLENECK_SWEEP_${CONNECTIONS}c_${RUNS}r_${TAG}"
REMOTE_RUNNER="/tmp/P5_BOTTLENECK_SWEEP_${TAG}.sh"
REMOTE_LOG="/root/P5_BOTTLENECK_SWEEP_${TAG}.remote-live.log"
REMOTE_STATE="/tmp/P5_BOTTLENECK_SWEEP_${TAG}.state"
REMOTE_ARCHIVE="/root/P5_BOTTLENECK_SWEEP_${TAG}.tar.gz"
LOCAL_MAC_LOG="$HOME/Downloads/P5_BOTTLENECK_SWEEP_${TAG}.mac.log"
LOCAL_LIVE_LOG="$HOME/Downloads/P5_BOTTLENECK_SWEEP_${TAG}.remote-live.log"
LOCAL_ARCHIVE="$HOME/Downloads/P5_BOTTLENECK_SWEEP_${TAG}.tar.gz"
LOCAL_EXPORT="$HOME/Downloads/P5_BOTTLENECK_SWEEP_EXPORT_${TAG}"
SSH=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3)

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
retry(){
    local rc
    while true; do
        if "$@"; then return 0; else rc=$?; fi
        if (( rc == 255 )); then
            log "SSH/SCP transport lost; retrying in 5 s"
            sleep 5
        else
            return "$rc"
        fi
    done
}
tiny(){
    local cmd="${1:?missing Tinyman command}" q
    printf -v q '%q' "$cmd"
    retry ssh "${SSH[@]}" idex "ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman $q"
}

[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: P5_BOTTLENECK_RUNS must be positive" >&2; exit 2; }
[[ "$CONNECTIONS" =~ ^[2-9][0-9]*$ ]] || { echo "ERROR: P5_BOTTLENECK_CONNECTIONS must be >=2" >&2; exit 2; }

if [[ "${1:-}" == "--detach" ]]; then
    shift
    nohup caffeinate -dimsu env \
        P5_BOTTLENECK_RUNS="$RUNS" \
        P5_BOTTLENECK_CONNECTIONS="$CONNECTIONS" \
        P5_BOTTLENECK_TAG="$TAG" \
        bash "$0" --foreground >"$LOCAL_MAC_LOG" 2>&1 </dev/null &
    pid=$!
    disown "$pid" 2>/dev/null || true
    echo "STARTED P5 BOTTLENECK SWEEP PID=$pid"
    echo "TAG=$TAG"
    echo "MAC_LOG=$LOCAL_MAC_LOG"
    echo "LIVE_LOG=$LOCAL_LIVE_LOG"
    echo "FINAL_ARCHIVE=$LOCAL_ARCHIVE"
    echo "FINAL_EXPORT=$LOCAL_EXPORT"
    echo "P5 only: 12 controlled OFF-mode cases; P7 is not run. Results + terminal log SCP automatically."
    exit 0
fi
[[ "${1:-}" == "--foreground" ]] && shift || true
[[ $# -eq 0 ]] || { echo "ERROR: unknown arguments: $*" >&2; exit 2; }

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
LOCAL_REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
LOCAL_BRANCH="$(git -C "$LOCAL_REPO" branch --show-current)"
LOCAL_SHA="$(git -C "$LOCAL_REPO" rev-parse HEAD)"
BASE_CLEANER="$HERE/safe_cleanup_greenquic_processes.py"
SWEEP_CLEANER="$HERE/safe_cleanup_p5_bottleneck_processes.py"
[[ "$LOCAL_BRANCH" == "$BRANCH" ]] || { echo "ERROR: local branch=$LOCAL_BRANCH expected=$BRANCH" >&2; exit 2; }
[[ -z "$(git -C "$LOCAL_REPO" status --porcelain --untracked-files=no)" ]] || { echo "ERROR: tracked local changes present" >&2; exit 2; }
for f in "$BASE_CLEANER" "$SWEEP_CLEANER"; do [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 2; }; done

# ---------------------------------------------------------------------------
# FIRST REMOTE ACTION: ancestry-safe stale-process cleanup on BOTH endpoints.
# Install the two Python files into one /tmp directory so the sweep-specific
# cleaner can import the base cleaner before repository synchronization.
# ---------------------------------------------------------------------------
REMOTE_CLEAN_DIR="/tmp/p5_bottleneck_cleanup_${TAG}"
log "installing P5 bottleneck safe cleanup on IDEX + Tinyman"
retry ssh "${SSH[@]}" idex "mkdir -p '$REMOTE_CLEAN_DIR'"
tiny "mkdir -p '$REMOTE_CLEAN_DIR'"
retry scp "${SSH[@]}" "$BASE_CLEANER" "$SWEEP_CLEANER" "idex:$REMOTE_CLEAN_DIR/"
retry ssh "${SSH[@]}" idex "scp -q -o BatchMode=yes -o ConnectTimeout=15 '$REMOTE_CLEAN_DIR/'*.py root@tinyman:'$REMOTE_CLEAN_DIR/'"

cleanup_idex(){
    retry ssh "${SSH[@]}" idex "cd '$REMOTE_CLEAN_DIR' && python3 ./safe_cleanup_p5_bottleneck_processes.py"
}
cleanup_tiny(){
    tiny "cd '$REMOTE_CLEAN_DIR' && python3 ./safe_cleanup_p5_bottleneck_processes.py"
}
log "cleaning stale P5/P7/bottleneck processes on IDEX"
cleanup_idex
log "cleaning stale P5/P7/bottleneck processes on Tinyman"
cleanup_tiny
log "SAFE STALE-PROCESS CLEANUP PASS: IDEX + Tinyman"

# ---------------------------------------------------------------------------
# Sync the exact Mac commit to both endpoints via a named-branch Git bundle.
# No server GitHub credentials and no deletion of untracked historical results.
# ---------------------------------------------------------------------------
BUNDLE="$(mktemp "${TMPDIR:-/tmp}/greenquic_bottleneck.XXXXXX.bundle")"
REMOTE_BUNDLE="/tmp/greenquic_bottleneck_${TAG}.bundle"
TMP_REMOTE=""
trap 'rm -f "$BUNDLE" "${TMP_REMOTE:-}"' EXIT
git -C "$LOCAL_REPO" bundle create "$BUNDLE" "$BRANCH"
retry scp "${SSH[@]}" "$BUNDLE" "idex:$REMOTE_BUNDLE"
retry ssh "${SSH[@]}" idex "cd /root/mohsen && git reset --hard && git fetch '$REMOTE_BUNDLE' '$BRANCH' && git checkout -B '$BRANCH' FETCH_HEAD && git reset --hard FETCH_HEAD"
retry ssh "${SSH[@]}" idex "scp -q -o BatchMode=yes -o ConnectTimeout=15 '$REMOTE_BUNDLE' root@tinyman:'$REMOTE_BUNDLE'"
tiny "cd /root/mohsen && git reset --hard && git fetch '$REMOTE_BUNDLE' '$BRANCH' && git checkout -B '$BRANCH' FETCH_HEAD && git reset --hard FETCH_HEAD"
IDEX_SHA="$(retry ssh "${SSH[@]}" idex 'cd /root/mohsen && git rev-parse HEAD')"
TINY_SHA="$(tiny 'cd /root/mohsen && git rev-parse HEAD')"
[[ "$IDEX_SHA" == "$LOCAL_SHA" && "$TINY_SHA" == "$LOCAL_SHA" ]] || {
    echo "ERROR: commit mismatch local=$LOCAL_SHA idex=$IDEX_SHA tinyman=$TINY_SHA" >&2
    exit 2
}
log "Mac + idex + tinyman synced to $BRANCH @ $LOCAL_SHA"

# Static preflight before the detached experiment.
retry ssh "${SSH[@]}" idex "cd '$ROOT' && bash -n ./run_p5_bottleneck_sweep.sh && bash -n ./run_p5_parallel_off_case.sh && python3 -m py_compile ./cpu_busy_sampler.py ./analyze_p5_bottleneck_case.py ./summarize_p5_bottleneck_sweep.py ./safe_cleanup_p5_bottleneck_processes.py && bash ./run_p5_parallel_off_case.sh --help >/dev/null"
log "P5 bottleneck sweep preflight PASS"

# ---------------------------------------------------------------------------
# Detached remote runner. It always attempts to archive whatever was produced.
# ---------------------------------------------------------------------------
TMP_REMOTE="$(mktemp "${TMPDIR:-/tmp}/p5_bottleneck_remote.XXXXXX")"
cat > "$TMP_REMOTE" <<'REMOTE'
#!/usr/bin/env bash
set +e
ROOT="$1"; RESULT_ROOT="$2"; RUNS="$3"; CONNECTIONS="$4"; TAG="$5"; STATE="$6"; ARCHIVE="$7"; LIVELOG="$8"
rm -f "$STATE.DONE" "$STATE.FAIL" "$STATE.RC" "$ARCHIVE"
cd "$ROOT" || { echo 90 > "$STATE.RC"; echo "CD:90" > "$STATE.FAIL"; exit 90; }
P5_BOTTLENECK_RUNS="$RUNS" \
P5_BOTTLENECK_CONNECTIONS="$CONNECTIONS" \
P5_BOTTLENECK_TAG="$TAG" \
P5_BOTTLENECK_OUTPUT_ROOT="$RESULT_ROOT" \
bash ./run_p5_bottleneck_sweep.sh
RC=$?
echo "$RC" > "$STATE.RC"
mkdir -p "$RESULT_ROOT"
cp -f "$LIVELOG" "$RESULT_ROOT/TERMINAL_REMOTE_LIVE.log" 2>/dev/null || true
printf 'sweep_rc=%s\n' "$RC" > "$RESULT_ROOT/SWEEP_REMOTE_STATUS.env"
PARENT="$(dirname "$RESULT_ROOT")"; BASE="$(basename "$RESULT_ROOT")"
tar -C "$PARENT" -czf "$ARCHIVE" "$BASE"
TAR_RC=$?
if [[ $TAR_RC -ne 0 ]]; then echo "TAR:$TAR_RC" > "$STATE.FAIL"; exit "$TAR_RC"; fi
touch "$STATE.DONE"
exit 0
REMOTE
bash -n "$TMP_REMOTE"
retry scp "${SSH[@]}" "$TMP_REMOTE" "idex:$REMOTE_RUNNER"
LAUNCH_OUT="$(retry ssh "${SSH[@]}" idex "rm -f '$REMOTE_LOG'; chmod 0700 '$REMOTE_RUNNER'; nohup setsid bash '$REMOTE_RUNNER' '$ROOT' '$RESULT_ROOT' '$RUNS' '$CONNECTIONS' '$TAG' '$REMOTE_STATE' '$REMOTE_ARCHIVE' '$REMOTE_LOG' >'$REMOTE_LOG' 2>&1 </dev/null & pid=\$!; echo \$pid > '$REMOTE_STATE.PID'; echo REMOTE_PID=\$pid")"
echo "$LAUNCH_OUT"
REMOTE_PID="$(printf '%s\n' "$LAUNCH_OUT" | sed -n 's/^REMOTE_PID=//p' | tail -1)"
[[ "$REMOTE_PID" =~ ^[0-9]+$ ]] || { echo "ERROR: could not parse remote PID" >&2; exit 2; }
log "detached P5 bottleneck sweep started on IDEX"

# Resumable live terminal stream to Mac.
: > "$LOCAL_LIVE_LOG"
while true; do
    if ssh "${SSH[@]}" idex "test -f '$REMOTE_STATE.DONE'" >/dev/null 2>&1; then break; fi
    if ssh "${SSH[@]}" idex "test -f '$REMOTE_STATE.FAIL'" >/dev/null 2>&1; then
        echo "ERROR: remote sweep infrastructure/archive failed" >&2
        ssh "${SSH[@]}" idex "cat '$REMOTE_STATE.FAIL'; tail -240 '$REMOTE_LOG'" >&2 || true
        break
    fi
    LOCAL_LINES="$(wc -l < "$LOCAL_LIVE_LOG" | tr -d '[:space:]')"
    START_LINE=$((LOCAL_LINES + 1))
    log "LIVE P5 BOTTLENECK LOG (resume line $START_LINE)"
    set +e
    ssh "${SSH[@]}" idex "touch '$REMOTE_LOG'; tail -n +$START_LINE -F --pid='$REMOTE_PID' '$REMOTE_LOG'" | tee -a "$LOCAL_LIVE_LOG"
    STREAM_RC=${PIPESTATUS[0]}
    set -e
    if (( STREAM_RC == 255 )); then
        log "live-log SSH lost; detached sweep continues; reconnecting in 5 s"
        sleep 5
    else
        sleep 1
    fi
done

# Capture any final lines after tail exits.
LOCAL_LINES="$(wc -l < "$LOCAL_LIVE_LOG" | tr -d '[:space:]')"
START_LINE=$((LOCAL_LINES + 1))
ssh "${SSH[@]}" idex "sed -n '${START_LINE},\$p' '$REMOTE_LOG'" 2>/dev/null | tee -a "$LOCAL_LIVE_LOG" || true

# ---------------------------------------------------------------------------
# Automatic SCP: full archive, raw terminal log, and small summary files.
# ---------------------------------------------------------------------------
mkdir -p "$LOCAL_EXPORT"
if ssh "${SSH[@]}" idex "test -f '$REMOTE_ARCHIVE'" >/dev/null 2>&1; then
    retry scp "${SSH[@]}" "idex:$REMOTE_ARCHIVE" "$LOCAL_ARCHIVE"
else
    echo "WARN: remote archive missing: $REMOTE_ARCHIVE" >&2
fi
retry scp "${SSH[@]}" "idex:$REMOTE_LOG" "$LOCAL_LIVE_LOG.raw" || true
for name in BOTTLENECK_SWEEP_SUMMARY.txt BOTTLENECK_SWEEP_SUMMARY.csv CASE_STATUS.tsv SWEEP_DESIGN.txt SWEEP_REMOTE_STATUS.env; do
    if ssh "${SSH[@]}" idex "test -f '$RESULT_ROOT/$name'" >/dev/null 2>&1; then
        retry scp "${SSH[@]}" "idex:$RESULT_ROOT/$name" "$LOCAL_EXPORT/$name"
    fi
done
cp -f "$LOCAL_LIVE_LOG" "$LOCAL_EXPORT/TERMINAL_LIVE_MAC_COPY.log" 2>/dev/null || true

log "P5 BOTTLENECK SWEEP DELIVERY COMPLETE"
log "ARCHIVE=$LOCAL_ARCHIVE"
log "LIVE_LOG=$LOCAL_LIVE_LOG"
log "RAW_REMOTE_LOG=$LOCAL_LIVE_LOG.raw"
log "SUMMARY_DIR=$LOCAL_EXPORT"
if [[ -f "$LOCAL_EXPORT/BOTTLENECK_SWEEP_SUMMARY.txt" ]]; then
    echo
    cat "$LOCAL_EXPORT/BOTTLENECK_SWEEP_SUMMARY.txt"
fi
