#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
BASE="$HERE/run_p5_parallel_off_case.sh"
CPU_ACTIVITY="$HERE/quic_cpu_activity_sampler.py"

OUTPUT_DIR=""
CASE_NAME="unknown"
QUIC_CPUS="21,22,23,24"
ARGS=("$@")
for ((i=0; i<${#ARGS[@]}; i++)); do
    case "${ARGS[$i]}" in
        --output-dir)
            (( i + 1 < ${#ARGS[@]} )) && OUTPUT_DIR="${ARGS[$((i+1))]}"
            ;;
        --case-name)
            (( i + 1 < ${#ARGS[@]} )) && CASE_NAME="${ARGS[$((i+1))]}"
            ;;
        --quic-cpus)
            (( i + 1 < ${#ARGS[@]} )) && QUIC_CPUS="${ARGS[$((i+1))]}"
            ;;
    esac
done

[[ -f "$BASE" ]] || { echo "ERROR: missing base bottleneck case runner: $BASE" >&2; exit 2; }
[[ -f "$CPU_ACTIVITY" ]] || { echo "ERROR: missing QUIC CPU activity sampler: $CPU_ACTIVITY" >&2; exit 2; }
[[ -n "$OUTPUT_DIR" ]] || { echo "ERROR: --output-dir is required" >&2; exit 2; }
mkdir -p "$OUTPUT_DIR"

SERVER_BIN="/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinteropserver"
CLIENT_BIN="/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop"
SERVER_PID=""
CLIENT_PID=""
TAG="p5_bottleneck_quic_${CASE_NAME}_$$_$(date +%s%N)"
REMOTE_JSON="/tmp/${TAG}_client.json"
REMOTE_CSV="/tmp/${TAG}_client.csv"
REMOTE_LOG="/tmp/${TAG}_client.log"

stop_diagnostics() {
    if [[ -n "${SERVER_PID:-}" ]]; then
        kill -TERM "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
        SERVER_PID=""
    fi
    if [[ -n "${CLIENT_PID:-}" ]]; then
        ssh -o BatchMode=yes -o ConnectTimeout=10 root@tinyman \
            "kill -TERM '$CLIENT_PID' 2>/dev/null || true; for i in \$(seq 1 100); do kill -0 '$CLIENT_PID' 2>/dev/null || exit 0; sleep 0.1; done; exit 0" \
            >/dev/null 2>&1 || true
        CLIENT_PID=""
    fi
}

cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    stop_diagnostics
    exit "$rc"
}
trap cleanup EXIT INT TERM

# Diagnostic only: never make traffic conditional on whether every configured
# QUIC worker is actually scheduled. We preserve exact-process thread CPU time
# so bottleneck interpretation can distinguish DPDK work from MsQuic work.
if [[ -x "$SERVER_BIN" ]]; then
    python3 "$CPU_ACTIVITY" \
        --binary "$SERVER_BIN" \
        --cpus "$QUIC_CPUS" \
        --json "$OUTPUT_DIR/quic_cpu_activity_server.json" \
        --csv "$OUTPUT_DIR/quic_cpu_activity_server.csv" \
        --interval-ms 5 \
        >"$OUTPUT_DIR/quic_cpu_activity_server_sampler.log" 2>&1 &
    SERVER_PID=$!
else
    echo "WARN: server QUIC binary unavailable for diagnostic sampler: $SERVER_BIN" >&2
fi

set +e
CLIENT_PID="$(ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman \
    "rm -f '$REMOTE_JSON' '$REMOTE_CSV' '$REMOTE_LOG'; if test -x '$CLIENT_BIN' && test -f '$CPU_ACTIVITY'; then nohup python3 '$CPU_ACTIVITY' --binary '$CLIENT_BIN' --cpus '$QUIC_CPUS' --json '$REMOTE_JSON' --csv '$REMOTE_CSV' --interval-ms 5 >'$REMOTE_LOG' 2>&1 </dev/null & echo \$!; fi" 2>/dev/null)"
CLIENT_START_RC=$?
set -e
if (( CLIENT_START_RC != 0 )) || [[ ! "$CLIENT_PID" =~ ^[0-9]+$ ]]; then
    echo "WARN: Tinyman exact QUIC CPU diagnostic sampler did not start; traffic will continue" >&2
    CLIENT_PID=""
fi

echo "QUIC CPU DIAGNOSTIC START case=$CASE_NAME requested=$QUIC_CPUS server_pid=${SERVER_PID:-none} client_pid=${CLIENT_PID:-none}"

set +e
bash "$BASE" "$@"
CASE_RC=$?
set -e

stop_diagnostics

# Retrieve diagnostic artifacts best-effort. Missing/FAIL activity is evidence,
# not a reason to discard a completed throughput case.
if ssh -o BatchMode=yes -o ConnectTimeout=10 root@tinyman "test -f '$REMOTE_JSON'" >/dev/null 2>&1; then
    scp -q -o BatchMode=yes -o ConnectTimeout=15 "root@tinyman:$REMOTE_JSON" "$OUTPUT_DIR/quic_cpu_activity_client.json" || true
fi
if ssh -o BatchMode=yes -o ConnectTimeout=10 root@tinyman "test -f '$REMOTE_CSV'" >/dev/null 2>&1; then
    scp -q -o BatchMode=yes -o ConnectTimeout=15 "root@tinyman:$REMOTE_CSV" "$OUTPUT_DIR/quic_cpu_activity_client.csv" || true
fi
ssh -o BatchMode=yes -o ConnectTimeout=10 root@tinyman "cat '$REMOTE_LOG' 2>/dev/null || true; rm -f '$REMOTE_JSON' '$REMOTE_CSV' '$REMOTE_LOG'" \
    >"$OUTPUT_DIR/quic_cpu_activity_client_sampler.log" 2>&1 || true

python3 - "$OUTPUT_DIR" <<'PY' || true
from pathlib import Path
import json, sys
root=Path(sys.argv[1])
for role in ('server','client'):
    p=root/f'quic_cpu_activity_{role}.json'
    if not p.is_file():
        print(f'QUIC CPU DIAGNOSTIC {role}: MISSING')
        continue
    try:
        j=json.loads(p.read_text(encoding='utf-8'))
    except Exception as exc:
        print(f'QUIC CPU DIAGNOSTIC {role}: INVALID {exc}')
        continue
    active=[str(r.get('cpu')) for r in j.get('rows',[]) if r.get('active')]
    inactive=[str(r.get('cpu')) for r in j.get('rows',[]) if not r.get('active')]
    total=sum(float(r.get('cpu_time_s',0.0)) for r in j.get('rows',[]))
    print(f"QUIC CPU DIAGNOSTIC {role}: status={j.get('status')} active={','.join(active) or '-'} inactive={','.join(inactive) or '-'} process_cpu_time_total_s={total:.6f}")
PY

echo "QUIC CPU DIAGNOSTIC COMPLETE case=$CASE_NAME traffic_rc=$CASE_RC"
exit "$CASE_RC"
