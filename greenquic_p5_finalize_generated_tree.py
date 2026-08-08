#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import os
import subprocess
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: greenquic_p5_finalize_generated_tree.py REPO P5")

repo = Path(sys.argv[1])
p5 = Path(sys.argv[2])
core_path = p5 / "run_matrix_from_idex_core.sh"
gq_path = p5 / "gq_common_p5.sh"
shared_timestamp = repo / "greenquic_test_suite_v22/common/bin/timestamp_tee.py"
local_timestamp = p5 / "timestamp_tee_p5.py"

SIGNAL_MARKER = "GREENQUIC-P5-SERVER-SIGNAL-SCOPE-V2"
PIPELINE_MARKER = "GREENQUIC-P5-SERVER-PIPELINE-RC-V1"
TIMESTAMP_MARKER = "GREENQUIC-P5-TIMESTAMP-SIGINT-SAFE-V1"

for path in (core_path, gq_path, shared_timestamp):
    if not path.is_file():
        raise SystemExit(f"ERROR: missing required P5 file: {path}")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            f"ERROR: {label}: expected exactly one match, found {count}; "
            "no P5 files were written"
        )
    return text.replace(old, new, 1)


core = core_path.read_text(encoding="utf-8")
gq = gq_path.read_text(encoding="utf-8")
ts = (
    local_timestamp.read_text(encoding="utf-8")
    if local_timestamp.is_file()
    else shared_timestamp.read_text(encoding="utf-8")
)

# 1) Graceful server shutdown must target quicinteropserver only.
# pgrep's default comm/name matching is limited to 15 characters on Linux,
# while "quicinteropserver" is longer. The old -x lookup can therefore fail
# and fall back to SIGINTing the whole process group, killing timestamp_tee.
if SIGNAL_MARKER not in core:
    core = replace_once(
        core,
        '''        app_pids="$(pgrep -g "$SERVER_PGID" -x quicinteropserver 2>/dev/null || true)"
        if [[ -n "$app_pids" ]]; then
            kill -INT $app_pids 2>/dev/null || true
        else
            kill -INT -- "-$SERVER_PGID" 2>/dev/null || true
        fi
''',
        '''        # GREENQUIC-P5-SERVER-SIGNAL-SCOPE-V2
        # Match the full command line because Linux process-name matching is
        # limited to 15 chars and "quicinteropserver" is longer. Signal only
        # the MsQuic server; the timestamp/reporting pipeline must survive.
        app_pids="$(pgrep -g "$SERVER_PGID" -f '(^|/)quicinteropserver([[:space:]]|$)' 2>/dev/null || true)"
        if [[ -n "$app_pids" ]]; then
            kill -INT $app_pids 2>/dev/null || true
        else
            warn "quicinteropserver PID not found in PGID=$SERVER_PGID; not SIGINTing logger/reporting helpers"
        fi
''',
        "scoped server SIGINT",
    )

# 2) Do not silently continue a matrix if server parsing/reporting fails.
if PIPELINE_MARKER not in core:
    core = replace_once(
        core,
        'SERVER_PIPELINE_PID=""\nSERVER_PIDFILE=""\n',
        'SERVER_PIPELINE_PID=""\nSERVER_PIDFILE=""\nSERVER_LAST_PIPELINE_RC=0\n',
        "server pipeline status global",
    )

    if '    local rc=0 app_pids="" cleanup_polls\n' in core:
        core = replace_once(
            core,
            '    local rc=0 app_pids="" cleanup_polls\n',
            '    local rc=0 app_pids="" cleanup_polls\n'
            '    SERVER_LAST_PIPELINE_RC=0\n',
            "stop_server status initialization",
        )
    elif '    local rc=0 app_pids=""\n' in core:
        core = replace_once(
            core,
            '    local rc=0 app_pids=""\n',
            '    local rc=0 app_pids=""\n'
            '    SERVER_LAST_PIPELINE_RC=0\n',
            "stop_server status initialization",
        )
    else:
        raise SystemExit(
            "ERROR: stop_server local-variable anchor not found; no P5 files were written"
        )

    core = replace_once(
        core,
        '''        case "$rc" in
            0|130|141|143) ;;
            *) warn "server display pipeline exited with rc=$rc" ;;
        esac
''',
        '''        # GREENQUIC-P5-SERVER-PIPELINE-RC-V1
        case "$rc" in
            0|130|141|143)
                SERVER_LAST_PIPELINE_RC=0
                ;;
            *)
                SERVER_LAST_PIPELINE_RC="$rc"
                warn "server display pipeline exited with rc=$rc"
                ;;
        esac
''',
        "server pipeline status capture",
    )

    core = replace_once(
        core,
        '''    stop_server

    server_summary="''',
        '''    stop_server
    if [[ "${SERVER_LAST_PIPELINE_RC:-0}" != 0 ]]; then
        echo "ERROR: server pipeline failed: test=$TEST_INDEX mode=$mode repetition=$rep rc=$SERVER_LAST_PIPELINE_RC" >&2
        exit "$SERVER_LAST_PIPELINE_RC"
    fi

    server_summary="''',
        "server pipeline fatal check",
    )

# 3) P5-local timestamp logger survives SIGINT and drains until EOF.
if TIMESTAMP_MARKER not in ts:
    ts = replace_once(
        ts,
        "import argparse\nimport json\nimport sys\nimport time\n",
        "import argparse\nimport json\nimport signal\nimport sys\nimport time\n",
        "timestamp signal import",
    )
    ts = replace_once(
        ts,
        '''    args = parser.parse_args()

    # Native MsQuic/DPDK output may contain non-UTF-8 bytes.
''',
        '''    args = parser.parse_args()

    # GREENQUIC-P5-TIMESTAMP-SIGINT-SAFE-V1
    # The controller gracefully SIGINTs quicinteropserver. This logger must
    # survive and drain the server pipe through EOF so the final GreenQUIC
    # COUNTERS line and cleanup output reach the raw log and timeline.
    signal.signal(signal.SIGINT, signal.SIG_IGN)

    # Native MsQuic/DPDK output may contain non-UTF-8 bytes.
''',
        "timestamp SIGINT policy",
    )

shared_invocation = 'python3 "$GQ_COMMON_DIR/bin/timestamp_tee.py"'
local_invocation = 'python3 "$GQ_P5_DIR/timestamp_tee_p5.py"'
if local_invocation not in gq:
    count = gq.count(shared_invocation)
    if count < 1:
        raise SystemExit(
            "ERROR: timestamp_tee invocation not found in gq_common_p5.sh; "
            "no P5 files were written"
        )
    gq = gq.replace(shared_invocation, local_invocation)

# Validate all modified content before any write.
subprocess.run(["bash", "-n"], input=core, text=True, check=True)
subprocess.run(["bash", "-n"], input=gq, text=True, check=True)
compile(ts, str(local_timestamp), "exec")

# Atomic writes preserve existing P5 results and built binaries.
for path, content in ((core_path, core), (gq_path, gq), (local_timestamp, ts)):
    tmp = path.with_name(path.name + ".p5-finalize.tmp")
    tmp.write_text(content, encoding="utf-8")
    os.chmod(tmp, 0o755)
    os.replace(tmp, path)

print("P5 generated-tree finalization fix applied:")
print(f"  {core_path}")
print(f"  {gq_path}")
print(f"  {local_timestamp}")
