#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import hashlib
import html
import json
import math
import os
import statistics
import textwrap
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

TRUE_VALUES = {"1", "true", "yes", "on"}


def env_enabled(name: str, default: str = "0") -> bool:
    return os.environ.get(name, default).strip().lower() in TRUE_VALUES


def env_int(names: Iterable[str], default: int, minimum: int | None = None) -> int:
    value = None
    for name in names:
        raw = os.environ.get(name)
        if raw is not None and raw.strip() != "":
            value = raw.strip()
            break
    try:
        result = default if value is None else int(value)
    except ValueError:
        result = default
    return max(minimum, result) if minimum is not None else result


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def write_placeholder_svg(path: Path, title: str, message: str) -> None:
    ensure_parent(path)
    path.write_text(
        "\n".join([
            '<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="400" viewBox="0 0 1600 400">',
            '<rect width="1600" height="400" fill="white"/>',
            f'<text x="50" y="100" font-family="sans-serif" font-size="34">{html.escape(title)}</text>',
            f'<text x="50" y="175" font-family="sans-serif" font-size="25">{html.escape(message)}</text>',
            '</svg>',
        ]) + "\n",
        encoding="utf-8",
    )


def read_summary(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def write_summary(path: Path, summary: dict) -> None:
    ensure_parent(path)
    path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")


@dataclass(frozen=True)
class TraceRow:
    timestamp_ns: int
    relative_ns: int
    cpu: int
    state: int
    event: str
    previous_state: int
    idle_duration_ns: int


@dataclass(frozen=True)
class IdleInterval:
    cpu: int
    state: int
    start_ns: int
    end_ns: int
    duration_ns: int
    end_event: str


@dataclass
class CompactBlock:
    number: int
    cpu: int
    intervals: list[IdleInterval]
    start_ns: int
    end_ns: int
    duration_by_state_ns: dict[int, int]
    count_by_state: Counter
    wakeups: int

    @property
    def total_idle_ns(self) -> int:
        return sum(self.duration_by_state_ns.values())

    @property
    def covered_ns(self) -> int:
        return max(0, self.end_ns - self.start_ns)


def load_rows(path: Path) -> list[TraceRow]:
    rows: list[TraceRow] = []
    with path.open(newline="", encoding="utf-8", errors="replace") as handle:
        for raw in csv.DictReader(handle):
            try:
                rows.append(TraceRow(
                    timestamp_ns=int(raw["timestamp_mono_raw_ns"]),
                    relative_ns=int(raw["relative_ns"]),
                    cpu=int(raw["cpu"]),
                    state=int(raw["state"]),
                    event=str(raw["event"]).strip().lower(),
                    previous_state=int(raw["previous_state"]),
                    idle_duration_ns=int(raw["idle_duration_ns"]),
                ))
            except (KeyError, TypeError, ValueError):
                continue
    return rows


def completed_intervals(rows: list[TraceRow]) -> list[IdleInterval]:
    intervals: list[IdleInterval] = []
    for row in rows:
        if row.event not in {"wake", "reenter"}:
            continue
        if row.previous_state < 0 or row.idle_duration_ns <= 0:
            continue
        intervals.append(IdleInterval(
            cpu=row.cpu,
            state=row.previous_state,
            start_ns=max(0, row.relative_ns - row.idle_duration_ns),
            end_ns=row.relative_ns,
            duration_ns=row.idle_duration_ns,
            end_event=row.event,
        ))
    intervals.sort(key=lambda item: (item.cpu, item.start_ns, item.end_ns, item.state))
    return intervals


def cpuidle_name(cpu: int, state: int) -> str:
    path = Path(f"/sys/devices/system/cpu/cpu{cpu}/cpuidle/state{state}/name")
    try:
        name = path.read_text(encoding="utf-8").strip()
    except OSError:
        name = ""
    return name or f"state{state}"


def state_title(cpu: int, state: int) -> str:
    return f"S{state} — {cpuidle_name(cpu, state)}"


def compact_intervals(cpu: int, intervals: list[IdleInterval], compact_size: int) -> list[CompactBlock]:
    if compact_size < 1:
        raise ValueError("compact_size must be at least 1")
    ordered = sorted(
        (item for item in intervals if item.cpu == cpu),
        key=lambda item: (item.start_ns, item.end_ns, item.state, item.end_event),
    )
    blocks: list[CompactBlock] = []
    for offset in range(0, len(ordered), compact_size):
        part = ordered[offset:offset + compact_size]
        if not part:
            continue
        duration_by_state_ns: dict[int, int] = defaultdict(int)
        count_by_state: Counter = Counter()
        for item in part:
            duration_by_state_ns[item.state] += item.duration_ns
            count_by_state[item.state] += 1
        blocks.append(CompactBlock(
            number=len(blocks) + 1,
            cpu=cpu,
            intervals=part,
            start_ns=min(item.start_ns for item in part),
            end_ns=max(item.end_ns for item in part),
            duration_by_state_ns=dict(duration_by_state_ns),
            count_by_state=count_by_state,
            wakeups=sum(item.end_event == "wake" for item in part),
        ))
    return blocks


def choose_colors(states: list[int]) -> dict[int, str]:
    fixed = [
        "#4E79A7", "#F28E2B", "#E15759", "#76B7B2", "#59A14F",
        "#EDC948", "#B07AA1", "#FF9DA7", "#9C755F", "#BAB0AC",
    ]
    return {state: fixed[index % len(fixed)] for index, state in enumerate(states)}


def dominant_state(block: CompactBlock) -> int:
    return max(
        block.duration_by_state_ns,
        key=lambda state: (
            block.duration_by_state_ns[state],
            block.count_by_state[state],
            -state,
        ),
    )


def validate_compaction(
    cpus: list[int],
    intervals_by_cpu: dict[int, list[IdleInterval]],
    blocks_by_cpu: dict[int, list[CompactBlock]],
    compact_size: int,
) -> dict[str, dict]:
    validation: dict[str, dict] = {}
    for cpu in cpus:
        raw = intervals_by_cpu[cpu]
        blocks = blocks_by_cpu[cpu]
        compacted = [item for block in blocks for item in block.intervals]
        raw_counts = Counter(item.state for item in raw)
        compacted_counts = Counter(item.state for item in compacted)
        raw_duration: dict[int, int] = defaultdict(int)
        compacted_duration: dict[int, int] = defaultdict(int)
        for item in raw:
            raw_duration[item.state] += item.duration_ns
        for item in compacted:
            compacted_duration[item.state] += item.duration_ns
        raw_wakeups = sum(item.end_event == "wake" for item in raw)
        compacted_wakeups = sum(block.wakeups for block in blocks)
        fingerprint = hashlib.sha256("\n".join(
            f"{item.cpu},{item.state},{item.start_ns},{item.end_ns},{item.duration_ns},{item.end_event}"
            for item in raw
        ).encode("utf-8")).hexdigest()
        passed = (
            len(raw) == len(compacted)
            and raw_counts == compacted_counts
            and dict(raw_duration) == dict(compacted_duration)
            and raw_wakeups == compacted_wakeups
            and all(len(block.intervals) == compact_size for block in blocks[:-1])
            and all(item.cpu == cpu for block in blocks for item in block.intervals)
        )
        row = {
            "passed": passed,
            "raw_interval_count": len(raw),
            "compacted_interval_count": len(compacted),
            "compact_block_count": len(blocks),
            "full_block_size": compact_size,
            "last_block_size": len(blocks[-1].intervals) if blocks else 0,
            "raw_wakeups": raw_wakeups,
            "compacted_wakeups": compacted_wakeups,
            "raw_state_counts": {str(k): raw_counts[k] for k in sorted(raw_counts)},
            "compacted_state_counts": {str(k): compacted_counts[k] for k in sorted(compacted_counts)},
            "raw_state_duration_ns": {str(k): raw_duration[k] for k in sorted(raw_duration)},
            "compacted_state_duration_ns": {str(k): compacted_duration[k] for k in sorted(compacted_duration)},
            "raw_interval_fingerprint_sha256": fingerprint,
        }
        validation[str(cpu)] = row
        if not passed:
            raise RuntimeError(f"CPU {cpu} C-state compaction validation failed")
    return validation


def mapping_lines_for_cpu(cpu: int, blocks: list[CompactBlock]) -> list[str]:
    lines: list[str] = []
    for block in blocks:
        dominant = dominant_state(block)
        state_parts = [
            f"{state_title(cpu, state)} {block.count_by_state[state]}×/{block.duration_by_state_ns[state] / 1_000_000.0:.3f}ms"
            for state in sorted(block.count_by_state)
        ]
        start_s = block.start_ns / 1_000_000_000.0
        end_s = block.end_ns / 1_000_000_000.0
        covered_ms = block.covered_ns / 1_000_000.0
        lines.append(
            f"{block.number}. t≈{start_s:.3f}–{end_s:.3f}s | N={len(block.intervals)} | "
            f"dom={state_title(cpu, dominant)} | "
            + ", ".join(state_parts)
            + f" | W={block.wakeups} | idle={block.total_idle_ns / 1_000_000.0:.3f}ms | covered={covered_ms:.3f}ms"
        )
    return lines


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
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.gridspec import GridSpec
    from matplotlib.patches import Patch
    from matplotlib.ticker import MaxNLocator

    del annotate_every, max_annotations

    cpus = sorted({item.cpu for item in intervals})
    states = sorted({item.state for item in intervals})
    if not cpus:
        raise ValueError("timeline_plot received no completed intervals")

    colors = choose_colors(states)
    intervals_by_cpu = {
        cpu: sorted(
            (item for item in intervals if item.cpu == cpu),
            key=lambda item: (item.start_ns, item.end_ns, item.state, item.end_event),
        )
        for cpu in cpus
    }
    blocks_by_cpu = {
        cpu: compact_intervals(cpu, intervals_by_cpu[cpu], compact_size)
        for cpu in cpus
    }
    validation = validate_compaction(cpus, intervals_by_cpu, blocks_by_cpu, compact_size)

    dpi = 100
    timeline_width_px = max(1800, width_px)
    mapping_width_px = env_int(["CSTATE_MAPPING_WIDTH_PX"], 6200, 1600)
    gap_px = max(1, round(dpi / 2.54))
    lane_height_px = max(950, height_px)
    total_width_px = timeline_width_px + gap_px + mapping_width_px
    total_height_px = lane_height_px * len(cpus)

    figure = plt.figure(figsize=(total_width_px / dpi, total_height_px / dpi), dpi=dpi)
    grid = GridSpec(
        nrows=len(cpus),
        ncols=3,
        figure=figure,
        width_ratios=[timeline_width_px, gap_px, mapping_width_px],
        wspace=0.0,
        hspace=0.34,
    )

    trace_end_ms = max(item.end_ns for item in intervals) / 1_000_000.0
    trace_span_ms = max(trace_end_ms, 0.001)
    minimum_visible_width_ms = max(trace_span_ms * 2.0 / timeline_width_px, 0.000001)
    compact_metadata: dict[str, list[dict]] = {}

    for cpu_index, cpu in enumerate(cpus):
        axis = figure.add_subplot(grid[cpu_index, 0])
        gap_axis = figure.add_subplot(grid[cpu_index, 1])
        mapping_axis = figure.add_subplot(grid[cpu_index, 2])
        gap_axis.axis("off")
        mapping_axis.axis("off")

        blocks = blocks_by_cpu[cpu]
        compact_metadata[str(cpu)] = []
        max_idle_ms = max((block.total_idle_ns / 1_000_000.0 for block in blocks), default=0.0)
        label_padding_ms = max(max_idle_ms * 0.025, 0.001)

        for block in blocks:
            start_ms = block.start_ns / 1_000_000.0
            end_ms = block.end_ns / 1_000_000.0
            center_ms = (start_ms + end_ms) / 2.0
            covered_ms = max(end_ms - start_ms, minimum_visible_width_ms)
            bar_width = max(covered_ms * 0.78, minimum_visible_width_ms)
            total_idle_ms = block.total_idle_ns / 1_000_000.0
            dominant = dominant_state(block)

            axis.bar(
                center_ms,
                total_idle_ms,
                width=bar_width,
                color=colors[dominant],
                edgecolor="black",
                linewidth=0.55,
                align="center",
                zorder=3,
            )
            axis.text(
                center_ms,
                total_idle_ms + label_padding_ms,
                str(block.number),
                ha="center",
                va="bottom",
                fontsize=10,
                fontweight="bold",
                bbox={
                    "boxstyle": "round,pad=0.18",
                    "facecolor": "white",
                    "edgecolor": colors[dominant],
                    "alpha": 0.97,
                },
                clip_on=False,
                zorder=10,
            )
            compact_metadata[str(cpu)].append({
                "block": block.number,
                "intervals": len(block.intervals),
                "start_ms": start_ms,
                "end_ms": end_ms,
                "covered_ms": block.covered_ns / 1_000_000.0,
                "idle_total_ms": total_idle_ms,
                "wakeups": block.wakeups,
                "dominant_state": dominant,
                "dominant_state_name": state_title(cpu, dominant),
                "state_interval_counts": {str(s): block.count_by_state[s] for s in sorted(block.count_by_state)},
                "state_duration_ms": {str(s): block.duration_by_state_ns[s] / 1_000_000.0 for s in sorted(block.duration_by_state_ns)},
            })

        axis.set_ylim(0.0, max(1.0, max_idle_ms + label_padding_ms * 8.0))
        axis.set_xlim(-trace_span_ms * 0.005, trace_end_ms + trace_span_ms * 0.005)
        axis.xaxis.set_major_locator(MaxNLocator(nbins=max_x_ticks, min_n_ticks=4))
        axis.grid(True, axis="y", linestyle="--", linewidth=0.7, alpha=0.35, zorder=0)
        axis.tick_params(axis="both", labelsize=11)
        axis.set_ylabel("Idle residency\n(ms/compact block)", fontsize=13)
        axis.set_xlabel("Kernel cpu_idle trace time (ms)", fontsize=13)
        axis.set_title(
            f"CPU {cpu} — one C-state lane — color = dominant state by residency — CSTATE_COMPACT={compact_size}",
            fontsize=15,
        )

        mapping_axis.text(
            0.0,
            1.0,
            f"CPU {cpu} compact mapping\n"
            "t≈ = approximate trace start/end; covered = first included idle-entry to last included idle-exit; "
            "idle = sum of C-state residency inside that covered window.",
            transform=mapping_axis.transAxes,
            ha="left",
            va="top",
            fontsize=12,
            fontweight="bold",
        )
        raw_lines = mapping_lines_for_cpu(cpu, blocks)
        rendered_lines: list[str] = []
        for line in raw_lines:
            rendered_lines.extend(textwrap.wrap(line, width=165, subsequent_indent="    ") or [line])
        font_size = max(6.0, min(9.5, 760.0 / max(1, len(rendered_lines))))
        mapping_axis.text(
            0.0,
            0.90,
            "\n".join(rendered_lines) if rendered_lines else "No compact blocks.",
            transform=mapping_axis.transAxes,
            ha="left",
            va="top",
            fontsize=font_size,
            family="monospace",
            linespacing=1.22,
        )

    legend_handles = [
        Patch(facecolor=colors[state], edgecolor="black", label=state_title(cpus[0], state))
        for state in states
    ]
    figure.legend(
        handles=legend_handles,
        loc="upper center",
        ncol=max(1, min(6, len(legend_handles))),
        fontsize=10,
        frameon=True,
        bbox_to_anchor=(0.5, 0.992),
        title="Compact-bar color = state with greatest residency in that block",
        title_fontsize=10,
    )
    figure.suptitle(
        f"GreenQUIC {role} CPU-wise C-state timeline — one lane per traced CPU",
        fontsize=18,
        y=0.999,
    )
    figure.subplots_adjust(left=0.035, right=0.995, top=0.945, bottom=0.075, wspace=0.0, hspace=0.34)
    ensure_parent(output)
    figure.savefig(output, format="svg")
    plt.close(figure)

    print("[GreenQUIC-Test] C-state compaction validation PASS: " + ", ".join(
        f"CPU {cpu}: {validation[str(cpu)]['raw_interval_count']} intervals, {validation[str(cpu)]['compact_block_count']} blocks"
        for cpu in cpus
    ))

    return {
        "kind": "cpuwise_cstate_single_lane_dominant_color_v5",
        "role": role,
        "cpus": cpus,
        "states": states,
        "compact_scope": "per_cpu",
        "compact_size_intervals_per_cpu": compact_size,
        "lanes_per_cpu": 1,
        "bar_height": "total idle residency in compact block",
        "bar_width": "covered trace time from first included idle entry to last included idle exit",
        "bar_color": "state with greatest residency duration in compact block",
        "wakeups_display": "mapping_only",
        "mapping_gap_cm": 1.0,
        "compaction_validation": validation,
        "compact_blocks_by_cpu": compact_metadata,
    }


def histogram_plot(
    *,
    output: Path,
    role: str,
    rows: list[TraceRow],
    intervals: list[IdleInterval],
    width_px: int,
) -> dict:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    state_counts = Counter(item.state for item in intervals)
    state_duration_ns: dict[int, int] = defaultdict(int)
    for item in intervals:
        state_duration_ns[item.state] += item.duration_ns

    cpus = sorted({item.cpu for item in intervals})
    representative_cpu = cpus[0]
    states = sorted(state_counts)
    colors = choose_colors(states)
    event_counts = Counter(row.event for row in rows)
    wakeups = event_counts["wake"]
    idle_entries = event_counts["enter"] + event_counts["reenter"]
    state_switches = event_counts["reenter"]

    labels = [state_title(representative_cpu, state) for state in states] + [
        "Idle entry", "State switch / re-enter", "Wakeup / idle exit"
    ]
    counts = [state_counts[state] for state in states] + [idle_entries, state_switches, wakeups]
    bar_colors = [colors[state] for state in states] + ["#8CD17D", "#B6992D", "#111111"]

    dpi = 100
    figure_width = max(width_px / dpi, max(14.0, len(labels) * 2.2))
    fig, ax = plt.subplots(figsize=(figure_width, 11.0), dpi=dpi)
    positions = list(range(len(labels)))
    bars = ax.bar(positions, counts, color=bar_colors, edgecolor="black", linewidth=0.6)
    maximum_count = max(counts) if counts else 1
    padding = max(maximum_count * 0.015, 0.5)
    for index, bar in enumerate(bars):
        text = (
            f"{counts[index]}\n{state_duration_ns[states[index]] / 1_000_000.0:.3f} ms total"
            if index < len(states)
            else str(counts[index])
        )
        ax.text(bar.get_x() + bar.get_width() / 2.0, bar.get_height() + padding, text,
                ha="center", va="bottom", fontsize=11)
    ax.set_xticks(positions)
    ax.set_xticklabels(labels, rotation=35, ha="right", fontsize=12)
    ax.tick_params(axis="y", labelsize=12)
    ax.set_ylabel("Number of events / completed idle intervals", fontsize=14)
    ax.set_xlabel("C-state or cpu_idle event type", fontsize=14)
    ax.set_title(
        f"GreenQUIC C-state and wakeup event counts — role={role}\n"
        "State colors match the timeline legend; state labels also show total residency",
        fontsize=18,
    )
    ax.grid(True, axis="y", linestyle="--", linewidth=0.7, alpha=0.35)
    ax.set_ylim(0.0, maximum_count * 1.20 + 1.0)
    fig.subplots_adjust(left=0.05, right=0.995, top=0.90, bottom=0.22)
    ensure_parent(output)
    fig.savefig(output, format="svg")
    plt.close(fig)
    return {
        "state_interval_counts": {str(state): state_counts[state] for state in states},
        "state_total_idle_ms": {str(state): state_duration_ns[state] / 1_000_000.0 for state in states},
        "idle_entry_events": idle_entries,
        "state_switch_events": state_switches,
        "wakeup_idle_exit_events": wakeups,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--timeline-svg", type=Path, required=True)
    parser.add_argument("--histogram-svg", type=Path, required=True)
    parser.add_argument("--role", required=True)
    args = parser.parse_args()

    summary = read_summary(args.summary)
    if not env_enabled("ENABLE_CSTATE_RECORD", "0"):
        reason = "ENABLE_CSTATE_RECORD is disabled"
        print(f"[GreenQUIC-Test] Skipping C-state plots: {reason}.")
        summary.update({"cstate_plots_skipped": True, "reason": reason})
        write_summary(args.summary, summary)
        write_placeholder_svg(args.timeline_svg, "GreenQUIC C-state timeline skipped", reason)
        write_placeholder_svg(args.histogram_svg, "GreenQUIC C-state histogram skipped", reason)
        return 0
    if not args.csv.is_file():
        reason = f"C-state CSV is missing: {args.csv}"
        print(f"[GreenQUIC-Test] Skipping C-state plots: {reason}.")
        summary.update({"cstate_plots_skipped": True, "reason": reason})
        write_summary(args.summary, summary)
        write_placeholder_svg(args.timeline_svg, "GreenQUIC C-state timeline skipped", reason)
        write_placeholder_svg(args.histogram_svg, "GreenQUIC C-state histogram skipped", reason)
        return 0

    rows = load_rows(args.csv)
    intervals = completed_intervals(rows)
    if not rows or not intervals:
        reason = "no completed C-state idle intervals were recorded"
        print(f"[GreenQUIC-Test] Skipping C-state plots: {reason}.")
        summary.update({"cstate_plots_skipped": True, "reason": reason})
        write_summary(args.summary, summary)
        write_placeholder_svg(args.timeline_svg, "GreenQUIC C-state timeline skipped", reason)
        write_placeholder_svg(args.histogram_svg, "GreenQUIC C-state histogram skipped", reason)
        return 0

    compact_size = env_int(["CSTATE_COMPACT", "Cstate_compact"], 500, 1)
    width_px = env_int(["GQ_CSTATE_PLOT_WIDTH_PX", "CSTATE_PLOT_WIDTH_PX", "GQ_PLOT_WIDTH_PX"], 24000, 1600)
    height_px = env_int(["GQ_CSTATE_PLOT_HEIGHT_PX", "CSTATE_PLOT_HEIGHT_PX", "GQ_PLOT_HEIGHT_PX"], 3500, 900)
    max_x_ticks = env_int(["CSTATE_MAX_X_TICKS"], 24, 4)
    annotate_every = env_int(["CSTATE_ANNOTATE_EVERY"], 1, 1)
    max_annotations = env_int(["CSTATE_MAX_ANNOTATIONS"], 100, 1)

    timeline_summary = timeline_plot(
        output=args.timeline_svg,
        role=args.role,
        intervals=intervals,
        compact_size=compact_size,
        width_px=width_px,
        height_px=height_px,
        max_x_ticks=max_x_ticks,
        annotate_every=annotate_every,
        max_annotations=max_annotations,
    )
    histogram_summary = histogram_plot(
        output=args.histogram_svg,
        role=args.role,
        rows=rows,
        intervals=intervals,
        width_px=width_px,
    )

    state_names: dict[str, str] = {}
    for interval in intervals:
        state_names.setdefault(str(interval.state), state_title(interval.cpu, interval.state))
    durations_ms = [interval.duration_ns / 1_000_000.0 for interval in intervals]
    summary.update({
        "cstate_plots_skipped": False,
        "csv_rows": len(rows),
        "completed_idle_intervals": len(intervals),
        "traced_cpus": sorted({item.cpu for item in intervals}),
        "state_names": state_names,
        "idle_interval_duration_ms": {
            "minimum": min(durations_ms),
            "median": statistics.median(durations_ms),
            "mean": statistics.mean(durations_ms),
            "maximum": max(durations_ms),
        },
        **timeline_summary,
        **histogram_summary,
    })
    write_summary(args.summary, summary)
    print(
        "[GreenQUIC-Test] C-state bar charts generated: "
        f"intervals={len(intervals)} compact={compact_size} "
        f"cpus={','.join(str(cpu) for cpu in summary['traced_cpus'])}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
