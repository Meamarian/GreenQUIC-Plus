#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/p7_common.sh"

RUNS="$MATRIX_REPETITIONS"
CLIENT_HOST="tinyman"
CLIENT_DIR="$HERE"
OUTPUT_DIR=""

usage(){ cat <<'EOF'
P7 Linux UDP baseline matrix (run on IDEX)

Options:
  --downloads N                   sequential downloads per connection (default config.env)
  --gap-seconds S                 gap between downloads (default 5)
  --runs N                        independent repetitions (default 5)
  --pre-cooldown-seconds S        connected pre-D1 idle window (default 5)
  --post-cooldown-seconds S       post-last-download recording window (default 5)
  --between-runs-seconds S        cooldown between repetitions (default 5)
  --dataplane-cpu CPU             Linux IRQ/NAPI target, analogous to P5 DPDK CPU (default 19)
  --quic-cpus LIST                MsQuic worker/process CPU list (default 21,22,23,24)
  --pin-irq 0|1                   pin E810 MSI IRQs to dataplane CPU (default 1)
  --pin-quic 0|1                  taskset + MsQuic ProcessorList (default 1)
  --disable-rps 0|1               disable RPS on test NIC during run (default 1)
  --nic-offloads native|on|off    NIC/kernel offload profile (default on: goodput-oriented)
  --record-quic-cpus 0|1          additionally trace QUIC CPU frequency/C-states (default 0)
  --enable-record 0|1             enable RAPL/frequency/C-state recording (default 1)
  --rapl-interval-ms MS           package+DRAM RAPL cadence (default 6)
  --freq-interval-ms MS           CPU-frequency cadence (default 1)
  --require-rapl 0|1              fail if package RAPL cannot start (default 1)
  --stop-irqbalance 0|1           stop irqbalance while IRQ pinning is active (default 1)
  --mtu N                         Linux test-interface MTU (default 1500)
  --restore-dpdk 0|1              restore vfio-pci after matrix (default 1)
  --client-host HOST              default tinyman
  --client-dir PATH               P7 path on client
  --output-dir PATH               result directory on IDEX

Default goodput/high-performance profile:
  max_throughput MsQuic + IRQ CPU19 + QUIC CPUs21-24 + IRQ/QUIC pinning +
  RPS disabled + irqbalance stopped + NIC offloads requested ON.
EOF
}

while (($#)); do
    case "$1" in
        --downloads) DOWNLOADS_PER_RUN="$2"; shift 2 ;;
        --gap-seconds) GAP_US="$(python3 -c 'import sys; print(int(round(float(sys.argv[1])*1e6)))' "$2")"; shift 2 ;;
        --runs) RUNS="$2"; shift 2 ;;
        --pre-cooldown-seconds) P7_PRE_COOLDOWN_SECONDS="$2"; shift 2 ;;
        --post-cooldown-seconds) P7_POST_COOLDOWN_SECONDS="$2"; shift 2 ;;
        --between-runs-seconds) P7_BETWEEN_RUNS_SECONDS="$2"; shift 2 ;;
        --dataplane-cpu) P7_DATAPLANE_CPU="$2"; P7_RECORD_CPUS="$2"; shift 2 ;;
        --quic-cpus) P7_QUIC_CPUS="$2"; shift 2 ;;
        --pin-irq) P7_PIN_IRQ="$2"; shift 2 ;;
        --pin-quic) P7_PIN_QUIC="$2"; shift 2 ;;
        --disable-rps) P7_DISABLE_RPS="$2"; shift 2 ;;
        --nic-offloads) P7_NIC_OFFLOAD_PROFILE="$2"; shift 2 ;;
        --record-quic-cpus) P7_RECORD_QUIC_CPUS="$2"; shift 2 ;;
        --enable-record) ENABLE_RECORD="$2"; shift 2 ;;
        --rapl-interval-ms) P7_RAPL_INTERVAL_MS="$2"; shift 2 ;;
        --freq-interval-ms) P7_FREQ_INTERVAL_MS="$2"; shift 2 ;;
        --require-rapl) P7_REQUIRE_RAPL="$2"; shift 2 ;;
        --stop-irqbalance) P7_STOP_IRQBALANCE="$2"; shift 2 ;;
        --mtu) P7_MTU="$2"; shift 2 ;;
        --restore-dpdk) P7_RESTORE_DPDK_AFTER_RUN="$2"; shift 2 ;;
        --client-host) CLIENT_HOST="$2"; shift 2 ;;
        --client-dir) CLIENT_DIR="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) p7_die "unknown matrix option: $1" ;;
    esac
done

[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || p7_die "--runs must be a positive integer"
[[ "$DOWNLOADS_PER_RUN" =~ ^[1-9][0-9]*$ ]] || p7_die "--downloads must be positive"
p7_bool "$P7_PIN_IRQ" >/dev/null || p7_die "--pin-irq must be 0|1"
p7_bool "$P7_PIN_QUIC" >/dev/null || p7_die "--pin-quic must be 0|1"
p7_bool "$P7_DISABLE_RPS" >/dev/null || p7_die "--disable-rps must be 0|1"
p7_bool "$P7_RECORD_QUIC_CPUS" >/dev/null || p7_die "--record-quic-cpus must be 0|1"
p7_bool "$ENABLE_RECORD" >/dev/null || p7_die "--enable-record must be 0|1"
p7_bool "$P7_REQUIRE_RAPL" >/dev/null || p7_die "--require-rapl must be 0|1"
p7_bool "$P7_STOP_IRQBALANCE" >/dev/null || p7_die "--stop-irqbalance must be 0|1"
p7_bool "$P7_RESTORE_DPDK_AFTER_RUN" >/dev/null || p7_die "--restore-dpdk must be 0|1"
[[ "$P7_MTU" =~ ^[1-9][0-9]*$ ]] || p7_die "--mtu must be positive"
python3 -c 'import sys; assert float(sys.argv[1]) > 0' "$P7_RAPL_INTERVAL_MS" || p7_die "--rapl-interval-ms must be >0"
python3 -c 'import sys; assert float(sys.argv[1]) > 0' "$P7_FREQ_INTERVAL_MS" || p7_die "--freq-interval-ms must be >0"
case "$P7_NIC_OFFLOAD_PROFILE" in native|on|off) ;; *) p7_die "bad --nic-offloads" ;; esac

stamp="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${OUTPUT_DIR:-$HERE/matrix_results/P7_linux_${stamp}}"
mkdir -p "$OUTPUT_DIR/runs/server" "$OUTPUT_DIR/runs/client" "$OUTPUT_DIR/setup"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
MATRIX_ID="$(basename "$OUTPUT_DIR")"
REMOTE_ROOT="$CLIENT_DIR/matrix_remote/$MATRIX_ID"
LOCAL_STATE="$OUTPUT_DIR/setup/server_state"
REMOTE_STATE="$REMOTE_ROOT/client_state"

P7_ENV=(
    "DOWNLOADS_PER_RUN=$DOWNLOADS_PER_RUN"
    "GAP_US=$GAP_US"
    "PAYLOAD_BYTES=$PAYLOAD_BYTES"
    "P7_PRE_COOLDOWN_SECONDS=$P7_PRE_COOLDOWN_SECONDS"
    "P7_POST_COOLDOWN_SECONDS=$P7_POST_COOLDOWN_SECONDS"
    "P7_BETWEEN_RUNS_SECONDS=$P7_BETWEEN_RUNS_SECONDS"
    "P7_DATAPLANE_CPU=$P7_DATAPLANE_CPU"
    "P7_RECORD_CPUS=$P7_RECORD_CPUS"
    "P7_QUIC_CPUS=$P7_QUIC_CPUS"
    "P7_PIN_IRQ=$P7_PIN_IRQ"
    "P7_PIN_QUIC=$P7_PIN_QUIC"
    "P7_DISABLE_RPS=$P7_DISABLE_RPS"
    "P7_NIC_OFFLOAD_PROFILE=$P7_NIC_OFFLOAD_PROFILE"
    "P7_RECORD_QUIC_CPUS=$P7_RECORD_QUIC_CPUS"
    "P7_RAPL_INTERVAL_MS=$P7_RAPL_INTERVAL_MS"
    "P7_RAPL_SMOOTH_SAMPLES=$P7_RAPL_SMOOTH_SAMPLES"
    "P7_FREQ_INTERVAL_MS=$P7_FREQ_INTERVAL_MS"
    "P7_REQUIRE_RAPL=$P7_REQUIRE_RAPL"
    "P7_STOP_IRQBALANCE=$P7_STOP_IRQBALANCE"
    "P7_MTU=$P7_MTU"
    "P7_RESTORE_DPDK_AFTER_RUN=$P7_RESTORE_DPDK_AFTER_RUN"
    "ENABLE_RECORD=$ENABLE_RECORD"
)

remote(){ ssh -o BatchMode=yes -o ConnectTimeout=20 root@"$CLIENT_HOST" "$@"; }
remote_env(){
    local q=() x
    for x in "${P7_ENV[@]}"; do printf -v x '%q' "$x"; q+=("$x"); done
    remote "env ${q[*]} $*"
}

server_pid=""
client_ssh_pid=""
cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    if [[ -n "${client_ssh_pid:-}" ]] && kill -0 "$client_ssh_pid" 2>/dev/null; then kill -TERM "$client_ssh_pid" 2>/dev/null || true; fi
    if [[ -n "${server_pid:-}" ]] && kill -0 "$server_pid" 2>/dev/null; then kill -TERM "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
    env "${P7_ENV[@]}" bash -c 'source "$1/p7_common.sh"; p7_restore_host server "$2"' _ "$HERE" "$LOCAL_STATE" 2>/dev/null || true
    remote_env "bash -c 'source \"$CLIENT_DIR/p7_common.sh\"; p7_restore_host client \"$REMOTE_STATE\"'" 2>/dev/null || true
    exit "$rc"
}
trap cleanup EXIT INT TERM

env "${P7_ENV[@]}" bash -c 'source "$1/p7_common.sh"; p7_validate_common; p7_check_host_role server' _ "$HERE"
remote_env "bash -c 'source \"$CLIENT_DIR/p7_common.sh\"; p7_validate_common; p7_check_host_role client'"

env "${P7_ENV[@]}" bash -c 'source "$1/p7_common.sh"; p7_prepare_host server "$2"' _ "$HERE" "$LOCAL_STATE"
remote_env "mkdir -p '$REMOTE_STATE'; bash -c 'source \"$CLIENT_DIR/p7_common.sh\"; p7_prepare_host client \"$REMOTE_STATE\"'"

for _ in $(seq 1 50); do
    if ping -c 1 -W 1 "$P7_CLIENT_IP" >/dev/null 2>&1; then break; fi
    sleep 0.2
done
ping -c 2 -W 2 "$P7_CLIENT_IP" >/dev/null || p7_die "IDEX cannot reach Tinyman at $P7_CLIENT_IP over the Linux test NIC"

cat > "$OUTPUT_DIR/matrix_config.env" <<EOF
schema=greenquic-p7-linux-matrix-v1
runs=$RUNS
downloads=$DOWNLOADS_PER_RUN
gap_us=$GAP_US
payload_bytes=$PAYLOAD_BYTES
pre_cooldown_s=$P7_PRE_COOLDOWN_SECONDS
post_cooldown_s=$P7_POST_COOLDOWN_SECONDS
between_runs_s=$P7_BETWEEN_RUNS_SECONDS
dataplane_cpu=$P7_DATAPLANE_CPU
quic_cpus=$P7_QUIC_CPUS
pin_irq=$P7_PIN_IRQ
pin_quic=$P7_PIN_QUIC
disable_rps=$P7_DISABLE_RPS
nic_offloads=$P7_NIC_OFFLOAD_PROFILE
record_quic_cpus=$P7_RECORD_QUIC_CPUS
enable_record=$ENABLE_RECORD
rapl_interval_ms=$P7_RAPL_INTERVAL_MS
freq_interval_ms=$P7_FREQ_INTERVAL_MS
require_rapl=$P7_REQUIRE_RAPL
stop_irqbalance=$P7_STOP_IRQBALANCE
mtu=$P7_MTU
EOF

for rep in $(seq 1 "$RUNS"); do
    rep2="$(printf '%02d' "$rep")"
    srun="$OUTPUT_DIR/runs/server/rep$rep2"
    crun_remote="$REMOTE_ROOT/runs/client/rep$rep2"
    crun_local="$OUTPUT_DIR/runs/client/rep$rep2"
    gate="/tmp/p7_${MATRIX_ID}_rep${rep2}.gate"
    mkdir -p "$srun"
    remote "rm -rf '$crun_remote'; mkdir -p '$crun_remote'; rm -f '$gate'"

    p7_log "REP $rep/$RUNS: starting Linux MsQuic server"
    env "${P7_ENV[@]}" "$HERE/run_server.sh" --run-dir "$srun" --rep "$rep" > "$srun/controller.log" 2>&1 &
    server_pid=$!
    for _ in $(seq 1 300); do
        [[ -f "$srun/server.log" ]] && grep -Eq 'Waiting forever\.|Waiting for SIGINT' "$srun/server.log" && break
        kill -0 "$server_pid" 2>/dev/null || { cat "$srun/controller.log" >&2; p7_die "server exited before readiness"; }
        sleep 0.1
    done
    [[ -f "$srun/server.log" ]] && grep -Eq 'Waiting forever\.|Waiting for SIGINT' "$srun/server.log" || p7_die "server readiness marker not observed"

    p7_log "REP $rep/$RUNS: starting connected client and waiting at P5 start gate"
    remote_env "'$CLIENT_DIR/run_client.sh' --run-dir '$crun_remote' --rep '$rep' --gate '$gate'" > "$OUTPUT_DIR/runs/client_rep${rep2}_controller.log" 2>&1 &
    client_ssh_pid=$!
    for _ in $(seq 1 600); do
        if remote "test -f '$crun_remote/client.log' && grep -qF 'ready_for_start_gate_us=' '$crun_remote/client.log'"; then break; fi
        kill -0 "$client_ssh_pid" 2>/dev/null || { cat "$OUTPUT_DIR/runs/client_rep${rep2}_controller.log" >&2; p7_die "client exited before start gate"; }
        sleep 0.1
    done
    remote "grep -qF 'ready_for_start_gate_us=' '$crun_remote/client.log'" || p7_die "client gate readiness marker missing"

    python3 "$HERE/p7_mark.py" --output "$srun/control_timeline.jsonl" --event pre_cool_start --role server --run-id "rep$rep"
    remote "python3 '$CLIENT_DIR/p7_mark.py' --output '$crun_remote/control_timeline.jsonl' --event pre_cool_start --role client --run-id 'rep$rep'"
    sleep "$P7_PRE_COOLDOWN_SECONDS"
    python3 "$HERE/p7_mark.py" --output "$srun/control_timeline.jsonl" --event pre_cool_end --role server --run-id "rep$rep"
    remote "python3 '$CLIENT_DIR/p7_mark.py' --output '$crun_remote/control_timeline.jsonl' --event pre_cool_end --role client --run-id 'rep$rep'; touch '$gate'"

    for _ in $(seq 1 1800); do
        grep -qE "\[GreenQUIC-P7\] request=${DOWNLOADS_PER_RUN} complete_us=.* success=1" "$srun/server.log" 2>/dev/null && break
        kill -0 "$server_pid" 2>/dev/null || p7_die "server died during transfer"
        kill -0 "$client_ssh_pid" 2>/dev/null || { cat "$OUTPUT_DIR/runs/client_rep${rep2}_controller.log" >&2; p7_die "client died during transfer"; }
        sleep 0.1
    done
    grep -qE "\[GreenQUIC-P7\] request=${DOWNLOADS_PER_RUN} complete_us=.* success=1" "$srun/server.log" || p7_die "final server request completion marker missing"
    python3 "$HERE/p7_mark.py" --output "$srun/control_timeline.jsonl" --event post_cool_start --role server --run-id "rep$rep"
    sleep "$P7_POST_COOLDOWN_SECONDS"
    python3 "$HERE/p7_mark.py" --output "$srun/control_timeline.jsonl" --event post_cool_end --role server --run-id "rep$rep"

    kill -TERM "$server_pid" 2>/dev/null || true
    wait "$server_pid" || { rc=$?; [[ "$rc" == 130 || "$rc" == 143 ]] || p7_die "server wrapper failed rc=$rc"; }
    server_pid=""
    wait "$client_ssh_pid" || { rc=$?; cat "$OUTPUT_DIR/runs/client_rep${rep2}_controller.log" >&2; p7_die "client wrapper failed rc=$rc"; }
    client_ssh_pid=""

    rm -rf "$crun_local"; mkdir -p "$crun_local"
    remote "tar -C '$crun_remote' -cf - ." | tar -C "$crun_local" -xf -
    [[ -f "$srun/summary.json" && -f "$crun_local/summary.json" ]] || p7_die "rep $rep summary missing"
    p7_log "REP $rep/$RUNS PASS"
    if (( rep < RUNS )); then sleep "$P7_BETWEEN_RUNS_SECONDS"; fi
done

python3 "$HERE/aggregate_p7_matrix.py" --matrix-dir "$OUTPUT_DIR" --runs "$RUNS"

env "${P7_ENV[@]}" bash -c 'source "$1/p7_common.sh"; p7_restore_host server "$2"' _ "$HERE" "$LOCAL_STATE"
remote_env "bash -c 'source \"$CLIENT_DIR/p7_common.sh\"; p7_restore_host client \"$REMOTE_STATE\"'"
trap - EXIT INT TERM

printf '\nP7 LINUX MATRIX PASS\nRESULTS: %s\n' "$OUTPUT_DIR"
