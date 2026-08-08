#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
source "$HERE/config.env"
REPO_ROOT="$(cd -- "$HERE/../../../.." && pwd)"
P6_CLIENT_BIN="$REPO_ROOT/msquic/build-greenquic-p6/bin/Release/quicinterop"
export GQ_INTEROP_CLIENT_BIN="${GQ_INTEROP_CLIENT_BIN:-$P6_CLIENT_BIN}"

MODE="${GQ_MODE_OVERRIDE:-basic}"
case "$MODE" in
    off|basic|plus) ;;
    *) echo "ERROR: invalid GQ_MODE_OVERRIDE=$MODE" >&2; exit 2 ;;
esac

[[ "$DOWNLOADS_PER_RUN" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: DOWNLOADS_PER_RUN must be positive" >&2; exit 2; }
[[ "$GAP_US" =~ ^[0-9]+$ ]] || { echo "ERROR: GAP_US must be non-negative" >&2; exit 2; }
[[ "$PAYLOAD_BYTES" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: PAYLOAD_BYTES must be positive" >&2; exit 2; }
[[ -x "$GQ_INTEROP_CLIENT_BIN" ]] || { echo "ERROR: P6 client binary missing: $GQ_INTEROP_CLIENT_BIN" >&2; exit 2; }
grep -aFq -- 'GreenQUIC-P5-SEQUENCE-V2' "$GQ_INTEROP_CLIENT_BIN" || { echo "ERROR: P6 client lacks sequential-download base" >&2; exit 2; }
grep -aFq -- 'GREENQUIC-P6-DETERMINISTIC-LOSS-V1' "$GQ_INTEROP_CLIENT_BIN" || { echo "ERROR: selected client is not the isolated P6 binary" >&2; exit 2; }
grep -aFq -- 'ready_for_start_gate_us=' "$GQ_INTEROP_CLIENT_BIN" || { echo "ERROR: P6 client lacks start gate" >&2; exit 2; }

# Validation reference only. The real payload is served by idex. Keep the sparse
# client-side reference inside P6, not in common/ or P5.
payload_name="${REQUEST_PATH##*/}"
validation_root="$HERE/validation_server_root"
reference_file="$validation_root/$payload_name"
mkdir -p "$validation_root"
if [[ ! -e "$reference_file" ]]; then
    truncate -s "$PAYLOAD_BYTES" "$reference_file"
fi
[[ "$(stat -Lc '%s' "$reference_file")" == "$PAYLOAD_BYTES" ]] || {
    echo "ERROR: P6 validation reference has wrong size: $reference_file" >&2
    exit 2
}

REQUEST_PATHS=""
for ((i=1; i<=DOWNLOADS_PER_RUN; i++)); do
    REQUEST_PATHS+="$REQUEST_PATH"$'\n'
done
REQUEST_PATHS="${REQUEST_PATHS%$'\n'}"
export REQUEST_PATHS
export GQ_INTEROP_P5_SEQUENCE=1
export GQ_INTEROP_REQUEST_GAP_US="$GAP_US"
export ENABLE_CSTATE_RECORD="${ENABLE_CSTATE_RECORD:-1}"

"$HERE/run_role_p5.sh" client "$HERE" "$MODE" 0

latest_file() {
    find "$2" -maxdepth 1 -type f -name "$1" -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-
}

client_log="$(latest_file "client_${MODE}_*.log" "$HERE/logs")"
[[ -n "$client_log" && -f "$client_log" ]] || { echo "ERROR: latest P6 client log not found" >&2; exit 2; }
base="$(basename "$client_log")"
stamp="${base#client_${MODE}_}"
stamp="${stamp%.log}"
manifest="$HERE/results/client_download_manifest_${MODE}_${stamp}.json"
[[ -f "$manifest" ]] || { echo "ERROR: P6 client manifest missing: $manifest" >&2; exit 2; }

read -r actual_bytes actual_files < <(python3 - "$manifest" <<'PY'
import json,sys
r=json.load(open(sys.argv[1],encoding='utf-8'))
print(int(r.get('total_bytes',0)), int(r.get('file_count',0)))
PY
)
expected_bytes=$((PAYLOAD_BYTES * DOWNLOADS_PER_RUN))
[[ "$actual_files" == "$DOWNLOADS_PER_RUN" ]] || { echo "ERROR: expected $DOWNLOADS_PER_RUN downloads, got $actual_files" >&2; exit 2; }
[[ "$actual_bytes" == "$expected_bytes" ]] || { echo "ERROR: expected $expected_bytes bytes, got $actual_bytes" >&2; exit 2; }

p5_metrics="$HERE/results/p5_metrics_${MODE}_${stamp}.json"
p5_text="$HERE/results/p5_summary_${MODE}_${stamp}.txt"
python3 "$HERE/report_p5_run.py" --log "$client_log" --manifest "$manifest" --mode "$MODE" --downloads "$DOWNLOADS_PER_RUN" --gap-us "$GAP_US" --out "$p5_metrics" --text-out "$p5_text" --quiet

if [[ "${ENABLE_RECORD:-1}" != 0 ]]; then
    energy="$HERE/results/client_energy_${MODE}_${stamp}.json"
    [[ -f "$energy" ]] || { echo "ERROR: P6 client energy file missing: $energy" >&2; exit 2; }
    goodput="$HERE/results/goodput_${MODE}_${stamp}.json"
    python3 "$HERE/../../../common/bin/report_goodput.py" --energy "$energy" --client-log "$client_log" --bytes "$actual_bytes" --mode "$MODE" --test-id "$TEST_ID" --out "$goodput"
    python3 "$HERE/../../../common/bin/bundle_run_results.py" --test-dir "$HERE" --role client --mode "$MODE" --stamp "$stamp"
    run_dir="$(find "$HERE/results" -maxdepth 1 -type d -name "${stamp}__$(basename "$HERE")__client__${MODE}*" -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)"
    if [[ -n "$run_dir" && -d "$run_dir/details" ]]; then
        cp -p "$p5_metrics" "$run_dir/details/"
        cp -p "$p5_text" "$run_dir/details/"
    fi
fi
cat "$p5_text"
