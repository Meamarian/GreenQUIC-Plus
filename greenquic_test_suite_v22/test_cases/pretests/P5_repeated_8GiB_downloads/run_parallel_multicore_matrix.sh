#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
BASE="$HERE/run_matrix_from_idex.sh"
CLIENT="$HERE/run_client_parallel_multicore.sh"
AGG="$HERE/aggregate_parallel_goodput.py"
VALIDATOR="$HERE/validate_p5_multicore_matrix.py"

RUNS=2
CONNECTIONS=4
OUTPUT_DIR=""
USER_ARGS=()
while (($#)); do
    case "$1" in
        --runs) RUNS="${2:?}"; shift 2 ;;
        --connections) CONNECTIONS="${2:?}"; shift 2 ;;
        --output-dir) OUTPUT_DIR="${2:?}"; shift 2 ;;
        -h|--help)
            echo "usage: $0 [--runs N] [--connections N] [--output-dir DIR] [normal P5 matrix options]"
            exit 0;;
        *) USER_ARGS+=("$1"); shift;;
    esac
done
[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: runs must be positive" >&2; exit 2; }
[[ "$CONNECTIONS" =~ ^[2-9][0-9]*$ ]] || { echo "ERROR: connections must be >=2" >&2; exit 2; }
for f in "$BASE" "$CLIENT" "$AGG" "$VALIDATOR"; do [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 2; }; done

OUTPUT_DIR="${OUTPUT_DIR:-$HERE/matrix_results/P5_PARALLEL_MC_${CONNECTIONS}c_${RUNS}r_$(date +%Y%m%d_%H%M%S)}"

# Server-side sparse aliases. The client wrapper creates matching Tinyman
# validation aliases and /dev/null sinks. Sparse files do not allocate 8 GiB.
ROOT="$HERE/../../../common/files/server_root"
mkdir -p "$ROOT"
for ((i=1;i<=CONNECTIONS;i++)); do
    f="$ROOT/file_8G_mc$(printf '%02d' "$i").bin"
    [[ -e "$f" ]] || truncate -s 8589934592 "$f"
    [[ "$(stat -Lc '%s' "$f")" == 8589934592 ]] || { echo "ERROR: wrong sparse payload size $f" >&2; exit 2; }
done

# The preserved controller is already correct for aligned RAPL/start-gate
# orchestration. Patch only the selected client wrapper in a temporary copy;
# existing sequential P5 remains untouched.
TMP="$(mktemp "$HERE/.parallel_matrix.XXXXXX.sh")"
trap 'rm -f "$TMP"' EXIT
python3 - "$BASE" "$TMP" <<'PY'
from pathlib import Path
import sys
src=Path(sys.argv[1]).read_text(encoding='utf-8')
old='./run_client.sh'
new='./run_client_parallel_multicore.sh'
count=src.count(old)
if count < 1:
    raise SystemExit(f'ERROR: base P5 runner contains no {old} anchor')
src=src.replace(old,new)
Path(sys.argv[2]).write_text(src,encoding='utf-8')
print(f'P5 parallel controller patch: replaced {count} client invocation anchor(s)')
PY
chmod 0700 "$TMP"; bash -n "$TMP"

export P5_PARALLEL_CONNECTIONS="$CONNECTIONS"
export P5_PARALLEL_LOCAL_PORT_BASE=45000

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
)

echo "======================================================================"
echo "P5 PARALLEL MULTICORE AGGREGATE-GOODPUT MATRIX"
echo "modes=OFF,BASIC,PLUS runs=$RUNS connections=$CONNECTIONS payload=8GiB/connection"
echo "DPDK=19,20 QUIC=21-24 RXQ=2 TXQ=2 local_ports=45000..$((44999+CONNECTIONS))"
echo "======================================================================"

# Gap is zero because the four downloads are simultaneous. The 5s connected
# edge cooldown is retained by the base controller for aligned power recording.
bash "$TMP" \
    --runs "$RUNS" \
    --downloads "$CONNECTIONS" \
    --gap-seconds 0 \
    --server-cooldown-seconds 5 \
    --between-tests-seconds 5 \
    --mode-order balanced \
    --seed 20260817 \
    --output-dir "$OUTPUT_DIR" \
    "${TOPOLOGY_ENV[@]}" \
    "${USER_ARGS[@]}"

[[ -d "$OUTPUT_DIR" ]] || { echo "ERROR: result directory missing: $OUTPUT_DIR" >&2; exit 1; }
python3 "$AGG" --matrix "$OUTPUT_DIR" --expected-runs "$RUNS" --connections "$CONNECTIONS"
python3 "$VALIDATOR" --matrix "$OUTPUT_DIR" --runs "$RUNS"

# Queue-use audit is separate from GreenQUIC policy counters and therefore also
# works for strict OFF. Server TX and client RX are the heavy download paths.
python3 - "$OUTPUT_DIR" "$RUNS" <<'PY'
from pathlib import Path
import re,sys
root=Path(sys.argv[1]);runs=int(sys.argv[2]);modes=('off','basic','plus')
pat=re.compile(r'\[GreenQUIC-MC\] QUEUE_STATS[^\n]*rxq0=(\d+)[^\n]*rxq1=(\d+)[^\n]*txq0=(\d+)[^\n]*txq1=(\d+)[^\n]*tx_hash_fallback=(\d+)')
problems=[]
for role in ('server','client'):
  for rep in range(1,runs+1):
    for mode in modes:
      candidates=list(root.rglob(f'*{role}*rep{rep:02d}*{mode}*log*'))+list(root.rglob(f'*{role}*{mode}*log.txt'))
      found=None
      for p in candidates:
        try:text=p.read_text(errors='replace')
        except:continue
        rows=pat.findall(text)
        if rows: found=tuple(map(int,rows[-1]));break
      if found is None:
        problems.append(f'{role} rep{rep} {mode}: queue stats missing');continue
      rx0,rx1,tx0,tx1,fallback=found
      if fallback!=0:problems.append(f'{role} rep{rep} {mode}: tx hash fallback={fallback}')
      if role=='server' and (tx0==0 or tx1==0):problems.append(f'{role} rep{rep} {mode}: TX queues not both active ({tx0},{tx1})')
      if role=='client' and (rx0==0 or rx1==0):problems.append(f'{role} rep{rep} {mode}: RSS RX queues not both active ({rx0},{rx1})')
if problems:
  raise SystemExit('ERROR: multicore queue-use validation failed:\n  '+'\n  '.join(problems))
print('P5 PARALLEL QUEUE-USE VALIDATION PASS: server TXQ0/TXQ1 and client RXQ0/RXQ1 active in every run/mode')
PY

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
tx_queue_mapping=stable_ipv4_udp_4tuple_hash
mode_isolation=OFF_no_policy_BASIC_physical_only_PLUS_physical_plus_quic_hints
EOF

echo "P5 PARALLEL MULTICORE MATRIX PASS"
echo "RESULTS: $OUTPUT_DIR"
echo "GOODPUT+VARIANCE: $OUTPUT_DIR/parallel_tables/parallel_goodput_summary.csv"
