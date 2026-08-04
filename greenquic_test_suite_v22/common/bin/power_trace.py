#!/usr/bin/env python3
"""GreenQUIC whole-system power and cumulative-energy sampler."""
from __future__ import annotations

import argparse
import csv
import html
import json
import math
import os
import re
import signal
import statistics
import subprocess
import time
from pathlib import Path
from typing import Any

from gq_plot import write_line_svg

_STOP = False


def request_stop(_signum: int, _frame: object) -> None:
    global _STOP
    _STOP = True


def percentile(values: list[float], p: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * p
    low, high = math.floor(position), math.ceil(position)
    if low == high:
        return ordered[low]
    fraction = position - low
    return ordered[low] * (1.0 - fraction) + ordered[high] * fraction


def unit_to_watts(value: float, unit: str) -> float:
    normalized = unit.replace("µ", "u").lower()
    factors = {"w": 1.0, "kw": 1000.0, "mw": 1e-3, "uw": 1e-6, "nw": 1e-9}
    if normalized not in factors:
        raise ValueError(f"unsupported power unit: {unit}")
    return value * factors[normalized]


def read_from_sensors(match: str, occurrence: str) -> tuple[float, str, str]:
    completed = subprocess.run(
        ["sensors"], check=False, capture_output=True, text=True, timeout=5.0
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or f"exit status {completed.returncode}"
        raise RuntimeError(f"sensors failed: {detail}")
    matching = [line.strip() for line in completed.stdout.splitlines() if match.lower() in line.lower()]
    if not matching:
        raise RuntimeError(f"no sensors line contains {match!r}")
    line = matching[0] if occurrence == "first" else matching[-1]
    found = re.search(
        rf"{re.escape(match)}\s*:\s*([+-]?\d+(?:\.\d+)?)\s*(kW|mW|uW|µW|nW|W)\b",
        line,
        re.IGNORECASE,
    )
    if found is None:
        found = re.search(r"([+-]?\d+(?:\.\d+)?)\s*(kW|mW|uW|µW|nW|W)\b", line, re.IGNORECASE)
    if found is None:
        raise RuntimeError(f"cannot parse watts from sensors line: {line}")
    return unit_to_watts(float(found.group(1)), found.group(2)), "lm-sensors", line


def read_from_sysfs(match: str, occurrence: str) -> tuple[float, str, str]:
    candidates: list[Path] = []
    for name in ("power1_average", "power1_input"):
        candidates.extend(sorted(Path("/sys/class/hwmon").glob(f"hwmon*/{name}")))
    readable: list[tuple[Path, str]] = []
    for path in candidates:
        if not os.access(path, os.R_OK):
            continue
        name_file = path.parent / "name"
        sensor_name = name_file.read_text(encoding="utf-8").strip() if name_file.exists() else path.parent.name
        description = f"{sensor_name}:{path.name}"
        if match.lower() in description.lower() or match.lower() == "power1":
            readable.append((path, description))
    if not readable:
        readable = [(p, str(p)) for p in candidates if os.access(p, os.R_OK)]
    if not readable:
        raise RuntimeError("no readable hwmon power1 sensor")
    path, description = readable[0] if occurrence == "first" else readable[-1]
    raw = float(path.read_text(encoding="utf-8").strip())
    return raw / 1_000_000.0, "hwmon-sysfs", f"{description} raw_uw={raw:g} path={path}"


def read_power(match: str, occurrence: str) -> tuple[float, str, str]:
    problems: list[str] = []
    try:
        return read_from_sensors(match, occurrence)
    except Exception as exc:
        problems.append(str(exc))
    try:
        return read_from_sysfs(match, occurrence)
    except Exception as exc:
        problems.append(str(exc))
    raise RuntimeError("; ".join(problems))


def cumulative_energy(samples: list[dict[str, Any]]) -> list[float]:
    totals = [0.0] if samples else []
    for left, right in zip(samples, samples[1:]):
        dt = float(right["elapsed_s"]) - float(left["elapsed_s"])
        increment = 0.0
        if dt > 0:
            increment = (float(left["power_w"]) + float(right["power_w"])) * 0.5 * dt
        totals.append(totals[-1] + increment)
    return totals


def histogram_svg(path: Path, role: str, values: list[float]) -> None:
    if not values:
        return
    width = int(os.environ.get("GQ_HISTOGRAM_WIDTH_PX", "1800"))
    height = int(os.environ.get("GQ_HISTOGRAM_HEIGHT_PX", "700"))
    width = min(max(width, 900), 20000)
    height = min(max(height, 400), 5000)
    left, right, top, bottom = 100, 50, 70, 100
    plot_w, plot_h = width - left - right, height - top - bottom
    bins = min(20, max(1, math.ceil(math.sqrt(len(values)))))
    low, high = min(values), max(values)
    if high <= low:
        low -= 0.5
        high += 0.5
    step = (high - low) / bins
    counts = [0] * bins
    for value in values:
        counts[min(bins - 1, max(0, int((value - low) / step)))] += 1
    max_count = max(counts) or 1
    bar_w = plot_w / bins
    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        '<rect width="100%" height="100%" fill="white"/>',
        f'<text x="{width/2}" y="35" text-anchor="middle" font-family="sans-serif" font-size="24">{html.escape(f"GreenQUIC {role} power1 histogram")}</text>',
        f'<line x1="{left}" y1="{top}" x2="{left}" y2="{top+plot_h}" stroke="black" stroke-width="2"/>',
        f'<line x1="{left}" y1="{top+plot_h}" x2="{left+plot_w}" y2="{top+plot_h}" stroke="black" stroke-width="2"/>',
    ]
    for index, count in enumerate(counts):
        bar_h = plot_h * count / max_count
        x = left + index * bar_w + 2
        y = top + plot_h - bar_h
        out.append(f'<rect x="{x:.2f}" y="{y:.2f}" width="{max(1.0, bar_w-4):.2f}" height="{bar_h:.2f}" fill="#d9e8f5" stroke="#1f77b4"/>')
    out.extend([
        f'<text x="{width/2}" y="{height-28}" text-anchor="middle" font-family="sans-serif" font-size="17">Power [W]</text>',
        f'<text x="30" y="{height/2}" text-anchor="middle" font-family="sans-serif" font-size="17" transform="rotate(-90 30 {height/2})">Sample count</text>',
        f'<text x="{left}" y="{top+plot_h+30}" text-anchor="middle" font-family="monospace" font-size="14">{low:.2f}</text>',
        f'<text x="{left+plot_w}" y="{top+plot_h+30}" text-anchor="middle" font-family="monospace" font-size="14">{high:.2f}</text>',
        '</svg>',
    ])
    path.write_text("\n".join(out) + "\n", encoding="utf-8")


def record(args: argparse.Namespace) -> int:
    global _STOP
    _STOP = False
    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)
    prefix: Path = args.prefix
    prefix.parent.mkdir(parents=True, exist_ok=True)
    paths = {
        "json": Path(str(prefix) + ".json"),
        "csv": Path(str(prefix) + ".csv"),
        "lists": Path(str(prefix) + "_python_lists.txt"),
        "power_svg": Path(str(prefix) + "_timeseries.svg"),
        "energy_svg": Path(str(prefix) + "_energy_timeseries.svg"),
        "hist_svg": Path(str(prefix) + "_histogram.svg"),
    }
    start_wall_ns = time.time_ns()
    start_mono_ns = time.monotonic_ns()
    interval_ns = int(args.interval_ms * 1_000_000)
    next_sample_ns = start_mono_ns
    samples: list[dict[str, Any]] = []
    problems: list[str] = []
    source = "unavailable"
    source_detail = ""

    while not _STOP:
        now_ns = time.monotonic_ns()
        if args.duration_s is not None and (now_ns - start_mono_ns) / 1e9 >= args.duration_s:
            break
        if now_ns < next_sample_ns:
            time.sleep(min(0.05, (next_sample_ns - now_ns) / 1e9))
            continue
        mono_ns, wall_ns = time.monotonic_ns(), time.time_ns()
        try:
            watts, source, source_detail = read_power(args.sensor_match, args.sensor_occurrence)
            samples.append({
                "sample_index": len(samples),
                "wall_ns": wall_ns,
                "monotonic_ns": mono_ns,
                "elapsed_s": (mono_ns - start_mono_ns) / 1e9,
                "power_w": watts,
                "source_line": source_detail,
            })
        except RuntimeError as exc:
            message = str(exc)
            if not problems or problems[-1] != message:
                problems.append(message)
        next_sample_ns += interval_ns
        if next_sample_ns <= mono_ns:
            next_sample_ns = mono_ns + interval_ns

    final_mono_ns, final_wall_ns = time.monotonic_ns(), time.time_ns()
    if not samples or final_mono_ns - int(samples[-1]["monotonic_ns"]) >= 1_000_000:
        try:
            watts, source, source_detail = read_power(args.sensor_match, args.sensor_occurrence)
            samples.append({
                "sample_index": len(samples),
                "wall_ns": final_wall_ns,
                "monotonic_ns": final_mono_ns,
                "elapsed_s": (final_mono_ns - start_mono_ns) / 1e9,
                "power_w": watts,
                "source_line": source_detail,
            })
        except RuntimeError as exc:
            message = str(exc)
            if not problems or problems[-1] != message:
                problems.append(message)

    powers = [float(row["power_w"]) for row in samples]
    times = [float(row["elapsed_s"]) for row in samples]
    cumulative = cumulative_energy(samples)
    energy_j = cumulative[-1] if cumulative else None
    covered_s = times[-1] - times[0] if len(times) >= 2 else 0.0
    average = energy_j / covered_s if energy_j is not None and covered_s > 0 else (powers[0] if len(powers) == 1 else None)
    duration_ms = (times[-1] if times else 0.0) * 1000.0

    power_plot = energy_plot = None
    if samples:
        power_plot = write_line_svg(
            paths["power_svg"], kind="power",
            title=f"GreenQUIC {args.role} whole-system power over time",
            y_label="Power [W]",
            series=[{"label": "power1", "points": [(t * 1000.0, p) for t, p in zip(times, powers)]}],
            duration_ms=duration_ms, step=False, y_value_format=".2f",
        )
        energy_plot = write_line_svg(
            paths["energy_svg"], kind="power",
            title=f"GreenQUIC {args.role} cumulative whole-system energy",
            y_label="Cumulative energy [J]",
            series=[{"label": "integrated energy", "points": [(t * 1000.0, e) for t, e in zip(times, cumulative)]}],
            duration_ms=duration_ms, step=False, y_value_format=".2f",
        )
        histogram_svg(paths["hist_svg"], args.role, powers)

    output: dict[str, Any] = {
        "schema": "greenquic-power1-trace-v2",
        "label": args.label,
        "role": args.role,
        "sensor_kind": "whole-system power1 (lm-sensors or hwmon)",
        "source": source,
        "source_detail_last": source_detail,
        "sensor_match": args.sensor_match,
        "sensor_occurrence": args.sensor_occurrence,
        "start_wall_ns": start_wall_ns,
        "end_wall_ns": time.time_ns(),
        "elapsed_s": (time.monotonic_ns() - start_mono_ns) / 1e9,
        "sample_interval_ms_requested": args.interval_ms,
        "sample_count": len(samples),
        "time_s_series": times,
        "power_w_series": powers,
        "cumulative_energy_j_series": cumulative,
        "samples": samples,
        "estimated_energy_j_trapezoidal": energy_j,
        "integration_covered_s": covered_s,
        "average_power_w_time_weighted": average,
        "power_w_min": min(powers) if powers else None,
        "power_w_max": max(powers) if powers else None,
        "power_w_mean_samples": statistics.fmean(powers) if powers else None,
        "power_w_median": statistics.median(powers) if powers else None,
        "power_w_p95": percentile(powers, 0.95),
        "plot": None if power_plot is None else {
            "width_px": power_plot.width,
            "height_px": power_plot.height,
            "x_tick_ms": power_plot.tick_ms,
            "x_label_ms": power_plot.label_ms,
            "min_px_per_tick": power_plot.min_px_per_tick,
        },
        "problems": problems,
        "measurement_note": (
            "power1 is whole-system/board power, not CPU package RAPL. Energy is "
            "trapezoidal integration of timestamped power samples. The 10 ms axis "
            "grid is display resolution and does not imply 10 ms power sampling."
        ),
    }
    paths["json"].write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")
    with paths["csv"].open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=[
            "sample_index", "elapsed_s", "wall_ns", "power_w", "cumulative_energy_j", "source_line"
        ])
        writer.writeheader()
        for row, energy in zip(samples, cumulative):
            writer.writerow({
                "sample_index": row["sample_index"], "elapsed_s": row["elapsed_s"],
                "wall_ns": row["wall_ns"], "power_w": row["power_w"],
                "cumulative_energy_j": energy, "source_line": row["source_line"],
            })
    paths["lists"].write_text(
        "time_s = " + repr(times) + "\n" +
        "power_w = " + repr(powers) + "\n" +
        "cumulative_energy_j = " + repr(cumulative) + "\n",
        encoding="utf-8",
    )
    return 0 if samples else 4


def shown(value: object, digits: int = 3) -> str:
    if value is None:
        return "unavailable"
    return f"{float(value):.{digits}f}"


def summary(args: argparse.Namespace) -> int:
    data = json.loads(args.input.read_text(encoding="utf-8"))
    times = data.get("time_s_series") or []
    duration = float(times[-1]) - float(times[0]) if times else None
    plot = data.get("plot") or {}
    print("\n=== GreenQUIC Power and Energy Summary ===")
    print(f"- Role: {data.get('role')}")
    print("- Sensor: power1, whole-system/board power; not package RAPL")
    print(f"- Samples: {data.get('sample_count', 0)}")
    print(f"- Actual sample interval requested: {data.get('sample_interval_ms_requested')} ms")
    print(f"- Trace duration: {shown(duration)} s")
    print(f"- Estimated cumulative energy: {shown(data.get('estimated_energy_j_trapezoidal'))} J")
    print(f"- Time-weighted average power: {shown(data.get('average_power_w_time_weighted'))} W")
    print(f"- Power range: {shown(data.get('power_w_min'))}–{shown(data.get('power_w_max'))} W")
    print(f"- Median / P95: {shown(data.get('power_w_median'))} / {shown(data.get('power_w_p95'))} W")
    if plot:
        print(f"- Plot size: {plot.get('width_px')} × {plot.get('height_px')} px")
        print(f"- X-axis minor tick: {plot.get('x_tick_ms')} ms")
        print(f"- X-axis labeled tick: {plot.get('x_label_ms')} ms")
    print("- Note: axis tick spacing does not change the sensor sampling interval")
    print()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    rec = sub.add_parser("record")
    rec.add_argument("--role", choices=("server", "client"), required=True)
    rec.add_argument("--label", default="")
    rec.add_argument("--prefix", type=Path, required=True)
    rec.add_argument("--interval-ms", type=int, default=1000)
    rec.add_argument("--sensor-match", default="power1")
    rec.add_argument("--sensor-occurrence", choices=("first", "last"), default="last")
    rec.add_argument("--duration-s", type=float)
    show = sub.add_parser("summary")
    show.add_argument("--input", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "record":
        if args.interval_ms < 50:
            parser.error("--interval-ms must be at least 50; lm-sensors is not a reliable 10 ms sampler")
        return record(args)
    return summary(args)


if __name__ == "__main__":
    raise SystemExit(main())
