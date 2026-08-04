#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
REMOTE_HOST="${REMOTE_HOST:-tinyman}"
REMOTE_ROOT="${REMOTE_ROOT:-/root/mohsen/greenquic_test_suite_v22}"
[[ "$(hostname -s)" == idex ]] || { echo "ERROR: run this orchestrator on idex" >&2; exit 1; }

"$ROOT/check_v22_install.sh"
ssh "root@$REMOTE_HOST" "cd '$REMOTE_ROOT' && ./check_v22_install.sh"
"$ROOT/test_cases/pretests/prepare_10g_on_idex.sh"

run_pair() {
    local rel="$1" name="$2" server_pid rc=0 server_rc=0
    local case_dir="$ROOT/$rel"
    echo "============================================================"
    echo "Starting $name server on idex"
    echo "============================================================"
    (cd "$case_dir" && exec ./run_server.sh) &
    server_pid=$!
    cleanup_pair() {
        if kill -0 "$server_pid" 2>/dev/null; then kill -INT "$server_pid" 2>/dev/null || true; fi
        wait "$server_pid" 2>/dev/null || true
    }
    trap cleanup_pair RETURN INT TERM
    sleep "${SERVER_START_WAIT_S:-5}"
    if ! kill -0 "$server_pid" 2>/dev/null; then
        wait "$server_pid" || server_rc=$?
        echo "ERROR: $name server exited during startup (rc=$server_rc)" >&2
        return 2
    fi
    echo "Running $name client on $REMOTE_HOST"
    ssh "root@$REMOTE_HOST" "cd '$REMOTE_ROOT/$rel' && ./run_client.sh" || rc=$?
    cleanup_pair
    trap - RETURN INT TERM
    [[ "$rc" == 0 ]] || return "$rc"
    echo "$name completed"
}

run_pair test_cases/pretests/P0_smoke_1MiB P0
run_pair test_cases/pretests/P1_goodput_off_10GiB P1
run_pair test_cases/pretests/P2_goodput_basic_10GiB P2
python3 "$ROOT/common/bin/compare_pretest_goodput.py" --suite-root "$ROOT"
