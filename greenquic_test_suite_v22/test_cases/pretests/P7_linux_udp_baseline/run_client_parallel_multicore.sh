#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
BASE="$HERE/run_client.sh"
TMP="$(mktemp "$HERE/.run_client_parallel.XXXXXX.sh")"
trap 'rm -f "$TMP"' EXIT

python3 - "$BASE" "$TMP" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text(encoding='utf-8')

def one(old,new,label):
    global s
    n=s.count(old)
    if n!=1:raise SystemExit(f'ERROR: {label}: expected one anchor, found {n}')
    s=s.replace(old,new,1)

one('python3 "$HERE/report_p7_run.py" \\\n', 'python3 "$HERE/report_p7_parallel_run.py" \\\n', 'parallel reporter')

old='''payload_name="${REQUEST_PATH##*/}"
reference="$P7_SERVER_ROOT/$payload_name"
mkdir -p "$P7_SERVER_ROOT" "$SUITE_ROOT/common/downloads"
[[ -e "$reference" ]] || truncate -s "$PAYLOAD_BYTES" "$reference"
[[ "$(stat -Lc '%s' "$reference")" == "$PAYLOAD_BYTES" ]] || p7_die "payload reference has wrong size: $reference"
ln -sfn /dev/null "$SUITE_ROOT/common/downloads/$payload_name"

args=()
url="https://${P7_SERVER_IP}:${P7_PORT}${REQUEST_PATH}"
for ((i=1; i<=DOWNLOADS_PER_RUN; i++)); do
    if (( i == 1 )); then args+=("-urls:$url"); else args+=("$url"); fi
done
'''
new='''# GREENQUIC-P7-PARALLEL-MULTICORE-V1
# DOWNLOADS_PER_RUN is the number of simultaneous QUIC connections in this
# comparison. Distinct paths avoid output-name collisions; forced local ports
# below provide identical 5-tuples to the P5 experiment.
mkdir -p "$P7_SERVER_ROOT" "$SUITE_ROOT/common/downloads"
args=()
for ((i=1; i<=DOWNLOADS_PER_RUN; i++)); do
    payload_name="file_8G_mc$(printf '%02d' "$i").bin"
    reference="$P7_SERVER_ROOT/$payload_name"
    [[ -e "$reference" ]] || truncate -s "$PAYLOAD_BYTES" "$reference"
    [[ "$(stat -Lc '%s' "$reference")" == "$PAYLOAD_BYTES" ]] || p7_die "payload reference has wrong size: $reference"
    ln -sfn /dev/null "$SUITE_ROOT/common/downloads/$payload_name"
    url="https://${P7_SERVER_IP}:${P7_PORT}/$payload_name"
    if (( i == 1 )); then args+=("-urls:$url"); else args+=("$url"); fi
done
'''
one(old,new,'payload/url block')

old='''export GQ_INTEROP_P5_SEQUENCE=1
export GQ_INTEROP_REQUEST_GAP_US="$GAP_US"
export GQ_INTEROP_P5_START_GATE="$GATE"
export GQ_INTEROP_P5_GATE_TIMEOUT_US=120000000
'''
new='''export GQ_INTEROP_P5_SEQUENCE=0
export GQ_INTEROP_P5_PARALLEL=1
export GQ_INTEROP_P5_PARALLEL_CONNECTIONS="$DOWNLOADS_PER_RUN"
export GQ_INTEROP_P5_LOCAL_PORT_BASE="${P7_PARALLEL_LOCAL_PORT_BASE:-45000}"
export GQ_INTEROP_P5_PARALLEL_READY_TIMEOUT_US=120000000
export GQ_INTEROP_P5_START_GATE="$GATE"
export GQ_INTEROP_P5_GATE_TIMEOUT_US=120000000
'''
one(old,new,'parallel environment')

old='''completed="$(grep -cE '\\[GreenQUIC-P5\\] request=[0-9]+/[0-9]+ complete_us=.* success=1' "$RUN_DIR/client.log" || true)"
[[ "$completed" == "$DOWNLOADS_PER_RUN" ]] || p7_die "expected $DOWNLOADS_PER_RUN completed downloads, observed $completed"

p7_log "client REP $REP: all $DOWNLOADS_PER_RUN GETs complete; starting ${P7_POST_COOLDOWN_SECONDS}s post-cooldown"
'''
new='''completed="$(grep -cE '^\\[GreenQUIC-PARALLEL\\] conn=[0-9]+/[0-9]+ complete_us=.* success=1 ' "$RUN_DIR/client.log" || true)"
[[ "$completed" == "$DOWNLOADS_PER_RUN" ]] || p7_die "expected $DOWNLOADS_PER_RUN completed parallel connections, observed $completed"
grep -qE "^\\[GreenQUIC-PARALLEL\\] batch=1 complete_us=.* connections=$DOWNLOADS_PER_RUN connected=$DOWNLOADS_PER_RUN completed=$DOWNLOADS_PER_RUN success=1$" "$RUN_DIR/client.log" || p7_die "parallel batch completion marker missing"

p7_log "client REP $REP: all $DOWNLOADS_PER_RUN parallel QUIC connections complete; starting ${P7_POST_COOLDOWN_SECONDS}s post-cooldown"
'''
one(old,new,'parallel completion validation')

Path(sys.argv[2]).write_text(s,encoding='utf-8')
PY
chmod 0700 "$TMP";bash -n "$TMP";exec bash "$TMP" "$@"
