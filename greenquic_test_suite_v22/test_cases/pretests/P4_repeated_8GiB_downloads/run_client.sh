#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
source "$HERE/config.env"

MODE="${GQ_MODE_OVERRIDE:-basic}"
case "$MODE" in
    off|basic|plus) ;;
    *) echo "ERROR: invalid GQ_MODE_OVERRIDE=$MODE" >&2; exit 2 ;;
esac

[[ "$DOWNLOADS_PER_RUN" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: DOWNLOADS_PER_RUN must be a positive integer" >&2
    exit 2
}
[[ "$GAP_US" =~ ^[0-9]+$ ]] || {
    echo "ERROR: GAP_US must be a non-negative integer" >&2
    exit 2
}
[[ "$PAYLOAD_BYTES" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: PAYLOAD_BYTES must be a positive integer" >&2
    exit 2
}

# Use the separately built P4 client automatically when available. This does
# not replace or modify the known-good build-greenquic binary.
REPO_ROOT="$(cd -- "$HERE/../../../.." && pwd)"
P4_CLIENT_BIN="${P4_CLIENT_BIN:-$REPO_ROOT/msquic/build-greenquic-p4/bin/Release/quicinterop}"
if [[ -z "${GQ_INTEROP_CLIENT_BIN:-}" && -x "$P4_CLIENT_BIN" ]]; then
    export GQ_INTEROP_CLIENT_BIN="$P4_CLIENT_BIN"
fi

actual_client_bin="${GQ_INTEROP_CLIENT_BIN:-$REPO_ROOT/msquic/build-greenquic/bin/Release/quicinterop}"
grep -aFq -- 'GreenQUIC-P4-SEQUENCE-V2' "$actual_client_bin" 2>/dev/null || {
    echo "ERROR: selected quicinterop is not the corrected P4 V2 sequential client" >&2
    echo "Binary: $actual_client_bin" >&2
    echo "Run ./build_p4_client.sh after updating the repository." >&2
    exit 2
}
grep -aFq -- 'ready_for_start_gate_us=' "$actual_client_bin" 2>/dev/null || {
    echo "ERROR: selected P4 client does not contain the startup gate" >&2
    exit 2
}

# The common manifest generator validates completed names against a local
# server_root reference. On Tinyman this is validation metadata only; downloads
# themselves are still written to the configured sink (/dev/null). Create a
# sparse logical-size reference so a fresh client node can validate 8-GiB
# completions without consuming 8 GiB of disk blocks.
server_root="$REPO_ROOT/greenquic_test_suite_v22/common/files/server_root"
payload_name="${REQUEST_PATH##*/}"
reference_file="$server_root/$payload_name"
mkdir -p "$server_root"
if [[ ! -e "$reference_file" ]]; then
    truncate -s "$PAYLOAD_BYTES" "$reference_file"
fi
[[ "$(stat -Lc '%s' "$reference_file")" == "$PAYLOAD_BYTES" ]] || {
    echo "ERROR: P4 validation reference has wrong size: $reference_file" >&2
    exit 2
}

# Repeat the same URL inside one quicinterop process. The corrected P4 client
# connects once, then sends one stream at a time, waits for the full response,
# sleeps GAP_US, and only then starts the next stream.
REQUEST_PATHS=""
for ((i=1; i<=DOWNLOADS_PER_RUN; i++)); do
    REQUEST_PATHS+="$REQUEST_PATH"$'\n'
done
REQUEST_PATHS="${REQUEST_PATHS%$'\n'}"

export REQUEST_PATHS
export GQ_INTEROP_P4_SEQUENCE=1
export GQ_INTEROP_REQUEST_GAP_US="$GAP_US"
export ENABLE_CSTATE_RECORD="${ENABLE_CSTATE_RECORD:-1}"

"$HERE/../../../common/bin/run_role.sh" client "$HERE" "$MODE" 0

latest_file() {
    local pattern="$1"
    find "$2" -maxdepth 1 -type f -name "$pattern" -printf '%T@ %p\n' 2>/dev/null |
        sort -nr |
        head -n1 |
        cut -d' ' -f2-
}

client_log="$(latest_file "client_${MODE}_*.log" "$HERE/logs")"
[[ -n "$client_log" && -f "$client_log" ]] || {
    echo "ERROR: latest client log for mode=$MODE not found" >&2
    exit 2
}

base="$(basename "$client_log")"
stamp="${base#client_${MODE}_}"
stamp="${stamp%.log}"

manifest="$HERE/results/client_download_manifest_${MODE}_${stamp}.json"
[[ -f "$manifest" ]] || {
    echo "ERROR: exact client download manifest not found: $manifest" >&2
    exit 2
}

read -r actual_bytes actual_files < <(
    python3 - "$manifest" <<'PY_MANIFEST'
import json
import sys
row = json.load(open(sys.argv[1], encoding="utf-8"))
print(int(row.get("total_bytes", 0)), int(row.get("file_count", 0)))
PY_MANIFEST
)

expected_bytes=$((PAYLOAD_BYTES * DOWNLOADS_PER_RUN))
[[ "$actual_files" == "$DOWNLOADS_PER_RUN" ]] || {
    echo "ERROR: expected $DOWNLOADS_PER_RUN completed downloads, got $actual_files" >&2
    exit 2
}
[[ "$actual_bytes" == "$expected_bytes" ]] || {
    echo "ERROR: expected $expected_bytes total bytes, got $actual_bytes" >&2
    exit 2
}

p4_metrics="$HERE/results/p4_metrics_${MODE}_${stamp}.json"
p4_text="$HERE/results/p4_summary_${MODE}_${stamp}.txt"

python3 "$HERE/report_p4_run.py" \
    --log "$client_log" \
    --manifest "$manifest" \
    --mode "$MODE" \
    --downloads "$DOWNLOADS_PER_RUN" \
    --gap-us "$GAP_US" \
    --out "$p4_metrics" \
    --text-out "$p4_text" \
    --quiet

if [[ "${ENABLE_RECORD:-1}" != 0 ]]; then
    energy="$HERE/results/client_energy_${MODE}_${stamp}.json"
    [[ -f "$energy" ]] || {
        echo "ERROR: exact client energy file not found: $energy" >&2
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

    run_dir="$(
        find "$HERE/results" -maxdepth 1 -type d \
            -name "${stamp}__$(basename "$HERE")__client__${MODE}*" \
            -printf '%T@ %p\n' |
        sort -nr |
        head -n1 |
        cut -d' ' -f2-
    )"
    if [[ -n "$run_dir" && -d "$run_dir/details" ]]; then
        cp -p "$p4_metrics" "$run_dir/details/"
        cp -p "$p4_text" "$run_dir/details/"
    fi
fi

cat "$p4_text"
