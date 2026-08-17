#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
BASE="$HERE/run_matrix_from_idex.sh"
CLIENT="$HERE/run_client_parallel_multicore.sh"
AGG="$HERE/aggregate_parallel_goodput.py"
ACTIVE="$HERE/analyze_p5_parallel_active.py"
CLOCK="$HERE/clock_sync_parallel.py"
VALIDATOR="$HERE/validate_p5_multicore_matrix.py"
CPU_ACTIVITY="$HERE/quic_cpu_activity_sampler.py"
PERCORE="$HERE/write_per_core_goodput_summary.py"
RUNS=2;CONNECTIONS=4;OUTPUT_DIR="";CONTROLLER_PREFLIGHT=0;USER_ARGS=()
while (($#)); do
    case "$1" in
        --runs) RUNS="${2:?}";shift 2;;
        --connections) CONNECTIONS="${2:?}";shift 2;;
        --output-dir) OUTPUT_DIR="${2:?}";shift 2;;
        --controller-preflight) CONTROLLER_PREFLIGHT=1;shift;;
        -h|--help) echo "usage: $0 [--runs N] [--connections N] [--output-dir DIR] [--controller-preflight] [normal P5 matrix options]";exit 0;;
        *) USER_ARGS+=("$1");shift;;
    esac
done
[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: runs must be positive" >&2;exit 2; }
[[ "$CONNECTIONS" =~ ^[2-9][0-9]*$ ]] || { echo "ERROR: connections must be >=2" >&2;exit 2; }
for f in "$BASE" "$CLIENT" "$AGG" "$ACTIVE" "$CLOCK" "$VALIDATOR" "$CPU_ACTIVITY" "$PERCORE";do
    [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2;exit 2; }
done
python3 "$CLOCK" --self-test >/dev/null
python3 "$CPU_ACTIVITY" --self-test >/dev/null
python3 -m py_compile "$CPU_ACTIVITY" "$PERCORE"

OUTPUT_DIR="${OUTPUT_DIR:-$HERE/matrix_results/P5_PARALLEL_MC_${CONNECTIONS}c_${RUNS}r_$(date +%Y%m%d_%H%M%S)}"
ROOT="$HERE/../../../common/files/server_root"
mkdir -p "$ROOT"
for ((i=1;i<=CONNECTIONS;i++));do
    f="$ROOT/file_8G_mc$(printf '%02d' "$i").bin"
    [[ -e "$f" ]] || truncate -s 8589934592 "$f"
    [[ "$(stat -Lc '%s' "$f")" == 8589934592 ]] || { echo "ERROR: wrong sparse payload size $f" >&2;exit 2; }
done

TMP="$(mktemp "$HERE/.parallel_matrix.XXXXXX.sh")"
SERVER_ACTIVITY_PID=""
CLIENT_ACTIVITY_PID=""
REMOTE_ACTIVITY_JSON=""
REMOTE_ACTIVITY_CSV=""
REMOTE_ACTIVITY_LOG=""
cleanup(){
    local rc=$?
    trap - EXIT INT TERM
    [[ -z "${SERVER_ACTIVITY_PID:-}" ]] || { kill -TERM "$SERVER_ACTIVITY_PID" 2>/dev/null || true; wait "$SERVER_ACTIVITY_PID" 2>/dev/null || true; }
    if [[ -n "${CLIENT_ACTIVITY_PID:-}" ]]; then
        ssh -o BatchMode=yes -o ConnectTimeout=10 root@tinyman "kill -TERM '$CLIENT_ACTIVITY_PID' 2>/dev/null || true" >/dev/null 2>&1 || true
    fi
    rm -f "$TMP"
    exit "$rc"
}
trap cleanup EXIT INT TERM

python3 - "$BASE" "$TMP" <<'PY'
from pathlib import Path
import sys
src=Path(sys.argv[1]).read_text(encoding='utf-8');old='./run_client.sh';new='bash ./run_client_parallel_multicore.sh';count=src.count(old)
if count<1:raise SystemExit(f'ERROR: base P5 runner contains no {old} anchor')
src=src.replace(old,new)
clock_old='python3 "$HERE/clock_sync.py"'
clock_new='python3 "$HERE/clock_sync_parallel.py"'
clock_count=src.count(clock_old)
if clock_count!=1:raise SystemExit(f'ERROR: public P5 wrapper clock-sync anchor count={clock_count}, expected 1')
src=src.replace(clock_old,clock_new,1)
needle='Path(sys.argv[2]).write_text(src, encoding="utf-8")'
if src.count(needle)!=1:raise SystemExit(f'ERROR: public P5 wrapper write anchor count={src.count(needle)}, expected 1')
completion_old='''    final_download_pattern="[GreenQUIC-P5] request=${DOWNLOADS}/${DOWNLOADS} complete_us="
    workload_complete=0
    while kill -0 "$client_pipeline_pid" 2>/dev/null; do
        if grep -F "$final_download_pattern" "$client_log" 2>/dev/null | tail -n1 | grep -Fq 'success=1'; then
            workload_complete=1
            break
        fi
        sleep 0.1
    done
'''
completion_new='''    final_download_pattern="[GreenQUIC-PARALLEL] batch=1 complete_us="
    workload_complete=0
    while kill -0 "$client_pipeline_pid" 2>/dev/null; do
        if grep -E "\\[GreenQUIC-PARALLEL\\] batch=1 complete_us=.* connections=${DOWNLOADS} connected=${DOWNLOADS} completed=${DOWNLOADS} success=1" "$client_log" 2>/dev/null | tail -n1 | grep -q .; then
            workload_complete=1
            break
        fi
        sleep 0.1
    done
'''
injection=("# P5-PARALLEL-COMPLETION-V1\n"+"parallel_old = "+repr(completion_old)+"\n"+"parallel_new = "+repr(completion_new)+"\n"+'replace_once(parallel_old, parallel_new, "parallel completion detector")\n'+needle)
src=src.replace(needle,injection,1);Path(sys.argv[2]).write_text(src,encoding='utf-8');print(f'P5 parallel controller patch: client anchors={count}; parallel completion detector + parallel clock sync injected')
PY
chmod 0700 "$TMP";bash -n "$TMP"
grep -Fq 'env $client_env_words bash ./run_client_parallel_multicore.sh' "$TMP" || { echo "ERROR: generated P5 controller does not invoke multicore client via bash" >&2;exit 2; }
grep -Fq 'P5-PARALLEL-COMPLETION-V1' "$TMP" || { echo "ERROR: generated P5 controller lacks parallel completion transform" >&2;exit 2; }
grep -Fq 'clock_sync_parallel.py' "$TMP" || { echo "ERROR: generated P5 controller lacks parallel-aware clock sync" >&2;exit 2; }
# Execute the outer wrapper only with --help. This forces its embedded transform
# to patch the real preserved core and fail on any stale anchor, but exits from
# the core option parser before SSH, NIC setup, DPDK, or traffic.
bash "$TMP" --help >/dev/null
printf 'P5 PARALLEL NESTED CONTROLLER PREFLIGHT PASS (no traffic/NIC changes)\n'
if [[ "$CONTROLLER_PREFLIGHT" == 1 ]];then exit 0;fi

export P5_PARALLEL_CONNECTIONS="$CONNECTIONS" P5_PARALLEL_LOCAL_PORT_BASE=45000
TOPOLOGY_ENV=(
    --env ENABLE_MULTICORE=1
    --env SERVER_DPDK_LCORES=19,20
    --env CLIENT_DPDK_LCORES=19,20
    --env SERVER_QUIC_CPUS=21,22,23,24
    --env CLIENT_QUIC_CPUS=21,22,23,24
    --env SERVER_PARTITION_MAP=0:19,1:19,2:20,3:20
    --env CLIENT_PARTITION_MAP=0:19,1:19,2:20,3:20
    --env SERVER_TX_OWNER_LCORE=19
    --env CLIENT_TX_OWNER_LCORE=19
    --env GREENQUIC_TX_OWNER_ALSO_RX=1
    --env P5_PARALLEL_CONNECTIONS="$CONNECTIONS"
    --env P5_PARALLEL_LOCAL_PORT_BASE=45000
    --env ENABLE_RECORD=1
    --env ENABLE_CSTATE_RECORD=1
    --env GQ_MSR_SAMPLE_INTERVAL_MS=6
    --env GQ_FREQ_SAMPLE_INTERVAL_MS=1
    --env MSQUIC_EXECUTION_PROFILE=max_throughput
)

mkdir -p "$OUTPUT_DIR"
P5_SERVER_BIN="/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinteropserver"
P5_CLIENT_BIN="/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop"
[[ -x "$P5_SERVER_BIN" ]] || { echo "ERROR: P5 server binary missing: $P5_SERVER_BIN" >&2;exit 2; }
ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman "test -x '$P5_CLIENT_BIN' && python3 '$CPU_ACTIVITY' --self-test >/dev/null" || {
    echo "ERROR: Tinyman P5 client/runtime CPU sampler preflight failed" >&2; exit 2;
}

ACTIVITY_TAG="p5_quic_cpu_activity_$(date +%Y%m%d_%H%M%S)_$$"
REMOTE_ACTIVITY_JSON="/tmp/${ACTIVITY_TAG}_client.json"
REMOTE_ACTIVITY_CSV="/tmp/${ACTIVITY_TAG}_client.csv"
REMOTE_ACTIVITY_LOG="/tmp/${ACTIVITY_TAG}_client.log"
python3 "$CPU_ACTIVITY" --binary "$P5_SERVER_BIN" --cpus 21,22,23,24 \
    --json "$OUTPUT_DIR/quic_cpu_activity_server.json" \
    --csv "$OUTPUT_DIR/quic_cpu_activity_server.csv" --interval-ms 5 \
    >"$OUTPUT_DIR/quic_cpu_activity_server_sampler.log" 2>&1 &
SERVER_ACTIVITY_PID=$!
CLIENT_ACTIVITY_PID="$(ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman \
    "rm -f '$REMOTE_ACTIVITY_JSON' '$REMOTE_ACTIVITY_CSV' '$REMOTE_ACTIVITY_LOG'; nohup python3 '$CPU_ACTIVITY' --binary '$P5_CLIENT_BIN' --cpus 21,22,23,24 --json '$REMOTE_ACTIVITY_JSON' --csv '$REMOTE_ACTIVITY_CSV' --interval-ms 5 >'$REMOTE_ACTIVITY_LOG' 2>&1 </dev/null & echo \$!")"
[[ "$CLIENT_ACTIVITY_PID" =~ ^[0-9]+$ ]] || { echo "ERROR: cannot start Tinyman QUIC CPU activity sampler: $CLIENT_ACTIVITY_PID" >&2;exit 2; }

echo "======================================================================"
echo "P5 PARALLEL MULTICORE AGGREGATE-GOODPUT MATRIX"
echo "modes=OFF,BASIC,PLUS runs=$RUNS connections=$CONNECTIONS payload=8GiB/connection"
echo "DPDK=19,20 QUIC=21-24 RXQ=2 TXQ=2 local_ports=45000..$((44999+CONNECTIONS))"
echo "recording: RAPL=6ms frequency=1ms C-state=19,20 profile=max_throughput"
echo "runtime proof: exact MsQuic process CPU activity required on QUIC CPUs 21,22,23,24 on both endpoints"
echo "active metrics: exact parallel batch start->complete; RAPL boundary-prorated; frequency time-weighted"
echo "======================================================================"

bash "$TMP" --runs "$RUNS" --downloads "$CONNECTIONS" --gap-seconds 0 --server-cooldown-seconds 5 --between-tests-seconds 5 --mode-order balanced --seed 20260817 --output-dir "$OUTPUT_DIR" "${TOPOLOGY_ENV[@]}" "${USER_ARGS[@]}"
[[ -d "$OUTPUT_DIR" ]] || { echo "ERROR: result directory missing: $OUTPUT_DIR" >&2;exit 1; }

# Stop runtime activity probes only after all P5 modes have completed.
kill -TERM "$SERVER_ACTIVITY_PID" 2>/dev/null || true
wait "$SERVER_ACTIVITY_PID" || true
SERVER_ACTIVITY_PID=""
ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman "kill -TERM '$CLIENT_ACTIVITY_PID' 2>/dev/null || true; for i in \$(seq 1 100); do kill -0 '$CLIENT_ACTIVITY_PID' 2>/dev/null || exit 0; sleep 0.1; done; exit 1" || {
    echo "ERROR: Tinyman QUIC CPU activity sampler did not stop cleanly" >&2;exit 2;
}
CLIENT_ACTIVITY_PID=""
scp -q -o BatchMode=yes -o ConnectTimeout=15 "root@tinyman:$REMOTE_ACTIVITY_JSON" "$OUTPUT_DIR/quic_cpu_activity_client.json"
scp -q -o BatchMode=yes -o ConnectTimeout=15 "root@tinyman:$REMOTE_ACTIVITY_CSV" "$OUTPUT_DIR/quic_cpu_activity_client.csv"
ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman "cat '$REMOTE_ACTIVITY_LOG'" > "$OUTPUT_DIR/quic_cpu_activity_client_sampler.log" 2>&1 || true

python3 - "$OUTPUT_DIR/quic_cpu_activity_server.json" "$OUTPUT_DIR/quic_cpu_activity_client.json" <<'PY'
import json,sys
for label,path in zip(('server','client'),sys.argv[1:]):
    j=json.load(open(path,encoding='utf-8'))
    print(f"P5 {label.upper()} QUIC CPU RUNTIME ACTIVITY: {j.get('status')}")
    for r in j.get('rows',[]):
        print(f"  CPU{r['cpu']}: process_cpu_time={r['cpu_time_s']:.6f}s pinned_single_cpu_time={r['single_cpu_pinned_time_s']:.6f}s hits={r['sample_hits']} active={int(bool(r['active']))}")
    if j.get('status')!='PASS': raise SystemExit(f"ERROR: P5 {label} did not execute on every requested QUIC CPU")
PY

python3 "$AGG" --matrix "$OUTPUT_DIR" --expected-runs "$RUNS" --connections "$CONNECTIONS"
python3 "$ACTIVE" --matrix "$OUTPUT_DIR" --runs "$RUNS" --connections "$CONNECTIONS"
python3 "$VALIDATOR" --matrix "$OUTPUT_DIR" --runs "$RUNS"
python3 - "$OUTPUT_DIR" "$RUNS" <<'PY'
from pathlib import Path
import json,re,sys
root=Path(sys.argv[1]);runs=int(sys.argv[2]);modes=('off','basic','plus');pat=re.compile(r'\[GreenQUIC-MC\] QUEUE_STATS[^\n]*rxq0=(\d+)[^\n]*rxq1=(\d+)[^\n]*txq0=(\d+)[^\n]*txq1=(\d+)[^\n]*tx_hash_fallback=(\d+)');problems=[];records=[]
for role in ('server','client'):
 for rep in range(1,runs+1):
  for mode in modes:
   p=root/f'{role}_rep{rep:02d}_{mode}.log'
   if not p.is_file():problems.append(f'{role} rep{rep:02d} {mode}: exact controller log missing: {p.name}');continue
   matches=pat.findall(p.read_text(errors='replace'))
   if not matches:problems.append(f'{role} rep{rep:02d} {mode}: queue stats missing in {p.name}');continue
   rx0,rx1,tx0,tx1,fallback=map(int,matches[-1]);records.append({'role':role,'repetition':rep,'mode':mode,'rxq0':rx0,'rxq1':rx1,'txq0':tx0,'txq1':tx1,'tx_hash_fallback':fallback,'log':str(p)})
   if role=='server' and (tx0==0 or tx1==0):problems.append(f'{role} rep{rep:02d} {mode}: TX queues not both active ({tx0},{tx1})')
   if role=='client' and (rx0==0 or rx1==0):problems.append(f'{role} rep{rep:02d} {mode}: RSS RX queues not both active ({rx0},{rx1})')
(root/'parallel_queue_activity.json').write_text(json.dumps({'schema':'greenquic-p5-parallel-queue-activity-v1','records':records,'errors':problems,'status':'PASS' if not problems else 'FAIL'},indent=2)+'\n')
if problems:raise SystemExit('ERROR: multicore queue-use validation failed:\n  '+'\n  '.join(problems))
print('P5 PARALLEL QUEUE-USE VALIDATION PASS: server TXQ0/TXQ1 and client RXQ0/RXQ1 active in every run/mode')
PY

python3 "$PERCORE" \
    --goodput "$OUTPUT_DIR/parallel_tables/parallel_goodput_summary.csv" \
    --server-activity "$OUTPUT_DIR/quic_cpu_activity_server.json" \
    --client-activity "$OUTPUT_DIR/quic_cpu_activity_client.json" \
    --dataplane-cores 2 \
    --output "$OUTPUT_DIR/parallel_tables/parallel_goodput_per_core_summary.csv"

cat > "$OUTPUT_DIR/PARALLEL_MULTICORE_CONFIG.txt" <<EOF
branch=performance2/p5-multicore
workload=one_process_multiple_simultaneous_quic_connections
runs=$RUNS
connections=$CONNECTIONS
payload_bytes_per_connection=8589934592
local_udp_port_base=45000
dpdk_lcores=19,20
quic_cpus=21,22,23,24
rx_queues=2
tx_queues=2
mtu=1500
msquic_execution_profile=max_throughput
rapl_interval_ms=6
frequency_interval_ms=1
cstate_cpus=19,20
tx_queue_mapping=stable_ipv4_udp_4tuple_hash
quic_cpu_runtime_validation=exact_process_thread_cpu_time_on_21_22_23_24_both_endpoints
per_core_goodput_semantics=normalized_aggregate_not_direct_payload_byte_attribution
active_window=parallel_batch_start_to_parallel_batch_complete
active_rapl=sample_overlap_prorated
active_frequency=midpoint_cell_time_weighted_cpu19_cpu20
mode_isolation=OFF_no_policy_BASIC_physical_only_PLUS_physical_plus_quic_hints
EOF

echo "P5 PARALLEL MULTICORE MATRIX PASS"
echo "RESULTS: $OUTPUT_DIR"
echo "GOODPUT+VARIANCE: $OUTPUT_DIR/parallel_tables/parallel_goodput_summary.csv"
echo "PER-CORE NORMALIZED GOODPUT: $OUTPUT_DIR/parallel_tables/parallel_goodput_per_core_summary.csv"
echo "QUIC CPU RUNTIME ACTIVITY: $OUTPUT_DIR/quic_cpu_activity_{server,client}.json"
echo "ACTIVE ENERGY+FREQUENCY: $OUTPUT_DIR/parallel_tables/parallel_active_metrics.csv"
echo "ACTIVE SUMMARY+VARIANCE: $OUTPUT_DIR/parallel_tables/parallel_active_summary.csv"
