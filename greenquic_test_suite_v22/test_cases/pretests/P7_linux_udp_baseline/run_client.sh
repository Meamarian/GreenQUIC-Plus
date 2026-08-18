#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
P7_COMMON_PATCHER="$HERE/enable_p7_recorder_affinity.py"
P7_COMMON_PATCHED="$(mktemp "$HERE/.p7_common_affinity.XXXXXX.sh")"
if ! python3 "$P7_COMMON_PATCHER" "$HERE/p7_common.sh" "$P7_COMMON_PATCHED"; then
    rm -f "$P7_COMMON_PATCHED"
    exit 2
fi
# shellcheck source=/dev/null
source "$P7_COMMON_PATCHED"
rm -f "$P7_COMMON_PATCHED"

RUN_DIR=""
REP="1"
GATE=""
while (($#)); do
    case "$1" in
        --run-dir) RUN_DIR="$2"; shift 2 ;;
        --rep) REP="$2"; shift 2 ;;
        --gate) GATE="$2"; shift 2 ;;
        -h|--help) echo "usage: $0 --run-dir DIR --gate FILE [--rep N]"; exit 0 ;;
        *) p7_die "unknown client option: $1" ;;
    esac
done
[[ -n "$RUN_DIR" && -n "$GATE" ]] || p7_die "--run-dir and --gate are required"
RUN_DIR="$(mkdir -p "$RUN_DIR" && cd "$RUN_DIR" && pwd)"
p7_validate_common
p7_check_host_role client
iface="$(p7_get_iface client)"
[[ "$(p7_driver_for_device "$(p7_role_device client)")" == ice ]] || p7_die "P7 client NIC is not bound to ice"

cfg="$(p7_write_execution_config client "$RUN_DIR")"
cp -p "$HERE/config.env" "$RUN_DIR/config.env.snapshot"
{
    printf 'role=client\nrep=%s\niface=%s\n' "$REP" "$iface"
    printf 'dataplane_cpu=%s\nquic_cpus=%s\npin_irq=%s\npin_quic=%s\n' "$P7_DATAPLANE_CPU" "$P7_QUIC_CPUS" "$P7_PIN_IRQ" "$P7_PIN_QUIC"
    printf 'nic_offloads=%s\n' "$P7_NIC_OFFLOAD_PROFILE"
} > "$RUN_DIR/effective.env"

payload_name="${REQUEST_PATH##*/}"
reference="$P7_SERVER_ROOT/$payload_name"
mkdir -p "$P7_SERVER_ROOT" "$SUITE_ROOT/common/downloads"
[[ -e "$reference" ]] || truncate -s "$PAYLOAD_BYTES" "$reference"
[[ "$(stat -Lc '%s' "$reference")" == "$PAYLOAD_BYTES" ]] || p7_die "payload reference has wrong size: $reference"
ln -sfn /dev/null "$SUITE_ROOT/common/downloads/$payload_name"

args=()
url="https://${P7_SERVER_IP}:${P7_PORT}${REQUEST_PATH}"
for ((i=1; i<=DOWNLOADS_PER_RUN; i++)); do
    if (( i == 1 )); then args+=("-urls:$url"); else args+=("$url"); fi
done

if [[ "$(p7_bool "${P7_SAVE_NETWORK_DIAGNOSTICS:-0}")" == 1 ]]; then
    p7_capture_net_snapshot client "$RUN_DIR" before
fi
p7_start_recorders client "$RUN_DIR"

cleanup() {
    local rc=$? start_ms elapsed_ms
    trap - EXIT INT TERM

    start_ms="$(date +%s%3N)"
    p7_log "client REP $REP: stopping C-state/frequency/RAPL recorders"
    p7_stop_recorders
    elapsed_ms=$(( $(date +%s%3N) - start_ms ))
    p7_log "client REP $REP: recorders stopped in ${elapsed_ms} ms"

    if [[ "$(p7_bool "${P7_SAVE_NETWORK_DIAGNOSTICS:-0}")" == 1 ]]; then
        start_ms="$(date +%s%3N)"
        p7_log "client REP $REP: capturing optional Linux network diagnostics"
        p7_capture_net_snapshot client "$RUN_DIR" after
        elapsed_ms=$(( $(date +%s%3N) - start_ms ))
        p7_log "client REP $REP: optional network diagnostics complete in ${elapsed_ms} ms"
    fi

    if [[ -f "$RUN_DIR/client.log" ]]; then
        start_ms="$(date +%s%3N)"
        p7_log "client REP $REP: starting numeric run analysis (no chart generation)"
        python3 "$HERE/report_p7_run.py" \
            --role client \
            --run-dir "$RUN_DIR" \
            --payload-bytes "$PAYLOAD_BYTES" \
            --downloads "$DOWNLOADS_PER_RUN" \
            --output "$RUN_DIR/summary.json" || rc=$?
        elapsed_ms=$(( $(date +%s%3N) - start_ms ))
        p7_log "client REP $REP: numeric run analysis complete in ${elapsed_ms} ms"
    fi

    touch "$RUN_DIR/client_finished"
    p7_log "client REP $REP: finalization complete"
    exit "$rc"
}
trap cleanup EXIT INT TERM

export GREENQUIC_CONFIG="$cfg"
export GQ_INTEROP_P5_SEQUENCE=1
export GQ_INTEROP_REQUEST_GAP_US="$GAP_US"
export GQ_INTEROP_P5_START_GATE="$GATE"
export GQ_INTEROP_P5_GATE_TIMEOUT_US=120000000

set +e
if [[ "$(p7_bool "$P7_PIN_QUIC")" == 1 ]]; then
    taskset -c "$P7_QUIC_CPUS" stdbuf -oL -eL "$P7_CLIENT_BIN" "-custom:$P7_SERVER_IP" "-port:$P7_PORT" -test:D "-timeout:$CLIENT_TIMEOUT_MS" "-download:$SUITE_ROOT/common/downloads" "${args[@]}" 2>&1 | tee "$RUN_DIR/client.log"
    rc=${PIPESTATUS[0]}
else
    stdbuf -oL -eL "$P7_CLIENT_BIN" "-custom:$P7_SERVER_IP" "-port:$P7_PORT" -test:D "-timeout:$CLIENT_TIMEOUT_MS" "-download:$SUITE_ROOT/common/downloads" "${args[@]}" 2>&1 | tee "$RUN_DIR/client.log"
    rc=${PIPESTATUS[0]}
fi
set -e
[[ "$rc" == 0 ]] || exit "$rc"

completed="$(grep -cE '\[GreenQUIC-P5\] request=[0-9]+/[0-9]+ complete_us=.* success=1' "$RUN_DIR/client.log" || true)"
[[ "$completed" == "$DOWNLOADS_PER_RUN" ]] || p7_die "expected $DOWNLOADS_PER_RUN completed downloads, observed $completed"

p7_log "client REP $REP: all $DOWNLOADS_PER_RUN GETs complete; starting ${P7_POST_COOLDOWN_SECONDS}s post-cooldown"
python3 "$HERE/p7_mark.py" --output "$RUN_DIR/control_timeline.jsonl" --event post_cool_start --role client --run-id "rep$REP"
sleep "$P7_POST_COOLDOWN_SECONDS"
python3 "$HERE/p7_mark.py" --output "$RUN_DIR/control_timeline.jsonl" --event post_cool_end --role client --run-id "rep$REP"
p7_log "client REP $REP: post-cooldown complete; finalizing"
