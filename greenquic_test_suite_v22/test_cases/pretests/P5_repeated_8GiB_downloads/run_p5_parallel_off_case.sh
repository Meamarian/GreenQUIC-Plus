#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
CORE="$HERE/run_matrix_from_idex_core.sh"
PUBLIC="$HERE/run_matrix_from_idex.sh"
CLIENT_PAR="$HERE/run_client_parallel_multicore.sh"
CLOCK_PAR="$HERE/clock_sync_parallel.py"
CPU_BUSY="$HERE/cpu_busy_sampler.py"
ANALYZE="$HERE/analyze_p5_bottleneck_case.py"

RUNS=2
CONNECTIONS=4
OUTPUT_DIR=""
CASE_NAME=""
DPDK_LCORES="19,20"
QUIC_CPUS="21,22,23,24"

while (($#)); do
    case "$1" in
        --runs) RUNS="${2:?}"; shift 2 ;;
        --connections) CONNECTIONS="${2:?}"; shift 2 ;;
        --output-dir) OUTPUT_DIR="${2:?}"; shift 2 ;;
        --case-name) CASE_NAME="${2:?}"; shift 2 ;;
        --dpdk-lcores) DPDK_LCORES="${2:?}"; shift 2 ;;
        --quic-cpus) QUIC_CPUS="${2:?}"; shift 2 ;;
        -h|--help)
            echo "usage: $0 --case-name NAME --output-dir DIR [--runs N] [--connections N] [--dpdk-lcores 19|19,20]"
            exit 0 ;;
        *) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
    esac
done

[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --runs must be positive" >&2; exit 2; }
[[ "$CONNECTIONS" =~ ^[2-9][0-9]*$ ]] || { echo "ERROR: --connections must be >=2" >&2; exit 2; }
[[ -n "$CASE_NAME" && -n "$OUTPUT_DIR" ]] || { echo "ERROR: --case-name and --output-dir are required" >&2; exit 2; }
case "$DPDK_LCORES" in 19|19,20) ;; *) echo "ERROR: bottleneck sweep supports --dpdk-lcores 19 or 19,20" >&2; exit 2;; esac
for f in "$CORE" "$PUBLIC" "$CLIENT_PAR" "$CLOCK_PAR" "$CPU_BUSY" "$ANALYZE"; do
    [[ -f "$f" ]] || { echo "ERROR: missing dependency: $f" >&2; exit 2; }
done
python3 -m py_compile "$CPU_BUSY" "$ANALYZE" "$CLOCK_PAR"
python3 "$CLOCK_PAR" --self-test >/dev/null

mkdir -p "$OUTPUT_DIR"
OFF_CORE="$(mktemp "$HERE/.bottleneck_off_core.XXXXXX.sh")"
OFF_PUBLIC="$(mktemp "$HERE/.bottleneck_off_public.XXXXXX.sh")"
SERVER_BUSY_PID=""
CLIENT_BUSY_PID=""
REMOTE_BUSY="/tmp/p5_bottleneck_busy_${CASE_NAME}_$$_client.csv"
cleanup(){
    local rc=$?
    trap - EXIT INT TERM
    if [[ -n "$SERVER_BUSY_PID" ]]; then kill -TERM "$SERVER_BUSY_PID" 2>/dev/null || true; wait "$SERVER_BUSY_PID" 2>/dev/null || true; fi
    if [[ -n "$CLIENT_BUSY_PID" ]]; then ssh -o BatchMode=yes -o ConnectTimeout=10 root@tinyman "kill -TERM '$CLIENT_BUSY_PID' 2>/dev/null || true" >/dev/null 2>&1 || true; fi
    rm -f "$OFF_CORE" "$OFF_PUBLIC"
    exit "$rc"
}
trap cleanup EXIT INT TERM

# Make a private OFF-only copy of the preserved controller core. This keeps the
# normal OFF/BASIC/PLUS matrix untouched while giving the bottleneck sweep one
# identical OFF workload per repetition.
python3 - "$CORE" "$OFF_CORE" <<'PY'
from pathlib import Path
import sys
src=Path(sys.argv[1]).read_text(encoding='utf-8')
repls=(
 ('MODE_ORDER="balanced"','MODE_ORDER="off"','default mode'),
 ('modes = ("off", "basic", "plus")','modes = ("off",)','mode set'),
 ('if len(order) != 3 or set(order) != set(modes):','if len(order) != len(modes) or set(order) != set(modes):','fixed-order validation'),
 ('raise SystemExit("ERROR: fixed --mode-order must contain off,basic,plus exactly once")','raise SystemExit("ERROR: bottleneck OFF controller requires --mode-order off")','fixed-order error'),
 ('TOTAL_TESTS=$((RUNS * 3))','TOTAL_TESTS=$RUNS','total tests'),
 ('position=$position/3 mode=$mode','position=$position/1 mode=$mode','schedule display'),
 ('POSITION $position/3 | MODE=$mode','POSITION $position/1 | MODE=$mode','test display'),
)
for old,new,label in repls:
    n=src.count(old)
    if n != 1:
        raise SystemExit(f'ERROR: OFF controller {label} anchor count={n}')
    src=src.replace(old,new,1)
Path(sys.argv[2]).write_text(src,encoding='utf-8')
PY
chmod 0700 "$OFF_CORE"
bash -n "$OFF_CORE"

# Apply the same proven parallel-client / gate / clock-sync transformation used
# by run_parallel_multicore_matrix.sh, but point the public wrapper at OFF_CORE.
python3 - "$PUBLIC" "$OFF_PUBLIC" "$OFF_CORE" <<'PY'
from pathlib import Path
import sys
src=Path(sys.argv[1]).read_text(encoding='utf-8')
core=Path(sys.argv[3])
old_core='CORE="$HERE/run_matrix_from_idex_core.sh"'
new_core=f'CORE="$HERE/{core.name}"'
if src.count(old_core)!=1: raise SystemExit(f'ERROR: public CORE anchor count={src.count(old_core)}')
src=src.replace(old_core,new_core,1)
old='./run_client.sh'; new='bash ./run_client_parallel_multicore.sh'
if src.count(old)<1: raise SystemExit('ERROR: no client wrapper anchor')
src=src.replace(old,new)
clock_old='python3 "$HERE/clock_sync.py"'; clock_new='python3 "$HERE/clock_sync_parallel.py"'
if src.count(clock_old)!=1: raise SystemExit(f'ERROR: clock anchor count={src.count(clock_old)}')
src=src.replace(clock_old,clock_new,1)
needle='Path(sys.argv[2]).write_text(src, encoding="utf-8")'
if src.count(needle)!=1: raise SystemExit(f'ERROR: public write anchor count={src.count(needle)}')
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
injection=("# P5-BOTTLENECK-PARALLEL-COMPLETION-V1\n"+"parallel_old = "+repr(completion_old)+"\n"+"parallel_new = "+repr(completion_new)+"\n"+'replace_once(parallel_old, parallel_new, "parallel completion detector")\n'+needle)
src=src.replace(needle,injection,1)
Path(sys.argv[2]).write_text(src,encoding='utf-8')
PY
chmod 0700 "$OFF_PUBLIC"
bash -n "$OFF_PUBLIC"
bash "$OFF_PUBLIC" --help >/dev/null

echo "P5 BOTTLENECK OFF CONTROLLER PREFLIGHT PASS case=$CASE_NAME"

IFS=',' read -r -a DP_ARRAY <<< "$DPDK_LCORES"
PARTITION_MAP=""
for ((p=0;p<CONNECTIONS;p++)); do
    cpu="${DP_ARRAY[$((p % ${#DP_ARRAY[@]}))]}"
    [[ -z "$PARTITION_MAP" ]] || PARTITION_MAP+="," 
    PARTITION_MAP+="$p:$cpu"
done
TX_OWNER="${DP_ARRAY[0]}"

export P5_PARALLEL_CONNECTIONS="$CONNECTIONS" P5_PARALLEL_LOCAL_PORT_BASE=45000
TOPOLOGY_ENV=(
  --env ENABLE_MULTICORE=1
  --env SERVER_DPDK_LCORES="$DPDK_LCORES"
  --env CLIENT_DPDK_LCORES="$DPDK_LCORES"
  --env SERVER_QUIC_CPUS="$QUIC_CPUS"
  --env CLIENT_QUIC_CPUS="$QUIC_CPUS"
  --env SERVER_PARTITION_MAP="$PARTITION_MAP"
  --env CLIENT_PARTITION_MAP="$PARTITION_MAP"
  --env SERVER_TX_OWNER_LCORE="$TX_OWNER"
  --env CLIENT_TX_OWNER_LCORE="$TX_OWNER"
  --env GREENQUIC_TX_OWNER_ALSO_RX=1
  --env P5_PARALLEL_CONNECTIONS="$CONNECTIONS"
  --env P5_PARALLEL_LOCAL_PORT_BASE=45000
  --env ENABLE_RECORD=1
  --env ENABLE_CSTATE_RECORD=1
  --env GQ_MSR_SAMPLE_INTERVAL_MS=6
  --env GQ_FREQ_SAMPLE_INTERVAL_MS=1
  --env MSQUIC_EXECUTION_PROFILE=max_throughput
)

# Independent /proc/stat activity traces for DPDK and QUIC CPUs. The case
# analyzer clips them to each exact parallel batch window.
python3 "$CPU_BUSY" --cpus 19,20,21,22,23,24 --interval-ms 20 --output "$OUTPUT_DIR/cpu_busy_server.csv" \
  >"$OUTPUT_DIR/cpu_busy_server_sampler.log" 2>&1 &
SERVER_BUSY_PID=$!
CLIENT_BUSY_PID="$(ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman \
  "rm -f '$REMOTE_BUSY'; nohup python3 '$CPU_BUSY' --cpus 19,20,21,22,23,24 --interval-ms 20 --output '$REMOTE_BUSY' >/tmp/p5_bottleneck_busy_${CASE_NAME}_$$.log 2>&1 </dev/null & echo \$!")"
[[ "$CLIENT_BUSY_PID" =~ ^[0-9]+$ ]] || { echo "ERROR: cannot start Tinyman CPU busy sampler" >&2; exit 2; }

set +e
bash "$OFF_PUBLIC" \
  --runs "$RUNS" \
  --downloads "$CONNECTIONS" \
  --gap-seconds 0 \
  --server-cooldown-seconds 5 \
  --between-tests-seconds 5 \
  --mode-order off \
  --seed 20260817 \
  --output-dir "$OUTPUT_DIR" \
  "${TOPOLOGY_ENV[@]}"
TRAFFIC_RC=$?
set -e

kill -TERM "$SERVER_BUSY_PID" 2>/dev/null || true
wait "$SERVER_BUSY_PID" 2>/dev/null || true
SERVER_BUSY_PID=""
ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman "kill -TERM '$CLIENT_BUSY_PID' 2>/dev/null || true; for i in \$(seq 1 100); do kill -0 '$CLIENT_BUSY_PID' 2>/dev/null || exit 0; sleep 0.1; done; exit 1" || true
CLIENT_BUSY_PID=""
scp -q -o BatchMode=yes -o ConnectTimeout=15 "root@tinyman:$REMOTE_BUSY" "$OUTPUT_DIR/cpu_busy_client.csv" || true

cat > "$OUTPUT_DIR/BOTTLENECK_CASE_CONFIG.env" <<EOF
case=$CASE_NAME
runs=$RUNS
connections=$CONNECTIONS
payload_bytes_per_connection=8589934592
mode=off
dpdk_lcores=$DPDK_LCORES
quic_cpus=$QUIC_CPUS
partition_map=$PARTITION_MAP
local_port_base=45000
traffic_rc=$TRAFFIC_RC
EOF

if (( TRAFFIC_RC != 0 )); then
    echo "P5 BOTTLENECK CASE TRAFFIC FAIL case=$CASE_NAME rc=$TRAFFIC_RC; preserving case directory" >&2
    exit "$TRAFFIC_RC"
fi

python3 "$ANALYZE" \
  --case-dir "$OUTPUT_DIR" \
  --case-name "$CASE_NAME" \
  --runs "$RUNS" \
  --connections "$CONNECTIONS" \
  --dpdk-cpus "$DPDK_LCORES"

echo "P5 BOTTLENECK CASE PASS case=$CASE_NAME results=$OUTPUT_DIR"
