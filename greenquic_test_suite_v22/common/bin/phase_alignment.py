#!/usr/bin/env python3
"""Strict cross-host phase-alignment helpers for GreenQUIC repeated downloads."""
from __future__ import annotations

import json
import math
import os
import re
import statistics
from pathlib import Path
from typing import Any

# Match the application/server HTTP request log, not arbitrary English text such
# as "Cannot get available frequencies".
_HTTP_GET_RE = re.compile(r"(?:^|\]\s)GET\s+['\"]?/", re.IGNORECASE)
DEFAULT_MAX_SPREAD_NS = 5_000_000  # 5 ms empirical pair-to-pair spread guard.


def _finite(value: Any) -> float | None:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def read_http_get_times(path: Path | None) -> list[int]:
    """Return only timestamped application HTTP GET events from a timeline.

    The timestamp is the wrapper's CLOCK_MONOTONIC capture time for the complete
    server log line. It is therefore suitable for estimating a *constant*
    server->client monotonic-domain shift across repeated GETs, while the
    residual spread is retained as an empirical alignment-quality measure.
    """
    if path is None or not path.is_file():
        return []
    output: list[int] = []
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            row = json.loads(raw)
        except Exception:
            continue
        if row.get("type") != "line":
            continue
        message = str(row.get("line", ""))
        if not _HTTP_GET_RE.search(message):
            continue
        direct = _finite(row.get("monotonic_ns"))
        if direct is not None:
            output.append(int(direct))
            continue
        # Compatibility fallback for older timestamped timeline schemas.
        for key, value in row.items():
            key_norm = re.sub(r"[^a-z0-9]+", "_", str(key).lower()).strip("_")
            number = _finite(value)
            if number is not None and ("mono" in key_norm or key_norm in {"timestamp_ns", "time_ns"}):
                output.append(int(number))
                break
    return output


def build_alignment_info(
    windows: list[tuple[int, int]],
    server_get_times: list[int],
    max_spread_ns: int | None = None,
) -> dict[str, Any]:
    """Build an auditable server-native -> client-monotonic shift estimate."""
    if max_spread_ns is None:
        try:
            max_spread_ns = int(os.environ.get("GQ_PHASE_ALIGNMENT_MAX_SPREAD_NS", DEFAULT_MAX_SPREAD_NS))
        except ValueError:
            max_spread_ns = DEFAULT_MAX_SPREAD_NS
    max_spread_ns = max(0, int(max_spread_ns))

    request_count = len(windows)
    pair_count = min(request_count, len(server_get_times))
    pairs = []
    offsets: list[int] = []
    for index in range(pair_count):
        client_start = int(windows[index][0])
        server_get = int(server_get_times[index])
        offset = client_start - server_get
        offsets.append(offset)
        pairs.append(
            {
                "download": index + 1,
                "client_start_ns": client_start,
                "server_get_native_ns": server_get,
                "offset_ns": offset,
            }
        )

    shift_ns = int(statistics.median(offsets)) if offsets else 0
    residuals = [offset - shift_ns for offset in offsets]
    spread_ns = max(offsets) - min(offsets) if len(offsets) >= 2 else 0
    max_abs_residual_ns = max((abs(v) for v in residuals), default=0)
    median_abs_residual_ns = int(statistics.median([abs(v) for v in residuals])) if residuals else 0

    for row, residual in zip(pairs, residuals):
        row["server_get_shifted_ns"] = int(row["server_get_native_ns"]) + shift_ns
        row["residual_ns"] = residual

    valid = bool(request_count and pair_count == request_count and spread_ns <= max_spread_ns)
    reason = "ok" if valid else (
        "no request windows" if not request_count else
        f"GET/request count mismatch: requests={request_count} GETs={len(server_get_times)}" if pair_count != request_count else
        f"alignment spread {spread_ns} ns exceeds limit {max_spread_ns} ns"
    )
    return {
        "schema": "greenquic-server-get-alignment-v2",
        "method": "median(client request start MONOTONIC - server HTTP GET timeline-capture MONOTONIC)",
        "request_count": request_count,
        "server_http_get_count": len(server_get_times),
        "pair_count": pair_count,
        "shift_ns": shift_ns,
        "offsets_ns": offsets,
        "residuals_ns": residuals,
        "spread_ns": spread_ns,
        "max_abs_residual_ns": max_abs_residual_ns,
        "median_abs_residual_ns": median_abs_residual_ns,
        "max_allowed_spread_ns": max_spread_ns,
        "valid": valid,
        "reason": reason,
        "pairs": pairs,
        "timestamp_semantics": "server GET timestamp is wrapper capture time of complete log line, not NIC packet-arrival time",
    }


def invalidate_server_phase_data(record: dict[str, Any]) -> None:
    """Remove only phase-attributed server fields; preserve whole-trace data."""
    for phase in ("active", "gap", "startup", "pre", "post", "tail"):
        record[f"server_{phase}"] = {}
    record["server_spans"] = []
    cstate = record.get("server_cstate")
    if isinstance(cstate, dict):
        for key in (
            "active_by_state_s", "gap_by_state_s", "aligned_by_state_s",
            "active_idle_s", "gap_idle_s", "aligned_idle_s",
            "active_intervals", "gap_intervals", "aligned_intervals",
            "active_duration_s", "gap_duration_s", "aligned_duration_s",
            "active_idle_fraction_pct", "gap_idle_fraction_pct", "aligned_idle_fraction_pct",
        ):
            cstate.pop(key, None)
