#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="${GREENQUIC_REPO:-$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)}"
[[ -n "$REPO_ROOT" && -d "$REPO_ROOT/.git" ]] || { echo "ERROR: run from GreenQUIC repo or set GREENQUIC_REPO" >&2; exit 2; }

P5_REL=greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads
BRANCH=performance2/p5-max-goodput
RUNS="${P5_P2_RUNS:-1}"
DOWNLOADS="${P5_P2_DOWNLOADS:-3}"
START_DELAY="${P5_P2_START_DELAY_SECONDS:-10}"
TAG="${P5_P2_GOODPUT_TAG:-$(date +%Y%m%d_%H%M%S)}"
SSH_OPTS=(-o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3)
LOCAL_LOCK="$HOME/Downloads/.greenquic_p2_goodput_screen.lock"
BUNDLE="${TMPDIR:-/tmp}/GreenQUIC_P2_GOODPUT_${TAG}.bundle"
REMOTE_BUNDLE="/tmp/GreenQUIC_P2_GOODPUT_${TAG}.bundle"
REMOTE_SCRIPT_LOCAL="${TMPDIR:-/tmp}/P5_P2_GOODPUT_REMOTE_${TAG}_$$.sh"
REMOTE_SCRIPT="/tmp/P5_P2_GOODPUT_REMOTE_${TAG}.sh"
REMOTE_LOG="/root/P5_P2_GOODPUT_${TAG}.log"
REMOTE_PID="/tmp/P5_P2_GOODPUT_${TAG}.pid"
EXPORT_REMOTE="/tmp/P5_P2_GOODPUT_EXPORT_${TAG}"
EXPORT_LOCAL="$HOME/Downloads/P5_P2_GOODPUT_EXPORT_${TAG}"

log(){ printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
ssh_once(){ ssh "${SSH_OPTS[@]}" idex "$@"; }

# Retry only transport loss. A real remote command/self-test/build failure must
# stop immediately instead of being mislabeled as an SSH outage forever.
ssh_transport_retry(){
    local rc
    while true; do
        if ssh_once "$@"; then
            return 0
        else
            rc=$?
        fi
        if (( rc == 255 )); then
            log "SSH transport failed; retrying in 30 s"
            sleep 30
            continue
        fi
        echo "ERROR: remote command failed rc=$rc (not an SSH transport failure)" >&2
        return "$rc"
    done
}

scp_to_idex_retry(){
    local src="$1" dst="$2" rc
    while true; do
        if scp "${SSH_OPTS[@]}" "$src" "idex:$dst"; then
            return 0
        else
            rc=$?
        fi
        if (( rc == 255 )); then
            log "SCP transport to idex failed; retrying in 30 s"
            sleep 30
            continue
        fi
        echo "ERROR: SCP to idex failed rc=$rc for $src" >&2
        return "$rc"
    done
}

[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: P5_P2_RUNS must be positive" >&2; exit 2; }
[[ "$DOWNLOADS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: P5_P2_DOWNLOADS must be positive" >&2; exit 2; }

if [[ "${1:-}" == "--detach" ]]; then
    shift
    LOG="$HOME/Downloads/P5_P2_GOODPUT_${TAG}.mac.log"
    PIDFILE="$HOME/Downloads/P5_P2_GOODPUT_${TAG}.mac.pid"
    if [[ -f "$PIDFILE" ]]; then
        old="$(cat "$PIDFILE" 2>/dev/null || true)"
        if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
            echo "ERROR: goodput screen already alive PID=$old" >&2
            exit 70
        fi
    fi
    nohup caffeinate -dimsu env \
        GREENQUIC_REPO="$REPO_ROOT" \
        P5_P2_GOODPUT_TAG="$TAG" \
        P5_P2_RUNS="$RUNS" \
        P5_P2_DOWNLOADS="$DOWNLOADS" \
        P5_P2_START_DELAY_SECONDS="$START_DELAY" \
        bash "$0" --foreground "$@" >"$LOG" 2>&1 </dev/null &
    pid=$!
    echo "$pid" > "$PIDFILE"
    disown "$pid" 2>/dev/null || true
    echo "STARTED P2 GOODPUT V4 PID=$pid"
    echo "TAG=$TAG"
    echo "LOG=$LOG"
    echo "FINAL_EXPORT=$EXPORT_LOCAL"
    exit 0
fi
[[ "${1:-}" == "--foreground" ]] && shift || true
[[ $# -eq 0 ]] || { echo "ERROR: unknown arguments: $*" >&2; exit 2; }

if [[ -d "$LOCAL_LOCK" ]]; then
    old="$(cat "$LOCAL_LOCK/pid" 2>/dev/null || true)"
    if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
        echo "ERROR: another P2 goodput screen is alive PID=$old" >&2
        exit 70
    fi
    rm -rf "$LOCAL_LOCK"
fi
mkdir -p "$LOCAL_LOCK"
echo $$ > "$LOCAL_LOCK/pid"
cleanup(){ rm -rf "$LOCAL_LOCK"; rm -f "$BUNDLE" "$REMOTE_SCRIPT_LOCAL"; }
trap cleanup EXIT INT TERM

for pf in \
    "$HOME/Downloads"/P5_P1_P2_CHAIN_V2_*.pid \
    "$HOME/Downloads"/P5_P1_P2_CHAIN_V3_*.pid \
    "$HOME/Downloads"/P5_P1_P2_CHAIN_V4_*.pid \
    "$HOME/Downloads"/P5_P2_IDLE_POWER_*.mac.pid \
    "$HOME/Downloads"/P5_P2_GOODPUT_*.mac.pid; do
    [[ -f "$pf" ]] || continue
    [[ "$pf" == "$HOME/Downloads/P5_P2_GOODPUT_${TAG}.mac.pid" ]] && continue
    p="$(cat "$pf" 2>/dev/null || true)"
    if [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; then
        echo "ERROR: existing P5 orchestrator is alive PID=$p ($pf)" >&2
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
    case "$cmd" in *run_matrix_with_sheet.sh*|*.run_matrix_fixed.*|*run_client.sh*|*run_server.sh*|*run_p7.sh*|*run_p5_performance2_sweep.sh*|*run_p5_performance2_selected_profiles.sh*|*run_p5_performance2_idle_power_screen.sh*|*run_p5_performance2_goodput_screen.sh*) bad=1;; esac
done
if fuser /var/run/dpdk/rte/config >/dev/null 2>&1; then bad=1; fi
exit "$bad"
CHECK
    else
        ssh "${SSH_OPTS[@]}" idex "ssh -o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3 root@tinyman 'bash -s'" <<'CHECK'
set +e
bad=0
for p in /proc/[0-9]*; do
    exe=$(readlink -f "$p/exe" 2>/dev/null || true)
    case "$exe" in */quicinterop|*/quicinteropserver) bad=1;; esac
    cmd=$(cat "$p/cmdline" 2>/dev/null | tr '\0' ' ' || true)
    case "$cmd" in *run_matrix_with_sheet.sh*|*.run_matrix_fixed.*|*run_client.sh*|*run_server.sh*|*run_p7.sh*|*run_p5_performance2_sweep.sh*|*run_p5_performance2_selected_profiles.sh*|*run_p5_performance2_idle_power_screen.sh*|*run_p5_performance2_goodput_screen.sh*) bad=1;; esac
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

fetch_bundle(){
    local rc
    cd "$REPO_ROOT"
    while ! git fetch origin "$BRANCH"; do log "git fetch failed; retry in 30 s"; sleep 30; done
    SHA="$(git rev-parse "origin/$BRANCH")"
    REF="refs/heads/__p2_goodput_${TAG}_$$"
    git update-ref "$REF" "$SHA"
    rm -f "$BUNDLE"
    git bundle create "$BUNDLE" "$REF"
    git update-ref -d "$REF"
    scp_to_idex_retry "$BUNDLE" "$REMOTE_BUNDLE"
    while true; do
        if ssh "${SSH_OPTS[@]}" idex "scp -o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3 '$REMOTE_BUNDLE' root@tinyman:'$REMOTE_BUNDLE'"; then
            break
        else
            rc=$?
        fi
        if (( rc == 255 )); then
            log "idex -> tinyman SCP transport failed; retry in 30 s"
            sleep 30
            continue
        fi
        echo "ERROR: idex -> tinyman bundle SCP failed rc=$rc" >&2
        return "$rc"
    done
    log "P2_SHA=$SHA"
}

sync_branch(){
    ssh_transport_retry "cd /root/mohsen && git reset --hard && git fetch '$REMOTE_BUNDLE' '$REF' && git checkout -B '$BRANCH' FETCH_HEAD && test \"\$(git rev-parse HEAD)\" = '$SHA'"
    ssh_transport_retry "ssh -o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3 root@tinyman 'cd /root/mohsen && git reset --hard && git fetch \"$REMOTE_BUNDLE\" \"$REF\" && git checkout -B \"$BRANCH\" FETCH_HEAD && test \"\$(git rev-parse HEAD)\" = \"$SHA\"'"
}

make_remote_runner(){
    cat > "$REMOTE_SCRIPT_LOCAL" <<'REMOTE'
#!/usr/bin/env bash
set +e
TAG="$1"; SELF_LOG="$2"; SHA="$3"; RUNS="$4"; DOWNLOADS="$5"
P5=/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads
RESULT="/tmp/P5_P2_GOODPUT_SCREEN_${TAG}"
MATRIX="$P5/matrix_results/P5_P2_GOODPUT_SCREEN_${TAG}"
EX="/tmp/P5_P2_GOODPUT_EXPORT_${TAG}"
rm -rf "$EX"; mkdir -p "$EX"
cd "$P5" || exit 90
STAMP="$TAG" RESULT_ROOT="$RESULT" MATRIX_ROOT="$MATRIX" \
P5_P2_RUNS="$RUNS" P5_P2_DOWNLOADS="$DOWNLOADS" P5_P2_CHART_STYLE=both \
bash ./run_p5_performance2_goodput_screen.sh
RRC=$?
cp -f "$RESULT/goodput_screen_summary.tsv" "$EX/" 2>/dev/null || true
cp -f "$RESULT/goodput_screen_vs_baseline.tsv" "$EX/" 2>/dev/null || true
cp -f "$RESULT/status.env" "$EX/" 2>/dev/null || true
cp -f "$SELF_LOG" "$EX/remote.log" 2>/dev/null || true
[ -d "$RESULT" ] && (cd /tmp && zip -qr "$EX/analysis__P5_P2_GOODPUT_SCREEN_${TAG}.zip" "P5_P2_GOODPUT_SCREEN_${TAG}")
[ -d "$MATRIX" ] && (cd "$(dirname "$MATRIX")" && zip -qr "$EX/matrix__P5_P2_GOODPUT_SCREEN_${TAG}.zip" "$(basename "$MATRIX")")
printf 'REMOTE_SCRIPT_RC=%s\nP2_SHA=%s\nRUNS=%s\nDOWNLOADS=%s\n' "$RRC" "$SHA" "$RUNS" "$DOWNLOADS" > "$EX/result_rc.txt"

cd "$EX" || exit 91
rm -f SHA256SUMS SHA256SUMS.tmp DONE EXPORT_FAILED
# This is a standalone remote script, not a nested quoted one-liner. -print0 is
# therefore preserved correctly; this fixes the earlier "filename0filename" manifest bug.
find . -maxdepth 1 -type f \
    ! -name SHA256SUMS ! -name SHA256SUMS.tmp ! -name DONE ! -name EXPORT_FAILED \
    -print0 | sort -z | xargs -0 -r sha256sum > SHA256SUMS.tmp
MRC=$?
if [ "$MRC" -ne 0 ]; then printf 'MANIFEST_RC=%s\n' "$MRC" > EXPORT_FAILED; exit 92; fi
mv SHA256SUMS.tmp SHA256SUMS
sha256sum -c SHA256SUMS >/dev/null 2>&1
VRC=$?
if [ "$VRC" -ne 0 ]; then printf 'VERIFY_RC=%s\n' "$VRC" > EXPORT_FAILED; exit 93; fi
date -Is > DONE
exit 0
REMOTE
    bash -n "$REMOTE_SCRIPT_LOCAL"
}

start_remote_detached(){
    scp_to_idex_retry "$REMOTE_SCRIPT_LOCAL" "$REMOTE_SCRIPT"
    ssh_transport_retry "chmod +x '$REMOTE_SCRIPT'; rm -rf '$EXPORT_REMOTE'; nohup setsid bash '$REMOTE_SCRIPT' '$TAG' '$REMOTE_LOG' '$SHA' '$RUNS' '$DOWNLOADS' >'$REMOTE_LOG' 2>&1 </dev/null & echo \$! > '$REMOTE_PID'; echo REMOTE_PID=\$(cat '$REMOTE_PID')"
}

wait_remote_done(){
    while true; do
        if ssh_once "test -f '$EXPORT_REMOTE/DONE'" >/dev/null 2>&1; then
            log "remote GOODPUT screen DONE detected"; return 0
        fi
        if ssh_once "test -f '$EXPORT_REMOTE/EXPORT_FAILED'" >/dev/null 2>&1; then
            echo "ERROR: remote export failed:" >&2
            ssh_once "cat '$EXPORT_REMOTE/EXPORT_FAILED'; tail -100 '$REMOTE_LOG'" >&2 || true
            return 92
        fi
        log "waiting for P2 goodput screen (Mac->idex SSH failure cannot kill remote nohup job)"
        sleep 60
    done
}

verify_or_copy_export(){
    local remote="$1" localdir="$2" rc
    mkdir -p "$localdir"
    while true; do
        if scp "${SSH_OPTS[@]}" "idex:$remote/SHA256SUMS" "$localdir/SHA256SUMS"; then break; else rc=$?; fi
        if (( rc == 255 )); then log "manifest SCP transport failed; retry in 30 s"; sleep 30; continue; fi
        echo "ERROR: manifest SCP failed rc=$rc" >&2; return "$rc"
    done

    while read -r hash file; do
        [[ -n "${file:-}" ]] || continue
        rel="${file#./}"
        if [[ -f "$localdir/$rel" ]] && printf '%s  %s\n' "$hash" "$rel" | (cd "$localdir" && shasum -a 256 -c - >/dev/null 2>&1); then
            log "already verified $rel"; continue
        fi
        while true; do
            mkdir -p "$(dirname "$localdir/$rel")"
            rm -f "$localdir/$rel.part"
            log "copying $rel"
            if scp "${SSH_OPTS[@]}" "idex:$remote/$rel" "$localdir/$rel.part"; then
                got="$(shasum -a 256 "$localdir/$rel.part" | awk '{print $1}')"
                if [[ "$got" == "$hash" ]]; then mv "$localdir/$rel.part" "$localdir/$rel"; log "verified $rel"; break; fi
                log "hash mismatch for $rel; retry in 60 s"
            else
                rc=$?
                if (( rc != 255 )); then echo "ERROR: SCP failed rc=$rc for $rel" >&2; return "$rc"; fi
                log "SCP transport failed for $rel; retry in 60 s"
            fi
            sleep 60
        done
    done < "$localdir/SHA256SUMS"
    (cd "$localdir" && shasum -a 256 -c SHA256SUMS)
    date "+%Y-%m-%dT%H:%M:%S%z" > "$localdir/SCP_DONE"
    log "SCP + SHA256 VERIFIED: $localdir"
}

log "P2 GOODPUT V4 startup tag=$TAG runs=$RUNS downloads=$DOWNLOADS"
wait_clean_both
sleep "$START_DELAY"
fetch_bundle
sync_branch
wait_clean_both

ssh_transport_retry "cd '/root/mohsen/$P5_REL' && bash -n ./build_p5_performance2.sh && bash -n ./run_p5_performance2_goodput_screen.sh && python3 -m py_compile ./apply_p5_performance2_v2.py ./test_p5_performance2_v2_transform.py && python3 ./test_p5_performance2_v2_transform.py"
ssh_transport_retry "ssh -o ConnectTimeout=15 root@tinyman 'cd /root/mohsen/$P5_REL && bash -n ./build_p5_performance2.sh && bash -n ./run_p5_performance2_goodput_screen.sh && python3 -m py_compile ./apply_p5_performance2_v2.py ./test_p5_performance2_v2_transform.py && python3 ./test_p5_performance2_v2_transform.py'"
log "preflight PASS on idex + tinyman"

make_remote_runner
start_remote_detached
wait_remote_done
verify_or_copy_export "$EXPORT_REMOTE" "$EXPORT_LOCAL"

FAILURES="$(awk -F= '$1=="FAILURES"{v=$2} END{print v+0}' "$EXPORT_LOCAL/status.env" 2>/dev/null || echo 999)"
log "COMPLETE"
log "EXPORT=$EXPORT_LOCAL"
log "FAILURES=$FAILURES"
cat "$EXPORT_LOCAL/goodput_screen_vs_baseline.tsv" 2>/dev/null || true

if [[ "$FAILURES" =~ ^[0-9]+$ ]] && (( FAILURES == 0 )); then exit 0; fi
exit 1
