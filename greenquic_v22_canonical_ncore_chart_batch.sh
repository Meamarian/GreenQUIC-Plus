#!/usr/bin/env bash
set -euo pipefail

# GreenQUIC V22 canonical CPU-wise chart batch
# Apply the same script on idex and tinyman.

SUITE="${GQ_SUITE_ROOT:-/root/mohsen/greenquic_test_suite_v22}"
CSTATE="$SUITE/common/bin/cstate_trace.py"
FREQ="$SUITE/common/bin/frequency_trace.py"

for required in "$CSTATE" "$FREQ"; do
    [[ -f "$required" ]] || {
        echo "ERROR: missing $required" >&2
        exit 1
    }
done

STAMP="$(date +%Y%m%d_%H%M%S)"
cp -a "$CSTATE" "${CSTATE}.before_canonical_cpu_charts_${STAMP}"
cp -a "$FREQ" "${FREQ}.before_canonical_cpu_charts_${STAMP}"

python3 - "$CSTATE" <<'PY'
from __future__ import annotations

import ast
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
tree = ast.parse(text)


def replace_function(source: str, tree: ast.Module, name: str, replacement: str) -> str:
    matches = [
        node
        for node in tree.body
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
        and node.name == name
    ]
    if len(matches) != 1:
        raise SystemExit(
            f"ERROR: expected one top-level function {name!r}, found {len(matches)}"
        )
    node = matches[0]
    lines = source.splitlines(keepends=True)
    start = node.lineno - 1
    end = node.end_lineno
    return (
        "".join(lines[:start])
        + replacement.rstrip()
        + "\n\n"
        + "".join(lines[end:])
    )


compact_function = r'''
def compact_intervals(
    cpu: int,
    intervals: list[IdleInterval],
    compact_size: int,
) -> list[CompactBlock]:
    """Deterministically compact completed intervals for exactly one CPU."""
    if compact_size < 1:
        raise ValueError("compact_size must be at least 1")

    ordered = sorted(
        (
            interval
            for interval in intervals
            if interval.cpu == cpu
        ),
        key=lambda interval: (
            interval.start_ns,
            interval.end_ns,
            interval.state,
            interval.end_event,
        ),
    )

    blocks: list[CompactBlock] = []

    for offset in range(0, len(ordered), compact_size):
        part = ordered[offset : offset + compact_size]
        if not part:
            continue

        duration_by_state: dict[int, int] = defaultdict(int)
        count_by_state: Counter = Counter()

        for interval in part:
            duration_by_state[interval.state] += interval.duration_ns
            count_by_state[interval.state] += 1

        blocks.append(
            CompactBlock(
                number=len(blocks) + 1,
                cpu=cpu,
                intervals=part,
                start_ns=min(interval.start_ns for interval in part),
                end_ns=max(interval.end_ns for interval in part),
                duration_by_state_ns=dict(duration_by_state),
                count_by_state=count_by_state,
                wakeups=sum(
                    interval.end_event == "wake"
                    for interval in part
                ),
            )
        )

    return blocks
'''


timeline_function = r'''
def timeline_plot(
    *,
    output: Path,
    role: str,
    intervals: list[IdleInterval],
    compact_size: int,
    width_px: int,
    height_px: int,
    max_x_ticks: int,
    annotate_every: int,
    max_annotations: int,
) -> dict:
    import hashlib
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.gridspec import GridSpec
    from matplotlib.patches import Patch
    from matplotlib.ticker import MaxNLocator

    del annotate_every, max_annotations

    cpus = sorted({interval.cpu for interval in intervals})
    states = sorted({interval.state for interval in intervals})
    colors = choose_colors(states)

    if not cpus:
        raise ValueError("timeline_plot received no CPU intervals")

    intervals_by_cpu: dict[int, list[IdleInterval]] = {
        cpu: sorted(
            (
                interval
                for interval in intervals
                if interval.cpu == cpu
            ),
            key=lambda interval: (
                interval.start_ns,
                interval.end_ns,
                interval.state,
                interval.end_event,
            ),
        )
        for cpu in cpus
    }

    blocks_by_cpu: dict[int, list[CompactBlock]] = {
        cpu: compact_intervals(
            cpu,
            intervals_by_cpu[cpu],
            compact_size,
        )
        for cpu in cpus
    }

    validation: dict[str, dict] = {}

    for cpu in cpus:
        raw = intervals_by_cpu[cpu]
        blocks = blocks_by_cpu[cpu]
        compacted = [
            interval
            for block in blocks
            for interval in block.intervals
        ]

        raw_state_counts = Counter(interval.state for interval in raw)
        compacted_state_counts = Counter(
            interval.state for interval in compacted
        )

        raw_state_duration_ns: dict[int, int] = defaultdict(int)
        compacted_state_duration_ns: dict[int, int] = defaultdict(int)

        for interval in raw:
            raw_state_duration_ns[interval.state] += interval.duration_ns
        for interval in compacted:
            compacted_state_duration_ns[interval.state] += interval.duration_ns

        raw_wakeups = sum(interval.end_event == "wake" for interval in raw)
        compacted_wakeups = sum(block.wakeups for block in blocks)

        fingerprint_input = "\n".join(
            (
                f"{interval.cpu},{interval.state},"
                f"{interval.start_ns},{interval.end_ns},"
                f"{interval.duration_ns},{interval.end_event}"
            )
            for interval in raw
        ).encode("utf-8")

        passed = (
            len(raw) == len(compacted)
            and raw_state_counts == compacted_state_counts
            and dict(raw_state_duration_ns) == dict(compacted_state_duration_ns)
            and raw_wakeups == compacted_wakeups
            and all(
                len(block.intervals) == compact_size
                for block in blocks[:-1]
            )
            and all(
                interval.cpu == cpu
                for block in blocks
                for interval in block.intervals
            )
        )

        validation[str(cpu)] = {
            "passed": passed,
            "raw_interval_count": len(raw),
            "compacted_interval_count": len(compacted),
            "compact_block_count": len(blocks),
            "full_block_size": compact_size,
            "last_block_size": len(blocks[-1].intervals) if blocks else 0,
            "raw_wakeups": raw_wakeups,
            "compacted_wakeups": compacted_wakeups,
            "raw_state_counts": {
                str(state): raw_state_counts[state]
                for state in sorted(raw_state_counts)
            },
            "compacted_state_counts": {
                str(state): compacted_state_counts[state]
                for state in sorted(compacted_state_counts)
            },
            "raw_state_duration_ns": {
                str(state): raw_state_duration_ns[state]
                for state in sorted(raw_state_duration_ns)
            },
            "compacted_state_duration_ns": {
                str(state): compacted_state_duration_ns[state]
                for state in sorted(compacted_state_duration_ns)
            },
            "raw_interval_fingerprint_sha256": (
                hashlib.sha256(fingerprint_input).hexdigest()
            ),
        }

        if not passed:
            raise RuntimeError(
                f"CPU {cpu} C-state compaction validation failed"
            )

    dpi = 100
    timeline_width_px = max(1800, width_px)
    mapping_width_px = env_int(
        ["CSTATE_MAPPING_WIDTH_PX"],
        default=5200,
        minimum=1400,
    )
    one_cm_gap_px = max(1, round(dpi / 2.54))
    cpu_panel_height_px = max(1100, height_px)
    total_height_px = cpu_panel_height_px * len(cpus)
    total_width_px = timeline_width_px + one_cm_gap_px + mapping_width_px

    figure = plt.figure(
        figsize=(total_width_px / dpi, total_height_px / dpi),
        dpi=dpi,
    )
    grid = GridSpec(
        nrows=len(cpus) * 2,
        ncols=3,
        figure=figure,
        width_ratios=[
            timeline_width_px,
            one_cm_gap_px,
            mapping_width_px,
        ],
        wspace=0.0,
        hspace=0.30,
    )

    idle_axes = []
    wake_axes = []
    mapping_axes = []

    for cpu_index in range(len(cpus)):
        idle_axes.append(figure.add_subplot(grid[cpu_index * 2, 0]))
        wake_axes.append(figure.add_subplot(grid[cpu_index * 2 + 1, 0]))
        gap_axis = figure.add_subplot(
            grid[cpu_index * 2 : cpu_index * 2 + 2, 1]
        )
        gap_axis.axis("off")
        mapping_axes.append(
            figure.add_subplot(
                grid[cpu_index * 2 : cpu_index * 2 + 2, 2]
            )
        )

    trace_end_ms = max(interval.end_ns for interval in intervals) / 1_000_000.0
    trace_span_ms = max(trace_end_ms, 0.001)
    min_visible_width_ms = max(
        trace_span_ms * 2.0 / timeline_width_px,
        0.000_001,
    )

    compact_metadata: dict[str, list[dict]] = {}

    for cpu_index, cpu in enumerate(cpus):
        idle_axis = idle_axes[cpu_index]
        wake_axis = wake_axes[cpu_index]
        mapping_axis = mapping_axes[cpu_index]
        blocks = blocks_by_cpu[cpu]
        compact_metadata[str(cpu)] = []

        maximum_idle_ms = max(
            (block.total_idle_ns / 1_000_000.0 for block in blocks),
            default=0.0,
        )
        maximum_wakeups = max(
            (block.wakeups for block in blocks),
            default=0,
        )
        label_padding_ms = max(maximum_idle_ms * 0.025, 0.001)
        mapping_lines: list[str] = []

        for block in blocks:
            start_ms = block.start_ns / 1_000_000.0
            end_ms = block.end_ns / 1_000_000.0
            span_ms = max(end_ms - start_ms, min_visible_width_ms)
            center_ms = (start_ms + end_ms) / 2.0
            bar_width = max(span_ms * 0.78, min_visible_width_ms)

            bottom_ms = 0.0
            for state in states:
                duration_ms = (
                    block.duration_by_state_ns.get(state, 0)
                    / 1_000_000.0
                )
                if duration_ms <= 0.0:
                    continue
                idle_axis.bar(
                    center_ms,
                    duration_ms,
                    width=bar_width,
                    bottom=bottom_ms,
                    color=colors[state],
                    edgecolor="black",
                    linewidth=0.45,
                    align="center",
                    zorder=3,
                )
                bottom_ms += duration_ms

            idle_axis.text(
                center_ms,
                bottom_ms + label_padding_ms,
                str(block.number),
                ha="center",
                va="bottom",
                fontsize=10,
                fontweight="bold",
                color="#111111",
                bbox={
                    "boxstyle": "round,pad=0.18",
                    "facecolor": "white",
                    "edgecolor": "#333333",
                    "alpha": 0.96,
                },
                clip_on=False,
                zorder=11,
            )

            wake_axis.bar(
                center_ms,
                block.wakeups,
                width=bar_width,
                color="#111111",
                edgecolor="black",
                linewidth=0.45,
                align="center",
                zorder=4,
            )

            state_parts = [
                (
                    f"{state_title(cpu, state)} "
                    f"{block.count_by_state[state]}×/"
                    f"{block.duration_by_state_ns[state] / 1_000_000.0:.3f}ms"
                )
                for state in sorted(block.count_by_state)
            ]
            mapping_lines.append(
                (
                    f"{block.number}. N={len(block.intervals)} | "
                    + ", ".join(state_parts)
                    + (
                        f" | W={block.wakeups}"
                        f" | idle={block.total_idle_ns / 1_000_000.0:.3f}ms"
                        f" | span={(block.end_ns - block.start_ns) / 1_000_000.0:.3f}ms"
                    )
                )
            )

            compact_metadata[str(cpu)].append(
                {
                    "block": block.number,
                    "intervals": len(block.intervals),
                    "start_ms": start_ms,
                    "end_ms": end_ms,
                    "wakeups": block.wakeups,
                    "idle_total_ms": block.total_idle_ns / 1_000_000.0,
                    "state_interval_counts": {
                        str(state): block.count_by_state[state]
                        for state in sorted(block.count_by_state)
                    },
                    "state_duration_ms": {
                        str(state): (
                            block.duration_by_state_ns[state] / 1_000_000.0
                        )
                        for state in sorted(block.duration_by_state_ns)
                    },
                }
            )

        idle_axis.set_ylim(
            0.0,
            maximum_idle_ms + label_padding_ms * 8.0
            if maximum_idle_ms > 0.0
            else 1.0,
        )
        wake_axis.set_ylim(
            0.0,
            max(1.0, maximum_wakeups * 1.20),
        )

        idle_axis.set_ylabel("C-state residency\n(ms/block)", fontsize=13)
        wake_axis.set_ylabel("Wakeups\n(count/block)", fontsize=13)
        idle_axis.set_title(
            (
                f"CPU {cpu} — lane 1: C-state residency; "
                f"lane 2: wakeups — CSTATE_COMPACT={compact_size}"
            ),
            fontsize=16,
        )

        for axis in (idle_axis, wake_axis):
            axis.set_xlim(
                -trace_span_ms * 0.005,
                trace_end_ms + trace_span_ms * 0.005,
            )
            axis.xaxis.set_major_locator(
                MaxNLocator(nbins=max_x_ticks, min_n_ticks=4)
            )
            axis.grid(
                True,
                axis="y",
                linestyle="--",
                linewidth=0.7,
                alpha=0.35,
                zorder=0,
            )
            axis.tick_params(axis="both", labelsize=11)

        idle_axis.tick_params(axis="x", labelbottom=False)
        wake_axis.set_xlabel("Kernel cpu_idle trace time (ms)", fontsize=13)

        mapping_axis.axis("off")
        mapping_axis.text(
            0.0,
            1.0,
            (
                f"CPU {cpu} compact mapping\n"
                "Number → N intervals, state count/duration, wakeups, idle total, span"
            ),
            transform=mapping_axis.transAxes,
            ha="left",
            va="top",
            fontsize=13,
            fontweight="bold",
        )
        mapping_axis.text(
            0.0,
            0.94,
            "\n".join(mapping_lines) if mapping_lines else "No compact blocks.",
            transform=mapping_axis.transAxes,
            ha="left",
            va="top",
            fontsize=9,
            family="monospace",
            linespacing=1.30,
            wrap=True,
        )

    legend_handles = [
        Patch(
            facecolor=colors[state],
            edgecolor="black",
            label=f"State {state}",
        )
        for state in states
    ]
    legend_handles.append(
        Patch(
            facecolor="#111111",
            edgecolor="black",
            label="Wakeups in lane 2",
        )
    )

    figure.legend(
        handles=legend_handles,
        loc="upper center",
        ncol=max(2, min(6, len(legend_handles))),
        fontsize=10,
        frameon=True,
        bbox_to_anchor=(0.5, 0.995),
    )
    figure.suptitle(
        (
            f"GreenQUIC {role} CPU-wise C-state chart — "
            f"2 lanes per CPU — deterministic per-CPU compaction"
        ),
        fontsize=18,
        y=0.999,
    )
    figure.subplots_adjust(
        left=0.045,
        right=0.995,
        bottom=0.045,
        top=0.955,
    )

    ensure_parent(output)
    figure.savefig(output, format="svg")
    plt.close(figure)

    print(
        "[GreenQUIC-Test] C-state compaction validation PASS: "
        + ", ".join(
            (
                f"CPU {cpu}: "
                f"{validation[str(cpu)]['raw_interval_count']} intervals, "
                f"{validation[str(cpu)]['compact_block_count']} blocks"
            )
            for cpu in cpus
        )
    )

    return {
        "kind": "cpuwise_cstate_dual_lane_v2",
        "role": role,
        "cpus": cpus,
        "states": states,
        "compact_scope": "per_cpu",
        "compact_size_intervals_per_cpu": compact_size,
        "lanes_per_cpu": 2,
        "lane_1": "stacked_state_residency_ms_per_block",
        "lane_2": "wakeups_per_block",
        "mapping_gap_cm": 1.0,
        "compaction_validation": validation,
        "compact_blocks_by_cpu": compact_metadata,
    }
'''

text = replace_function(text, tree, "compact_intervals", compact_function)
tree = ast.parse(text)
text = replace_function(text, tree, "timeline_plot", timeline_function)
ast.parse(text)
path.write_text(text, encoding="utf-8")
print("Patched:", path)
PY

cat > "$FREQ" <<'PY'
#!/usr/bin/env python3
"""GreenQUIC CPU-frequency interval bars, one lane per CPU."""

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
        if (
            last_frequency_by_cpu.get(cpu) == frequency
            and event["source"] == "periodic_stats"
        ):
            continue
        result.append(event)
        last_frequency_by_cpu[cpu] = frequency
    return result


def build_intervals(
    events: list[dict[str, Any]],
    duration_ms: float,
) -> dict[int, list[dict[str, Any]]]:
    events_by_cpu: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for event in events:
        events_by_cpu[int(event["cpu"])].append(event)

    intervals_by_cpu: dict[int, list[dict[str, Any]]] = {}
    for cpu in sorted(events_by_cpu):
        cpu_events = sorted(
            events_by_cpu[cpu],
            key=lambda event: float(event["elapsed_ms"]),
        )
        intervals: list[dict[str, Any]] = []
        for index, event in enumerate(cpu_events):
            start_ms = float(event["elapsed_ms"])
            end_ms = (
                float(cpu_events[index + 1]["elapsed_ms"])
                if index + 1 < len(cpu_events)
                else float(duration_ms)
            )
            if end_ms <= start_ms:
                continue
            intervals.append({
                "cpu": cpu,
                "start_ms": start_ms,
                "end_ms": end_ms,
                "duration_ms": end_ms - start_ms,
                "freq_khz": int(event["freq_khz"]),
                "freq_ghz": int(event["freq_khz"]) / 1_000_000.0,
                "source": event["source"],
                "action": event.get("action"),
            })
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


def write_bar_svg(
    path: Path,
    *,
    role: str,
    intervals_by_cpu: dict[int, list[dict[str, Any]]],
    duration_ms: float,
) -> dict[str, Any]:
    cpus = sorted(intervals_by_cpu)
    width = env_int(
        "GQ_FREQ_PLOT_WIDTH_PX",
        env_int("GQ_PLOT_WIDTH_PX", 24000, 1200, 500000),
        1200,
        500000,
    )
    lane_height = env_int("GQ_FREQ_LANE_HEIGHT_PX", 430, 220, 1500)
    max_ticks = env_int("GQ_FREQ_MAX_X_TICKS", 24, 4, 200)
    max_labels = env_int("GQ_FREQ_MAX_BAR_LABELS", 80, 0, 10000)
    requested_tick_ms = env_int("GQ_FREQ_PLOT_X_LABEL_MS", 100, 1, 600000)

    left, right, top, bottom = 125, 55, 100, 95
    height = top + bottom + lane_height * max(1, len(cpus))
    plot_width = width - left - right
    max_x_ms = max(float(duration_ms), 1.0)
    maximum_ghz = max(
        (
            float(interval["freq_ghz"])
            for intervals in intervals_by_cpu.values()
            for interval in intervals
        ),
        default=1.0,
    )
    y_max = max(1.0, math.ceil(maximum_ghz * 10.0) / 10.0) * 1.08
    tick_step_ms = nice_step(max_x_ms, requested_tick_ms, max_ticks)
    total_bars = sum(len(intervals) for intervals in intervals_by_cpu.values())
    label_stride = (
        max(1, math.ceil(total_bars / max_labels))
        if max_labels > 0
        else total_bars + 1
    )
    palette = ["#4E79A7", "#F28E2B", "#59A14F", "#E15759", "#B07AA1", "#76B7B2"]

    def x_position(value_ms: float) -> float:
        return left + min(max(value_ms, 0.0), max_x_ms) / max_x_ms * plot_width

    output = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        '<rect width="100%" height="100%" fill="white"/>',
        f'<text x="{width / 2:.1f}" y="34" text-anchor="middle" font-family="sans-serif" font-size="24">{html.escape(f"GreenQUIC {role} CPU-frequency residency bars")}</text>',
        f'<text x="{width / 2:.1f}" y="61" text-anchor="middle" font-family="sans-serif" font-size="15">One lane per CPU; height = GHz; width = duration</text>',
    ]

    plot_bottom = top + lane_height * max(1, len(cpus))
    tick = 0.0
    while tick <= max_x_ms + tick_step_ms * 0.001:
        x = x_position(tick)
        output.append(f'<line x1="{x:.2f}" y1="{top}" x2="{x:.2f}" y2="{plot_bottom}" stroke="#dedede" stroke-width="1"/>')
        output.append(f'<text x="{x:.2f}" y="{plot_bottom + 32}" text-anchor="middle" font-family="monospace" font-size="13">{tick:g}</text>')
        tick += tick_step_ms

    bar_counter = 0
    for lane_index, cpu in enumerate(cpus):
        lane_top = top + lane_index * lane_height
        lane_bottom = lane_top + lane_height - 55
        usable_height = lane_height - 95
        color = palette[lane_index % len(palette)]
        output.append(f'<rect x="{left}" y="{lane_top}" width="{plot_width}" height="{lane_height - 35}" fill="#fafafa" stroke="#aaaaaa"/>')
        output.append(f'<text x="{left - 16}" y="{lane_top + 24}" text-anchor="end" font-family="sans-serif" font-size="16" font-weight="bold">CPU {cpu}</text>')

        for y_index in range(6):
            value = y_max * y_index / 5.0
            y = lane_bottom - value / y_max * usable_height
            output.append(f'<line x1="{left}" y1="{y:.2f}" x2="{width - right}" y2="{y:.2f}" stroke="#e6e6e6"/>')
            output.append(f'<text x="{left - 12}" y="{y + 5:.2f}" text-anchor="end" font-family="monospace" font-size="13">{value:.2f}</text>')

        for interval in intervals_by_cpu[cpu]:
            x0 = x_position(float(interval["start_ms"]))
            x1 = x_position(float(interval["end_ms"]))
            bar_width = max(1.0, x1 - x0)
            frequency_ghz = float(interval["freq_ghz"])
            bar_height = frequency_ghz / y_max * usable_height
            y = lane_bottom - bar_height
            output.append(f'<rect x="{x0:.2f}" y="{y:.2f}" width="{bar_width:.2f}" height="{bar_height:.2f}" fill="{color}" stroke="black" stroke-width="0.6"/>')

            if max_labels > 0 and bar_counter % label_stride == 0 and bar_width >= 30.0:
                label = f"{frequency_ghz:.3f} GHz"
                if interval.get("action"):
                    label += f" | {interval['action']}"
                output.append(f'<text x="{x0 + bar_width / 2:.2f}" y="{max(lane_top + 18, y - 7):.2f}" text-anchor="middle" font-family="sans-serif" font-size="11">{html.escape(label)}</text>')
            bar_counter += 1

        output.append(f'<line x1="{left}" y1="{lane_bottom}" x2="{width - right}" y2="{lane_bottom}" stroke="black" stroke-width="2"/>')

    output.extend([
        f'<text x="{width / 2:.1f}" y="{height - 23}" text-anchor="middle" font-family="sans-serif" font-size="17">Elapsed time [ms] — tick {tick_step_ms:g} ms</text>',
        f'<text x="27" y="{height / 2:.1f}" text-anchor="middle" font-family="sans-serif" font-size="17" transform="rotate(-90 27 {height / 2:.1f})">Frequency [GHz]</text>',
        '</svg>',
    ])

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(output) + "\n", encoding="utf-8")
    return {
        "kind": "cpuwise_frequency_interval_bars",
        "width_px": width,
        "height_px": height,
        "x_tick_ms": tick_step_ms,
        "x_label_ms": tick_step_ms,
        "lanes": len(cpus),
        "cpus": cpus,
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
        "schema": "greenquic-frequency-trace-v3",
        "role": args.role,
        "timeline_duration_s": duration_s,
        "event_count_raw": len(raw_events),
        "event_count": len(events),
        "cpus": cpus,
        "min_freq_khz": min(frequencies) if frequencies else None,
        "max_freq_khz": max(frequencies) if frequencies else None,
        "events": events,
        "frequency_intervals_by_cpu": {
            str(cpu): intervals
            for cpu, intervals in intervals_by_cpu.items()
        },
        "plot": plot,
        "measurement_note": (
            "Each CPU has its own lane. Each bar is one deduplicated "
            "frequency-residency interval; height is GHz and width is duration. "
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
PY

chmod +x "$CSTATE" "$FREQ"
python3 -m py_compile "$CSTATE" "$FREQ"

echo
echo "PASS: canonical CPU-wise chart batch installed."
echo
echo "C-state:"
echo "  - deterministic compaction per CPU"
echo "  - CSTATE_COMPACT=N means N intervals from that CPU"
echo "  - 2 lanes per CPU"
echo "  - one number above the upper bar only"
echo "  - 1 cm gap, then concise per-CPU mapping"
echo "  - count/duration/wakeup validation must pass"
echo
echo "Frequency:"
echo "  - 1 bar-chart lane per CPU"
echo "  - height = GHz"
echo "  - width = frequency residency duration"
echo
echo "No MsQuic rebuild is required."
