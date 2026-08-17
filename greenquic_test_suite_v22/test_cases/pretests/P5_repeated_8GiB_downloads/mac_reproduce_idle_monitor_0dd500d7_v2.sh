#!/usr/bin/env bash
set -Eeuo pipefail

# Exact reproduction of archived idle_monitor_normal_20260816_000131.
# The measured GreenQUIC code is pinned to TARGET_SHA on both endpoints.
# This controller DOES NOT checkout/reset the Mac working tree.

TARGET_SHA="0dd500d7d91e15a258b84b5553561f43c74071de"
TARGET_BRANCH="performance/p5-max-goodput"
RUNS="${P5_REPRO_RUNS:-6}"
DOWNLOADS="${P5_REPRO_DOWNLOADS:-5}"
SEED="${P5_REPRO_SEED:-20260806}"
TAG="${P5_REPRO_TAG:-$(date +%Y%m%d_%H%M%S)}"

REPO_ROOT="${GREENQUIC_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
[[ -n "$REPO_ROOT" && -d "$REPO_ROOT/.git" ]] || { echo "ERROR: run from GreenQUIC or set GREENQUIC_REPO" >&2; exit 2; }
[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: invalid P5_REPRO_RUNS=$RUNS" >&2; exit 2; }
[[ "$DOWNLOADS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: invalid P5_REPRO_DOWNLOADS=$DOWNLOADS" >&2; exit 2; }
[[ "$SEED" =~ ^[0-9]+$ ]] || { echo "ERROR: invalid P5_REPRO_SEED=$SEED" >&2; exit 2; }

P5=/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads
BIN=/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop
SERVER_BIN=/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinteropserver
OUT="$P5/matrix_results/idle_monitor_normal_REPRO_${RUNS}r_${DOWNLOADS}d_${TAG}"
REMOTE_LOG="/root/P5_REPRO_0dd500d7_${TAG}.log"
REMOTE_RUNNER="/tmp/P5_REPRO_0dd500d7_${TAG}.runner.sh"
REMOTE_PIDFILE="/tmp/P5_REPRO_0dd500d7_${TAG}.pid"
REMOTE_EXPORT="/tmp/P5_REPRO_0dd500d7_EXPORT_${TAG}"
LOCAL_EXPORT="$HOME/Downloads/P5_REPRO_0dd500d7_EXPORT_${TAG}"
BUNDLE="${TMPDIR:-/tmp}/GreenQUIC_REPRO_0dd500d7_${TAG}.bundle"
REMOTE_BUNDLE="/tmp/GreenQUIC_REPRO_0dd500d7_${TAG}.bundle"
TMP_REF="refs/heads/__p5_repro_0dd500d7_${TAG}_$$"
BUILD_I="$HOME/Downloads/P5_REPRO_0dd500d7_${TAG}.build_idex.log"
BUILD_T="$HOME/Downloads/P5_REPRO_0dd500d7_${TAG}.build_tinyman.log"
LOCK="$HOME/Downloads/.greenquic_p5_repro_0dd500d7.lock"
SSH=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3)

log(){ printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

if [[ "${1:-}" == --detach ]]; then
    shift
    MAC_LOG="$HOME/Downloads/P5_REPRO_0dd500d7_${TAG}.mac.log"
    MAC_PID="$HOME/Downloads/P5_REPRO_0dd500d7_${TAG}.mac.pid"
    nohup caffeinate -dimsu env \
        GREENQUIC_REPO="$REPO_ROOT" \
        P5_REPRO_TAG="$TAG" P5_REPRO_RUNS="$RUNS" P5_REPRO_DOWNLOADS="$DOWNLOADS" P5_REPRO_SEED="$SEED" \
        bash "$0" --foreground "$@" >"$MAC_LOG" 2>&1 </dev/null &
    pid=$!
    echo "$pid" >"$MAC_PID"
    disown "$pid" 2>/dev/null || true
    echo "STARTED P5 historical Idle Monitor reproduction"
    echo "PID=$pid"
    echo "TARGET_SHA=$TARGET_SHA"
    echo "RUNS=$RUNS DOWNLOADS=$DOWNLOADS SEED=$SEED"
    echo "LOG=$MAC_LOG"
    echo "FINAL_EXPORT=$LOCAL_EXPORT"
    exit 0
fi
[[ "${1:-}" == --foreground ]] && shift || true
[[ $# -eq 0 ]] || { echo "ERROR: unknown arguments: $*" >&2; exit 2; }

if [[ -d "$LOCK" ]]; then
    old="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
        echo "ERROR: another historical reproduction controller is running PID=$old" >&2
        exit 70
    fi
    rm -rf "$LOCK"
fi
mkdir -p "$LOCK"; echo $$ >"$LOCK/pid"
cleanup(){ git -C "$REPO_ROOT" update-ref -d "$TMP_REF" 2>/dev/null || true; rm -f "$BUNDLE"; rm -rf "$LOCK"; }
trap cleanup EXIT INT TERM

# Refuse to touch either endpoint if a real P5/GreenQUIC test or build is active.
preflight_host(){
    local host="$1"
    if [[ "$host" == idex ]]; then
        ssh "${SSH[@]}" idex 'bash -s' <<'REMOTE'
set -euo pipefail
active=()
recorders=()
for proc in /proc/[0-9]*; do
    pid="${proc##*/}"
    [[ "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
    cmd="$(tr '\0' ' ' <"$proc/cmdline" 2>/dev/null || true)"
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
    echo "ERROR: active P5/GreenQUIC workload/build on $(hostname -s): ${active[*]}" >&2
    for pid in "${active[@]}"; do tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true; echo; done >&2
    exit 70
fi
if fuser /var/run/dpdk/rte/config >/dev/null 2>&1; then
    echo "ERROR: DPDK runtime is owned by a live process on $(hostname -s)" >&2
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
echo "CLEAN_PREFLIGHT host=$(hostname -s) PASS"
REMOTE
    else
        ssh "${SSH[@]}" idex "ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman 'bash -s'" <<'REMOTE'
set -euo pipefail
active=()
recorders=()
for proc in /proc/[0-9]*; do
    pid="${proc##*/}"
    [[ "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
    cmd="$(tr '\0' ' ' <"$proc/cmdline" 2>/dev/null || true)"
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
    echo "ERROR: active P5/GreenQUIC workload/build on $(hostname -s): ${active[*]}" >&2
    for pid in "${active[@]}"; do tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true; echo; done >&2
    exit 70
fi
if fuser /var/run/dpdk/rte/config >/dev/null 2>&1; then
    echo "ERROR: DPDK runtime is owned by a live process on $(hostname -s)" >&2
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
echo "CLEAN_PREFLIGHT host=$(hostname -s) PASS"
REMOTE
    fi
}

log "safe preflight: idex"
preflight_host idex
log "safe preflight: tinyman"
preflight_host tinyman

# Fetch only; never checkout/reset the current Mac worktree.
cd "$REPO_ROOT"
log "fetching archived branch object (Mac worktree is unchanged)"
git fetch origin "$TARGET_BRANCH"
git cat-file -e "$TARGET_SHA^{commit}"
git merge-base --is-ancestor "$TARGET_SHA" "origin/$TARGET_BRANCH" || {
    echo "ERROR: $TARGET_SHA is not an ancestor of origin/$TARGET_BRANCH" >&2
    exit 72
}

git update-ref "$TMP_REF" "$TARGET_SHA"
rm -f "$BUNDLE"
git bundle create "$BUNDLE" "$TMP_REF"
git update-ref -d "$TMP_REF"

log "copying exact archived commit bundle to idex + tinyman"
scp "${SSH[@]}" "$BUNDLE" "idex:$REMOTE_BUNDLE"
ssh "${SSH[@]}" idex "scp -o BatchMode=yes -o ConnectTimeout=15 '$REMOTE_BUNDLE' root@tinyman:'$REMOTE_BUNDLE'"

log "pinning idex to $TARGET_SHA"
ssh "${SSH[@]}" idex "cd /root/mohsen && git reset --hard && git fetch '$REMOTE_BUNDLE' '$TMP_REF' && git checkout --detach FETCH_HEAD"
log "pinning tinyman to $TARGET_SHA"
ssh "${SSH[@]}" idex "ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman \"cd /root/mohsen && git reset --hard && git fetch '$REMOTE_BUNDLE' '$TMP_REF' && git checkout --detach FETCH_HEAD\""

IDEX_SHA="$(ssh "${SSH[@]}" idex 'git -C /root/mohsen rev-parse HEAD')"
TINY_SHA="$(ssh "${SSH[@]}" idex 'ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman "git -C /root/mohsen rev-parse HEAD"')"
[[ "$IDEX_SHA" == "$TARGET_SHA" ]] || { echo "ERROR: idex HEAD=$IDEX_SHA" >&2; exit 73; }
[[ "$TINY_SHA" == "$TARGET_SHA" ]] || { echo "ERROR: tinyman HEAD=$TINY_SHA" >&2; exit 73; }
echo "IDEX_HEAD=$IDEX_SHA"
echo "TINYMAN_HEAD=$TINY_SHA"

# These are disposable P5-only trees. Removing them prevents any newer D1/D2+
# application transform or performance2 datapath transform from being reused.
log "removing disposable P5 build/source trees"
ssh "${SSH[@]}" idex 'rm -rf /root/mohsen/msquic-p5-source /root/mohsen/msquic/build-greenquic-p5'
ssh "${SSH[@]}" idex "ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman 'rm -rf /root/mohsen/msquic-p5-source /root/mohsen/msquic/build-greenquic-p5'"

PERF='P5_BUILD_REUSE=1 P5_SUPER_CACHE=128 P5_SUPER_RX_BURST=32 P5_SUPER_TX_BURST=16 P5_SUPER_RING_SIZE=4096 P5_SUPER_RING_SYNC=legacy P5_SUPER_DRAIN_BURSTS=2 P5_SUPER_DRAIN_THRESHOLD=0 P5_SUPER_MTU=0 P5_SUPER_SKIP_OFF_RINGCOUNT=0 P5_SUPER_DEBUG_COUNTERS=1 P5_SUPER_TRANSFER_WINDOW=1 P5_SUPER_TRACE_RINGCOUNT=1 P5_SUPER_TX_META=mbuf P5_SUPER_RX_META=mbuf P5_SUPER_TX_LOCK_MODE=single_owner P5_SUPER_CAP_DIAG=1'

log "building exact archived SUPER-PERF profile on both endpoints"
set +e
ssh "${SSH[@]}" idex "cd '$P5' && env $PERF bash ./build_p5_super_performance.sh" >"$BUILD_I" 2>&1 & p1=$!
ssh "${SSH[@]}" idex "ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman \"cd '$P5' && env $PERF bash ./build_p5_super_performance.sh\"" >"$BUILD_T" 2>&1 & p2=$!
wait "$p1"; b1=$?
wait "$p2"; b2=$?
set -e
if [[ "$b1" -ne 0 || "$b2" -ne 0 ]]; then
    echo "ERROR: archived build failed idex=$b1 tinyman=$b2" >&2
    echo "--- idex ---" >&2; tail -100 "$BUILD_I" >&2 || true
    echo "--- tinyman ---" >&2; tail -100 "$BUILD_T" >&2 || true
    exit 74
fi

# Verify commit again after build, plus the exact historical SUPER-PERF marker.
IDEX_SHA="$(ssh "${SSH[@]}" idex 'git -C /root/mohsen rev-parse HEAD')"
TINY_SHA="$(ssh "${SSH[@]}" idex 'ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman "git -C /root/mohsen rev-parse HEAD"')"
[[ "$IDEX_SHA" == "$TARGET_SHA" && "$TINY_SHA" == "$TARGET_SHA" ]] || { echo "ERROR: endpoint HEAD changed during build" >&2; exit 75; }
ssh "${SSH[@]}" idex "grep -aFq 'GREENQUIC-P5-SUPER-PERF-V2' '$BIN' && grep -aFq 'GREENQUIC-P5-SUPER-PERF-V2' '$SERVER_BIN'"
ssh "${SSH[@]}" idex "ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman \"grep -aFq 'GREENQUIC-P5-SUPER-PERF-V2' '$BIN' && grep -aFq 'GREENQUIC-P5-SUPER-PERF-V2' '$SERVER_BIN'\""
log "commit + binary marker verification PASS"

TMP_RUNNER="${TMPDIR:-/tmp}/P5_REPRO_0dd500d7_${TAG}.runner.sh"
cat >"$TMP_RUNNER" <<'REMOTE'
#!/usr/bin/env bash
set +e
TARGET_SHA="$1"; RUNS="$2"; DOWNLOADS="$3"; SEED="$4"; OUT="$5"; EX="$6"
P5=/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads
BIN=/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop
mkdir -p "$EX"; rm -f "$EX/DONE" "$EX/FAILED" "$EX/SHA256SUMS"
{
  echo "TARGET_SHA=$TARGET_SHA"
  echo "IDEX_HEAD=$(git -C /root/mohsen rev-parse HEAD 2>/dev/null)"
  echo "TINYMAN_HEAD=$(ssh root@tinyman 'git -C /root/mohsen rev-parse HEAD' 2>/dev/null)"
  echo "RUNS=$RUNS"
  echo "DOWNLOADS=$DOWNLOADS"
  echo "SEED=$SEED"
  echo "MODE_ORDER=balanced"
  echo "GAP_SECONDS=5"
  echo "SERVER_COOLDOWN_SECONDS=5"
  echo "BETWEEN_TESTS_SECONDS=0"
  echo "CSTATE_CPU=19"
  echo "ENABLE_RECORD=1"
  echo "GQ_LOG_LEVEL=0"
  echo "GQ_IDLE_MODE_OVERRIDE=monitor"
  echo "GQ_IDLE_FALLBACK_OVERRIDE=short"
  echo "BUILD=cache128 RX32 TX16 ring4096 legacy drain2 metadata-mbuf-both single-owner"
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
cd "$EX" || exit 91
find . -maxdepth 1 -type f ! -name SHA256SUMS ! -name DONE ! -name FAILED -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS
[[ "$rc" -eq 0 ]] || touch FAILED
touch DONE
exit "$rc"
REMOTE
chmod 0700 "$TMP_RUNNER"
scp "${SSH[@]}" "$TMP_RUNNER" "idex:$REMOTE_RUNNER"
rm -f "$TMP_RUNNER"

log "launching Idle Monitor only: $RUNS runs x $DOWNLOADS downloads x OFF/BASIC/PLUS"
REMOTE_PID="$(ssh "${SSH[@]}" idex "rm -rf '$REMOTE_EXPORT'; mkdir -p '$REMOTE_EXPORT'; nohup setsid bash '$REMOTE_RUNNER' '$TARGET_SHA' '$RUNS' '$DOWNLOADS' '$SEED' '$OUT' '$REMOTE_EXPORT' >'$REMOTE_LOG' 2>&1 </dev/null & echo \\$!")"
echo "$REMOTE_PID" | ssh "${SSH[@]}" idex "cat >'$REMOTE_PIDFILE'"
echo "REMOTE_PID=$REMOTE_PID"
echo "REMOTE_LOG=$REMOTE_LOG"

while true; do
    set +e
    ssh "${SSH[@]}" idex "test -f '$REMOTE_EXPORT/DONE'"
    done_rc=$?
    set -e
    if [[ "$done_rc" -eq 0 ]]; then break; fi
    if [[ "$done_rc" -eq 255 ]]; then
        log "SSH transport unavailable; detached remote run continues; retrying in 30 s"
        sleep 30
        continue
    fi
    set +e
    ssh "${SSH[@]}" idex "kill -0 '$REMOTE_PID' 2>/dev/null"
    alive_rc=$?
    set -e
    if [[ "$alive_rc" -ne 0 && "$alive_rc" -ne 255 ]]; then
        echo "ERROR: remote runner exited without DONE marker" >&2
        ssh "${SSH[@]}" idex "tail -120 '$REMOTE_LOG'" >&2 || true
        exit 76
    fi
    log "historical Idle Monitor still running"
    sleep 30
done

mkdir -p "$LOCAL_EXPORT"
log "copying ZIP + metadata + logs automatically to Mac"
while ! scp "${SSH[@]}" -r "idex:$REMOTE_EXPORT/." "$LOCAL_EXPORT/"; do
    log "SCP export failed; retrying in 30 s"; sleep 30
done
scp "${SSH[@]}" "idex:$REMOTE_LOG" "$LOCAL_EXPORT/remote.log" || true
cp "$BUILD_I" "$LOCAL_EXPORT/build_idex.log"
cp "$BUILD_T" "$LOCAL_EXPORT/build_tinyman.log"

(cd "$LOCAL_EXPORT" && shasum -a 256 -c SHA256SUMS)
TEST_RC="$(cat "$LOCAL_EXPORT/test_rc.txt" 2>/dev/null || echo 99)"

echo
printf '%s\n' \
  "======================================================================" \
  "P5 HISTORICAL IDLE MONITOR REPRODUCTION COMPLETE" \
  "TARGET_SHA=$TARGET_SHA" \
  "RUNS=$RUNS DOWNLOADS=$DOWNLOADS SEED=$SEED" \
  "IDLE_MODE=monitor FALLBACK=short" \
  "TEST_RC=$TEST_RC" \
  "MAC_EXPORT=$LOCAL_EXPORT" \
  "REMOTE_RESULT=$OUT" \
  "REMOTE_LOG=$REMOTE_LOG" \
  "======================================================================"

[[ "$TEST_RC" == 0 ]]
