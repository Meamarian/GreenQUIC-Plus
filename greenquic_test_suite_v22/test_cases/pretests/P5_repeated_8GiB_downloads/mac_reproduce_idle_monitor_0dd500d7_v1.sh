#!/usr/bin/env bash
set -Eeuo pipefail

# Reproduce the archived idle_monitor_normal_20260816_000131 experiment.
# Measurement code is pinned to the exact archived GreenQUIC commit on BOTH
# endpoints. This Mac-side orchestrator itself may live on a newer branch; it
# never checks out or resets the user's Mac working tree.

TARGET_SHA="0dd500d7d91e15a258b84b5553561f43c74071de"
TARGET_BRANCH="performance/p5-max-goodput"
RUNS="${P5_REPRO_RUNS:-6}"
DOWNLOADS="${P5_REPRO_DOWNLOADS:-5}"
SEED="${P5_REPRO_SEED:-20260806}"
TAG="${P5_REPRO_TAG:-$(date +%Y%m%d_%H%M%S)}"

REPO_ROOT="${GREENQUIC_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
[[ -n "$REPO_ROOT" && -d "$REPO_ROOT/.git" ]] || {
    echo "ERROR: set GREENQUIC_REPO or run from a GreenQUIC checkout" >&2
    exit 2
}

[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: P5_REPRO_RUNS must be positive" >&2; exit 2; }
[[ "$DOWNLOADS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: P5_REPRO_DOWNLOADS must be positive" >&2; exit 2; }
[[ "$SEED" =~ ^[0-9]+$ ]] || { echo "ERROR: P5_REPRO_SEED must be an integer" >&2; exit 2; }

P5_REL="greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
P5="/root/mohsen/$P5_REL"
BIN="/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop"
SERVER_BIN="/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinteropserver"
OUT="$P5/matrix_results/idle_monitor_repro_0dd500d7_${RUNS}r_${DOWNLOADS}d_${TAG}"
REMOTE_LOG="/root/P5_REPRO_0dd500d7_${TAG}.log"
REMOTE_SCRIPT="/tmp/P5_REPRO_0dd500d7_${TAG}.sh"
REMOTE_EXPORT="/tmp/P5_REPRO_0dd500d7_EXPORT_${TAG}"
LOCAL_EXPORT="$HOME/Downloads/P5_REPRO_0dd500d7_EXPORT_${TAG}"
BUNDLE="${TMPDIR:-/tmp}/GreenQUIC_REPRO_0dd500d7_${TAG}.bundle"
REMOTE_BUNDLE="/tmp/GreenQUIC_REPRO_0dd500d7_${TAG}.bundle"
REF="refs/heads/__p5_repro_0dd500d7_${TAG}_$$"
LOCAL_BUILD_I="$HOME/Downloads/P5_REPRO_0dd500d7_${TAG}.build_idex.log"
LOCAL_BUILD_T="$HOME/Downloads/P5_REPRO_0dd500d7_${TAG}.build_tinyman.log"
LOCK="$HOME/Downloads/.greenquic_p5_repro_0dd500d7.lock"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3)

PERF_ENV=(
    P5_BUILD_REUSE=1
    P5_SUPER_CACHE=128
    P5_SUPER_RX_BURST=32
    P5_SUPER_TX_BURST=16
    P5_SUPER_RING_SIZE=4096
    P5_SUPER_RING_SYNC=legacy
    P5_SUPER_DRAIN_BURSTS=2
    P5_SUPER_DRAIN_THRESHOLD=0
    P5_SUPER_MTU=0
    P5_SUPER_SKIP_OFF_RINGCOUNT=0
    P5_SUPER_DEBUG_COUNTERS=1
    P5_SUPER_TRANSFER_WINDOW=1
    P5_SUPER_TRACE_RINGCOUNT=1
    P5_SUPER_TX_META=mbuf
    P5_SUPER_RX_META=mbuf
    P5_SUPER_TX_LOCK_MODE=single_owner
    P5_SUPER_CAP_DIAG=1
)

log(){ printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

if [[ "${1:-}" == "--detach" ]]; then
    shift
    LOG="$HOME/Downloads/P5_REPRO_0dd500d7_${TAG}.mac.log"
    PIDFILE="$HOME/Downloads/P5_REPRO_0dd500d7_${TAG}.mac.pid"
    nohup caffeinate -dimsu env \
        GREENQUIC_REPO="$REPO_ROOT" \
        P5_REPRO_TAG="$TAG" \
        P5_REPRO_RUNS="$RUNS" \
        P5_REPRO_DOWNLOADS="$DOWNLOADS" \
        P5_REPRO_SEED="$SEED" \
        bash "$0" --foreground "$@" >"$LOG" 2>&1 </dev/null &
    pid=$!
    echo "$pid" >"$PIDFILE"
    disown "$pid" 2>/dev/null || true
    echo "STARTED historical P5 Idle Monitor reproduction PID=$pid"
    echo "TARGET_SHA=$TARGET_SHA"
    echo "RUNS=$RUNS DOWNLOADS=$DOWNLOADS SEED=$SEED"
    echo "LOG=$LOG"
    echo "FINAL_EXPORT=$LOCAL_EXPORT"
    exit 0
fi
[[ "${1:-}" == "--foreground" ]] && shift || true
[[ $# -eq 0 ]] || { echo "ERROR: unknown arguments: $*" >&2; exit 2; }

if [[ -d "$LOCK" ]]; then
    old="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
        echo "ERROR: another historical P5 reproduction is active PID=$old" >&2
        exit 70
    fi
    rm -rf "$LOCK"
fi
mkdir -p "$LOCK"
echo $$ >"$LOCK/pid"

cleanup_local(){
    git -C "$REPO_ROOT" update-ref -d "$REF" 2>/dev/null || true
    rm -f "$BUNDLE"
    rm -rf "$LOCK"
}
trap cleanup_local EXIT INT TERM

# Refuse to interfere with a real test/build. Once this passes, remove only
# stale high-rate measurement samplers and stale DPDK runtime directories.
check_and_clean_host_script='set -euo pipefail
active=()
recorders=()
for proc in /proc/[0-9]*; do
  pid="${proc##*/}"
  [[ "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
  cmd="$(tr "\\0" " " <"$proc/cmdline" 2>/dev/null || true)"
  cwd="$(readlink -f "$proc/cwd" 2>/dev/null || true)"
  [[ -n "$cmd" ]] || continue
  case "$cmd $cwd" in
    *quicinterop*|*run_matrix_with_sheet*|*run_matrix_from_idex*|*run_client.sh*|*run_server.sh*|*build_p5_*|*P5_P2_FINAL_REMOTE*|*P5_REPRO_0dd500d7*|*build-greenquic-p5*gmake*|*build-greenquic-p5*cmake*) active+=("$pid") ;;
  esac
  case "$cmd" in
    *gq_rapl_msr_sampler*|*frequency_sampler.py*|*gq_cstate_trace*|*power_trace.py*) recorders+=("$pid") ;;
  esac
done
if ((${#active[@]})); then
  echo "ERROR: active GreenQUIC/P5 workload or build on $(hostname -s): ${active[*]}" >&2
  for pid in "${active[@]}"; do tr "\\0" " " <"/proc/$pid/cmdline" 2>/dev/null || true; echo; done >&2
  exit 70
fi
if fuser /var/run/dpdk/rte/config >/dev/null 2>&1; then
  echo "ERROR: DPDK runtime is owned by a live process on $(hostname -s); refusing to interfere" >&2
  fuser -v /var/run/dpdk/rte/config >&2 || true
  exit 71
fi
if ((${#recorders[@]})); then
  echo "STALE_RECORDER_CLEANUP host=$(hostname -s) pids=${recorders[*]}"
  kill -TERM "${recorders[@]}" 2>/dev/null || true
  sleep 0.5
  for pid in "${recorders[@]}"; do kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true; done
fi
rm -rf /var/run/dpdk/rte
rm -f /tmp/p5_start_gate_* /tmp/p5_aligned_client_*
echo "CLEAN_PREFLIGHT host=$(hostname -s) PASS"'

log "checking idex is idle"
ssh "${SSH_OPTS[@]}" idex "bash -c $(printf '%q' "$check_and_clean_host_script")"
log "checking tinyman is idle"
ssh "${SSH_OPTS[@]}" idex "ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman bash -c $(printf '%q' "$check_and_clean_host_script")"

# Fetch the old branch only to ensure the archived SHA object is present. Do not
# checkout/reset anything in the user's current Mac working tree.
cd "$REPO_ROOT"
log "fetching historical branch; Mac working tree remains untouched"
git fetch origin "$TARGET_BRANCH"
git cat-file -e "$TARGET_SHA^{commit}" || {
    echo "ERROR: archived commit $TARGET_SHA is not available after fetch" >&2
    exit 72
}
if ! git merge-base --is-ancestor "$TARGET_SHA" "origin/$TARGET_BRANCH"; then
    echo "ERROR: archived commit is no longer an ancestor of origin/$TARGET_BRANCH" >&2
    exit 73
fi

git update-ref "$REF" "$TARGET_SHA"
rm -f "$BUNDLE"
git bundle create "$BUNDLE" "$REF"
git update-ref -d "$REF"
ls -lh "$BUNDLE"

scp "${SSH_OPTS[@]}" "$BUNDLE" "idex:$REMOTE_BUNDLE"
ssh "${SSH_OPTS[@]}" idex "scp -o BatchMode=yes -o ConnectTimeout=15 '$REMOTE_BUNDLE' root@tinyman:'$REMOTE_BUNDLE'"

sync_one='set -euo pipefail
cd /root/mohsen
git reset --hard
git fetch "$BUNDLE" "$REF"
git checkout --detach FETCH_HEAD
test "$(git rev-parse HEAD)" = "$EXPECTED"
printf "HOST=%s HEAD=%s SUBJECT=%s\\n" "$(hostname -s)" "$(git rev-parse HEAD)" "$(git log -1 --format=%s)"'

log "pinning idex to archived commit"
ssh "${SSH_OPTS[@]}" idex "EXPECTED='$TARGET_SHA' BUNDLE='$REMOTE_BUNDLE' REF='$REF' bash -c $(printf '%q' "$sync_one")"
log "pinning tinyman to archived commit"
ssh "${SSH_OPTS[@]}" idex "ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman \"EXPECTED='$TARGET_SHA' BUNDLE='$REMOTE_BUNDLE' REF='$REF' bash -c $(printf '%q' "$sync_one")\""

# Clean disposable P5 source/build trees to prevent newer D1/D2+ or performance2
# transforms from leaking into the historical binary. The old build script still
# receives P5_BUILD_REUSE=1; with no disposable tree it deterministically creates
# the clean historical source and then applies the archived SUPER-PERF transform.
log "removing disposable P5 source/build trees before historical build"
ssh "${SSH_OPTS[@]}" idex 'rm -rf /root/mohsen/msquic-p5-source /root/mohsen/msquic/build-greenquic-p5'
ssh "${SSH_OPTS[@]}" idex "ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman 'rm -rf /root/mohsen/msquic-p5-source /root/mohsen/msquic/build-greenquic-p5'"

perf_words=""
for kv in "${PERF_ENV[@]}"; do printf -v q '%q' "$kv"; perf_words+=" $q"; done

log "building archived P5 SUPER-PERF binary on idex + tinyman"
set +e
ssh "${SSH_OPTS[@]}" idex "cd '$P5' && env$perf_words bash ./build_p5_super_performance.sh" >"$LOCAL_BUILD_I" 2>&1 & p1=$!
ssh "${SSH_OPTS[@]}" idex "ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman \"cd '$P5' && env$perf_words bash ./build_p5_super_performance.sh\"" >"$LOCAL_BUILD_T" 2>&1 & p2=$!
wait "$p1"; brc1=$?
wait "$p2"; brc2=$?
set -e
if [[ "$brc1" -ne 0 || "$brc2" -ne 0 ]]; then
    echo "ERROR: historical build failed idex=$brc1 tinyman=$brc2" >&2
    echo "--- idex build tail ---" >&2; tail -100 "$LOCAL_BUILD_I" >&2 || true
    echo "--- tinyman build tail ---" >&2; tail -100 "$LOCAL_BUILD_T" >&2 || true
    exit 74
fi

ssh "${SSH_OPTS[@]}" idex "test \"\$(git -C /root/mohsen rev-parse HEAD)\" = '$TARGET_SHA' && grep -aFq 'GREENQUIC-P5-SUPER-PERF-V2' '$BIN' && grep -aFq 'GREENQUIC-P5-SUPER-PERF-V2' '$SERVER_BIN'"
ssh "${SSH_OPTS[@]}" idex "ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman \"test \\\"\\\$(git -C /root/mohsen rev-parse HEAD)\\\" = '$TARGET_SHA' && grep -aFq 'GREENQUIC-P5-SUPER-PERF-V2' '$BIN' && grep -aFq 'GREENQUIC-P5-SUPER-PERF-V2' '$SERVER_BIN'\""
log "historical build + marker verification PASS"

cat >"${TMPDIR:-/tmp}/P5_REPRO_REMOTE_${TAG}.sh" <<'REMOTE'
#!/usr/bin/env bash
set +e
TAG="$1"; TARGET_SHA="$2"; RUNS="$3"; DOWNLOADS="$4"; SEED="$5"; OUT="$6"; EX="$7"
P5=/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads
BIN=/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop
mkdir -p "$EX"
rm -f "$EX/DONE" "$EX/FAILED"
{
  echo "TARGET_SHA=$TARGET_SHA"
  echo "IDEX_HEAD=$(git -C /root/mohsen rev-parse HEAD 2>/dev/null)"
  echo "TINYMAN_HEAD=$(ssh root@tinyman 'git -C /root/mohsen rev-parse HEAD' 2>/dev/null)"
  echo "RUNS=$RUNS"
  echo "DOWNLOADS=$DOWNLOADS"
  echo "SEED=$SEED"
  echo "PROFILE=idle_monitor_normal"
  echo "GQ_IDLE_MODE_OVERRIDE=monitor"
  echo "GQ_IDLE_FALLBACK_OVERRIDE=short"
  echo "BUILD=cache128 RX32 TX16 ring4096 drain2 legacy-sync TX/RX-mbuf single-owner"
} >"$EX/reproduction_metadata.txt"

cd "$P5" || exit 90
bash ./run_matrix_with_sheet.sh \
    --chart-style both \
    --client-host tinyman \
    --client-dir "$P5" \
    --client-bin "$BIN" \
    --downloads "$DOWNLOADS" \
    --gap-seconds 5 \
    --server-cooldown-seconds 5 \
    --between-tests-seconds 0 \
    --cstate-cpu 19 \
    --runs "$RUNS" \
    --mode-order balanced \
    --seed "$SEED" \
    --output-dir "$OUT" \
    --env ENABLE_RECORD=1 \
    --env GQ_LOG_LEVEL=0 \
    --env GQ_IDLE_MODE_OVERRIDE=monitor \
    --env GQ_IDLE_FALLBACK_OVERRIDE=short
rc=$?
echo "$rc" >"$EX/test_rc.txt"

if [[ -d "$OUT" ]]; then
    (cd "$(dirname "$OUT")" && zip -qr "$EX/$(basename "$OUT").zip" "$(basename "$OUT")")
fi
printf '%s\n' "$OUT" >"$EX/source_path.txt"
cp -f "$0" "$EX/remote_runner.sh" 2>/dev/null || true
cd "$EX" || exit 91
find . -maxdepth 1 -type f ! -name SHA256SUMS ! -name DONE ! -name FAILED -print0 | sort -z | xargs -0 shasum -a 256 >SHA256SUMS
if [[ "$rc" -eq 0 ]]; then
    touch DONE
else
    touch FAILED
    touch DONE
fi
exit "$rc"
REMOTE
chmod 0700 "${TMPDIR:-/tmp}/P5_REPRO_REMOTE_${TAG}.sh"
scp "${SSH_OPTS[@]}" "${TMPDIR:-/tmp}/P5_REPRO_REMOTE_${TAG}.sh" "idex:$REMOTE_SCRIPT"
rm -f "${TMPDIR:-/tmp}/P5_REPRO_REMOTE_${TAG}.sh"

log "launching archived Idle Monitor: ${RUNS} runs x ${DOWNLOADS} downloads x 3 modes"
ssh "${SSH_OPTS[@]}" idex "rm -rf '$REMOTE_EXPORT'; mkdir -p '$REMOTE_EXPORT'; nohup setsid bash '$REMOTE_SCRIPT' '$TAG' '$TARGET_SHA' '$RUNS' '$DOWNLOADS' '$SEED' '$OUT' '$REMOTE_EXPORT' >'$REMOTE_LOG' 2>&1 </dev/null & echo \$! >'/tmp/P5_REPRO_0dd500d7_${TAG}.pid'; cat '/tmp/P5_REPRO_0dd500d7_${TAG}.pid'"

while true; do
    set +e
    ssh "${SSH_OPTS[@]}" idex "test -f '$REMOTE_EXPORT/DONE'"
    rc=$?
    set -e
    if [[ "$rc" -eq 0 ]]; then break; fi
    if [[ "$rc" -eq 255 ]]; then
        log "SSH transport unavailable; remote detached run continues; retrying in 30 s"
    else
        log "historical P5 run still active"
    fi
    sleep 30
done

mkdir -p "$LOCAL_EXPORT"
log "SCP result export to Mac"
scp "${SSH_OPTS[@]}" -r "idex:$REMOTE_EXPORT/." "$LOCAL_EXPORT/"
scp "${SSH_OPTS[@]}" "idex:$REMOTE_LOG" "$LOCAL_EXPORT/remote.log" || true
cp "$LOCAL_BUILD_I" "$LOCAL_EXPORT/build_idex.log"
cp "$LOCAL_BUILD_T" "$LOCAL_EXPORT/build_tinyman.log"

(
    cd "$LOCAL_EXPORT"
    if [[ -s SHA256SUMS ]]; then shasum -a 256 -c SHA256SUMS; fi
)

TEST_RC="$(cat "$LOCAL_EXPORT/test_rc.txt" 2>/dev/null || echo 99)"
echo
printf '%s\n' \
    "======================================================================" \
    "HISTORICAL P5 IDLE MONITOR REPRODUCTION COMPLETE" \
    "TARGET_SHA=$TARGET_SHA" \
    "RUNS=$RUNS DOWNLOADS=$DOWNLOADS SEED=$SEED" \
    "IDLE=monitor FALLBACK=short" \
    "TEST_RC=$TEST_RC" \
    "MAC_EXPORT=$LOCAL_EXPORT" \
    "REMOTE_RESULT=$OUT" \
    "REMOTE_LOG=$REMOTE_LOG" \
    "======================================================================"

[[ "$TEST_RC" == 0 ]]
