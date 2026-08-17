#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
CORE="$HERE/run_matrix_from_idex_core.sh"
PUBLIC="$HERE/run_matrix_from_idex.sh"
CPU_BUSY="$HERE/cpu_busy_sampler.py"
QUIC_ACTIVITY="$HERE/quic_cpu_activity_sampler.py"
ANALYZE="$HERE/analyze_p5_bottleneck_case.py"

RUNS=2
CONNECTIONS=4
OUTPUT_DIR=""
CASE_NAME=""
DPDK_LCORES="19,20"
QUIC_CPUS="21,22,23,24"
PARTITION_MAP=""
QUIC_AFFINITIZE=1
EXEC_PROFILE=max_throughput

while (($#)); do
    case "$1" in
        --runs) RUNS="${2:?}"; shift 2 ;;
        --connections) CONNECTIONS="${2:?}"; shift 2 ;;
        --output-dir) OUTPUT_DIR="${2:?}"; shift 2 ;;
        --case-name) CASE_NAME="${2:?}"; shift 2 ;;
        --dpdk-lcores) DPDK_LCORES="${2:?}"; shift 2 ;;
        --quic-cpus) QUIC_CPUS="${2:?}"; shift 2 ;;
        --partition-map) PARTITION_MAP="${2:?}"; shift 2 ;;
        --quic-affinitize) QUIC_AFFINITIZE="${2:?}"; shift 2 ;;
        --execution-profile) EXEC_PROFILE="${2:?}"; shift 2 ;;
        -h|--help)
            cat <<'USAGE'
usage: run_p5_arch_off_case_v4.sh --case-name NAME --output-dir DIR [options]
  --runs N
  --connections 4
  --dpdk-lcores 19|19,20|19,20,21,22
  --quic-cpus LIST
  --partition-map 0:19,1:20,...
  --quic-affinitize 0|1
  --execution-profile max_throughput|low_latency
USAGE
            exit 0 ;;
        *) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
    esac
done

[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: runs must be positive" >&2; exit 2; }
[[ "$CONNECTIONS" == 4 ]] || { echo "ERROR: architecture suite currently requires exactly 4 parallel connections" >&2; exit 2; }
[[ -n "$CASE_NAME" && -n "$OUTPUT_DIR" ]] || { echo "ERROR: --case-name and --output-dir are required" >&2; exit 2; }
[[ "$QUIC_AFFINITIZE" == 0 || "$QUIC_AFFINITIZE" == 1 ]] || { echo "ERROR: --quic-affinitize must be 0|1" >&2; exit 2; }
case "$EXEC_PROFILE" in max_throughput|low_latency) ;; *) echo "ERROR: unsupported execution profile $EXEC_PROFILE" >&2; exit 2;; esac
for f in "$CORE" "$PUBLIC" "$CPU_BUSY" "$QUIC_ACTIVITY" "$ANALYZE"; do
    [[ -f "$f" ]] || { echo "ERROR: missing dependency: $f" >&2; exit 2; }
done
python3 -m py_compile "$CPU_BUSY" "$QUIC_ACTIVITY" "$ANALYZE"

# Validate CPU-list syntax and build a compact comma list for the /proc/stat analyzer.
readarray -t CPU_META < <(python3 - "$DPDK_LCORES" "$QUIC_CPUS" <<'PY'
import re,sys

def parse(s):
    out=[]
    for tok in s.split(','):
        tok=tok.strip()
        if not re.fullmatch(r'\d+',tok): raise SystemExit(f'ERROR invalid CPU token {tok!r}')
        out.append(int(tok))
    if not out or len(out)!=len(set(out)): raise SystemExit('ERROR empty/duplicate CPU list')
    return out
D=parse(sys.argv[1]); Q=parse(sys.argv[2])
if set(D)&set(Q): raise SystemExit(f'ERROR DPDK/QUIC CPU overlap: {sorted(set(D)&set(Q))}')
print('1' if len(D)>1 else '0')
print(','.join(map(str,sorted(set(D+Q)))))
PY
)
ENABLE_MULTI="${CPU_META[0]}"
BUSY_CPUS="${CPU_META[1]}"

if [[ -z "$PARTITION_MAP" ]]; then
    PARTITION_MAP="$(python3 - "$DPDK_LCORES" <<'PY'
import sys
D=[int(x) for x in sys.argv[1].split(',')]
print(','.join(f'{i}:{D[i%len(D)]}' for i in range(4)))
PY
)"
fi

mkdir -p "$OUTPUT_DIR"
OFF_CORE="$(mktemp "$HERE/.arch4_off_core.XXXXXX.sh")"
OFF_PUBLIC="$(mktemp "$HERE/.arch4_off_public.XXXXXX.sh")"
SERVER_BUSY_PID=""; CLIENT_BUSY_PID=""
SERVER_QUIC_PID=""; CLIENT_QUIC_PID=""
REMOTE_BUSY="/tmp/p5_arch4_busy_${CASE_NAME}_$$_client.csv"
REMOTE_QJSON="/tmp/p5_arch4_quic_${CASE_NAME}_$$_client.json"
REMOTE_QCSV="/tmp/p5_arch4_quic_${CASE_NAME}_$$_client.csv"
REMOTE_QLOG="/tmp/p5_arch4_quic_${CASE_NAME}_$$_client.log"

stop_diag(){
    if [[ -n "${SERVER_BUSY_PID:-}" ]]; then kill -TERM "$SERVER_BUSY_PID" 2>/dev/null || true; wait "$SERVER_BUSY_PID" 2>/dev/null || true; SERVER_BUSY_PID=""; fi
    if [[ -n "${SERVER_QUIC_PID:-}" ]]; then kill -TERM "$SERVER_QUIC_PID" 2>/dev/null || true; wait "$SERVER_QUIC_PID" 2>/dev/null || true; SERVER_QUIC_PID=""; fi
    if [[ -n "${CLIENT_BUSY_PID:-}" ]]; then ssh -o BatchMode=yes -o ConnectTimeout=10 root@tinyman "kill -TERM '$CLIENT_BUSY_PID' 2>/dev/null || true" >/dev/null 2>&1 || true; CLIENT_BUSY_PID=""; fi
    if [[ -n "${CLIENT_QUIC_PID:-}" ]]; then ssh -o BatchMode=yes -o ConnectTimeout=10 root@tinyman "kill -TERM '$CLIENT_QUIC_PID' 2>/dev/null || true" >/dev/null 2>&1 || true; CLIENT_QUIC_PID=""; fi
}
cleanup(){ local rc=$?; trap - EXIT INT TERM; stop_diag; rm -f "$OFF_CORE" "$OFF_PUBLIC"; exit "$rc"; }
trap cleanup EXIT INT TERM

# Private OFF-only controller. We do not change the normal matrix runner.
python3 - "$CORE" "$OFF_CORE" <<'PY'
from pathlib import Path
import sys
src=Path(sys.argv[1]).read_text(encoding='utf-8')
repls=(
 ('MODE_ORDER="balanced"','MODE_ORDER="off"','default mode'),
 ('modes = ("off", "basic", "plus")','modes = ("off",)','mode set'),
 ('if len(order) != 3 or set(order) != set(modes):','if len(order) != len(modes) or set(order) != set(modes):','fixed validation'),
 ('raise SystemExit("ERROR: fixed --mode-order must contain off,basic,plus exactly once")','raise SystemExit("ERROR: architecture OFF controller requires --mode-order off")','fixed error'),
 ('TOTAL_TESTS=$((RUNS * 3))','TOTAL_TESTS=$RUNS','total tests'),
 ('position=$position/3 mode=$mode','position=$position/1 mode=$mode','schedule display'),
 ('POSITION $position/3 | MODE=$mode','POSITION $position/1 | MODE=$mode','test display'),
)
for old,new,label in repls:
    n=src.count(old)
    if n!=1: raise SystemExit(f'ERROR OFF controller {label} anchor count={n}')
    src=src.replace(old,new,1)
Path(sys.argv[2]).write_text(src,encoding='utf-8')
PY
chmod 0700 "$OFF_CORE"; bash -n "$OFF_CORE"

# Reuse the proven public parallel/gate transformation, pointed at our OFF-only core.
python3 - "$PUBLIC" "$OFF_PUBLIC" "$OFF_CORE" <<'PY'
from pathlib import Path
import sys
src=Path(sys.argv[1]).read_text(encoding='utf-8'); core=Path(sys.argv[3])
old='CORE="$HERE/run_matrix_from_idex_core.sh"'; new=f'CORE="$HERE/{core.name}"'
if src.count(old)!=1: raise SystemExit(f'ERROR public CORE anchor count={src.count(old)}')
src=src.replace(old,new,1)
old_client='./run_client.sh'; new_client='bash ./run_client_parallel_multicore.sh'
if src.count(old_client)<1: raise SystemExit('ERROR no client wrapper anchor')
src=src.replace(old_client,new_client)
clock_old='python3 "$HERE/clock_sync.py"'; clock_new='python3 "$HERE/clock_sync_parallel.py"'
if src.count(clock_old)!=1: raise SystemExit(f'ERROR clock anchor count={src.count(clock_old)}')
src=src.replace(clock_old,clock_new,1)
needle='Path(sys.argv[2]).write_text(src, encoding="utf-8")'
if src.count(needle)!=1: raise SystemExit(f'ERROR public write anchor count={src.count(needle)}')
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
injection=("# P5-ARCH-V4-PARALLEL-COMPLETION\nparallel_old = "+repr(completion_old)+"\nparallel_new = "+repr(completion_new)+"\nreplace_once(parallel_old, parallel_new, \"parallel completion detector\")\n"+needle)
src=src.replace(needle,injection,1)
Path(sys.argv[2]).write_text(src,encoding='utf-8')
PY
chmod 0700 "$OFF_PUBLIC"; bash -n "$OFF_PUBLIC"; bash "$OFF_PUBLIC" --help >/dev/null

echo "P5 ARCH V4 CASE PREFLIGHT PASS case=$CASE_NAME multi=$ENABLE_MULTI DPDK=$DPDK_LCORES QUIC=$QUIC_CPUS aff=$QUIC_AFFINITIZE profile=$EXEC_PROFILE pmap=$PARTITION_MAP"

export P5_PARALLEL_CONNECTIONS="$CONNECTIONS" P5_PARALLEL_LOCAL_PORT_BASE=45000
TOPOLOGY_ENV=(
  --env ENABLE_MULTICORE="$ENABLE_MULTI"
  --env SERVER_DPDK_LCORES="$DPDK_LCORES"
  --env CLIENT_DPDK_LCORES="$DPDK_LCORES"
  --env SERVER_QUIC_CPUS="$QUIC_CPUS"
  --env CLIENT_QUIC_CPUS="$QUIC_CPUS"
  --env SERVER_PARTITION_MAP="$PARTITION_MAP"
  --env CLIENT_PARTITION_MAP="$PARTITION_MAP"
  --env SERVER_TX_OWNER_LCORE="${DPDK_LCORES%%,*}"
  --env CLIENT_TX_OWNER_LCORE="${DPDK_LCORES%%,*}"
  --env GREENQUIC_TX_OWNER_ALSO_RX=1
  --env P5_PARALLEL_CONNECTIONS="$CONNECTIONS"
  --env P5_PARALLEL_LOCAL_PORT_BASE=45000
  --env ENABLE_RECORD=1
  --env ENABLE_CSTATE_RECORD=1
  --env GQ_MSR_SAMPLE_INTERVAL_MS=6
  --env GQ_FREQ_SAMPLE_INTERVAL_MS=1
  --env MSQUIC_EXECUTION_PROFILE="$EXEC_PROFILE"
  --env MSQUIC_AFFINITIZE="$QUIC_AFFINITIZE"
)

# All diagnostics are best-effort and may NEVER gate traffic.
set +e
python3 "$CPU_BUSY" --cpus "$BUSY_CPUS" --interval-ms 20 --output "$OUTPUT_DIR/cpu_busy_server.csv" >"$OUTPUT_DIR/cpu_busy_server_sampler.log" 2>&1 & SERVER_BUSY_PID=$!
CLIENT_BUSY_PID="$(ssh -o BatchMode=yes -o ConnectTimeout=10 root@tinyman "rm -f '$REMOTE_BUSY'; nohup python3 '$CPU_BUSY' --cpus '$BUSY_CPUS' --interval-ms 20 --output '$REMOTE_BUSY' >/tmp/p5_arch4_busy_${CASE_NAME}_$$.log 2>&1 </dev/null & echo \$!" 2>/dev/null)"
SERVER_BIN="/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinteropserver"
CLIENT_BIN="/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop"
python3 "$QUIC_ACTIVITY" --binary "$SERVER_BIN" --cpus 0-63 --json "$OUTPUT_DIR/quic_runtime_allcpus_server.json" --csv "$OUTPUT_DIR/quic_runtime_allcpus_server.csv" --interval-ms 5 >"$OUTPUT_DIR/quic_runtime_allcpus_server.log" 2>&1 & SERVER_QUIC_PID=$!
CLIENT_QUIC_PID="$(ssh -o BatchMode=yes -o ConnectTimeout=10 root@tinyman "rm -f '$REMOTE_QJSON' '$REMOTE_QCSV' '$REMOTE_QLOG'; nohup python3 '$QUIC_ACTIVITY' --binary '$CLIENT_BIN' --cpus 0-63 --json '$REMOTE_QJSON' --csv '$REMOTE_QCSV' --interval-ms 5 >'$REMOTE_QLOG' 2>&1 </dev/null & echo \$!" 2>/dev/null)"
set -e
[[ "$CLIENT_BUSY_PID" =~ ^[0-9]+$ ]] || CLIENT_BUSY_PID=""
[[ "$CLIENT_QUIC_PID" =~ ^[0-9]+$ ]] || CLIENT_QUIC_PID=""

set +e
bash "$OFF_PUBLIC" \
  --runs "$RUNS" --downloads "$CONNECTIONS" --gap-seconds 0 \
  --server-cooldown-seconds 5 --between-tests-seconds 5 \
  --mode-order off --seed 20260817 --output-dir "$OUTPUT_DIR" \
  "${TOPOLOGY_ENV[@]}"
CONTROLLER_RC=$?
set -e

stop_diag
ssh -o BatchMode=yes -o ConnectTimeout=10 root@tinyman "test -f '$REMOTE_BUSY'" >/dev/null 2>&1 && scp -q -o BatchMode=yes -o ConnectTimeout=15 "root@tinyman:$REMOTE_BUSY" "$OUTPUT_DIR/cpu_busy_client.csv" || true
ssh -o BatchMode=yes -o ConnectTimeout=10 root@tinyman "test -f '$REMOTE_QJSON'" >/dev/null 2>&1 && scp -q -o BatchMode=yes -o ConnectTimeout=15 "root@tinyman:$REMOTE_QJSON" "$OUTPUT_DIR/quic_runtime_allcpus_client.json" || true
ssh -o BatchMode=yes -o ConnectTimeout=10 root@tinyman "test -f '$REMOTE_QCSV'" >/dev/null 2>&1 && scp -q -o BatchMode=yes -o ConnectTimeout=15 "root@tinyman:$REMOTE_QCSV" "$OUTPUT_DIR/quic_runtime_allcpus_client.csv" || true
ssh -o BatchMode=yes -o ConnectTimeout=10 root@tinyman "cat '$REMOTE_QLOG' 2>/dev/null || true; rm -f '$REMOTE_BUSY' '$REMOTE_QJSON' '$REMOTE_QCSV' '$REMOTE_QLOG'" >"$OUTPUT_DIR/quic_runtime_allcpus_client.log" 2>&1 || true

# Authoritative traffic verdict: every repetition must contain a successful 4-connection batch marker.
TRAFFIC_RC=0
MISSING=""
for ((rep=1; rep<=RUNS; rep++)); do
    rid="rep$(printf '%02d' "$rep")_off"
    logf="$(find "$OUTPUT_DIR" -maxdepth 2 -type f -name "client_${rid}.log" -o -name "client_${rid}*.log" 2>/dev/null | head -n1)"
    if [[ -z "$logf" || ! -f "$logf" ]]; then
        TRAFFIC_RC=20; MISSING+=" $rid(no-log)"; continue
    fi
    if ! grep -E "\\[GreenQUIC-PARALLEL\\] batch=1 complete_us=.* connections=${CONNECTIONS} connected=${CONNECTIONS} completed=${CONNECTIONS} success=1" "$logf" >/dev/null 2>&1; then
        TRAFFIC_RC=20; MISSING+=" $rid(no-success-marker)"
    fi
done

ANALYSIS_RC=0
if (( TRAFFIC_RC == 0 )); then
    set +e
    python3 "$ANALYZE" --case-dir "$OUTPUT_DIR" --case-name "$CASE_NAME" --runs "$RUNS" --connections "$CONNECTIONS" --dpdk-cpus "$DPDK_LCORES" --all-cpus "$BUSY_CPUS"
    ANALYSIS_RC=$?
    set -e
else
    ANALYSIS_RC=125
fi

cat > "$OUTPUT_DIR/ARCH_CASE_STATUS.env" <<EOF
case=$CASE_NAME
runs=$RUNS
connections=$CONNECTIONS
dpdk_lcores=$DPDK_LCORES
quic_cpus=$QUIC_CPUS
partition_map=$PARTITION_MAP
quic_affinitize=$QUIC_AFFINITIZE
execution_profile=$EXEC_PROFILE
controller_rc=$CONTROLLER_RC
traffic_rc=$TRAFFIC_RC
analysis_rc=$ANALYSIS_RC
missing_or_failed_batches=${MISSING# }
EOF

if (( TRAFFIC_RC != 0 )); then
    echo "P5 ARCH V4 TRAFFIC FAIL case=$CASE_NAME controller_rc=$CONTROLLER_RC missing=$MISSING" >&2
    exit "$TRAFFIC_RC"
fi
if (( CONTROLLER_RC != 0 )); then
    echo "WARN: case=$CASE_NAME traffic PASS but controller/post-processing rc=$CONTROLLER_RC; preserving traffic and continuing" >&2
fi
if (( ANALYSIS_RC != 0 )); then
    echo "WARN: case=$CASE_NAME traffic PASS but analyzer rc=$ANALYSIS_RC; raw traffic remains valid" >&2
fi

echo "P5 ARCH V4 TRAFFIC PASS case=$CASE_NAME controller_rc=$CONTROLLER_RC analysis_rc=$ANALYSIS_RC results=$OUTPUT_DIR"
exit 0
