#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
source "$HERE/config.env"

MODE="${GQ_MODE_OVERRIDE:-basic}"
case "$MODE" in
    off|basic|plus) ;;
    *) echo "ERROR: invalid GQ_MODE_OVERRIDE=$MODE" >&2; exit 2 ;;
esac

# P3 is a comparison pretest, so collect the same C-state visual by default in
# every mode. Set ENABLE_CSTATE_RECORD=0 explicitly to disable it.
export ENABLE_CSTATE_RECORD="${ENABLE_CSTATE_RECORD:-1}"

"$HERE/../../../common/bin/run_role.sh" client "$HERE" "$MODE" 0

# GREENQUIC-ENABLE-RECORD-V1: run_role already printed goodput and removed transient artifacts.
if [[ "${ENABLE_RECORD:-1}" == 0 ]]; then
    exit 0
fi

manifest="$(
    find "$HERE/results" -maxdepth 1 -type f \
        -name "client_download_manifest_${MODE}_*.json" \
        -printf '%T@ %p\n' |
    sort -nr |
    head -n1 |
    cut -d' ' -f2-
)"
[[ -n "$manifest" && -f "$manifest" ]] || {
    echo "ERROR: latest client download manifest for mode=$MODE not found" >&2
    exit 2
}

base="$(basename "$manifest")"
stamp="${base#client_download_manifest_${MODE}_}"
stamp="${stamp%.json}"
energy="$HERE/results/client_energy_${MODE}_${stamp}.json"
client_log="$HERE/logs/client_${MODE}_${stamp}.log"

[[ -f "$energy" ]] || {
    echo "ERROR: exact client energy file not found: $energy" >&2
    exit 2
}
[[ -f "$client_log" ]] || {
    echo "ERROR: exact client log not found: $client_log" >&2
    exit 2
}

actual_bytes="$(python3 - "$manifest" <<'PY_BYTES'
import json
import sys

row = json.load(open(sys.argv[1], encoding="utf-8"))
print(int(row.get("total_bytes", 0)))
PY_BYTES
)"
[[ "$actual_bytes" -gt 0 ]] || {
    echo "ERROR: no downloaded payload bytes were recorded in $manifest" >&2
    exit 2
}
[[ "$actual_bytes" == "$PAYLOAD_BYTES" ]] || {
    echo "ERROR: expected $PAYLOAD_BYTES bytes, got $actual_bytes" >&2
    exit 2
}

goodput="$HERE/results/goodput_${MODE}_${stamp}.json"
python3 "$HERE/../../../common/bin/report_goodput.py" \
    --energy "$energy" \
    --client-log "$client_log" \
    --bytes "$actual_bytes" \
    --mode "$MODE" \
    --test-id "$TEST_ID" \
    --out "$goodput"

python3 "$HERE/../../../common/bin/bundle_run_results.py" \
    --test-dir "$HERE" \
    --role client \
    --mode "$MODE" \
    --stamp "$stamp"
