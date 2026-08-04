#!/usr/bin/env python3
"""GreenQUIC CPU-frequency residency bars with per-CPU numbered mapping."""
from __future__ import annotations

import argparse
import csv
import html
import json
import math
import os
import re
from collections import defaultdict
from pathlib import Path
from typing import Any

CPU_RE = re.compile(r"^\[CPU\s+(\d+)\]")
ACTION_RE = re.compile(r"\bpolicy_action=([^\s]+).*?\bafter_khz=(\d+)")
STATS_RE = re.compile(r"\bfreq_khz=(\d+)")

ACTION_COLORS = {
    "init": "#7F7F7F",
    "freq_min": "#4E79A7",
    "freq_max_hard": "#E15759",
    "freq_max": "#E15759",
    "freq_down": "#F28E2B",
    "freq_up": "#59A14F",
    "hold/sample": "#B07AA1",
    "other": "#76B7B2",
}


def env_int(name: str, default: int, minimum: int, maximum: int) -> int:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    try:
        value = int(raw)
    except ValueError as error:
        raise ValueError(f"{name} must be an integer, got {raw!r}") from error
    if not minimum <= value <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return value


def action_category(interval: dict[str, Any]) -> str:
    action = str(interval.get("action") or "").strip()
    source = str(interval.get("source") or "")
    if action in {"none", "init_then_max"}:
        return "init"
    if action in ACTION_COLORS:
        return action
    if action.startswith("freq_max"):
        return "freq_max_hard"
    if action.startswith("freq_down"):
        return "freq_down"
    if action.startswith("freq_up"):
        return "freq_up"
    if action.startswith("freq_min"):
        return "freq_min"
    if source == "periodic_stats":
        return "hold/sample"
    return "other"


def read_events(path: Path) -> tuple[list[dict[str, Any]], float]:
    events: list[dict[str, Any]] = []
    duration_s = 0.0
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            row = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if row.get("type") != "line":
            continue
        elapsed_s = float(row.get("elapsed_s", 0.0))
        duration_s = max(duration_s, elapsed_s)
        line = str(row.get("line", ""))
        cpu_match = CPU_RE.search(line)
        if not cpu_match:
            continue
        cpu = int(cpu_match.group(1))
        action_match = ACTION_RE.search(line)
        stats_match = STATS_RE.search(line)
        if action_match:
            events.append({
                "elapsed_s": elapsed_s,
                "elapsed_ms": elapsed_s * 1000.0,
                "cpu": cpu,
                "freq_khz": int(action_match.group(2)),
                "source": "frequency_action",
                "action": action_match.group(1),
            })
        elif stats_match:
            events.append({
                "elapsed_s": elapsed_s,
                "elapsed_ms": elapsed_s * 1000.0,
                "cpu": cpu,
                "freq_khz": int(stats_match.group(1)),
                "source": "periodic_stats",
                "action": None,
            })
    events.sort(key=lambda event: (
        float(event["elapsed_ms"]),
        int(event["cpu"]),
        0 if event["source"] == "frequency_action" else 1,
    ))
    return events, duration_s


def deduplicate(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    last_frequency_by_cpu: dict[int, int] = {}
    for event in events:
        cpu = int(event["cpu"])
        frequency = int(event["freq_khz"])
        if last_frequency_by_cpu.get(cpu) == frequency and event["source"] == "periodic_stats":
            continue
        result.append(event)
        last_frequency_by_cpu[cpu] = frequency
    return result


def build_intervals(events: list[dict[str, Any]], duration_ms: float) -> dict[int, list[dict[str, Any]]]:
    events_by_cpu: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for event in events:
        events_by_cpu[int(event["cpu"])].append(event)
    intervals_by_cpu: dict[int, list[dict[str, Any]]] = {}
    for cpu in sorted(events_by_cpu):
        cpu_events = sorted(events_by_cpu[cpu], key=lambda event: float(event["elapsed_ms"]))
        intervals: list[dict[str, Any]] = []
        for index, event in enumerate(cpu_events):
            start_ms = float(event["elapsed_ms"])
            end_ms = float(cpu_events[index + 1]["elapsed_ms"]) if index + 1 < len(cpu_events) else float(duration_ms)
            if end_ms <= start_ms:
                continue
            interval = {
                "number": len(intervals) + 1,
                "cpu": cpu,
                "start_ms": start_ms,
                "end_ms": end_ms,
                "duration_ms": end_ms - start_ms,
                "freq_khz": int(event["freq_khz"]),
                "freq_ghz": int(event["freq_khz"]) / 1_000_000.0,
                "source": event["source"],
                "action": event.get("action"),
            }
            interval["category"] = action_category(interval)
            intervals.append(interval)
        intervals_by_cpu[cpu] = intervals
    return intervals_by_cpu


def nice_step(duration_ms: float, requested_ms: int, max_ticks: int) -> float:
    minimum_step = max(float(requested_ms), duration_ms / max(1, max_ticks))
    if minimum_step <= 0:
        return 1.0
    exponent = 10 ** math.floor(math.log10(minimum_step))
    for factor in (1, 2, 2.5, 5, 10):
        candidate = factor * exponent
        if candidate >= minimum_step:
            return candidate
    return 10 * exponent


def mapping_lines(intervals: list[dict[str, Any]]) -> list[str]:
    result: list[str] = []
    for interval in intervals:
        action = interval.get("action") or (
            "periodic hold/sample" if interval.get("source") == "periodic_stats" else "none/init"
        )
        result.append(
            f"{interval['number']}. t≈{interval['start_ms'] / 1000.0:.3f}–{interval['end_ms'] / 1000.0:.3f}s | "
            f"{interval['freq_ghz']:.3f}GHz | action={action} | type={interval['category']} | "
            f"covered={interval['duration_ms']:.3f}ms"
        )
    return result


def write_bar_svg(
    path: Path,
    *,
    role: str,
    intervals_by_cpu: dict[int, list[dict[str, Any]]],
    duration_ms: float,
) -> dict[str, Any]:
    cpus = sorted(intervals_by_cpu)
    timeline_width = env_int(
        "GQ_FREQ_PLOT_WIDTH_PX",
        env_int("GQ_PLOT_WIDTH_PX", 24000, 1200, 500000),
        1200,
        500000,
    )
    mapping_width = env_int("GQ_FREQ_MAPPING_WIDTH_PX", 6200, 1600, 50000)
    lane_height = env_int("GQ_FREQ_LANE_HEIGHT_PX", 700, 320, 2400)
    max_ticks = env_int("GQ_FREQ_MAX_X_TICKS", 24, 4, 200)
    requested_tick_ms = env_int("GQ_FREQ_PLOT_X_LABEL_MS", 100, 1, 600000)
    dpi = 100
    gap = max(1, round(dpi / 2.54))
    left, right, top, bottom = 125, 30, 125, 95
    width = timeline_width + gap + mapping_width
    height = top + bottom + lane_height * max(1, len(cpus))
    plot_width = timeline_width - left - right
    mapping_x = timeline_width + gap + 28
    max_x_ms = max(float(duration_ms), 1.0)
    maximum_ghz = max(
        (float(interval["freq_ghz"]) for intervals in intervals_by_cpu.values() for interval in intervals),
        default=1.0,
    )
    y_max = max(1.0, math.ceil(maximum_ghz * 10.0) / 10.0) * 1.10
    tick_step_ms = nice_step(max_x_ms, requested_tick_ms, max_ticks)

    def x_position(value_ms: float) -> float:
        return left + min(max(value_ms, 0.0), max_x_ms) / max_x_ms * plot_width

    output = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        '<rect width="100%" height="100%" fill="white"/>',
        f'<text x="{width / 2:.1f}" y="34" text-anchor="middle" font-family="sans-serif" font-size="25">{html.escape(f"GreenQUIC {role} CPU-frequency residency bars")}</text>',
        f'<text x="{width / 2:.1f}" y="64" text-anchor="middle" font-family="sans-serif" font-size="15">One lane per CPU; height = GHz; width = covered time; color = frequency action type</text>',
    ]

    # Global color legend.
    legend_x = left
    legend_y = 92
    for category, color in ACTION_COLORS.items():
        output.append(f'<rect x="{legend_x}" y="{legend_y - 14}" width="22" height="14" fill="{color}" stroke="black"/>')
        output.append(f'<text x="{legend_x + 29}" y="{legend_y}" font-family="sans-serif" font-size="12">{html.escape(category)}</text>')
        legend_x += 150

    plot_bottom = top + lane_height * max(1, len(cpus))
    tick = 0.0
    while tick <= max_x_ms + tick_step_ms * 0.001:
        x = x_position(tick)
        output.append(f'<line x1="{x:.2f}" y1="{top}" x2="{x:.2f}" y2="{plot_bottom}" stroke="#dedede" stroke-width="1"/>')
        output.append(f'<text x="{x:.2f}" y="{plot_bottom + 32}" text-anchor="middle" font-family="monospace" font-size="13">{tick:g}</text>')
        tick += tick_step_ms

    for lane_index, cpu in enumerate(cpus):
        lane_top = top + lane_index * lane_height
        lane_bottom = lane_top + lane_height - 70
        usable_height = lane_height - 135
        output.append(f'<rect x="{left}" y="{lane_top}" width="{plot_width}" height="{lane_height - 45}" fill="#fafafa" stroke="#aaaaaa"/>')
        output.append(f'<text x="{left - 16}" y="{lane_top + 25}" text-anchor="end" font-family="sans-serif" font-size="16" font-weight="bold">CPU {cpu}</text>')

        for y_index in range(6):
            value = y_max * y_index / 5.0
            y = lane_bottom - value / y_max * usable_height
            output.append(f'<line x1="{left}" y1="{y:.2f}" x2="{timeline_width - right}" y2="{y:.2f}" stroke="#e6e6e6"/>')
            output.append(f'<text x="{left - 12}" y="{y + 5:.2f}" text-anchor="end" font-family="monospace" font-size="13">{value:.2f}</text>')

        intervals = intervals_by_cpu[cpu]
        last_label_x = -1e9
        label_level = 0
        for interval in intervals:
            x0 = x_position(float(interval["start_ms"]))
            x1 = x_position(float(interval["end_ms"]))
            bar_width = max(1.0, x1 - x0)
            frequency_ghz = float(interval["freq_ghz"])
            bar_height = frequency_ghz / y_max * usable_height
            y = lane_bottom - bar_height
            category = str(interval["category"])
            color = ACTION_COLORS.get(category, ACTION_COLORS["other"])
            output.append(f'<rect x="{x0:.2f}" y="{y:.2f}" width="{bar_width:.2f}" height="{bar_height:.2f}" fill="{color}" stroke="black" stroke-width="0.7"/>')

            center = x0 + bar_width / 2.0
            if center - last_label_x < 36:
                label_level = (label_level + 1) % 4
            else:
                label_level = 0
            label_y = max(lane_top + 26 + label_level * 22, y - 8 - label_level * 3)
            output.append(
                f'<text x="{center:.2f}" y="{label_y:.2f}" text-anchor="middle" '
                f'font-family="sans-serif" font-size="12" font-weight="bold" '
                f'fill="#111111" stroke="white" stroke-width="3" paint-order="stroke">{interval["number"]}</text>'
            )
            last_label_x = center

        output.append(f'<line x1="{left}" y1="{lane_bottom}" x2="{timeline_width - right}" y2="{lane_bottom}" stroke="black" stroke-width="2"/>')

        # Mapping panel for this CPU.
        output.append(f'<text x="{mapping_x}" y="{lane_top + 25}" font-family="sans-serif" font-size="16" font-weight="bold">CPU {cpu} frequency mapping</text>')
        output.append(f'<text x="{mapping_x}" y="{lane_top + 49}" font-family="sans-serif" font-size="12">t≈ = approximate log time; covered = how long that frequency remained until the next observed event.</text>')
        lines = mapping_lines(intervals)
        available = max(1, lane_height - 100)
        line_step = max(15, min(25, available // max(1, len(lines))))
        font_size = max(8, min(13, line_step - 3))
        for index, line in enumerate(lines):
            y_text = lane_top + 82 + index * line_step
            if y_text > lane_top + lane_height - 20:
                break
            output.append(f'<text x="{mapping_x}" y="{y_text}" font-family="monospace" font-size="{font_size}">{html.escape(line)}</text>')

    output.extend([
        f'<text x="{timeline_width / 2:.1f}" y="{height - 23}" text-anchor="middle" font-family="sans-serif" font-size="17">Elapsed time [ms] — tick {tick_step_ms:g} ms</text>',
        f'<text x="27" y="{height / 2:.1f}" text-anchor="middle" font-family="sans-serif" font-size="17" transform="rotate(-90 27 {height / 2:.1f})">Frequency [GHz]</text>',
        '</svg>',
    ])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(output) + "\n", encoding="utf-8")
    return {
        "kind": "cpuwise_frequency_interval_bars_with_mapping_v4",
        "width_px": width,
        "height_px": height,
        "timeline_width_px": timeline_width,
        "mapping_width_px": mapping_width,
        "mapping_gap_cm": 1.0,
        "x_tick_ms": tick_step_ms,
        "x_label_ms": tick_step_ms,
        "lanes": len(cpus),
        "cpus": cpus,
        "bar_color": "frequency action category",
        "action_colors": ACTION_COLORS,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeline", type=Path, required=True)
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument("--role", choices=("server", "client"), required=True)
    args = parser.parse_args()

    raw_events, duration_s = read_events(args.timeline)
    events = deduplicate(raw_events)
    duration_ms = duration_s * 1000.0
    args.prefix.parent.mkdir(parents=True, exist_ok=True)
    json_path = Path(str(args.prefix) + ".json")
    csv_path = Path(str(args.prefix) + ".csv")
    list_path = Path(str(args.prefix) + "_lists.txt")
    svg_path = Path(str(args.prefix) + "_timeseries.svg")
    intervals_by_cpu = build_intervals(events, duration_ms)
    plot = None
    if any(intervals_by_cpu.values()):
        plot = write_bar_svg(
            svg_path,
            role=args.role,
            intervals_by_cpu=intervals_by_cpu,
            duration_ms=duration_ms,
        )

    cpus = sorted(intervals_by_cpu)
    frequencies = [int(event["freq_khz"]) for event in events]
    output = {
        "schema": "greenquic-frequency-trace-v4",
        "role": args.role,
        "timeline_duration_s": duration_s,
        "event_count_raw": len(raw_events),
        "event_count": len(events),
        "cpus": cpus,
        "min_freq_khz": min(frequencies) if frequencies else None,
        "max_freq_khz": max(frequencies) if frequencies else None,
        "events": events,
        "frequency_intervals_by_cpu": {str(cpu): intervals for cpu, intervals in intervals_by_cpu.items()},
        "plot": plot,
        "measurement_note": (
            "Each CPU has one lane. Each numbered bar is one deduplicated frequency-residency interval; "
            "height is GHz, width is covered time until the next observed frequency event, and color is action type. "
            "Frequency before the first observed event is not inferred."
        ),
    }
    json_path.write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")
    with csv_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=[
            "elapsed_s", "elapsed_ms", "cpu", "freq_khz", "source", "action"
        ])
        writer.writeheader()
        writer.writerows(events)
    list_path.write_text(
        "frequency_events = " + repr(events) + "\n"
        + "frequency_intervals_by_cpu = " + repr(intervals_by_cpu) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
