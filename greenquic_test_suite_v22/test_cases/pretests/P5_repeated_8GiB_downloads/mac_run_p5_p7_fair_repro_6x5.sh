#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="${GREENQUIC_REPO:-$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)}"
[[ -n "$REPO_ROOT" && -d "$REPO_ROOT/.git" ]] || {
    echo "ERROR: run from the GreenQUIC repository or set GREENQUIC_REPO" >&2
    exit 2
}

BRANCH="performance2/p5-multicore"
RUNS="${GQ_FAIR_RUNS:-6}"
DOWNLOADS="${GQ_FAIR_DOWNLOADS:-5}"
GAP_SECONDS="${GQ_FAIR_GAP_SECONDS:-5}"
EDGE_COOLDOWN_SECONDS="${GQ_FAIR_EDGE_COOLDOWN_SECONDS:-5}"
BETWEEN_SECONDS="${GQ_FAIR_BETWEEN_SECONDS:-5}"
SEED="${GQ_FAIR_SEED:-20260806}"
TAG="${GQ_FAIR_TAG:-$(date +%Y%m%d_%H%M%S)}"

SSH_OPTS=(-o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3)
REMOTE_SCRIPT="/tmp/GQ_FAIR_REPRO_${TAG}.sh"
REMOTE_LOG="/root/GQ_FAIR_REPRO_${TAG}.log"
REMOTE_PID="/tmp/GQ_FAIR_REPRO_${TAG}.pid"
REMOTE_ART="/root/GQ_FAIR_REPRO_${TAG}"
LOCAL_SCRIPT="${TMPDIR:-/tmp}/GQ_FAIR_REPRO_${TAG}_$$.sh"

for v in "$RUNS" "$DOWNLOADS"; do
    [[ "$v" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: runs/downloads must be positive integers" >&2; exit 2; }
done
for v in "$GAP_SECONDS" "$EDGE_COOLDOWN_SECONDS" "$BETWEEN_SECONDS"; do
    [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "ERROR: timing values must be non-negative numbers" >&2; exit 2; }
done
[[ "$SEED" =~ ^[0-9]+$ ]] || { echo "ERROR: seed must be an integer" >&2; exit 2; }

cleanup_local(){ rm -f "$LOCAL_SCRIPT"; }
trap cleanup_local EXIT INT TERM

cd "$REPO_ROOT"
git fetch origin "$BRANCH"
SHA="$(git rev-parse "origin/$BRANCH")"

echo "======================================================================"
echo "P5/P7 FAIR REPRODUCTION"
echo "branch=$BRANCH"
echo "sha=$SHA"
echo "runs=$RUNS downloads=$DOWNLOADS"
echo "gap=${GAP_SECONDS}s edge_cooldown=${EDGE_COOLDOWN_SECONDS}s between=${BETWEEN_SECONDS}s"
echo "P5=optimized Performance2 V2 + idle_monitor_normal + isolated recorders"
echo "P7=paper Linux profile + isolated recorders + active/gap C-state charts"
echo "======================================================================"

cat > "$LOCAL_SCRIPT" <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail

TAG="$1"; SHA="$2"; BRANCH="$3"; RUNS="$4"; DOWNLOADS="$5"; GAP="$6"; EDGE="$7"; BETWEEN="$8"; SEED="$9"
ROOT=/root/mohsen
P5="$ROOT/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
P7="$ROOT/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline"
P5BIN="$ROOT/msquic/build-greenquic-p5/bin/Release/quicinterop"
ART="/root/GQ_FAIR_REPRO_${TAG}"
P5OUT="$P5/matrix_results/P5_FAIR_OPT_PINNED_${RUNS}r_${DOWNLOADS}d_${TAG}"
P7OUT="$P7/matrix_results/P7_FAIR_PAPER_PINNED_${RUNS}r_${DOWNLOADS}d_${TAG}"
mkdir -p "$ART"
rm -f "$ART/DONE" "$ART/FAILED"

log(){ printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

restore_p5_common(){
    set +e
    git -C "$ROOT" checkout "$SHA" -- greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/gq_common_p5.sh >/dev/null 2>&1 || true
    ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman \
        "git -C '$ROOT' checkout '$SHA' -- greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/gq_common_p5.sh" >/dev/null 2>&1 || true
    set -e
}

on_exit(){
    rc=$?
    trap - EXIT INT TERM
    restore_p5_common
    if (( rc != 0 )); then
        printf 'rc=%s\nline=%s\n' "$rc" "${BASH_LINENO[0]:-unknown}" > "$ART/FAILED"
        log "FAILED rc=$rc; see $ART/FAILED and this log"
    fi
    exit "$rc"
}
trap on_exit EXIT INT TERM

sync_host(){
    local host="$1"
    if [[ "$host" == idex ]]; then
        cd "$ROOT"
        git reset --hard
        git fetch origin "$BRANCH"
        git checkout -B "$BRANCH" "$SHA"
        test "$(git rev-parse HEAD)" = "$SHA"
    else
        ssh -o BatchMode=yes -o ConnectTimeout=20 root@tinyman \
            "cd '$ROOT' && git reset --hard && git fetch origin '$BRANCH' && git checkout -B '$BRANCH' '$SHA' && test \"\$(git rev-parse HEAD)\" = '$SHA'"
    fi
}

cleanup_both(){
    log "safe cleanup on IDEX"
    cd "$P5"
    python3 ./safe_cleanup_p5_bottleneck_processes.py
    python3 ./safe_cleanup_p5_bottleneck_processes.py --check

    log "safe cleanup on Tinyman"
    ssh -o BatchMode=yes -o ConnectTimeout=20 root@tinyman \
        "cd '$P5' && python3 ./safe_cleanup_p5_bottleneck_processes.py && python3 ./safe_cleanup_p5_bottleneck_processes.py --check"
}

log "sync exact branch SHA on IDEX"
sync_host idex
log "sync exact branch SHA on Tinyman"
sync_host tinyman

log "verify recorder/report self-tests"
cd "$P5"
python3 ./enable_p5_claim_recording_gate.py --self-test
cd "$P7"
python3 ./enable_p7_recorder_affinity.py --self-test
python3 ./build_p7_report.py --self-test

cleanup_both

log "build current optimized P5 Performance2 V2 on both endpoints"
(
    cd "$P5"
    P5_BUILD_REUSE=1 bash ./build_p5_performance2.sh >"$ART/build_p5_idex.log" 2>&1
) & p1=$!
ssh -n -o BatchMode=yes root@tinyman \
    "cd '$P5' && P5_BUILD_REUSE=1 bash ./build_p5_performance2.sh" \
    >"$ART/build_p5_tinyman.log" 2>&1 & p2=$!
wait "$p1"; wait "$p2"

P5_MARKER='GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0'
grep -aFq -- "$P5_MARKER" "$P5BIN"
ssh -n -o BatchMode=yes root@tinyman "grep -aFq -- '$P5_MARKER' '$P5BIN'"

log "build P7 Linux binaries on both endpoints before measured traffic"
(
    cd "$P7"
    bash ./build_p7_linux.sh >"$ART/build_p7_idex.log" 2>&1
) & p3=$!
ssh -n -o BatchMode=yes root@tinyman \
    "cd '$P7' && bash ./build_p7_linux.sh" \
    >"$ART/build_p7_tinyman.log" 2>&1 & p4=$!
wait "$p3"; wait "$p4"

# Normal P7 already applies its recorder-affinity transformer. Normal P5 does
# not yet, so apply the same tested P5 transformer to the runtime shell on both
# endpoints. This changes recorder placement only; it does not rebuild MsQuic.
log "apply P5 recorder CPU isolation on both endpoints"
cd "$P5"
python3 ./enable_p5_claim_recording_gate.py ./gq_common_p5.sh
ssh -n -o BatchMode=yes root@tinyman \
    "cd '$P5' && python3 ./enable_p5_claim_recording_gate.py ./gq_common_p5.sh"
grep -Fq 'GREENQUIC-P5-CLAIM-RECORDER-AFFINITY-V1' "$P5/gq_common_p5.sh"
ssh -n -o BatchMode=yes root@tinyman \
    "grep -Fq 'GREENQUIC-P5-CLAIM-RECORDER-AFFINITY-V1' '$P5/gq_common_p5.sh'"

cleanup_both

log "TEST 1/2 P5 optimized idle_monitor_normal"
cd "$P5"
bash ./run_matrix_with_sheet.sh \
    --chart-style both \
    --client-host tinyman \
    --client-dir "$P5" \
    --client-bin "$P5BIN" \
    --downloads "$DOWNLOADS" \
    --gap-seconds "$GAP" \
    --server-cooldown-seconds "$EDGE" \
    --between-tests-seconds "$BETWEEN" \
    --cstate-cpu 19 \
    --runs "$RUNS" \
    --mode-order balanced \
    --seed "$SEED" \
    --output-dir "$P5OUT" \
    --env ENABLE_RECORD=1 \
    --env GQ_CLAIM_DISABLE_ACTIVE_RECORDERS=0 \
    --env GQ_CLAIM_RECORDER_CPU=auto \
    --env GQ_LOG_LEVEL=0 \
    --env ENABLE_FREQ=1 \
    --env ENABLE_SLEEP=1 \
    --env ENABLE_PAUSE=1 \
    --env KEEP_PAUSE_ITERATIONS=1 \
    --env SHORT_PAUSE_ITERATIONS=1 \
    --env GQ_IDLE_MODE_OVERRIDE=monitor \
    --env GQ_IDLE_FALLBACK_OVERRIDE=short \
    --env GQ_POST_TRANSFER_WAIT_S=0 \
    --env ENABLE_MULTICORE=0 \
    --env SERVER_DPDK_LCORES=19 \
    --env CLIENT_DPDK_LCORES=19 \
    --env SERVER_TX_OWNER_LCORE=19 \
    --env CLIENT_TX_OWNER_LCORE=19 \
    --env SERVER_QUIC_CPUS=21,22,23,24 \
    --env CLIENT_QUIC_CPUS=21,22,23,24 \
    --env MSQUIC_EXECUTION_PROFILE=max_throughput \
    2>&1 | tee "$ART/p5.log"

cleanup_both
log "fair P5->P7 transition delay ${BETWEEN}s"
sleep "$BETWEEN"

log "TEST 2/2 P7 paper Linux baseline"
cd "$P7"
P7_RECORDER_CPU=auto bash ./run_matrix_with_report.sh \
    --chart-style both \
    --log-level 0 \
    --client-host tinyman \
    --client-dir "$P7" \
    --downloads "$DOWNLOADS" \
    --gap-seconds "$GAP" \
    --runs "$RUNS" \
    --pre-cooldown-seconds "$EDGE" \
    --post-cooldown-seconds "$EDGE" \
    --between-runs-seconds "$BETWEEN" \
    --dataplane-cpu 19 \
    --quic-cpus 21,22,23,24 \
    --pin-irq 1 \
    --pin-quic 1 \
    --disable-rps 1 \
    --disable-rdma 1 \
    --nic-offloads paper \
    --udp-rmem 6815744 \
    --udp-wmem 6815744 \
    --combined-channels 1 \
    --network-diagnostics 0 \
    --record-quic-cpus 0 \
    --enable-record 1 \
    --rapl-interval-ms 6 \
    --freq-interval-ms 1 \
    --require-rapl 1 \
    --stop-irqbalance 1 \
    --mtu 1500 \
    --output-dir "$P7OUT" \
    2>&1 | tee "$ART/p7.log"

log "validate P7 recorder-affinity evidence and new C-state charts"
find "$P7OUT/runs" -type f \( -name 'rapl_affinity.txt' -o -name 'frequency_affinity.txt' -o -name 'cstate_affinity.txt' \) -print > "$ART/p7_affinity_files.txt"
test -s "$ART/p7_affinity_files.txt"
test -f "$P7OUT/the_sheet_rules_all/charts/with_variance/svg/with_values/19_active_cstate_residency.svg"
test -f "$P7OUT/the_sheet_rules_all/charts/with_variance/svg/with_values/20_gap_cstate_residency.svg"

log "validate P5 recorder-affinity evidence"
find "$P5OUT/runs" -type f -name '*_affinity.txt' -print > "$ART/p5_affinity_files.txt"
test -s "$ART/p5_affinity_files.txt"

cat > "$ART/config.env" <<EOF_CONFIG
branch=$BRANCH
commit=$SHA
runs=$RUNS
downloads=$DOWNLOADS
gap_seconds=$GAP
edge_cooldown_seconds=$EDGE
between_seconds=$BETWEEN
seed=$SEED
P5_profile=optimized_Performance2_V2_idle_monitor_normal
P5_dpdk_cpu=19
P5_quic_cpus=21,22,23,24
P5_recorder_cpu=auto_housekeeping
P7_profile=paper_linux
P7_dataplane_cpu=19
P7_quic_cpus=21,22,23,24
P7_recorder_cpu=auto_housekeeping
P7_nic_offloads=paper
P7_disable_rdma=1
P7_udp_rmem=6815744
P7_udp_wmem=6815744
P7_combined_channels=1
NOTE=Uploaded P5 reference had between_tests=0 and uploaded P7 reference had between_runs=10. This fair reproduction deliberately uses the same between_seconds value for both; default is 5 seconds.
EOF_CONFIG

log "zip results"
(cd "$(dirname "$P5OUT")" && zip -qr "/root/P5_FAIR_OPT_PINNED_${RUNS}r_${DOWNLOADS}d_${TAG}.zip" "$(basename "$P5OUT")")
(cd "$(dirname "$P7OUT")" && zip -qr "/root/P7_FAIR_PAPER_PINNED_${RUNS}r_${DOWNLOADS}d_${TAG}.zip" "$(basename "$P7OUT")")
printf '%s\n%s\n' \
    "/root/P5_FAIR_OPT_PINNED_${RUNS}r_${DOWNLOADS}d_${TAG}.zip" \
    "/root/P7_FAIR_PAPER_PINNED_${RUNS}r_${DOWNLOADS}d_${TAG}.zip" \
    > "$ART/RESULT_ZIPS.txt"

touch "$ART/DONE"
log "DONE"
cat "$ART/RESULT_ZIPS.txt"
REMOTE

bash -n "$LOCAL_SCRIPT"

# Install and launch only on IDEX. All Tinyman setup/cleanup now happens inside
# the detached job, so a setup failure is visible in REMOTE_LOG instead of
# making the Mac launcher disappear before a monitorable process exists.
ssh "${SSH_OPTS[@]}" idex "cat > '$REMOTE_SCRIPT' && chmod 0700 '$REMOTE_SCRIPT'" < "$LOCAL_SCRIPT"
ssh "${SSH_OPTS[@]}" idex \
    "rm -rf '$REMOTE_ART'; nohup setsid bash '$REMOTE_SCRIPT' '$TAG' '$SHA' '$BRANCH' '$RUNS' '$DOWNLOADS' '$GAP_SECONDS' '$EDGE_COOLDOWN_SECONDS' '$BETWEEN_SECONDS' '$SEED' >'$REMOTE_LOG' 2>&1 </dev/null & echo \$! >'$REMOTE_PID'; echo REMOTE_PID=\$(cat '$REMOTE_PID')"

echo
echo "STARTED FAIR REPRODUCTION"
echo "TAG=$TAG"
echo "SHA=$SHA"
echo "REMOTE_LOG=$REMOTE_LOG"
echo
echo "LIVE MONITOR:"
echo "ssh idex 'tail -n +1 -F $REMOTE_LOG'"
echo
echo "STATUS:"
echo "ssh idex 'if test -f $REMOTE_ART/DONE; then echo DONE; cat $REMOTE_ART/RESULT_ZIPS.txt; elif test -f $REMOTE_ART/FAILED; then echo FAILED; cat $REMOTE_ART/FAILED; tail -120 $REMOTE_LOG; else echo RUNNING; tail -60 $REMOTE_LOG; fi'"
