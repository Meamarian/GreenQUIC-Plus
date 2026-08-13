#!/usr/bin/env python3
"""Official P4/P5 sheet-rules entry point with endpoint clock alignment."""
from __future__ import annotations

from dataclasses import replace
import os
from pathlib import Path
import subprocess
import sys

import build_sheet_rules_all as base

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
        get_times = base.read_get_times(server_files.get("timeline"))
        if not get_times:
            base.warn(
                "server_cstate_endpoint_alignment_missing",
                "Server C-state has a RAW↔MONOTONIC bridge, but no timestamped server GET events were recorded. Whole-trace C-state remains valid; server active/gap C-state is reported with a warning.",
                f"server rep{repetition:02d} {mode}",
            )
            continue
        shift_ns = int(record.get("server_shift_ns", 0))
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
    for i,arg in enumerate(sys.argv[1:]):
        if arg == name and i + 2 <= len(sys.argv[1:]):
            return sys.argv[1:][i+1]
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
            base.warn(warning_code, f"{script_name} returned {result.returncode}", "P4")
    return 0


if __name__ == "__main__":
    rc = base.main()
    if rc == 0:
        _generate_newcharts()
    raise SystemExit(rc)
