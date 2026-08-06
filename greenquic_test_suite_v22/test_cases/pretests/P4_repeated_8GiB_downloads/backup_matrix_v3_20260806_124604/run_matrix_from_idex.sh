#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
CLIENT_HOST="${CLIENT_HOST:-tinyman}"
CLIENT_DIR="${CLIENT_DIR:-/root/greenquic_snapshot/greenquic_test_suite_v22/test_cases/pretests/P4_repeated_8GiB_downloads}"
DOWNLOADS=5
GAP_SECONDS=5
RUNS=5
BETWEEN_RUNS_SECONDS=5
READY_TIMEOUT_SECONDS=90
OUTPUT_DIR=""
ENV_OVERRIDES=()
MODES=(off basic plus)
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
  --between-runs-seconds N     pause after each independent workload (default 5)
  --client-host HOST           SSH host/alias for tinyman (default tinyman)
  --client-dir PATH            P4 folder on tinyman
  --output-dir PATH            result folder on idex
  --env KEY=VALUE              apply an ENV override to every server/client run
                               repeat this option for multiple variables

Examples:
  ./run_matrix_from_idex.sh

  ./run_matrix_from_idex.sh \
      --downloads 5 \
      --gap-seconds 5 \
      --runs 5 \
      --env ENABLE_RECORD=1 \
      --env GQ_LOG_LEVEL=0

  ./run_matrix_from_idex.sh --runs 1 --env ENABLE_RECORD=0 --env GQ_LOG_LEVEL=1
USAGE
}

while (($#)); do
    case "$1" in
        --downloads) DOWNLOADS="${2:?missing value}"; shift 2 ;;
        --gap-seconds) GAP_SECONDS="${2:?missing value}"; shift 2 ;;
        --runs) RUNS="${2:?missing value}"; shift 2 ;;
        --between-runs-seconds) BETWEEN_RUNS_SECONDS="${2:?missing value}"; shift 2 ;;
        --client-host) CLIENT_HOST="${2:?missing value}"; shift 2 ;;
        --client-dir) CLIENT_DIR="${2:?missing value}"; shift 2 ;;
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
[[ "$BETWEEN_RUNS_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "ERROR: invalid --between-runs-seconds" >&2; exit 2; }

GAP_US="$(
    python3 - "$GAP_SECONDS" <<'PY'
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
OUTPUT_DIR="${OUTPUT_DIR:-$HERE/matrix_results/$STAMP}"
mkdir -p "$OUTPUT_DIR"

has_env_key() {
    local wanted="$1" row
    for row in "${ENV_OVERRIDES[@]}"; do
        [[ "${row%%=*}" == "$wanted" ]] && return 0
    done
    return 1
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

quote() {
    printf '%q' "$1"
}

build_env_words() {
    local mode="$1" item quoted words=()
    for item in \
        "${ENV_OVERRIDES[@]}" \
        "DOWNLOADS_PER_RUN=$DOWNLOADS" \
        "GAP_US=$GAP_US" \
        "GQ_MODE_OVERRIDE=$mode"; do
        printf -v quoted '%q' "$item"
        words+=("$quoted")
    done
    printf '%s ' "${words[@]}"
}

stop_server() {
    local rc=0
    if [[ -n "$SERVER_PGID" ]]; then
        kill -INT -- "-$SERVER_PGID" 2>/dev/null || true
        for _ in $(seq 1 150); do
            kill -0 "$SERVER_PGID" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$SERVER_PGID" 2>/dev/null; then
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
            *) echo "[P4:WARN] server display pipeline exited with rc=$rc" >&2 ;;
        esac
    fi
    [[ -n "$SERVER_PIDFILE" ]] && rm -f "$SERVER_PIDFILE"
    SERVER_PGID=""
    SERVER_PIPELINE_PID=""
    SERVER_PIDFILE=""
}

trap 'stop_server' EXIT INT TERM

command -v setsid >/dev/null 2>&1 || {
    echo "ERROR: setsid is required on idex" >&2
    exit 2
}
ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$CLIENT_HOST" true || {
    echo "ERROR: idex cannot SSH non-interactively to root@$CLIENT_HOST" >&2
    exit 2
}
ssh "root@$CLIENT_HOST" "test -x $(quote "$CLIENT_DIR/run_client.sh")" || {
    echo "ERROR: P4 client folder is missing on $CLIENT_HOST: $CLIENT_DIR" >&2
    exit 2
}

python3 - "$OUTPUT_DIR/matrix_config.json" "$CLIENT_HOST" "$CLIENT_DIR" \
    "$DOWNLOADS" "$GAP_SECONDS" "$GAP_US" "$RUNS" "${ENV_OVERRIDES[@]}" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
path.write_text(json.dumps({
    "controller_host": "idex",
    "client_host": sys.argv[2],
    "server_dir": str(Path.cwd()),
    "client_dir": sys.argv[3],
    "downloads_per_run": int(sys.argv[4]),
    "gap_seconds": float(sys.argv[5]),
    "gap_us": int(sys.argv[6]),
    "repetitions_per_mode": int(sys.argv[7]),
    "modes": ["off", "basic", "plus"],
    "environment": sys.argv[8:],
}, indent=2) + "\n", encoding="utf-8")
PY

TOTAL_TESTS=$((RUNS * ${#MODES[@]}))
TEST_INDEX=0

for ((rep=1; rep<=RUNS; rep++)); do
    for mode in "${MODES[@]}"; do
        TEST_INDEX=$((TEST_INDEX + 1))
        run_id="rep$(printf '%02d' "$rep")_${mode}"
        server_log="$OUTPUT_DIR/server_${run_id}.log"
        client_log="$OUTPUT_DIR/client_${run_id}.log"
        marker="$HERE/results/.matrix_${run_id}_$(date +%s%N).marker"
        SERVER_PIDFILE="$HERE/runtime/server/.matrix_${run_id}.pid"
        mkdir -p "$HERE/results" "$HERE/runtime/server"
        : > "$marker"
        rm -f "$SERVER_PIDFILE" "$server_log" "$client_log"

        echo
        echo "=========================================================================="
        printf 'TEST %02d/%02d | REPETITION %d/%d | MODE=%s | DOWNLOADS=%d | GAP=%ss\n' \
            "$TEST_INDEX" "$TOTAL_TESTS" "$rep" "$RUNS" "$mode" "$DOWNLOADS" "$GAP_SECONDS"
        echo "=========================================================================="

        env_words="$(build_env_words "$mode")"
        server_inner="cd $(quote "$HERE") && echo \$\$ > $(quote "$SERVER_PIDFILE") && exec env $env_words ./run_server.sh"

        (
            setsid bash -lc "$server_inner" 2>&1 |
                tee "$server_log" |
                python3 -u "$HERE/live_prefix.py" \
                    --role server \
                    --test-index "$TEST_INDEX" \
                    --total-tests "$TOTAL_TESTS" \
                    --mode "$mode" \
                    --downloads "$DOWNLOADS"
        ) &
        SERVER_PIPELINE_PID=$!

        for _ in $(seq 1 100); do
            [[ -s "$SERVER_PIDFILE" ]] && break
            sleep 0.05
        done
        [[ -s "$SERVER_PIDFILE" ]] || {
            echo "ERROR: server process ID was not created" >&2
            stop_server
            exit 1
        }
        SERVER_PGID="$(cat "$SERVER_PIDFILE")"
        [[ "$SERVER_PGID" =~ ^[0-9]+$ ]] || {
            echo "ERROR: invalid server process ID: $SERVER_PGID" >&2
            stop_server
            exit 1
        }

        ready=0
        inner_server_log=""
        for ((second=0; second<READY_TIMEOUT_SECONDS; second++)); do
            inner_server_log="$(
                find "$HERE/logs" -maxdepth 1 -type f \
                    -name "server_${mode}_*.log" -newer "$marker" \
                    -printf '%T@ %p\n' 2>/dev/null |
                sort -nr |
                head -n1 |
                cut -d' ' -f2-
            )"
            if [[ -n "$inner_server_log" && -f "$inner_server_log" ]] &&
               grep -Eq 'Waiting forever\.|Port 0 Link up' "$inner_server_log" 2>/dev/null; then
                ready=1
                break
            fi
            kill -0 "$SERVER_PGID" 2>/dev/null || break
            sleep 1
        done
        [[ "$ready" == 1 ]] || {
            echo "ERROR: server was not ready within ${READY_TIMEOUT_SECONDS}s" >&2
            stop_server
            exit 1
        }

        echo "[P4][TEST $(printf '%02d' "$TEST_INDEX")/$TOTAL_TESTS][MODE=$mode] server ready; starting tinyman client"

        client_inner="cd $(quote "$CLIENT_DIR") && exec env $env_words ./run_client.sh"
        set +e
        ssh "root@$CLIENT_HOST" "bash -lc $(quote "$client_inner")" 2>&1 |
            tee "$client_log" |
            python3 -u "$HERE/live_prefix.py" \
                --role client \
                --test-index "$TEST_INDEX" \
                --total-tests "$TOTAL_TESTS" \
                --mode "$mode" \
                --downloads "$DOWNLOADS"
        statuses=("${PIPESTATUS[@]}")
        set -e
        client_rc="${statuses[0]}"

        stop_server

        # Add the complete server summary to the local server log after its
        # result bundle has been finalized.
        server_summary="$(
            find "$HERE/results" -type f -path '*/details/*' \
                -name '*_summary.txt' -newer "$marker" -printf '%T@ %p\n' 2>/dev/null |
            sort -nr |
            head -n1 |
            cut -d' ' -f2-
        )"
        if [[ -n "$server_summary" && -f "$server_summary" ]]; then
            printf '\n' >> "$server_log"
            cat "$server_summary" >> "$server_log"
        fi
        rm -f "$marker"

        if [[ "$client_rc" != 0 ]]; then
            echo "ERROR: client failed: test=$TEST_INDEX mode=$mode repetition=$rep rc=$client_rc" >&2
            python3 "$HERE/aggregate_p4_matrix.py" \
                --input "$OUTPUT_DIR" \
                --runs "$RUNS" || true
            exit "$client_rc"
        fi

        echo "[P4][TEST $(printf '%02d' "$TEST_INDEX")/$TOTAL_TESTS][MODE=$mode] COMPLETE"
        [[ "$TEST_INDEX" -eq "$TOTAL_TESTS" ]] || sleep "$BETWEEN_RUNS_SECONDS"
    done
done

python3 "$HERE/aggregate_p4_matrix.py" \
    --input "$OUTPUT_DIR" \
    --runs "$RUNS"

echo
echo "SUCCESS: all $TOTAL_TESTS P4 workloads completed"
echo "Matrix results: $OUTPUT_DIR"
