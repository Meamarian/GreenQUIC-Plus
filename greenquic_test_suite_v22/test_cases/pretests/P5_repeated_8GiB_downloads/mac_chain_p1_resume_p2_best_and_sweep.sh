#!/usr/bin/env bash
set -u

REPO_ROOT="${GREENQUIC_REPO:-}"
if [ -z "$REPO_ROOT" ]; then
    HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
    REPO_ROOT="$(cd -- "$HERE/../../../.." && pwd)"
fi
CHAIN_TAG="${CHAIN_TAG:-$(date +%Y%m%d_%H%M%S)}"
P1_BRANCH="performance/p5-max-goodput"
P2_BRANCH="performance2/p5-max-goodput"
P2_BEST_PROFILE="${P5_P2_BEST_PROFILE:-sharded_udp4}"
SSH_OPTS=(-o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3)
TMPBASE="${TMPDIR:-/tmp}"
BUNDLE="$TMPBASE/GreenQUIC_P1_P2_CHAIN_${CHAIN_TAG}.bundle"
REMOTE_BUNDLE="/tmp/GreenQUIC_P1_P2_CHAIN_${CHAIN_TAG}.bundle"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

retry_ssh() {
    while true; do
        ssh "${SSH_OPTS[@]}" idex "$@" && return 0
        log "SSH to idex failed; retrying in 30 s"
        sleep 30
    done
}

retry_scp_to_idex() {
    local src="$1" dst="$2"
    while true; do
        scp "${SSH_OPTS[@]}" "$src" "idex:$dst" && return 0
        log "SCP to idex failed; retrying in 30 s"
        sleep 30
    done
}

check_clean_idex_once() {
    ssh "${SSH_OPTS[@]}" idex 'bash -s' <<'CHECK'
set +e
bad=0
for p in /proc/[0-9]*; do
    pid="${p##*/}"
    exe=$(readlink -f "$p/exe" 2>/dev/null || true)
    case "$exe" in
        */quicinterop|*/quicinteropserver)
            echo "ACTIVE PID=$pid EXE=$exe"
            bad=1
            ;;
    esac
    cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null || true)
    case "$cmd" in
        *run_matrix_with_sheet.sh*|*.run_matrix_fixed.*|*run_client.sh*|*run_server.sh*|*run_p7.sh*|*run_p5_performance2_sweep.sh*)
            echo "ACTIVE PID=$pid CMD=$cmd"
            bad=1
            ;;
    esac
done
if fuser /var/run/dpdk/rte/config >/dev/null 2>&1; then
    echo "ACTIVE DPDK holder"
    fuser -v /var/run/dpdk/rte/config 2>/dev/null || true
    bad=1
else
    echo "DPDK: No holder"
fi
[ "$bad" -eq 0 ] && echo CLEAN
exit "$bad"
CHECK
}

check_clean_tinyman_once() {
    ssh "${SSH_OPTS[@]}" idex "ssh -o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3 root@tinyman 'bash -s'" <<'CHECK'
set +e
bad=0
for p in /proc/[0-9]*; do
    pid="${p##*/}"
    exe=$(readlink -f "$p/exe" 2>/dev/null || true)
    case "$exe" in
        */quicinterop|*/quicinteropserver)
            echo "ACTIVE PID=$pid EXE=$exe"
            bad=1
            ;;
    esac
    cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null || true)
    case "$cmd" in
        *run_matrix_with_sheet.sh*|*.run_matrix_fixed.*|*run_client.sh*|*run_server.sh*|*run_p7.sh*|*run_p5_performance2_sweep.sh*)
            echo "ACTIVE PID=$pid CMD=$cmd"
            bad=1
            ;;
    esac
done
if fuser /var/run/dpdk/rte/config >/dev/null 2>&1; then
    echo "ACTIVE DPDK holder"
    fuser -v /var/run/dpdk/rte/config 2>/dev/null || true
    bad=1
else
    echo "DPDK: No holder"
fi
[ "$bad" -eq 0 ] && echo CLEAN
exit "$bad"
CHECK
}

wait_clean_both() {
    log "Waiting until idex is clean"
    until check_clean_idex_once; do
        log "idex still active/unreachable; checking again in 30 s"
        sleep 30
    done
    log "Waiting until tinyman is clean"
    until check_clean_tinyman_once; do
        log "tinyman still active/unreachable; checking again in 30 s"
        sleep 30
    done
    log "Both hosts are clean"
}

make_remote_manifest() {
    local remote="$1"
    retry_ssh "cd '$remote' && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\\0' | sort -z | xargs -0 -r sha256sum > SHA256SUMS.tmp && mv SHA256SUMS.tmp SHA256SUMS"
}

copy_export_verified() {
    local remote="$1" localdir="$2"
    local manifest="$localdir/SHA256SUMS"
    mkdir -p "$localdir"
    make_remote_manifest "$remote"
    while true; do
        scp "${SSH_OPTS[@]}" "idex:$remote/SHA256SUMS" "$manifest" && break
        log "Could not fetch SHA256SUMS from $remote; retrying in 30 s"
        sleep 30
    done
    while read -r hash file; do
        [ -n "${file:-}" ] || continue
        if [ -f "$localdir/$file" ] && printf '%s  %s\n' "$hash" "$file" | (cd "$localdir" && shasum -a 256 -c - >/dev/null 2>&1); then
            log "Already verified: $file"
            continue
        fi
        while true; do
            log "SCP $file"
            scp "${SSH_OPTS[@]}" "idex:$remote/$file" "$localdir/$file" || true
            if [ -f "$localdir/$file" ] && printf '%s  %s\n' "$hash" "$file" | (cd "$localdir" && shasum -a 256 -c - >/dev/null 2>&1); then
                log "SHA256 verified: $file"
                break
            fi
            log "SCP/hash incomplete for $file; retrying in 60 s"
            sleep 60
        done
    done < "$manifest"
    if (cd "$localdir" && shasum -a 256 -c SHA256SUMS); then
        touch "$localdir/SCP_DONE"
        log "EXPORT FULLY COPIED + SHA256 VERIFIED: $localdir"
        return 0
    fi
    log "Final hash verification failed; retrying export"
    sleep 30
    copy_export_verified "$remote" "$localdir"
}

verify_previous_export_if_any() {
    local prev localdir
    prev="$(retry_ssh 'for d in /tmp/P5_RESUME_EXPORT_* /tmp/P5_P7_FINAL_EXPORT_*; do [ -d "$d" ] && [ -f "$d/DONE" ] && printf "%s %s\n" "$(stat -c %Y "$d" 2>/dev/null || echo 0)" "$d"; done | sort -nr | head -1 | cut -d" " -f2-' || true)"
    if [ -z "$prev" ]; then
        log "No previous completed export directory found; process-clean checks are sufficient"
        return 0
    fi
    localdir="$HOME/Downloads/$(basename "$prev")"
    log "Verifying previous completed export before new testing: $prev"
    copy_export_verified "$prev" "$localdir"
}

fetch_and_bundle() {
    cd "$REPO_ROOT" || exit 10
    while ! git fetch origin "$P1_BRANCH" "$P2_BRANCH"; do
        log "git fetch failed; retrying in 30 s"
        sleep 30
    done
    P1_SHA="$(git rev-parse "origin/$P1_BRANCH")"
    P2_SHA="$(git rev-parse "origin/$P2_BRANCH")"
    git branch -f __p1p2_chain_p1 "$P1_SHA" >/dev/null
    git branch -f __p1p2_chain_p2 "$P2_SHA" >/dev/null
    rm -f "$BUNDLE"
    git bundle create "$BUNDLE" __p1p2_chain_p1 __p1p2_chain_p2
    git branch -D __p1p2_chain_p1 __p1p2_chain_p2 >/dev/null 2>&1 || true
    retry_scp_to_idex "$BUNDLE" "$REMOTE_BUNDLE"
    retry_ssh "while ! scp -o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3 '$REMOTE_BUNDLE' root@tinyman:'$REMOTE_BUNDLE'; do echo 'bundle copy to tinyman failed; retrying'; sleep 30; done"
    log "P1_SHA=$P1_SHA"
    log "P2_SHA=$P2_SHA"
}

sync_branch_both() {
    local branch="$1" tempref="$2" expected="$3"
    log "Syncing $branch to idex"
    retry_ssh "cd /root/mohsen && git reset --hard && git fetch '$REMOTE_BUNDLE' 'refs/heads/$tempref' && git checkout -B '$branch' FETCH_HEAD && test \"\$(git rev-parse HEAD)\" = '$expected'"
    log "Syncing $branch to tinyman"
    retry_ssh "ssh -o ConnectTimeout=15 root@tinyman \"cd /root/mohsen && git reset --hard && git fetch '$REMOTE_BUNDLE' 'refs/heads/$tempref' && git checkout -B '$branch' FETCH_HEAD && test \\\"\\\$(git rev-parse HEAD)\\\" = '$expected'\""
}

start_remote_job() {
    local script_local="$1" script_remote="$2" logfile="$3" pidfile="$4" donefile="$5" arg="$6"
    retry_scp_to_idex "$script_local" "$script_remote"
    retry_ssh "chmod +x '$script_remote'; if [ -f '$donefile' ]; then echo 'JOB ALREADY DONE'; elif [ -s '$pidfile' ] && kill -0 \$(cat '$pidfile') 2>/dev/null; then echo \"JOB ALREADY RUNNING PID=\$(cat '$pidfile')\"; else nohup bash '$script_remote' '$arg' '$logfile' >'$logfile' 2>&1 </dev/null & echo \$! >'$pidfile'; echo \"JOB STARTED PID=\$(cat '$pidfile')\"; fi"
}

wait_remote_done() {
    local donefile="$1" logfile="$2"
    while true; do
        if ssh "${SSH_OPTS[@]}" idex "test -f '$donefile'" >/dev/null 2>&1; then
            return 0
        fi
        log "Remote job still running or SSH unavailable: $logfile"
        sleep 60
    done
}

wait_remote_pid_gone() {
    local pidfile="$1"
    while retry_ssh "if [ -s '$pidfile' ] && kill -0 \$(cat '$pidfile') 2>/dev/null; then exit 1; else exit 0; fi"; do
        return 0
    done
}

create_p1_runner() {
    local path="$1"
    cat > "$path" <<'REMOTE'
#!/usr/bin/env bash
set +e
TAG="$1"
SELF_LOG="$2"
P5=/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads
P7=/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline
EX="/tmp/P5_RESUME_EXPORT_${TAG}"
mkdir -p "$EX"
finalize() {
    rc=$?
    printf 'REMOTE_SCRIPT_RC=%s\n' "$rc" >> "$EX/result_rc.txt"
    [ -f "$SELF_LOG" ] && cp "$SELF_LOG" "$EX/resume_remote.log" 2>/dev/null || true
    (cd "$EX" && find . -maxdepth 1 -type f ! -name SHA256SUMS ! -name DONE -printf '%f\0' | sort -z | xargs -0 -r sha256sum > SHA256SUMS)
    date > "$EX/DONE"
    exit 0
}
trap finalize EXIT
latest_complete_p5() {
    pattern="$1"
    while IFS= read -r d; do
        [ -d "$d" ] || continue
        if grep -R -q 'SUCCESS: all 18/18 P5 workloads completed' "$d" 2>/dev/null; then
            printf '%s\n' "$d"
            return 0
        fi
    done < <(find "$P5/matrix_results" -maxdepth 1 -type d -name "$pattern" -printf '%T@ %p\n' 2>/dev/null | sort -nr | cut -d' ' -f2-)
    return 1
}
zip_one() {
    src="$1"
    label="$2"
    if [ -d "$src" ]; then
        (cd "$(dirname "$src")" && zip -qr "$EX/${label}__$(basename "$src").zip" "$(basename "$src")")
    else
        echo "WARNING missing source for $label: $src"
    fi
}
PERF_ENV="P5_BUILD_REUSE=1 P5_SUPER_CACHE=128 P5_SUPER_RX_BURST=32 P5_SUPER_TX_BURST=16 P5_SUPER_RING_SIZE=4096 P5_SUPER_RING_SYNC=legacy P5_SUPER_DRAIN_BURSTS=2 P5_SUPER_DRAIN_THRESHOLD=0 P5_SUPER_MTU=0 P5_SUPER_SKIP_OFF_RINGCOUNT=0 P5_SUPER_DEBUG_COUNTERS=1 P5_SUPER_TRANSFER_WINDOW=1 P5_SUPER_TRACE_RINGCOUNT=1 P5_SUPER_TX_META=mbuf P5_SUPER_RX_META=mbuf P5_SUPER_TX_LOCK_MODE=single_owner P5_SUPER_CAP_DIAG=1"
MONITOR="$(latest_complete_p5 'idle_monitor_normal_*' || true)"
POWER="$(latest_complete_p5 'main_power_friendly_*' || true)"
SHORT="$(latest_complete_p5 'main_normal_short_8GiB_*' || true)"
printf 'REUSED_MONITOR=%s\nREUSED_POWER=%s\nREUSED_SHORT=%s\n' "$MONITOR" "$POWER" "$SHORT" > "$EX/result_rc.txt"
cd "$P5"
env $PERF_ENV bash ./build_p5_super_performance.sh
B1=$?
ssh -o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3 root@tinyman "cd '$P5' && env $PERF_ENV bash ./build_p5_super_performance.sh"
B2=$?
printf 'BUILD_IDEX=%s\nBUILD_TINYMAN=%s\n' "$B1" "$B2" >> "$EX/result_rc.txt"
RC2=88
RC3=88
if [ -z "$POWER" ] && [ "$B1" -eq 0 ] && [ "$B2" -eq 0 ]; then
    POWER="$P5/matrix_results/main_power_friendly_${TAG}"
    echo "=== PERFORMANCE1 TEST 2/4 POWER_FRIENDLY ==="
    bash ./run_matrix_with_sheet.sh --chart-style both --client-host tinyman --client-dir "$P5" --client-bin /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop --downloads 5 --gap-seconds 5 --server-cooldown-seconds 5 --between-tests-seconds 0 --cstate-cpu 19 --runs 6 --mode-order balanced --seed 20260806 --output-dir "$POWER" --env ENABLE_RECORD=1 --env GQ_LOG_LEVEL=0 --env ENABLE_FREQ=1 --env ENABLE_SLEEP=1 --env GQ_IDLE_MODE_OVERRIDE=epoll --env GQ_IDLE_FALLBACK_OVERRIDE=short
    RC2=$?
else
    [ -n "$POWER" ] && RC2=0
    echo "POWER_FRIENDLY reuse/skip: $POWER"
fi
if [ -z "$SHORT" ] && [ "$B1" -eq 0 ] && [ "$B2" -eq 0 ]; then
    SHORT="$P5/matrix_results/main_normal_short_8GiB_${TAG}"
    echo "=== PERFORMANCE1 TEST 3/4 NORMAL_SHORT_8GiB ==="
    bash ./run_matrix_with_sheet.sh --chart-style both --client-host tinyman --client-dir "$P5" --client-bin /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop --downloads 5 --gap-seconds 5 --server-cooldown-seconds 5 --between-tests-seconds 0 --cstate-cpu 19 --runs 6 --mode-order balanced --seed 20260806 --output-dir "$SHORT" --env ENABLE_RECORD=1 --env GQ_LOG_LEVEL=0 --env GQ_IDLE_MODE_OVERRIDE=short --env GQ_IDLE_FALLBACK_OVERRIDE=short --env REQUEST_PATH=/file_8G.bin --env PAYLOAD_BYTES=8589934592
    RC3=$?
else
    [ -n "$SHORT" ] && RC3=0
    echo "NORMAL_SHORT reuse/skip: $SHORT"
fi
echo "=== PERFORMANCE1 TEST 4/4 P7 LINUX ==="
P7_OUT="$P7/matrix_results/P7_MAIN_linux_6runs_${TAG}"
P7_LOG="/root/P7_MAIN_${TAG}.log"
/root/run_p7.sh --chart-style both --log-level 0 --downloads 5 --gap-seconds 5 --runs 6 --pre-cooldown-seconds 5 --post-cooldown-seconds 5 --between-runs-seconds 5 --dataplane-cpu 19 --quic-cpus 21,22,23,24 --pin-irq 1 --pin-quic 1 --disable-rps 1 --nic-offloads native --record-quic-cpus 0 --enable-record 1 --rapl-interval-ms 6 --freq-interval-ms 1 --require-rapl 1 --stop-irqbalance 1 --mtu 1500 --output-dir "$P7_OUT" 2>&1 | tee "$P7_LOG"
RC4=${PIPESTATUS[0]}
printf 'POWER=%s\nSHORT=%s\nP7=%s\n' "$RC2" "$RC3" "$RC4" >> "$EX/result_rc.txt"
printf 'MONITOR=%s\nPOWER=%s\nSHORT=%s\nP7=%s\n' "$MONITOR" "$POWER" "$SHORT" "$P7_OUT" > "$EX/source_paths.txt"
[ -n "$MONITOR" ] && zip_one "$MONITOR" monitor
[ -n "$POWER" ] && zip_one "$POWER" power
[ -n "$SHORT" ] && zip_one "$SHORT" short
zip_one "$P7_OUT" p7
[ -f "$P7_LOG" ] && cp "$P7_LOG" "$EX/"
echo "P1 RESUME FINISHED: POWER=$RC2 SHORT=$RC3 P7=$RC4"
REMOTE
}

create_p2_runner() {
    local path="$1" phase="$2" profile="$3" runs="$4" downloads="$5"
    cat > "$path" <<REMOTE
#!/usr/bin/env bash
set +e
TAG="\$1"
SELF_LOG="\$2"
P5=/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads
PHASE="$phase"
PROFILE="$profile"
RUNS="$runs"
DOWNLOADS="$downloads"
STAMP="\${TAG}_\${PHASE}"
RESULT="/tmp/P5_PERFORMANCE2_\${STAMP}"
MATRIX="\$P5/matrix_results/P5_PERFORMANCE2_\${STAMP}"
EX="/tmp/P5_PERFORMANCE2_EXPORT_\${STAMP}"
mkdir -p "\$EX"
finalize() {
    rc=\$?
    printf 'REMOTE_SCRIPT_RC=%s\n' "\$rc" >> "\$EX/result_rc.txt"
    [ -f "\$SELF_LOG" ] && cp "\$SELF_LOG" "\$EX/remote.log" 2>/dev/null || true
    (cd "\$EX" && find . -maxdepth 1 -type f ! -name SHA256SUMS ! -name DONE -printf '%f\\0' | sort -z | xargs -0 -r sha256sum > SHA256SUMS)
    date > "\$EX/DONE"
    exit 0
}
trap finalize EXIT
cd "\$P5"
bash -n ./build_p5_performance2.sh
S1=\$?
bash -n ./run_p5_performance2_sweep.sh
S2=\$?
python3 -m py_compile ./apply_p5_performance2.py ./test_p5_performance2_transform.py
S3=\$?
python3 ./test_p5_performance2_transform.py
S4=\$?
printf 'PREFLIGHT_BASH_BUILD=%s\nPREFLIGHT_BASH_SWEEP=%s\nPREFLIGHT_PYCOMPILE=%s\nPREFLIGHT_SELFTEST=%s\n' "\$S1" "\$S2" "\$S3" "\$S4" > "\$EX/result_rc.txt"
if [ "\$S1" -ne 0 ] || [ "\$S2" -ne 0 ] || [ "\$S3" -ne 0 ] || [ "\$S4" -ne 0 ]; then
    echo "PERFORMANCE2 preflight failed"
else
    if [ -n "\$PROFILE" ]; then
        STAMP="\$STAMP" RESULT_ROOT="\$RESULT" P5_P2_DOWNLOADS="\$DOWNLOADS" P5_P2_RUNS="\$RUNS" P5_P2_TESTS="\$PROFILE" bash ./run_p5_performance2_sweep.sh
    else
        STAMP="\$STAMP" RESULT_ROOT="\$RESULT" P5_P2_DOWNLOADS="\$DOWNLOADS" P5_P2_RUNS="\$RUNS" P5_P2_TESTS="" bash ./run_p5_performance2_sweep.sh
    fi
    RRC=\$?
    printf 'RUNNER_RC=%s\nPROFILE=%s\nRUNS=%s\nDOWNLOADS=%s\n' "\$RRC" "\${PROFILE:-ALL_12}" "\$RUNS" "\$DOWNLOADS" >> "\$EX/result_rc.txt"
fi
if [ -d "\$RESULT" ]; then
    (cd /tmp && zip -qr "\$EX/analysis__P5_PERFORMANCE2_\${STAMP}.zip" "P5_PERFORMANCE2_\${STAMP}")
fi
if [ -d "\$MATRIX" ]; then
    (cd "\$(dirname "\$MATRIX")" && zip -qr "\$EX/matrix__P5_PERFORMANCE2_\${STAMP}.zip" "\$(basename "\$MATRIX")")
fi
printf 'RESULT=%s\nMATRIX=%s\n' "\$RESULT" "\$MATRIX" > "\$EX/source_paths.txt"
echo "PERFORMANCE2 \$PHASE FINISHED PROFILE=\${PROFILE:-ALL_12} RUNS=\$RUNS DOWNLOADS=\$DOWNLOADS"
REMOTE
}

wait_for_export_done() {
    local export="$1" logname="$2"
    while true; do
        if ssh "${SSH_OPTS[@]}" idex "test -f '$export/DONE'" >/dev/null 2>&1; then
            return 0
        fi
        log "Waiting for $logname; SSH failures are harmless to the remote nohup job"
        sleep 60
    done
}

log "CHAIN_TAG=$CHAIN_TAG"
log "Performance2 best pre-measurement guess=$P2_BEST_PROFILE"
log "Stage order: verify old transfer -> finish Performance1 -> SHA256 SCP -> 5 min -> P2 best 6x5 -> SHA256 SCP -> 5 min -> P2 12-profile 1x3 -> SHA256 SCP"

wait_clean_both
verify_previous_export_if_any
fetch_and_bundle
sync_branch_both "$P1_BRANCH" __p1p2_chain_p1 "$P1_SHA"
wait_clean_both

P1_SCRIPT="$TMPBASE/P1_RESUME_${CHAIN_TAG}.sh"
P1_REMOTE="/tmp/P1_RESUME_${CHAIN_TAG}.sh"
P1_LOG="/root/P1_RESUME_${CHAIN_TAG}.log"
P1_PID="/tmp/P1_RESUME_${CHAIN_TAG}.pid"
P1_EXPORT="/tmp/P5_RESUME_EXPORT_${CHAIN_TAG}"
P1_LOCAL="$HOME/Downloads/P5_RESUME_EXPORT_${CHAIN_TAG}"
create_p1_runner "$P1_SCRIPT"
start_remote_job "$P1_SCRIPT" "$P1_REMOTE" "$P1_LOG" "$P1_PID" "$P1_EXPORT/DONE" "$CHAIN_TAG"
wait_for_export_done "$P1_EXPORT" "Performance1 resume"
copy_export_verified "$P1_EXPORT" "$P1_LOCAL"
wait_clean_both
log "Performance1 is finished and its exported files are SHA256-verified on the Mac"
log "Cooling down for 5 minutes before Performance2"
sleep 300

sync_branch_both "$P2_BRANCH" __p1p2_chain_p2 "$P2_SHA"
wait_clean_both

P2_BEST_PHASE="BEST_${P2_BEST_PROFILE}"
P2_BEST_SCRIPT="$TMPBASE/P2_BEST_${CHAIN_TAG}.sh"
P2_BEST_REMOTE="/tmp/P2_BEST_${CHAIN_TAG}.sh"
P2_BEST_LOG="/root/P2_BEST_${CHAIN_TAG}.log"
P2_BEST_PID="/tmp/P2_BEST_${CHAIN_TAG}.pid"
P2_BEST_STAMP="${CHAIN_TAG}_${P2_BEST_PHASE}"
P2_BEST_EXPORT="/tmp/P5_PERFORMANCE2_EXPORT_${P2_BEST_STAMP}"
P2_BEST_LOCAL="$HOME/Downloads/P5_PERFORMANCE2_EXPORT_${P2_BEST_STAMP}"
create_p2_runner "$P2_BEST_SCRIPT" "$P2_BEST_PHASE" "$P2_BEST_PROFILE" 6 5
start_remote_job "$P2_BEST_SCRIPT" "$P2_BEST_REMOTE" "$P2_BEST_LOG" "$P2_BEST_PID" "$P2_BEST_EXPORT/DONE" "$CHAIN_TAG"
wait_for_export_done "$P2_BEST_EXPORT" "Performance2 best-profile 6x5"
copy_export_verified "$P2_BEST_EXPORT" "$P2_BEST_LOCAL"
wait_clean_both
log "Performance2 best-profile 6x5 is finished and copied to the Mac"
log "Cooling down for 5 minutes before the 12-profile exploratory sweep"
sleep 300

P2_SWEEP_PHASE="SWEEP12"
P2_SWEEP_SCRIPT="$TMPBASE/P2_SWEEP12_${CHAIN_TAG}.sh"
P2_SWEEP_REMOTE="/tmp/P2_SWEEP12_${CHAIN_TAG}.sh"
P2_SWEEP_LOG="/root/P2_SWEEP12_${CHAIN_TAG}.log"
P2_SWEEP_PID="/tmp/P2_SWEEP12_${CHAIN_TAG}.pid"
P2_SWEEP_STAMP="${CHAIN_TAG}_${P2_SWEEP_PHASE}"
P2_SWEEP_EXPORT="/tmp/P5_PERFORMANCE2_EXPORT_${P2_SWEEP_STAMP}"
P2_SWEEP_LOCAL="$HOME/Downloads/P5_PERFORMANCE2_EXPORT_${P2_SWEEP_STAMP}"
create_p2_runner "$P2_SWEEP_SCRIPT" "$P2_SWEEP_PHASE" "" 1 3
start_remote_job "$P2_SWEEP_SCRIPT" "$P2_SWEEP_REMOTE" "$P2_SWEEP_LOG" "$P2_SWEEP_PID" "$P2_SWEEP_EXPORT/DONE" "$CHAIN_TAG"
wait_for_export_done "$P2_SWEEP_EXPORT" "Performance2 12-profile sweep"
copy_export_verified "$P2_SWEEP_EXPORT" "$P2_SWEEP_LOCAL"
wait_clean_both

log "======================================================================"
log "ENTIRE P1 -> P2 CHAIN COMPLETE"
log "P1 export: $P1_LOCAL"
log "P2 best 6x5 ($P2_BEST_PROFILE): $P2_BEST_LOCAL"
log "P2 12-profile 1x3 sweep: $P2_SWEEP_LOCAL"
log "All three exports are SHA256-verified; idex and tinyman are clean."
log "======================================================================"

rm -f "$BUNDLE" "$P1_SCRIPT" "$P2_BEST_SCRIPT" "$P2_SWEEP_SCRIPT" 2>/dev/null || true
exit 0
