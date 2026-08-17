#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
BASE="$HERE/run_p5_arch_off_case.sh"
THREAD="$HERE/thread_topology_sampler.py"
QUIC="$HERE/quic_cpu_activity_sampler.py"
VERIFY="$HERE/verify_p5_arch_effective_config.py"
OUTPUT=""; CASE=""; QCPUS="21,22,23,24"; DCPUS="19,20"; ARGS=("$@")
for ((i=0;i<${#ARGS[@]};i++)); do
    case "${ARGS[$i]}" in
        --output-dir) OUTPUT="${ARGS[$((i+1))]}";;
        --case-name) CASE="${ARGS[$((i+1))]}";;
        --quic-cpus) QCPUS="${ARGS[$((i+1))]}";;
        --dpdk-lcores) DCPUS="${ARGS[$((i+1))]}";;
    esac
done
[[ -f "$BASE" && -f "$THREAD" && -f "$QUIC" && -f "$VERIFY" && -n "$OUTPUT" ]] || { echo 'ERROR: arch diagnostic/config dependencies/output' >&2; exit 2; }
python3 -m py_compile "$THREAD" "$QUIC" "$VERIFY"
mkdir -p "$OUTPUT"
SBIN=/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinteropserver
CBIN=/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop
ALL_CPUS="$(printf '%s\n' "$DCPUS,$QCPUS" | tr ',' '\n' | sed '/^$/d' | sort -n -u | paste -sd, -)"
TAG="p5arch_${CASE}_$$_$(date +%s%N)"
SP=""; SQ=""; CP=""; CQ=""; PS=""; PC=""
R_TJ="/tmp/${TAG}_thread.json"; R_TC="/tmp/${TAG}_thread.csv"; R_TL="/tmp/${TAG}_thread.log"
R_QJ="/tmp/${TAG}_quic.json"; R_QC="/tmp/${TAG}_quic.csv"; R_QL="/tmp/${TAG}_quic.log"
R_PS="/tmp/${TAG}_perf_stat.txt"; R_PL="/tmp/${TAG}_perf_stat.log"
PERF_EVENTS="cycles,instructions,cache-references,cache-misses,branches,branch-misses,context-switches,cpu-migrations,page-faults"

stop(){
    [[ -n "$SP" ]] && { kill -TERM "$SP" 2>/dev/null || true; wait "$SP" 2>/dev/null || true; SP=""; }
    [[ -n "$SQ" ]] && { kill -TERM "$SQ" 2>/dev/null || true; wait "$SQ" 2>/dev/null || true; SQ=""; }
    if [[ -n "$PS" ]]; then
        kill -INT "$PS" 2>/dev/null || true
        for _ in $(seq 1 100); do kill -0 "$PS" 2>/dev/null || break; sleep 0.05; done
        kill -TERM "$PS" 2>/dev/null || true
        wait "$PS" 2>/dev/null || true
        PS=""
    fi
    for p in "$CP" "$CQ"; do
        if [[ -n "$p" ]]; then
            ssh -o BatchMode=yes -o ConnectTimeout=8 root@tinyman \
                "kill -TERM '$p' 2>/dev/null || true; for i in \$(seq 1 100); do kill -0 '$p' 2>/dev/null || exit 0; sleep 0.05; done; exit 0" \
                >/dev/null 2>&1 || true
        fi
    done
    if [[ -n "$PC" ]]; then
        ssh -o BatchMode=yes -o ConnectTimeout=8 root@tinyman \
            "kill -INT '$PC' 2>/dev/null || true; for i in \$(seq 1 100); do kill -0 '$PC' 2>/dev/null || exit 0; sleep 0.05; done; kill -TERM '$PC' 2>/dev/null || true; exit 0" \
            >/dev/null 2>&1 || true
    fi
    CP=""; CQ=""; PC=""
}
trap 'rc=$?; trap - EXIT INT TERM; stop; exit $rc' EXIT INT TERM

# GREENQUIC-P5-ARCH-FRESH-CONFIG-EVIDENCE-V1
# A case may fail before the peer application starts. Never let a dpdk.ini from
# an earlier case masquerade as current-case effective-config evidence.
rm -f "$HERE/runtime/server/dpdk.ini"
ssh -o BatchMode=yes -o ConnectTimeout=12 root@tinyman \
    "rm -f '$HERE/runtime/client/dpdk.ini'" >/dev/null 2>&1 || true

# Diagnostics are evidence only. Failure to start any sampler must not block traffic.
set +e
python3 "$THREAD" --binary "$SBIN" --json "$OUTPUT/thread_topology_server.json" --csv "$OUTPUT/thread_topology_server.csv" --interval-ms 20 >"$OUTPUT/thread_topology_server.log" 2>&1 & SP=$!
python3 "$QUIC" --binary "$SBIN" --cpus "$QCPUS" --json "$OUTPUT/quic_cpu_activity_server.json" --csv "$OUTPUT/quic_cpu_activity_server.csv" --interval-ms 10 >"$OUTPUT/quic_cpu_activity_server.log" 2>&1 & SQ=$!
CP="$(ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman "rm -f '$R_TJ' '$R_TC' '$R_TL'; nohup python3 '$THREAD' --binary '$CBIN' --json '$R_TJ' --csv '$R_TC' --interval-ms 20 >'$R_TL' 2>&1 </dev/null & echo \$!" 2>/dev/null)"
CQ="$(ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman "rm -f '$R_QJ' '$R_QC' '$R_QL'; nohup python3 '$QUIC' --binary '$CBIN' --cpus '$QCPUS' --json '$R_QJ' --csv '$R_QC' --interval-ms 10 >'$R_QL' 2>&1 </dev/null & echo \$!" 2>/dev/null)"

if command -v perf >/dev/null 2>&1; then
    perf stat -a -C "$ALL_CPUS" -e "$PERF_EVENTS" -o "$OUTPUT/perf_stat_server_selected_cpus.txt" \
        >"$OUTPUT/perf_stat_server_selected_cpus.log" 2>&1 & PS=$!
    sleep 0.10
    if ! kill -0 "$PS" 2>/dev/null; then
        wait "$PS" 2>/dev/null || true
        PS=""
        echo 'WARN: server perf stat unavailable; traffic will continue' >&2
    fi
else
    echo 'WARN: perf not installed on server; traffic will continue' >&2
fi
PC="$(ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman \
    "rm -f '$R_PS' '$R_PL'; if command -v perf >/dev/null 2>&1; then nohup perf stat -a -C '$ALL_CPUS' -e '$PERF_EVENTS' -o '$R_PS' >'$R_PL' 2>&1 </dev/null & echo \$!; fi" 2>/dev/null)"
set -e
[[ "$CP" =~ ^[0-9]+$ ]]||{ echo 'WARN: client thread sampler unavailable' >&2; CP=""; }
[[ "$CQ" =~ ^[0-9]+$ ]]||{ echo 'WARN: client quic sampler unavailable' >&2; CQ=""; }
[[ "$PC" =~ ^[0-9]+$ ]]||{ echo 'WARN: client perf stat unavailable' >&2; PC=""; }

set +e
bash "$BASE" "$@"
RC=$?
set -e
stop

# Preserve the exact generated runtime topology used by both endpoints before
# any later case can overwrite runtime/{server,client}/dpdk.ini. The verifier
# operates only on the immutable per-case result directory.
CFG_DIR="$OUTPUT/effective_config"
mkdir -p "$CFG_DIR/server" "$CFG_DIR/client"
if [[ -f "$HERE/runtime/server/dpdk.ini" ]]; then
    cp -f "$HERE/runtime/server/dpdk.ini" "$CFG_DIR/server/server_dpdk.ini"
    echo "P5 ARCH CONFIG SNAPSHOT server=$CFG_DIR/server/server_dpdk.ini"
else
    echo "WARN: server runtime dpdk.ini missing after case $CASE" >&2
fi
if scp -q -o BatchMode=yes -o ConnectTimeout=12 \
    root@tinyman:"$HERE/runtime/client/dpdk.ini" \
    "$CFG_DIR/client/client_dpdk.ini" 2>/dev/null; then
    echo "P5 ARCH CONFIG SNAPSHOT client=$CFG_DIR/client/client_dpdk.ini"
else
    echo "WARN: client runtime dpdk.ini snapshot unavailable after case $CASE" >&2
fi

for spec in "$R_TJ:thread_topology_client.json" "$R_TC:thread_topology_client.csv" "$R_QJ:quic_cpu_activity_client.json" "$R_QC:quic_cpu_activity_client.csv" "$R_PS:perf_stat_client_selected_cpus.txt"; do
    r=${spec%%:*}; l=${spec#*:}; scp -q -o BatchMode=yes -o ConnectTimeout=12 root@tinyman:"$r" "$OUTPUT/$l" 2>/dev/null||true
done
ssh -o BatchMode=yes -o ConnectTimeout=8 root@tinyman \
    "cat '$R_TL' 2>/dev/null||true; cat '$R_QL' 2>/dev/null||true; cat '$R_PL' 2>/dev/null||true; rm -f '$R_TJ' '$R_TC' '$R_TL' '$R_QJ' '$R_QC' '$R_QL' '$R_PS' '$R_PL'" \
    >"$OUTPUT/client_diagnostic_sampler.log" 2>&1||true

python3 - "$OUTPUT" <<'PY' || true
import json,sys
from pathlib import Path
r=Path(sys.argv[1])
for role in ('server','client'):
 p=r/f'thread_topology_{role}.json'
 if not p.exists(): print(f'THREAD TOPOLOGY {role}: MISSING'); continue
 try:j=json.loads(p.read_text())
 except Exception as e: print(f'THREAD TOPOLOGY {role}: INVALID {e}'); continue
 top=sorted(j.get('threads',[]),key=lambda x:float(x.get('cpu_time_s',0)),reverse=True)[:12]
 print(f"THREAD TOPOLOGY {role}: active={j.get('active_threads')} total_cpu={j.get('total_cpu_time_s',0):.3f}s")
 for x in top: print(f"  tid={x.get('tid')} comm={x.get('comm')} cpu_s={x.get('cpu_time_s',0):.3f} cpus={x.get('cpus_seen')} allowed={x.get('allowed')}")
PY

# Scientific-validity check is separate from transport success. A successful
# QUIC transfer remains traffic PASS even if the requested topology was not
# actually materialized; such a case is marked CONFIG FAIL and excluded from
# causal interpretation by the summary.
CONFIG_RC=125
STATUS_FILE="$OUTPUT/ARCH_CASE_STATUS.env"
if [[ -f "$STATUS_FILE" ]]; then
    traffic_rc="$(awk -F= '$1=="traffic_rc"{print $2}' "$STATUS_FILE" | tail -1)"
    if [[ "$traffic_rc" == 0 ]]; then
        dpdk="$(awk -F= '$1=="dpdk_lcores"{print $2}' "$STATUS_FILE" | tail -1)"
        quic="$(awk -F= '$1=="quic_cpus"{print $2}' "$STATUS_FILE" | tail -1)"
        pmap="$(awk -F= '$1=="partition_map"{print $2}' "$STATUS_FILE" | tail -1)"
        execp="$(awk -F= '$1=="execution_profile"{print $2}' "$STATUS_FILE" | tail -1)"
        aff="$(awk -F= '$1=="quic_affinitize"{print $2}' "$STATUS_FILE" | tail -1)"
        multi="$(awk -F= '$1=="enable_multicore"{print $2}' "$STATUS_FILE" | tail -1)"
        set +e
        python3 "$VERIFY" \
            --case-dir "$OUTPUT" \
            --dpdk-lcores "$dpdk" \
            --quic-cpus "$quic" \
            --partition-map "$pmap" \
            --affinitize "$aff" \
            --execution-profile "$execp" \
            --enable-multicore "$multi"
        CONFIG_RC=$?
        set -e
    fi
    if grep -q '^config_rc=' "$STATUS_FILE"; then
        python3 - "$STATUS_FILE" "$CONFIG_RC" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); rc=sys.argv[2]
rows=p.read_text().splitlines()
rows=[f'config_rc={rc}' if x.startswith('config_rc=') else x for x in rows]
p.write_text('\n'.join(rows)+'\n')
PY
    else
        printf 'config_rc=%s\n' "$CONFIG_RC" >>"$STATUS_FILE"
    fi
else
    echo 'WARN: ARCH_CASE_STATUS.env missing; cannot verify effective runtime topology' >&2
fi

if ((CONFIG_RC==0)); then
    echo "P5 ARCH EFFECTIVE TOPOLOGY PASS case=$CASE"
elif ((RC==0)); then
    echo "WARN: P5 ARCH EFFECTIVE TOPOLOGY FAIL case=$CASE config_rc=$CONFIG_RC; traffic remains PASS" >&2
fi

echo "P5 ARCH DIAGNOSTICS COMPLETE case=$CASE traffic_rc=$RC config_rc=$CONFIG_RC"
exit "$RC"
