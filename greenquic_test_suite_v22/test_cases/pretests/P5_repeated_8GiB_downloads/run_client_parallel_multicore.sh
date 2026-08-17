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

# Four (by default) distinct URLs prevent output-name collisions, and four
# forced local UDP ports create four distinct 5-tuples for RSS on both P5/P7.
server_root="$REPO_ROOT/greenquic_test_suite_v22/common/files/server_root"
download_root="$REPO_ROOT/greenquic_test_suite_v22/common/downloads"
mkdir -p "$server_root" "$download_root"
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

"$HERE/run_role_p5.sh" client "$HERE" "$MODE" 0

latest_file() {
    local pattern="$1" dir="$2"
    find "$dir" -maxdepth 1 -type f -name "$pattern" -printf '%T@ %p\n' 2>/dev/null |
        sort -nr | head -n1 | cut -d' ' -f2-
}

client_log="$(latest_file "client_${MODE}_*.log" "$HERE/logs")"
[[ -n "$client_log" && -f "$client_log" ]] || { echo "ERROR: parallel client log not found" >&2; exit 2; }
base="$(basename "$client_log")"
stamp="${base#client_${MODE}_}"; stamp="${stamp%.log}"
manifest="$HERE/results/client_download_manifest_${MODE}_${stamp}.json"
[[ -f "$manifest" ]] || { echo "ERROR: exact client manifest missing: $manifest" >&2; exit 2; }

read -r actual_bytes actual_files < <(python3 - "$manifest" <<'PY'
import json,sys
r=json.load(open(sys.argv[1],encoding='utf-8'));print(int(r.get('total_bytes',0)),int(r.get('file_count',0)))
PY
)
expected_bytes=$((PAYLOAD_BYTES * CONNECTIONS))
[[ "$actual_files" == "$CONNECTIONS" ]] || { echo "ERROR: expected $CONNECTIONS completions, got $actual_files" >&2; exit 2; }
[[ "$actual_bytes" == "$expected_bytes" ]] || { echo "ERROR: payload bytes $actual_bytes != $expected_bytes" >&2; exit 2; }

metrics="$HERE/results/p5_parallel_metrics_${MODE}_${stamp}.json"
summary="$HERE/results/p5_parallel_summary_${MODE}_${stamp}.txt"
goodput="$HERE/results/goodput_${MODE}_${stamp}.json"
python3 "$HERE/report_p5_parallel_run.py" \
    --log "$client_log" \
    --manifest "$manifest" \
    --mode "$MODE" \
    --connections "$CONNECTIONS" \
    --out "$metrics" \
    --text-out "$summary" \
    --goodput-out "$goodput"

if [[ "${ENABLE_RECORD:-1}" != 0 ]]; then
    python3 "$HERE/../../../common/bin/bundle_run_results.py" \
        --test-dir "$HERE" --role client --mode "$MODE" --stamp "$stamp"
    run_dir="$(find "$HERE/results" -maxdepth 1 -type d \
        -name "${stamp}__$(basename "$HERE")__client__${MODE}*" \
        -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)"
    if [[ -n "$run_dir" && -d "$run_dir/details" ]]; then
        cp -p "$metrics" "$summary" "$run_dir/details/"
    fi
fi

cat "$summary"
