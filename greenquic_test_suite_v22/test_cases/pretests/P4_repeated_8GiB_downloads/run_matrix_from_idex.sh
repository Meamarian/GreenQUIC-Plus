#!/usr/bin/env bash
set -Eeuo pipefail

# Public P4 controller wrapper.
#
# The preserved controller core contains the full P4 scheduling, aligned-RAPL,
# result bundling and aggregation logic. This wrapper applies two installation/
# hardware fixes before executing it:
#   1. fresh clones live under /root/mohsen, not /root/greenquic_snapshot;
#   2. on the E810 pair the server can remain in DPDK "Checking link status"
#      until Tinyman starts its DPDK port. Therefore server-process liveness,
#      not pre-client "Port 0 Link up", is the startup gate. The P4 client is
#      given the requested edge cooldown as an initial no-GET delay so that the
#      peer DPDK port can come up before the first 8-GiB request.

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
CORE="$HERE/run_matrix_from_idex_core.sh"

[[ -f "$CORE" ]] || {
    echo "ERROR: missing preserved P4 controller core: $CORE" >&2
    exit 2
}

TMP="$(mktemp "$HERE/.run_matrix_fixed.XXXXXX.sh")"
cleanup() { rm -f -- "$TMP"; }
trap cleanup EXIT

python3 - "$CORE" "$TMP" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text(encoding="utf-8")

# Fresh-install paths.
src = src.replace(
    "/root/greenquic_snapshot/greenquic_test_suite_v22/test_cases/pretests/P4_repeated_8GiB_downloads",
    "/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P4_repeated_8GiB_downloads",
)
src = src.replace(
    "/root/greenquic_snapshot/msquic/build-greenquic-p4/bin/Release/quicinterop",
    "/root/mohsen/msquic/build-greenquic-p4/bin/Release/quicinterop",
)

# The E810 link on these two userspace-bound endpoints is established only once
# both DPDK applications have started. Waiting for server-side Link up before
# launching Tinyman creates a circular wait. Treat a live server process as the
# pre-client readiness condition instead; the real link and transfer are then
# validated by the running client/server workload.
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

new_ready = r'''    # E810 two-ended DPDK startup: the peer DPDK port on Tinyman is not
    # active yet, so IDEX may legitimately remain inside "Checking link status".
    # Do not wait for pre-client "Port 0 Link up" here. Verify that the server
    # process remains alive; Tinyman will start below and complete link training.
    sleep 1
    kill -0 "$SERVER_PGID" 2>/dev/null || {
        echo "ERROR: server exited during DPDK initialization" >&2
        [[ -f "$server_log" ]] && tail -n 100 "$server_log" >&2 || true
        stop_server
        exit 1
    }
    notice "TEST $(printf '%02d' "$TEST_INDEX")/$TOTAL_TESTS mode=$mode server process alive; peer DPDK startup required for link-up"
'''

if old_ready not in src:
    raise SystemExit("ERROR: expected P4 server-readiness block was not found in controller core")
src = src.replace(old_ready, new_ready, 1)

# Start Tinyman immediately rather than sleeping while its DPDK port is still
# down. The isolated P4 client itself owns the requested pre-download delay.
old_precool = r'''    notice "TEST $(printf '%02d' "$TEST_INDEX")/$TOTAL_TESTS mode=$mode PRE-COOLDOWN ${SERVER_COOLDOWN_SECONDS}s (server running; no download yet)"
    sleep "$SERVER_COOLDOWN_SECONDS"
    notice "TEST $(printf '%02d' "$TEST_INDEX")/$TOTAL_TESTS mode=$mode starting tinyman client"
'''
new_precool = r'''    notice "TEST $(printf '%02d' "$TEST_INDEX")/$TOTAL_TESTS mode=$mode starting tinyman client so both DPDK ports can establish link"
    notice "TEST $(printf '%02d' "$TEST_INDEX")/$TOTAL_TESTS mode=$mode PRE-COOLDOWN ${SERVER_COOLDOWN_SECONDS}s will occur inside the P4 client before its first GET"
'''
if old_precool not in src:
    raise SystemExit("ERROR: expected P4 pre-cooldown block was not found in controller core")
src = src.replace(old_precool, new_precool, 1)

# Convert the configured cooldown to microseconds once and pass it only to the
# client. The patched isolated P4 client waits this long before its first GET.
needle = '    CLIENT_RUN_ENV=(\n        "${COMMON_RUN_ENV[@]}"\n        "GQ_INTEROP_CLIENT_BIN=$CLIENT_BIN_EFFECTIVE"\n    )\n'
replacement = '''    P4_INITIAL_DELAY_US="$(python3 - "$SERVER_COOLDOWN_SECONDS" <<'PY_DELAY'\nfrom decimal import Decimal\nimport sys\nprint(int(Decimal(sys.argv[1]) * Decimal(1000000)))\nPY_DELAY\n)"\n\n    CLIENT_RUN_ENV=(\n        "${COMMON_RUN_ENV[@]}"\n        "GQ_INTEROP_CLIENT_BIN=$CLIENT_BIN_EFFECTIVE"\n        "GQ_INTEROP_P4_INITIAL_DELAY_US=$P4_INITIAL_DELAY_US"\n    )\n'''
if needle not in src:
    raise SystemExit("ERROR: expected P4 client environment block was not found in controller core")
src = src.replace(needle, replacement, 1)

Path(sys.argv[2]).write_text(src, encoding="utf-8")
PY

chmod 0700 "$TMP"
exec bash "$TMP" "$@"
