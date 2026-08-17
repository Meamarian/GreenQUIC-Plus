#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
BASE="$HERE/run_parallel_multicore_matrix.sh"
[[ -f "$BASE" ]] || { echo "ERROR: missing $BASE" >&2; exit 2; }

for arg in "$@"; do
    if [[ "$arg" == "--controller-preflight" ]]; then
        exec bash "$BASE" "$@"
    fi
done

OUTPUT_DIR=""
args=("$@")
for ((i=0; i<${#args[@]}; ++i)); do
    case "${args[$i]}" in
        --output-dir) OUTPUT_DIR="${args[$((i+1))]}" ;;
    esac
done
[[ -n "$OUTPUT_DIR" ]] || { echo "ERROR: fair P7 runner requires explicit --output-dir" >&2; exit 2; }

TMP="$(mktemp "$HERE/.run_parallel_multicore_fair.XXXXXX.sh")"
trap 'rm -f "$TMP"' EXIT
python3 - "$BASE" "$TMP" <<'PY'
from pathlib import Path
import sys
src=Path(sys.argv[1]).read_text(encoding='utf-8')
old='bash "$TMP" "${USER_ARGS[@]}" "${FIXED[@]}"\n'
new='''set +e
bash "$TMP" "${USER_ARGS[@]}" "${FIXED[@]}"
GREENQUIC_FAIR_TRAFFIC_RC=$?
if [[ "$GREENQUIC_FAIR_TRAFFIC_RC" != 0 ]]; then
    echo "P7 FAIR TRAFFIC FAIL rc=$GREENQUIC_FAIR_TRAFFIC_RC; preserving partial results" >&2
    exit "$GREENQUIC_FAIR_TRAFFIC_RC"
fi
# Traffic is complete. Everything below is analysis/validation/reporting and is
# deliberately nonfatal so a diagnostic cannot erase the Linux comparison run.
set +e
'''
if src.count(old)!=1:
    raise SystemExit(f'ERROR: P7 traffic boundary anchor count={src.count(old)}')
src=src.replace(old,new,1)
Path(sys.argv[2]).write_text(src,encoding='utf-8')
PY
chmod 0700 "$TMP"
bash -n "$TMP"

set +e
bash "$TMP" "$@"
TRAFFIC_OR_PHASE_RC=$?
set -e
mkdir -p "$OUTPUT_DIR"

if (( TRAFFIC_OR_PHASE_RC != 0 )); then
    python3 - "$OUTPUT_DIR" "$TRAFFIC_OR_PHASE_RC" <<'PY'
from pathlib import Path
import json,sys
root=Path(sys.argv[1]);rc=int(sys.argv[2])
(root/'P7_FAIRNESS_STATUS.json').write_text(json.dumps({
 'schema':'greenquic-p7-fairness-status-v1','traffic_status':'FAIL','traffic_rc':rc,
 'fairness_status':'NOT_EVALUATED','note':'Linux traffic/controller phase failed; partial results preserved.'
},indent=2)+'\n')
PY
    exit "$TRAFFIC_OR_PHASE_RC"
fi

python3 - "$OUTPUT_DIR" <<'PY'
from pathlib import Path
import json,sys
root=Path(sys.argv[1])
def load(name):
 p=root/name
 if not p.is_file(): return {'status':'MISSING'}
 try:return json.load(open(p,encoding='utf-8'))
 except Exception as e:return {'status':'INVALID','error':str(e)}
irq=load('parallel_irq_activity_validation.json')
topo=load('multicore_validation.json')
server=load('quic_cpu_activity_server.json')
client=load('quic_cpu_activity_client.json')
fair='PASS' if irq.get('status')=='PASS' and topo.get('status')=='PASS' else 'FAIL'
out={
 'schema':'greenquic-p7-fairness-status-v1','traffic_status':'PASS','traffic_rc':0,
 'linux_dataplane_cpu_activity_status':irq.get('status','UNKNOWN'),
 'topology_recording_status':topo.get('status','UNKNOWN'),
 'server_quic_cpu_activity_status':server.get('status','UNKNOWN'),
 'client_quic_cpu_activity_status':client.get('status','UNKNOWN'),
 'quic_cpu_activity_is_hard_gate':False,
 'fairness_status':fair,
 'dataplane_note':'CPU19/CPU20 engagement is proven with pinned queue IRQ deltas plus NET_RX softirq deltas; QUIC worker utilization is diagnostic only.'
}
(root/'P7_FAIRNESS_STATUS.json').write_text(json.dumps(out,indent=2)+'\n')
print('P7 FAIRNESS STATUS:',fair)
print('  traffic=PASS')
print('  Linux CPU19/20 dataplane activity=',out['linux_dataplane_cpu_activity_status'])
print('  topology/recording=',out['topology_recording_status'])
print('  QUIC CPU activity diagnostic: server=',out['server_quic_cpu_activity_status'],'client=',out['client_quic_cpu_activity_status'])
PY

echo "P7 FAIR PHASE COMPLETE: Linux traffic completed; diagnostics preserved even if fairness status is FAIL"
exit 0
