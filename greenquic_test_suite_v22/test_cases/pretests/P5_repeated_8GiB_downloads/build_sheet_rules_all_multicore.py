#!/usr/bin/env python3
"""Multicore-safe P5 report entry point.

The stock P5 C-state reader sums residency over all traced CPUs. That is correct
as CPU-seconds, but its legacy percentage denominator is one wall-clock window.
For a multicore run that can produce >100% idle fraction and misleading
single-core-looking residency charts.

This wrapper keeps the existing endpoint clock-alignment logic, then normalizes
C-state residency to average seconds per traced dataplane CPU and recomputes the
fractions. Raw C-state CSV/JSON files remain unchanged and preserve per-CPU
measurement evidence.
"""
from __future__ import annotations

import json
from pathlib import Path
import sys

import build_sheet_rules_all as base
import build_sheet_rules_all_aligned as aligned  # installs phase alignment

_original_read_cstate = base.read_cstate


def _cpu_count(path: Path | None) -> int:
    if path is None or not path.is_file():
        return 1
    cpus: set[int] = set()
    for row in base.read_csv(path):
        value = row.get("cpu")
        if value is None:
            continue
        try:
            cpus.add(int(value))
        except (TypeError, ValueError):
            continue
    return max(1, len(cpus))


def _divide_state_map(value, divisor: int):
    if not isinstance(value, dict) or divisor <= 1:
        return value
    out = {}
    for key, item in value.items():
        try:
            out[key] = float(item) / divisor
        except (TypeError, ValueError):
            out[key] = item
    return out


def multicore_read_cstate(path, bridge, windows):
    result = _original_read_cstate(path, bridge, windows)
    if not isinstance(result, dict):
        return result

    ncpu = _cpu_count(path)
    result["measured_cpu_count"] = ncpu
    result["residency_semantics"] = "average_seconds_per_measured_dataplane_cpu"

    if ncpu <= 1:
        return result

    for scope in ("whole", "active", "gap", "aligned"):
        map_key = f"{scope}_by_state_s"
        idle_key = f"{scope}_idle_s"
        if map_key in result:
            result[f"{scope}_by_state_cpu_seconds"] = dict(result[map_key])
            result[map_key] = _divide_state_map(result[map_key], ncpu)
        if idle_key in result:
            try:
                original = float(result[idle_key])
            except (TypeError, ValueError):
                pass
            else:
                result[f"{scope}_idle_cpu_seconds"] = original
                result[idle_key] = original / ncpu

    # Legacy fractions are summed CPU-seconds / one wall-clock window. Convert
    # them to mean per-core percentages.
    for key in (
        "active_idle_fraction_pct",
        "gap_idle_fraction_pct",
        "aligned_idle_fraction_pct",
    ):
        if key in result and result[key] is not None:
            try:
                result[key] = float(result[key]) / ncpu
            except (TypeError, ValueError):
                pass

    return result


# build_sheet_rules_all_aligned resolves base.read_cstate dynamically, so this
# replacement applies to both endpoints without changing its alignment logic.
base.read_cstate = multicore_read_cstate


def _arg_value(name: str) -> str | None:
    args = sys.argv[1:]
    for i, arg in enumerate(args):
        if arg == name and i + 1 < len(args):
            return args[i + 1]
        prefix = name + "="
        if arg.startswith(prefix):
            return arg[len(prefix):]
    return None


def _write_semantics() -> None:
    output = _arg_value("--output")
    if not output:
        return
    root = Path(output)
    root.mkdir(parents=True, exist_ok=True)
    data = {
        "schema": "greenquic-p5-multicore-report-semantics-v1",
        "cstate_residency": "average seconds per measured dataplane CPU",
        "cstate_idle_fraction": "mean per-core idle fraction; expected range 0..100%",
        "raw_cstate_files": "unchanged; preserve per-CPU events and aggregate CPU-seconds",
        "frequency": "existing sampler/report consumes all configured GreenQuicDpdkLcores",
        "policy_counters": "lcore-local policy actions summed; process-global hint counters deduplicated by existing parser",
    }
    (root / "MULTICORE_METRIC_SEMANTICS.json").write_text(
        json.dumps(data, indent=2) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    rc = base.main()
    if rc == 0:
        _write_semantics()
    raise SystemExit(rc)
