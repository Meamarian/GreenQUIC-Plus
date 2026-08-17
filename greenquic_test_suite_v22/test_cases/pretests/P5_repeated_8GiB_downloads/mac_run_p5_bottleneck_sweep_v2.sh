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
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
retry(){ local rc;while true;do if "$@";then return 0;else rc=$?;fi;if ((rc==255));then log 'SSH/SCP lost; retrying in 5 s';sleep 5;else return "$rc";fi;done; }
tiny(){ local c="$1" q;printf -v q '%q' "$c";retry ssh "${SSH[@]}" idex "ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman $q"; }
[[ "$RUNS" =~ ^[1-9][0-9]*$ ]]||{ echo 'ERROR: invalid runs' >&2;exit 2;};[[ "$CONNECTIONS" =~ ^[2-9][0-9]*$ ]]||{ echo 'ERROR: connections >=2' >&2;exit 2;}
if [[ "${1:-}" == --detach ]];then shift;nohup caffeinate -dimsu env P5_BOTTLENECK_RUNS="$RUNS" P5_BOTTLENECK_CONNECTIONS="$CONNECTIONS" P5_BOTTLENECK_TAG="$TAG" bash "$0" --foreground >"$LOCAL_MAC_LOG" 2>&1 </dev/null & pid=$!;disown "$pid" 2>/dev/null||true;echo "STARTED P5 BOTTLENECK SWEEP V2 PID=$pid";echo "TAG=$TAG";echo "MAC_LOG=$LOCAL_MAC_LOG";echo "REMOTE_LIVE_LOG=$LOCAL_LIVE";echo "FINAL_TERMINAL_LOG=$LOCAL_TERMINAL";echo "FULL_RESULTS=$LOCAL_FULL";echo "SHARE_RESULTS=$LOCAL_SHARE";echo "20 controlled P5/OFF cases; failures are preserved and later cases continue.";exit 0;fi
[[ "${1:-}" == --foreground ]]&&shift||true;[[ $# -eq 0 ]]||{ echo "ERROR: unknown args $*" >&2;exit 2;}
HERE="$(cd -- "$(dirname -- "$0")" && pwd)";REPO="$(git -C "$HERE" rev-parse --show-toplevel)";SHA="$(git -C "$REPO" rev-parse HEAD)";B="$(git -C "$REPO" branch --show-current)"
[[ "$B" == "$BRANCH" ]]||{ echo "ERROR: branch=$B expected=$BRANCH" >&2;exit 2;};[[ -z "$(git -C "$REPO" status --porcelain --untracked-files=no)" ]]||{ echo 'ERROR: tracked local changes present' >&2;exit 2;}
BASE_CLEAN="$HERE/safe_cleanup_greenquic_processes.py";BN_CLEAN="$HERE/safe_cleanup_p5_bottleneck_processes.py";[[ -f "$BASE_CLEAN" && -f "$BN_CLEAN" ]]||{ echo 'ERROR: cleanup helpers missing' >&2;exit 2;}
# FIRST REMOTE ACTION: install ancestry-safe cleaner and clean both endpoints.
RCD="/tmp/gq_bn_clean_${TAG}";log 'installing safe bottleneck cleaner on IDEX + Tinyman';retry ssh "${SSH[@]}" idex "mkdir -p '$RCD'";retry scp "${SSH[@]}" "$BASE_CLEAN" "$BN_CLEAN" "idex:$RCD/";retry ssh "${SSH[@]}" idex "ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman 'mkdir -p $RCD'; scp -q -o BatchMode=yes -o ConnectTimeout=15 '$RCD/'*.py root@tinyman:'$RCD/'"
clean_idex(){ local m="/tmp/gqbn_${TAG}_idex.done" l="/tmp/gqbn_${TAG}_idex.log";retry ssh "${SSH[@]}" idex "rm -f '$m' '$l'; nohup setsid python3 '$RCD/safe_cleanup_p5_bottleneck_processes.py' --marker '$m' >'$l' 2>&1 </dev/null & echo CLEAN_PID=\$!";while ! ssh "${SSH[@]}" idex "test -f '$m'" >/dev/null 2>&1;do sleep 1;done;retry ssh "${SSH[@]}" idex "cat '$l'; test \"\$(cat '$m')\" = PASS; cd '$RCD' && python3 ./safe_cleanup_p5_bottleneck_processes.py --check"; }
clean_tiny(){ local m="/tmp/gqbn_${TAG}_tiny.done" l="/tmp/gqbn_${TAG}_tiny.log";tiny "rm -f '$m' '$l'; nohup setsid python3 '$RCD/safe_cleanup_p5_bottleneck_processes.py' --marker '$m' >'$l' 2>&1 </dev/null & echo CLEAN_PID=\$!";while ! tiny "test -f '$m'" >/dev/null 2>&1;do sleep 1;done;tiny "cat '$l'; test \"\$(cat '$m')\" = PASS; cd '$RCD' && python3 ./safe_cleanup_p5_bottleneck_processes.py --check"; }
log 'cleaning IDEX';clean_idex;log 'cleaning Tinyman';clean_tiny;log 'SAFE CLEANUP PASS: IDEX + Tinyman'
# Exact Mac commit -> IDEX -> Tinyman via bundle; no server GitHub credentials.
BUNDLE="$(mktemp "${TMPDIR:-/tmp}/gq_bn.XXXXXX.bundle")";RB="/tmp/gq_bn_${TAG}.bundle";TMP_REMOTE='';trap 'rm -f "$BUNDLE" "${TMP_REMOTE:-}"' EXIT;git -C "$REPO" bundle create "$BUNDLE" "$BRANCH";retry scp "${SSH[@]}" "$BUNDLE" "idex:$RB";retry ssh "${SSH[@]}" idex "cd /root/mohsen && git reset --hard && git fetch '$RB' '$BRANCH' && git checkout -B '$BRANCH' FETCH_HEAD && git reset --hard FETCH_HEAD";retry ssh "${SSH[@]}" idex "scp -q -o BatchMode=yes -o ConnectTimeout=15 '$RB' root@tinyman:'$RB'";tiny "cd /root/mohsen && git reset --hard && git fetch '$RB' '$BRANCH' && git checkout -B '$BRANCH' FETCH_HEAD && git reset --hard FETCH_HEAD";ISHA="$(retry ssh "${SSH[@]}" idex 'cd /root/mohsen && git rev-parse HEAD')";TSHA="$(tiny 'cd /root/mohsen && git rev-parse HEAD')";[[ "$ISHA" == "$SHA" && "$TSHA" == "$SHA" ]]||{ echo "ERROR SHA local=$SHA idex=$ISHA tiny=$TSHA" >&2;exit 2;};log "synced all hosts @ $SHA"
# Static preflight only; builds and traffic happen inside detached remote sweep.
retry ssh "${SSH[@]}" idex "cd '$P5' && bash -n ./run_p5_bottleneck_sweep_v2.sh && bash -n ./run_p5_bottleneck_case_diag.sh && bash -n ./run_p5_parallel_off_case.sh && bash -n ./build_p5_bottleneck_profile.sh && python3 -m py_compile ./summarize_p5_bottleneck_sweep_v2.py ./analyze_p5_bottleneck_case.py ./cpu_busy_sampler.py ./quic_cpu_activity_sampler.py ./apply_p5_bottleneck_txq.py"
log 'P5 bottleneck static preflight PASS'
TMP_REMOTE="$(mktemp "${TMPDIR:-/tmp}/gq_bn_remote.XXXXXX.sh")"
cat >"$TMP_REMOTE" <<'REMOTE'
#!/usr/bin/env bash
set +e
P5="$1";RUNS="$2";CONNS="$3";TAG="$4";OUT="$5";STATE="$6";FULL="$7";SHARE="$8"
rm -f "$STATE.DONE" "$STATE.RC" "$FULL" "$SHARE"
echo "P5 BOTTLENECK REMOTE START tag=$TAG runs=$RUNS connections=$CONNS commit=$(git -C /root/mohsen rev-parse HEAD 2>/dev/null)"
cd "$P5" || { echo 98 >"$STATE.RC";touch "$STATE.DONE";exit 0; }
env P5_BOTTLENECK_RUNS="$RUNS" P5_BOTTLENECK_CONNECTIONS="$CONNS" P5_BOTTLENECK_TAG="$TAG" P5_BOTTLENECK_OUTPUT_ROOT="$OUT" bash ./run_p5_bottleneck_sweep_v2.sh
RC=$?
echo "$RC" >"$STATE.RC"
echo "P5 BOTTLENECK SWEEP PROCESS RC=$RC"
if [[ -d "$OUT" ]];then
 echo "Packaging full result archive...";tar -C "$(dirname "$OUT")" -czf "$FULL" "$(basename "$OUT")";echo "FULL_ARCHIVE_RC=$? path=$FULL"
 echo "Packaging share result archive (raw unified runs excluded)...";tar -C "$(dirname "$OUT")" --exclude='*/runs/*' -czf "$SHARE" "$(basename "$OUT")";echo "SHARE_ARCHIVE_RC=$? path=$SHARE"
else
 echo "WARN result root missing: $OUT"
fi
touch "$STATE.DONE"
echo "P5 BOTTLENECK REMOTE COMPLETE"
exit 0
REMOTE
bash -n "$TMP_REMOTE";retry scp "${SSH[@]}" "$TMP_REMOTE" "idex:$REMOTE_RUNNER";OUT="$(retry ssh "${SSH[@]}" idex "chmod 0700 '$REMOTE_RUNNER'; nohup setsid bash '$REMOTE_RUNNER' '$P5' '$RUNS' '$CONNECTIONS' '$TAG' '$RESULT_ROOT' '$REMOTE_STATE' '$REMOTE_FULL' '$REMOTE_SHARE' >'$REMOTE_LOG' 2>&1 </dev/null & pid=\$!; echo \$pid >'$REMOTE_STATE.PID'; echo REMOTE_PID=\$pid")";echo "$OUT";RPID="$(printf '%s\n' "$OUT"|sed -n 's/^REMOTE_PID=//p'|tail -1)";[[ "$RPID" =~ ^[0-9]+$ ]]||{ echo 'ERROR parse remote PID' >&2;exit 2;};log "remote sweep detached PID=$RPID"
: >"$LOCAL_LIVE"
while true;do if ssh "${SSH[@]}" idex "test -f '$REMOTE_STATE.DONE'" >/dev/null 2>&1;then break;fi;N="$(wc -l <"$LOCAL_LIVE"|tr -d '[:space:]')";S=$((N+1));log "LIVE REMOTE LOG resume=$S";set +e;ssh "${SSH[@]}" idex "touch '$REMOTE_LOG'; tail -n +$S -F --pid='$RPID' '$REMOTE_LOG'"|tee -a "$LOCAL_LIVE";RC=${PIPESTATUS[0]};set -e;if ((RC==255));then log 'live SSH lost; remote continues; reconnecting';sleep 5;else sleep 1;fi;done
N="$(wc -l <"$LOCAL_LIVE"|tr -d '[:space:]')";S=$((N+1));ssh "${SSH[@]}" idex "sed -n '${S},\$p' '$REMOTE_LOG'" 2>/dev/null|tee -a "$LOCAL_LIVE"||true
mkdir -p "$LOCAL_EXPORT";retry scp "${SSH[@]}" "idex:$REMOTE_LOG" "$LOCAL_TERMINAL";if ssh "${SSH[@]}" idex "test -f '$REMOTE_SHARE'" >/dev/null 2>&1;then retry scp "${SSH[@]}" "idex:$REMOTE_SHARE" "$LOCAL_SHARE";fi;if ssh "${SSH[@]}" idex "test -f '$REMOTE_FULL'" >/dev/null 2>&1;then retry scp "${SSH[@]}" "idex:$REMOTE_FULL" "$LOCAL_FULL";fi
for f in BOTTLENECK_SWEEP_SUMMARY.txt BOTTLENECK_SWEEP_SUMMARY.csv CASE_STATUS.tsv SWEEP_DESIGN.txt;do if ssh "${SSH[@]}" idex "test -f '$RESULT_ROOT/$f'" >/dev/null 2>&1;then retry scp "${SSH[@]}" "idex:$RESULT_ROOT/$f" "$LOCAL_EXPORT/$f";fi;done
if ssh "${SSH[@]}" idex "test -f '$REMOTE_STATE.RC'" >/dev/null 2>&1;then retry scp "${SSH[@]}" "idex:$REMOTE_STATE.RC" "$LOCAL_EXPORT/sweep_process_rc.txt";fi
log 'AUTO-SCP COMPLETE';echo "TERMINAL_LOG=$LOCAL_TERMINAL";echo "LIVE_LOG=$LOCAL_LIVE";echo "SHARE_ARCHIVE=$LOCAL_SHARE";echo "FULL_ARCHIVE=$LOCAL_FULL";echo "SUMMARY_DIR=$LOCAL_EXPORT";[[ -f "$LOCAL_EXPORT/BOTTLENECK_SWEEP_SUMMARY.txt" ]]&&cat "$LOCAL_EXPORT/BOTTLENECK_SWEEP_SUMMARY.txt"||true
