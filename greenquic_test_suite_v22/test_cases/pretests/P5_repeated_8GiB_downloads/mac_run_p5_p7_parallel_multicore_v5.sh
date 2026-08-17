#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
V4="$HERE/mac_run_p5_p7_parallel_multicore_v4.sh"
CLEANER="$HERE/safe_cleanup_greenquic_processes.py"
BRANCH=performance2/p5-multicore
RUNS="${P5_MC_RUNS:-2}"
CONNECTIONS="${P5_MC_CONNECTIONS:-4}"
TAG="${P5_MC_TAG:-$(date +%Y%m%d_%H%M%S)}"
LOCAL_LOG="$HOME/Downloads/P5_P7_MC_${TAG}.mac.log"
LOCAL_EXPORT="$HOME/Downloads/P5_P7_MC_EXPORT_${TAG}"
REMOTE_CLEANER="/tmp/safe_cleanup_greenquic_processes_${TAG}.py"
SSH=(-o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3)

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

[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: P5_MC_RUNS must be positive" >&2; exit 2; }
[[ "$CONNECTIONS" =~ ^[2-9][0-9]*$ ]] || { echo "ERROR: P5_MC_CONNECTIONS must be >=2" >&2; exit 2; }
[[ -f "$V4" && -f "$CLEANER" ]] || { echo "ERROR: V4/cleanup helper missing" >&2; exit 2; }
python3 "$CLEANER" --help >/dev/null

if [[ "${1:-}" == "--detach" ]]; then
    shift
    nohup caffeinate -dimsu env \
        P5_MC_RUNS="$RUNS" \
        P5_MC_CONNECTIONS="$CONNECTIONS" \
        P5_MC_TAG="$TAG" \
        bash "$0" --foreground >"$LOCAL_LOG" 2>&1 </dev/null &
    pid=$!
    disown "$pid" 2>/dev/null || true
    echo "STARTED P5+P7 PARALLEL MULTICORE V5 PID=$pid"
    echo "TAG=$TAG"
    echo "MAC_LOG=$LOCAL_LOG"
    echo "FINAL_EXPORT=$LOCAL_EXPORT"
    echo "V5 performs ancestry-safe stale-process cleanup on IDEX + Tinyman before sync/traffic."
    exit 0
fi
[[ "${1:-}" == "--foreground" ]] && shift || true
[[ $# -eq 0 ]] || { echo "ERROR: unknown arguments: $*" >&2; exit 2; }

cd "$HERE"
LOCAL_REPO="$(git rev-parse --show-toplevel)"
LOCAL_BRANCH="$(git -C "$LOCAL_REPO" branch --show-current)"
[[ "$LOCAL_BRANCH" == "$BRANCH" ]] || { echo "ERROR: local branch=$LOCAL_BRANCH expected=$BRANCH" >&2; exit 2; }
[[ -z "$(git -C "$LOCAL_REPO" status --porcelain --untracked-files=no)" ]] || {
    echo "ERROR: tracked local changes present; commit/stash before launch" >&2
    exit 2
}

# FIRST REMOTE ACTION: install and execute the ancestry-safe process cleanup.
log "installing safe cleanup helper on IDEX"
retry scp "${SSH[@]}" "$CLEANER" "idex:$REMOTE_CLEANER"
retry ssh "${SSH[@]}" idex "chmod 0700 '$REMOTE_CLEANER'; scp -q -o BatchMode=yes -o ConnectTimeout=15 '$REMOTE_CLEANER' root@tinyman:'$REMOTE_CLEANER'; ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman chmod 0700 '$REMOTE_CLEANER'"

run_cleanup_idex(){
    local marker="/tmp/gq_cleanup_${TAG}_idex.done" logf="/tmp/gq_cleanup_${TAG}_idex.log" jsonf="/tmp/gq_cleanup_${TAG}_idex.json"
    retry ssh "${SSH[@]}" idex "rm -f '$marker' '$logf' '$jsonf'; nohup setsid python3 '$REMOTE_CLEANER' --marker '$marker' --json '$jsonf' >'$logf' 2>&1 </dev/null & echo CLEANUP_PID=\$!"
    while true; do
        if retry ssh "${SSH[@]}" idex "test -f '$marker'" >/dev/null 2>&1; then break; fi
        sleep 1
    done
    retry ssh "${SSH[@]}" idex "cat '$logf'; test \"\$(cat '$marker')\" = PASS; python3 '$REMOTE_CLEANER' --check"
}

run_cleanup_tinyman(){
    local marker="/tmp/gq_cleanup_${TAG}_tinyman.done" logf="/tmp/gq_cleanup_${TAG}_tinyman.log" jsonf="/tmp/gq_cleanup_${TAG}_tinyman.json"
    retry ssh "${SSH[@]}" idex "ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman \"rm -f '$marker' '$logf' '$jsonf'; nohup setsid python3 '$REMOTE_CLEANER' --marker '$marker' --json '$jsonf' >'$logf' 2>&1 </dev/null & echo CLEANUP_PID=\\\$!\""
    while true; do
        if retry ssh "${SSH[@]}" idex "ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman test -f '$marker'" >/dev/null 2>&1; then break; fi
        sleep 1
    done
    retry ssh "${SSH[@]}" idex "ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman \"cat '$logf'; test \\\"\$(cat '$marker')\\\" = PASS; python3 '$REMOTE_CLEANER' --check\""
}

log "cleaning stale GreenQUIC/P5/P7 process trees on IDEX"
run_cleanup_idex
log "cleaning stale GreenQUIC/P5/P7 process trees on Tinyman"
run_cleanup_tinyman
log "SAFE STALE-PROCESS CLEANUP PASS: IDEX + Tinyman"

# V4 contains the proven branch-bundle sync, controller preflights, detached
# remote suite, resumable live log, exports, goodput summary, and runtime-core
# checks. Strip ONLY its obsolete broad-pkill cleanup block because V5 has just
# completed and verified the safer cleanup above.
TMP_V4="$(mktemp "${TMPDIR:-/tmp}/greenquic_mc_v4_nocleanup.XXXXXX.sh")"
python3 - "$V4" "$TMP_V4" <<'PY'
from pathlib import Path
import sys
src = Path(sys.argv[1]).read_text(encoding="utf-8")
start_marker = "# FIRST ACTION: kill stale P5/P7/GreenQUIC processes on both test hosts."
end_marker = 'log "stale-process cleanup PASS on IDEX + Tinyman"\n'
start = src.find(start_marker)
end = src.find(end_marker)
if start < 0 or end < 0 or end < start:
    raise SystemExit("ERROR: V4 cleanup anchors changed; refusing unsafe transform")
end += len(end_marker)
replacement = (
    "# GREENQUIC-V5-SAFE-CLEANUP-V1\n"
    "# Stale process cleanup was already completed and verified by the V5 wrapper.\n"
    'log "V5 safe stale-process cleanup already PASS on IDEX + Tinyman"\n'
)
out = src[:start] + replacement + src[end:]
Path(sys.argv[2]).write_text(out, encoding="utf-8")
PY
chmod 0700 "$TMP_V4"
bash -n "$TMP_V4"
grep -Fq 'GREENQUIC-V5-SAFE-CLEANUP-V1' "$TMP_V4" || { echo "ERROR: V5 transform missing" >&2; exit 2; }
if grep -Fq 'pkill -TERM -f' "$TMP_V4"; then
    echo "ERROR: unsafe broad cleanup survived V5 transform" >&2
    exit 2
fi

log "starting proven V4 sync/preflight/detached-suite/live-stream path after safe cleanup"
export P5_MC_RUNS="$RUNS" P5_MC_CONNECTIONS="$CONNECTIONS" P5_MC_TAG="$TAG"
exec bash "$TMP_V4" --foreground
