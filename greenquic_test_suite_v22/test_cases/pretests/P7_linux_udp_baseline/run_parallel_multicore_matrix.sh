#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
BASE="$HERE/run_matrix_from_idex.sh";IRQ_HELPER="$HERE/p7_multicore_irq.py";VALIDATOR="$HERE/validate_p7_multicore_matrix.py";IRQ_ACTIVITY="$HERE/validate_p7_parallel_irq_activity.py";REPORTER="$HERE/build_p7_report_multicore.py";AGG="$HERE/aggregate_p7_parallel_goodput.py";ACTIVE="$HERE/aggregate_p7_parallel_active.py";CLOCK_SYNC="$HERE/../P5_repeated_8GiB_downloads/clock_sync.py"
RUNS=2;CONNECTIONS=4;OUTPUT_DIR="";CONTROLLER_PREFLIGHT=0;USER_ARGS=()
while (($#));do case "$1" in --runs) RUNS="${2:?}";shift 2;;--connections) CONNECTIONS="${2:?}";shift 2;;--output-dir) OUTPUT_DIR="${2:?}";shift 2;;--controller-preflight) CONTROLLER_PREFLIGHT=1;shift;;-h|--help) echo "usage: $0 [--runs N] [--connections N] [--output-dir DIR] [--controller-preflight]";exit 0;;*) USER_ARGS+=("$1");shift;;esac;done
[[ "$RUNS" =~ ^[1-9][0-9]*$ && "$CONNECTIONS" =~ ^[2-9][0-9]*$ ]] || { echo "ERROR: invalid runs/connections" >&2;exit 2; }
for f in "$BASE" "$IRQ_HELPER" "$VALIDATOR" "$IRQ_ACTIVITY" "$REPORTER" "$AGG" "$ACTIVE" "$CLOCK_SYNC" "$HERE/run_server_parallel_multicore.sh" "$HERE/run_client_parallel_multicore.sh";do [[ -f "$f" ]]||{ echo "ERROR: missing $f" >&2;exit 2;};done
OUTPUT_DIR="${OUTPUT_DIR:-$HERE/matrix_results/P7_PARALLEL_MC_${CONNECTIONS}c_${RUNS}r_$(date +%Y%m%d_%H%M%S)}"
ROOT="$HERE/../../../common/files/server_root";mkdir -p "$ROOT";for ((i=1;i<=CONNECTIONS;i++));do f="$ROOT/file_8G_mc$(printf '%02d' "$i").bin";[[ -e "$f" ]]||truncate -s 8589934592 "$f";[[ "$(stat -Lc '%s' "$f")" == 8589934592 ]]||{ echo "ERROR: bad payload $f" >&2;exit 2;};done
TMP="$(mktemp "$HERE/.run_parallel_multicore.XXXXXX.sh")";trap 'rm -f "$TMP"' EXIT
python3 - "$BASE" "$TMP" <<'PY'
from pathlib import Path
import sys
src=Path(sys.argv[1]).read_text(encoding='utf-8')
def one(old,new,label):
 global src
 n=src.count(old)
 if n!=1:raise SystemExit(f'ERROR: {label}: expected one anchor, found {n}')
 src=src.replace(old,new,1)
one('"$HERE/run_server.sh" --run-dir "$srun" --rep "$rep"','bash "$HERE/run_server_parallel_multicore.sh" --run-dir "$srun" --rep "$rep"','server wrapper')
one("'$CLIENT_DIR/run_client.sh' --run-dir '$crun_remote' --rep '$rep' --gate '$gate'","bash '$CLIENT_DIR/run_client_parallel_multicore.sh' --run-dir '$crun_remote' --rep '$rep' --gate '$gate'",'client wrapper')
# Map Tinyman CLOCK_MONOTONIC to IDEX immediately before the measured connected
# pre-cooldown. The active analyzer uses the client batch start/end on BOTH
# endpoints, translated with this offset, exactly like P5.
old=r'''    remote "grep -qF 'ready_for_start_gate_us=' '$crun_remote/client.log'" || p7_die "client gate readiness marker missing"

    p7_log "REP $rep/$RUNS: PRE-COOLDOWN start (${P7_PRE_COOLDOWN_SECONDS}s), connection established and no GET released"
'''
new=r'''    remote "grep -qF 'ready_for_start_gate_us=' '$crun_remote/client.log'" || p7_die "client gate readiness marker missing"

    # GREENQUIC-P7-PARALLEL-CLOCK-SYNC-V1
    python3 "$HERE/../P5_repeated_8GiB_downloads/clock_sync.py" --host "$CLIENT_HOST" --out "$OUTPUT_DIR/clock_sync_rep${rep2}.json" --samples 25 --no-post-sync

    p7_log "REP $rep/$RUNS: PRE-COOLDOWN start (${P7_PRE_COOLDOWN_SECONDS}s), connection established and no GET released"
'''
one(old,new,'parallel clock sync')
old=r'''env "${P7_ENV[@]}" bash -c 'source "$1/p7_common.sh"; iface="$(cat "$2/iface")"; p7_pin_irqs "$iface" "$P7_DATAPLANE_CPU"; p7_disable_rps "$iface"' _ "$HERE" "$LOCAL_STATE"
remote_env "bash -c 'source \"$CLIENT_DIR/p7_common.sh\"; iface=\"\$(cat \"$REMOTE_STATE/iface\")\"; p7_pin_irqs \"\$iface\" \"\$P7_DATAPLANE_CPU\"; p7_disable_rps \"\$iface\"'"
'''
new=old+r'''
# GREENQUIC-P7-PARALLEL-MULTICORE-IRQ-V1
local_multicore_iface="$(cat "$LOCAL_STATE/iface")"
python3 "$HERE/p7_multicore_irq.py" --iface "$local_multicore_iface" --cpus "$P7_DATAPLANE_CPU" --state-dir "$LOCAL_STATE" --expected-queues 2
remote "python3 '$CLIENT_DIR/p7_multicore_irq.py' --iface \"\$(cat '$REMOTE_STATE/iface')\" --cpus '$P7_DATAPLANE_CPU' --state-dir '$REMOTE_STATE' --expected-queues 2"
cp "$LOCAL_STATE/multicore_irq_map.json" "$OUTPUT_DIR/setup/server_multicore_irq_map.json"
remote "cat '$REMOTE_STATE/multicore_irq_map.json'" > "$OUTPUT_DIR/setup/client_multicore_irq_map.json"
python3 - "$OUTPUT_DIR/setup/server_multicore_irq_map.json" "$OUTPUT_DIR/setup/client_multicore_irq_map.json" <<'PYIRQ'
import json,sys
for p in sys.argv[1:]:
 d=json.load(open(p));m=sorted(d.get('mappings',[]),key=lambda x:int(x.get('queue_order',999999)))[:2];used={int(x['cpu']) for x in m}
 if len(m)!=2 or used!={19,20}:raise SystemExit(f'ERROR: {p} first-two queue IRQ CPUs={sorted(used)} count={len(m)}')
print('P7 parallel local+remote queue IRQ maps verified: exactly two data queues on CPUs 19,20')
PYIRQ
'''
one(old,new,'IRQ/RPS post-channel')
old=r'''    for _ in $(seq 1 1800); do
        grep -qE "\[GreenQUIC-P7\] request=${DOWNLOADS_PER_RUN} complete_us=.* success=1" "$srun/server.log" 2>/dev/null && break
        kill -0 "$server_pid" 2>/dev/null || p7_die "server died during transfer"
        kill -0 "$client_ssh_pid" 2>/dev/null || { cat "$OUTPUT_DIR/runs/client_rep${rep2}_controller.log" >&2; p7_die "client died during transfer"; }
        sleep 0.1
    done
    grep -qE "\[GreenQUIC-P7\] request=${DOWNLOADS_PER_RUN} complete_us=.* success=1" "$srun/server.log" || p7_die "final server request completion marker missing"
'''
new=r'''    for _ in $(seq 1 1800); do
        completed_server="$(grep -cE '\[GreenQUIC-P7\] request=[0-9]+ complete_us=.* success=1' "$srun/server.log" 2>/dev/null || true)"
        [[ "$completed_server" -ge "$DOWNLOADS_PER_RUN" ]] && break
        kill -0 "$server_pid" 2>/dev/null || p7_die "server died during parallel transfer"
        kill -0 "$client_ssh_pid" 2>/dev/null || { cat "$OUTPUT_DIR/runs/client_rep${rep2}_controller.log" >&2; p7_die "client died during parallel transfer"; }
        sleep 0.1
    done
    completed_server="$(grep -cE '\[GreenQUIC-P7\] request=[0-9]+ complete_us=.* success=1' "$srun/server.log" 2>/dev/null || true)"
    [[ "$completed_server" == "$DOWNLOADS_PER_RUN" ]] || p7_die "expected $DOWNLOADS_PER_RUN server completions, observed $completed_server"
'''
one(old,new,'parallel server completion');Path(sys.argv[2]).write_text(src,encoding='utf-8')
PY
chmod 0700 "$TMP";bash -n "$TMP"
grep -Fq 'bash "$HERE/run_server_parallel_multicore.sh" --run-dir "$srun" --rep "$rep"' "$TMP" || { echo "ERROR: generated P7 controller does not invoke server multicore wrapper via bash" >&2;exit 2; };grep -Fq "bash '\$CLIENT_DIR/run_client_parallel_multicore.sh' --run-dir '\$crun_remote' --rep '\$rep' --gate '\$gate'" "$TMP" || { echo "ERROR: generated P7 controller does not invoke client multicore wrapper via bash" >&2;exit 2; };grep -Fq 'GREENQUIC-P7-PARALLEL-CLOCK-SYNC-V1' "$TMP" || { echo "ERROR: generated P7 controller lacks clock-sync transform" >&2;exit 2; }
bash "$TMP" --help >/dev/null;printf 'P7 PARALLEL TRANSFORMED CONTROLLER PREFLIGHT PASS (no traffic/NIC changes)\n';if [[ "$CONTROLLER_PREFLIGHT" == 1 ]];then exit 0;fi
FIXED=(--downloads "$CONNECTIONS" --gap-seconds 0 --runs "$RUNS" --pre-cooldown-seconds 5 --post-cooldown-seconds 5 --between-runs-seconds 5 --dataplane-cpu 19,20 --quic-cpus 21,22,23,24 --pin-irq 1 --pin-quic 1 --disable-rps 1 --disable-rdma 1 --combined-channels 2 --stop-irqbalance 1 --nic-offloads paper --udp-rmem 6815744 --udp-wmem 6815744 --network-diagnostics 1 --record-quic-cpus 0 --enable-record 1 --rapl-interval-ms 6 --freq-interval-ms 1 --require-rapl 1 --mtu 1500 --restore-dpdk 1 --output-dir "$OUTPUT_DIR")
export P7_PARALLEL_LOCAL_PORT_BASE=45000
echo "======================================================================";echo "P7 FAIR LINUX PARALLEL MULTICORE MATRIX";echo "runs=$RUNS connections=$CONNECTIONS payload=8GiB/connection local_ports=45000..$((44999+CONNECTIONS))";echo "Linux queues=2 IRQ->19,20 QUIC=21-24 RPS=off irqbalance=off";echo "TUM network profile: GSO/GRO + rmem/wmem=6815744";echo "active metrics: client parallel batch interval mapped to both hosts; RAPL boundary-prorated; frequency time-weighted";echo "======================================================================"
bash "$TMP" "${USER_ARGS[@]}" "${FIXED[@]}";python3 "$AGG" --matrix "$OUTPUT_DIR" --runs "$RUNS" --connections "$CONNECTIONS";python3 "$ACTIVE" --matrix "$OUTPUT_DIR" --runs "$RUNS" --connections "$CONNECTIONS";python3 "$VALIDATOR" --matrix "$OUTPUT_DIR" --runs "$RUNS";python3 "$IRQ_ACTIVITY" --matrix "$OUTPUT_DIR" --runs "$RUNS";rm -rf "$OUTPUT_DIR/the_sheet_rules_all";python3 "$REPORTER" --matrix-dir "$OUTPUT_DIR" --output "$OUTPUT_DIR/the_sheet_rules_all";python3 "$VALIDATOR" --matrix "$OUTPUT_DIR" --runs "$RUNS" --report-dir "$OUTPUT_DIR/the_sheet_rules_all"
cat > "$OUTPUT_DIR/PARALLEL_MULTICORE_CONFIG.txt" <<EOF
branch=performance2/p5-multicore
workload=one_process_multiple_simultaneous_quic_connections
runs=$RUNS
connections=$CONNECTIONS
payload_bytes_per_connection=8589934592
local_udp_port_base=45000
linux_combined_channels=2
linux_dataplane_cpus=19,20
quic_cpus=21,22,23,24
pin_irq=1
disable_rps=1
stop_irqbalance=1
disable_rdma=1
nic_offloads=paper
udp_rmem_bytes=6815744
udp_wmem_bytes=6815744
active_window=client_parallel_batch_start_to_complete_mapped_to_server_clock
active_rapl=sample_overlap_prorated
active_frequency=midpoint_cell_time_weighted_cpu19_cpu20
EOF
echo "P7 FAIR PARALLEL MULTICORE MATRIX PASS";echo "RESULTS: $OUTPUT_DIR";echo "GOODPUT+VARIANCE: $OUTPUT_DIR/parallel_tables/parallel_goodput_summary.csv";echo "ACTIVE ENERGY+FREQUENCY: $OUTPUT_DIR/parallel_tables/parallel_active_metrics.csv";echo "ACTIVE SUMMARY+VARIANCE: $OUTPUT_DIR/parallel_tables/parallel_active_summary.csv"
