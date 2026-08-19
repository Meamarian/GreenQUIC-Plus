#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IMPL="$HERE/mac_run_p5_t29_t41_top3_p7_auto_impl.sh"
WATCHER="$HERE/mac_remote_result_watcher.sh"
[[ -x "$IMPL" ]] || { echo "ERROR: implementation launcher missing: $IMPL" >&2; exit 2; }
[[ -x "$WATCHER" ]] || { echo "ERROR: auto-SCP watcher missing: $WATCHER" >&2; exit 2; }

STAMP="${GQ_FAIR_TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}"
AUTO_SCP="${GQ_AUTO_SCP:-1}"
LOCAL_DEST="${GQ_LOCAL_RESULTS_DIR:-$HOME/Downloads/GreenQUIC_results/$STAMP}"
SEQTAG="T29_T41_TOP3_P7_${STAMP}"
ART="/root/$SEQTAG"
REMOTE_LOG="/root/${SEQTAG}.log"

# The original implementation remains responsible for the remote experiment.
# Disable its fragile foreground SCP loop; this wrapper starts a detached,
# retrying watcher after REMOTE START OK instead.
GQ_FAIR_TIMESTAMP="$STAMP" \
GQ_LOCAL_RESULTS_DIR="$LOCAL_DEST" \
GQ_AUTO_SCP=0 \
bash "$IMPL"

if [[ "$AUTO_SCP" != 1 ]]; then
    echo "GQ_AUTO_SCP=$AUTO_SCP: remote experiment continues detached; auto-SCP watcher not started."
    exit 0
fi

mkdir -p "$LOCAL_DEST"
WATCH_LOG="$LOCAL_DEST/auto_scp_watcher.log"
nohup bash "$WATCHER" "$ART" "$REMOTE_LOG" "$LOCAL_DEST" "T29/T41/TOP3/P7 $STAMP" \
    >"$WATCH_LOG" 2>&1 </dev/null &
WATCH_PID=$!

echo "AUTO-SCP WATCHER STARTED"
echo "WATCHER_PID=$WATCH_PID"
echo "WATCHER_LOG=$WATCH_LOG"
echo "The watcher survives terminal close and retries temporary SSH/SCP failures."
echo "LIVE REMOTE: ssh idex 'tail -n +1 -F $REMOTE_LOG'"
echo "LIVE SCP:    tail -n +1 -F '$WATCH_LOG'"
