#!/usr/bin/env bash
set -Eeuo pipefail

BRANCH="performance2/p5-multicore"
RUNS="${GQ_FAIR_RUNS:-6}"
DOWNLOADS="${GQ_FAIR_DOWNLOADS:-5}"
GAP="${GQ_FAIR_GAP_SECONDS:-5}"
EDGE="${GQ_FAIR_EDGE_COOLDOWN_SECONDS:-5}"
BETWEEN="${GQ_FAIR_BETWEEN_SECONDS:-5}"
STAMP="${GQ_FAIR_TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}"
AUTO_SCP="${GQ_AUTO_SCP:-1}"
SEQTAG="P7_PAPER_FAIR_${STAMP}"

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO" && -d "$REPO/.git" ]] || { echo "ERROR: cannot resolve GreenQUIC repo" >&2; exit 2; }
WATCHER="$HERE/mac_remote_result_watcher.sh"
[[ -x "$WATCHER" ]] || { echo "ERROR: auto-SCP watcher missing: $WATCHER" >&2; exit 2; }

ROOT=/root/mohsen
P7_REL="greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline"
REMOTE_RUNNER="$ROOT/$P7_REL/run_p7_paper_fair_from_idex.sh"
LOCAL_BUNDLE="${TMPDIR:-/tmp}/${SEQTAG}_$$.bundle"
TMPREF="refs/heads/__${SEQTAG}_$$"
REMOTE_BUNDLE="/tmp/${SEQTAG}.bundle"
REMOTE_LOG="/root/${SEQTAG}.log"
REMOTE_PID="/root/${SEQTAG}.pid"
ART="/root/${SEQTAG}"
LOCAL_DEST="${GQ_LOCAL_RESULTS_DIR:-$HOME/Downloads/GreenQUIC_results/P7_${STAMP}}"
STARTUP_RETRY="${GQ_STARTUP_RETRY_SECONDS:-10}"

for v in "$RUNS" "$DOWNLOADS"; do
    [[ "$v" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: invalid run/download count: $v" >&2; exit 2; }
done
[[ "$STARTUP_RETRY" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: GQ_STARTUP_RETRY_SECONDS must be positive" >&2; exit 2; }

cleanup_local(){
    git -C "$REPO" update-ref -d "$TMPREF" 2>/dev/null || true
    rm -f "$LOCAL_BUNDLE"
}
trap cleanup_local EXIT INT TERM

ssh_idex_retry(){
    local rc
    while :; do
        set +e
        ssh -o BatchMode=yes -o ConnectTimeout=10 idex "$@"
        rc=$?
        set -e
        (( rc == 0 )) && return 0
        echo "IDEX SSH unavailable (rc=$rc); retrying in ${STARTUP_RETRY}s..." >&2
        sleep "$STARTUP_RETRY"
    done
}

scp_idex_retry(){
    local src="$1" dst="$2" rc
    while :; do
        set +e
        scp -o ConnectTimeout=20 "$src" "$dst"
        rc=$?
        set -e
        (( rc == 0 )) && return 0
        echo "SCP unavailable (rc=$rc); retrying in ${STARTUP_RETRY}s: $src -> $dst" >&2
        sleep "$STARTUP_RETRY"
    done
}

cd "$REPO"
git fetch origin "$BRANCH"
SHA="$(git rev-parse "origin/$BRANCH")"
git update-ref "$TMPREF" "$SHA"
git bundle create "$LOCAL_BUNDLE" "$TMPREF"
git update-ref -d "$TMPREF"
git bundle verify "$LOCAL_BUNDLE" >/dev/null

cat <<HDR
======================================================================
P7 PAPER + FAIR REPRODUCTION
branch=$BRANCH
sha=$SHA
matrix folder=P7_${STAMP}
runs=$RUNS; sequential 8-GiB downloads/run=$DOWNLOADS
gap=${GAP}s; pre/post cooldown=${EDGE}s; between-runs=${BETWEEN}s
paper side: max_throughput + paper GSO/GRO + rmem/wmem=6815744
fair side: CPU19 dataplane/IRQ/NAPI, QUIC CPUs21-24, pinning/RPS hygiene
recording: RAPL 6ms + frequency 1ms + C-state CPU19
charts/report: both
local destination=$LOCAL_DEST
AUTO-SCP: detached watcher retries SSH/SCP and survives terminal close
======================================================================
HDR

scp_idex_retry "$LOCAL_BUNDLE" "idex:$REMOTE_BUNDLE"
ssh_idex_retry "cd '$ROOT' && git reset --hard && git fetch '$REMOTE_BUNDLE' '$TMPREF' && git checkout -B '$BRANCH' FETCH_HEAD && test \"\$(git rev-parse HEAD)\" = '$SHA' && test -x '$REMOTE_RUNNER'"

ssh_idex_retry "rm -rf '$ART'; nohup setsid bash '$REMOTE_RUNNER' '$STAMP' '$SHA' '$BRANCH' '$RUNS' '$DOWNLOADS' '$GAP' '$EDGE' '$BETWEEN' '$REMOTE_BUNDLE' '$TMPREF' >'$REMOTE_LOG' 2>&1 </dev/null & echo \$! >'$REMOTE_PID'"
sleep 5

RPID="$(ssh_idex_retry "cat '$REMOTE_PID'")"
STATUS="$(ssh_idex_retry "if kill -0 '$RPID' 2>/dev/null; then echo RUNNING; elif test -f '$ART/DONE'; then echo DONE; else echo DEAD; fi")"
if [[ "$STATUS" == DEAD ]]; then
    echo "ERROR: remote P7 sequence died during startup" >&2
    ssh_idex_retry "cat '$REMOTE_LOG' 2>/dev/null || true"
    exit 1
fi

echo "REMOTE START OK"
echo "STAMP=$STAMP"
echo "REMOTE_PID=$RPID"
echo "REMOTE_LOG=$REMOTE_LOG"
echo "REMOTE_ART=$ART"
echo "REMOTE_MATRIX=P7_$STAMP"
echo "LIVE: ssh idex 'tail -n +1 -F $REMOTE_LOG'"

if [[ "$AUTO_SCP" != 1 ]]; then
    echo "GQ_AUTO_SCP=$AUTO_SCP: remote P7 continues detached; auto-SCP watcher disabled."
    exit 0
fi

mkdir -p "$LOCAL_DEST"
WATCH_LOG="$LOCAL_DEST/auto_scp_watcher.log"
nohup bash "$WATCHER" "$ART" "$REMOTE_LOG" "$LOCAL_DEST" "P7 paper+fair $STAMP" \
    >"$WATCH_LOG" 2>&1 </dev/null &
WATCH_PID=$!

echo "AUTO-SCP WATCHER STARTED"
echo "WATCHER_PID=$WATCH_PID"
echo "WATCHER_LOG=$WATCH_LOG"
echo "Closing this terminal does NOT kill the remote test or detached SCP watcher."
echo "Temporary Mac<->IDEX SSH/SCP loss is retried automatically."
