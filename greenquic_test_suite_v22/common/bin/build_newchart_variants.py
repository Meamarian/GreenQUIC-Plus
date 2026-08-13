#!/usr/bin/env python3
"""Generate phase-safe GreenQUIC charts with timing/source audits.

This generator intentionally does *not* fabricate a 62-chart phase set.  The
original 62-chart report remains under ``the_sheet_rules_all/charts``.  Here we
only render metrics whose active/gap/combined attribution is supported by the
recorded clocks and sources.  Omitted chart numbers are documented in CSV/JSON
instead of being represented by misleading ``*_unavailable`` placeholder
images.
"""
from __future__ import annotations

import argparse
import csv
import functools
import json
import math
import re
import shutil
import statistics
import sys
from pathlib import Path
from typing import Any, Callable

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

SCOPES = ("active", "gap", "combined")
VERSIONS = ("without_variance", "with_variance")
EXPECTED_ORIGINAL_CHARTS = 62
T975 = {
    1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447,
    7: 2.365, 8: 2.306, 9: 2.262, 10: 2.228, 11: 2.201, 12: 2.179,
    13: 2.160, 14: 2.145, 15: 2.131, 16: 2.120, 17: 2.110,
    18: 2.101, 19: 2.093, 20: 2.086, 21: 2.080, 22: 2.074,
    23: 2.069, 24: 2.064, 25: 2.060, 26: 2.056, 27: 2.052,
    28: 2.048, 29: 2.045, 30: 2.042,
}

# Phase chart catalog. Numbers keep a relationship with the original 62-chart
# report, but titles explicitly describe the phase-safe meaning.
CHART_NAMES = {
    4: "active_goodput",
    5: "gap_inclusive_goodput",
    6: "phase_duration",
    7: "average_rapl_power",
    8: "rapl_energy",
    9: "rapl_energy_per_gib",
    14: "server_cstate_residency",
    15: "client_cstate_residency",
    16: "cpu_idle_time",
    17: "cpu_idle_fraction",
    18: "idle_intervals",
    19: "server_cstate_residency",
    20: "client_cstate_residency",
    21: "cpu_idle_time",
    22: "cpu_idle_fraction",
    23: "idle_intervals",
    29: "server_observed_frequency",
    30: "client_observed_frequency",
    32: "server_observed_frequency_transitions",
    34: "client_observed_frequency_transitions",
    36: "timestamped_frequency_samples",
    44: "active_rapl_power",
    45: "gap_rapl_power",
    46: "active_rapl_energy",
    47: "gap_rapl_energy",
}


def finite(value: Any) -> float | None:
    try:
        x = float(value)
    except (TypeError, ValueError):
        return None
    return x if math.isfinite(x) else None


def stats(values: list[float | None]) -> dict[str, Any]:
    vals = [float(v) for v in values if v is not None and math.isfinite(float(v))]
    n = len(vals)
    if not vals:
        return {"n": 0, "mean": None, "variance": None, "sd": None, "sem": None,
                "ci95_low": None, "ci95_high": None}
    mean = statistics.mean(vals)
    if n < 2:
        return {"n": n, "mean": mean, "variance": None, "sd": None, "sem": None,
                "ci95_low": None, "ci95_high": None}
    variance = statistics.variance(vals)
    sd = math.sqrt(variance)
    sem = sd / math.sqrt(n)
    half = T975.get(n - 1, 1.96) * sem
    return {"n": n, "mean": mean, "variance": variance, "sd": sd, "sem": sem,
            "ci95_low": mean - half, "ci95_high": mean + half}


def request_windows(record: dict[str, Any]) -> list[tuple[int, int]]:
    return [(int(a), int(b)) for a, b in (record.get("windows") or []) if int(b) >= int(a)]


def windows_for(windows: list[tuple[int, int]], scope: str) -> list[tuple[int, int]]:
    if not windows:
        return []
    if scope == "active":
        return list(windows)
    if scope == "gap":
        return [
            (windows[i][1], windows[i + 1][0])
            for i in range(len(windows) - 1)
            if windows[i + 1][0] > windows[i][1]
        ]
    return [(windows[0][0], windows[-1][1])]


def scope_duration(record: dict[str, Any], scope: str) -> float | None:
    ws = windows_for(request_windows(record), scope)
    if not ws:
        return None
    return sum(max(0, b - a) for a, b in ws) / 1e9


def inside_half_open(ts: int, windows: list[tuple[int, int]]) -> bool:
    # Half-open intervals avoid double-attributing a sample at an active/gap
    # boundary to both phases.
    return any(a <= ts < b for a, b in windows)


def server_alignment_valid(record: dict[str, Any]) -> bool:
    info = record.get("server_alignment")
    return not isinstance(info, dict) or bool(info.get("valid", False))


def phase_rapl(record: dict[str, Any], endpoint: str, scope: str, key: str) -> float | None:
    if endpoint == "server" and not server_alignment_valid(record):
        return None
    if scope in ("active", "gap"):
        return finite((record.get(f"{endpoint}_{scope}") or {}).get(key))
    active = record.get(f"{endpoint}_active") or {}
    gap = record.get(f"{endpoint}_gap") or {}
    if key in ("energy_j", "duration_s"):
        a, g = finite(active.get(key)), finite(gap.get(key))
        return a + g if a is not None and g is not None else None
    if key == "power_w":
        ae, ad = finite(active.get("energy_j")), finite(active.get("duration_s"))
        ge, gd = finite(gap.get("energy_j")), finite(gap.get("duration_s"))
        if None in (ae, ad, ge, gd) or ad + gd <= 0:
            return None
        return (ae + ge) / (ad + gd)
    return None


def cstate_value(
    record: dict[str, Any], endpoint: str, scope: str, metric: str,
    state: int | None = None,
) -> float | None:
    if endpoint == "server" and not server_alignment_valid(record):
        return None
    c = record.get(f"{endpoint}_cstate") or {}
    if not c:
        return None
    if state is not None:
        key = {
            "active": "active_by_state_s",
            "gap": "gap_by_state_s",
            "combined": "aligned_by_state_s",
        }[scope]
        by_state = c.get(key)
        if not isinstance(by_state, dict):
            return None
        # A valid mapped C-state trace with no interval in this state means zero
        # residency, not missing data.
        value = by_state.get(state, by_state.get(str(state), 0.0))
        return finite(value)
    keys = {
        ("active", "idle_s"): "active_idle_s",
        ("gap", "idle_s"): "gap_idle_s",
        ("combined", "idle_s"): "aligned_idle_s",
        ("active", "idle_fraction_pct"): "active_idle_fraction_pct",
        ("gap", "idle_fraction_pct"): "gap_idle_fraction_pct",
        ("combined", "idle_fraction_pct"): "aligned_idle_fraction_pct",
        ("active", "intervals"): "active_intervals",
        ("gap", "intervals"): "gap_intervals",
        # Older base reporters do not store aligned_intervals. Do not synthesize
        # it as active+gap because an idle interval crossing a boundary would be
        # counted twice.
        ("combined", "intervals"): "aligned_intervals",
    }
    return finite(c.get(keys[(scope, metric)])) if (scope, metric) in keys else None


@functools.lru_cache(maxsize=None)
def freq_rows(path: Path | None, shift_ns: int = 0) -> list[tuple[int, int, int]]:
    rows: list[tuple[int, int, int]] = []
    if path is None or not path.is_file():
        return rows
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            row = json.loads(raw)
        except Exception:
            continue
        if row.get("type") != "line":
            continue
        ts = finite(row.get("monotonic_ns"))
        cpu = finite(row.get("cpu"))
        khz = finite(row.get("freq_khz"))
        if ts is not None and cpu is not None and khz is not None:
            rows.append((int(ts) + shift_ns, int(cpu), int(khz)))
            continue
        match = re.search(r"\[CPU\s+(\d+)\].*?freq_khz=(\d+)", str(row.get("line", "")))
        if ts is not None and match:
            rows.append((int(ts) + shift_ns, int(match.group(1)), int(match.group(2))))
    rows.sort()
    return rows


def _rows_in_window(rows: list[tuple[int, int, int]], window: tuple[int, int]) -> list[tuple[int, int, int]]:
    a, b = window
    return [row for row in rows if a <= row[0] < b]


def freq_metric(
    record: dict[str, Any], bundle: dict[str, Path], endpoint: str,
    scope: str, metric: str,
) -> float | None:
    """Phase-safe frequency metric used by both this and normalized charts.

    ``changes`` is the number of transitions observed by the frequency sampler,
    counted independently inside each disjoint phase window. It never bridges
    D1->Gap->D2 boundaries. It is deliberately *not* called a controller policy
    decision count.
    """
    if endpoint == "server" and not server_alignment_valid(record):
        return None
    ws = windows_for(request_windows(record), scope)
    if not ws:
        return None
    shift = int(record.get("server_shift_ns", 0)) if endpoint == "server" else 0
    all_rows = freq_rows(bundle.get("frequency"), shift)
    selected = [row for row in all_rows if inside_half_open(row[0], ws)]
    if not selected:
        return None
    khz = [row[2] for row in selected]
    if metric == "min":
        return min(khz) / 1e6
    if metric == "mean":
        return statistics.mean(khz) / 1e6
    if metric == "max":
        return max(khz) / 1e6
    if metric == "samples":
        return float(len(selected))
    if metric == "changes":
        total = 0
        # Count separately per source window and per CPU. This prevents a
        # transition that happened in an excluded gap from being charged to an
        # active transfer merely because the endpoint samples differ.
        for window in ws:
            by_cpu: dict[int, list[tuple[int, int]]] = {}
            for ts, cpu, value in _rows_in_window(all_rows, window):
                by_cpu.setdefault(cpu, []).append((ts, value))
            for samples in by_cpu.values():
                samples.sort()
                total += sum(a[1] != b[1] for a, b in zip(samples, samples[1:]))
        return float(total)
    return None


def per_mode(records, mode: str, getter: Callable[[int, dict[str, Any]], float | None]) -> list[float | None]:
    return [getter(rep, row) for (rep, m), row in sorted(records.items()) if m == mode]


def combine(a: list[float | None], b: list[float | None]) -> list[float | None]:
    return [x + y if x is not None and y is not None else None for x, y in zip(a, b)]


def index_rows(rows: list[dict[str, Any]]) -> dict[tuple[int, str], dict[str, Any]]:
    out: dict[tuple[int, str], dict[str, Any]] = {}
    for row in rows:
        rep = finite(row.get("repetition"))
        mode = str(row.get("mode", "")).lower()
        if rep is not None and mode:
            out[(int(rep), mode)] = row
    return out


def table_metric(base, indexed, rep: int, mode: str, *parts: str) -> float | None:
    return base.field(indexed.get((rep, mode)), *parts)


def payload_gib(base, clients, rep: int, mode: str) -> float | None:
    value = table_metric(base, clients, rep, mode, "total", "payload")
    if value is None:
        value = table_metric(base, clients, rep, mode, "payload", "gib")
    return value if value is not None and value > 0 else None


def useful_gbit(gib: float | None) -> float | None:
    return gib * 8.0 * (2 ** 30) / 1e9 if gib is not None and gib > 0 else None


def render_dir(root: Path, ext: str, show_values: bool) -> Path:
    return root / ext / ("with_values" if show_values else "without_values")


def save_bar(
    root: Path, number: int, name: str, title: str, ylabel: str,
    series: dict[str, dict[str, list[float | None]]], modes, mode_names,
    variance: bool, stat_rows: list[dict[str, Any]], scope: str,
    source: str, quality: str,
) -> bool:
    cache = {label: [stats(by_mode.get(mode, [])) for mode in modes] for label, by_mode in series.items()}
    if not any(s["mean"] is not None for group in cache.values() for s in group):
        return False
    for label, group in cache.items():
        for mode, result in zip(modes, group):
            stat_rows.append({
                "chart": number, "name": name, "scope": scope, "series": label,
                "mode": mode, "source": source, "quality": quality, **result,
            })

    for show_values in (True, False):
        fig, ax = plt.subplots(figsize=(15, 8))
        x = np.arange(len(modes), dtype=float)
        width = min(0.72 / max(1, len(series)), 0.24)
        ymax = 0.0
        for j, (label, _) in enumerate(series.items()):
            group = cache[label]
            means = [s["mean"] if s["mean"] is not None else np.nan for s in group]
            errors = [s["sd"] if variance and s["sd"] is not None else 0.0 for s in group]
            pos = x + (j - (len(series) - 1) / 2) * width
            bars = ax.bar(pos, means, width, label=label,
                          yerr=errors if variance else None, capsize=5 if variance else 0)
            for mean, error in zip(means, errors):
                if math.isfinite(mean):
                    ymax = max(ymax, mean + error)
            if show_values:
                for bar, mean, result, error in zip(bars, means, group, errors):
                    if not math.isfinite(mean):
                        continue
                    if variance and result["variance"] is not None:
                        text = f"μ={mean:.2f}\nσ²={result['variance']:.3g}"
                    else:
                        text = f"{mean:.2f}"
                    ax.annotate(
                        text,
                        (bar.get_x() + bar.get_width() / 2, mean + error),
                        xytext=(0, 8), textcoords="offset points", ha="center", fontsize=7,
                    )
        ax.set_xticks(x, [mode_names[m] for m in modes])
        ax.set_ylabel(ylabel)
        ax.set_title(title, pad=18, fontweight="normal")
        ax.grid(axis="y", alpha=0.3)
        ax.set_axisbelow(True)
        ax.set_ylim(0, max(1.0, ymax * (1.35 if show_values else 1.22)))
        if len(series) > 1:
            ax.legend(loc="center left", bbox_to_anchor=(1.01, 0.5))
        fig.tight_layout()
        for ext in ("svg", "pdf"):
            dest = render_dir(root, ext, show_values)
            dest.mkdir(parents=True, exist_ok=True)
            fig.savefig(dest / f"{number:02d}_{name}.{ext}", bbox_inches="tight", dpi=300)
        plt.close(fig)
    return True


def write_stats(path: Path, rows: list[dict[str, Any]]) -> None:
    columns = [
        "chart", "name", "scope", "series", "mode", "source", "quality",
        "n", "mean", "variance", "sd", "sem", "ci95_low", "ci95_high",
    ]
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: row.get(key) for key in columns})


def source_range(path: Path | None, kind: str, shift_ns: int = 0) -> tuple[int | None, int | None, int]:
    if path is None or not path.is_file():
        return None, None, 0
    if kind == "frequency":
        rows = freq_rows(path, shift_ns)
        if not rows:
            return None, None, 0
        return rows[0][0], rows[-1][0], len(rows)
    if kind == "timeline":
        timestamps = []
        for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
            try:
                row = json.loads(raw)
            except Exception:
                continue
            ts = finite(row.get("monotonic_ns"))
            if ts is not None:
                timestamps.append(int(ts) + shift_ns)
        return (min(timestamps), max(timestamps), len(timestamps)) if timestamps else (None, None, 0)
    return None, None, 0


def msr_range(trace: dict[str, Any] | None) -> tuple[int | None, int | None, int]:
    if not trace or len(trace.get("t", [])) == 0:
        return None, None, 0
    t = trace["t"]
    dt = trace["dt"]
    return int(t[0]), int(t[-1] + dt[-1] * 1e9), len(t)


def build_audits(root: Path, out: Path, records, files, modes) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    windows_rows: list[dict[str, Any]] = []
    timing_rows: list[dict[str, Any]] = []
    alignment_rows: list[dict[str, Any]] = []
    log_lines = [
        "GreenQUIC phase-attribution timing audit",
        "========================================",
        "All chart phase windows use client CLOCK_MONOTONIC request markers.",
        "Server sources are shifted into the client monotonic domain using repeated HTTP GET pairs.",
        "Timeline log timestamps are wrapper-capture times and are NOT used for high-rate policy/hint counts.",
        "",
    ]

    for (rep, mode), record in sorted(records.items()):
        ws = request_windows(record)
        if not ws:
            log_lines.append(f"rep{rep:02d} {mode}: NO REQUEST WINDOWS")
            continue
        first, last = ws[0][0], ws[-1][1]
        for i, (a, b) in enumerate(ws, 1):
            windows_rows.append({"repetition": rep, "mode": mode, "phase": "active", "index": i,
                                 "start_ns": a, "end_ns": b, "duration_s": (b-a)/1e9})
            if i < len(ws) and ws[i][0] > b:
                windows_rows.append({"repetition": rep, "mode": mode, "phase": "gap", "index": i,
                                     "start_ns": b, "end_ns": ws[i][0], "duration_s": (ws[i][0]-b)/1e9})
        active_s = sum((b-a) for a,b in ws) / 1e9
        combined_s = (last-first) / 1e9
        gap_s = combined_s - active_s
        relation_error_ns = int(round((combined_s - active_s - gap_s) * 1e9))
        alignment = record.get("server_alignment") or {}
        log_lines.append(
            f"rep{rep:02d} {mode}: downloads={len(ws)} active={active_s:.6f}s "
            f"gap={gap_s:.6f}s combined={combined_s:.6f}s partition_error={relation_error_ns}ns"
        )
        if alignment:
            log_lines.append(
                f"  server GET alignment: valid={alignment.get('valid')} pairs={alignment.get('pair_count')}/"
                f"{alignment.get('request_count')} shift={int(alignment.get('shift_ns',0))/1e6:.3f}ms "
                f"spread={int(alignment.get('spread_ns',0))/1e6:.3f}ms "
                f"max_residual={int(alignment.get('max_abs_residual_ns',0))/1e6:.3f}ms"
            )
            for pair in alignment.get("pairs", []):
                alignment_rows.append({"repetition": rep, "mode": mode, **pair,
                                       "shift_ns": alignment.get("shift_ns"),
                                       "spread_ns": alignment.get("spread_ns"),
                                       "valid": alignment.get("valid")})

        for endpoint in ("client", "server"):
            shift = int(record.get("server_shift_ns", 0)) if endpoint == "server" else 0
            bundle = files.get((endpoint, rep, mode), {})
            ranges = []
            a, b, n = msr_range(record.get(endpoint))
            ranges.append(("rapl", a, b, n, "CLOCK_MONOTONIC; interval-overlap weighted at phase boundaries"))
            a, b, n = source_range(bundle.get("frequency"), "frequency", shift)
            ranges.append(("frequency", a, b, n, "CLOCK_MONOTONIC samples; observed state at sample timestamps"))
            a, b, n = source_range(bundle.get("timeline"), "timeline", shift)
            ranges.append(("timeline", a, b, n, "wrapper CLOCK_MONOTONIC log-capture timestamps; audit only"))
            cstate = record.get(f"{endpoint}_cstate") or {}
            timing_rows.append({
                "repetition": rep, "mode": mode, "endpoint": endpoint, "source": "cstate",
                "path": str(bundle.get("cstate") or ""), "source_start_ns": "", "source_end_ns": "",
                "samples": "", "combined_start_ns": first, "combined_end_ns": last,
                "start_margin_ms": "", "end_margin_ms": "", "coverage_ok": bool(cstate),
                "server_shift_ns": shift, "clock_method": cstate.get("clock_method", ""),
                "clock_uncertainty_ns": cstate.get("clock_uncertainty_ns", ""),
                "usage": "phase C-state clipping when clock bridge/alignment is valid",
            })
            for source, a, b, n, semantics in ranges:
                coverage = a is not None and b is not None and a <= first and b >= last
                timing_rows.append({
                    "repetition": rep, "mode": mode, "endpoint": endpoint, "source": source,
                    "path": str(bundle.get(source if source != "rapl" else "msr") or ""),
                    "source_start_ns": a if a is not None else "",
                    "source_end_ns": b if b is not None else "", "samples": n,
                    "combined_start_ns": first, "combined_end_ns": last,
                    "start_margin_ms": (first-a)/1e6 if a is not None else "",
                    "end_margin_ms": (b-last)/1e6 if b is not None else "",
                    "coverage_ok": coverage, "server_shift_ns": shift,
                    "clock_method": "", "clock_uncertainty_ns": "",
                    "usage": semantics,
                })
                log_lines.append(
                    f"  {endpoint:6s} {source:9s}: samples={n} coverage={'PASS' if coverage else 'FAIL'}"
                    + (f" start_margin={(first-a)/1e3:.1f}us end_margin={(b-last)/1e3:.1f}us" if a is not None and b is not None else "")
                )
        log_lines.append("")

    audit = out / "audit"
    audit.mkdir(parents=True, exist_ok=True)
    for filename, rows in (("phase_windows.csv", windows_rows), ("timing_sources.csv", timing_rows),
                           ("server_get_alignment_pairs.csv", alignment_rows)):
        path = audit / filename
        columns = sorted({key for row in rows for key in row}) if rows else ["status"]
        with path.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=columns)
            writer.writeheader()
            if rows:
                writer.writerows(rows)
    (audit / "phase_attribution_audit.log").write_text("\n".join(log_lines) + "\n", encoding="utf-8")
    return timing_rows, alignment_rows


def omission_reason(scope: str, number: int) -> str:
    if number in {1, 2, 3, 24, 42, 43}:
        return "phase-independent configuration/metadata; retained only in original 62-chart report"
    if number in {10, 11, 12, 13}:
        return "whole-trace metric; combined workload is not the same as whole trace"
    if number in {25, 26, 27, 28}:
        return "idle/EPOLL counters are cumulative; no exact per-event phase timestamp is recorded"
    if number in {31, 33, 35}:
        return "controller policy-decision counters are cumulative and can reach millions; timeline FREQ lines only represent logged API/change events, not all policy decisions"
    if number in {37, 38, 39, 40}:
        return "QUIC hint counters are process-end cumulative counters; exact per-hint phase timestamps are not recorded"
    if number == 41:
        return "DPDK packet counters are whole-run/transfer-window cumulative counts; exact active-vs-gap packet attribution is not recorded"
    if 48 <= number <= 62:
        return "representative time-series/overlay chart has no repetition-variance semantics; use original chart set plus timing audit"
    if number == 4 and scope != "active":
        return "active goodput is only defined for active scope"
    if number == 5 and scope != "combined":
        return "gap-inclusive/workload goodput is only defined for combined scope"
    if number == 9 and scope == "gap":
        return "gaps carry zero useful payload; J/GiB is not defined for gap-only scope"
    if number in {44, 46} and scope != "active":
        return "active-transfer RAPL duplicate is only applicable to active scope"
    if number in {45, 47} and scope != "gap":
        return "gap RAPL duplicate is only applicable to gap scope"
    if number in {19, 20, 21, 22, 23} and scope != "gap":
        return "original chart family is specifically the inter-download-gap C-state family"
    if number in {14, 15, 16, 17, 18} and scope == "gap":
        return "gap C-state uses original chart numbers 19–23 in this phase report"
    return "no scientifically valid phase-attributed counterpart is defined"


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate audited active/gap/combined chart variants")
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--reporter-dir", type=Path, required=True)
    args = parser.parse_args()

    reporter = args.reporter_dir.resolve()
    sys.path.insert(0, str(reporter))
    import build_sheet_rules_all_aligned as aligned

    base = aligned.base
    modes = base.MODES
    mode_names = base.MODE_NAMES
    root = args.input.resolve()
    report = (args.output or (root / "the_sheet_rules_all")).resolve()
    out = report / "newchart"
    # Clear only this helper's previous output so stale *_unavailable placeholders
    # from v1 cannot survive a regeneration.
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True, exist_ok=True)

    records = base.raw_data(root)
    files = base.discover_files(root)
    tables = base.load_tables(root)
    clients = index_rows(tables.get("client_runs", []))

    build_audits(root, out, records, files, modes)

    payloads = {
        mode: [payload_gib(base, clients, rep, mode) for (rep, m), _ in sorted(records.items()) if m == mode]
        for mode in modes
    }
    gbits = {mode: [useful_gbit(value) for value in payloads[mode]] for mode in modes}

    all_stats: list[dict[str, Any]] = []
    chart_audit: list[dict[str, Any]] = []
    generated_by_scope: dict[str, list[int]] = {}

    for scope in SCOPES:
        generated_numbers: set[int] = set()
        for version in VERSIONS:
            variance = version == "with_variance"
            dest = out / scope / version
            rows: list[dict[str, Any]] = []

            def emit(number: int, title: str, ylabel: str, series, source: str, quality: str) -> None:
                name = CHART_NAMES[number]
                if save_bar(dest, number, name, title, ylabel, series, modes, mode_names,
                            variance, rows, scope, source, quality):
                    generated_numbers.add(number)

            durations = {mode: per_mode(records, mode, lambda rep, r, s=scope: scope_duration(r, s)) for mode in modes}
            emit(6, f"{scope.title()} duration", "Seconds", {"Duration": durations},
                 "client request start/complete MONOTONIC markers", "exact application phase boundaries")

            # Goodput from useful payload divided by the exact request-window duration.
            if scope in {"active", "combined"}:
                number = 4 if scope == "active" else 5
                goodput = {}
                for mode in modes:
                    vals = []
                    ds = durations[mode]
                    for gbit, duration_s in zip(gbits[mode], ds):
                        vals.append(gbit / duration_s if gbit is not None and duration_s is not None and duration_s > 0 else None)
                    goodput[mode] = vals
                emit(number,
                     "Active goodput" if scope == "active" else "Gap-inclusive workload goodput",
                     "Gbit/s", {"Goodput": goodput},
                     "useful payload + client request MONOTONIC windows", "exact workload accounting")

            server_energy = {mode: per_mode(records, mode, lambda rep, r, s=scope: phase_rapl(r, "server", s, "energy_j")) for mode in modes}
            client_energy = {mode: per_mode(records, mode, lambda rep, r, s=scope: phase_rapl(r, "client", s, "energy_j")) for mode in modes}
            combined_energy = {mode: combine(server_energy[mode], client_energy[mode]) for mode in modes}
            server_power = {mode: per_mode(records, mode, lambda rep, r, s=scope: phase_rapl(r, "server", s, "power_w")) for mode in modes}
            client_power = {mode: per_mode(records, mode, lambda rep, r, s=scope: phase_rapl(r, "client", s, "power_w")) for mode in modes}
            combined_power = {}
            for mode in modes:
                vals = []
                for se, ce, duration_s in zip(server_energy[mode], client_energy[mode], durations[mode]):
                    vals.append((se + ce) / duration_s if se is not None and ce is not None and duration_s is not None and duration_s > 0 else None)
                combined_power[mode] = vals

            power_series = {"Server": server_power, "Client": client_power, "Combined": combined_power}
            energy_series = {"Server": server_energy, "Client": client_energy, "Combined": combined_energy}
            emit(7, f"{scope.title()} average RAPL power", "Power (W)", power_series,
                 "6 ms package+DRAM RAPL samples integrated by interval overlap", "phase-boundary weighted integration")
            emit(8, f"{scope.title()} RAPL energy", "Energy (J)", energy_series,
                 "6 ms package+DRAM RAPL samples integrated by interval overlap", "phase-boundary weighted integration")

            if scope in {"active", "combined"}:
                epg: dict[str, dict[str, list[float | None]]] = {}
                for label, source in (("Server", server_energy), ("Client", client_energy), ("Combined", combined_energy)):
                    epg[label] = {}
                    for mode in modes:
                        epg[label][mode] = [
                            energy / payload if energy is not None and payload is not None and payload > 0 else None
                            for energy, payload in zip(source[mode], payloads[mode])
                        ]
                emit(9, f"{scope.title()} RAPL energy per useful GiB", "J/GiB", epg,
                     "phase RAPL energy + total useful payload", "exact payload; phase-boundary weighted energy")

            if scope == "active":
                emit(44, "Active-transfer RAPL power", "Power (W)", power_series,
                     "6 ms package+DRAM RAPL samples", "active-window weighted integration")
                emit(46, "Active-transfer RAPL energy", "Energy (J)", energy_series,
                     "6 ms package+DRAM RAPL samples", "active-window weighted integration")
            elif scope == "gap":
                emit(45, "Inter-download-gap RAPL power", "Power (W)", power_series,
                     "6 ms package+DRAM RAPL samples", "gap-window weighted integration")
                emit(47, "Inter-download-gap RAPL energy", "Energy (J)", energy_series,
                     "6 ms package+DRAM RAPL samples", "gap-window weighted integration")

            # C-state chart family. Active uses original 14–18, gap uses 19–23.
            # Combined reuses 14–17; combined interval count is omitted unless an
            # aligned_intervals field exists, avoiding active+gap double counting.
            if scope == "gap":
                server_num, client_num, idle_num, frac_num, intervals_num = 19, 20, 21, 22, 23
            else:
                server_num, client_num, idle_num, frac_num, intervals_num = 14, 15, 16, 17, 18
            for number, endpoint in ((server_num, "server"), (client_num, "client")):
                series = {
                    f"state{state}": {
                        mode: per_mode(records, mode, lambda rep, r, ep=endpoint, st=state, s=scope: cstate_value(r, ep, s, "state", st))
                        for mode in modes
                    }
                    for state in range(4)
                }
                emit(number, f"{scope.title()} — {endpoint.title()} C-state residency", "Seconds", series,
                     "Linux cpu_idle intervals mapped with MONOTONIC_RAW↔MONOTONIC bridge",
                     "interval clipping; server additionally requires validated GET alignment")
            for number, metric, title, ylabel in (
                (idle_num, "idle_s", "CPU idle time", "Seconds"),
                (frac_num, "idle_fraction_pct", "CPU idle fraction", "Percent"),
                (intervals_num, "intervals", "Idle intervals", "Count"),
            ):
                series = {
                    endpoint.title(): {
                        mode: per_mode(records, mode, lambda rep, r, ep=endpoint, me=metric, s=scope: cstate_value(r, ep, s, me))
                        for mode in modes
                    }
                    for endpoint in ("server", "client")
                }
                emit(number, f"{scope.title()} — {title}", ylabel, series,
                     "Linux cpu_idle intervals", "interval clipping; no synthetic combined interval count")

            # Frequency observation charts. These are sampler observations, not
            # controller policy-decision counts.
            for number, endpoint in ((29, "server"), (30, "client")):
                series = {}
                for metric, label in (("min", "Min"), ("mean", "Mean"), ("max", "Max")):
                    series[label] = {
                        mode: [
                            freq_metric(r, files.get((endpoint, rep, mode), {}), endpoint, scope, metric)
                            for (rep, m), r in sorted(records.items()) if m == mode
                        ]
                        for mode in modes
                    }
                emit(number, f"{scope.title()} — {endpoint.title()} observed frequency", "GHz", series,
                     "timestamped frequency sampler", "sample-timestamp phase attribution")

            for number, endpoint in ((32, "server"), (34, "client")):
                series = {"Observed transitions": {
                    mode: [
                        freq_metric(r, files.get((endpoint, rep, mode), {}), endpoint, scope, "changes")
                        for (rep, m), r in sorted(records.items()) if m == mode
                    ]
                    for mode in modes
                }}
                emit(number, f"{scope.title()} — {endpoint.title()} observed frequency transitions",
                     "Transitions", series, "timestamped frequency sampler",
                     "transitions counted independently inside each disjoint phase window")

            series = {
                endpoint.title(): {
                    mode: [
                        freq_metric(r, files.get((endpoint, rep, mode), {}), endpoint, scope, "samples")
                        for (rep, m), r in sorted(records.items()) if m == mode
                    ]
                    for mode in modes
                }
                for endpoint in ("server", "client")
            }
            emit(36, f"{scope.title()} — timestamped frequency samples", "Count", series,
                 "timestamped frequency sampler", "half-open phase-window membership")

            write_stats(dest / "statistics.csv", rows)
            all_stats.extend(rows)

        generated_by_scope[scope] = sorted(generated_numbers)
        for number in range(1, EXPECTED_ORIGINAL_CHARTS + 1):
            if number not in generated_numbers:
                chart_audit.append({
                    "scope": scope, "chart": number, "status": "omitted",
                    "reason": omission_reason(scope, number),
                })
            else:
                chart_audit.append({"scope": scope, "chart": number, "status": "generated", "reason": ""})

    write_stats(out / "statistics_all_scopes.csv", all_stats)
    with (out / "audit" / "chart_availability.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=["scope", "chart", "status", "reason"])
        writer.writeheader()
        writer.writerows(chart_audit)

    manifest = {
        "schema": "greenquic-newchart-v2-audited",
        "scopes": list(SCOPES),
        "versions": list(VERSIONS),
        "render_variants": ["svg/with_values", "svg/without_values", "pdf/with_values", "pdf/without_values"],
        "generated_chart_numbers": generated_by_scope,
        "original_62_chart_report": "unchanged under the_sheet_rules_all/charts",
        "placeholder_policy": "no unavailable placeholder images; omitted phase charts are documented in audit/chart_availability.csv",
        "variance": "unbiased sample variance across independent repetitions (n-1)",
        "error_bars": "mean ± sample SD across independent repetitions",
        "combined": "D1 start through last download completion = active transfer + inter-download gaps only",
        "interval_policy": "half-open [start,end) for timestamp samples to avoid phase-boundary double attribution",
        "server_alignment_guard": "repeated HTTP GET pairs; default max offset spread 5 ms",
        "timeline_policy": "wrapper-capture timeline timestamps are audit-only for high-rate counters; policy/hint/EPOLL phase counts are not inferred",
        "frequency_policy": "charts 32/34 are observed sampler transitions, not controller policy-decision counters",
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    print("[greenquic-newchart] audited phase chart generation complete")
    for scope in SCOPES:
        print(f"[greenquic-newchart] {scope}: generated charts {generated_by_scope[scope]}")
    print(f"[greenquic-newchart] timing audit: {out/'audit'/'phase_attribution_audit.log'}")
    print(f"[greenquic-newchart] chart availability: {out/'audit'/'chart_availability.csv'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
