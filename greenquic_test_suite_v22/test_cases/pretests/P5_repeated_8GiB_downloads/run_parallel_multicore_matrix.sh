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

ROOT="$HERE/../../../common/files/server_root"
mkdir -p "$ROOT"
for ((i=1;i<=CONNECTIONS;i++)); do
    f="$ROOT/file_8G_mc$(printf '%02d' "$i").bin"
    [[ -e "$f" ]] || truncate -s 8589934592 "$f"
    [[ "$(stat -Lc '%s' "$f")" == 8589934592 ]] || { echo "ERROR: wrong sparse payload size $f" >&2; exit 2; }
done

# Reuse the proven aligned-RAPL/start-gate controller and change only the client
# entry point in a temporary copy. The original sequential P5 runner is intact.
# New branch-only wrappers are created via GitHub's contents API and therefore
# may not carry an executable mode. Invoke them explicitly through bash rather
# than mutating tracked file modes on the experiment hosts.
TMP="$(mktemp "$HERE/.parallel_matrix.XXXXXX.sh")"
trap 'rm -f "$TMP"' EXIT
python3 - "$BASE" "$TMP" <<'PY'
from pathlib import Path
import sys
src=Path(sys.argv[1]).read_text(encoding='utf-8')
old='./run_client.sh';new='bash ./run_client_parallel_multicore.sh';count=src.count(old)
if count < 1:raise SystemExit(f'ERROR: base P5 runner contains no {old} anchor')
src=src.replace(old,new)
Path(sys.argv[2]).write_text(src,encoding='utf-8')
print(f'P5 parallel controller patch: replaced {count} client invocation anchor(s); wrapper invoked via bash')
PY
chmod 0700 "$TMP"; bash -n "$TMP"

grep -Fq 'env $client_env_words bash ./run_client_parallel_multicore.sh' "$TMP" || {
    echo "ERROR: generated P5 controller does not invoke multicore client via bash" >&2
    exit 2
}

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
    --env ENABLE_RECORD=1
    --env ENABLE_CSTATE_RECORD=1
    --env GQ_MSR_SAMPLE_INTERVAL_MS=6
    --env GQ_FREQ_SAMPLE_INTERVAL_MS=1
    --env MSQUIC_EXECUTION_PROFILE=max_throughput
)

echo "======================================================================"
echo "P5 PARALLEL MULTICORE AGGREGATE-GOODPUT MATRIX"
echo "modes=OFF,BASIC,PLUS runs=$RUNS connections=$CONNECTIONS payload=8GiB/connection"
echo "DPDK=19,20 QUIC=21-24 RXQ=2 TXQ=2 local_ports=45000..$((44999+CONNECTIONS))"
echo "recording: RAPL=6ms frequency=1ms C-state=19,20 profile=max_throughput"
echo "======================================================================"

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

# QUEUE_STATS is mode-independent, so strict OFF is validated too. Use the
# controller's exact per-repetition logs; never fall back to a different run.
# Non-UDP setup/control frames may legitimately use queue 0, so tx_hash_fallback
# is recorded as a diagnostic rather than treated as a workload failure.
python3 - "$OUTPUT_DIR" "$RUNS" <<'PY'
from pathlib import Path
import json,re,sys
root=Path(sys.argv[1]);runs=int(sys.argv[2]);modes=('off','basic','plus')
pat=re.compile(r'\[GreenQUIC-MC\] QUEUE_STATS[^\n]*rxq0=(\d+)[^\n]*rxq1=(\d+)[^\n]*txq0=(\d+)[^\n]*txq1=(\d+)[^\n]*tx_hash_fallback=(\d+)')
problems=[];records=[]
for role in ('server','client'):
  for rep in range(1,runs+1):
    for mode in modes:
      p=root/f'{role}_rep{rep:02d}_{mode}.log'
      if not p.is_file():
        problems.append(f'{role} rep{rep:02d} {mode}: exact controller log missing: {p.name}');continue
      rows=pat.findall(p.read_text(errors='replace'))
      if not rows:
        problems.append(f'{role} rep{rep:02d} {mode}: queue stats missing in {p.name}');continue
      rx0,rx1,tx0,tx1,fallback=map(int,rows[-1])
      records.append({'role':role,'repetition':rep,'mode':mode,'rxq0':rx0,'rxq1':rx1,'txq0':tx0,'txq1':tx1,'tx_hash_fallback':fallback,'log':str(p)})
      if role=='server' and (tx0==0 or tx1==0):problems.append(f'{role} rep{rep:02d} {mode}: TX queues not both active ({tx0},{tx1})')
      if role=='client' and (rx0==0 or rx1==0):problems.append(f'{role} rep{rep:02d} {mode}: RSS RX queues not both active ({rx0},{rx1})')
out=root/'parallel_queue_activity.json';out.write_text(json.dumps({'schema':'greenquic-p5-parallel-queue-activity-v1','records':records,'errors':problems,'status':'PASS' if not problems else 'FAIL'},indent=2)+'\n')
if problems:raise SystemExit('ERROR: multicore queue-use validation failed:\n  '+'\n  '.join(problems))
print('P5 PARALLEL QUEUE-USE VALIDATION PASS: server TXQ0/TXQ1 and client RXQ0/RXQ1 active in every run/mode')
for r in records:
  if r['tx_hash_fallback']:
    print(f"NOTE: {r['role']} rep{r['repetition']:02d} {r['mode']} non-UDP/malformed TX hash fallback={r['tx_hash_fallback']}")
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
mtu=1500
msquic_execution_profile=max_throughput
rapl_interval_ms=6
frequency_interval_ms=1
cstate_cpus=19,20
tx_queue_mapping=stable_ipv4_udp_4tuple_hash
mode_isolation=OFF_no_policy_BASIC_physical_only_PLUS_physical_plus_quic_hints
EOF

echo "P5 PARALLEL MULTICORE MATRIX PASS"
echo "RESULTS: $OUTPUT_DIR"
echo "GOODPUT+VARIANCE: $OUTPUT_DIR/parallel_tables/parallel_goodput_summary.csv"
