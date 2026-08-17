#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
BASE="$HERE/run_parallel_multicore_matrix.sh"
BUILD="$HERE/build_p5_multicore_performance2.sh"
ANALYZE="$HERE/analyze_p5_dpdk_lcore_activity.py"

[[ -f "$BASE" && -x "$BUILD" && -f "$ANALYZE" ]] || {
    echo "ERROR: P5 fair-run dependencies missing" >&2
    exit 2
}
python3 -m py_compile "$ANALYZE"

# Controller preflight must remain traffic/NIC/build free.
for arg in "$@"; do
    if [[ "$arg" == "--controller-preflight" ]]; then
        exec bash "$BASE" "$@"
    fi
done

RUNS=2
OUTPUT_DIR=""
args=("$@")
for ((i=0; i<${#args[@]}; ++i)); do
    case "${args[$i]}" in
        --runs) RUNS="${args[$((i+1))]}" ;;
        --output-dir) OUTPUT_DIR="${args[$((i+1))]}" ;;
    esac
done
[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: invalid --runs=$RUNS" >&2; exit 2; }
[[ -n "$OUTPUT_DIR" ]] || { echo "ERROR: fair P5 runner requires explicit --output-dir" >&2; exit 2; }

# Build both endpoints from the same synced commit. The build verifier requires
# the queue and lcore runtime markers, so stale binaries cannot enter traffic.
echo "P5 FAIR: building verified multicore binary with per-lcore RX/TX evidence on IDEX"
bash "$BUILD"
echo "P5 FAIR: building verified multicore binary with per-lcore RX/TX evidence on Tinyman"
ssh -o BatchMode=yes -o ConnectTimeout=20 root@tinyman "cd '$HERE' && bash ./build_p5_multicore_performance2.sh"
echo "P5 FAIR: compiled runtime contract PASS on IDEX + Tinyman"

TMP="$(mktemp "$HERE/.run_parallel_multicore_fair.XXXXXX.sh")"
trap 'rm -f "$TMP"' EXIT
python3 - "$BASE" "$TMP" <<'PY'
from pathlib import Path
import sys
src=Path(sys.argv[1]).read_text(encoding='utf-8')

# QUIC worker utilization is diagnostic. The configured worker set is fixed,
# but the scheduler is not required to execute on every allowed CPU every run.
old="if j.get('status')!='PASS': raise SystemExit(f\"ERROR: P5 {label} did not execute on every requested QUIC CPU\")"
new="if j.get('status')!='PASS': print(f\"WARN: P5 {label} did not execute on every configured QUIC CPU; continuing because this is diagnostic only\")"
if src.count(old)!=1:
    raise SystemExit(f'ERROR: P5 QUIC activity gate anchor count={src.count(old)}')
src=src.replace(old,new,1)

# Keep the legacy topology/recording output, but do not make it erase traffic.
old='python3 "$VALIDATOR" --matrix "$OUTPUT_DIR" --runs "$RUNS"\n'
new='python3 "$VALIDATOR" --matrix "$OUTPUT_DIR" --runs "$RUNS" || echo "WARN: P5 topology/recording validation failed; preserving results"\n'
if src.count(old)!=1:
    raise SystemExit(f'ERROR: P5 validator anchor count={src.count(old)}')
src=src.replace(old,new,1)

# Legacy directional queue validation required server TXQ0/TXQ1 and client
# RXQ0/RXQ1 independently. That can reject a busy lcore whose other direction
# is carrying the work. Preserve it as a diagnostic only.
old='if problems:raise SystemExit(\'ERROR: multicore queue-use validation failed:\\n  \'+\'\\n  \'.join(problems))'
new='if problems:print(\'WARN: legacy directional queue validation failed (nonfatal):\\n  \'+\'\\n  \'.join(problems))'
if src.count(old)!=1:
    raise SystemExit(f'ERROR: legacy queue gate anchor count={src.count(old)}')
src=src.replace(old,new,1)

# The base runner has one exact boundary: this command executes all P5 traffic.
# If it fails, the P5 traffic phase is failed. If it succeeds, every subsequent
# command is analysis/validation/reporting and must be nonfatal.
traffic_old='bash "$TMP" --runs "$RUNS" --downloads "$CONNECTIONS" --gap-seconds 0 --server-cooldown-seconds 5 --between-tests-seconds 5 --mode-order balanced --seed 20260817 --output-dir "$OUTPUT_DIR" "${TOPOLOGY_ENV[@]}" "${USER_ARGS[@]}"\n'
traffic_new='''set +e
bash "$TMP" --runs "$RUNS" --downloads "$CONNECTIONS" --gap-seconds 0 --server-cooldown-seconds 5 --between-tests-seconds 5 --mode-order balanced --seed 20260817 --output-dir "$OUTPUT_DIR" "${TOPOLOGY_ENV[@]}" "${USER_ARGS[@]}"
GREENQUIC_FAIR_TRAFFIC_RC=$?
if [[ "$GREENQUIC_FAIR_TRAFFIC_RC" != 0 ]]; then
    echo "P5 FAIR TRAFFIC FAIL rc=$GREENQUIC_FAIR_TRAFFIC_RC; preserving partial results" >&2
    exit "$GREENQUIC_FAIR_TRAFFIC_RC"
fi
# Traffic is complete. Do not let post-run diagnostics stop P7.
set +e
'''
if src.count(traffic_old)!=1:
    raise SystemExit(f'ERROR: P5 traffic boundary anchor count={src.count(traffic_old)}')
src=src.replace(traffic_old,traffic_new,1)

Path(sys.argv[2]).write_text(src,encoding='utf-8')
PY
chmod 0700 "$TMP"
bash -n "$TMP"

set +e
bash "$TMP" "$@"
TRAFFIC_RC=$?
set -e

mkdir -p "$OUTPUT_DIR"
if (( TRAFFIC_RC != 0 )); then
    python3 - "$OUTPUT_DIR" "$TRAFFIC_RC" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1]);rc=int(sys.argv[2])
(root/'P5_FAIRNESS_STATUS.json').write_text(json.dumps({
 'schema':'greenquic-p5-fairness-status-v1',
 'traffic_status':'FAIL','traffic_rc':rc,
 'fairness_status':'NOT_EVALUATED',
 'note':'P5 traffic/controller failed; top-level suite should still attempt P7.'
},indent=2)+'\n')
PY
    echo "P5 FAIR TRAFFIC FAIL rc=$TRAFFIC_RC; result directory preserved; top-level suite should continue to P7" >&2
    exit "$TRAFFIC_RC"
fi

set +e
python3 "$ANALYZE" --matrix "$OUTPUT_DIR" --runs "$RUNS"
DPDK_RC=$?
set -e

python3 - "$OUTPUT_DIR" "$DPDK_RC" <<'PY'
from pathlib import Path
import json,sys
root=Path(sys.argv[1]);dpdk_rc=int(sys.argv[2])
def load(name):
 p=root/name
 if not p.is_file(): return {'status':'MISSING'}
 try:return json.load(open(p,encoding='utf-8'))
 except Exception as e:return {'status':'INVALID','error':str(e)}

dpdk=load('dpdk_lcore_activity_validation.json')
topo=load('multicore_validation.json')
server=load('quic_cpu_activity_server.json')
client=load('quic_cpu_activity_client.json')
fair = 'PASS' if dpdk.get('status')=='PASS' and topo.get('status')=='PASS' else 'FAIL'
out={
 'schema':'greenquic-p5-fairness-status-v1',
 'traffic_status':'PASS','traffic_rc':0,
 'dpdk_lcore_activity_status':dpdk.get('status','UNKNOWN'),
 'topology_recording_status':topo.get('status','UNKNOWN'),
 'server_quic_cpu_activity_status':server.get('status','UNKNOWN'),
 'client_quic_cpu_activity_status':client.get('status','UNKNOWN'),
 'quic_cpu_activity_is_hard_gate':False,
 'fairness_status':fair,
 'power_note':'OFF-mode RAPL/frequency/C-state is a cross-check. Both DPDK CPUs are fixed to max in OFF, so power alone cannot prove packet work; per-lcore RX/TX counters are authoritative.',
 'dpdk_analyzer_rc':dpdk_rc,
}
(root/'P5_FAIRNESS_STATUS.json').write_text(json.dumps(out,indent=2)+'\n')
print('P5 FAIRNESS STATUS:',fair)
print('  traffic=PASS')
print('  DPDK per-lcore packet activity=',out['dpdk_lcore_activity_status'])
print('  topology/recording=',out['topology_recording_status'])
print('  QUIC CPU activity diagnostic: server=',out['server_quic_cpu_activity_status'],'client=',out['client_quic_cpu_activity_status'])
PY

echo "P5 FAIR PHASE COMPLETE: traffic completed; diagnostics preserved even if fairness status is FAIL"
exit 0
