#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
BASE="$HERE/run_p5_arch_off_case.sh"
THREAD="$HERE/thread_topology_sampler.py"
QUIC="$HERE/quic_cpu_activity_sampler.py"
OUTPUT=""; CASE=""; QCPUS="21,22,23,24"; ARGS=("$@")
for ((i=0;i<${#ARGS[@]};i++)); do case "${ARGS[$i]}" in --output-dir) OUTPUT="${ARGS[$((i+1))]}";; --case-name) CASE="${ARGS[$((i+1))]}";; --quic-cpus) QCPUS="${ARGS[$((i+1))]}";; esac; done
[[ -f "$BASE" && -f "$THREAD" && -f "$QUIC" && -n "$OUTPUT" ]] || { echo 'ERROR: arch diagnostic dependencies/output' >&2; exit 2; }
mkdir -p "$OUTPUT"
SBIN=/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinteropserver
CBIN=/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop
TAG="p5arch_${CASE}_$$_$(date +%s%N)"
SP=""; SQ=""; CP=""; CQ=""
R_TJ="/tmp/${TAG}_thread.json"; R_TC="/tmp/${TAG}_thread.csv"; R_TL="/tmp/${TAG}_thread.log"
R_QJ="/tmp/${TAG}_quic.json"; R_QC="/tmp/${TAG}_quic.csv"; R_QL="/tmp/${TAG}_quic.log"
stop(){
    [[ -n "$SP" ]] && { kill -TERM "$SP" 2>/dev/null || true; wait "$SP" 2>/dev/null || true; SP=""; }
    [[ -n "$SQ" ]] && { kill -TERM "$SQ" 2>/dev/null || true; wait "$SQ" 2>/dev/null || true; SQ=""; }
    for p in "$CP" "$CQ"; do
        if [[ -n "$p" ]]; then
            ssh -o BatchMode=yes -o ConnectTimeout=8 root@tinyman \
                "kill -TERM '$p' 2>/dev/null || true; for i in \$(seq 1 100); do kill -0 '$p' 2>/dev/null || exit 0; sleep 0.05; done; exit 0" \
                >/dev/null 2>&1 || true
        fi
    done
    CP=""; CQ=""
}
trap 'rc=$?; trap - EXIT INT TERM; stop; exit $rc' EXIT INT TERM
python3 "$THREAD" --binary "$SBIN" --json "$OUTPUT/thread_topology_server.json" --csv "$OUTPUT/thread_topology_server.csv" --interval-ms 20 >"$OUTPUT/thread_topology_server.log" 2>&1 & SP=$!
python3 "$QUIC" --binary "$SBIN" --cpus "$QCPUS" --json "$OUTPUT/quic_cpu_activity_server.json" --csv "$OUTPUT/quic_cpu_activity_server.csv" --interval-ms 10 >"$OUTPUT/quic_cpu_activity_server.log" 2>&1 & SQ=$!
set +e
CP="$(ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman "rm -f '$R_TJ' '$R_TC' '$R_TL'; nohup python3 '$THREAD' --binary '$CBIN' --json '$R_TJ' --csv '$R_TC' --interval-ms 20 >'$R_TL' 2>&1 </dev/null & echo \$!" 2>/dev/null)"
CQ="$(ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman "rm -f '$R_QJ' '$R_QC' '$R_QL'; nohup python3 '$QUIC' --binary '$CBIN' --cpus '$QCPUS' --json '$R_QJ' --csv '$R_QC' --interval-ms 10 >'$R_QL' 2>&1 </dev/null & echo \$!" 2>/dev/null)"
set -e
[[ "$CP" =~ ^[0-9]+$ ]]||{ echo 'WARN: client thread sampler unavailable' >&2; CP=""; }
[[ "$CQ" =~ ^[0-9]+$ ]]||{ echo 'WARN: client quic sampler unavailable' >&2; CQ=""; }
set +e; bash "$BASE" "$@"; RC=$?; set -e
stop
for spec in "$R_TJ:thread_topology_client.json" "$R_TC:thread_topology_client.csv" "$R_QJ:quic_cpu_activity_client.json" "$R_QC:quic_cpu_activity_client.csv"; do r=${spec%%:*}; l=${spec#*:}; scp -q -o BatchMode=yes -o ConnectTimeout=12 root@tinyman:"$r" "$OUTPUT/$l" 2>/dev/null||true; done
ssh -o BatchMode=yes -o ConnectTimeout=8 root@tinyman "cat '$R_TL' 2>/dev/null||true; cat '$R_QL' 2>/dev/null||true; rm -f '$R_TJ' '$R_TC' '$R_TL' '$R_QJ' '$R_QC' '$R_QL'" >"$OUTPUT/client_diagnostic_sampler.log" 2>&1||true
python3 - "$OUTPUT" <<'PY' || true
import json,sys
from pathlib import Path
r=Path(sys.argv[1])
for role in ('server','client'):
 p=r/f'thread_topology_{role}.json'
 if not p.exists(): print(f'THREAD TOPOLOGY {role}: MISSING'); continue
 try:j=json.loads(p.read_text())
 except Exception as e: print(f'THREAD TOPOLOGY {role}: INVALID {e}'); continue
 top=sorted(j.get('threads',[]),key=lambda x:float(x.get('cpu_time_s',0)),reverse=True)[:8]
 print(f"THREAD TOPOLOGY {role}: active={j.get('active_threads')} total_cpu={j.get('total_cpu_time_s',0):.3f}s")
 for x in top: print(f"  tid={x.get('tid')} comm={x.get('comm')} cpu_s={x.get('cpu_time_s',0):.3f} cpus={x.get('cpus_seen')} allowed={x.get('allowed')}")
PY
echo "P5 ARCH DIAGNOSTICS COMPLETE case=$CASE traffic_rc=$RC"
exit "$RC"
