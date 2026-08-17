#!/usr/bin/env bash
set -Eeuo pipefail

BRANCH=performance2/p5-multicore
RUNS="${P5_MC_RUNS:-2}"
CONNECTIONS="${P5_MC_CONNECTIONS:-4}"
TAG="${P5_MC_TAG:-$(date +%Y%m%d_%H%M%S)}"
ROOT=/root/mohsen/greenquic_test_suite_v22/test_cases/pretests
P5="$ROOT/P5_repeated_8GiB_downloads"
P7="$ROOT/P7_linux_udp_baseline"
P5_MATRIX="$P5/matrix_results/P5_PARALLEL_MC_${CONNECTIONS}c_${RUNS}r_${TAG}"
P7_MATRIX="$P7/matrix_results/P7_PARALLEL_MC_${CONNECTIONS}c_${RUNS}r_${TAG}"
REMOTE_RUNNER="/tmp/P5_P7_MC_${TAG}.sh"
REMOTE_LOG="/root/P5_P7_MC_${TAG}.log"
REMOTE_STATE="/tmp/P5_P7_MC_${TAG}.state"
REMOTE_SUMMARY="/tmp/P5_P7_MC_${TAG}_goodput_all_cases.tsv"
LOCAL_LOG="$HOME/Downloads/P5_P7_MC_${TAG}.mac.log"
LOCAL_REMOTE_LOG="$HOME/Downloads/P5_P7_MC_${TAG}.remote-live.log"
LOCAL_EXPORT="$HOME/Downloads/P5_P7_MC_EXPORT_${TAG}"
REMOTE_CLEANER="/tmp/safe_cleanup_greenquic_processes_${TAG}.py"
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

[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: P5_MC_RUNS must be positive" >&2; exit 2; }
[[ "$CONNECTIONS" =~ ^[2-9][0-9]*$ ]] || { echo "ERROR: P5_MC_CONNECTIONS must be >=2" >&2; exit 2; }

if [[ "${1:-}" == "--detach" ]]; then
    shift
    nohup caffeinate -dimsu env \
        P5_MC_RUNS="$RUNS" P5_MC_CONNECTIONS="$CONNECTIONS" P5_MC_TAG="$TAG" \
        bash "$0" --foreground >"$LOCAL_LOG" 2>&1 </dev/null &
    pid=$!
    disown "$pid" 2>/dev/null || true
    echo "STARTED P5+P7 PARALLEL MULTICORE V6 PID=$pid"
    echo "TAG=$TAG"
    echo "MAC_LOG=$LOCAL_LOG"
    echo "REMOTE_LIVE_LOG=$LOCAL_REMOTE_LOG"
    echo "FINAL_EXPORT=$LOCAL_EXPORT"
    echo "V6: safe cleanup first; P5 then mandatory P7; post-run diagnostics never stop the other phase."
    exit 0
fi
[[ "${1:-}" == "--foreground" ]] && shift || true
[[ $# -eq 0 ]] || { echo "ERROR: unknown arguments: $*" >&2; exit 2; }

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
LOCAL_REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
LOCAL_SHA="$(git -C "$LOCAL_REPO" rev-parse HEAD)"
LOCAL_BRANCH="$(git -C "$LOCAL_REPO" branch --show-current)"
CLEANER="$HERE/safe_cleanup_greenquic_processes.py"
[[ "$LOCAL_BRANCH" == "$BRANCH" ]] || { echo "ERROR: local branch=$LOCAL_BRANCH expected=$BRANCH" >&2; exit 2; }
[[ -z "$(git -C "$LOCAL_REPO" status --porcelain --untracked-files=no)" ]] || { echo "ERROR: tracked local changes present" >&2; exit 2; }
[[ -f "$CLEANER" ]] || { echo "ERROR: missing cleanup helper $CLEANER" >&2; exit 2; }

# ---------------------------------------------------------------------------
# FIRST REMOTE ACTION: ancestry-safe stale-process cleanup on BOTH endpoints.
# ---------------------------------------------------------------------------
log "installing safe cleanup helper on IDEX + Tinyman"
retry scp "${SSH[@]}" "$CLEANER" "idex:$REMOTE_CLEANER"
retry ssh "${SSH[@]}" idex "chmod 0700 '$REMOTE_CLEANER'; scp -q -o BatchMode=yes -o ConnectTimeout=15 '$REMOTE_CLEANER' root@tinyman:'$REMOTE_CLEANER'"
tiny "chmod 0700 '$REMOTE_CLEANER'"

cleanup_host_idex(){
    local marker="/tmp/gq_cleanup_${TAG}_idex.done" logf="/tmp/gq_cleanup_${TAG}_idex.log" jsonf="/tmp/gq_cleanup_${TAG}_idex.json"
    retry ssh "${SSH[@]}" idex "rm -f '$marker' '$logf' '$jsonf'; nohup setsid python3 '$REMOTE_CLEANER' --marker '$marker' --json '$jsonf' >'$logf' 2>&1 </dev/null & echo CLEANUP_PID=\$!"
    while ! ssh "${SSH[@]}" idex "test -f '$marker'" >/dev/null 2>&1; do sleep 1; done
    retry ssh "${SSH[@]}" idex "cat '$logf'; test \"\$(cat '$marker')\" = PASS; python3 '$REMOTE_CLEANER' --check"
}
cleanup_host_tiny(){
    local marker="/tmp/gq_cleanup_${TAG}_tinyman.done" logf="/tmp/gq_cleanup_${TAG}_tinyman.log" jsonf="/tmp/gq_cleanup_${TAG}_tinyman.json"
    tiny "rm -f '$marker' '$logf' '$jsonf'; nohup setsid python3 '$REMOTE_CLEANER' --marker '$marker' --json '$jsonf' >'$logf' 2>&1 </dev/null & echo CLEANUP_PID=\$!"
    while ! tiny "test -f '$marker'" >/dev/null 2>&1; do sleep 1; done
    tiny "cat '$logf'; test \"\$(cat '$marker')\" = PASS; python3 '$REMOTE_CLEANER' --check"
}
log "cleaning stale P5/P7 processes on IDEX"
cleanup_host_idex
log "cleaning stale P5/P7 processes on Tinyman"
cleanup_host_tiny
log "SAFE STALE-PROCESS CLEANUP PASS: IDEX + Tinyman"

# ---------------------------------------------------------------------------
# Sync exact Mac commit to both endpoints without requiring GitHub credentials.
# ---------------------------------------------------------------------------
BUNDLE="$(mktemp "${TMPDIR:-/tmp}/greenquic_mc.XXXXXX.bundle")"
REMOTE_BUNDLE="/tmp/greenquic_mc_${TAG}.bundle"
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
    echo "ERROR: commit mismatch local=$LOCAL_SHA idex=$IDEX_SHA tinyman=$TINY_SHA" >&2; exit 2;
}
log "Mac + idex + tinyman synced to $BRANCH @ $LOCAL_SHA"

# Preflights are traffic/NIC/build free.
retry ssh "${SSH[@]}" idex "cd '$P5' && bash ./run_parallel_multicore_fair.sh --controller-preflight --runs '$RUNS' --connections '$CONNECTIONS'"
retry ssh "${SSH[@]}" idex "cd '$P7' && bash ./run_parallel_multicore_fair.sh --controller-preflight --runs '$RUNS' --connections '$CONNECTIONS'"
log "P5 + P7 fair multicore controller preflight PASS"

# ---------------------------------------------------------------------------
# Remote detached suite. P7 is attempted regardless of P5 phase return code.
# ---------------------------------------------------------------------------
TMP_REMOTE="$(mktemp "${TMPDIR:-/tmp}/p5_p7_mc_remote.XXXXXX")"
cat > "$TMP_REMOTE" <<'REMOTE'
#!/usr/bin/env bash
set +e
P5="$1"; P7="$2"; P5_MATRIX="$3"; P7_MATRIX="$4"; RUNS="$5"; CONNECTIONS="$6"; STATE="$7"; SUMMARY="$8"
rm -f "$STATE.DONE" "$STATE.FAIL" "$STATE.PHASES" "$SUMMARY" "$SUMMARY.status.json"

P5RC=90
if cd "$P5"; then
    echo "======================================================================"
    echo "PHASE P5 DPDK: START"
    echo "======================================================================"
    bash ./run_parallel_multicore_fair.sh --runs "$RUNS" --connections "$CONNECTIONS" --output-dir "$P5_MATRIX"
    P5RC=$?
    echo "PHASE P5 DPDK: COMPLETE rc=$P5RC"
else
    echo "WARN: cannot cd to P5 directory; rc=$P5RC"
fi

sleep 10

P7RC=91
if cd "$P7"; then
    echo "======================================================================"
    echo "PHASE P7 LINUX FAIR BASELINE: START (MANDATORY ATTEMPT)"
    echo "======================================================================"
    bash ./run_parallel_multicore_fair.sh --runs "$RUNS" --connections "$CONNECTIONS" --output-dir "$P7_MATRIX"
    P7RC=$?
    echo "PHASE P7 LINUX FAIR BASELINE: COMPLETE rc=$P7RC"
else
    echo "WARN: cannot cd to P7 directory; rc=$P7RC"
fi

python3 "$P5/build_p5_p7_fair_summary.py" \
    --p5-matrix "$P5_MATRIX" \
    --p7-matrix "$P7_MATRIX" \
    --p5-rc "$P5RC" \
    --p7-rc "$P7RC" \
    --output "$SUMMARY"
SUMMARY_RC=$?
if [[ $SUMMARY_RC -ne 0 ]]; then
    echo "SUMMARY:$SUMMARY_RC" > "$STATE.FAIL"
    exit "$SUMMARY_RC"
fi
printf 'P5_RC=%s\nP7_RC=%s\n' "$P5RC" "$P7RC" > "$STATE.PHASES"
touch "$STATE.DONE"
exit 0
REMOTE
bash -n "$TMP_REMOTE"
retry scp "${SSH[@]}" "$TMP_REMOTE" "idex:$REMOTE_RUNNER"
LAUNCH_OUT="$(retry ssh "${SSH[@]}" idex "chmod 0700 '$REMOTE_RUNNER'; nohup setsid bash '$REMOTE_RUNNER' '$P5' '$P7' '$P5_MATRIX' '$P7_MATRIX' '$RUNS' '$CONNECTIONS' '$REMOTE_STATE' '$REMOTE_SUMMARY' >'$REMOTE_LOG' 2>&1 </dev/null & pid=\$!; echo \$pid > '$REMOTE_STATE.PID'; echo REMOTE_PID=\$pid")"
echo "$LAUNCH_OUT"
REMOTE_PID="$(printf '%s\n' "$LAUNCH_OUT" | sed -n 's/^REMOTE_PID=//p' | tail -1)"
[[ "$REMOTE_PID" =~ ^[0-9]+$ ]] || { echo "ERROR: could not parse remote PID" >&2; exit 2; }
log "detached fair P5+P7 multicore suite started on idex"

# Full live remote log with resumable line offset.
: > "$LOCAL_REMOTE_LOG"
while true; do
    if ssh "${SSH[@]}" idex "test -f '$REMOTE_STATE.DONE'" >/dev/null 2>&1; then break; fi
    if ssh "${SSH[@]}" idex "test -f '$REMOTE_STATE.FAIL'" >/dev/null 2>&1; then
        echo "ERROR: remote suite infrastructure/summary failed" >&2
        ssh "${SSH[@]}" idex "cat '$REMOTE_STATE.FAIL'; tail -240 '$REMOTE_LOG'" >&2 || true
        exit 1
    fi
    LOCAL_LINES="$(wc -l < "$LOCAL_REMOTE_LOG" | tr -d '[:space:]')"
    START_LINE=$((LOCAL_LINES + 1))
    log "LIVE REMOTE LOG (resume line $START_LINE): $REMOTE_LOG"
    set +e
    ssh "${SSH[@]}" idex "touch '$REMOTE_LOG'; tail -n +$START_LINE -F --pid='$REMOTE_PID' '$REMOTE_LOG'" | tee -a "$LOCAL_REMOTE_LOG"
    STREAM_RC=${PIPESTATUS[0]}
    set -e
    if (( STREAM_RC == 255 )); then
        log "live-log SSH lost; remote suite remains detached; reconnecting in 5 s"
        sleep 5
    else
        sleep 1
    fi
    if ! ssh "${SSH[@]}" idex "kill -0 '$REMOTE_PID' 2>/dev/null || test -f '$REMOTE_STATE.DONE' || test -f '$REMOTE_STATE.FAIL'" >/dev/null 2>&1; then
        echo "ERROR: remote runner exited without DONE/FAIL state" >&2
        ssh "${SSH[@]}" idex "tail -240 '$REMOTE_LOG'" >&2 || true
        exit 1
    fi
done

LOCAL_LINES="$(wc -l < "$LOCAL_REMOTE_LOG" | tr -d '[:space:]')"
START_LINE=$((LOCAL_LINES + 1))
ssh "${SSH[@]}" idex "sed -n '${START_LINE},\$p' '$REMOTE_LOG'" 2>/dev/null | tee -a "$LOCAL_REMOTE_LOG" || true

# ---------------------------------------------------------------------------
# Best-effort export: missing diagnostics never hide the other phase's results.
# ---------------------------------------------------------------------------
mkdir -p "$LOCAL_EXPORT/P5" "$LOCAL_EXPORT/P7"
copy_if_exists(){
    local remote="$1" local_path="$2"
    if ssh "${SSH[@]}" idex "test -f '$remote'" >/dev/null 2>&1; then
        retry scp "${SSH[@]}" "idex:$remote" "$local_path"
    fi
}
copy_if_exists "$REMOTE_SUMMARY" "$LOCAL_EXPORT/goodput_all_cases.tsv"
copy_if_exists "$REMOTE_SUMMARY.status.json" "$LOCAL_EXPORT/goodput_all_cases.tsv.status.json"
copy_if_exists "$REMOTE_STATE.PHASES" "$LOCAL_EXPORT/phase_status.txt"
copy_if_exists "$REMOTE_LOG" "$LOCAL_EXPORT/remote.log"

P5_FILES=(
  parallel_tables/parallel_goodput_summary.csv
  parallel_tables/parallel_goodput_all_runs.csv
  parallel_tables/parallel_goodput_per_core_summary.csv
  parallel_tables/parallel_active_summary.csv
  parallel_tables/dpdk_lcore_activity.csv
  parallel_tables/dpdk_lcore_activity_summary.csv
  dpdk_lcore_activity_validation.json
  P5_FAIRNESS_STATUS.json
  parallel_queue_activity.json
  multicore_validation.json
  quic_cpu_activity_server.json quic_cpu_activity_server.csv
  quic_cpu_activity_client.json quic_cpu_activity_client.csv
  PARALLEL_MULTICORE_CONFIG.txt
)
for rel in "${P5_FILES[@]}"; do copy_if_exists "$P5_MATRIX/$rel" "$LOCAL_EXPORT/P5/$(basename "$rel")"; done

P7_FILES=(
  parallel_tables/parallel_goodput_summary.csv
  parallel_tables/parallel_goodput_all_runs.csv
  parallel_tables/parallel_goodput_per_core_summary.csv
  parallel_tables/parallel_active_summary.csv
  parallel_tables/linux_dataplane_cpu_activity.csv
  parallel_tables/linux_dataplane_cpu_activity_summary.csv
  parallel_irq_activity_validation.json
  P7_FAIRNESS_STATUS.json
  multicore_validation.json
  quic_cpu_activity_server.json quic_cpu_activity_server.csv
  quic_cpu_activity_client.json quic_cpu_activity_client.csv
  PARALLEL_MULTICORE_CONFIG.txt
)
for rel in "${P7_FILES[@]}"; do copy_if_exists "$P7_MATRIX/$rel" "$LOCAL_EXPORT/P7/$(basename "$rel")"; done

log "COMPLETE: both P5 and mandatory P7 were attempted"
log "P5_MATRIX=$P5_MATRIX"
log "P7_MATRIX=$P7_MATRIX"
log "EXPORT=$LOCAL_EXPORT"
echo
if [[ -f "$LOCAL_EXPORT/phase_status.txt" ]]; then cat "$LOCAL_EXPORT/phase_status.txt"; fi
if [[ -f "$LOCAL_EXPORT/goodput_all_cases.tsv" ]]; then
    echo "FINAL FAIR GOODPUT SUMMARY"
    cat "$LOCAL_EXPORT/goodput_all_cases.tsv"
fi
if [[ -f "$LOCAL_EXPORT/goodput_all_cases.tsv.status.json" ]]; then
    echo "FINAL FAIRNESS STATUS"
    cat "$LOCAL_EXPORT/goodput_all_cases.tsv.status.json"
fi
