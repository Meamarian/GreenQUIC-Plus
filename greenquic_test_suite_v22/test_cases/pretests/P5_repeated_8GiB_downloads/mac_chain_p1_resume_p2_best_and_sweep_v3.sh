#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="${GREENQUIC_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
[[ -n "$REPO_ROOT" && -d "$REPO_ROOT/.git" ]] || { echo "ERROR: run from GreenQUIC repo or set GREENQUIC_REPO" >&2; exit 2; }
TAG="${CHAIN_TAG:-$(date +%Y%m%d_%H%M%S)}"
P1_BRANCH="performance/p5-max-goodput"
P2_BRANCH="performance2/p5-max-goodput"
P2_BEST_PROFILE="${P5_P2_BEST_PROFILE:-sharded_udp4}"
START_DELAY="${CHAIN_START_DELAY_SECONDS:-10}"
INTER_STAGE_DELAY="${CHAIN_INTER_STAGE_DELAY_SECONDS:-300}"
SSH_OPTS=(-o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3)
TMPBASE="${TMPDIR:-/tmp}"
REMOTE_LOCK="/tmp/greenquic_p1_p2_chain.lock"
LOCAL_LOCK="$HOME/Downloads/.greenquic_p1_p2_chain.lock"
BUNDLE="$TMPBASE/GreenQUIC_P1P2_${TAG}.bundle"
REMOTE_BUNDLE="/tmp/GreenQUIC_P1P2_${TAG}.bundle"

log(){ printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

ssh_once(){ ssh "${SSH_OPTS[@]}" idex "$@"; }

ssh_retry(){
    while ! ssh_once "$@"; do
        log "SSH transport/command failed; retrying in 30 s"
        sleep 30
    done
}

scp_to_idex_retry(){
    local src="$1" dst="$2"
    while ! scp "${SSH_OPTS[@]}" "$src" "idex:$dst"; do
        log "SCP to idex failed; retrying in 30 s"
        sleep 30
    done
}

check_host_once(){
    local which="$1"
    if [[ "$which" == idex ]]; then
        ssh "${SSH_OPTS[@]}" idex 'bash -s' <<'CHECK'
set +e
bad=0
for p in /proc/[0-9]*; do
    pid="${p##*/}"
    exe=$(readlink -f "$p/exe" 2>/dev/null || true)
    case "$exe" in */quicinterop|*/quicinteropserver) echo "ACTIVE EXE PID=$pid $exe"; bad=1;; esac
    cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null || true)
    case "$cmd" in *run_matrix_with_sheet.sh*|*.run_matrix_fixed.*|*run_client.sh*|*run_server.sh*|*run_p7.sh*|*run_p5_performance2_sweep.sh*) echo "ACTIVE CMD PID=$pid $cmd"; bad=1;; esac
done
if fuser /var/run/dpdk/rte/config >/dev/null 2>&1; then echo "ACTIVE DPDK HOLDER"; bad=1; else echo "DPDK: No holder"; fi
[ "$bad" -eq 0 ] && echo CLEAN
exit "$bad"
CHECK
    else
        ssh "${SSH_OPTS[@]}" idex "ssh -o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3 root@tinyman 'bash -s'" <<'CHECK'
set +e
bad=0
for p in /proc/[0-9]*; do
    pid="${p##*/}"
    exe=$(readlink -f "$p/exe" 2>/dev/null || true)
    case "$exe" in */quicinterop|*/quicinteropserver) echo "ACTIVE EXE PID=$pid $exe"; bad=1;; esac
    cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null || true)
    case "$cmd" in *run_matrix_with_sheet.sh*|*.run_matrix_fixed.*|*run_client.sh*|*run_server.sh*|*run_p7.sh*|*run_p5_performance2_sweep.sh*) echo "ACTIVE CMD PID=$pid $cmd"; bad=1;; esac
done
if fuser /var/run/dpdk/rte/config >/dev/null 2>&1; then echo "ACTIVE DPDK HOLDER"; bad=1; else echo "DPDK: No holder"; fi
[ "$bad" -eq 0 ] && echo CLEAN
exit "$bad"
CHECK
    fi
}

wait_clean_both(){
    until check_host_once idex; do log "idex active/unreachable; retry in 30 s"; sleep 30; done
    until check_host_once tinyman; do log "tinyman active/unreachable; retry in 30 s"; sleep 30; done
    log "idex + tinyman clean"
}

verify_or_copy_export(){
    local remote="$1" localdir="$2"
    mkdir -p "$localdir"
    ssh_retry "cd '$remote' && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\\0' | sort -z | xargs -0 -r sha256sum > SHA256SUMS.tmp && mv SHA256SUMS.tmp SHA256SUMS"
    while ! scp "${SSH_OPTS[@]}" "idex:$remote/SHA256SUMS" "$localdir/SHA256SUMS"; do log "manifest SCP failed; retry in 30 s"; sleep 30; done
    while read -r hash file; do
        [[ -n "${file:-}" ]] || continue
        if [[ -f "$localdir/$file" ]] && printf '%s  %s\n' "$hash" "$file" | (cd "$localdir" && shasum -a 256 -c - >/dev/null 2>&1); then
            log "Already verified $file"
            continue
        fi
        while true; do
            rm -f "$localdir/$file.part"
            if scp "${SSH_OPTS[@]}" "idex:$remote/$file" "$localdir/$file.part"; then
                got=$(shasum -a 256 "$localdir/$file.part" | awk '{print $1}')
                if [[ "$got" == "$hash" ]]; then mv "$localdir/$file.part" "$localdir/$file"; break; fi
            fi
            log "SCP/hash failed for $file; retry in 60 s"
            sleep 60
        done
    done < "$localdir/SHA256SUMS"
    (cd "$localdir" && shasum -a 256 -c SHA256SUMS)
    date -Is > "$localdir/SCP_DONE"
    log "SCP + SHA256 VERIFIED: $localdir"
}

verify_previous_export(){
    local prev localdir
    prev="$(ssh_once 'for d in /tmp/P5_RESUME_EXPORT_* /tmp/P5_P7_FINAL_EXPORT_*; do [ -d "$d" ] && printf "%s %s\n" "$(stat -c %Y "$d" 2>/dev/null || echo 0)" "$d"; done | sort -nr | head -1 | cut -d" " -f2-' 2>/dev/null || true)"
    [[ -n "$prev" ]] || { log "No prior export found"; return 0; }
    localdir="$HOME/Downloads/$(basename "$prev")"
    log "Verifying previous export: $prev"
    verify_or_copy_export "$prev" "$localdir"
}

fetch_bundle(){
    cd "$REPO_ROOT"
    while ! git fetch origin "$P1_BRANCH" "$P2_BRANCH"; do log "git fetch failed; retry 30 s"; sleep 30; done
    P1_SHA=$(git rev-parse "origin/$P1_BRANCH")
    P2_SHA=$(git rev-parse "origin/$P2_BRANCH")
    git update-ref refs/heads/__chain_p1 "$P1_SHA"
    git update-ref refs/heads/__chain_p2 "$P2_SHA"
    rm -f "$BUNDLE"
    git bundle create "$BUNDLE" refs/heads/__chain_p1 refs/heads/__chain_p2
    git update-ref -d refs/heads/__chain_p1
    git update-ref -d refs/heads/__chain_p2
    scp_to_idex_retry "$BUNDLE" "$REMOTE_BUNDLE"
    ssh_retry "while ! scp -o ConnectTimeout=15 '$REMOTE_BUNDLE' root@tinyman:'$REMOTE_BUNDLE'; do sleep 30; done"
    log "P1_SHA=$P1_SHA"
    log "P2_SHA=$P2_SHA"
}

sync_branch(){
    local branch="$1" ref="$2" expected="$3"
    ssh_retry "cd /root/mohsen && git reset --hard && git fetch '$REMOTE_BUNDLE' 'refs/heads/$ref' && git checkout -B '$branch' FETCH_HEAD && test \"\$(git rev-parse HEAD)\" = '$expected'"
    ssh_retry "ssh -o ConnectTimeout=15 root@tinyman \"cd /root/mohsen && git reset --hard && git fetch '$REMOTE_BUNDLE' 'refs/heads/$ref' && git checkout -B '$branch' FETCH_HEAD && test \\\"\\\$(git rev-parse HEAD)\\\" = '$expected'\""
}

start_detached(){
    local local_script="$1" remote_script="$2" remote_log="$3" remote_pid="$4" arg="$5"
    scp_to_idex_retry "$local_script" "$remote_script"
    ssh_retry "chmod +x '$remote_script'; nohup setsid bash '$remote_script' '$arg' '$remote_log' >'$remote_log' 2>&1 </dev/null & echo \$! > '$remote_pid'; echo REMOTE_PID=\$(cat '$remote_pid')"
}

wait_done(){
    local donefile="$1" label="$2"
    while true; do
        if ssh_once "test -f '$donefile'" >/dev/null 2>&1; then log "$label DONE detected"; return 0; fi
        log "Waiting for $label (SSH failure cannot kill remote nohup job)"
        sleep 60
    done
}

make_p1_runner(){
    local out="$1"
    cat > "$out" <<'REMOTE'
#!/usr/bin/env bash
set +e
TAG="$1"
SELF_LOG="$2"
P5=/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads
P7=/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline
EX="/tmp/P5_RESUME_EXPORT_${TAG}"
LOCK=/tmp/greenquic_p1_p2_chain.lock
mkdir -p "$EX"
if ! mkdir "$LOCK" 2>/dev/null; then echo "ERROR: remote chain lock exists"; exit 90; fi
echo $$ > "$LOCK/pid"
cleanup(){ rm -rf "$LOCK"; }
finalize(){ rc=$?; [ -f "$SELF_LOG" ] && cp "$SELF_LOG" "$EX/remote.log" 2>/dev/null || true; printf 'REMOTE_SCRIPT_RC=%s\n' "$rc" >> "$EX/result_rc.txt"; (cd "$EX" && find . -maxdepth 1 -type f ! -name SHA256SUMS ! -name DONE -printf '%f\0' | sort -z | xargs -0 -r sha256sum > SHA256SUMS); date -Is > "$EX/DONE"; cleanup; exit 0; }
trap finalize EXIT INT TERM
latest_complete(){ pat="$1"; find "$P5/matrix_results" -maxdepth 1 -type d -name "$pat" -printf '%T@ %p\n' 2>/dev/null | sort -nr | cut -d' ' -f2- | while IFS= read -r d; do if grep -R -q 'SUCCESS: all 18/18 P5 workloads completed' "$d" 2>/dev/null; then echo "$d"; break; fi; done; }
zip_one(){ src="$1" label="$2"; [ -d "$src" ] || return 0; (cd "$(dirname "$src")" && zip -qr "$EX/${label}__$(basename "$src").zip" "$(basename "$src")"); }
PERF_ENV="P5_BUILD_REUSE=1 P5_SUPER_CACHE=128 P5_SUPER_RX_BURST=32 P5_SUPER_TX_BURST=16 P5_SUPER_RING_SIZE=4096 P5_SUPER_RING_SYNC=legacy P5_SUPER_DRAIN_BURSTS=2 P5_SUPER_DRAIN_THRESHOLD=0 P5_SUPER_MTU=0 P5_SUPER_SKIP_OFF_RINGCOUNT=0 P5_SUPER_DEBUG_COUNTERS=1 P5_SUPER_TRANSFER_WINDOW=1 P5_SUPER_TRACE_RINGCOUNT=1 P5_SUPER_TX_META=mbuf P5_SUPER_RX_META=mbuf P5_SUPER_TX_LOCK_MODE=single_owner P5_SUPER_CAP_DIAG=1"
MONITOR="$(latest_complete 'idle_monitor_normal_*')"
POWER="$(latest_complete 'main_power_friendly_*')"
SHORT="$(latest_complete 'main_normal_short_8GiB_*')"
printf 'MONITOR=%s\nPOWER=%s\nSHORT=%s\n' "$MONITOR" "$POWER" "$SHORT" > "$EX/source_paths.txt"
cd "$P5"
env $PERF_ENV bash ./build_p5_super_performance.sh; B1=$?
ssh -o ConnectTimeout=15 root@tinyman "cd '$P5' && env $PERF_ENV bash ./build_p5_super_performance.sh"; B2=$?
printf 'BUILD_IDEX=%s\nBUILD_TINYMAN=%s\n' "$B1" "$B2" > "$EX/result_rc.txt"
RC2=88; RC3=88
if [ -z "$POWER" ] && [ "$B1" -eq 0 ] && [ "$B2" -eq 0 ]; then POWER="$P5/matrix_results/main_power_friendly_${TAG}"; bash ./run_matrix_with_sheet.sh --chart-style both --client-host tinyman --client-dir "$P5" --client-bin /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop --downloads 5 --gap-seconds 5 --server-cooldown-seconds 5 --between-tests-seconds 0 --cstate-cpu 19 --runs 6 --mode-order balanced --seed 20260806 --output-dir "$POWER" --env ENABLE_RECORD=1 --env GQ_LOG_LEVEL=0 --env ENABLE_FREQ=1 --env ENABLE_SLEEP=1 --env GQ_IDLE_MODE_OVERRIDE=epoll --env GQ_IDLE_FALLBACK_OVERRIDE=short; RC2=$?; else [ -n "$POWER" ] && RC2=0; fi
if [ -z "$SHORT" ] && [ "$B1" -eq 0 ] && [ "$B2" -eq 0 ]; then SHORT="$P5/matrix_results/main_normal_short_8GiB_${TAG}"; bash ./run_matrix_with_sheet.sh --chart-style both --client-host tinyman --client-dir "$P5" --client-bin /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop --downloads 5 --gap-seconds 5 --server-cooldown-seconds 5 --between-tests-seconds 0 --cstate-cpu 19 --runs 6 --mode-order balanced --seed 20260806 --output-dir "$SHORT" --env ENABLE_RECORD=1 --env GQ_LOG_LEVEL=0 --env GQ_IDLE_MODE_OVERRIDE=short --env GQ_IDLE_FALLBACK_OVERRIDE=short --env REQUEST_PATH=/file_8G.bin --env PAYLOAD_BYTES=8589934592; RC3=$?; else [ -n "$SHORT" ] && RC3=0; fi
P7_OUT="$P7/matrix_results/P7_MAIN_linux_6runs_${TAG}"
P7_LOG="/root/P7_MAIN_${TAG}.log"
/root/run_p7.sh --chart-style both --log-level 0 --downloads 5 --gap-seconds 5 --runs 6 --pre-cooldown-seconds 5 --post-cooldown-seconds 5 --between-runs-seconds 5 --dataplane-cpu 19 --quic-cpus 21,22,23,24 --pin-irq 1 --pin-quic 1 --disable-rps 1 --nic-offloads native --record-quic-cpus 0 --enable-record 1 --rapl-interval-ms 6 --freq-interval-ms 1 --require-rapl 1 --stop-irqbalance 1 --mtu 1500 --output-dir "$P7_OUT" 2>&1 | tee "$P7_LOG"; RC4=${PIPESTATUS[0]}
printf 'POWER=%s\nSHORT=%s\nP7=%s\n' "$RC2" "$RC3" "$RC4" >> "$EX/result_rc.txt"
printf 'MONITOR=%s\nPOWER=%s\nSHORT=%s\nP7=%s\n' "$MONITOR" "$POWER" "$SHORT" "$P7_OUT" > "$EX/source_paths.txt"
zip_one "$MONITOR" monitor; zip_one "$POWER" power; zip_one "$SHORT" short; zip_one "$P7_OUT" p7
[ -f "$P7_LOG" ] && cp "$P7_LOG" "$EX/"
exit 0
REMOTE
}

make_p2_runner(){
    local out="$1" phase="$2" profile="$3" runs="$4" downloads="$5"
    cat > "$out" <<REMOTE
#!/usr/bin/env bash
set +e
TAG="\$1"; SELF_LOG="\$2"
P5=/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads
PHASE="$phase"; PROFILE="$profile"; RUNS="$runs"; DOWNLOADS="$downloads"
STAMP="\${TAG}_\${PHASE}"; RESULT="/tmp/P5_PERFORMANCE2_\${STAMP}"; MATRIX="\$P5/matrix_results/P5_PERFORMANCE2_\${STAMP}"; EX="/tmp/P5_PERFORMANCE2_EXPORT_\${STAMP}"; LOCK=/tmp/greenquic_p1_p2_chain.lock
mkdir -p "\$EX"
if ! mkdir "\$LOCK" 2>/dev/null; then echo "ERROR: remote chain lock exists"; exit 90; fi
echo \$\$ > "\$LOCK/pid"
cleanup(){ rm -rf "\$LOCK"; }
finalize(){ rc=\$?; [ -f "\$SELF_LOG" ] && cp "\$SELF_LOG" "\$EX/remote.log" 2>/dev/null || true; printf 'REMOTE_SCRIPT_RC=%s\n' "\$rc" >> "\$EX/result_rc.txt"; (cd "\$EX" && find . -maxdepth 1 -type f ! -name SHA256SUMS ! -name DONE -printf '%f\\0' | sort -z | xargs -0 -r sha256sum > SHA256SUMS); date -Is > "\$EX/DONE"; cleanup; exit 0; }
trap finalize EXIT INT TERM
cd "\$P5"
bash -n ./build_p5_performance2.sh; S1=\$?
bash -n ./run_p5_performance2_sweep.sh; S2=\$?
python3 -m py_compile ./apply_p5_performance2.py ./test_p5_performance2_transform.py; S3=\$?
python3 ./test_p5_performance2_transform.py; S4=\$?
printf 'PREFLIGHT_BUILD=%s\nPREFLIGHT_SWEEP=%s\nPREFLIGHT_PY=%s\nPREFLIGHT_SELFTEST=%s\n' "\$S1" "\$S2" "\$S3" "\$S4" > "\$EX/result_rc.txt"
if [ "\$S1" -eq 0 ] && [ "\$S2" -eq 0 ] && [ "\$S3" -eq 0 ] && [ "\$S4" -eq 0 ]; then STAMP="\$STAMP" RESULT_ROOT="\$RESULT" P5_P2_DOWNLOADS="\$DOWNLOADS" P5_P2_RUNS="\$RUNS" P5_P2_TESTS="\$PROFILE" bash ./run_p5_performance2_sweep.sh; RRC=\$?; printf 'RUNNER_RC=%s\nPROFILE=%s\nRUNS=%s\nDOWNLOADS=%s\n' "\$RRC" "\${PROFILE:-ALL_12}" "\$RUNS" "\$DOWNLOADS" >> "\$EX/result_rc.txt"; fi
[ -d "\$RESULT" ] && (cd /tmp && zip -qr "\$EX/analysis__P5_PERFORMANCE2_\${STAMP}.zip" "P5_PERFORMANCE2_\${STAMP}")
[ -d "\$MATRIX" ] && (cd "\$(dirname "\$MATRIX")" && zip -qr "\$EX/matrix__P5_PERFORMANCE2_\${STAMP}.zip" "\$(basename "\$MATRIX")")
printf 'RESULT=%s\nMATRIX=%s\n' "\$RESULT" "\$MATRIX" > "\$EX/source_paths.txt"
exit 0
REMOTE
}

if [[ -d "$LOCAL_LOCK" ]]; then
    old=$(cat "$LOCAL_LOCK/pid" 2>/dev/null || true)
    if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then echo "ERROR: another Mac chain is alive PID=$old" >&2; exit 70; fi
    rm -rf "$LOCAL_LOCK"
fi
mkdir -p "$LOCAL_LOCK"
echo $$ > "$LOCAL_LOCK/pid"
trap 'rm -rf "$LOCAL_LOCK"; rm -f "$BUNDLE"' EXIT INT TERM

log "Startup: verify clean + previous export, then wait ${START_DELAY}s"
wait_clean_both
verify_previous_export
sleep "$START_DELAY"
fetch_bundle
sync_branch "$P1_BRANCH" __chain_p1 "$P1_SHA"
wait_clean_both

P1_SCRIPT="$TMPBASE/P1_RESUME_V3_${TAG}.sh"; P1_REMOTE="/tmp/P1_RESUME_V3_${TAG}.sh"; P1_LOG="/root/P1_RESUME_V3_${TAG}.log"; P1_PID="/tmp/P1_RESUME_V3_${TAG}.pid"; P1_EXPORT="/tmp/P5_RESUME_EXPORT_${TAG}"; P1_LOCAL="$HOME/Downloads/P5_RESUME_EXPORT_${TAG}"
make_p1_runner "$P1_SCRIPT"
bash -n "$P1_SCRIPT"
start_detached "$P1_SCRIPT" "$P1_REMOTE" "$P1_LOG" "$P1_PID" "$TAG"
wait_done "$P1_EXPORT/DONE" "Performance1"
verify_or_copy_export "$P1_EXPORT" "$P1_LOCAL"
wait_clean_both
log "P1 complete + copied; cooldown ${INTER_STAGE_DELAY}s"
sleep "$INTER_STAGE_DELAY"

sync_branch "$P2_BRANCH" __chain_p2 "$P2_SHA"
wait_clean_both
P2B_PHASE="BEST_${P2_BEST_PROFILE}"; P2B_SCRIPT="$TMPBASE/P2_BEST_V3_${TAG}.sh"; P2B_REMOTE="/tmp/P2_BEST_V3_${TAG}.sh"; P2B_LOG="/root/P2_BEST_V3_${TAG}.log"; P2B_PID="/tmp/P2_BEST_V3_${TAG}.pid"; P2B_STAMP="${TAG}_${P2B_PHASE}"; P2B_EXPORT="/tmp/P5_PERFORMANCE2_EXPORT_${P2B_STAMP}"; P2B_LOCAL="$HOME/Downloads/P5_PERFORMANCE2_EXPORT_${P2B_STAMP}"
make_p2_runner "$P2B_SCRIPT" "$P2B_PHASE" "$P2_BEST_PROFILE" 6 5
bash -n "$P2B_SCRIPT"
start_detached "$P2B_SCRIPT" "$P2B_REMOTE" "$P2B_LOG" "$P2B_PID" "$TAG"
wait_done "$P2B_EXPORT/DONE" "Performance2 best ${P2_BEST_PROFILE} 6x5"
verify_or_copy_export "$P2B_EXPORT" "$P2B_LOCAL"
wait_clean_both
log "P2 best complete + copied; cooldown ${INTER_STAGE_DELAY}s"
sleep "$INTER_STAGE_DELAY"

P2S_PHASE="SWEEP12"; P2S_SCRIPT="$TMPBASE/P2_SWEEP12_V3_${TAG}.sh"; P2S_REMOTE="/tmp/P2_SWEEP12_V3_${TAG}.sh"; P2S_LOG="/root/P2_SWEEP12_V3_${TAG}.log"; P2S_PID="/tmp/P2_SWEEP12_V3_${TAG}.pid"; P2S_STAMP="${TAG}_${P2S_PHASE}"; P2S_EXPORT="/tmp/P5_PERFORMANCE2_EXPORT_${P2S_STAMP}"; P2S_LOCAL="$HOME/Downloads/P5_PERFORMANCE2_EXPORT_${P2S_STAMP}"
make_p2_runner "$P2S_SCRIPT" "$P2S_PHASE" "" 1 3
bash -n "$P2S_SCRIPT"
start_detached "$P2S_SCRIPT" "$P2S_REMOTE" "$P2S_LOG" "$P2S_PID" "$TAG"
wait_done "$P2S_EXPORT/DONE" "Performance2 12-profile 1x3"
verify_or_copy_export "$P2S_EXPORT" "$P2S_LOCAL"
wait_clean_both

log "ENTIRE CHAIN COMPLETE"
log "P1=$P1_LOCAL"
log "P2_BEST=$P2B_LOCAL"
log "P2_SWEEP=$P2S_LOCAL"
