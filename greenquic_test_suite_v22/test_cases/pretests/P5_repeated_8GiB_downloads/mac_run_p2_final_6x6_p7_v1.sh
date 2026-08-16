#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="${GREENQUIC_REPO:-$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)}"
[[ -n "$REPO_ROOT" && -d "$REPO_ROOT/.git" ]] || { echo "ERROR: run from GreenQUIC repo or set GREENQUIC_REPO" >&2; exit 2; }

BRANCH=performance2/p5-max-goodput
P5_REL=greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads
P7_REL=greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline
RUNS="${P5_FINAL_RUNS:-6}"
DOWNLOADS="${P5_FINAL_DOWNLOADS:-6}"
SEED="${P5_FINAL_SEED:-20260806}"
START_DELAY="${P5_FINAL_START_DELAY_SECONDS:-5}"
TAG="${P5_FINAL_TAG:-$(date +%Y%m%d_%H%M%S)}"
SSH_OPTS=(-o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3)
LOCAL_LOCK="$HOME/Downloads/.greenquic_p2_final_6x6_p7.lock"
BUNDLE="${TMPDIR:-/tmp}/GreenQUIC_P2_FINAL_${TAG}.bundle"
REMOTE_BUNDLE="/tmp/GreenQUIC_P2_FINAL_${TAG}.bundle"
REMOTE_SCRIPT_LOCAL="${TMPDIR:-/tmp}/P5_P2_FINAL_REMOTE_${TAG}_$$.sh"
REMOTE_SCRIPT="/tmp/P5_P2_FINAL_REMOTE_${TAG}.sh"
REMOTE_LOG="/root/P5_P2_FINAL_${TAG}.log"
REMOTE_PID="/tmp/P5_P2_FINAL_${TAG}.pid"
EXPORT_REMOTE="/tmp/P5_P2_FINAL_EXPORT_${TAG}"
EXPORT_LOCAL="$HOME/Downloads/P5_P2_FINAL_EXPORT_${TAG}"

log(){ printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
ssh_once(){ ssh "${SSH_OPTS[@]}" idex "$@"; }

ssh_transport_retry(){
    local rc
    while true; do
        if ssh_once "$@"; then return 0; else rc=$?; fi
        if (( rc == 255 )); then log "SSH transport failed; retrying in 30 s"; sleep 30; continue; fi
        echo "ERROR: remote command failed rc=$rc (not an SSH transport failure)" >&2
        return "$rc"
    done
}

scp_to_idex_retry(){
    local src="$1" dst="$2" rc
    while true; do
        if scp "${SSH_OPTS[@]}" "$src" "idex:$dst"; then return 0; else rc=$?; fi
        if (( rc == 255 )); then log "SCP transport to idex failed; retrying in 30 s"; sleep 30; continue; fi
        echo "ERROR: SCP to idex failed rc=$rc for $src" >&2
        return "$rc"
    done
}

[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: P5_FINAL_RUNS must be positive" >&2; exit 2; }
[[ "$DOWNLOADS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: P5_FINAL_DOWNLOADS must be positive" >&2; exit 2; }
[[ "$SEED" =~ ^[0-9]+$ ]] || { echo "ERROR: P5_FINAL_SEED must be an integer" >&2; exit 2; }

if [[ "${1:-}" == "--detach" ]]; then
    shift
    LOG="$HOME/Downloads/P5_P2_FINAL_${TAG}.mac.log"
    PIDFILE="$HOME/Downloads/P5_P2_FINAL_${TAG}.mac.pid"
    if [[ -f "$PIDFILE" ]]; then
        old="$(cat "$PIDFILE" 2>/dev/null || true)"
        if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
            echo "ERROR: final P2/P7 runner already alive PID=$old" >&2
            exit 70
        fi
    fi
    nohup caffeinate -dimsu env \
        GREENQUIC_REPO="$REPO_ROOT" \
        P5_FINAL_TAG="$TAG" \
        P5_FINAL_RUNS="$RUNS" \
        P5_FINAL_DOWNLOADS="$DOWNLOADS" \
        P5_FINAL_SEED="$SEED" \
        P5_FINAL_START_DELAY_SECONDS="$START_DELAY" \
        bash "$0" --foreground "$@" >"$LOG" 2>&1 </dev/null &
    pid=$!
    echo "$pid" > "$PIDFILE"
    disown "$pid" 2>/dev/null || true
    echo "STARTED P2 FINAL 6x6 + P7 PID=$pid"
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
        echo "ERROR: another final validation runner is alive PID=$old" >&2
        exit 70
    fi
    rm -rf "$LOCAL_LOCK"
fi
mkdir -p "$LOCAL_LOCK"
echo $$ > "$LOCAL_LOCK/pid"
cleanup(){ rm -rf "$LOCAL_LOCK"; rm -f "$BUNDLE" "$REMOTE_SCRIPT_LOCAL"; }
trap cleanup EXIT INT TERM

# Refuse to overlap the earlier P5 orchestrators if their Mac processes are still alive.
for pf in \
    "$HOME/Downloads"/P5_P2_GOODPUT_*.mac.pid \
    "$HOME/Downloads"/P5_P2_PLUS_IDLE_*.mac.pid \
    "$HOME/Downloads"/P5_P2_FINAL_*.mac.pid; do
    [[ -f "$pf" ]] || continue
    [[ "$pf" == "$HOME/Downloads/P5_P2_FINAL_${TAG}.mac.pid" ]] && continue
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
    case "$cmd" in *run_matrix_with_sheet.sh*|*.run_matrix_fixed.*|*run_matrix_with_report.sh*|*run_matrix_from_idex.sh*|*run_client.sh*|*run_server.sh*|*P5_P2_FINAL_REMOTE*) bad=1;; esac
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
    case "$cmd" in *run_matrix_with_sheet.sh*|*.run_matrix_fixed.*|*run_matrix_with_report.sh*|*run_matrix_from_idex.sh*|*run_client.sh*|*run_server.sh*|*P5_P2_FINAL_REMOTE*) bad=1;; esac
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
    REF="refs/heads/__p2_final_${TAG}_$$"
    git update-ref "$REF" "$SHA"
    rm -f "$BUNDLE"
    git bundle create "$BUNDLE" "$REF"
    git update-ref -d "$REF"
    scp_to_idex_retry "$BUNDLE" "$REMOTE_BUNDLE"
    while true; do
        if ssh "${SSH_OPTS[@]}" idex "scp -o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3 '$REMOTE_BUNDLE' root@tinyman:'$REMOTE_BUNDLE'"; then break; else rc=$?; fi
        if (( rc == 255 )); then log "idex -> tinyman bundle SCP transport failed; retry in 30 s"; sleep 30; continue; fi
        echo "ERROR: idex -> tinyman bundle SCP failed rc=$rc" >&2
        return "$rc"
    done
    log "FINAL_SHA=$SHA"
}

sync_branch(){
    ssh_transport_retry "cd /root/mohsen && git reset --hard && git fetch '$REMOTE_BUNDLE' '$REF' && git checkout -B '$BRANCH' FETCH_HEAD && test \"\$(git rev-parse HEAD)\" = '$SHA'"
    ssh_transport_retry "ssh -o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3 root@tinyman 'cd /root/mohsen && git reset --hard && git fetch \"$REMOTE_BUNDLE\" \"$REF\" && git checkout -B \"$BRANCH\" FETCH_HEAD && test \"\$(git rev-parse HEAD)\" = \"$SHA\"'"
}

make_remote_runner(){
    cat > "$REMOTE_SCRIPT_LOCAL" <<'REMOTE'
#!/usr/bin/env bash
set +e
TAG="$1"; SELF_LOG="$2"; SHA="$3"; RUNS="$4"; DOWNLOADS="$5"; SEED="$6"
ROOT=/root/mohsen
P5="$ROOT/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
P7="$ROOT/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline"
MON="$P5/matrix_results/P5_P2_FINAL_idle_monitor_${RUNS}r_${DOWNLOADS}d_${TAG}"
PWR="$P5/matrix_results/P5_P2_FINAL_power_friendly_${RUNS}r_${DOWNLOADS}d_${TAG}"
P7OUT="$P7/matrix_results/P7_FINAL_linux_native_${RUNS}r_${DOWNLOADS}d_${TAG}"
EX="/tmp/P5_P2_FINAL_EXPORT_${TAG}"
mkdir -p "$EX"
rm -f "$EX"/DONE "$EX"/EXPORT_FAILED "$EX"/SHA256SUMS "$EX"/SHA256SUMS.tmp

clean_host_local(){
    pkill -TERM -f 'quicinteropserver|quicinterop' 2>/dev/null || true
    sleep 1
    pkill -KILL -f 'quicinteropserver|quicinterop' 2>/dev/null || true
    if ! fuser /var/run/dpdk/rte/config >/dev/null 2>&1; then rm -rf /var/run/dpdk/rte; fi
}
clean_host_remote(){
    ssh -o ConnectTimeout=15 root@tinyman 'pkill -TERM -f "quicinteropserver|quicinterop" 2>/dev/null || true; sleep 1; pkill -KILL -f "quicinteropserver|quicinterop" 2>/dev/null || true; if ! fuser /var/run/dpdk/rte/config >/dev/null 2>&1; then rm -rf /var/run/dpdk/rte; fi' || true
}

# Build the promoted Performance2 default on both endpoints.
echo '=== BUILD P5 PROMOTED PERFORMANCE2 DEFAULT ==='
(cd "$P5" && P5_BUILD_REUSE=1 bash ./build_p5_performance2.sh >"$EX/build_p5_idex.log" 2>&1) & p1=$!
ssh -n root@tinyman "cd '$P5' && P5_BUILD_REUSE=1 bash ./build_p5_performance2.sh" >"$EX/build_p5_tinyman.log" 2>&1 & p2=$!
wait "$p1"; BP51=$?
wait "$p2"; BP52=$?
echo "P5 builds: idex=$BP51 tinyman=$BP52"

P5_MARKER='GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0'
VP51=1; VP52=1
if [ "$BP51" -eq 0 ]; then grep -aFq -- "$P5_MARKER" "$ROOT/msquic/build-greenquic-p5/bin/Release/quicinterop"; VP51=$?; fi
if [ "$BP52" -eq 0 ]; then ssh -n root@tinyman "grep -aFq -- '$P5_MARKER' '$ROOT/msquic/build-greenquic-p5/bin/Release/quicinterop'"; VP52=$?; fi
echo "P5 promoted-marker verify: idex=$VP51 tinyman=$VP52"

# Build the isolated normal-Linux P7 binaries on both endpoints before measurement.
echo '=== BUILD P7 LINUX ==='
(cd "$P7" && bash ./build_p7_linux.sh >"$EX/build_p7_idex.log" 2>&1) & p3=$!
ssh -n root@tinyman "cd '$P7' && bash ./build_p7_linux.sh" >"$EX/build_p7_tinyman.log" 2>&1 & p4=$!
wait "$p3"; BP71=$?
wait "$p4"; BP72=$?
echo "P7 builds: idex=$BP71 tinyman=$BP72"

RC1=98; RC2=98; RC3=98
if [ "$BP51" -eq 0 ] && [ "$BP52" -eq 0 ] && [ "$VP51" -eq 0 ] && [ "$VP52" -eq 0 ]; then
    run_p5(){
        local out="$1"; shift
        cd "$P5" || return 90
        bash ./run_matrix_with_sheet.sh \
            --chart-style both \
            --client-host tinyman \
            --client-dir "$P5" \
            --client-bin "$ROOT/msquic/build-greenquic-p5/bin/Release/quicinterop" \
            --downloads "$DOWNLOADS" \
            --gap-seconds 5 \
            --server-cooldown-seconds 5 \
            --between-tests-seconds 0 \
            --cstate-cpu 19 \
            --runs "$RUNS" \
            --mode-order balanced \
            --seed "$SEED" \
            --output-dir "$out" \
            --env ENABLE_RECORD=1 \
            --env GQ_LOG_LEVEL=0 \
            "$@"
    }

    echo '=== 1/3 P5 IDLE_MONITOR_NORMAL — OFF/BASIC/PLUS ==='
    run_p5 "$MON" \
        --env GQ_IDLE_MODE_OVERRIDE=monitor \
        --env GQ_IDLE_FALLBACK_OVERRIDE=short
    RC1=$?
    echo "P5 IDLE_MONITOR_NORMAL RC=$RC1"

    clean_host_local; clean_host_remote

    echo '=== 2/3 P5 POWER_FRIENDLY — OFF/BASIC/PLUS ==='
    run_p5 "$PWR" \
        --env ENABLE_FREQ=1 \
        --env ENABLE_SLEEP=1 \
        --env GQ_IDLE_MODE_OVERRIDE=epoll \
        --env GQ_IDLE_FALLBACK_OVERRIDE=short
    RC2=$?
    echo "P5 POWER_FRIENDLY RC=$RC2"
else
    echo 'ERROR: promoted P5 build/marker verification failed; P5 matrices skipped.'
fi

clean_host_local; clean_host_remote

if [ "$BP71" -eq 0 ] && [ "$BP72" -eq 0 ]; then
    echo '=== 3/3 P7 PRIMARY LINUX UDP BASELINE ==='
    cd "$P7" || exit 90
    bash ./run_matrix_with_report.sh \
        --chart-style both \
        --log-level 0 \
        --client-host tinyman \
        --client-dir "$P7" \
        --downloads "$DOWNLOADS" \
        --gap-seconds 5 \
        --runs "$RUNS" \
        --pre-cooldown-seconds 5 \
        --post-cooldown-seconds 5 \
        --between-runs-seconds 5 \
        --dataplane-cpu 19 \
        --quic-cpus 21,22,23,24 \
        --pin-irq 1 \
        --pin-quic 1 \
        --disable-rps 1 \
        --nic-offloads native \
        --record-quic-cpus 0 \
        --enable-record 1 \
        --rapl-interval-ms 6 \
        --freq-interval-ms 1 \
        --require-rapl 1 \
        --stop-irqbalance 1 \
        --mtu 1500 \
        --output-dir "$P7OUT"
    RC3=$?
    echo "P7 LINUX RC=$RC3"
else
    echo 'ERROR: P7 build failed; P7 matrix skipped.'
fi

printf 'P5_BUILD_IDEX=%s\nP5_BUILD_TINYMAN=%s\nP5_MARKER_IDEX=%s\nP5_MARKER_TINYMAN=%s\nP7_BUILD_IDEX=%s\nP7_BUILD_TINYMAN=%s\nP5_IDLE_RC=%s\nP5_POWER_RC=%s\nP7_RC=%s\n' \
    "$BP51" "$BP52" "$VP51" "$VP52" "$BP71" "$BP72" "$RC1" "$RC2" "$RC3" > "$EX/status.env"
printf 'branch=performance2/p5-max-goodput\ncommit=%s\nruns=%s\ndownloads=%s\nseed=%s\nP5_default=txalloc8+no_TxEnqueueCounter+RXpipe2+safe_TX_zero\nP5_idle=%s\nP5_power=%s\nP7=%s\nP7_config=native_offloads+IRQ_CPU19+QUIC_21_22_23_24+pinning+RPS_off\n' \
    "$SHA" "$RUNS" "$DOWNLOADS" "$SEED" "$MON" "$PWR" "$P7OUT" > "$EX/source_paths.txt"
printf '%s %s %s\n' "$RC1" "$RC2" "$RC3" > "$EX/test_rc.txt"
cp -f "$SELF_LOG" "$EX/remote.log" 2>/dev/null || true

zip_one(){
    local src="$1" label="$2"
    [ -d "$src" ] || return 0
    (cd "$(dirname "$src")" && zip -qr "$EX/${label}.zip" "$(basename "$src")")
}
zip_one "$MON" "P5_IDLE_MONITOR_${RUNS}r_${DOWNLOADS}d_${TAG}"
zip_one "$PWR" "P5_POWER_FRIENDLY_${RUNS}r_${DOWNLOADS}d_${TAG}"
zip_one "$P7OUT" "P7_LINUX_NATIVE_${RUNS}r_${DOWNLOADS}d_${TAG}"

cd "$EX" || exit 91
rm -f SHA256SUMS SHA256SUMS.tmp DONE EXPORT_FAILED
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
    ssh_transport_retry "chmod +x '$REMOTE_SCRIPT'; rm -rf '$EXPORT_REMOTE'; nohup setsid bash '$REMOTE_SCRIPT' '$TAG' '$REMOTE_LOG' '$SHA' '$RUNS' '$DOWNLOADS' '$SEED' >'$REMOTE_LOG' 2>&1 </dev/null & echo \$! > '$REMOTE_PID'; echo REMOTE_PID=\$(cat '$REMOTE_PID')"
}

wait_remote_done(){
    while true; do
        if ssh_once "test -f '$EXPORT_REMOTE/DONE'" >/dev/null 2>&1; then
            log "remote final P5/P7 suite DONE detected"
            return 0
        fi
        if ssh_once "test -f '$EXPORT_REMOTE/EXPORT_FAILED'" >/dev/null 2>&1; then
            echo "ERROR: remote export failed:" >&2
            ssh_once "cat '$EXPORT_REMOTE/EXPORT_FAILED'; tail -150 '$REMOTE_LOG'" >&2 || true
            return 92
        fi
        log "waiting for final 6x6 P5/P7 suite (Mac->idex SSH failure cannot kill remote nohup job)"
        sleep 60
    done
}

verify_or_copy_export(){
    local remote="$1" localdir="$2" rc rel got
    mkdir -p "$localdir"
    while true; do
        if scp "${SSH_OPTS[@]}" "idex:$remote/SHA256SUMS" "$localdir/SHA256SUMS"; then break; else rc=$?; fi
        if (( rc == 255 )); then log "manifest SCP transport failed; retry in 30 s"; sleep 30; continue; fi
        echo "ERROR: manifest SCP failed rc=$rc" >&2
        return "$rc"
    done

    while read -r hash file; do
        [[ -n "${file:-}" ]] || continue
        rel="${file#./}"
        if [[ -f "$localdir/$rel" ]] && printf '%s  %s\n' "$hash" "$rel" | (cd "$localdir" && shasum -a 256 -c - >/dev/null 2>&1); then
            log "already verified $rel"
            continue
        fi
        while true; do
            mkdir -p "$(dirname "$localdir/$rel")"
            rm -f "$localdir/$rel.part"
            log "copying $rel"
            if scp "${SSH_OPTS[@]}" "idex:$remote/$rel" "$localdir/$rel.part"; then
                got="$(shasum -a 256 "$localdir/$rel.part" | awk '{print $1}')"
                if [[ "$got" == "$hash" ]]; then
                    mv "$localdir/$rel.part" "$localdir/$rel"
                    log "verified $rel"
                    break
                fi
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

log "P2 FINAL startup tag=$TAG runs=$RUNS downloads=$DOWNLOADS seed=$SEED"
wait_clean_both
sleep "$START_DELAY"
fetch_bundle
sync_branch
wait_clean_both

ssh_transport_retry "cd '/root/mohsen/$P5_REL' && bash -n ./build_p5_performance2.sh ./run_matrix_with_sheet.sh && python3 -m py_compile ./apply_p5_performance2.py ./test_p5_performance2_transform.py ./apply_p5_performance2_v2.py ./test_p5_performance2_v2_transform.py && python3 ./test_p5_performance2_transform.py && python3 ./test_p5_performance2_v2_transform.py && cd '/root/mohsen/$P7_REL' && bash -n ./build_p7_linux.sh ./run_matrix_with_report.sh ./run_matrix_from_idex.sh"
ssh_transport_retry "ssh -o ConnectTimeout=15 root@tinyman 'cd /root/mohsen/$P5_REL && bash -n ./build_p5_performance2.sh ./run_matrix_with_sheet.sh && python3 -m py_compile ./apply_p5_performance2.py ./test_p5_performance2_transform.py ./apply_p5_performance2_v2.py ./test_p5_performance2_v2_transform.py && python3 ./test_p5_performance2_transform.py && python3 ./test_p5_performance2_v2_transform.py && cd /root/mohsen/$P7_REL && bash -n ./build_p7_linux.sh ./run_matrix_with_report.sh ./run_matrix_from_idex.sh'"
log "preflight PASS on idex + tinyman"

make_remote_runner
start_remote_detached
wait_remote_done
verify_or_copy_export "$EXPORT_REMOTE" "$EXPORT_LOCAL"

log "COMPLETE"
log "EXPORT=$EXPORT_LOCAL"
cat "$EXPORT_LOCAL/status.env" 2>/dev/null || true

read -r RC1 RC2 RC3 < "$EXPORT_LOCAL/test_rc.txt" || true
if [[ "${RC1:-}" =~ ^[0-9]+$ && "${RC2:-}" =~ ^[0-9]+$ && "${RC3:-}" =~ ^[0-9]+$ ]] && (( RC1 == 0 && RC2 == 0 && RC3 == 0 )); then
    exit 0
fi
exit 1
