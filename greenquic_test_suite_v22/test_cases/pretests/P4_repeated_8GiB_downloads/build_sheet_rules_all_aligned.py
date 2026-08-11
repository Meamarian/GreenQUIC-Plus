#!/usr/bin/env python3
"""Official P4/P5 sheet-rules entry point with endpoint clock alignment.

The base reporter keeps all extraction/plotting code.  This wrapper corrects the
server phase-C-state clock domain before report generation:

  cpu_idle trace:         server CLOCK_MONOTONIC_RAW
  clock bridge:           server RAW -> server MONOTONIC
  GET/request alignment:  server MONOTONIC -> client MONOTONIC

This is the same endpoint alignment already used for server RAPL phase traces.
Missing inputs are warnings only; report generation continues.
"""
from __future__ import annotations

from dataclasses import replace

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
            # The base reporter already preserves whole-trace C-state and emits
            # the detailed missing-bridge warning.  Do not fail the report.
            continue

        get_times = base.read_get_times(server_files.get("timeline"))
        if not get_times:
            base.warn(
                "server_cstate_endpoint_alignment_missing",
                "Server C-state has a RAW↔MONOTONIC bridge, but no timestamped "
                "server GET events were recorded. Whole-trace C-state remains "
                "valid; server active/gap C-state is reported with a warning.",
                f"server rep{repetition:02d} {mode}",
            )
            continue

        # server_shift_ns maps server-local MONOTONIC into the client
        # MONOTONIC domain used by request start/complete windows.
        shift_ns = int(record.get("server_shift_ns", 0))
        shifted_bridge = replace(
            bridge,
            start_mono_ns=int(bridge.start_mono_ns) + shift_ns,
            end_mono_ns=(
                int(bridge.end_mono_ns) + shift_ns
                if bridge.end_mono_ns is not None
                else None
            ),
            method=f"{bridge.method}+server_get_to_client",
        )
        record["server_cstate"] = base.read_cstate(
            cstate_path,
            shifted_bridge,
            windows,
        )

    return records


base.raw_data = _aligned_raw_data

if __name__ == "__main__":
    raise SystemExit(base.main())
