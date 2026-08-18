#!/usr/bin/env bash
set -Eeuo pipefail

BRANCH="performance2/p5-multicore"
RUNS="${GQ_FAIR_RUNS:-6}"
DOWNLOADS="${GQ_FAIR_DOWNLOADS:-5}"
GAP="${GQ_FAIR_GAP_SECONDS:-5}"
EDGE="${GQ_FAIR_EDGE_COOLDOWN_SECONDS:-5}"
BETWEEN="${GQ_FAIR_BETWEEN_SECONDS:-5}"
SEED="${GQ_FAIR_SEED:-20260806}"
TAG="${GQ_FAIR_TAG:-P5_TOP3_T29_P7_$(date +%Y%m%d_%H%M%S)}"
AUTO_SCP="${GQ_AUTO_SCP:-1}"

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO" && -d "$REPO/.git" ]] || { echo "ERROR: cannot resolve GreenQUIC repo" >&2; exit 2; }

P5_REL="greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
ROOT="/root/mohsen"
P5="$ROOT/$P5_REL"
P7="$ROOT/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline"

LOCAL_BUNDLE="${TMPDIR:-/tmp}/${TAG}_$$.bundle"
TMPREF="refs/heads/__${TAG}_$$"
REMOTE_BUNDLE="/tmp/${TAG}.bundle"
REMOTE_SCRIPT="/tmp/${TAG}_remote.sh"
REMOTE_LOG="/root/${TAG}.log"
REMOTE_PID="/root/${TAG}.pid"
ART="/root/${TAG}"
LOCAL_DEST="${GQ_LOCAL_RESULTS_DIR:-$HOME/Downloads/GreenQUIC_results/$TAG}"

cleanup_local(){
    git -C "$REPO" update-ref -d "$TMPREF" 2>/dev/null || true
    rm -f "$LOCAL_BUNDLE"
}
trap cleanup_local EXIT INT TERM

for v in "$RUNS" "$DOWNLOADS"; do
    [[ "$v" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: invalid run/download count: $v" >&2; exit 2; }
done

cd "$REPO"
git fetch origin "$BRANCH"
SHA="$(git rev-parse "origin/$BRANCH")"
git update-ref "$TMPREF" "$SHA"
git bundle create "$LOCAL_BUNDLE" "$TMPREF"
git update-ref -d "$TMPREF"
git bundle verify "$LOCAL_BUNDLE" >/dev/null

cat <<HDR
======================================================================
P5 TOP3 -> P5 T29 -> P7 FAIR SEQUENCE
branch=$BRANCH
sha=$SHA
runs=$RUNS downloads=$DOWNLOADS
P5 modes: OFF + BASIC + PLUS (normal 3-mode chart/sheet pipeline)
P5 TOP3: PRESSURE_UP=450 RX_QUEUE_HIGH=48 ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16
P5 T29:  RX_QUEUE_HIGH=48
P7: paper Linux profile
recording: power/RAPL + frequency 1ms + C-state
P5/P7 chart generation: enabled (chart-style=both)
local destination: $LOCAL_DEST
======================================================================
HDR

scp "$LOCAL_BUNDLE" "idex:$REMOTE_BUNDLE"

ssh idex "cat > '$REMOTE_SCRIPT' && chmod 0700 '$REMOTE_SCRIPT'" <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail

TAG="$1"; SHA="$2"; BRANCH="$3"; RUNS="$4"; DOWNLOADS="$5"; GAP="$6"; EDGE="$7"; BETWEEN="$8"; SEED="$9"; BUNDLE="${10}"; BUNDLE_REF="${11}"
ROOT=/root/mohsen
P5="$ROOT/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
P7="$ROOT/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline"
P5BIN="$ROOT/msquic/build-greenquic-p5/bin/Release/quicinterop"
ART="/root/$TAG"
P5_TOP3_OUT="$P5/matrix_results/P5_TOP3_FAIR_3MODES_${RUNS}r_${DOWNLOADS}d_${TAG}"
P5_T29_OUT="$P5/matrix_results/P5_T29_FAIR_3MODES_${RUNS}r_${DOWNLOADS}d_${TAG}"
P7_OUT="$P7/matrix_results/P7_FAIR_PAPER_${RUNS}r_${DOWNLOADS}d_${TAG}"
mkdir -p "$ART"
rm -f "$ART/DONE" "$ART/FAILED" "$ART/RESULT_ZIPS.txt"

log(){ printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

restore_repo_file(){
    local rel="$1"
    git -C "$ROOT" checkout "$SHA" -- "$rel" >/dev/null 2>&1 || true
    ssh -n -o BatchMode=yes root@tinyman "git -C '$ROOT' checkout '$SHA' -- '$rel'" >/dev/null 2>&1 || true
}

on_exit(){
    rc=$?
    trap - EXIT INT TERM
    restore_repo_file greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/gq_common_p5.sh
    rm -f "$BUNDLE" >/dev/null 2>&1 || true
    ssh -n root@tinyman "rm -f '$BUNDLE'" >/dev/null 2>&1 || true
    if (( rc != 0 )); then
        printf 'rc=%s\nline=%s\n' "$rc" "${BASH_LINENO[0]:-unknown}" > "$ART/FAILED"
        log "FAILED rc=$rc"
    fi
    exit "$rc"
}
trap on_exit EXIT INT TERM

cleanup_both(){
    cd "$P5"
    python3 ./safe_cleanup_p5_bottleneck_processes.py || true
    python3 ./safe_cleanup_p5_bottleneck_processes.py --check
    ssh -n root@tinyman "cd '$P5' && python3 ./safe_cleanup_p5_bottleneck_processes.py || true; python3 ./safe_cleanup_p5_bottleneck_processes.py --check"
}

log "sync exact SHA on IDEX"
cd "$ROOT"
git reset --hard
git fetch "$BUNDLE" "$BUNDLE_REF"
git checkout -B "$BRANCH" FETCH_HEAD
test "$(git rev-parse HEAD)" = "$SHA"

log "sync exact SHA on Tinyman"
scp -q "$BUNDLE" root@tinyman:"$BUNDLE"
ssh -n root@tinyman "cd '$ROOT' && git reset --hard && git fetch '$BUNDLE' '$BUNDLE_REF' && git checkout -B '$BRANCH' FETCH_HEAD && test \"\$(git rev-parse HEAD)\" = '$SHA'"

cleanup_both

log "build P5 Performance2 V2 on both endpoints"
(cd "$P5" && P5_BUILD_REUSE=1 bash ./build_p5_performance2.sh >"$ART/build_p5_idex.log" 2>&1) & p1=$!
ssh -n root@tinyman "cd '$P5' && P5_BUILD_REUSE=1 bash ./build_p5_performance2.sh" >"$ART/build_p5_tinyman.log" 2>&1 & p2=$!
wait "$p1"; wait "$p2"
P5_MARKER='GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0'
grep -aFq -- "$P5_MARKER" "$P5BIN"
ssh -n root@tinyman "grep -aFq -- '$P5_MARKER' '$P5BIN'"

log "build P7 Linux binaries on both endpoints"
(cd "$P7" && bash ./build_p7_linux.sh >"$ART/build_p7_idex.log" 2>&1) & p3=$!
ssh -n root@tinyman "cd '$P7' && bash ./build_p7_linux.sh" >"$ART/build_p7_tinyman.log" 2>&1 & p4=$!
wait "$p3"; wait "$p4"

log "apply isolated P5 recorder affinity on both endpoints"
cd "$P5"
python3 ./enable_p5_claim_recording_gate.py ./gq_common_p5.sh
ssh -n root@tinyman "cd '$P5' && python3 ./enable_p5_claim_recording_gate.py ./gq_common_p5.sh"
grep -Fq 'GREENQUIC-P5-CLAIM-RECORDER-AFFINITY-V1' ./gq_common_p5.sh
ssh -n root@tinyman "grep -Fq 'GREENQUIC-P5-CLAIM-RECORDER-AFFINITY-V1' '$P5/gq_common_p5.sh'"

P5_COMMON_ARGS=(
    --chart-style both
    --client-host tinyman
    --client-dir "$P5"
    --client-bin "$P5BIN"
    --downloads "$DOWNLOADS"
    --gap-seconds "$GAP"
    --server-cooldown-seconds "$EDGE"
    --between-tests-seconds "$BETWEEN"
    --cstate-cpu 19
    --runs "$RUNS"
    --mode-order balanced
    --seed "$SEED"
    --env ENABLE_RECORD=1
    --env GQ_CLAIM_DISABLE_ACTIVE_RECORDERS=0
    --env GQ_CLAIM_RECORDER_CPU=auto
    --env GQ_LOG_LEVEL=0
    --env ENABLE_FREQ=1
    --env ENABLE_SLEEP=1
    --env ENABLE_PAUSE=1
    --env KEEP_PAUSE_ITERATIONS=1
    --env SHORT_PAUSE_ITERATIONS=1
    --env GQ_IDLE_MODE_OVERRIDE=monitor
    --env GQ_IDLE_FALLBACK_OVERRIDE=short
    --env GQ_ENABLE_ACPI_POWER_TRACE=1
    --env GQ_POWER_SAMPLE_INTERVAL_MS=1000
    --env GQ_ENABLE_MSR_TRACE=1
    --env GQ_MSR_SAMPLE_INTERVAL_MS=6
    --env GQ_MSR_SMOOTH_SAMPLES=3
    --env ENABLE_CSTATE_RECORD=1
    --env GQ_ENABLE_FREQ_TRACE=1
    --env GQ_FREQ_SAMPLE_INTERVAL_MS=1
    --env GQ_POST_TRANSFER_WAIT_S=0
    --env ENABLE_MULTICORE=0
    --env SERVER_DPDK_LCORES=19
    --env CLIENT_DPDK_LCORES=19
    --env SERVER_TX_OWNER_LCORE=19
    --env CLIENT_TX_OWNER_LCORE=19
    --env SERVER_QUIC_CPUS=21,22,23,24
    --env CLIENT_QUIC_CPUS=21,22,23,24
    --env MSQUIC_EXECUTION_PROFILE=max_throughput
)

cleanup_both
log "TEST 1/3 P5 TOP3 — OFF + BASIC + PLUS"
cd "$P5"
bash ./run_matrix_with_sheet.sh "${P5_COMMON_ARGS[@]}" \
    --output-dir "$P5_TOP3_OUT" \
    --env PRESSURE_UP=450 \
    --env RX_QUEUE_HIGH=48 \
    --env ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16 \
    2>&1 | tee "$ART/p5_top3.log"

grep -RFl 'GreenQUIC Run Summary' "$P5_TOP3_OUT/runs" >/dev/null
for mode in off basic plus; do
    find "$P5_TOP3_OUT/runs" -type d -name "*_${mode}" -print -quit | grep -q . || {
        echo "ERROR: TOP3 missing mode=$mode run bundles" >&2
        exit 1
    }
done
find "$P5_TOP3_OUT/runs" -type f -name '*_affinity.txt' -print > "$ART/p5_top3_affinity.txt"
test -s "$ART/p5_top3_affinity.txt"

cleanup_both
sleep "$BETWEEN"
log "TEST 2/3 P5 T29 RX_QUEUE_HIGH=48 — OFF + BASIC + PLUS"
cd "$P5"
bash ./run_matrix_with_sheet.sh "${P5_COMMON_ARGS[@]}" \
    --output-dir "$P5_T29_OUT" \
    --env RX_QUEUE_HIGH=48 \
    2>&1 | tee "$ART/p5_t29.log"

grep -RFl 'GreenQUIC Run Summary' "$P5_T29_OUT/runs" >/dev/null
for mode in off basic plus; do
    find "$P5_T29_OUT/runs" -type d -name "*_${mode}" -print -quit | grep -q . || {
        echo "ERROR: T29 missing mode=$mode run bundles" >&2
        exit 1
    }
done
find "$P5_T29_OUT/runs" -type f -name '*_affinity.txt' -print > "$ART/p5_t29_affinity.txt"
test -s "$ART/p5_t29_affinity.txt"

cleanup_both
sleep "$BETWEEN"
log "TEST 3/3 P7 paper Linux baseline"
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
    --output-dir "$P7_OUT" \
    2>&1 | tee "$ART/p7.log"

find "$P7_OUT/runs" -type f \( -name 'rapl_affinity.txt' -o -name 'frequency_affinity.txt' -o -name 'cstate_affinity.txt' \) -print > "$ART/p7_affinity.txt"
test -s "$ART/p7_affinity.txt"

cat > "$ART/config.env" <<CFG
branch=$BRANCH
commit=$SHA
runs=$RUNS
downloads=$DOWNLOADS
gap_seconds=$GAP
edge_cooldown_seconds=$EDGE
between_seconds=$BETWEEN
seed=$SEED
P5_modes=off,basic,plus
P5_chart_pipeline=normal_3mode_run_matrix_with_sheet_chart_style_both
P5_profile=Performance2_V2_monitor_short
P5_top3=PRESSURE_UP_450,RX_QUEUE_HIGH_48,ACTIVE_TRANSFER_SLEEP_MIN_LEVEL_16
P5_t29=RX_QUEUE_HIGH_48
P5_dpdk_cpu=19
P5_quic_cpus=21,22,23,24
P5_recording=power1_1000ms,rapl_msr_6ms,frequency_1ms,cstate_cpu19
P7_profile=paper_linux
P7_dataplane_cpu=19
P7_quic_cpus=21,22,23,24
P7_recording=rapl_6ms,frequency_1ms,cstate_cpu19
P7_disable_rdma=1
P7_nic_offloads=paper
P7_udp_rmem=6815744
P7_udp_wmem=6815744
P7_combined_channels=1
CFG

log "zip all three result directories"
TOP3_ZIP="/root/P5_TOP3_FAIR_3MODES_${RUNS}r_${DOWNLOADS}d_${TAG}.zip"
T29_ZIP="/root/P5_T29_FAIR_3MODES_${RUNS}r_${DOWNLOADS}d_${TAG}.zip"
P7_ZIP="/root/P7_FAIR_PAPER_${RUNS}r_${DOWNLOADS}d_${TAG}.zip"
(cd "$(dirname "$P5_TOP3_OUT")" && zip -qr "$TOP3_ZIP" "$(basename "$P5_TOP3_OUT")")
(cd "$(dirname "$P5_T29_OUT")" && zip -qr "$T29_ZIP" "$(basename "$P5_T29_OUT")")
(cd "$(dirname "$P7_OUT")" && zip -qr "$P7_ZIP" "$(basename "$P7_OUT")")
printf '%s\n%s\n%s\n' "$TOP3_ZIP" "$T29_ZIP" "$P7_ZIP" > "$ART/RESULT_ZIPS.txt"
touch "$ART/DONE"
log "DONE"
cat "$ART/RESULT_ZIPS.txt"
REMOTE

BUNDLE_REF="$TMPREF"

ssh idex "rm -rf '$ART'; nohup setsid bash '$REMOTE_SCRIPT' '$TAG' '$SHA' '$BRANCH' '$RUNS' '$DOWNLOADS' '$GAP' '$EDGE' '$BETWEEN' '$SEED' '$REMOTE_BUNDLE' '$BUNDLE_REF' >'$REMOTE_LOG' 2>&1 </dev/null & echo \$! >'$REMOTE_PID'"
sleep 5

RPID="$(ssh idex "cat '$REMOTE_PID' 2>/dev/null || true")"
if [[ -z "$RPID" ]] || ! ssh idex "kill -0 '$RPID' 2>/dev/null"; then
    echo "ERROR: remote sequence died during startup"
    ssh idex "cat '$REMOTE_LOG' 2>/dev/null || true"
    exit 1
fi

echo "REMOTE START OK"
echo "TAG=$TAG"
echo "REMOTE_PID=$RPID"
echo "REMOTE_LOG=$REMOTE_LOG"
echo "REMOTE_ART=$ART"
echo "LIVE: ssh idex 'tail -n +1 -F $REMOTE_LOG'"

if [[ "$AUTO_SCP" != 1 ]]; then
    echo "GQ_AUTO_SCP=$AUTO_SCP: remote sequence continues detached; automatic SCP disabled."
    exit 0
fi

mkdir -p "$LOCAL_DEST"
if command -v caffeinate >/dev/null 2>&1; then
    caffeinate -dimsu -w $$ >/dev/null 2>&1 &
fi

echo "Waiting for all three tests to finish; Mac must remain awake/network-connected for automatic SCP."
while :; do
    if ssh idex "test -f '$ART/DONE'"; then
        break
    fi
    if ssh idex "test -f '$ART/FAILED'"; then
        echo "REMOTE SEQUENCE FAILED"
        ssh idex "cat '$ART/FAILED'; tail -120 '$REMOTE_LOG'"
        scp "idex:$REMOTE_LOG" "$LOCAL_DEST/" 2>/dev/null || true
        exit 1
    fi
    ssh idex "tail -4 '$REMOTE_LOG' 2>/dev/null || true"
    sleep 30
done

echo "Remote sequence DONE; downloading result ZIPs..."
ssh idex "cat '$ART/RESULT_ZIPS.txt'" | while IFS= read -r remote_zip; do
    [[ -n "$remote_zip" ]] || continue
    scp "idex:$remote_zip" "$LOCAL_DEST/"
done
scp "idex:$ART/config.env" "$LOCAL_DEST/"
scp "idex:$REMOTE_LOG" "$LOCAL_DEST/"

echo "======================================================================"
echo "ALL DONE + SCP COMPLETE"
echo "LOCAL_RESULTS=$LOCAL_DEST"
ls -lh "$LOCAL_DEST"
echo "======================================================================"
