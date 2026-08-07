#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
CLIENT_HOST="${CLIENT_HOST:-tinyman}"
CLIENT_DIR="${CLIENT_DIR:-/root/greenquic_snapshot/greenquic_test_suite_v22/test_cases/pretests/P4_repeated_8GiB_downloads}"
P4_CLIENT_BIN="${P4_CLIENT_BIN:-/root/greenquic_snapshot/msquic/build-greenquic-p4/bin/Release/quicinterop}"
DOWNLOADS=5
GAP_SECONDS=5
RUNS=5
BETWEEN_TESTS_SECONDS=5
SERVER_COOLDOWN_SECONDS=5
READY_TIMEOUT_SECONDS=90
P4_CSTATE_CPU=19
OUTPUT_DIR=""
MODE_ORDER="balanced"
SEED=""
ENV_OVERRIDES=()
SERVER_PGID=""
SERVER_PIPELINE_PID=""
SERVER_PIDFILE=""

usage() {
    cat <<'USAGE'
Usage:
  ./run_matrix_from_idex.sh [options]

Options:
  --downloads N                downloads inside each one-process workload (default 5)
  --gap-seconds N              idle gap between downloads (default 5)
  --runs N                     independent repetitions per mode (default 5)
  --between-tests-seconds N    cooldown after every independent workload (default 5)
  --between-runs-seconds N     backward-compatible alias for --between-tests-seconds
  --server-cooldown-seconds N  measured idle time before first and after last download (default 5)
  --mode-order balanced        randomized six-permutation balanced schedule (default)
  --mode-order random          independently shuffle OFF/BASIC/PLUS each repetition
  --mode-order LIST            fixed comma list, for example plus,off,basic
  --seed N                     reproducible schedule seed; default current epoch second
  --client-host HOST           SSH host/alias for tinyman (default tinyman)
  --client-dir PATH            P4 folder on tinyman
  --client-bin PATH            separate P4 quicinterop binary on tinyman
  --cstate-cpu N              CPU/lcore whose cpuidle state names are recorded (default 19)
  --output-dir PATH            result folder on idex
  --env KEY=VALUE              apply an ENV override to every server/client run
                               repeat this option for multiple variables

Examples:
  ./run_matrix_from_idex.sh

  ./run_matrix_from_idex.sh \
      --downloads 5 \
      --gap-seconds 5 \
      --runs 5 \
      --mode-order balanced \
      --env ENABLE_RECORD=1 \
      --env GQ_LOG_LEVEL=0
USAGE
}

while (($#)); do
    case "$1" in
        --downloads) DOWNLOADS="${2:?missing value}"; shift 2 ;;
        --gap-seconds) GAP_SECONDS="${2:?missing value}"; shift 2 ;;
        --runs) RUNS="${2:?missing value}"; shift 2 ;;
        --between-tests-seconds|--between-runs-seconds) BETWEEN_TESTS_SECONDS="${2:?missing value}"; shift 2 ;;
        --server-cooldown-seconds) SERVER_COOLDOWN_SECONDS="${2:?missing value}"; shift 2 ;;
        --mode-order) MODE_ORDER="${2:?missing value}"; shift 2 ;;
        --seed) SEED="${2:?missing value}"; shift 2 ;;
        --client-host) CLIENT_HOST="${2:?missing value}"; shift 2 ;;
        --client-dir) CLIENT_DIR="${2:?missing value}"; shift 2 ;;
        --client-bin) P4_CLIENT_BIN="${2:?missing value}"; shift 2 ;;
        --cstate-cpu) P4_CSTATE_CPU="${2:?missing value}"; shift 2 ;;
        --output-dir) OUTPUT_DIR="${2:?missing value}"; shift 2 ;;
        --env)
            [[ "${2:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]] || {
                echo "ERROR: --env requires KEY=VALUE" >&2
                exit 2
            }
            ENV_OVERRIDES+=("$2")
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ "$DOWNLOADS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: invalid --downloads" >&2; exit 2; }
[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: invalid --runs" >&2; exit 2; }
[[ "$GAP_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "ERROR: invalid --gap-seconds" >&2; exit 2; }
[[ "$BETWEEN_TESTS_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "ERROR: invalid between-test cooldown" >&2; exit 2; }
[[ "$SERVER_COOLDOWN_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "ERROR: invalid --server-cooldown-seconds" >&2; exit 2; }
[[ -z "$SEED" || "$SEED" =~ ^[0-9]+$ ]] || { echo "ERROR: --seed must be an integer" >&2; exit 2; }
[[ "$P4_CSTATE_CPU" =~ ^[0-9]+$ ]] || { echo "ERROR: --cstate-cpu must be a non-negative integer" >&2; exit 2; }

GAP_US="$(python3 - "$GAP_SECONDS" <<'PY'
from decimal import Decimal
import sys
value = Decimal(sys.argv[1])
result = int(value * Decimal(1_000_000))
if result < 0:
    raise SystemExit(2)
print(result)
PY
)"

STAMP="$(date +%Y%m%d_%H%M%S)"
SEED="${SEED:-$(date +%s)}"
OUTPUT_DIR="${OUTPUT_DIR:-$HERE/matrix_results/$STAMP}"
mkdir -p "$OUTPUT_DIR"

now() { date '+%Y-%m-%dT%H:%M:%S.%3N%:z'; }
notice() { printf '[%s][CONTROLLER] %s\n' "$(now)" "$*"; }
warn() { printf '[%s][CONTROLLER][WARN] %s\n' "$(now)" "$*" >&2; }

has_env_key() {
    local wanted="$1" row
    for row in "${ENV_OVERRIDES[@]}"; do
        [[ "${row%%=*}" == "$wanted" ]] && return 0
    done
    return 1
}

env_value() {
    local wanted="$1" default="$2" row
    for row in "${ENV_OVERRIDES[@]}"; do
        if [[ "${row%%=*}" == "$wanted" ]]; then
            printf '%s\n' "${row#*=}"
            return 0
        fi
    done
    printf '%s\n' "$default"
}

# Measurement defaults. Explicit --env values override them.
has_env_key ENABLE_RECORD || ENV_OVERRIDES+=("ENABLE_RECORD=1")
has_env_key GQ_LOG_LEVEL || ENV_OVERRIDES+=("GQ_LOG_LEVEL=0")
has_env_key ENABLE_SLEEP || ENV_OVERRIDES+=("ENABLE_SLEEP=1")
has_env_key ENABLE_PAUSE || ENV_OVERRIDES+=("ENABLE_PAUSE=1")
has_env_key KEEP_PAUSE_ITERATIONS || ENV_OVERRIDES+=("KEEP_PAUSE_ITERATIONS=1")
has_env_key SHORT_PAUSE_ITERATIONS || ENV_OVERRIDES+=("SHORT_PAUSE_ITERATIONS=1")
has_env_key GQ_IDLE_MODE_OVERRIDE || ENV_OVERRIDES+=("GQ_IDLE_MODE_OVERRIDE=epoll")
has_env_key GQ_IDLE_FALLBACK_OVERRIDE || ENV_OVERRIDES+=("GQ_IDLE_FALLBACK_OVERRIDE=short")
has_env_key GQ_POST_TRANSFER_WAIT_S || ENV_OVERRIDES+=("GQ_POST_TRANSFER_WAIT_S=0")
CLIENT_BIN_EFFECTIVE="$(env_value GQ_INTEROP_CLIENT_BIN "$P4_CLIENT_BIN")"

ENABLE_RECORD_EFFECTIVE="$(env_value ENABLE_RECORD 1)"
case "${ENABLE_RECORD_EFFECTIVE,,}" in
    1|true|yes|on) ALIGNED_RAPL_ENABLED=1 ;;
    *) ALIGNED_RAPL_ENABLED=0 ;;
esac

quote() { printf '%q' "$1"; }

stop_server() {
    local rc=0 app_pids=""
    if [[ -n "$SERVER_PGID" ]]; then
        # Stop only the server application first. The surrounding tee and
        # timestamp pipelines remain alive and can consume the final reports.
        app_pids="$(pgrep -g "$SERVER_PGID" -x quicinteropserver 2>/dev/null || true)"
        if [[ -n "$app_pids" ]]; then
            kill -INT $app_pids 2>/dev/null || true
        else
            kill -INT -- "-$SERVER_PGID" 2>/dev/null || true
        fi
        for _ in $(seq 1 300); do
            kill -0 "$SERVER_PGID" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$SERVER_PGID" 2>/dev/null; then
            warn "server did not stop cleanly after 30s; terminating its process group"
            kill -TERM -- "-$SERVER_PGID" 2>/dev/null || true
            sleep 1
        fi
        if kill -0 "$SERVER_PGID" 2>/dev/null; then
            kill -KILL -- "-$SERVER_PGID" 2>/dev/null || true
        fi
    fi
    if [[ -n "$SERVER_PIPELINE_PID" ]]; then
        wait "$SERVER_PIPELINE_PID" 2>/dev/null || rc=$?
        case "$rc" in
            0|130|141|143) ;;
            *) warn "server display pipeline exited with rc=$rc" ;;
        esac
    fi
    [[ -n "$SERVER_PIDFILE" ]] && rm -f "$SERVER_PIDFILE"
    SERVER_PGID=""
    SERVER_PIPELINE_PID=""
    SERVER_PIDFILE=""
}

trap 'stop_server' EXIT INT TERM

command -v setsid >/dev/null 2>&1 || { echo "ERROR: setsid is required on idex" >&2; exit 2; }
command -v pgrep >/dev/null 2>&1 || { echo "ERROR: pgrep is required on idex" >&2; exit 2; }
ssh -n -o BatchMode=yes -o ConnectTimeout=10 "root@$CLIENT_HOST" true || {
    echo "ERROR: idex cannot SSH non-interactively to root@$CLIENT_HOST" >&2
    exit 2
}
ssh -n "root@$CLIENT_HOST" "test -x $(quote "$CLIENT_DIR/run_client.sh")" || {
    echo "ERROR: P4 client folder is missing on $CLIENT_HOST: $CLIENT_DIR" >&2
    exit 2
}
ssh -n "root@$CLIENT_HOST" "test -x $(quote "$CLIENT_BIN_EFFECTIVE")" || {
    echo "ERROR: separate P4 client binary is missing: $CLIENT_BIN_EFFECTIVE" >&2
    exit 2
}
if [[ "$ALIGNED_RAPL_ENABLED" == 1 ]]; then
    test -x "$HERE/rapl_window.py" || { echo "ERROR: $HERE/rapl_window.py is missing" >&2; exit 2; }
    test -x "$HERE/clock_sync.py" || { echo "ERROR: $HERE/clock_sync.py is missing" >&2; exit 2; }
    ssh -n "root@$CLIENT_HOST" "test -x $(quote "$CLIENT_DIR/rapl_window.py")" || {
        echo "ERROR: client aligned RAPL helper is missing: $CLIENT_DIR/rapl_window.py" >&2
        exit 2
    }
fi

# P4-UNIFIED-RESULTS-CPUIDLE-ENV-V1
CONFIG_DIR="$OUTPUT_DIR/configuration"
RUN_BUNDLE_DIR="$OUTPUT_DIR/runs"
mkdir -p \
    "$CONFIG_DIR/run_env" \
    "$RUN_BUNDLE_DIR/server" \
    "$RUN_BUNDLE_DIR/client"

capture_matrix_configuration() {
    cp -a "$HERE/config.env" "$CONFIG_DIR/server_test_config.env"
    cp -a "$HERE/../../../suite.env" "$CONFIG_DIR/server_suite.env"

    ssh -n "root@$CLIENT_HOST" "cat $(quote "$CLIENT_DIR/config.env")" \
        > "$CONFIG_DIR/client_test_config.env"
    ssh -n "root@$CLIENT_HOST" \
        "cat $(quote "$CLIENT_DIR/../../../suite.env")" \
        > "$CONFIG_DIR/client_suite.env"

    python3 "$HERE/capture_cpuidle_map.py" \
        --cpu "$P4_CSTATE_CPU" --role server \
        --out "$CONFIG_DIR/cpuidle_server.json"

    ssh -n "root@$CLIENT_HOST" \
        "cd $(quote "$CLIENT_DIR") && python3 ./capture_cpuidle_map.py --cpu $(quote "$P4_CSTATE_CPU") --role client" \
        > "$CONFIG_DIR/cpuidle_client.json"

    {
        printf 'DOWNLOADS_PER_RUN=%s\n' "$DOWNLOADS"
        printf 'GAP_SECONDS=%s\n' "$GAP_SECONDS"
        printf 'GAP_US=%s\n' "$GAP_US"
        printf 'RUNS=%s\n' "$RUNS"
        printf 'BETWEEN_TESTS_SECONDS=%s\n' "$BETWEEN_TESTS_SECONDS"
        printf 'P4_CSTATE_CPU=%s\n' "$P4_CSTATE_CPU"
        if [[ -n "${SERVER_COOLDOWN_SECONDS:-}" ]]; then
            printf 'SERVER_COOLDOWN_SECONDS=%s\n' "$SERVER_COOLDOWN_SECONDS"
        fi
        printf 'MODE_ORDER=%s\n' "$MODE_ORDER"
        printf 'SEED=%s\n' "$SEED"
        printf 'CLIENT_HOST=%s\n' "$CLIENT_HOST"
        printf 'CLIENT_DIR=%s\n' "$CLIENT_DIR"
        printf 'CLIENT_BIN=%s\n' "$CLIENT_BIN_EFFECTIVE"
        printf '%s\n' "${ENV_OVERRIDES[@]}"
    } | LC_ALL=C sort -u > "$CONFIG_DIR/matrix_effective_settings.env"

    git -C "$HERE/../../../.." rev-parse HEAD \
        > "$CONFIG_DIR/server_git_commit.txt" 2>/dev/null || true
    ssh -n "root@$CLIENT_HOST" \
        "git -C $(quote "$CLIENT_DIR/../../../..") rev-parse HEAD 2>/dev/null || true" \
        > "$CONFIG_DIR/client_git_commit.txt"

    cat > "$CONFIG_DIR/result_layout.txt" <<EOF
P4 unified result layout
========================
Matrix root: $OUTPUT_DIR
Server run bundles: $OUTPUT_DIR/runs/server/
Client run bundles: $OUTPUT_DIR/runs/client/
Per-run effective ENV: $OUTPUT_DIR/configuration/run_env/
CPUIdle mappings: $OUTPUT_DIR/configuration/cpuidle_{server,client}.json
Tables/charts: $OUTPUT_DIR/tables/

The P4 run bundles are temporarily created in each endpoint's test results/
folder, then moved into this matrix directory. The verified tinyman bundle is
deleted from tinyman after successful transfer, so the matrix directory is the
single P4 result location for this execution.
EOF
}

snapshot_run_environment() {
    local run_id="$1"
    local server_words="$2"
    local client_words="$3"

    (
        cd "$HERE"
        # shellcheck disable=SC2086
        env $server_words ./snapshot_effective_env.sh
    ) > "$CONFIG_DIR/run_env/${run_id}_server_effective.env"

    ssh -n "root@$CLIENT_HOST" \
        "cd $(quote "$CLIENT_DIR") && env $client_words ./snapshot_effective_env.sh" \
        > "$CONFIG_DIR/run_env/${run_id}_client_effective.env"
}

consolidate_run_bundles() {
    local mode="$1"
    local run_id="$2"
    local server_marker="$3"
    local client_marker="$4"
    local server_source=""
    local client_source=""
    local client_name=""
    local server_destination="$RUN_BUNDLE_DIR/server/$run_id"
    local client_destination="$RUN_BUNDLE_DIR/client/$run_id"

    mkdir -p "$server_destination" "$client_destination"

    server_source="$(
        find "$HERE/results" -mindepth 1 -maxdepth 1 -type d \
            -name "*__server__${mode}*" -newer "$server_marker" \
            -printf '%T@ %p\n' 2>/dev/null |
        sort -nr | head -n1 | cut -d' ' -f2-
    )"
    [[ -n "$server_source" && -d "$server_source" ]] || {
        echo "ERROR: cannot find server run bundle for $run_id" >&2
        return 1
    }
    mv "$server_source" "$server_destination/"

    client_source="$(
        ssh -n "root@$CLIENT_HOST" \
            "find $(quote "$CLIENT_DIR/results") -mindepth 1 -maxdepth 1 -type d -name $(quote "*__client__${mode}*") -newer $(quote "$client_marker") -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-"
    )"
    [[ -n "$client_source" ]] || {
        echo "ERROR: cannot find tinyman client run bundle for $run_id" >&2
        return 1
    }
    client_name="$(basename "$client_source")"

    ssh -n "root@$CLIENT_HOST" \
        "tar -C $(quote "$CLIENT_DIR/results") -czf - $(quote "$client_name")" |
        tar -xzf - -C "$client_destination"

    [[ -d "$client_destination/$client_name/details" ]] || {
        echo "ERROR: transferred client bundle failed validation: $run_id" >&2
        return 1
    }

    ssh -n "root@$CLIENT_HOST" \
        "rm -rf $(quote "$client_source") $(quote "$client_marker")"

    notice "TEST $(printf '%02d' "$TEST_INDEX")/$TOTAL_TESTS mode=$mode unified bundles saved under matrix_results/runs"
}

capture_matrix_configuration

SCHEDULE="$OUTPUT_DIR/schedule.tsv"
python3 - "$SCHEDULE" "$RUNS" "$MODE_ORDER" "$SEED" <<'PY'
from __future__ import annotations
import itertools
from pathlib import Path
import random
import sys

path = Path(sys.argv[1])
runs = int(sys.argv[2])
strategy = sys.argv[3].strip().lower()
seed = int(sys.argv[4])
modes = ("off", "basic", "plus")
rng = random.Random(seed)

schedule = []
if strategy == "balanced":
    permutations = list(itertools.permutations(modes))
    rng.shuffle(permutations)
    orders = [permutations[index % len(permutations)] for index in range(runs)]
elif strategy == "random":
    orders = []
    for _ in range(runs):
        order = list(modes)
        rng.shuffle(order)
        orders.append(tuple(order))
else:
    order = tuple(item.strip() for item in strategy.split(",") if item.strip())
    if len(order) != 3 or set(order) != set(modes):
        raise SystemExit("ERROR: fixed --mode-order must contain off,basic,plus exactly once")
    orders = [order for _ in range(runs)]

rows = ["test_index\trepetition\tposition\tmode"]
test_index = 0
for repetition, order in enumerate(orders, 1):
    for position, mode in enumerate(order, 1):
        test_index += 1
        rows.append(f"{test_index}\t{repetition}\t{position}\t{mode}")
path.write_text("\n".join(rows) + "\n", encoding="utf-8")
PY

TOTAL_TESTS=$((RUNS * 3))
notice "P4 schedule seed=$SEED strategy=$MODE_ORDER"
while IFS=$'\t' read -r test_index repetition position mode; do
    [[ "$test_index" == test_index ]] && continue
    notice "schedule test=$test_index/$TOTAL_TESTS repetition=$repetition/$RUNS position=$position/3 mode=$mode"
done < "$SCHEDULE"

python3 - "$OUTPUT_DIR/matrix_config.json" "$CLIENT_HOST" "$CLIENT_DIR" "$CLIENT_BIN_EFFECTIVE" \
    "$DOWNLOADS" "$GAP_SECONDS" "$GAP_US" "$RUNS" "$MODE_ORDER" "$SEED" "$SCHEDULE" \
    "${ENV_OVERRIDES[@]}" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
schedule_path = Path(sys.argv[11])
schedule = []
for line in schedule_path.read_text(encoding="utf-8").splitlines()[1:]:
    test_index, repetition, position, mode = line.split("\t")
    schedule.append({
        "test_index": int(test_index),
        "repetition": int(repetition),
        "position": int(position),
        "mode": mode,
    })
path.write_text(json.dumps({
    "controller_host": "idex",
    "client_host": sys.argv[2],
    "server_dir": str(Path.cwd()),
    "client_dir": sys.argv[3],
    "client_binary": sys.argv[4],
    "downloads_per_run": int(sys.argv[5]),
    "gap_seconds": float(sys.argv[6]),
    "gap_us": int(sys.argv[7]),
    "repetitions_per_mode": int(sys.argv[8]),
    "mode_order_strategy": sys.argv[9],
    "schedule_seed": int(sys.argv[10]),
    "schedule": schedule,
    "environment": sys.argv[12:],
    "aligned_rapl_scope": "pre-cooldown + P4 downloads/gaps + post-cooldown; reporting tail excluded",
}, indent=2) + "\n", encoding="utf-8")
PY

COMPLETED_TESTS=0
exec 9< "$SCHEDULE"
while IFS=$'\t' read -r TEST_INDEX rep position mode <&9; do
    [[ "$TEST_INDEX" == test_index ]] && continue
    run_id="rep$(printf '%02d' "$rep")_${mode}"
    server_log="$OUTPUT_DIR/server_${run_id}.log"
    client_log="$OUTPUT_DIR/client_${run_id}.log"
    server_live_log="$OUTPUT_DIR/server_${run_id}_timestamped.log"
    client_live_log="$OUTPUT_DIR/client_${run_id}_timestamped.log"
    marker="$HERE/results/.matrix_${run_id}_$(date +%s%N).marker"
    SERVER_PIDFILE="$HERE/runtime/server/.matrix_${run_id}.pid"
    mkdir -p "$HERE/results" "$HERE/runtime/server"
    client_result_marker="/tmp/p4_matrix_${run_id}_$$_${TEST_INDEX}.marker"
    : > "$marker"
    ssh -n "root@$CLIENT_HOST" "touch $(quote "$client_result_marker")"
    rm -f "$SERVER_PIDFILE" "$server_log" "$client_log" "$server_live_log" "$client_live_log"

    echo
    notice "=========================================================================="
    notice "TEST $(printf '%02d' "$TEST_INDEX")/$(printf '%02d' "$TOTAL_TESTS") | REPETITION $rep/$RUNS | POSITION $position/3 | MODE=$mode | DOWNLOADS=$DOWNLOADS | GAP=${GAP_SECONDS}s | EDGE_COOLDOWN=${SERVER_COOLDOWN_SECONDS}s"
    notice "=========================================================================="

    COMMON_RUN_ENV=()
    for item in "${ENV_OVERRIDES[@]}"; do
        case "${item%%=*}" in
            GQ_INTEROP_CLIENT_BIN|GQ_POST_TRANSFER_WAIT_S) continue ;;
        esac
        COMMON_RUN_ENV+=("$item")
    done
    COMMON_RUN_ENV+=(
        "DOWNLOADS_PER_RUN=$DOWNLOADS"
        "GAP_US=$GAP_US"
        "GQ_MODE_OVERRIDE=$mode"
        "GQ_POST_TRANSFER_WAIT_S=$SERVER_COOLDOWN_SECONDS"
        "P4_SERVER_COOLDOWN_SECONDS=$SERVER_COOLDOWN_SECONDS"
    )

    server_env_words=""
    for item in "${COMMON_RUN_ENV[@]}"; do
        server_env_words+="$(quote "$item") "
    done

    CLIENT_RUN_ENV=(
        "${COMMON_RUN_ENV[@]}"
        "GQ_INTEROP_CLIENT_BIN=$CLIENT_BIN_EFFECTIVE"
    )
    client_env_words=""
    for item in "${CLIENT_RUN_ENV[@]}"; do
        client_env_words+="$(quote "$item") "
    done

    snapshot_run_environment "$run_id" "$server_env_words" "$client_env_words"

    server_inner="cd $(quote "$HERE") && echo \$\$ > $(quote "$SERVER_PIDFILE") && exec env $server_env_words ./run_server.sh"
    (
        setsid bash -lc "$server_inner" 2>&1 |
            tee "$server_log" |
            python3 -u "$HERE/live_prefix.py" \
                --role server --test-index "$TEST_INDEX" --total-tests "$TOTAL_TESTS" \
                --mode "$mode" --downloads "$DOWNLOADS" |
            tee "$server_live_log"
    ) &
    SERVER_PIPELINE_PID=$!

    for _ in $(seq 1 100); do
        [[ -s "$SERVER_PIDFILE" ]] && break
        sleep 0.05
    done
    [[ -s "$SERVER_PIDFILE" ]] || { echo "ERROR: server process ID was not created" >&2; stop_server; exit 1; }
    SERVER_PGID="$(cat "$SERVER_PIDFILE")"
    [[ "$SERVER_PGID" =~ ^[0-9]+$ ]] || { echo "ERROR: invalid server process ID: $SERVER_PGID" >&2; stop_server; exit 1; }

    ready=0
    inner_server_log=""
    for ((second=0; second<READY_TIMEOUT_SECONDS; second++)); do
        inner_server_log="$(find "$HERE/logs" -maxdepth 1 -type f -name "server_${mode}_*.log" -newer "$marker" -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
        if [[ -n "$inner_server_log" && -f "$inner_server_log" ]] && grep -Eq 'Waiting forever\.|Port 0 Link up' "$inner_server_log" 2>/dev/null; then
            ready=1
            break
        fi
        kill -0 "$SERVER_PGID" 2>/dev/null || break
        sleep 1
    done
    [[ "$ready" == 1 ]] || { echo "ERROR: server was not ready within ${READY_TIMEOUT_SECONDS}s" >&2; stop_server; exit 1; }
    notice "TEST $(printf '%02d' "$TEST_INDEX")/$TOTAL_TESTS mode=$mode server ready"

    server_aligned_state="$OUTPUT_DIR/aligned_server_${run_id}.start.json"
    server_aligned_result="$OUTPUT_DIR/aligned_server_${run_id}.json"
    client_aligned_result="$OUTPUT_DIR/aligned_client_${run_id}.json"
    clock_sync_result="$OUTPUT_DIR/clock_sync_${run_id}.json"
    client_remote_state="/tmp/p4_aligned_client_${run_id}_$$.start.json"
    client_remote_result="/tmp/p4_aligned_client_${run_id}_$$.json"

    # P4-SERVER-COOLDOWN-V2
    # Both endpoint counters start before the deterministic pre-cooldown. They
    # are stopped after the last successful download plus the deterministic
    # post-cooldown. Client/server report generation is outside this window.
    client_rapl_started=0
    if [[ "$ALIGNED_RAPL_ENABLED" == 1 ]]; then
        python3 "$HERE/clock_sync.py" \
            --host "$CLIENT_HOST" --out "$clock_sync_result" --samples 5
        python3 "$HERE/rapl_window.py" start \
            --state "$server_aligned_state" --label "P4 server edge-cooldown window" \
            --role server --mode "$mode" --run-id "$run_id"
        if ssh -n "root@$CLIENT_HOST" \
            "cd $(quote "$CLIENT_DIR") && python3 ./rapl_window.py start --state $(quote "$client_remote_state") --label $(quote 'P4 client edge-cooldown window') --role client --mode $(quote "$mode") --run-id $(quote "$run_id")"; then
            client_rapl_started=1
        else
            warn "client aligned RAPL start failed for $run_id; client and combined energy will be N/A"
        fi
    fi

    notice "TEST $(printf '%02d' "$TEST_INDEX")/$TOTAL_TESTS mode=$mode PRE-COOLDOWN ${SERVER_COOLDOWN_SECONDS}s (server running; no download yet)"
    sleep "$SERVER_COOLDOWN_SECONDS"
    notice "TEST $(printf '%02d' "$TEST_INDEX")/$TOTAL_TESTS mode=$mode starting tinyman client"

    client_inner="set -uo pipefail; cd $(quote "$CLIENT_DIR"); client_rc=0; set +e; env $client_env_words ./run_client.sh; client_rc=\$?; set -e; exit \$client_rc"

    client_status_file="$OUTPUT_DIR/.client_${run_id}.pipeline_status"
    rm -f "$client_status_file"
    (
        set +e
        ssh -n "root@$CLIENT_HOST" "bash -lc $(quote "$client_inner")" 2>&1 |
            tee "$client_log" |
            python3 -u "$HERE/live_prefix.py" \
                --role client --test-index "$TEST_INDEX" --total-tests "$TOTAL_TESTS" \
                --mode "$mode" --downloads "$DOWNLOADS" |
            tee "$client_live_log"
        pipeline_statuses=("${PIPESTATUS[@]}")
        printf '%s\n' "${pipeline_statuses[*]}" > "$client_status_file"
        exit 0
    ) &
    client_pipeline_pid=$!

    final_download_pattern="[GreenQUIC-P4] request=${DOWNLOADS}/${DOWNLOADS} complete_us="
    workload_complete=0
    while kill -0 "$client_pipeline_pid" 2>/dev/null; do
        if grep -F "$final_download_pattern" "$client_log" 2>/dev/null | tail -n1 | grep -Fq 'success=1'; then
            workload_complete=1
            break
        fi
        sleep 0.1
    done
    if [[ "$workload_complete" == 0 ]] && \
       grep -F "$final_download_pattern" "$client_log" 2>/dev/null | tail -n1 | grep -Fq 'success=1'; then
        workload_complete=1
    fi

    if [[ "$workload_complete" == 1 ]]; then
        notice "TEST $(printf '%02d' "$TEST_INDEX")/$TOTAL_TESTS mode=$mode FINAL DOWNLOAD COMPLETE; POST-COOLDOWN ${SERVER_COOLDOWN_SECONDS}s"
        # run_role.sh receives the same GQ_POST_TRANSFER_WAIT_S, so the client
        # and server stay in the post-transfer idle period while this runs.
        sleep "$SERVER_COOLDOWN_SECONDS"
    else
        warn "final successful download marker was not observed for $run_id; closing RAPL window immediately"
    fi

    if [[ "$ALIGNED_RAPL_ENABLED" == 1 ]]; then
        server_rapl_rc=0
        python3 "$HERE/rapl_window.py" finish \
            --state "$server_aligned_state" --out "$server_aligned_result" || server_rapl_rc=$?

        if [[ "$client_rapl_started" == 1 ]]; then
            if ! ssh -n "root@$CLIENT_HOST" \
                "cd $(quote "$CLIENT_DIR") && python3 ./rapl_window.py finish --state $(quote "$client_remote_state") --out $(quote "$client_remote_result")"; then
                warn "client aligned RAPL finish failed for $run_id"
            fi
            if ! ssh -n "root@$CLIENT_HOST" "cat $(quote "$client_remote_result")" > "$client_aligned_result"; then
                warn "failed to retrieve client aligned RAPL JSON for $run_id"
                rm -f "$client_aligned_result"
            fi
        else
            rm -f "$client_aligned_result"
        fi
        ssh -n "root@$CLIENT_HOST" "rm -f $(quote "$client_remote_state") $(quote "$client_remote_result")" || true
        [[ "$server_rapl_rc" == 0 ]] || warn "server aligned RAPL unavailable for $run_id"
    fi

    wait "$client_pipeline_pid" || true
    [[ -s "$client_status_file" ]] || {
        echo "ERROR: client pipeline status was not written for $run_id" >&2
        stop_server
        exit 1
    }
    read -r -a statuses < "$client_status_file"
    rm -f "$client_status_file"
    client_rc="${statuses[0]:-1}"

    stop_server

    server_summary="$(find "$HERE/results" -type f -path '*/details/*' -name '*_summary.txt' -newer "$marker" -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
    if [[ -n "$server_summary" && -f "$server_summary" ]] && ! grep -q '^GreenQUIC Run Summary$' "$server_log" 2>/dev/null; then
        printf '\n' >> "$server_log"
        cat "$server_summary" >> "$server_log"
    fi
    consolidate_run_bundles         "$mode" "$run_id" "$marker" "$client_result_marker"
    rm -f "$marker"

    if [[ "$client_rc" != 0 ]]; then
        echo "ERROR: client failed: test=$TEST_INDEX mode=$mode repetition=$rep rc=$client_rc" >&2
        python3 "$HERE/aggregate_p4_matrix.py" --input "$OUTPUT_DIR" --runs "$RUNS" || true
        exit "$client_rc"
    fi

    COMPLETED_TESTS=$((COMPLETED_TESTS + 1))
    notice "TEST $(printf '%02d' "$TEST_INDEX")/$TOTAL_TESTS mode=$mode COMPLETE ($COMPLETED_TESTS/$TOTAL_TESTS)"
    [[ "$COMPLETED_TESTS" -eq "$TOTAL_TESTS" ]] || sleep "$BETWEEN_TESTS_SECONDS"
done
exec 9<&-

if [[ "$COMPLETED_TESTS" -ne "$TOTAL_TESTS" ]]; then
    echo "ERROR: controller completed $COMPLETED_TESTS/$TOTAL_TESTS workloads; refusing to print SUCCESS" >&2
    python3 "$HERE/aggregate_p4_matrix.py" --input "$OUTPUT_DIR" --runs "$RUNS" || true
    exit 1
fi

python3 "$HERE/aggregate_p4_matrix.py" --input "$OUTPUT_DIR" --runs "$RUNS"
python3 "$HERE/p4_finalize_matrix.py" --matrix "$OUTPUT_DIR"

echo
notice "SUCCESS: all $COMPLETED_TESTS/$TOTAL_TESTS P4 workloads completed"
notice "Matrix results: $OUTPUT_DIR"
