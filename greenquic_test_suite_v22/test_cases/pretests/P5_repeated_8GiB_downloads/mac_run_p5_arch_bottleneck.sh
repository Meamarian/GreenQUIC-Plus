#!/usr/bin/env bash
set -Eeuo pipefail
BRANCH=performance2/p5-multicore
RUNS="${P5_ARCH_RUNS:-2}"; CONNS="${P5_ARCH_CONNECTIONS:-4}"; TAG="${P5_ARCH_TAG:-$(date +%Y%m%d_%H%M%S)}"
P5=/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads
RESULT_ROOT="$P5/matrix_results/P5_ARCH_BOTTLENECK_${CONNS}c_${RUNS}r_${TAG}"
REMOTE_RUNNER="/tmp/P5_ARCH_${TAG}.sh"; REMOTE_LOG="/root/P5_ARCH_${TAG}.log"; REMOTE_STATE="/tmp/P5_ARCH_${TAG}.state"
REMOTE_FULL="/root/P5_ARCH_FULL_${TAG}.tar.gz"; REMOTE_SHARE="/root/P5_ARCH_SHARE_${TAG}.tar.gz"
LOCAL_MAC="$HOME/Downloads/P5_ARCH_${TAG}.mac.log"; LOCAL_LIVE="$HOME/Downloads/P5_ARCH_${TAG}.remote-live.log"; LOCAL_TERM="$HOME/Downloads/P5_ARCH_${TAG}.terminal.log"
LOCAL_FULL="$HOME/Downloads/P5_ARCH_FULL_${TAG}.tar.gz"; LOCAL_SHARE="$HOME/Downloads/P5_ARCH_SHARE_${TAG}.tar.gz"; LOCAL_EXPORT="$HOME/Downloads/P5_ARCH_EXPORT_${TAG}"
SSH=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3)
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
retry(){ local rc; while true; do if "$@"; then return 0; else rc=$?; fi; if ((rc==255)); then log 'SSH/SCP lost; retrying in 5s'; sleep 5; else return "$rc"; fi; done; }
tiny(){ local q; printf -v q '%q' "$1"; retry ssh "${SSH[@]}" idex "ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman $q"; }
[[ "$RUNS" =~ ^[1-9][0-9]*$ && "$CONNS" =~ ^[2-9][0-9]*$ ]] || { echo 'ERROR invalid runs/connections' >&2; exit 2; }
if [[ "${1:-}" == --detach ]]; then
  nohup caffeinate -dimsu env P5_ARCH_RUNS="$RUNS" P5_ARCH_CONNECTIONS="$CONNS" P5_ARCH_TAG="$TAG" bash "$0" --foreground >"$LOCAL_MAC" 2>&1 </dev/null & pid=$!; disown "$pid" 2>/dev/null || true
  echo "STARTED P5 ARCH BOTTLENECK SWEEP PID=$pid"; echo "TAG=$TAG"; echo "MAC_LOG=$LOCAL_MAC"; echo "REMOTE_LIVE_LOG=$LOCAL_LIVE"; echo "FINAL_TERMINAL_LOG=$LOCAL_TERM"; echo "FULL_RESULTS=$LOCAL_FULL"; echo "SHARE_RESULTS=$LOCAL_SHARE"; echo '16 architecture cases A-P; only QUIC traffic failure fails a case; diagnostic/postprocess failures are preserved and later cases continue.'; exit 0
fi
[[ "${1:-}" == --foreground ]] && shift || true; [[ $# -eq 0 ]] || { echo "ERROR unknown args $*" >&2; exit 2; }
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"; REPO="$(git -C "$HERE" rev-parse --show-toplevel)"; SHA="$(git -C "$REPO" rev-parse HEAD)"; CUR="$(git -C "$REPO" branch --show-current)"
[[ "$CUR" == "$BRANCH" ]] || { echo "ERROR branch=$CUR expected=$BRANCH" >&2; exit 2; }
[[ -z "$(git -C "$REPO" status --porcelain --untracked-files=no)" ]] || { echo 'ERROR tracked local changes present' >&2; exit 2; }
BASE_CLEAN="$HERE/safe_cleanup_greenquic_processes.py"; BN_CLEAN="$HERE/safe_cleanup_p5_bottleneck_processes.py"; [[ -f "$BASE_CLEAN" && -f "$BN_CLEAN" ]] || { echo 'ERROR cleanup helper missing' >&2; exit 2; }

# FIRST REMOTE ACTION: ancestry-safe stale-process cleanup on both endpoints.
CDIR="/tmp/gq_arch_clean_${TAG}"; log 'installing safe cleaner on IDEX + Tinyman'; retry ssh "${SSH[@]}" idex "mkdir -p '$CDIR'"; retry scp "${SSH[@]}" "$BASE_CLEAN" "$BN_CLEAN" "idex:$CDIR/"; retry ssh "${SSH[@]}" idex "ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman 'mkdir -p $CDIR'; scp -q '$CDIR/'*.py root@tinyman:'$CDIR/'"
retry ssh "${SSH[@]}" idex "python3 '$CDIR/safe_cleanup_p5_bottleneck_processes.py'"
tiny "python3 '$CDIR/safe_cleanup_p5_bottleneck_processes.py'"
retry ssh "${SSH[@]}" idex "python3 '$CDIR/safe_cleanup_p5_bottleneck_processes.py' --check"
tiny "python3 '$CDIR/safe_cleanup_p5_bottleneck_processes.py' --check"
log 'initial safe cleanup PASS on IDEX + Tinyman'

# Install perf before any build/preflight/traffic. Debian trixie provides the
# perf command through the linux-perf package. Retry transient apt failures,
# then fail closed if perf is still unavailable.
PERF_INSTALL='set -Eeuo pipefail; export DEBIAN_FRONTEND=noninteractive; if ! command -v perf >/dev/null 2>&1; then for attempt in 1 2 3; do echo "[P5-ARCH-PERF] host=$(hostname -s) apt_attempt=$attempt"; if apt-get update && apt-get install -y --no-install-recommends linux-perf; then break; fi; if [ "$attempt" -ge 3 ]; then echo "ERROR: failed to install linux-perf after 3 attempts" >&2; exit 2; fi; sleep 5; done; fi; command -v perf >/dev/null 2>&1 || { echo "ERROR: perf command unavailable after linux-perf install" >&2; exit 2; }; echo "[P5-ARCH-PERF] host=$(hostname -s) path=$(command -v perf) version=$(perf --version)"'
log 'ensuring linux-perf is installed on IDEX'
retry ssh "${SSH[@]}" idex "$PERF_INSTALL"
log 'ensuring linux-perf is installed on Tinyman'
tiny "$PERF_INSTALL"
log 'linux-perf PASS on IDEX + Tinyman'

# Exact Mac commit -> IDEX -> Tinyman.
BUNDLE="$(mktemp "${TMPDIR:-/tmp}/gq_arch.XXXXXX.bundle")"; RB="/tmp/gq_arch_${TAG}.bundle"; trap 'rm -f "$BUNDLE"' EXIT
git -C "$REPO" bundle create "$BUNDLE" "$BRANCH"; retry scp "${SSH[@]}" "$BUNDLE" "idex:$RB"; retry ssh "${SSH[@]}" idex "cd /root/mohsen && git reset --hard && git fetch '$RB' '$BRANCH' && git checkout -B '$BRANCH' FETCH_HEAD && git reset --hard FETCH_HEAD"; retry ssh "${SSH[@]}" idex "scp -q '$RB' root@tinyman:'$RB'"; tiny "cd /root/mohsen && git reset --hard && git fetch '$RB' '$BRANCH' && git checkout -B '$BRANCH' FETCH_HEAD && git reset --hard FETCH_HEAD"
ISHA="$(retry ssh "${SSH[@]}" idex 'cd /root/mohsen && git rev-parse HEAD')"; TSHA="$(tiny 'cd /root/mohsen && git rev-parse HEAD')"; [[ "$ISHA" == "$SHA" && "$TSHA" == "$SHA" ]] || { echo "ERROR SHA local=$SHA idex=$ISHA tiny=$TSHA" >&2; exit 2; }; log "synced both endpoints @ $SHA"

# Traffic-free preflight. Validate the exact P5-local runtime helper on a temp copy,
# including AFFINITIZE insertion and the OFF all-CPU max-frequency transform.
retry ssh "${SSH[@]}" idex "cd '$P5' && for f in ./run_p5_arch_bottleneck_sweep.sh ./run_p5_arch_case_diag.sh ./run_p5_arch_off_case.sh ./build_p5_arch_profile.sh; do bash -n \$f || exit \$?; done && python3 -m py_compile ./enable_p5_arch_runtime_config.py ./thread_topology_sampler.py ./summarize_p5_arch_sweep.py ./cpu_busy_sampler.py ./analyze_p5_bottleneck_case.py ./quic_cpu_activity_sampler.py && python3 ./enable_p5_arch_runtime_config.py --self-test && t=\$(mktemp) && cp ./gq_common_p5.sh \$t && python3 ./enable_p5_arch_runtime_config.py \$t && grep -Fq GREENQUIC-P5-ARCH-AFFINITIZE-RUNTIME-V1 \$t && grep -Fq GREENQUIC-P5-ARCH-OFF-ALL-CPU-MAX-V1 \$t && rm -f \$t && bash ./run_p5_arch_off_case.sh --self-test"
COUNT="$(retry ssh "${SSH[@]}" idex "cd '$P5' && grep -Ec '^run_case [A-P]_' ./run_p5_arch_bottleneck_sweep.sh")"; [[ "$COUNT" == 16 ]] || { echo "ERROR expected 16 A-P cases, got $COUNT" >&2; exit 2; }; log 'architecture sweep static preflight PASS: 16 cases + exact runtime overlay'

TMP="$(mktemp "${TMPDIR:-/tmp}/gq_arch_remote.XXXXXX.sh")"
cat >"$TMP" <<'REMOTE'
#!/usr/bin/env bash
set +e
P5="$1"; RUNS="$2"; CONNS="$3"; TAG="$4"; OUT="$5"; STATE="$6"; FULL="$7"; SHARE="$8"
rm -f "$STATE.DONE" "$STATE.RC" "$FULL" "$SHARE"; echo "P5 ARCH REMOTE START tag=$TAG commit=$(git -C /root/mohsen rev-parse HEAD 2>/dev/null)"
cd "$P5" || { echo 98 >"$STATE.RC"; touch "$STATE.DONE"; exit 0; }
env P5_ARCH_RUNS="$RUNS" P5_ARCH_CONNECTIONS="$CONNS" P5_ARCH_TAG="$TAG" P5_ARCH_OUTPUT_ROOT="$OUT" bash ./run_p5_arch_bottleneck_sweep.sh; RC=$?; echo "$RC" >"$STATE.RC"; echo "P5 ARCH SWEEP PROCESS RC=$RC"
if [[ -d "$OUT" ]]; then tar -C "$(dirname "$OUT")" -czf "$FULL" "$(basename "$OUT")"; tar -C "$(dirname "$OUT")" --exclude='*/runs/*' -czf "$SHARE" "$(basename "$OUT")"; fi
touch "$STATE.DONE"; echo 'P5 ARCH REMOTE COMPLETE'; exit 0
REMOTE
bash -n "$TMP"; retry scp "${SSH[@]}" "$TMP" "idex:$REMOTE_RUNNER"; rm -f "$TMP"
LAUNCH="$(retry ssh "${SSH[@]}" idex "chmod 0700 '$REMOTE_RUNNER'; nohup setsid bash '$REMOTE_RUNNER' '$P5' '$RUNS' '$CONNS' '$TAG' '$RESULT_ROOT' '$REMOTE_STATE' '$REMOTE_FULL' '$REMOTE_SHARE' >'$REMOTE_LOG' 2>&1 </dev/null & echo REMOTE_PID=\$!")"; echo "$LAUNCH"; RPID="$(echo "$LAUNCH"|sed -n 's/^REMOTE_PID=//p'|tail -1)"; [[ "$RPID" =~ ^[0-9]+$ ]] || { echo 'ERROR remote pid' >&2; exit 2; }
: >"$LOCAL_LIVE"; while ! ssh "${SSH[@]}" idex "test -f '$REMOTE_STATE.DONE'" >/dev/null 2>&1; do L="$(wc -l <"$LOCAL_LIVE"|tr -d ' ')"; S=$((L+1)); set +e; ssh "${SSH[@]}" idex "touch '$REMOTE_LOG'; tail -n +$S -F --pid='$RPID' '$REMOTE_LOG'" | tee -a "$LOCAL_LIVE"; rc=${PIPESTATUS[0]}; set -e; ((rc==255)) && sleep 5 || sleep 1; done
L="$(wc -l <"$LOCAL_LIVE"|tr -d ' ')"; S=$((L+1)); ssh "${SSH[@]}" idex "sed -n '${S},\$p' '$REMOTE_LOG'" 2>/dev/null | tee -a "$LOCAL_LIVE" || true
mkdir -p "$LOCAL_EXPORT"; retry scp "${SSH[@]}" "idex:$REMOTE_LOG" "$LOCAL_TERM"; ssh "${SSH[@]}" idex "test -f '$REMOTE_SHARE'" >/dev/null 2>&1 && retry scp "${SSH[@]}" "idex:$REMOTE_SHARE" "$LOCAL_SHARE" || true; ssh "${SSH[@]}" idex "test -f '$REMOTE_FULL'" >/dev/null 2>&1 && retry scp "${SSH[@]}" "idex:$REMOTE_FULL" "$LOCAL_FULL" || true
for f in ARCH_BOTTLENECK_SUMMARY.txt ARCH_BOTTLENECK_SUMMARY.csv CASE_STATUS.tsv SWEEP_DESIGN.txt; do ssh "${SSH[@]}" idex "test -f '$RESULT_ROOT/$f'" >/dev/null 2>&1 && retry scp "${SSH[@]}" "idex:$RESULT_ROOT/$f" "$LOCAL_EXPORT/$f" || true; done
ssh "${SSH[@]}" idex "test -f '$REMOTE_STATE.RC'" >/dev/null 2>&1 && retry scp "${SSH[@]}" "idex:$REMOTE_STATE.RC" "$LOCAL_EXPORT/sweep_process_rc.txt" || true
log 'AUTO-SCP COMPLETE'; echo "TERMINAL_LOG=$LOCAL_TERM"; echo "LIVE_LOG=$LOCAL_LIVE"; echo "SHARE_ARCHIVE=$LOCAL_SHARE"; echo "FULL_ARCHIVE=$LOCAL_FULL"; echo "SUMMARY_DIR=$LOCAL_EXPORT"; [[ -f "$LOCAL_EXPORT/ARCH_BOTTLENECK_SUMMARY.txt" ]] && cat "$LOCAL_EXPORT/ARCH_BOTTLENECK_SUMMARY.txt" || true
