#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
CORE="$HERE/run_matrix_from_idex_core.sh"
PUBLIC="$HERE/run_matrix_from_idex.sh"
CLOCK_PAR="$HERE/clock_sync_parallel.py"
CPU_BUSY="$HERE/cpu_busy_sampler.py"
ANALYZE="$HERE/analyze_p5_bottleneck_case.py"
RUNS=2; CONNECTIONS=4; OUTPUT_DIR=""; CASE_NAME=""
DPDK_LCORES="19,20"; QUIC_CPUS="21,22,23,24"; PARTITION_STYLE=balanced; EXEC_PROFILE=max_throughput; AFFINITIZE=1; PARTITION_OVERRIDE=""; SELF_TEST=0
while (($#)); do case "$1" in
 --runs) RUNS="${2:?}"; shift 2;; --connections) CONNECTIONS="${2:?}"; shift 2;;
 --output-dir) OUTPUT_DIR="${2:?}"; shift 2;; --case-name) CASE_NAME="${2:?}"; shift 2;;
 --dpdk-lcores) DPDK_LCORES="${2:?}"; shift 2;; --quic-cpus) QUIC_CPUS="${2:?}"; shift 2;;
 --partition-style) PARTITION_STYLE="${2:?}"; shift 2;; --partition-map) PARTITION_OVERRIDE="${2:?}"; shift 2;; --execution-profile) EXEC_PROFILE="${2:?}"; shift 2;; --affinitize) AFFINITIZE="${2:?}"; shift 2;; --self-test) SELF_TEST=1; shift;;
 *) echo "ERROR: unknown option $1" >&2; exit 2;; esac; done
[[ "$RUNS" =~ ^[1-9][0-9]*$ && "$CONNECTIONS" =~ ^[2-9][0-9]*$ ]] || { echo 'ERROR: invalid runs/connections' >&2; exit 2; }
if ((SELF_TEST==0)); then [[ -n "$CASE_NAME" && -n "$OUTPUT_DIR" ]] || { echo 'ERROR: case/output required' >&2; exit 2; }; fi
[[ "$DPDK_LCORES" =~ ^[0-9]+(,[0-9]+)*$ && "$QUIC_CPUS" =~ ^[0-9]+(,[0-9]+)*$ ]] || { echo 'ERROR: invalid CPU list' >&2; exit 2; }
case "$PARTITION_STYLE" in balanced|grouped|all_first) ;; *) echo 'ERROR: partition-style balanced|grouped|all_first' >&2; exit 2;; esac
case "$EXEC_PROFILE" in max_throughput|low_latency) ;; *) echo 'ERROR: execution-profile max_throughput|low_latency' >&2; exit 2;; esac
[[ "$AFFINITIZE" == 0 || "$AFFINITIZE" == 1 ]] || { echo 'ERROR: affinitize 0|1' >&2; exit 2; }
for f in "$CORE" "$PUBLIC" "$CLOCK_PAR" "$CPU_BUSY" "$ANALYZE"; do [[ -f "$f" ]] || { echo "ERROR missing $f" >&2; exit 2; }; done
python3 -m py_compile "$CPU_BUSY" "$ANALYZE" "$CLOCK_PAR"; python3 "$CLOCK_PAR" --self-test >/dev/null
((SELF_TEST==1)) || mkdir -p "$OUTPUT_DIR"
OFF_CORE="$(mktemp "$HERE/.arch_off_core.XXXXXX.sh")"; OFF_PUBLIC="$(mktemp "$HERE/.arch_off_public.XXXXXX.sh")"
SERVER_BUSY_PID=""; CLIENT_BUSY_PID=""; REMOTE_BUSY="/tmp/p5_arch_busy_${CASE_NAME}_$$_client.csv"
cleanup(){ local rc=$?; trap - EXIT INT TERM; [[ -n "$SERVER_BUSY_PID" ]] && { kill -TERM "$SERVER_BUSY_PID" 2>/dev/null||true; wait "$SERVER_BUSY_PID" 2>/dev/null||true; }; [[ -n "$CLIENT_BUSY_PID" ]] && ssh -o BatchMode=yes -o ConnectTimeout=8 root@tinyman "kill -TERM '$CLIENT_BUSY_PID' 2>/dev/null||true" >/dev/null 2>&1||true; rm -f "$OFF_CORE" "$OFF_PUBLIC"; exit "$rc"; }; trap cleanup EXIT INT TERM
python3 - "$CORE" "$OFF_CORE" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
R=[('MODE_ORDER="balanced"','MODE_ORDER="off"'),('modes = ("off", "basic", "plus")','modes = ("off",)'),('if len(order) != 3 or set(order) != set(modes):','if len(order) != len(modes) or set(order) != set(modes):'),('raise SystemExit("ERROR: fixed --mode-order must contain off,basic,plus exactly once")','raise SystemExit("ERROR: architecture OFF controller requires --mode-order off")'),('TOTAL_TESTS=$((RUNS * 3))','TOTAL_TESTS=$RUNS'),('position=$position/3 mode=$mode','position=$position/1 mode=$mode'),('POSITION $position/3 | MODE=$mode','POSITION $position/1 | MODE=$mode'),('python3 "$HERE/p5_finalize_matrix.py" --matrix "$OUTPUT_DIR"','echo "[P5-ARCH] OFF-only case: skipping normal OFF/BASIC/PLUS finalizer"')]
for o,n in R:
 c=s.count(o)
 if c!=1: raise SystemExit(f'ERROR OFF anchor {o[:30]} count={c}')
 s=s.replace(o,n,1)
Path(sys.argv[2]).write_text(s)
PY
chmod 700 "$OFF_CORE"; bash -n "$OFF_CORE"
python3 - "$PUBLIC" "$OFF_PUBLIC" "$OFF_CORE" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text(); core=Path(sys.argv[3])
def one(o,n,label):
 global s
 c=s.count(o)
 if c!=1: raise SystemExit(f'ERROR {label} count={c}')
 s=s.replace(o,n,1)
one('CORE="$HERE/run_matrix_from_idex_core.sh"',f'CORE="$HERE/{core.name}"','core')
if './run_client.sh' not in s: raise SystemExit('ERROR client anchor')
s=s.replace('./run_client.sh','bash ./run_client_parallel_multicore.sh')
one('python3 "$HERE/clock_sync.py"','python3 "$HERE/clock_sync_parallel.py"','clock')
needle='Path(sys.argv[2]).write_text(src, encoding="utf-8")'
if needle not in s: raise SystemExit('ERROR public write anchor')
old='''    final_download_pattern="[GreenQUIC-P5] request=${DOWNLOADS}/${DOWNLOADS} complete_us="\n    workload_complete=0\n    while kill -0 "$client_pipeline_pid" 2>/dev/null; do\n        if grep -F "$final_download_pattern" "$client_log" 2>/dev/null | tail -n1 | grep -Fq 'success=1'; then\n            workload_complete=1\n            break\n        fi\n        sleep 0.1\n    done\n'''
new='''    final_download_pattern="[GreenQUIC-PARALLEL] batch=1 complete_us="\n    workload_complete=0\n    while kill -0 "$client_pipeline_pid" 2>/dev/null; do\n        if grep -E "\\[GreenQUIC-PARALLEL\\] batch=1 complete_us=.* connections=${DOWNLOADS} connected=${DOWNLOADS} completed=${DOWNLOADS} success=1" "$client_log" 2>/dev/null | tail -n1 | grep -q .; then\n            workload_complete=1\n            break\n        fi\n        sleep 0.1\n    done\n'''
inj="# P5-ARCH-PARALLEL-COMPLETION-V1\nparallel_old = "+repr(old)+"\nparallel_new = "+repr(new)+"\nreplace_once(parallel_old, parallel_new, \"parallel completion detector\")\n"+needle
s=s.replace(needle,inj,1); Path(sys.argv[2]).write_text(s)
PY
chmod 700 "$OFF_PUBLIC"; bash -n "$OFF_PUBLIC"
if ((SELF_TEST==1)); then
    bash "$OFF_PUBLIC" --help >/dev/null
    echo "P5 ARCH OFF CASE SELF-TEST PASS"
    exit 0
fi
IFS=',' read -r -a DPA <<< "$DPDK_LCORES"; IFS=',' read -r -a QPA <<< "$QUIC_CPUS"; ND=${#DPA[@]}; NQ=${#QPA[@]}
((ND>=1 && NQ>=1)) || exit 2
# The architecture build supports one-or-more DPDK owners. Keep its multicore
# queue/statistics path enabled even for F/N with one owner so the experiment
# emits the same direct lcore RX/TX packet evidence as the 2D/4D cases.
MULTI=1
PARTITION_MAP="$PARTITION_OVERRIDE"
if [[ -z "$PARTITION_MAP" ]]; then
 for ((p=0;p<NQ;p++)); do
  case "$PARTITION_STYLE" in
   balanced) cpu="${DPA[$((p%ND))]}";;
   grouped) idx=$((p*ND/NQ)); ((idx>=ND))&&idx=$((ND-1)); cpu="${DPA[$idx]}";;
   all_first) cpu="${DPA[0]}";;
  esac
  [[ -z "$PARTITION_MAP" ]]||PARTITION_MAP+=","; PARTITION_MAP+="$p:$cpu"
 done
fi
ALL_CPUS="$(printf '%s\n' "$DPDK_LCORES,$QUIC_CPUS" | tr ',' '\n' | sort -n -u | paste -sd, -)"
TX_OWNER="${DPA[0]}"
export P5_PARALLEL_CONNECTIONS="$CONNECTIONS" P5_PARALLEL_LOCAL_PORT_BASE=45000
TOPO=(--env ENABLE_MULTICORE="$MULTI" --env SERVER_DPDK_LCORES="$DPDK_LCORES" --env CLIENT_DPDK_LCORES="$DPDK_LCORES" --env SERVER_QUIC_CPUS="$QUIC_CPUS" --env CLIENT_QUIC_CPUS="$QUIC_CPUS" --env SERVER_PARTITION_MAP="$PARTITION_MAP" --env CLIENT_PARTITION_MAP="$PARTITION_MAP" --env SERVER_TX_OWNER_LCORE="$TX_OWNER" --env CLIENT_TX_OWNER_LCORE="$TX_OWNER" --env GREENQUIC_TX_OWNER_ALSO_RX=1 --env P5_PARALLEL_CONNECTIONS="$CONNECTIONS" --env P5_PARALLEL_LOCAL_PORT_BASE=45000 --env ENABLE_RECORD=1 --env ENABLE_CSTATE_RECORD=1 --env GQ_MSR_SAMPLE_INTERVAL_MS=6 --env GQ_FREQ_SAMPLE_INTERVAL_MS=1 --env MSQUIC_EXECUTION_PROFILE="$EXEC_PROFILE" --env MSQUIC_QUIC_AFFINITIZE="$AFFINITIZE")

# Diagnostics must never gate QUIC traffic.
set +e
python3 "$CPU_BUSY" --cpus "$ALL_CPUS" --interval-ms 20 --output "$OUTPUT_DIR/cpu_busy_server.csv" >"$OUTPUT_DIR/cpu_busy_server_sampler.log" 2>&1 & SERVER_BUSY_PID=$!
CLIENT_BUSY_PID="$(ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman "rm -f '$REMOTE_BUSY'; nohup python3 '$CPU_BUSY' --cpus '$ALL_CPUS' --interval-ms 20 --output '$REMOTE_BUSY' >/tmp/p5_arch_busy_${CASE_NAME}_$$.log 2>&1 </dev/null & echo \$!" 2>/dev/null)"
set -e
if [[ ! "$CLIENT_BUSY_PID" =~ ^[0-9]+$ ]]; then
    echo 'WARN: client CPU-busy sampler unavailable; traffic will continue' >&2
    CLIENT_BUSY_PID=""
fi

set +e
bash "$OFF_PUBLIC" --runs "$RUNS" --downloads "$CONNECTIONS" --gap-seconds 0 --server-cooldown-seconds 5 --between-tests-seconds 5 --mode-order off --seed 20260817 --output-dir "$OUTPUT_DIR" "${TOPO[@]}"
CONTROLLER_RC=$?
set -e
kill -TERM "$SERVER_BUSY_PID" 2>/dev/null||true; wait "$SERVER_BUSY_PID" 2>/dev/null||true; SERVER_BUSY_PID=""
if [[ -n "$CLIENT_BUSY_PID" ]]; then
    ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman "kill -TERM '$CLIENT_BUSY_PID' 2>/dev/null||true; for i in \$(seq 1 100); do kill -0 '$CLIENT_BUSY_PID' 2>/dev/null||exit 0; sleep .1; done; exit 0" >/dev/null 2>&1||true
    CLIENT_BUSY_PID=""
fi
scp -q -o BatchMode=yes -o ConnectTimeout=15 root@tinyman:"$REMOTE_BUSY" "$OUTPUT_DIR/cpu_busy_client.csv" || true
SUCCESS_LOGS=0
for f in "$OUTPUT_DIR"/client_rep*_off.log; do [[ -f "$f" ]]||continue; grep -Eq "\\[GreenQUIC-PARALLEL\\] batch=1 complete_us=.* connections=$CONNECTIONS connected=$CONNECTIONS completed=$CONNECTIONS success=1" "$f" && SUCCESS_LOGS=$((SUCCESS_LOGS+1)); done
GOODPUT_FILES="$(find "$OUTPUT_DIR" -type f -name 'goodput_parallel_off_*.json' 2>/dev/null | wc -l | tr -d ' ')"
TRAFFIC_RC=1
if ((SUCCESS_LOGS>=RUNS)); then TRAFFIC_RC=0; fi
if ((CONTROLLER_RC!=0 && TRAFFIC_RC==0)); then echo "WARN: controller_rc=$CONTROLLER_RC after all $RUNS traffic repetitions completed; treating as POSTPROCESS failure" >&2; fi
ANALYSIS_RC=125
if ((TRAFFIC_RC==0)); then
 set +e; python3 "$ANALYZE" --case-dir "$OUTPUT_DIR" --case-name "$CASE_NAME" --runs "$RUNS" --connections "$CONNECTIONS" --dpdk-cpus "$DPDK_LCORES" --all-cpus "$ALL_CPUS"; ANALYSIS_RC=$?; set -e
 ((ANALYSIS_RC==0)) || echo "WARN: analysis rc=$ANALYSIS_RC; traffic remains PASS" >&2
fi
cat >"$OUTPUT_DIR/ARCH_CASE_STATUS.env" <<EOF
case=$CASE_NAME
runs=$RUNS
connections=$CONNECTIONS
dpdk_lcores=$DPDK_LCORES
quic_cpus=$QUIC_CPUS
partition_style=$PARTITION_STYLE
partition_map=$PARTITION_MAP
execution_profile=$EXEC_PROFILE
quic_affinitize=$AFFINITIZE
enable_multicore=$MULTI
controller_rc=$CONTROLLER_RC
traffic_success_logs=$SUCCESS_LOGS
goodput_files=$GOODPUT_FILES
traffic_rc=$TRAFFIC_RC
analysis_rc=$ANALYSIS_RC
EOF
if ((TRAFFIC_RC==0)); then echo "P5 ARCH CASE TRAFFIC PASS case=$CASE_NAME controller_rc=$CONTROLLER_RC analysis_rc=$ANALYSIS_RC"; else echo "P5 ARCH CASE TRAFFIC FAIL case=$CASE_NAME controller_rc=$CONTROLLER_RC success_logs=$SUCCESS_LOGS goodput=$GOODPUT_FILES" >&2; fi
exit "$TRAFFIC_RC"
