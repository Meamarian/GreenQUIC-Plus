#!/usr/bin/env bash
set -Eeuo pipefail

BRANCH=performance2/p5-multicore
RUNS="${P5_BOTTLENECK_RUNS:-2}"
CONNECTIONS="${P5_BOTTLENECK_CONNECTIONS:-4}"
TAG="${P5_BOTTLENECK_TAG:-$(date +%Y%m%d_%H%M%S)}"
P5=/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads
MATRIX="$P5/matrix_results/P5_BOTTLENECK_SWEEP_${CONNECTIONS}c_${RUNS}r_${TAG}"
REMOTE_RUNNER="/tmp/P5_BOTTLENECK_${TAG}.sh"
REMOTE_LOG="/root/P5_BOTTLENECK_${TAG}.log"
REMOTE_STATE="/tmp/P5_BOTTLENECK_${TAG}.state"
REMOTE_ARCHIVE="/root/P5_BOTTLENECK_EXPORT_${TAG}.tar.gz"
LOCAL_MAC_LOG="$HOME/Downloads/P5_BOTTLENECK_${TAG}.mac.log"
LOCAL_LIVE_LOG="$HOME/Downloads/P5_BOTTLENECK_${TAG}.remote-live.log"
LOCAL_ARCHIVE="$HOME/Downloads/P5_BOTTLENECK_EXPORT_${TAG}.tar.gz"
LOCAL_EXPORT="$HOME/Downloads/P5_BOTTLENECK_EXPORT_${TAG}"
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
  echo "STARTED P5 BOTTLENECK SWEEP V2 PID=$pid"
  echo "TAG=$TAG"
  echo "MAC_LOG=$LOCAL_MAC_LOG"
  echo "LIVE_REMOTE_LOG=$LOCAL_LIVE_LOG"
  echo "FINAL_ARCHIVE=$LOCAL_ARCHIVE"
  echo "FINAL_EXPORT=$LOCAL_EXPORT"
  echo "P5 only: 16 controlled OFF-mode cases, identical ${CONNECTIONS}x8GiB workload."
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

# FIRST REMOTE ACTION: safe stale-process cleanup on IDEX and Tinyman.
REMOTE_CLEAN_DIR="/tmp/p5_bottleneck_cleanup_${TAG}"
log "installing cleanup helper on IDEX + Tinyman"
retry ssh "${SSH[@]}" idex "mkdir -p '$REMOTE_CLEAN_DIR'"
tiny "mkdir -p '$REMOTE_CLEAN_DIR'"
retry scp "${SSH[@]}" "$BASE_CLEANER" "$SWEEP_CLEANER" "idex:$REMOTE_CLEAN_DIR/"
retry ssh "${SSH[@]}" idex "scp -q -o BatchMode=yes -o ConnectTimeout=15 '$REMOTE_CLEAN_DIR/safe_cleanup_greenquic_processes.py' '$REMOTE_CLEAN_DIR/safe_cleanup_p5_bottleneck_processes.py' root@tinyman:'$REMOTE_CLEAN_DIR/'"
log "cleaning stale P5/P7/bottleneck processes on IDEX"
retry ssh "${SSH[@]}" idex "cd '$REMOTE_CLEAN_DIR' && python3 ./safe_cleanup_p5_bottleneck_processes.py || true"
log "cleaning stale P5/P7/bottleneck processes on Tinyman"
tiny "cd '$REMOTE_CLEAN_DIR' && python3 ./safe_cleanup_p5_bottleneck_processes.py || true"
log "initial stale-process cleanup complete"

# Exact Mac commit -> IDEX -> Tinyman using a named branch bundle. No git clean.
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
log "Mac + IDEX + Tinyman synced to $BRANCH @ $LOCAL_SHA"

# Traffic-free static preflight.
retry ssh "${SSH[@]}" idex "cd '$P5' && bash -n ./run_p5_bottleneck_sweep.sh"
retry ssh "${SSH[@]}" idex "cd '$P5' && bash -n ./run_p5_parallel_off_case.sh"
retry ssh "${SSH[@]}" idex "cd '$P5' && bash -n ./build_p5_bottleneck_profile.sh"
retry ssh "${SSH[@]}" idex "cd '$P5' && python3 -m py_compile ./apply_p5_bottleneck_txq.py ./cpu_busy_sampler.py ./analyze_p5_bottleneck_case.py ./summarize_p5_bottleneck_sweep.py ./safe_cleanup_p5_bottleneck_processes.py"
retry ssh "${SSH[@]}" idex "cd '$P5' && bash ./run_p5_parallel_off_case.sh --help >/dev/null"
log "P5 bottleneck sweep preflight PASS"

# Detached remote experiment. Individual case/build failures are recorded and
# the sweep continues; packaging still happens at the end.
TMP_REMOTE="$(mktemp "${TMPDIR:-/tmp}/p5_bottleneck_remote.XXXXXX")"
cat > "$TMP_REMOTE" <<'REMOTE'
#!/usr/bin/env bash
set +e
P5="$1"; MATRIX="$2"; RUNS="$3"; CONNECTIONS="$4"; TAG="$5"; STATE="$6"; ARCHIVE="$7"
rm -f "$STATE.DONE" "$STATE.FAIL" "$STATE.RC" "$ARCHIVE"
mkdir -p "$MATRIX"
cd "$P5" || { echo "cannot cd to $P5" > "$STATE.FAIL"; exit 90; }
echo "======================================================================"
echo "P5 BOTTLENECK ISOLATION SWEEP: START"
echo "runs=$RUNS connections=$CONNECTIONS payload=8GiB/connection mode=OFF"
echo "matrix=$MATRIX"
echo "======================================================================"
P5_BOTTLENECK_RUNS="$RUNS" \
P5_BOTTLENECK_CONNECTIONS="$CONNECTIONS" \
P5_BOTTLENECK_TAG="$TAG" \
P5_BOTTLENECK_OUTPUT_ROOT="$MATRIX" \
bash ./run_p5_bottleneck_sweep.sh
RC=$?
printf '%s\n' "$RC" > "$STATE.RC"
printf 'remote_sweep_rc=%s\n' "$RC" > "$MATRIX/SWEEP_REMOTE_STATUS.env"
echo "======================================================================"
echo "P5 BOTTLENECK ISOLATION SWEEP: FINISHED rc=$RC"
echo "Packaging every produced case directory."
echo "======================================================================"
tar -C "$(dirname "$MATRIX")" -czf "$ARCHIVE" "$(basename "$MATRIX")"
TAR_RC=$?
if (( TAR_RC != 0 )); then
  echo "archive_rc=$TAR_RC sweep_rc=$RC" > "$STATE.FAIL"
  exit "$TAR_RC"
fi
touch "$STATE.DONE"
exit 0
REMOTE
bash -n "$TMP_REMOTE"
retry scp "${SSH[@]}" "$TMP_REMOTE" "idex:$REMOTE_RUNNER"
LAUNCH_OUT="$(retry ssh "${SSH[@]}" idex "rm -f '$REMOTE_LOG'; chmod 0700 '$REMOTE_RUNNER'; nohup setsid bash '$REMOTE_RUNNER' '$P5' '$MATRIX' '$RUNS' '$CONNECTIONS' '$TAG' '$REMOTE_STATE' '$REMOTE_ARCHIVE' >'$REMOTE_LOG' 2>&1 </dev/null & pid=\$!; echo \$pid > '$REMOTE_STATE.PID'; echo REMOTE_PID=\$pid")"
echo "$LAUNCH_OUT"
REMOTE_PID="$(printf '%s\n' "$LAUNCH_OUT" | sed -n 's/^REMOTE_PID=//p' | tail -1)"
[[ "$REMOTE_PID" =~ ^[0-9]+$ ]] || { echo "ERROR: cannot parse remote PID" >&2; exit 2; }
log "detached P5 bottleneck sweep started on IDEX pid=$REMOTE_PID"

# Live terminal log with reconnect/resume.
: > "$LOCAL_LIVE_LOG"
while true; do
  if ssh "${SSH[@]}" idex "test -f '$REMOTE_STATE.DONE'" >/dev/null 2>&1; then break; fi
  if ssh "${SSH[@]}" idex "test -f '$REMOTE_STATE.FAIL'" >/dev/null 2>&1; then
    log "remote infrastructure/archive state reports FAIL; preserving partial results"
    break
  fi
  LOCAL_LINES="$(wc -l < "$LOCAL_LIVE_LOG" | tr -d '[:space:]')"
  START_LINE=$((LOCAL_LINES + 1))
  log "LIVE P5 BOTTLENECK LOG resume line $START_LINE"
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
  if ! ssh "${SSH[@]}" idex "kill -0 '$REMOTE_PID' 2>/dev/null || test -f '$REMOTE_STATE.DONE' || test -f '$REMOTE_STATE.FAIL'" >/dev/null 2>&1; then
    log "remote PID exited; proceeding to retrieval"
    break
  fi
done

# Automatic SCP. Exact remote log replaces the reconnectable stream copy.
mkdir -p "$LOCAL_EXPORT"
if ssh "${SSH[@]}" idex "test -f '$REMOTE_LOG'" >/dev/null 2>&1; then
  retry scp "${SSH[@]}" "idex:$REMOTE_LOG" "$LOCAL_LIVE_LOG"
fi
if ssh "${SSH[@]}" idex "test -f '$REMOTE_ARCHIVE'" >/dev/null 2>&1; then
  retry scp "${SSH[@]}" "idex:$REMOTE_ARCHIVE" "$LOCAL_ARCHIVE"
else
  echo "WARN: archive missing: $REMOTE_ARCHIVE" >&2
fi
copy_if_exists(){
  local remote="$1" local_path="$2"
  if ssh "${SSH[@]}" idex "test -f '$remote'" >/dev/null 2>&1; then
    retry scp "${SSH[@]}" "idex:$remote" "$local_path"
  fi
}
copy_if_exists "$MATRIX/BOTTLENECK_SWEEP_SUMMARY.txt" "$LOCAL_EXPORT/BOTTLENECK_SWEEP_SUMMARY.txt"
copy_if_exists "$MATRIX/BOTTLENECK_SWEEP_SUMMARY.csv" "$LOCAL_EXPORT/BOTTLENECK_SWEEP_SUMMARY.csv"
copy_if_exists "$MATRIX/CASE_STATUS.tsv" "$LOCAL_EXPORT/CASE_STATUS.tsv"
copy_if_exists "$MATRIX/SWEEP_DESIGN.txt" "$LOCAL_EXPORT/SWEEP_DESIGN.txt"
copy_if_exists "$MATRIX/SWEEP_REMOTE_STATUS.env" "$LOCAL_EXPORT/SWEEP_REMOTE_STATUS.env"
cp -f "$LOCAL_LIVE_LOG" "$LOCAL_EXPORT/TERMINAL_REMOTE_LIVE.log" 2>/dev/null || true

log "P5 BOTTLENECK SWEEP DELIVERY COMPLETE"
echo "ARCHIVE=$LOCAL_ARCHIVE"
echo "TERMINAL_LIVE_LOG=$LOCAL_LIVE_LOG"
echo "SUMMARY_DIR=$LOCAL_EXPORT"
if [[ -f "$LOCAL_EXPORT/BOTTLENECK_SWEEP_SUMMARY.txt" ]]; then
  echo
  cat "$LOCAL_EXPORT/BOTTLENECK_SWEEP_SUMMARY.txt"
fi
