#!/usr/bin/env bash
set -Eeuo pipefail

if (( $# < 4 )); then
    echo "Usage: $0 REMOTE_ART_DIR REMOTE_LOG LOCAL_DEST LABEL" >&2
    exit 2
fi

ART="$1"
REMOTE_LOG="$2"
LOCAL_DEST="$3"
LABEL="$4"
HOST="${GQ_RESULT_HOST:-idex}"
RETRY_SECONDS="${GQ_SCP_RETRY_SECONDS:-20}"
SSH_TIMEOUT="${GQ_SSH_CONNECT_TIMEOUT:-10}"
SCP_TIMEOUT="${GQ_SCP_CONNECT_TIMEOUT:-20}"

[[ "$RETRY_SECONDS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: GQ_SCP_RETRY_SECONDS must be a positive integer" >&2; exit 2; }
[[ "$SSH_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: GQ_SSH_CONNECT_TIMEOUT must be a positive integer" >&2; exit 2; }
[[ "$SCP_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: GQ_SCP_CONNECT_TIMEOUT must be a positive integer" >&2; exit 2; }

mkdir -p "$LOCAL_DEST"

now(){ date '+%Y-%m-%d %H:%M:%S'; }
log(){ printf '[%s][AUTO-SCP] %s\n' "$(now)" "$*"; }

ssh_once(){
    ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" "$HOST" "$@"
}

ssh_capture_retry(){
    local out rc
    while :; do
        set +e
        out="$(ssh_once "$@" 2>&1)"
        rc=$?
        set -e
        if (( rc == 0 )); then
            printf '%s' "$out"
            return 0
        fi
        log "SSH to $HOST unavailable (rc=$rc); retrying in ${RETRY_SECONDS}s" >&2
        sleep "$RETRY_SECONDS"
    done
}

scp_retry(){
    local src="$1" dst="$2" rc
    while :; do
        set +e
        scp -o ConnectTimeout="$SCP_TIMEOUT" "$src" "$dst"
        rc=$?
        set -e
        if (( rc == 0 )); then
            return 0
        fi
        log "SCP failed (rc=$rc): $src -> $dst; retrying in ${RETRY_SECONDS}s"
        sleep "$RETRY_SECONDS"
    done
}

# Keep the Mac awake while the detached watcher is alive. The watcher itself is
# normally launched through nohup, so closing the terminal does not kill it.
if command -v caffeinate >/dev/null 2>&1; then
    caffeinate -dimsu -w $$ >/dev/null 2>&1 &
fi

log "watching $LABEL"
log "remote art=$ART"
log "remote log=$REMOTE_LOG"
log "local dest=$LOCAL_DEST"

while :; do
    set +e
    ssh_once "test -f '$ART/DONE'" >/dev/null 2>&1
    done_rc=$?
    ssh_once "test -f '$ART/FAILED'" >/dev/null 2>&1
    failed_rc=$?
    set -e

    if (( done_rc == 0 )); then
        log "remote DONE detected"
        break
    fi

    if (( failed_rc == 0 )); then
        log "remote FAILED detected"
        set +e
        ssh_once "cat '$ART/FAILED'; tail -120 '$REMOTE_LOG'" || true
        set -e
        scp_retry "$HOST:$REMOTE_LOG" "$LOCAL_DEST/"
        printf '%s\n' "$(now) $LABEL remote failure" > "$LOCAL_DEST/.SCP_FAILED"
        exit 1
    fi

    # Any SSH loss here is deliberately non-fatal. This is the old failure mode:
    # the remote experiment kept running while the Mac wrapper exited before SCP.
    set +e
    ssh_once "tail -4 '$REMOTE_LOG' 2>/dev/null || true" || \
        log "temporary Mac->$HOST SSH loss; watcher stays alive"
    set -e
    sleep "$RETRY_SECONDS"
done

result_zips="$(ssh_capture_retry "cat '$ART/RESULT_ZIPS.txt'")"
[[ -n "$result_zips" ]] || { log "ERROR: RESULT_ZIPS.txt is empty"; exit 1; }

while IFS= read -r remote_zip; do
    [[ -n "$remote_zip" ]] || continue
    log "downloading $remote_zip"
    scp_retry "$HOST:$remote_zip" "$LOCAL_DEST/"
done <<< "$result_zips"

# config.env is expected for these launchers, but retrying an absent optional
# file forever would be undesirable. Check existence first, then copy robustly.
if ssh_capture_retry "test -f '$ART/config.env' && echo yes || echo no" | grep -qx yes; then
    scp_retry "$HOST:$ART/config.env" "$LOCAL_DEST/"
fi
scp_retry "$HOST:$REMOTE_LOG" "$LOCAL_DEST/"

printf '%s\n' "$(now) $LABEL SCP complete" > "$LOCAL_DEST/.SCP_DONE"
log "SCP COMPLETE"
ls -lh "$LOCAL_DEST"
