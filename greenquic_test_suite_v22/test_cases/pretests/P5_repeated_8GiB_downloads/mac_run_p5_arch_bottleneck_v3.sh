#!/usr/bin/env bash
set -Eeuo pipefail
BRANCH=performance2/p5-multicore
RUNS="${P5_ARCH_RUNS:-2}";CONNS="${P5_ARCH_CONNECTIONS:-4}";TAG="${P5_ARCH_TAG:-$(date +%Y%m%d_%H%M%S)}"
P5=/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads
RESULT_ROOT="$P5/matrix_results/P5_ARCH_BOTTLENECK_V3_${CONNS}c_${RUNS}r_${TAG}"
REMOTE_RUNNER="/tmp/P5_ARCH_${TAG}.sh";REMOTE_LOG="/root/P5_ARCH_${TAG}.log";REMOTE_STATE="/tmp/P5_ARCH_${TAG}.state"
REMOTE_FULL="/root/P5_ARCH_FULL_${TAG}.tar.gz";REMOTE_SHARE="/root/P5_ARCH_SHARE_${TAG}.tar.gz"
LOCAL_MAC="$HOME/Downloads/P5_ARCH_${TAG}.mac.log";LOCAL_LIVE="$HOME/Downloads/P5_ARCH_${TAG}.remote-live.log";LOCAL_TERMINAL="$HOME/Downloads/P5_ARCH_${TAG}.terminal.log"
LOCAL_FULL="$HOME/Downloads/P5_ARCH_FULL_${TAG}.tar.gz";LOCAL_SHARE="$HOME/Downloads/P5_ARCH_SHARE_${TAG}.tar.gz";LOCAL_EXPORT="$HOME/Downloads/P5_ARCH_EXPORT_${TAG}"
SSH=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3)
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
retry(){ local rc;while true;do if "$@";then return 0;else rc=$?;fi;if ((rc==255));then log 'SSH/SCP transport lost; retrying in 5 s';sleep 5;else return "$rc";fi;done; }
tiny(){ local c="$1" q;printf -v q '%q' "$c";retry ssh "${SSH[@]}" idex "ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman $q"; }
[[ "$RUNS" =~ ^[1-9][0-9]*$ && "$CONNS" == 4 ]]||{ echo 'ERROR: P5_ARCH_RUNS positive and P5_ARCH_CONNECTIONS=4 required' >&2;exit 2;}
if [[ "${1:-}" == --detach ]];then
 shift;nohup caffeinate -dimsu env P5_ARCH_RUNS="$RUNS" P5_ARCH_CONNECTIONS="$CONNS" P5_ARCH_TAG="$TAG" bash "$0" --foreground >"$LOCAL_MAC" 2>&1 </dev/null & pid=$!;disown "$pid" 2>/dev/null||true
 echo "STARTED P5 ARCH BOTTLENECK V3 PID=$pid";echo "TAG=$TAG";echo "MAC_LOG=$LOCAL_MAC";echo "REMOTE_LIVE_LOG=$LOCAL_LIVE";echo "FINAL_TERMINAL_LOG=$LOCAL_TERMINAL";echo "FULL_RESULTS=$LOCAL_FULL";echo "SHARE_RESULTS=$LOCAL_SHARE";echo "14 ranked architecture cases + perf diagnostic + raw DPDK ceiling probe; 4x8GiB each.";exit 0
fi
[[ "${1:-}" == --foreground ]]&&shift||true;[[ $# -eq 0 ]]||{ echo "ERROR unknown args $*" >&2;exit 2;}
HERE="$(cd -- "$(dirname -- "$0")" && pwd)";REPO="$(git -C "$HERE" rev-parse --show-toplevel)";SHA="$(git -C "$REPO" rev-parse HEAD)";CUR="$(git -C "$REPO" branch --show-current)"
[[ "$CUR" == "$BRANCH" ]]||{ echo "ERROR branch=$CUR expected=$BRANCH" >&2;exit 2;};[[ -z "$(git -C "$REPO" status --porcelain --untracked-files=no)" ]]||{ echo 'ERROR tracked local changes present' >&2;exit 2;}
BASE_CLEAN="$HERE/safe_cleanup_greenquic_processes.py";INSTALLER="$HERE/install_p5_arch_suite_v3.py";[[ -f "$BASE_CLEAN" && -f "$INSTALLER" ]]||{ echo 'ERROR base cleaner/architecture installer missing' >&2;exit 2;}
GEN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/gq_arch_gen.XXXXXX")";python3 "$INSTALLER" --target "$GEN_TMP" >/dev/null;ARCH_CLEAN="$GEN_TMP/safe_cleanup_p5_arch_processes.py"
[[ -f "$ARCH_CLEAN" ]]||{ echo 'ERROR generated architecture cleaner missing' >&2;exit 2;}

# FIRST REMOTE ACTION: install ancestry-safe cleanup and clean both endpoints.
RCD="/tmp/gq_arch_clean_${TAG}";log 'installing architecture cleaner on IDEX + Tinyman';retry ssh "${SSH[@]}" idex "mkdir -p '$RCD'";retry scp "${SSH[@]}" "$BASE_CLEAN" "$ARCH_CLEAN" "idex:$RCD/";retry ssh "${SSH[@]}" idex "ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman 'mkdir -p $RCD'; scp -q -o BatchMode=yes -o ConnectTimeout=15 '$RCD/'*.py root@tinyman:'$RCD/'"
clean_idex(){ local m="/tmp/gqarch_${TAG}_idex.done" l="/tmp/gqarch_${TAG}_idex.log";retry ssh "${SSH[@]}" idex "rm -f '$m' '$l'; nohup setsid python3 '$RCD/safe_cleanup_p5_arch_processes.py' --marker '$m' >'$l' 2>&1 </dev/null & echo CLEAN_PID=\$!";while ! ssh "${SSH[@]}" idex "test -f '$m'" >/dev/null 2>&1;do sleep 1;done;retry ssh "${SSH[@]}" idex "cat '$l'; test \"\$(cat '$m')\" = PASS; cd '$RCD' && python3 ./safe_cleanup_p5_arch_processes.py --check"; }
clean_tiny(){ local m="/tmp/gqarch_${TAG}_tiny.done" l="/tmp/gqarch_${TAG}_tiny.log";tiny "rm -f '$m' '$l'; nohup setsid python3 '$RCD/safe_cleanup_p5_arch_processes.py' --marker '$m' >'$l' 2>&1 </dev/null & echo CLEAN_PID=\$!";while ! tiny "test -f '$m'" >/dev/null 2>&1;do sleep 1;done;tiny "cat '$l'; test \"\$(cat '$m')\" = PASS; cd '$RCD' && python3 ./safe_cleanup_p5_arch_processes.py --check"; }
log 'cleaning IDEX';clean_idex;log 'cleaning Tinyman';clean_tiny;log 'SAFE CLEANUP PASS: IDEX + Tinyman'

# Exact Mac commit -> IDEX -> Tinyman.
BUNDLE="$(mktemp "${TMPDIR:-/tmp}/gq_arch.XXXXXX.bundle")";RB="/tmp/gq_arch_${TAG}.bundle";TMP_REMOTE='';trap 'rm -f "$BUNDLE" "${TMP_REMOTE:-}"; rm -rf "${GEN_TMP:-}"' EXIT
git -C "$REPO" bundle create "$BUNDLE" "$BRANCH";retry scp "${SSH[@]}" "$BUNDLE" "idex:$RB";retry ssh "${SSH[@]}" idex "cd /root/mohsen && git reset --hard && git fetch '$RB' '$BRANCH' && git checkout -B '$BRANCH' FETCH_HEAD && git reset --hard FETCH_HEAD";retry ssh "${SSH[@]}" idex "scp -q -o BatchMode=yes -o ConnectTimeout=15 '$RB' root@tinyman:'$RB'";tiny "cd /root/mohsen && git reset --hard && git fetch '$RB' '$BRANCH' && git checkout -B '$BRANCH' FETCH_HEAD && git reset --hard FETCH_HEAD"
ISHA="$(retry ssh "${SSH[@]}" idex 'cd /root/mohsen && git rev-parse HEAD')";TSHA="$(tiny 'cd /root/mohsen && git rev-parse HEAD')";[[ "$ISHA" == "$SHA" && "$TSHA" == "$SHA" ]]||{ echo "ERROR SHA local=$SHA idex=$ISHA tiny=$TSHA" >&2;exit 2;};log "Mac + IDEX + Tinyman synced @ $SHA"
# Materialize the architecture suite deterministically from the tracked installer on both endpoints.
retry ssh "${SSH[@]}" idex "cd '$P5' && python3 ./install_p5_arch_suite_v3.py --target '$P5'"
tiny "cd '$P5' && python3 ./install_p5_arch_suite_v3.py --target '$P5'"
log 'architecture suite materialized identically on IDEX + Tinyman'

# Static-only preflight: no NIC startup or traffic.
retry ssh "${SSH[@]}" idex "cd '$P5' && for f in mac_run_p5_arch_bottleneck_v3.sh run_p5_arch_bottleneck_sweep_v3.sh run_p5_arch_off_case.sh build_p5_arch_profile.sh gq_common_p5_arch_overlay.sh run_role_p5_arch.sh run_server_arch.sh run_client_parallel_arch.sh run_p5_raw_dpdk_ceiling_probe.sh perf_profile_exact_process.sh; do bash -n \"\$f\" || exit; done; python3 -m py_compile thread_cpu_profiler.py apply_p5_arch_spsc.py summarize_p5_arch_bottleneck.py safe_cleanup_p5_arch_processes.py; bash ./run_p5_arch_off_case.sh --help >/dev/null"
log 'P5 architecture static preflight PASS'

TMP_REMOTE="$(mktemp "${TMPDIR:-/tmp}/gq_arch_remote.XXXXXX.sh")"
cat >"$TMP_REMOTE" <<'REMOTE'
#!/usr/bin/env bash
set +e
P5="$1";RUNS="$2";CONNS="$3";TAG="$4";OUT="$5";STATE="$6";FULL="$7";SHARE="$8"
rm -f "$STATE.DONE" "$STATE.RC" "$FULL" "$SHARE";echo "P5 ARCH REMOTE START tag=$TAG runs=$RUNS connections=$CONNS commit=$(git -C /root/mohsen rev-parse HEAD 2>/dev/null)"
cd "$P5"||{ echo 98>"$STATE.RC";touch "$STATE.DONE";exit 0; }
env P5_ARCH_RUNS="$RUNS" P5_ARCH_CONNECTIONS="$CONNS" P5_ARCH_TAG="$TAG" P5_ARCH_OUTPUT_ROOT="$OUT" bash ./run_p5_arch_bottleneck_sweep_v3.sh
RC=$?;echo "$RC">"$STATE.RC";echo "P5 ARCH SWEEP PROCESS RC=$RC"
if [[ -d "$OUT" ]];then
 tar -C "$(dirname "$OUT")" -czf "$FULL" "$(basename "$OUT")";echo "FULL_ARCHIVE_RC=$? path=$FULL"
 tar -C "$(dirname "$OUT")" --exclude='*/runs/*' --exclude='*.data' -czf "$SHARE" "$(basename "$OUT")";echo "SHARE_ARCHIVE_RC=$? path=$SHARE"
else echo "WARN result root missing: $OUT";fi
touch "$STATE.DONE";echo 'P5 ARCH REMOTE COMPLETE';exit 0
REMOTE
bash -n "$TMP_REMOTE";retry scp "${SSH[@]}" "$TMP_REMOTE" "idex:$REMOTE_RUNNER";OUT="$(retry ssh "${SSH[@]}" idex "chmod 0700 '$REMOTE_RUNNER'; nohup setsid bash '$REMOTE_RUNNER' '$P5' '$RUNS' '$CONNS' '$TAG' '$RESULT_ROOT' '$REMOTE_STATE' '$REMOTE_FULL' '$REMOTE_SHARE' >'$REMOTE_LOG' 2>&1 </dev/null & pid=\$!; echo \$pid >'$REMOTE_STATE.PID'; echo REMOTE_PID=\$pid")";echo "$OUT";RPID="$(printf '%s\n' "$OUT"|sed -n 's/^REMOTE_PID=//p'|tail -1)";[[ "$RPID" =~ ^[0-9]+$ ]]||{ echo 'ERROR remote PID parse' >&2;exit 2;};log "remote architecture suite detached pid=$RPID"
: >"$LOCAL_LIVE"
while true;do if ssh "${SSH[@]}" idex "test -f '$REMOTE_STATE.DONE'" >/dev/null 2>&1;then break;fi;N="$(wc -l <"$LOCAL_LIVE"|tr -d '[:space:]')";S=$((N+1));log "LIVE REMOTE LOG resume=$S";set +e;ssh "${SSH[@]}" idex "touch '$REMOTE_LOG'; tail -n +$S -F --pid='$RPID' '$REMOTE_LOG'"|tee -a "$LOCAL_LIVE";RC=${PIPESTATUS[0]};set -e;if ((RC==255));then log 'live SSH lost; detached suite continues';sleep 5;else sleep 1;fi;done
N="$(wc -l <"$LOCAL_LIVE"|tr -d '[:space:]')";S=$((N+1));ssh "${SSH[@]}" idex "sed -n '${S},\$p' '$REMOTE_LOG'" 2>/dev/null|tee -a "$LOCAL_LIVE"||true
mkdir -p "$LOCAL_EXPORT";retry scp "${SSH[@]}" "idex:$REMOTE_LOG" "$LOCAL_TERMINAL";for pair in "$REMOTE_SHARE|$LOCAL_SHARE" "$REMOTE_FULL|$LOCAL_FULL";do r="${pair%%|*}";l="${pair#*|}";ssh "${SSH[@]}" idex "test -f '$r'" >/dev/null 2>&1&&retry scp "${SSH[@]}" "idex:$r" "$l"||true;done
for f in ARCH_SWEEP_SUMMARY.txt ARCH_SWEEP_SUMMARY.csv CASE_STATUS.tsv SWEEP_DESIGN.txt TOPOLOGY.txt RAW_DPDK/summary.txt RAW_DPDK/status.txt;do if ssh "${SSH[@]}" idex "test -f '$RESULT_ROOT/$f'" >/dev/null 2>&1;then mkdir -p "$LOCAL_EXPORT/$(dirname "$f")";retry scp "${SSH[@]}" "idex:$RESULT_ROOT/$f" "$LOCAL_EXPORT/$f";fi;done
log 'AUTO-SCP COMPLETE';echo "TERMINAL_LOG=$LOCAL_TERMINAL";echo "LIVE_LOG=$LOCAL_LIVE";echo "SHARE_ARCHIVE=$LOCAL_SHARE";echo "FULL_ARCHIVE=$LOCAL_FULL";echo "SUMMARY_DIR=$LOCAL_EXPORT";[[ -f "$LOCAL_EXPORT/ARCH_SWEEP_SUMMARY.txt" ]]&&cat "$LOCAL_EXPORT/ARCH_SWEEP_SUMMARY.txt"||true
