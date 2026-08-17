#!/usr/bin/env bash
set -Eeuo pipefail
BRANCH=performance2/p5-multicore
RUNS="${P5_ARCH4_RUNS:-2}";CONNS="${P5_ARCH4_CONNECTIONS:-4}";TAG="${P5_ARCH4_TAG:-$(date +%Y%m%d_%H%M%S)}"
P5=/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads
RESULT="$P5/matrix_results/P5_ARCH_V4_${CONNS}c_${RUNS}r_${TAG}"
RLOG="/root/P5_ARCH_V4_${TAG}.log";RSTATE="/tmp/P5_ARCH_V4_${TAG}";RRUN="/tmp/P5_ARCH_V4_${TAG}.sh"
RFULL="/root/P5_ARCH_V4_FULL_${TAG}.tar.gz";RSHARE="/root/P5_ARCH_V4_SHARE_${TAG}.tar.gz"
LMAC="$HOME/Downloads/P5_ARCH_V4_${TAG}.mac.log";LLIVE="$HOME/Downloads/P5_ARCH_V4_${TAG}.remote-live.log";LTERM="$HOME/Downloads/P5_ARCH_V4_${TAG}.terminal.log"
LFULL="$HOME/Downloads/P5_ARCH_V4_FULL_${TAG}.tar.gz";LSHARE="$HOME/Downloads/P5_ARCH_V4_SHARE_${TAG}.tar.gz";LEXPORT="$HOME/Downloads/P5_ARCH_V4_EXPORT_${TAG}"
SSH=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3)
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
retry(){ local rc;while true;do if "$@";then return 0;else rc=$?;fi;if ((rc==255));then log 'SSH/SCP transport lost; remote run is unaffected; retrying';sleep 5;else return "$rc";fi;done; }
tiny(){ local c="$1" q;printf -v q '%q' "$c";retry ssh "${SSH[@]}" idex "ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman $q"; }
[[ "$RUNS" =~ ^[1-9][0-9]*$ && "$CONNS" == 4 ]]||{ echo 'ERROR P5_ARCH4_RUNS positive and P5_ARCH4_CONNECTIONS=4 required' >&2;exit 2;}

if [[ "${1:-}" == --detach ]];then
  shift
  nohup caffeinate -dimsu env P5_ARCH4_RUNS="$RUNS" P5_ARCH4_CONNECTIONS="$CONNS" P5_ARCH4_TAG="$TAG" bash "$0" --foreground >"$LMAC" 2>&1 </dev/null & pid=$!
  disown "$pid" 2>/dev/null||true
  echo "STARTED P5 ARCH V4 PID=$pid";echo "TAG=$TAG";echo "MAC_LOG=$LMAC";echo "REMOTE_LIVE_LOG=$LLIVE";echo "FINAL_TERMINAL_LOG=$LTERM";echo "FULL_RESULTS=$LFULL";echo "SHARE_RESULTS=$LSHARE";echo '14 architectural cases; successful traffic survives diagnostic/plot/analyzer failures.'
  exit 0
fi
[[ "${1:-}" == --foreground ]]&&shift||true;[[ $# -eq 0 ]]||{ echo "ERROR unknown args $*" >&2;exit 2;}
HERE="$(cd -- "$(dirname -- "$0")" && pwd)";REPO="$(git -C "$HERE" rev-parse --show-toplevel)";SHA="$(git -C "$REPO" rev-parse HEAD)";CUR="$(git -C "$REPO" branch --show-current)"
[[ "$CUR" == "$BRANCH" ]]||{ echo "ERROR branch=$CUR expected=$BRANCH" >&2;exit 2;};[[ -z "$(git -C "$REPO" status --porcelain --untracked-files=no)" ]]||{ echo 'ERROR tracked local changes present' >&2;exit 2;}

# FIRST REMOTE ACTION: install safe cleaner and clean stale experiment processes on both endpoints.
BASE_CLEAN="$HERE/safe_cleanup_greenquic_processes.py";BN_CLEAN="$HERE/safe_cleanup_p5_bottleneck_processes.py";[[ -f "$BASE_CLEAN" && -f "$BN_CLEAN" ]]||{ echo 'ERROR cleanup helpers missing' >&2;exit 2;}
RCD="/tmp/gq_arch4_clean_${TAG}";log 'installing safe cleanup on IDEX + Tinyman';retry ssh "${SSH[@]}" idex "mkdir -p '$RCD'";retry scp "${SSH[@]}" "$BASE_CLEAN" "$BN_CLEAN" "idex:$RCD/";retry ssh "${SSH[@]}" idex "ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman 'mkdir -p $RCD'; scp -q -o BatchMode=yes -o ConnectTimeout=15 '$RCD/'*.py root@tinyman:'$RCD/'"
run_clean_idex(){ local m="/tmp/gqarch4_${TAG}_i.done" l="/tmp/gqarch4_${TAG}_i.log";retry ssh "${SSH[@]}" idex "rm -f '$m' '$l'; nohup setsid python3 '$RCD/safe_cleanup_p5_bottleneck_processes.py' --marker '$m' >'$l' 2>&1 </dev/null &";while ! ssh "${SSH[@]}" idex "test -f '$m'" >/dev/null 2>&1;do sleep 1;done;retry ssh "${SSH[@]}" idex "cat '$l'; test \"\$(cat '$m')\" = PASS"; }
run_clean_tiny(){ local m="/tmp/gqarch4_${TAG}_t.done" l="/tmp/gqarch4_${TAG}_t.log";tiny "rm -f '$m' '$l'; nohup setsid python3 '$RCD/safe_cleanup_p5_bottleneck_processes.py' --marker '$m' >'$l' 2>&1 </dev/null &";while ! tiny "test -f '$m'" >/dev/null 2>&1;do sleep 1;done;tiny "cat '$l'; test \"\$(cat '$m')\" = PASS"; }
log 'cleaning IDEX';run_clean_idex;log 'cleaning Tinyman';run_clean_tiny;log 'SAFE CLEANUP PASS'

# Sync the exact Mac commit to both experiment hosts with a git bundle.
BUNDLE="$(mktemp "${TMPDIR:-/tmp}/gq_arch4.XXXXXX.bundle")";RB="/tmp/gq_arch4_${TAG}.bundle";TMP_REMOTE='';trap 'rm -f "$BUNDLE" "${TMP_REMOTE:-}"' EXIT
git -C "$REPO" bundle create "$BUNDLE" "$BRANCH";retry scp "${SSH[@]}" "$BUNDLE" "idex:$RB";retry ssh "${SSH[@]}" idex "cd /root/mohsen && git reset --hard && git fetch '$RB' '$BRANCH' && git checkout -B '$BRANCH' FETCH_HEAD && git reset --hard FETCH_HEAD";retry ssh "${SSH[@]}" idex "scp -q -o BatchMode=yes -o ConnectTimeout=15 '$RB' root@tinyman:'$RB'";tiny "cd /root/mohsen && git reset --hard && git fetch '$RB' '$BRANCH' && git checkout -B '$BRANCH' FETCH_HEAD && git reset --hard FETCH_HEAD"
ISHA="$(retry ssh "${SSH[@]}" idex 'cd /root/mohsen && git rev-parse HEAD')";TSHA="$(tiny 'cd /root/mohsen && git rev-parse HEAD')";[[ "$ISHA" == "$SHA" && "$TSHA" == "$SHA" ]]||{ echo "ERROR SHA local=$SHA idex=$ISHA tiny=$TSHA" >&2;exit 2;};log "all hosts synced @ $SHA"

# Static-only preflight. No NIC or traffic starts here.
retry ssh "${SSH[@]}" idex "cd '$P5' && bash -n ./run_p5_arch_off_case_v4.sh && bash -n ./run_p5_arch_sweep_v4.sh && bash -n ./mac_run_p5_arch_v4.sh && python3 -m py_compile ./apply_p5_arch_runtime_overlay_v4.py ./summarize_p5_arch_v4.py ./cpu_busy_sampler.py ./quic_cpu_activity_sampler.py ./analyze_p5_bottleneck_case.py && python3 ./quic_cpu_activity_sampler.py --self-test && bash ./run_p5_arch_off_case_v4.sh --help >/dev/null"
CASE_COUNT="$(retry ssh "${SSH[@]}" idex "cd '$P5' && grep -Ec '^run_case (A0_|A1_|B1_|B2_|B8_|C1_|C2_|C4_|Dg_|Do_|E_|Fm_|Fr_|Z_)' ./run_p5_arch_sweep_v4.sh")";[[ "$CASE_COUNT" == 14 ]]||{ echo "ERROR expected 14 architecture cases, found $CASE_COUNT" >&2;exit 2;};log 'P5 ARCH V4 static preflight PASS (14 cases)'

TMP_REMOTE="$(mktemp "${TMPDIR:-/tmp}/gq_arch4_remote.XXXXXX.sh")"
cat >"$TMP_REMOTE" <<'REMOTE'
#!/usr/bin/env bash
set +e
P5="$1";RUNS="$2";CONNS="$3";TAG="$4";OUT="$5";STATE="$6";FULL="$7";SHARE="$8"
rm -f "$STATE.DONE" "$STATE.RC" "$FULL" "$SHARE";echo "P5 ARCH V4 REMOTE START tag=$TAG runs=$RUNS connections=$CONNS commit=$(git -C /root/mohsen rev-parse HEAD 2>/dev/null)"
cd "$P5"||{ echo 98>"$STATE.RC";touch "$STATE.DONE";exit 0; }
env P5_ARCH4_RUNS="$RUNS" P5_ARCH4_CONNECTIONS="$CONNS" P5_ARCH4_TAG="$TAG" P5_ARCH4_OUTPUT_ROOT="$OUT" bash ./run_p5_arch_sweep_v4.sh
RC=$?;echo "$RC">"$STATE.RC";echo "P5 ARCH V4 SWEEP PROCESS RC=$RC"
if [[ -d "$OUT" ]];then tar -C "$(dirname "$OUT")" -czf "$FULL" "$(basename "$OUT")";echo "FULL_ARCHIVE_RC=$? path=$FULL";tar -C "$(dirname "$OUT")" --exclude='*/runs/*' -czf "$SHARE" "$(basename "$OUT")";echo "SHARE_ARCHIVE_RC=$? path=$SHARE";else echo "WARN result root missing: $OUT";fi
touch "$STATE.DONE";echo 'P5 ARCH V4 REMOTE COMPLETE';exit 0
REMOTE
bash -n "$TMP_REMOTE";retry scp "${SSH[@]}" "$TMP_REMOTE" "idex:$RRUN";LAUNCH="$(retry ssh "${SSH[@]}" idex "chmod 0700 '$RRUN'; nohup setsid bash '$RRUN' '$P5' '$RUNS' '$CONNS' '$TAG' '$RESULT' '$RSTATE' '$RFULL' '$RSHARE' >'$RLOG' 2>&1 </dev/null & pid=\$!; echo \$pid >'$RSTATE.PID'; echo REMOTE_PID=\$pid")";echo "$LAUNCH";RPID="$(printf '%s\n' "$LAUNCH"|sed -n 's/^REMOTE_PID=//p'|tail -1)";[[ "$RPID" =~ ^[0-9]+$ ]]||{ echo 'ERROR remote PID parse' >&2;exit 2;};log "remote architecture sweep detached pid=$RPID"

: >"$LLIVE"
while true;do if ssh "${SSH[@]}" idex "test -f '$RSTATE.DONE'" >/dev/null 2>&1;then break;fi;N="$(wc -l <"$LLIVE"|tr -d '[:space:]')";S=$((N+1));set +e;ssh "${SSH[@]}" idex "touch '$RLOG'; tail -n +$S -F --pid='$RPID' '$RLOG'"|tee -a "$LLIVE";RC=${PIPESTATUS[0]};set -e;if ((RC==255));then log 'live SSH lost; remote continues';sleep 5;else sleep 1;fi;done
N="$(wc -l <"$LLIVE"|tr -d '[:space:]')";S=$((N+1));ssh "${SSH[@]}" idex "sed -n '${S},\$p' '$RLOG'" 2>/dev/null|tee -a "$LLIVE"||true
mkdir -p "$LEXPORT";retry scp "${SSH[@]}" "idex:$RLOG" "$LTERM";ssh "${SSH[@]}" idex "test -f '$RSHARE'" >/dev/null 2>&1&&retry scp "${SSH[@]}" "idex:$RSHARE" "$LSHARE"||true;ssh "${SSH[@]}" idex "test -f '$RFULL'" >/dev/null 2>&1&&retry scp "${SSH[@]}" "idex:$RFULL" "$LFULL"||true
for f in ARCH_SWEEP_SUMMARY.txt ARCH_SWEEP_SUMMARY.csv CASE_STATUS.tsv SWEEP_DESIGN.txt;do ssh "${SSH[@]}" idex "test -f '$RESULT/$f'" >/dev/null 2>&1&&retry scp "${SSH[@]}" "idex:$RESULT/$f" "$LEXPORT/$f"||true;done
log 'AUTO-SCP COMPLETE';echo "TERMINAL_LOG=$LTERM";echo "LIVE_LOG=$LLIVE";echo "SHARE_ARCHIVE=$LSHARE";echo "FULL_ARCHIVE=$LFULL";echo "SUMMARY_DIR=$LEXPORT";[[ -f "$LEXPORT/ARCH_SWEEP_SUMMARY.txt" ]]&&cat "$LEXPORT/ARCH_SWEEP_SUMMARY.txt"||true
