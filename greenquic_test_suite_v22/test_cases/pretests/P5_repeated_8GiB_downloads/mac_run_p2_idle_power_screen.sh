#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="${GREENQUIC_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
[[ -n "$REPO_ROOT" && -d "$REPO_ROOT/.git" ]] || { echo "ERROR: run from GreenQUIC repo or set GREENQUIC_REPO" >&2; exit 2; }
P5_REL=greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads
BRANCH=performance2/p5-max-goodput
RUNS="${P5_P2_RUNS:-1}"
DOWNLOADS="${P5_P2_DOWNLOADS:-3}"
START_DELAY="${P5_P2_START_DELAY_SECONDS:-10}"
TAG="${P5_P2_SCREEN_TAG:-$(date +%Y%m%d_%H%M%S)}"
SSH_OPTS=(-o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3)
LOCAL_LOCK="$HOME/Downloads/.greenquic_p2_idle_power_screen.lock"
BUNDLE="${TMPDIR:-/tmp}/GreenQUIC_P2_IDLE_POWER_${TAG}.bundle"
REMOTE_BUNDLE="/tmp/GreenQUIC_P2_IDLE_POWER_${TAG}.bundle"
EXPORT_REMOTE="/tmp/P5_P2_IDLE_POWER_EXPORT_${TAG}"
EXPORT_LOCAL="$HOME/Downloads/P5_P2_IDLE_POWER_EXPORT_${TAG}"
REMOTE_LOG="/root/P5_P2_IDLE_POWER_${TAG}.log"
REMOTE_PID="/tmp/P5_P2_IDLE_POWER_${TAG}.pid"
REMOTE_RUNNER="/root/mohsen/$P5_REL/run_p5_performance2_idle_power_screen.sh"

log(){ printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

if [[ "${1:-}" == "--detach" ]]; then
    shift
    LOG="$HOME/Downloads/P5_P2_IDLE_POWER_${TAG}.mac.log"
    PIDFILE="$HOME/Downloads/P5_P2_IDLE_POWER_${TAG}.mac.pid"
    nohup caffeinate -dimsu env \
        GREENQUIC_REPO="$REPO_ROOT" \
        P5_P2_SCREEN_TAG="$TAG" \
        P5_P2_RUNS="$RUNS" \
        P5_P2_DOWNLOADS="$DOWNLOADS" \
        P5_P2_START_DELAY_SECONDS="$START_DELAY" \
        bash "$0" --foreground "$@" >"$LOG" 2>&1 </dev/null &
    pid=$!
    echo "$pid" > "$PIDFILE"
    disown "$pid" 2>/dev/null || true
    echo "STARTED PID=$pid"
    echo "TAG=$TAG"
    echo "LOG=$LOG"
    exit 0
fi
[[ "${1:-}" == "--foreground" ]] && shift || true

if [[ -d "$LOCAL_LOCK" ]]; then
    old="$(cat "$LOCAL_LOCK/pid" 2>/dev/null || true)"
    if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
        echo "ERROR: another P2 idle/power screen is alive PID=$old" >&2
        exit 70
    fi
    rm -rf "$LOCAL_LOCK"
fi
mkdir -p "$LOCAL_LOCK"
echo $$ > "$LOCAL_LOCK/pid"
trap 'rm -rf "$LOCAL_LOCK"; rm -f "$BUNDLE"' EXIT INT TERM

for pf in "$HOME/Downloads"/P5_P1_P2_CHAIN_V2_*.pid "$HOME/Downloads"/P5_P1_P2_CHAIN_V3_*.pid "$HOME/Downloads"/P5_P1_P2_CHAIN_V4_*.pid; do
    [[ -f "$pf" ]] || continue
    p="$(cat "$pf" 2>/dev/null || true)"
    if [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; then
        echo "ERROR: existing P1/P2 chain is still alive PID=$p ($pf). Let it finish or stop it before this screen." >&2
        exit 71
    fi
done

check_host_once(){
    local which="$1"
    if [[ "$which" == idex ]]; then
        ssh "${SSH_OPTS[@]}" idex 'bash -s' <<'CHECK'
set +e
bad=0
for p in /proc/[0-9]*; do
    exe=$(readlink -f "$p/exe" 2>/dev/null || true)
    case "$exe" in */quicinterop|*/quicinteropserver) bad=1;; esac
    cmd=$(cat "$p/cmdline" 2>/dev/null | tr '\0' ' ' || true)
    case "$cmd" in *run_matrix_with_sheet.sh*|*.run_matrix_fixed.*|*run_client.sh*|*run_server.sh*|*run_p7.sh*|*run_p5_performance2_sweep.sh*|*run_p5_performance2_selected_profiles.sh*|*run_p5_performance2_idle_power_screen.sh*) bad=1;; esac
done
if fuser /var/run/dpdk/rte/config >/dev/null 2>&1; then bad=1; fi
exit "$bad"
CHECK
    else
        ssh "${SSH_OPTS[@]}" idex "ssh -o ConnectTimeout=15 root@tinyman 'bash -s'" <<'CHECK'
set +e
bad=0
for p in /proc/[0-9]*; do
    exe=$(readlink -f "$p/exe" 2>/dev/null || true)
    case "$exe" in */quicinterop|*/quicinteropserver) bad=1;; esac
    cmd=$(cat "$p/cmdline" 2>/dev/null | tr '\0' ' ' || true)
    case "$cmd" in *run_matrix_with_sheet.sh*|*.run_matrix_fixed.*|*run_client.sh*|*run_server.sh*|*run_p7.sh*|*run_p5_performance2_sweep.sh*|*run_p5_performance2_selected_profiles.sh*|*run_p5_performance2_idle_power_screen.sh*) bad=1;; esac
done
if fuser /var/run/dpdk/rte/config >/dev/null 2>&1; then bad=1; fi
exit "$bad"
CHECK
    fi
}

wait_clean_both(){
    until check_host_once idex; do log "idex busy/unreachable; retry in 30 s"; sleep 30; done
    until check_host_once tinyman; do log "tinyman busy/unreachable; retry in 30 s"; sleep 30; done
    log "idex + tinyman clean"
}

scp_retry(){
    local src="$1" dst="$2"
    until scp "${SSH_OPTS[@]}" "$src" "$dst"; do log "SCP failed; retry in 30 s"; sleep 30; done
}

wait_clean_both
sleep "$START_DELAY"

cd "$REPO_ROOT"
while ! git fetch origin "$BRANCH"; do log "git fetch failed; retry in 30 s"; sleep 30; done
SHA="$(git rev-parse "origin/$BRANCH")"
REF="refs/heads/__p2_idle_power_${TAG}_$$"
git update-ref "$REF" "$SHA"
git bundle create "$BUNDLE" "$REF"
git update-ref -d "$REF"
scp_retry "$BUNDLE" "idex:$REMOTE_BUNDLE"
ssh "${SSH_OPTS[@]}" idex "while ! scp -o ConnectTimeout=15 '$REMOTE_BUNDLE' root@tinyman:'$REMOTE_BUNDLE'; do sleep 30; done"

ssh "${SSH_OPTS[@]}" idex "cd /root/mohsen && git reset --hard && git fetch '$REMOTE_BUNDLE' '$REF' && git checkout -B '$BRANCH' FETCH_HEAD && test \"\$(git rev-parse HEAD)\" = '$SHA'"
ssh "${SSH_OPTS[@]}" idex "ssh -o ConnectTimeout=15 root@tinyman \"cd /root/mohsen && git reset --hard && git fetch '$REMOTE_BUNDLE' '$REF' && git checkout -B '$BRANCH' FETCH_HEAD && test \\\"\\\$(git rev-parse HEAD)\\\" = '$SHA'\""
log "P2_SHA=$SHA"

wait_clean_both

ssh "${SSH_OPTS[@]}" idex "rm -rf '$EXPORT_REMOTE'; mkdir -p '$EXPORT_REMOTE'; chmod +x '$REMOTE_RUNNER'; nohup setsid bash -lc 'STAMP=$TAG RESULT_ROOT=/tmp/P5_P2_IDLE_POWER_SCREEN_$TAG MATRIX_ROOT=/root/mohsen/$P5_REL/matrix_results/P5_P2_IDLE_POWER_SCREEN_$TAG P5_P2_RUNS=$RUNS P5_P2_DOWNLOADS=$DOWNLOADS P5_P2_CHART_STYLE=both bash $REMOTE_RUNNER; rc=\$?; ex=$EXPORT_REMOTE; cp -f /tmp/P5_P2_IDLE_POWER_SCREEN_$TAG/idle_power_summary.tsv \$ex/ 2>/dev/null || true; cp -f /tmp/P5_P2_IDLE_POWER_SCREEN_$TAG/status.env \$ex/ 2>/dev/null || true; cp -f $REMOTE_LOG \$ex/remote.log 2>/dev/null || true; [ -d /tmp/P5_P2_IDLE_POWER_SCREEN_$TAG ] && (cd /tmp && zip -qr \$ex/analysis__P5_P2_IDLE_POWER_SCREEN_$TAG.zip P5_P2_IDLE_POWER_SCREEN_$TAG); [ -d /root/mohsen/$P5_REL/matrix_results/P5_P2_IDLE_POWER_SCREEN_$TAG ] && (cd /root/mohsen/$P5_REL/matrix_results && zip -qr \$ex/matrix__P5_P2_IDLE_POWER_SCREEN_$TAG.zip P5_P2_IDLE_POWER_SCREEN_$TAG); printf "REMOTE_SCRIPT_RC=%s\\nP2_SHA=$SHA\\n" \"\$rc\" > \$ex/result_rc.txt; (cd \$ex && find . -maxdepth 1 -type f ! -name SHA256SUMS ! -name SHA256SUMS.tmp ! -name DONE -printf "%f\\0" | sort -z | xargs -0 -r sha256sum > SHA256SUMS.tmp && mv SHA256SUMS.tmp SHA256SUMS); date -Is > \$ex/DONE; exit \$rc' >'$REMOTE_LOG' 2>&1 </dev/null & echo \$! > '$REMOTE_PID'; echo REMOTE_PID=\$(cat '$REMOTE_PID')"

while true; do
    if ssh "${SSH_OPTS[@]}" idex "test -f '$EXPORT_REMOTE/DONE'" >/dev/null 2>&1; then break; fi
    log "waiting for P2 idle+power screen"
    sleep 60
done

mkdir -p "$EXPORT_LOCAL"
scp_retry "idex:$EXPORT_REMOTE/SHA256SUMS" "$EXPORT_LOCAL/SHA256SUMS"
while read -r hash file; do
    [[ -n "${file:-}" ]] || continue
    if [[ -f "$EXPORT_LOCAL/$file" ]] && printf '%s  %s\n' "$hash" "$file" | (cd "$EXPORT_LOCAL" && shasum -a 256 -c - >/dev/null 2>&1); then
        continue
    fi
    while true; do
        rm -f "$EXPORT_LOCAL/$file.part"
        if scp "${SSH_OPTS[@]}" "idex:$EXPORT_REMOTE/$file" "$EXPORT_LOCAL/$file.part"; then
            got="$(shasum -a 256 "$EXPORT_LOCAL/$file.part" | awk '{print $1}')"
            if [[ "$got" == "$hash" ]]; then mv "$EXPORT_LOCAL/$file.part" "$EXPORT_LOCAL/$file"; break; fi
        fi
        log "SCP/hash failed for $file; retry in 30 s"
        sleep 30
    done
done < "$EXPORT_LOCAL/SHA256SUMS"
(cd "$EXPORT_LOCAL" && shasum -a 256 -c SHA256SUMS)
date "+%Y-%m-%dT%H:%M:%S%z" > "$EXPORT_LOCAL/SCP_DONE"

log "COMPLETE"
log "EXPORT=$EXPORT_LOCAL"
cat "$EXPORT_LOCAL/idle_power_summary.tsv" 2>/dev/null || true
