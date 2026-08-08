#!/usr/bin/env python3
# GREENQUIC-P5-FINALIZER-V2
from __future__ import annotations

from pathlib import Path
import os
import subprocess
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: greenquic_p5_finalize_generated_tree_v2.py REPO P5")

repo = Path(sys.argv[1])
p5 = Path(sys.argv[2])
gq_path = p5 / "gq_common_p5.sh"
summary_path = p5 / "write_run_summary.py"
matrix_finalizer_path = p5 / "p5_finalize_matrix.py"

for path in (gq_path, summary_path, matrix_finalizer_path):
    if not path.is_file():
        raise SystemExit(f"ERROR: missing generated P5 file: {path}")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"ERROR: {label}: expected exactly 1 match, found {count}")
    return text.replace(old, new, 1)


gq = gq_path.read_text(encoding="utf-8")
if "GREENQUIC-P5-GRACEFUL-SERVER-EXIT-V1" not in gq:
    gq = replace_once(
        gq,
        '            "-root:$root" "-file:$cert" "-key:$key" -noexit\n',
        '            "-root:$root" "-file:$cert" "-key:$key" -exitonsig\n',
        "generated P5 server exit flag",
    )
    gq = replace_once(
        gq,
        '        export GREENQUIC_POWER_CONFIG="$runtime/powermng.ini"\n'
        '        exec stdbuf -oL -eL "$INTEROP_SERVER_BIN" \\\n',
        '        export GREENQUIC_POWER_CONFIG="$runtime/powermng.ini"\n'
        '        # GREENQUIC-P5-GRACEFUL-SERVER-EXIT-V1\n'
        '        # Use normal interopserver teardown so MsQuicClose/DPDK cleanup runs.\n'
        '        exec stdbuf -oL -eL "$INTEROP_SERVER_BIN" \\\n',
        "generated P5 graceful-exit marker",
    )

summary = summary_path.read_text(encoding="utf-8")
if "GREENQUIC-P5-HINT-COUNTER-SEMANTICS-V1" not in summary:
    summary = replace_once(
        summary,
        '''        "- Semantics: API events emitted by QUIC/app hooks, not periodic samples.",
        f"- ACK_PENDING: {int(counters.get('hint_ack_pending', 0) or 0)}",
        f"- CUBIC_CWND_BLOCKED: {int(counters.get('hint_cubic_cwnd_blocked', 0) or 0)}",
        f"- CUBIC_RECOVERY begin/assert: {int(counters.get('hint_cubic_recovery', 0) or 0)}",
        f"- CUBIC_RECOVERY end: {int(counters.get('hint_cubic_recovery_end', 0) or 0)}",
        f"- CUBIC_RAMPING: {int(counters.get('hint_cubic_ramping', 0) or 0)}",
        f"- SERVER_FILE_TX_ACTIVE begin / end: {int(counters.get('hint_server_file_tx_active', 0) or 0)} / {int(counters.get('hint_server_file_tx_end', 0) or 0)}",
        f"- CLIENT_FILE_RX_ACTIVE begin / end: {int(counters.get('hint_client_file_rx_active', 0) or 0)} / {int(counters.get('hint_client_file_rx_end', 0) or 0)}",
''',
        '''        # GREENQUIC-P5-HINT-COUNTER-SEMANTICS-V1
        "- Semantics: direct QUIC/app hook events; pulse counts are hook invocations, not distinct episodes or periodic samples.",
        f"- ACK_PENDING pulse calls: {int(counters.get('hint_ack_pending', 0) or 0)}",
        f"- CUBIC_CWND_BLOCKED pulse calls (send-allowance evaluations while blocked): {int(counters.get('hint_cubic_cwnd_blocked', 0) or 0)}",
        f"- CUBIC_RECOVERY begin lifecycle events: {int(counters.get('hint_cubic_recovery', 0) or 0)}",
        f"- CUBIC_RECOVERY successful end lifecycle events: {int(counters.get('hint_cubic_recovery_end', 0) or 0)}",
        f"- CUBIC_RAMPING CWND-growth pulse calls: {int(counters.get('hint_cubic_ramping', 0) or 0)}",
        f"- SERVER_FILE_TX_ACTIVE lifecycle begin / end: {int(counters.get('hint_server_file_tx_active', 0) or 0)} / {int(counters.get('hint_server_file_tx_end', 0) or 0)}",
        f"- CLIENT_FILE_RX_ACTIVE lifecycle begin / end: {int(counters.get('hint_client_file_rx_active', 0) or 0)} / {int(counters.get('hint_client_file_rx_end', 0) or 0)}",
''',
        "generated P5 hint counter labels",
    )

# GREENQUIC-P5-COUNTER-HISTOGRAMS-POSTGEN-V1
matrix_finalizer = matrix_finalizer_path.read_text(encoding="utf-8")
if "GREENQUIC-P5-COUNTER-HISTOGRAMS-V1" not in matrix_finalizer:
    _anchor = '    server_bundles = sorted((matrix / "runs" / "server").glob("rep*/*"))\n'
    if matrix_finalizer.count(_anchor) != 1:
        raise SystemExit(
            f"ERROR: generated P5 counter-histogram anchor expected once, "
            f"found {matrix_finalizer.count(_anchor)}"
        )
    _hook = '    # GREENQUIC-P5-COUNTER-HISTOGRAMS-V1\n    # Additional charts only. Existing P5/P4 chart files are not modified.\n    import subprocess as _gq_subprocess\n    import sys as _gq_sys\n    _gq_counter_plotter = (\n        Path(__file__).resolve().parents[3]\n        / "common" / "bin" / "plot_greenquic_counter_histograms.py"\n    )\n    if not _gq_counter_plotter.is_file():\n        raise SystemExit(f"ERROR: missing P5 counter histogram plotter: {_gq_counter_plotter}")\n    _gq_subprocess.run(\n        [_gq_sys.executable, str(_gq_counter_plotter), "--matrix", str(matrix)],\n        check=True,\n    )\n\n'
    matrix_finalizer = matrix_finalizer.replace(_anchor, _hook + _anchor, 1)

subprocess.run(["bash", "-n"], input=gq, text=True, check=True)
compile(summary, str(summary_path), "exec")
compile(matrix_finalizer, str(matrix_finalizer_path), "exec")

for path, text in ((gq_path, gq), (summary_path, summary), (matrix_finalizer_path, matrix_finalizer)):
    tmp = path.with_name(path.name + ".gq-finalizer-v2.tmp")
    tmp.write_text(text, encoding="utf-8")
    os.chmod(tmp, path.stat().st_mode & 0o777)
    os.replace(tmp, path)

print("P5 finalizer v2 applied")
