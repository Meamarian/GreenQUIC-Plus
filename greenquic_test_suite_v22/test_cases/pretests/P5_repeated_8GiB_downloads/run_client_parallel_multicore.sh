#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
source "$HERE/config.env"
REPO_ROOT="$(cd -- "$HERE/../../../.." && pwd)"

MODE="${GQ_MODE_OVERRIDE:-basic}"
case "$MODE" in off|basic|plus) ;; *) echo "ERROR: invalid GQ_MODE_OVERRIDE=$MODE" >&2; exit 2;; esac

CONNECTIONS="${P5_PARALLEL_CONNECTIONS:-4}"
LOCAL_PORT_BASE="${P5_PARALLEL_LOCAL_PORT_BASE:-45000}"
[[ "$CONNECTIONS" =~ ^[2-9][0-9]*$ ]] || { echo "ERROR: P5_PARALLEL_CONNECTIONS must be >=2" >&2; exit 2; }
[[ "$LOCAL_PORT_BASE" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: P5_PARALLEL_LOCAL_PORT_BASE must be positive" >&2; exit 2; }
(( LOCAL_PORT_BASE + CONNECTIONS - 1 <= 65535 )) || { echo "ERROR: parallel local port range exceeds 65535" >&2; exit 2; }

export GQ_INTEROP_CLIENT_BIN="${GQ_INTEROP_CLIENT_BIN:-$REPO_ROOT/msquic/build-greenquic-p5/bin/Release/quicinterop}"
actual_client_bin="$GQ_INTEROP_CLIENT_BIN"
for marker in GREENQUIC-P5-PARALLEL-CONNECTIONS-V1 GREENQUIC-P5-MULTICORE-TXQ-V1; do
    grep -aFq -- "$marker" "$actual_client_bin" 2>/dev/null || {
        echo "ERROR: selected P5 client lacks $marker: $actual_client_bin" >&2
        echo "Run ./build_p5_multicore_performance2.sh first." >&2
        exit 2
    }
done

# Four (by default) distinct URLs prevent output-name collisions, and forced
# local UDP ports create distinct 5-tuples for RSS on both P5 and P7.
server_root="$REPO_ROOT/greenquic_test_suite_v22/common/files/server_root"
download_root="$REPO_ROOT/greenquic_test_suite_v22/common/downloads"
mkdir -p "$server_root" "$download_root" "$HERE/results"
REQUEST_PATHS=""
for ((i=1; i<=CONNECTIONS; i++)); do
    name="file_8G_mc$(printf '%02d' "$i").bin"
    reference="$server_root/$name"
    [[ -e "$reference" ]] || truncate -s "$PAYLOAD_BYTES" "$reference"
    [[ "$(stat -Lc '%s' "$reference")" == "$PAYLOAD_BYTES" ]] || {
        echo "ERROR: client validation reference has wrong size: $reference" >&2
        exit 2
    }
    ln -sfn /dev/null "$download_root/$name"
    REQUEST_PATHS+="/$name"$'\n'
done
REQUEST_PATHS="${REQUEST_PATHS%$'\n'}"

export REQUEST_PATHS
export DOWNLOADS_PER_RUN="$CONNECTIONS"
export GAP_US=0
export WORKLOAD_KIND=multi_stream_single_connection
export GQ_INTEROP_P5_SEQUENCE=0
export GQ_INTEROP_P5_PARALLEL=1
export GQ_INTEROP_P5_PARALLEL_CONNECTIONS="$CONNECTIONS"
export GQ_INTEROP_P5_LOCAL_PORT_BASE="$LOCAL_PORT_BASE"
export GQ_INTEROP_P5_PARALLEL_READY_TIMEOUT_US=120000000
export ENABLE_CSTATE_RECORD="${ENABLE_CSTATE_RECORD:-1}"

# run_role_p5 performs the normal P5 teardown and bundling. Mark the results
# directory first, then augment that exact newly-created bundle; do not invoke a
# second bundler because the first bundler has already moved the raw log and
# manifest into details/.
marker="$HERE/results/.parallel_client_${MODE}_$$_$(date +%s%N).marker"
touch "$marker"
cleanup_marker(){ rm -f "$marker"; }
trap cleanup_marker EXIT

"$HERE/run_role_p5.sh" client "$HERE" "$MODE" 0

run_dir="$(
    find "$HERE/results" -mindepth 1 -maxdepth 1 -type d \
        -name "*__client__${MODE}*" -newer "$marker" -printf '%T@ %p\n' 2>/dev/null |
    sort -nr | head -n1 | cut -d' ' -f2-
)"
[[ -n "$run_dir" && -d "$run_dir/details" ]] || {
    echo "ERROR: exact newly-created parallel client bundle not found" >&2
    exit 2
}

details="$run_dir/details"
client_log="$(find "$details" -maxdepth 1 -type f -name '*_log.txt' -print | head -n1)"
manifest="$(find "$details" -maxdepth 1 -type f -name '*_download_manifest.json' -print | head -n1)"
[[ -n "$client_log" && -f "$client_log" ]] || { echo "ERROR: bundled parallel client log missing in $details" >&2; exit 2; }
[[ -n "$manifest" && -f "$manifest" ]] || { echo "ERROR: bundled client manifest missing in $details" >&2; exit 2; }

read -r actual_bytes actual_files < <(python3 - "$manifest" <<'PY'
import json,sys
r=json.load(open(sys.argv[1],encoding='utf-8'));print(int(r.get('total_bytes',0)),int(r.get('file_count',0)))
PY
)
expected_bytes=$((PAYLOAD_BYTES * CONNECTIONS))
[[ "$actual_files" == "$CONNECTIONS" ]] || { echo "ERROR: expected $CONNECTIONS completions, got $actual_files" >&2; exit 2; }
[[ "$actual_bytes" == "$expected_bytes" ]] || { echo "ERROR: payload bytes $actual_bytes != $expected_bytes" >&2; exit 2; }

stem="$(basename "$run_dir")"
metrics="$details/${stem}_parallel_metrics.json"
summary="$details/${stem}_parallel_summary.txt"
goodput="$details/${stem}_parallel_goodput.json"
python3 "$HERE/report_p5_parallel_run.py" \
    --log "$client_log" \
    --manifest "$manifest" \
    --mode "$MODE" \
    --connections "$CONNECTIONS" \
    --out "$metrics" \
    --text-out "$summary" \
    --goodput-out "$goodput"

# The outer matrix captures stdout in client_repNN_MODE.log. Printing this
# summary there gives the matrix-level aggregate-goodput/variance parser an
# exact per-test source while the JSON stays inside the unified run bundle.
cat "$summary"
