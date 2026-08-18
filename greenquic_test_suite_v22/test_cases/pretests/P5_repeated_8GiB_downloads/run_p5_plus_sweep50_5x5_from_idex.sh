#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(cd -- "$HERE/../../../.." && pwd)"
CLIENT_HOST="${CLIENT_HOST:-tinyman}"
CLIENT_DIR="${CLIENT_DIR:-$HERE}"
TAG="${TAG:-P5_PLUS_SWEEP50_5RUNS_$(date +%Y%m%d_%H%M%S)}"

OUT="${OUT:-$HERE/matrix_results/$TAG}"
SUMMARY="${SUMMARY:-/root/${TAG}.summary.txt}"
DONE="${DONE:-/root/${TAG}.DONE}"
FAILED="${FAILED:-/root/${TAG}.FAILED}"

TEMP_COMMON="$HERE/.${TAG}_gq_common_p5.sh"
TEMP_ROLE="$HERE/.${TAG}_run_role_p5.sh"
TEMP_SERVER="$HERE/.${TAG}_server.sh"
TEMP_CLIENT="$HERE/.${TAG}_client.sh"
TEMP_CORE="$HERE/.${TAG}_core.sh"
TEMP_BASE="$HERE/.${TAG}_from_idex.sh"

cleanup_temp() {
    rm -f -- "$TEMP_COMMON" "$TEMP_ROLE" "$TEMP_SERVER" "$TEMP_CORE" "$TEMP_BASE"
    ssh -n "$CLIENT_HOST" "rm -f $(printf '%q' "$CLIENT_DIR/.${TAG}_gq_common_p5.sh") $(printf '%q' "$CLIENT_DIR/.${TAG}_run_role_p5.sh") $(printf '%q' "$CLIENT_DIR/.${TAG}_client.sh")" >/dev/null 2>&1 || true
}
trap cleanup_temp EXIT INT TERM

mkdir -p "$OUT"
rm -f "$DONE" "$FAILED" "$SUMMARY"

command -v ssh >/dev/null 2>&1 || { echo "ERROR: ssh is required" >&2; exit 2; }
ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$CLIENT_HOST" true || {
    echo "ERROR: IDEX cannot SSH non-interactively to $CLIENT_HOST" >&2
    exit 2
}

# Create a local temporary execution path. It keeps every recorder active but
# removes post-run SVG/bundle/matrix generation. The original repository files
# remain unchanged.
python3 - "$HERE" "$TAG" <<'PY'
from pathlib import Path
import sys

p5 = Path(sys.argv[1])
tag = sys.argv[2]


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"ERROR: expected one {label}, found {count}")
    return text.replace(old, new, 1)

common_src = p5 / "gq_common_p5.sh"
common_dst = p5 / f".{tag}_gq_common_p5.sh"
common = common_src.read_text(encoding="utf-8")
old_bundle = '        python3 "$GQ_P5_DIR/bundle_run_results_p5.py" --test-dir "$GQ_SERVER_TEST_DIR" --role server --mode "$GQ_SERVER_MODE" --stamp "$GQ_SERVER_STAMP" || bundle_rc=$?\n'
common = replace_once(
    common,
    old_bundle,
    '        : # sweep: recorder data preserved; skip server SVG/bundle generation\n',
    "server P5 bundle call",
)
common_dst.write_text(common, encoding="utf-8")
common_dst.chmod(0o700)

role_src = p5 / "run_role_p5.sh"
role_dst = p5 / f".{tag}_run_role_p5.sh"
role = role_src.read_text(encoding="utf-8")
role = replace_once(
    role,
    'source "$HERE/gq_common_p5.sh"',
    f'source "$HERE/.{tag}_gq_common_p5.sh"',
    "role common source",
)
role_dst.write_text(role, encoding="utf-8")
role_dst.chmod(0o700)

server_src = p5 / "run_server.sh"
server_dst = p5 / f".{tag}_server.sh"
server = server_src.read_text(encoding="utf-8")
server = replace_once(
    server,
    '"$HERE/run_role_p5.sh" server "$HERE" "$MODE" 0',
    f'"$HERE/.{tag}_run_role_p5.sh" server "$HERE" "$MODE" 0',
    "server role call",
)
server_dst.write_text(server, encoding="utf-8")
server_dst.chmod(0o700)

core_src = p5 / "run_matrix_from_idex_core.sh"
core_dst = p5 / f".{tag}_core.sh"
core = core_src.read_text(encoding="utf-8")
core = replace_once(core, 'modes = ("off", "basic", "plus")', 'modes = ("plus",)', "mode tuple")
core = replace_once(core, 'TOTAL_TESTS=$((RUNS * 3))', 'TOTAL_TESTS=$RUNS', "TOTAL_TESTS")
core = core.replace('position=$position/3', 'position=$position/1')
core = core.replace('POSITION $position/3', 'POSITION $position/1')
core = core.replace('run_server.sh', f'.{tag}_server.sh')
core = core.replace('run_client.sh', f'.{tag}_client.sh')
old_consolidate = '    consolidate_run_bundles         "$mode" "$run_id" "$marker" "$client_result_marker"\n'
core = replace_once(
    core,
    old_consolidate,
    '    ssh -n "root@$CLIENT_HOST" "rm -f $(quote "$client_result_marker")" || true\n',
    "bundle consolidation call",
)
core = core.replace(
    '        python3 "$HERE/aggregate_p5_matrix.py" --input "$OUTPUT_DIR" --runs "$RUNS" || true\n',
    '',
)
core = core.replace(
    '    python3 "$HERE/aggregate_p5_matrix.py" --input "$OUTPUT_DIR" --runs "$RUNS" || true\n',
    '',
)
core = core.replace(
    'python3 "$HERE/aggregate_p5_matrix.py" --input "$OUTPUT_DIR" --runs "$RUNS"\n',
    '',
)
core = core.replace(
    'python3 "$HERE/p5_finalize_matrix.py" --matrix "$OUTPUT_DIR"\n',
    '',
)
if 'aggregate_p5_matrix.py' in core or 'p5_finalize_matrix.py' in core:
    raise SystemExit("ERROR: matrix postprocessor remains in temporary core")
core_dst.write_text(core, encoding="utf-8")
core_dst.chmod(0o700)

base_src = p5 / "run_matrix_from_idex.sh"
base_dst = p5 / f".{tag}_from_idex.sh"
base = base_src.read_text(encoding="utf-8")
base = replace_once(
    base,
    'CORE="$HERE/run_matrix_from_idex_core.sh"',
    f'CORE="$HERE/.{tag}_core.sh"',
    "base CORE assignment",
)
# The V2 start-gate replacement inside this wrapper creates its own client
# command, so redirect that generated command to the temporary client too.
base = base.replace('run_client.sh', f'.{tag}_client.sh')
base_dst.write_text(base, encoding="utf-8")
base_dst.chmod(0o700)
PY

# Build the corresponding temporary client path on Tinyman. The actual power,
# C-state, MSR and frequency recorders remain unchanged; only post-measurement
# visualization/result bundling is skipped.
ssh -n "$CLIENT_HOST" "python3 - $(printf '%q' "$CLIENT_DIR") $(printf '%q' "$TAG")" <<'PY'
from pathlib import Path
import sys

p5 = Path(sys.argv[1])
tag = sys.argv[2]


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"ERROR: expected one {label}, found {count}")
    return text.replace(old, new, 1)

common_src = p5 / "gq_common_p5.sh"
common_dst = p5 / f".{tag}_gq_common_p5.sh"
common = common_src.read_text(encoding="utf-8")
old_bundle = '        python3 "$GQ_P5_DIR/bundle_run_results_p5.py" --test-dir "$GQ_SERVER_TEST_DIR" --role server --mode "$GQ_SERVER_MODE" --stamp "$GQ_SERVER_STAMP" || bundle_rc=$?\n'
common = replace_once(
    common,
    old_bundle,
    '        : # sweep: recorder data preserved; skip server SVG/bundle generation\n',
    "server P5 bundle call",
)
common_dst.write_text(common, encoding="utf-8")
common_dst.chmod(0o700)

role_src = p5 / "run_role_p5.sh"
role_dst = p5 / f".{tag}_run_role_p5.sh"
role = role_src.read_text(encoding="utf-8")
role = replace_once(
    role,
    'source "$HERE/gq_common_p5.sh"',
    f'source "$HERE/.{tag}_gq_common_p5.sh"',
    "role common source",
)
role_dst.write_text(role, encoding="utf-8")
role_dst.chmod(0o700)

client_src = p5 / "run_client.sh"
client_dst = p5 / f".{tag}_client.sh"
client = client_src.read_text(encoding="utf-8")
client = replace_once(
    client,
    '"$HERE/run_role_p5.sh" client "$HERE" "$MODE" 0',
    f'"$HERE/.{tag}_run_role_p5.sh" client "$HERE" "$MODE" 0',
    "client role call",
)
start_marker = '    python3 "$HERE/../../../common/bin/bundle_run_results.py"'
start = client.find(start_marker)
if start < 0:
    raise SystemExit("ERROR: client bundle_run_results.py block not found")
end_marker = '\nfi\n\ncat "$p5_text"'
end = client.find(end_marker, start)
if end < 0:
    raise SystemExit("ERROR: end of client bundle block not found")
client = (
    client[:start]
    + '    # sweep: raw recorder outputs kept; skip client SVG/result bundling.\n'
    + client[end:]
)
if 'bundle_run_results.py' in client:
    raise SystemExit("ERROR: client bundle postprocessor remains")
client_dst.write_text(client, encoding="utf-8")
client_dst.chmod(0o700)
PY

test -x "$TEMP_COMMON"
test -x "$TEMP_ROLE"
test -x "$TEMP_SERVER"
test -x "$TEMP_CORE"
test -x "$TEMP_BASE"
ssh -n "$CLIENT_HOST" "test -x $(printf '%q' "$TEMP_CLIENT")"

echo "======================================================================"
echo "P5 PLUS 50-CONFIG x 5-RUN SWEEP"
echo "TAG=$TAG"
echo "OUTPUT=$OUT"
echo "SUMMARY=$SUMMARY"
echo "Idle mode fixed: monitor"
echo "Fallback fixed: short"
echo "Recorders: enabled"
echo "Post-run chart/matrix generation: disabled"
echo "======================================================================"

set +e
python3 -u "$HERE/p5_plus_sweep50_5x5.py" \
    --p5 "$HERE" \
    --runner "$TEMP_BASE" \
    --client-host "$CLIENT_HOST" \
    --output "$OUT" \
    --summary "$SUMMARY" \
    --done "$DONE" \
    --failed "$FAILED"
rc=$?
set -e

if [[ "$rc" != 0 && ! -f "$FAILED" ]]; then
    printf 'controller_rc=%s\n' "$rc" > "$FAILED"
fi

exit "$rc"
