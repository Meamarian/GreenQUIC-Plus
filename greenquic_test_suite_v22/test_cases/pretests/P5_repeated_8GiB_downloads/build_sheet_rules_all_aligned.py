#!/usr/bin/env python3
"""Official P5 sheet-rules entry point with endpoint clock alignment."""
from __future__ import annotations

from dataclasses import replace
import os
from pathlib import Path
import subprocess
import sys

import build_sheet_rules_all as base

COMMON_BIN = Path(__file__).resolve().parents[3] / "common" / "bin"
if str(COMMON_BIN) not in sys.path:
    sys.path.insert(0, str(COMMON_BIN))
import phase_alignment

# Make base.raw_data use only real HTTP GET lines. This avoids matching text
# such as "Cannot get available frequencies".
base.read_get_times = phase_alignment.read_http_get_times
_original_raw_data = base.raw_data


def _aligned_raw_data(root):
    records = _original_raw_data(root)
    files = base.discover_files(root)
    for (repetition, mode), record in records.items():
        windows = record.get("windows") or []
        if not windows:
            continue
        server_files = files.get(("server", repetition, mode), {})
        cstate_path = server_files.get("cstate")
        if cstate_path is None:
            continue
        frequency = base.read_frequency(server_files.get("frequency"))
        bridge = frequency.get("bridge") if frequency else None
        if bridge is None:
            continue
        get_times = phase_alignment.read_http_get_times(server_files.get("timeline"))
        alignment = phase_alignment.build_alignment_info(windows, get_times)
        record["server_alignment"] = alignment
        if not alignment["valid"]:
            base.warn(
                "server_phase_alignment_rejected",
                "Server phase attribution rejected by repeated-GET alignment guard; whole-trace data remains valid.",
                f"server rep{repetition:02d} {mode}: {alignment['reason']}",
            )
            phase_alignment.invalidate_server_phase_data(record)
            continue
        shift_ns = int(alignment["shift_ns"])
        record["server_shift_ns"] = shift_ns
        shifted_bridge = replace(
            bridge,
            start_mono_ns=int(bridge.start_mono_ns) + shift_ns,
            end_mono_ns=(int(bridge.end_mono_ns) + shift_ns if bridge.end_mono_ns is not None else None),
            method=f"{bridge.method}+server_get_to_client",
        )
        record["server_cstate"] = base.read_cstate(cstate_path, shifted_bridge, windows)
    return records


base.raw_data = _aligned_raw_data


def _arg_value(name: str) -> str | None:
    args = sys.argv[1:]
    for i,arg in enumerate(args):
        if arg == name and i + 1 < len(args):
            return args[i+1]
        prefix = name + "="
        if arg.startswith(prefix):
            return arg[len(prefix):]
    return None


def _generate_newcharts() -> int:
    here = Path(__file__).resolve().parent
    common_dir = here.parents[2] / "common" / "bin"
    input_arg = _arg_value("--input")
    output_arg = _arg_value("--output")
    if not input_arg:
        base.warn("newchart_generator_missing_input", "Cannot run chart generators without --input", str(here))
        return 0
    env = os.environ.copy()
    env["PYTHONPATH"] = str(here) + (os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else "")
    for script_name, warning_code in (
        ("build_newchart_variants.py", "newchart_generation_failed"),
        ("build_normalized_derived_charts.py", "normalized_derived_generation_failed"),
    ):
        script = common_dir / script_name
        if not script.is_file():
            base.warn("newchart_generator_missing", "Cannot run chart generator", str(script))
            continue
        cmd = [sys.executable, str(script), "--input", input_arg, "--reporter-dir", str(here)]
        if output_arg:
            cmd += ["--output", output_arg]
        result = subprocess.run(cmd, env=env, check=False)
        if result.returncode != 0:
            base.warn(warning_code, f"{script_name} returned {result.returncode}", "P5")
    return 0


if __name__ == "__main__":
    rc = base.main()
    if rc == 0:
        _generate_newcharts()
    raise SystemExit(rc)
