#!/usr/bin/env bash
set -Eeuo pipefail

# Public P4 controller wrapper.
#
# The preserved controller core contains the full scheduling, aligned-RAPL,
# bundling and aggregation logic. This wrapper adapts it for the fresh
# /root/mohsen installation and the two-ended E810 DPDK startup requirement.
#
# Correct startup/measurement order:
#   server process starts
#   -> client process starts
#   -> both DPDK ports report link up
#   -> one QUIC connection is established
#   -> P4 client waits at a start gate (NO GET yet)
#   -> aligned RAPL starts
#   -> deterministic pre-cooldown
#   -> gate released
#   -> 5 sequential completed 8-GiB streams with configured gaps
#   -> deterministic post-cooldown
#   -> aligned RAPL stops

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
CORE="$HERE/run_matrix_from_idex_core.sh"

[[ -f "$CORE" ]] || {
    echo "ERROR: missing preserved P4 controller core: $CORE" >&2
    exit 2
}

# P4 result bundling generates C-state SVGs. Fail before any measured workload
# if the plotting dependency is missing instead of wasting a transfer.
python3 -c 'import matplotlib' >/dev/null 2>&1 || {
    echo "ERROR: Python matplotlib is required for P4 result bundling." >&2
    echo "Install python3-matplotlib on both idex and tinyman before running P4." >&2
    exit 2
}

TMP="$(mktemp "$HERE/.run_matrix_fixed.XXXXXX.sh")"
cleanup() { rm -f -- "$TMP"; }
trap cleanup EXIT

python3 - "$CORE" "$TMP" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text(encoding="utf-8")


def replace_once(old: str, new: str, label: str) -> None:
    global src
    count = src.count(old)
    if count != 1:
        raise SystemExit(
            f"ERROR: expected exactly one {label} block, found {count}; "
            "refusing to run an unexpected controller core"
        )
    src = src.replace(old, new, 1)


# Fresh-install paths.
src = src.replace(
    "/root/greenquic_snapshot/greenquic_test_suite_v22/test_cases/pretests/P4_repeated_8GiB_downloads",
    "/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P4_repeated_8GiB_downloads",
)
src = src.replace(
    "/root/greenquic_snapshot/msquic/build-greenquic-p4/bin/Release/quicinterop",
    "/root/mohsen/msquic/build-greenquic-p4/bin/Release/quicinterop",
)

# Require the corrected V2 client before any test starts.
needle = '''ssh -n "root@$CLIENT_HOST" "test -x $(quote "$CLIENT_BIN_EFFECTIVE")" || {
    echo "ERROR: separate P4 client binary is missing: $CLIENT_BIN_EFFECTIVE" >&2
    exit 2
}
'''
replacement = needle + '''ssh -n "root@$CLIENT_HOST" "grep -aFq -- GreenQUIC-P4-SEQUENCE-V2 $(quote \"$CLIENT_BIN_EFFECTIVE\")" || {
    echo "ERROR: tinyman P4 binary is not the corrected V2 sequential client: $CLIENT_BIN_EFFECTIVE" >&2
    exit 2
}
ssh -n "root@$CLIENT_HOST" "python3 -c 'import matplotlib'" >/dev/null 2>&1 || {
    echo "ERROR: python3-matplotlib is missing on $CLIENT_HOST" >&2
    exit 2
}
'''
replace_once(needle, replacement, "P4 binary preflight")

# The server can remain in DPDK link-check until Tinyman starts its DPDK port.
# Only require the server process to survive initial startup here.
old_ready = r'''    ready=0
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
'''
new_ready = r'''    sleep 1
    kill -0 "$SERVER_PGID" 2>/dev/null || {
        echo "ERROR: server exited during initial DPDK startup" >&2
        [[ -f "$server_log" ]] && tail -n 100 "$server_log" >&2 || true
        stop_server
        exit 1
    }
    notice "TEST $(printf '%02d' "$TEST_INDEX")/$TOTAL_TESTS mode=$mode server process alive; starting peer DPDK endpoint next"
'''
replace_once(old_ready, new_ready, "server readiness")

# Create a unique remote start gate and pass it to the P4 client. The client
# connects first and then blocks before GET #1 until the controller touches it.
old_client_env = '''    CLIENT_RUN_ENV=(
        "${COMMON_RUN_ENV[@]}"
        "GQ_INTEROP_CLIENT_BIN=$CLIENT_BIN_EFFECTIVE"
    )
'''
new_client_env = '''    client_start_gate="/tmp/p4_start_gate_${run_id}_$$_${TEST_INDEX}"
    ssh -n "root@$CLIENT_HOST" "rm -f $(quote "$client_start_gate")"

    CLIENT_RUN_ENV=(
        "${COMMON_RUN_ENV[@]}"
        "GQ_INTEROP_CLIENT_BIN=$CLIENT_BIN_EFFECTIVE"
        "GQ_INTEROP_P4_START_GATE=$client_start_gate"
        "GQ_INTEROP_P4_GATE_TIMEOUT_US=120000000"
    )
'''
replace_once(old_client_env, new_client_env, "client environment")

# Replace the old sequence from aligned-RAPL setup through client launch. The
# client must be launched first so its DPDK port can bring the cable up, but it
# cannot issue GET #1 until the gate is released after the measured pre-cooldown.
start = src.index('    server_aligned_state="$OUTPUT_DIR/aligned_server_${run_id}.start.json"\n')
end_marker = '    client_pipeline_pid=$!\n'
end = src.index(end_marker, start) + len(end_marker)
old_block = src[start:end]

new_block = r'''    server_aligned_state="$OUTPUT_DIR/aligned_server_${run_id}.start.json"
    server_aligned_result="$OUTPUT_DIR/aligned_server_${run_id}.json"
    client_aligned_result="$OUTPUT_DIR/aligned_client_${run_id}.json"
    clock_sync_result="$OUTPUT_DIR/clock_sync_${run_id}.json"
    client_remote_state="/tmp/p4_aligned_client_${run_id}_$$.start.json"
    client_remote_result="/tmp/p4_aligned_client_${run_id}_$$.json"

    notice "TEST $(printf '%02d' "$TEST_INDEX")/$TOTAL_TESTS mode=$mode starting tinyman client to activate peer DPDK port"

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

    # Wait for REAL readiness on both endpoints:
    #   - IDEX DPDK port reports Link up
    #   - Tinyman has established the QUIC connection and reached the no-GET gate
    link_ready=0
    gate_ready=0
    for ((second=0; second<READY_TIMEOUT_SECONDS; second++)); do
        grep -Fq 'Port 0 Link up' "$server_log" 2>/dev/null && link_ready=1 || true
        grep -Fq '[GreenQUIC-P4] ready_for_start_gate_us=' "$client_log" 2>/dev/null && gate_ready=1 || true

        if [[ "$link_ready" == 1 && "$gate_ready" == 1 ]]; then
            break
        fi

        kill -0 "$SERVER_PGID" 2>/dev/null || {
            echo "ERROR: server exited before P4 readiness" >&2
            stop_server
            exit 1
        }
        kill -0 "$client_pipeline_pid" 2>/dev/null || {
            echo "ERROR: client exited before reaching P4 start gate" >&2
            tail -n 150 "$client_log" >&2 || true
            stop_server
            exit 1
        }
        sleep 1
    done

    [[ "$link_ready" == 1 ]] || {
        echo "ERROR: IDEX DPDK port did not report Link up within ${READY_TIMEOUT_SECONDS}s" >&2
        stop_server
        exit 1
    }
    [[ "$gate_ready" == 1 ]] || {
        echo "ERROR: Tinyman did not establish QUIC and reach the P4 start gate within ${READY_TIMEOUT_SECONDS}s" >&2
        stop_server
        exit 1
    }

    notice "TEST $(printf '%02d' "$TEST_INDEX")/$TOTAL_TESTS mode=$mode DPDK link UP and QUIC connection established; no GET sent yet"

    # P4-SERVER-COOLDOWN-V3
    # Start aligned counters only after DPDK/QUIC startup is complete. The
    # following pre-cooldown is therefore a true connected idle window.
    client_rapl_started=0
    if [[ "$ALIGNED_RAPL_ENABLED" == 1 ]]; then
        python3 "$HERE/clock_sync.py" \
            --host "$CLIENT_HOST" --out "$clock_sync_result" --samples 5
        python3 "$HERE/rapl_window.py" start \
            --state "$server_aligned_state" --label "P4 server connected edge-cooldown window" \
            --role server --mode "$mode" --run-id "$run_id"
        if ssh -n "root@$CLIENT_HOST" \
            "cd $(quote "$CLIENT_DIR") && python3 ./rapl_window.py start --state $(quote "$client_remote_state") --label $(quote 'P4 client connected edge-cooldown window') --role client --mode $(quote "$mode") --run-id $(quote "$run_id")"; then
            client_rapl_started=1
        else
            warn "client aligned RAPL start failed for $run_id; client and combined energy will be N/A"
        fi
    fi

    notice "TEST $(printf '%02d' "$TEST_INDEX")/$TOTAL_TESTS mode=$mode PRE-COOLDOWN ${SERVER_COOLDOWN_SECONDS}s (both endpoints linked + QUIC connected; NO download)"
    sleep "$SERVER_COOLDOWN_SECONDS"

    notice "TEST $(printf '%02d' "$TEST_INDEX")/$TOTAL_TESTS mode=$mode releasing P4 start gate; DOWNLOAD 1/$DOWNLOADS may begin"
    ssh -n "root@$CLIENT_HOST" "touch $(quote "$client_start_gate")"
'''

src = src[:start] + new_block + src[end:]

# Clean the remote gate after each workload once the client is done.
needle_cleanup = '''    read -r -a statuses < "$client_status_file"
    rm -f "$client_status_file"
    client_rc="${statuses[0]:-1}"

    stop_server
'''
replacement_cleanup = '''    read -r -a statuses < "$client_status_file"
    rm -f "$client_status_file"
    client_rc="${statuses[0]:-1}"
    ssh -n "root@$CLIENT_HOST" "rm -f $(quote "$client_start_gate")" || true

    stop_server
'''
replace_once(needle_cleanup, replacement_cleanup, "client gate cleanup")

Path(sys.argv[2]).write_text(src, encoding="utf-8")
PY

chmod 0700 "$TMP"
exec bash "$TMP" "$@"
