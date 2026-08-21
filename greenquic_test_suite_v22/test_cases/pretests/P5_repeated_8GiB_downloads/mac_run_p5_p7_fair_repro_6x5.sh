#!/usr/bin/env bash
set -Eeuo pipefail

# Authoritative GreenQUIC+ paper-evaluation launcher.
# RUN ON: control host (a Mac in our paper setup, but any Unix control host is OK).
# The control host needs access to the private GitHub repository and SSH access
# to the server role. The server role must be able to SSH to the client role.

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${GREENQUIC_REPO:-$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)}"
[[ -n "$REPO_ROOT" && -d "$REPO_ROOT/.git" ]] || {
    echo "ERROR: run from a GreenQUIC-Plus clone or set GREENQUIC_REPO" >&2
    exit 2
}

BRANCH=main
RUNS="${GQ_FAIR_RUNS:-6}"
DOWNLOADS="${GQ_FAIR_DOWNLOADS:-5}"
GAP_SECONDS="${GQ_FAIR_GAP_SECONDS:-5}"
EDGE_COOLDOWN_SECONDS="${GQ_FAIR_EDGE_COOLDOWN_SECONDS:-5}"
BETWEEN_SECONDS="${GQ_FAIR_BETWEEN_SECONDS:-5}"
SEED="${GQ_FAIR_SEED:-20260806}"
TAG="${GQ_FAIR_TAG:-$(date +%Y%m%d_%H%M%S)}"

# Paper-testbed defaults. These are host names, not role definitions.
SERVER_HOST="${GQ_SERVER_HOST:-idex}"
CLIENT_HOST="${GQ_CLIENT_HOST:-tinyman}"
BASTION="${GQ_BASTION:-}"
SSH_KEY="${GQ_SSH_KEY:-}"
AUTO_DOWNLOAD="${GQ_FAIR_AUTO_DOWNLOAD:-1}"
DOWNLOAD_DEST="${GQ_FAIR_DOWNLOAD_DEST:-$REPO_ROOT/reproduced_results}"
WAIT_POLL_SECONDS="${GQ_FAIR_WAIT_POLL_SECONDS:-15}"

usage() {
    cat <<'USAGE'
GreenQUIC+ final paper evaluation

RUN ON: control host (Mac in our paper setup)

Host/SSH switches:
  --server-host HOST       SSH endpoint for the QUIC server/controller role
                           as seen from the control host (default: idex)
  --client-host HOST       SSH endpoint/name for the QUIC client role as seen
                           from the server role (default: tinyman)
  --bastion USER@HOST      optional ProxyJump used by control-host -> server SSH
  --bastion none           connect directly from control host to server
  --ssh-key PATH           optional private key used by control-host -> server SSH

Result-copy switches:
  --download-dest DIR      CONTROL-HOST destination root for automatic SCP
                           (default: <repo>/reproduced_results)
  --no-auto-download       start the remote run and return without waiting/SCP
  --auto-download          explicitly enable wait + automatic SCP (default)

Workload switches:
  --runs N                 default 6
  --downloads N            default 5
  --gap-seconds N          default 5
  --edge-cooldown-seconds N default 5
  --between-seconds N      default 5
  --seed N                 default 20260806
  --tag STRING             override output tag
  -h, --help

SSH topology for this launcher:
  control host -> server role: REQUIRED
  server role  -> client role: REQUIRED
  control host -> client role: not required by the final launcher
  client role  -> server role: not required

The server/client host names are configurable. In the paper testbed idex was the
server/controller and tinyman was the client; those names are not semantic.

By default this launcher remains attached on the CONTROL HOST until the remote
run is DONE, prints the final remote/local result paths, then SCPs the result
ZIPs and metadata automatically. Use a second CONTROL-HOST terminal for the
live log monitor while this command waits.
USAGE
}

need_arg() { [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: $1 needs a value" >&2; exit 2; }; }
while (($#)); do
    case "$1" in
        --server-host) need_arg "$@"; SERVER_HOST="$2"; shift 2 ;;
        --client-host) need_arg "$@"; CLIENT_HOST="$2"; shift 2 ;;
        --bastion) need_arg "$@"; BASTION="$2"; shift 2 ;;
        --ssh-key) need_arg "$@"; SSH_KEY="$2"; shift 2 ;;
        --download-dest) need_arg "$@"; DOWNLOAD_DEST="$2"; shift 2 ;;
        --no-auto-download) AUTO_DOWNLOAD=0; shift ;;
        --auto-download) AUTO_DOWNLOAD=1; shift ;;
        --runs) need_arg "$@"; RUNS="$2"; shift 2 ;;
        --downloads) need_arg "$@"; DOWNLOADS="$2"; shift 2 ;;
        --gap-seconds) need_arg "$@"; GAP_SECONDS="$2"; shift 2 ;;
        --edge-cooldown-seconds) need_arg "$@"; EDGE_COOLDOWN_SECONDS="$2"; shift 2 ;;
        --between-seconds) need_arg "$@"; BETWEEN_SECONDS="$2"; shift 2 ;;
        --seed) need_arg "$@"; SEED="$2"; shift 2 ;;
        --tag) need_arg "$@"; TAG="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ "$SERVER_HOST" != "$CLIENT_HOST" ]] || { echo "ERROR: server and client hosts must differ" >&2; exit 2; }
for v in "$RUNS" "$DOWNLOADS"; do
    [[ "$v" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: runs/downloads must be positive integers" >&2; exit 2; }
done
for v in "$GAP_SECONDS" "$EDGE_COOLDOWN_SECONDS" "$BETWEEN_SECONDS"; do
    [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "ERROR: timing values must be non-negative numbers" >&2; exit 2; }
done
[[ "$SEED" =~ ^[0-9]+$ ]] || { echo "ERROR: seed must be an integer" >&2; exit 2; }
[[ "$AUTO_DOWNLOAD" == 0 || "$AUTO_DOWNLOAD" == 1 ]] || { echo "ERROR: GQ_FAIR_AUTO_DOWNLOAD must be 0 or 1" >&2; exit 2; }
[[ "$WAIT_POLL_SECONDS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: GQ_FAIR_WAIT_POLL_SECONDS must be a positive integer" >&2; exit 2; }
if [[ -n "$SSH_KEY" && ! -f "$SSH_KEY" ]]; then
    echo "ERROR: SSH key not found: $SSH_KEY" >&2
    exit 2
fi
if [[ "$DOWNLOAD_DEST" != /* ]]; then DOWNLOAD_DEST="$REPO_ROOT/$DOWNLOAD_DEST"; fi

SSH_OPTS=(-o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new)
[[ -n "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
if [[ -n "$BASTION" && "$BASTION" != none ]]; then
    SSH_OPTS+=(-J "$BASTION")
fi
SERVER_TARGET="root@$SERVER_HOST"

REMOTE_SCRIPT="/tmp/GQ_FAIR_REPRO_${TAG}.sh"
REMOTE_LOG="/root/GQ_FAIR_REPRO_${TAG}.log"
REMOTE_PID="/tmp/GQ_FAIR_REPRO_${TAG}.pid"
REMOTE_ART="/root/GQ_FAIR_REPRO_${TAG}"
REMOTE_P5OUT="/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/matrix_results/P5_FAIR_OPT_PINNED_${RUNS}r_${DOWNLOADS}d_${TAG}"
REMOTE_P7OUT="/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline/matrix_results/P7_FAIR_PAPER_PINNED_${RUNS}r_${DOWNLOADS}d_${TAG}"
LOCAL_SCRIPT="${TMPDIR:-/tmp}/GQ_FAIR_REPRO_${TAG}_$$.sh"
LOCAL_BUNDLE="${TMPDIR:-/tmp}/GQ_FAIR_REPRO_${TAG}_$$.bundle"
REMOTE_BUNDLE="/tmp/GQ_FAIR_REPRO_${TAG}.bundle"
BUNDLE_REF="refs/heads/__gq_fair_repro_${TAG}_$$"

cleanup_local() {
    git -C "$REPO_ROOT" update-ref -d "$BUNDLE_REF" >/dev/null 2>&1 || true
    rm -f "$LOCAL_SCRIPT" "$LOCAL_BUNDLE"
}
trap cleanup_local EXIT INT TERM

cd "$REPO_ROOT"
ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
case "$ORIGIN_URL" in
    git@github.com:Meamarian/GreenQUIC-Plus.git|https://github.com/Meamarian/GreenQUIC-Plus.git) ;;
    *) echo "ERROR: origin must be Meamarian/GreenQUIC-Plus, got: ${ORIGIN_URL:-none}" >&2; exit 2 ;;
esac

# Explicit refspec makes this work even if the local clone was originally made
# with --single-branch and its remote.origin.fetch still names an old branch.
git fetch origin '+refs/heads/main:refs/remotes/origin/main'
SHA="$(git rev-parse refs/remotes/origin/main)"
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "ERROR: cannot resolve origin/main" >&2; exit 2; }

git update-ref "$BUNDLE_REF" "$SHA"
git bundle create "$LOCAL_BUNDLE" "$BUNDLE_REF"
git update-ref -d "$BUNDLE_REF"
git bundle verify "$LOCAL_BUNDLE" >/dev/null

printf '%s\n' \
    '======================================================================' \
    'GREENQUIC+ FINAL PAPER EVALUATION' \
    'RUN ON: control host' \
    "server role: $SERVER_HOST" \
    "client role (reachable from server): $CLIENT_HOST" \
    "bastion: ${BASTION:-none}" \
    "branch=$BRANCH" \
    "sha=$SHA" \
    "runs=$RUNS downloads=$DOWNLOADS" \
    "gap=${GAP_SECONDS}s edge_cooldown=${EDGE_COOLDOWN_SECONDS}s between=${BETWEEN_SECONDS}s" \
    "automatic_result_scp=$AUTO_DOWNLOAD" \
    "local_result_root=$DOWNLOAD_DEST" \
    'P5=Performance2 V2 + TOP3 + monitor/short + isolated recorders' \
    'P7=isolated normal-Linux paper baseline' \
    '======================================================================'

# Final run only needs control-host -> server; the server then controls the client.
ssh "${SSH_OPTS[@]}" "$SERVER_TARGET" true

cat > "$LOCAL_SCRIPT" <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail

TAG="$1"; SHA="$2"; BRANCH="$3"; RUNS="$4"; DOWNLOADS="$5"; GAP="$6"; EDGE="$7"; BETWEEN="$8"; SEED="$9"
SERVER_HOST_LABEL="${10}"; CLIENT_HOST="${11}"; BUNDLE="${12}"; BUNDLE_REF="${13}"
ROOT=/root/mohsen
P5="$ROOT/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
P7="$ROOT/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline"
P5BIN="$ROOT/msquic/build-greenquic-p5/bin/Release/quicinterop"
ART="/root/GQ_FAIR_REPRO_${TAG}"
P5OUT="$P5/matrix_results/P5_FAIR_OPT_PINNED_${RUNS}r_${DOWNLOADS}d_${TAG}"
P7OUT="$P7/matrix_results/P7_FAIR_PAPER_PINNED_${RUNS}r_${DOWNLOADS}d_${TAG}"
P5ZIP="/root/P5_FAIR_OPT_PINNED_${RUNS}r_${DOWNLOADS}d_${TAG}.zip"
P7ZIP="/root/P7_FAIR_PAPER_PINNED_${RUNS}r_${DOWNLOADS}d_${TAG}.zip"
CLIENT_TARGET="root@$CLIENT_HOST"
CLIENT_SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new)
mkdir -p "$ART"
rm -f "$ART/DONE" "$ART/FAILED"

log(){ printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
client_ssh(){ ssh "${CLIENT_SSH_OPTS[@]}" "$CLIENT_TARGET" "$@"; }

restore_p5_common(){
    set +e
    git -C "$ROOT" checkout "$SHA" -- greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/gq_common_p5.sh >/dev/null 2>&1 || true
    client_ssh "git -C '$ROOT' checkout '$SHA' -- greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/gq_common_p5.sh" >/dev/null 2>&1 || true
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

log "verify required server-role -> client-role SSH"
client_ssh 'hostname'

log "synchronize exact bundled main SHA on server role ($SERVER_HOST_LABEL)"
test -s "$BUNDLE"
cd "$ROOT"
git reset --hard
git fetch "$BUNDLE" "$BUNDLE_REF"
git checkout -B "$BRANCH" FETCH_HEAD
test "$(git rev-parse HEAD)" = "$SHA"

log "copy exact-SHA bundle to client role ($CLIENT_HOST) and synchronize"
scp "${CLIENT_SSH_OPTS[@]}" "$BUNDLE" "$CLIENT_TARGET:$BUNDLE"
client_ssh "cd '$ROOT' && git reset --hard && git fetch '$BUNDLE' '$BUNDLE_REF' && git checkout -B '$BRANCH' FETCH_HEAD && test \"\$(git rev-parse HEAD)\" = '$SHA'"

cleanup_both(){
    log "safe cleanup on server role ($SERVER_HOST_LABEL)"
    cd "$P5"
    python3 ./safe_cleanup_p5_bottleneck_processes.py
    python3 ./safe_cleanup_p5_bottleneck_processes.py --check
    log "safe cleanup on client role ($CLIENT_HOST)"
    client_ssh "cd '$P5' && python3 ./safe_cleanup_p5_bottleneck_processes.py && python3 ./safe_cleanup_p5_bottleneck_processes.py --check"
}

log "verify recorder/report self-tests"
cd "$P5"
python3 ./enable_p5_claim_recording_gate.py --self-test
python3 ./validate_p5_recorder_evidence.py --self-test
cd "$P7"
python3 ./enable_p7_recorder_affinity.py --self-test
python3 ./build_p7_report.py --self-test
cleanup_both

log "build P5 Performance2 V2 on both roles"
(
    cd "$P5"
    P5_BUILD_REUSE=1 bash ./build_p5_performance2.sh >"$ART/build_p5_server.log" 2>&1
) & p1=$!
client_ssh "cd '$P5' && P5_BUILD_REUSE=1 bash ./build_p5_performance2.sh" >"$ART/build_p5_client.log" 2>&1 & p2=$!
wait "$p1"; wait "$p2"
P5_MARKER='GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0'
grep -aFq -- "$P5_MARKER" "$P5BIN"
client_ssh "grep -aFq -- '$P5_MARKER' '$P5BIN'"

log "build isolated P7 Linux binaries on both roles"
(
    cd "$P7"
    bash ./build_p7_linux.sh >"$ART/build_p7_server.log" 2>&1
) & p3=$!
client_ssh "cd '$P7' && bash ./build_p7_linux.sh" >"$ART/build_p7_client.log" 2>&1 & p4=$!
wait "$p3"; wait "$p4"

log "apply P5 recorder CPU isolation on both roles"
cd "$P5"
python3 ./enable_p5_claim_recording_gate.py ./gq_common_p5.sh
client_ssh "cd '$P5' && python3 ./enable_p5_claim_recording_gate.py ./gq_common_p5.sh"
grep -Fq 'GREENQUIC-P5-CLAIM-RECORDER-AFFINITY-V1' "$P5/gq_common_p5.sh"
client_ssh "grep -Fq 'GREENQUIC-P5-CLAIM-RECORDER-AFFINITY-V1' '$P5/gq_common_p5.sh'"
cleanup_both

log "TEST 1/2: P5 DPDK OFF/BASIC/PLUS, final TOP3 paper profile"
cd "$P5"
bash ./run_matrix_with_sheet.sh \
    --chart-style both \
    --client-host "$CLIENT_HOST" \
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
    --env GQ_ENABLE_ACPI_POWER_TRACE=1 \
    --env GQ_POWER_SAMPLE_INTERVAL_MS=1000 \
    --env GQ_ENABLE_MSR_TRACE=1 \
    --env GQ_MSR_SAMPLE_INTERVAL_MS=6 \
    --env GQ_MSR_SMOOTH_SAMPLES=3 \
    --env ENABLE_CSTATE_RECORD=1 \
    --env GQ_ENABLE_FREQ_TRACE=1 \
    --env GQ_FREQ_SAMPLE_INTERVAL_MS=1 \
    --env PRESSURE_UP=450 \
    --env RX_QUEUE_HIGH=48 \
    --env ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16 \
    --env FREQ_PERIOD_US=10000 \
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

log "TEST 2/2: P7 isolated normal-Linux baseline"
cd "$P7"
P7_RECORDER_CPU=auto bash ./run_matrix_with_report.sh \
    --chart-style both \
    --log-level 0 \
    --client-host "$CLIENT_HOST" \
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

log "validate P7 recorder-affinity evidence and C-state charts"
find "$P7OUT/runs" -type f \( -name 'rapl_affinity.txt' -o -name 'frequency_affinity.txt' -o -name 'cstate_affinity.txt' \) -print > "$ART/p7_affinity_files.txt"
test -s "$ART/p7_affinity_files.txt"
test -f "$P7OUT/the_sheet_rules_all/charts/with_variance/svg/with_values/19_active_cstate_residency.svg"
test -f "$P7OUT/the_sheet_rules_all/charts/with_variance/svg/with_values/20_gap_cstate_residency.svg"

log "validate P5 matrix integrity and durable recorder-CPU evidence"
cd "$P5"
python3 ./validate_p5_recorder_evidence.py \
    --matrix-dir "$P5OUT" \
    --runs "$RUNS" \
    --output "$ART/p5_recorder_evidence.json"

cat > "$ART/config.env" <<EOF_CONFIG
branch=$BRANCH
commit=$SHA
server_role_host=$SERVER_HOST_LABEL
client_role_host=$CLIENT_HOST
runs=$RUNS
downloads=$DOWNLOADS
gap_seconds=$GAP
edge_cooldown_seconds=$EDGE
between_seconds=$BETWEEN
seed=$SEED
P5_profile=optimized_Performance2_V2_TOP3_idle_monitor_normal
P5_power_profile=TOP3
P5_pressure_up=450
P5_rx_queue_high=48
P5_active_transfer_sleep_min_level=16
P5_freq_period_us=10000
P5_idle_mode=monitor
P5_idle_fallback=short
P5_acpi_interval_ms=1000
P5_msr_interval_ms=6
P5_freq_trace_interval_ms=1
P5_dpdk_cpu=19
P5_quic_cpus=21,22,23,24
P5_recorder_cpu=auto_housekeeping
P5_recorder_validation=durable_per_run_log_evidence
P7_profile=paper_linux
P7_dataplane_cpu=19
P7_quic_cpus=21,22,23,24
P7_recorder_cpu=auto_housekeeping
P7_nic_offloads=paper
P7_disable_rdma=1
P7_udp_rmem=6815744
P7_udp_wmem=6815744
P7_combined_channels=1
EOF_CONFIG

cat > "$ART/RESULT_DIRS.env" <<EOF_DIRS
artifact_dir=$ART
remote_log=/root/GQ_FAIR_REPRO_${TAG}.log
p5_matrix_dir=$P5OUT
p7_matrix_dir=$P7OUT
p5_zip=$P5ZIP
p7_zip=$P7ZIP
EOF_DIRS

log "FINAL REMOTE RESULT PATHS (before archive/SCP)"
cat "$ART/RESULT_DIRS.env"

log "zip results"
rm -f "$P5ZIP" "$P7ZIP"
(cd "$(dirname "$P5OUT")" && zip -qr "$P5ZIP" "$(basename "$P5OUT")")
(cd "$(dirname "$P7OUT")" && zip -qr "$P7ZIP" "$(basename "$P7OUT")")
printf '%s\n%s\n' "$P5ZIP" "$P7ZIP" > "$ART/RESULT_ZIPS.txt"
(cd /root && sha256sum "$(basename "$P5ZIP")" "$(basename "$P7ZIP")") > "$ART/RESULT_ZIPS.sha256"

touch "$ART/DONE"
log "DONE — final paths follow"
cat "$ART/RESULT_DIRS.env"
cat "$ART/RESULT_ZIPS.sha256"
REMOTE

bash -n "$LOCAL_SCRIPT"
scp "${SSH_OPTS[@]}" "$LOCAL_BUNDLE" "$SERVER_TARGET:$REMOTE_BUNDLE"
ssh "${SSH_OPTS[@]}" "$SERVER_TARGET" "test -s '$REMOTE_BUNDLE'"
ssh "${SSH_OPTS[@]}" "$SERVER_TARGET" "cat > '$REMOTE_SCRIPT' && chmod 0700 '$REMOTE_SCRIPT'" < "$LOCAL_SCRIPT"
ssh "${SSH_OPTS[@]}" "$SERVER_TARGET" \
    "rm -rf '$REMOTE_ART'; nohup setsid bash '$REMOTE_SCRIPT' '$TAG' '$SHA' '$BRANCH' '$RUNS' '$DOWNLOADS' '$GAP_SECONDS' '$EDGE_COOLDOWN_SECONDS' '$BETWEEN_SECONDS' '$SEED' '$SERVER_HOST' '$CLIENT_HOST' '$REMOTE_BUNDLE' '$BUNDLE_REF' >'$REMOTE_LOG' 2>&1 </dev/null & echo \$! >'$REMOTE_PID'; echo REMOTE_PID=\$(cat '$REMOTE_PID')"

cat <<EOF

STARTED FAIR REPRODUCTION
RUN LOCATION: control host
SERVER_ROLE=$SERVER_HOST
CLIENT_ROLE=$CLIENT_HOST
TAG=$TAG
SHA=$SHA
REMOTE_LOG=$REMOTE_LOG
EXPECTED_P5_RESULT_DIR=$REMOTE_P5OUT
EXPECTED_P7_RESULT_DIR=$REMOTE_P7OUT

LIVE MONITOR FROM ANOTHER CONTROL-HOST TERMINAL:
ssh ${BASTION:+-J "$BASTION" }${SSH_KEY:+-i "$SSH_KEY" }root@$SERVER_HOST 'tail -n +1 -F $REMOTE_LOG'

STATUS FROM CONTROL HOST:
ssh ${BASTION:+-J "$BASTION" }${SSH_KEY:+-i "$SSH_KEY" }root@$SERVER_HOST 'if test -f $REMOTE_ART/DONE; then echo DONE; cat $REMOTE_ART/RESULT_DIRS.env; elif test -f $REMOTE_ART/FAILED; then echo FAILED; cat $REMOTE_ART/FAILED; tail -120 $REMOTE_LOG; else echo RUNNING; tail -60 $REMOTE_LOG; fi'
EOF

if [[ "$AUTO_DOWNLOAD" == 0 ]]; then
    echo
    echo "Automatic SCP disabled. Remote run continues in the background."
    echo "When DONE, use results_analysis/download_latest_reproduction.sh --tag '$TAG'."
    exit 0
fi

echo
echo "AUTO-DOWNLOAD ENABLED: waiting for remote DONE before SCP."
echo "Keep the live monitor open in the second CONTROL-HOST terminal."
while true; do
    state="$(ssh "${SSH_OPTS[@]}" "$SERVER_TARGET" "if test -f '$REMOTE_ART/DONE'; then echo DONE; elif test -f '$REMOTE_ART/FAILED'; then echo FAILED; elif test -f '$REMOTE_PID' && kill -0 \$(cat '$REMOTE_PID') 2>/dev/null; then echo RUNNING; else echo UNKNOWN; fi")"
    case "$state" in
        DONE) break ;;
        FAILED)
            echo
            echo "REMOTE RUN FAILED — no result SCP will be attempted."
            echo "Recoverable/current remote paths:"
            echo "  artifact: $REMOTE_ART"
            echo "  log:      $REMOTE_LOG"
            echo "  P5:       $REMOTE_P5OUT"
            echo "  P7:       $REMOTE_P7OUT"
            ssh "${SSH_OPTS[@]}" "$SERVER_TARGET" "cat '$REMOTE_ART/FAILED' 2>/dev/null || true; tail -160 '$REMOTE_LOG' 2>/dev/null || true" >&2
            exit 1
            ;;
        RUNNING)
            printf '[%s] remote run still active; waiting %ss before next completion check\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$WAIT_POLL_SECONDS"
            sleep "$WAIT_POLL_SECONDS"
            ;;
        *)
            echo "ERROR: remote controller is neither RUNNING, DONE nor explicitly FAILED." >&2
            echo "Remote artifact: $REMOTE_ART" >&2
            echo "Remote log: $REMOTE_LOG" >&2
            ssh "${SSH_OPTS[@]}" "$SERVER_TARGET" "tail -160 '$REMOTE_LOG' 2>/dev/null || true" >&2
            exit 1
            ;;
    esac
done

echo
echo "REMOTE RUN IS DONE. The downloader will print FINAL REMOTE and LOCAL paths before SCP starts."
DOWNLOAD_CMD=(
    bash "$REPO_ROOT/results_analysis/download_latest_reproduction.sh"
    --server-host "$SERVER_HOST"
    --tag "$TAG"
    --dest "$DOWNLOAD_DEST"
    --expect-runs "$RUNS"
    --expect-downloads "$DOWNLOADS"
)
if [[ -n "$BASTION" ]]; then DOWNLOAD_CMD+=(--bastion "$BASTION"); fi
if [[ -n "$SSH_KEY" ]]; then DOWNLOAD_CMD+=(--ssh-key "$SSH_KEY"); fi
"${DOWNLOAD_CMD[@]}"

echo
echo "GREENQUIC+ FINAL PAPER EVALUATION + AUTOMATIC SCP: PASS"
echo "Local result directory: $DOWNLOAD_DEST/$TAG"
