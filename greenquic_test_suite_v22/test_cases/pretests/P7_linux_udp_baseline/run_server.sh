#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/p7_common.sh"

RUN_DIR=""
REP="1"
while (($#)); do
    case "$1" in
        --run-dir) RUN_DIR="$2"; shift 2 ;;
        --rep) REP="$2"; shift 2 ;;
        -h|--help) echo "usage: $0 --run-dir DIR [--rep N]"; exit 0 ;;
        *) p7_die "unknown server option: $1" ;;
    esac
done
[[ -n "$RUN_DIR" ]] || p7_die "--run-dir is required"
RUN_DIR="$(mkdir -p "$RUN_DIR" && cd "$RUN_DIR" && pwd)"
p7_validate_common
p7_check_host_role server
iface="$(p7_get_iface server)"
[[ "$(p7_driver_for_device "$(p7_role_device server)")" == ice ]] || p7_die "P7 server NIC is not bound to ice"

cfg="$(p7_write_execution_config server "$RUN_DIR")"
cp -p "$HERE/config.env" "$RUN_DIR/config.env.snapshot"
{
    printf 'role=server\nrep=%s\niface=%s\n' "$REP" "$iface"
    printf 'dataplane_cpu=%s\nquic_cpus=%s\npin_irq=%s\npin_quic=%s\n' "$P7_DATAPLANE_CPU" "$P7_QUIC_CPUS" "$P7_PIN_IRQ" "$P7_PIN_QUIC"
    printf 'nic_offloads=%s\n' "$P7_NIC_OFFLOAD_PROFILE"
} > "$RUN_DIR/effective.env"

p7_capture_net_snapshot server "$RUN_DIR" before
p7_start_recorders server "$RUN_DIR"

FIFO="$RUN_DIR/server.stdout.fifo"
rm -f "$FIFO"; mkfifo "$FIFO"
python3 "$P7_P5_DIR/timestamp_tee_p5.py" --raw-log "$RUN_DIR/server.log" --timeline "$RUN_DIR/server_timeline.jsonl" < "$FIFO" &
TEE_PID=$!
APP_PID=""

cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    if [[ -n "${APP_PID:-}" ]] && kill -0 "$APP_PID" 2>/dev/null; then
        kill -INT -- "-$APP_PID" 2>/dev/null || kill -INT "$APP_PID" 2>/dev/null || true
    fi
    [[ -n "${APP_PID:-}" ]] && wait "$APP_PID" 2>/dev/null || true
    [[ -n "${TEE_PID:-}" ]] && wait "$TEE_PID" 2>/dev/null || true
    p7_stop_recorders
    p7_capture_net_snapshot server "$RUN_DIR" after
    rm -f "$FIFO"
    if [[ -f "$RUN_DIR/server.log" ]]; then
        python3 "$HERE/report_p7_run.py" --role server --run-dir "$RUN_DIR" --payload-bytes "$PAYLOAD_BYTES" --downloads "$DOWNLOADS_PER_RUN" --output "$RUN_DIR/summary.json" || rc=$?
    fi
    touch "$RUN_DIR/server_finished"
    exit "$rc"
}
trap cleanup EXIT INT TERM

export GREENQUIC_CONFIG="$cfg"

if [[ "$(p7_bool "$P7_PIN_QUIC")" == 1 ]]; then
    setsid taskset -c "$P7_QUIC_CPUS" stdbuf -oL -eL "$P7_SERVER_BIN" "-listen:*" "-port:$P7_PORT" "-root:$P7_SERVER_ROOT" "-file:$P7_CERT" "-key:$P7_KEY" -exitonsig > "$FIFO" 2>&1 &
else
    setsid stdbuf -oL -eL "$P7_SERVER_BIN" "-listen:*" "-port:$P7_PORT" "-root:$P7_SERVER_ROOT" "-file:$P7_CERT" "-key:$P7_KEY" -exitonsig > "$FIFO" 2>&1 &
fi
APP_PID=$!
printf '%s\n' "$APP_PID" > "$RUN_DIR/server_app.pid"
p7_log "server rep=$REP pid=$APP_PID run=$RUN_DIR"
wait "$APP_PID"
