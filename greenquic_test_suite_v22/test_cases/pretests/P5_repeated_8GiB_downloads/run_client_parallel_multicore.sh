#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
source "$HERE/config.env"
REPO_ROOT="$(cd -- "$HERE/../../../.." && pwd)"
VERIFY_BINARY="$HERE/verify_p5_parallel_multicore_binary.sh"

MODE="${GQ_MODE_OVERRIDE:-basic}"
case "$MODE" in off|basic|plus) ;; *) echo "ERROR: invalid GQ_MODE_OVERRIDE=$MODE" >&2; exit 2;; esac

CONNECTIONS="${P5_PARALLEL_CONNECTIONS:-4}"
LOCAL_PORT_BASE="${P5_PARALLEL_LOCAL_PORT_BASE:-45000}"
[[ "$CONNECTIONS" =~ ^[2-9][0-9]*$ ]] || { echo "ERROR: P5_PARALLEL_CONNECTIONS must be >=2" >&2; exit 2; }
[[ "$LOCAL_PORT_BASE" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: P5_PARALLEL_LOCAL_PORT_BASE must be positive" >&2; exit 2; }
(( LOCAL_PORT_BASE + CONNECTIONS - 1 <= 65535 )) || { echo "ERROR: parallel local port range exceeds 65535" >&2; exit 2; }

export GQ_INTEROP_CLIENT_BIN="${GQ_INTEROP_CLIENT_BIN:-$REPO_ROOT/msquic/build-greenquic-p5/bin/Release/quicinterop}"
actual_client_bin="$GQ_INTEROP_CLIENT_BIN"
[[ -f "$VERIFY_BINARY" ]] || { echo "ERROR: compiled-runtime verifier missing: $VERIFY_BINARY" >&2; exit 2; }
bash "$VERIFY_BINARY" client "$actual_client_bin"

# Distinct URLs prevent output-name collisions, and forced local UDP ports make
# each simultaneous QUIC connection a distinct 5-tuple for RSS.
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

# IMPORTANT: run_role_p5.sh creates the raw client artifacts, but it does NOT
# create the final unified client bundle. Mirror the proven normal run_client.sh
# ordering exactly: run_role -> exact log/stamp -> manifest -> report -> bundle.
marker="$HERE/logs/.parallel_client_${MODE}_$$_$(date +%s%N).marker"
mkdir -p "$HERE/logs"
touch "$marker"
cleanup_marker(){ rm -f "$marker"; }
trap cleanup_marker EXIT

"$HERE/run_role_p5.sh" client "$HERE" "$MODE" 0

client_log="$(
    find "$HERE/logs" -maxdepth 1 -type f -name "client_${MODE}_*.log" -newer "$marker" \
        -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-
)"
[[ -n "$client_log" && -f "$client_log" ]] || {
    echo "ERROR: exact parallel client log not found after run_role_p5" >&2
    exit 2
}
base="$(basename "$client_log")"
stamp="${base#client_${MODE}_}"
stamp="${stamp%.log}"

manifest="$HERE/results/client_download_manifest_${MODE}_${stamp}.json"
[[ -f "$manifest" ]] || {
    echo "ERROR: exact parallel client manifest not found: $manifest" >&2
    exit 2
}

read -r actual_bytes actual_files < <(python3 - "$manifest" <<'PY'
import json,sys
r=json.load(open(sys.argv[1],encoding='utf-8'))
print(int(r.get('total_bytes',0)),int(r.get('file_count',0)))
PY
)
expected_bytes=$((PAYLOAD_BYTES * CONNECTIONS))
[[ "$actual_files" == "$CONNECTIONS" ]] || { echo "ERROR: expected $CONNECTIONS completions, got $actual_files" >&2; exit 2; }
[[ "$actual_bytes" == "$expected_bytes" ]] || { echo "ERROR: payload bytes $actual_bytes != $expected_bytes" >&2; exit 2; }

metrics="$HERE/results/p5_parallel_metrics_${MODE}_${stamp}.json"
summary="$HERE/results/p5_parallel_summary_${MODE}_${stamp}.txt"
goodput="$HERE/results/goodput_parallel_${MODE}_${stamp}.json"
python3 "$HERE/report_p5_parallel_run.py" \
    --log "$client_log" \
    --manifest "$manifest" \
    --mode "$MODE" \
    --connections "$CONNECTIONS" \
    --out "$metrics" \
    --text-out "$summary" \
    --goodput-out "$goodput"

# Create the same unified result bundle as normal P5 only AFTER goodput exists,
# so the common bundler moves the exact raw log/manifest/RAPL/frequency/C-state
# data plus the parallel goodput JSON into details/.
python3 "$HERE/../../../common/bin/bundle_run_results.py" \
    --test-dir "$HERE" \
    --role client \
    --mode "$MODE" \
    --stamp "$stamp"

run_dir="$(
    find "$HERE/results" -mindepth 1 -maxdepth 1 -type d \
        -name "${stamp}__$(basename "$HERE")__client__${MODE}*" \
        -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-
)"
[[ -n "$run_dir" && -d "$run_dir/details" ]] || {
    echo "ERROR: parallel client bundle was not created for exact stamp=$stamp mode=$MODE" >&2
    exit 2
}

# The common bundler does not know these branch-only report names. Preserve them
# beside the normal artifacts for matrix-level active-window analysis.
cp -p "$metrics" "$run_dir/details/"
cp -p "$summary" "$run_dir/details/"

# The outer matrix captures stdout in client_repNN_MODE.log. Print the complete
# per-connection + aggregate goodput summary for every repetition.
cat "$summary"
echo "[GreenQUIC-PARALLEL-BUNDLE] stamp=$stamp mode=$MODE bundle=$(basename "$run_dir") status=PASS"
