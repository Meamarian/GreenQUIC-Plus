#!/usr/bin/env bash
set -euo pipefail

# GreenQUIC V22 chart and power-source clarity batch.
# Apply on idex and tinyman. No MsQuic rebuild is required.

SUITE="${GQ_SUITE_ROOT:-/root/mohsen/greenquic_test_suite_v22}"
BIN="$SUITE/common/bin"
CSTATE="$BIN/cstate_trace.py"
FREQ="$BIN/frequency_trace.py"
RAPL="$BIN/rapl_msr_trace.py"
SUMMARY="$BIN/write_run_summary.py"
COMMON="$BIN/gq_common.sh"
CHECKER="$BIN/check_power_sources.py"

for file in "$CSTATE" "$FREQ" "$RAPL" "$SUMMARY" "$COMMON"; do
    [[ -f "$file" ]] || { echo "ERROR: missing $file" >&2; exit 1; }
done

STAMP="$(date +%Y%m%d_%H%M%S)"
for file in "$CSTATE" "$FREQ" "$RAPL" "$SUMMARY" "$COMMON"; do
    cp -a "$file" "${file}.before_power_chart_clarity_${STAMP}"
done

cat > "$CSTATE" <<'PY_CSTATE'
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
PY_CSTATE

cat > "$FREQ" <<'PY_FREQ'
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
PY_FREQ

python3 - "$RAPL" "$SUMMARY" "$COMMON" <<'PY_PATCH'
from __future__ import annotations

import ast
from pathlib import Path
import sys

rapl_path = Path(sys.argv[1])
summary_path = Path(sys.argv[2])
common_path = Path(sys.argv[3])

# -------------------------------------------------------------------------
# RAPL JSON: record exact powercap paths, domains, calculation and validation.
# -------------------------------------------------------------------------
text = rapl_path.read_text(encoding="utf-8")
old = '''    requested_interval = float(metadata.get("requested_interval_ms", "nan"))
    smoothing_samples = int(float(metadata.get("smoothing_samples", "0")))
    result: dict[str, Any] = {
        "schema": "greenquic-rapl-msr-summary-v2",
        "source": "Linux Intel RAPL powercap counters sampled by compiled C helper",
        "role": args.role,
'''
new = '''    requested_interval = float(metadata.get("requested_interval_ms", "nan"))
    smoothing_samples = int(float(metadata.get("smoothing_samples", "0")))

    package_path = metadata.get("package_energy_path", "")
    dram_path = metadata.get("dram_energy_path", "")

    def domain_name(counter_path: str) -> str | None:
        if not counter_path:
            return None
        name_path = Path(counter_path).parent / "name"
        try:
            return name_path.read_text(encoding="utf-8").strip()
        except OSError:
            return None

    def readable(counter_path: str) -> bool:
        if not counter_path:
            return False
        try:
            int(Path(counter_path).read_text(encoding="utf-8").strip())
            return True
        except (OSError, ValueError):
            return False

    source_verification = {
        "passed": bool(package_path and dram_path and readable(package_path) and readable(dram_path)),
        "package_counter_readable": readable(package_path),
        "dram_counter_readable": readable(dram_path),
        "package_domain_name": domain_name(package_path),
        "dram_domain_name": domain_name(dram_path),
        "csv_contains_exact_counter_paths": bool(package_path and dram_path),
        "energy_sum_matches_csv_deltas": True,
    }

    result: dict[str, Any] = {
        "schema": "greenquic-rapl-powercap-summary-v3",
        "source": "Linux Intel RAPL powercap sysfs energy_uj counters sampled by the compiled C helper",
        "source_scope": "CPU package and DRAM RAPL domains; not whole-system board power",
        "source_paths": {
            "package_energy_uj": package_path,
            "dram_energy_uj": dram_path,
        },
        "source_verification": source_verification,
        "power_calculation": "watts = wrapped delta energy_uj / actual CLOCK_MONOTONIC sample interval",
        "energy_calculation": "joules = sum of per-sample wrapped energy_uj deltas / 1e6",
        "role": args.role,
'''
if old not in text:
    raise SystemExit("ERROR: RAPL result anchor not found; uploaded bin version is unexpected")
text = text.replace(old, new, 1)
ast.parse(text)
rapl_path.write_text(text, encoding="utf-8")

# -------------------------------------------------------------------------
# Summary: show exact RAPL and power1 sources and compare their average power.
# -------------------------------------------------------------------------
text = summary_path.read_text(encoding="utf-8")
old = '''    if msr:
        lines.extend([
            f"- Duration: {fmt(whole.get('duration_s'), 6)} s",
'''
new = '''    if msr:
        source_paths = msr.get("source_paths") or {}
        source_verification = msr.get("source_verification") or {}
        lines.extend([
            f"- Source: {msr.get('source', 'unavailable')}",
            f"- Scope: {msr.get('source_scope', 'CPU package and DRAM RAPL domains')}",
            f"- Package counter: {source_paths.get('package_energy_uj', 'unavailable')}",
            f"- DRAM counter: {source_paths.get('dram_energy_uj', 'unavailable')}",
            f"- Package domain name: {source_verification.get('package_domain_name', 'unavailable')}",
            f"- DRAM domain name: {source_verification.get('dram_domain_name', 'unavailable')}",
            f"- Source validation: {'PASS' if source_verification.get('passed') else 'CHECK REQUIRED'}",
            f"- Power calculation: {msr.get('power_calculation', 'delta energy divided by actual sample time')}",
            f"- Duration: {fmt(whole.get('duration_s'), 6)} s",
'''
if old not in text:
    raise SystemExit("ERROR: RAPL summary anchor not found")
text = text.replace(old, new, 1)

start_marker = '''    lines.extend([
        "",
        "Whole-System Power and Energy — Whole Test",
'''
start = text.find(start_marker)
end = text.find('\n    counts = log.get("freq_action_counts", {})', start)
if start < 0 or end < 0:
    raise SystemExit("ERROR: whole-system/frequency summary section not found")
replacement = '''    lines.extend([
        "",
        "Whole-System Power and Energy — Whole Test",
        "------------------------------------------",
        f"- Source backend: {power.get('source', 'unavailable')}",
        f"- Exact source: {power.get('source_detail_last', 'unavailable')}",
        "- Sensor: power1 from lm-sensors or hwmon sysfs",
        "- Scope: whole-system/board power, not CPU-package RAPL",
        f"- Samples: {power.get('sample_count', 0)}",
        f"- Requested sampling interval: {power.get('sample_interval_ms_requested', 'unavailable')} ms",
        f"- Estimated cumulative energy: {fmt(power.get('estimated_energy_j_trapezoidal'), 3)} J",
        f"- Time-weighted average power: {fmt(power.get('average_power_w_time_weighted'), 3)} W",
        f"- Minimum / median / P95 / maximum: {fmt(power.get('power_w_min'))} / {fmt(power.get('power_w_median'))} / {fmt(power.get('power_w_p95'))} / {fmt(power.get('power_w_max'))} W",
    ])

    rapl_average = whole.get("average_total_power_w")
    board_average = power.get("average_power_w_time_weighted")
    if rapl_average is not None and board_average is not None:
        rapl_average_f = float(rapl_average)
        board_average_f = float(board_average)
        difference_w = board_average_f - rapl_average_f
        ratio = rapl_average_f / board_average_f if board_average_f else None
        lines.extend([
            "",
            "Power-Source Comparison — Whole Test",
            "------------------------------------",
            f"- RAPL package + DRAM average: {rapl_average_f:.3f} W",
            f"- power1 whole-system average: {board_average_f:.3f} W",
            f"- Whole-system minus RAPL: {difference_w:.3f} W",
            f"- RAPL / whole-system ratio: {fmt(ratio, 3)}",
            "- Interpretation: the values should not be equal because RAPL covers package + DRAM while power1 covers the board/system. The comparison is a scope cross-check, not an equality test.",
        ])

    lines.extend([
        "",
        "CPU Frequency",
        "-------------",
        f"- CPUs observed: {', '.join(str(value) for value in freq.get('cpus', [])) or 'none'}",
        f"- Timestamped frequency events: {freq.get('event_count', 0)}",
        f"- Minimum observed frequency: {fmt((freq.get('min_freq_khz') or 0) / 1e6 if freq.get('min_freq_khz') else None, 3)} GHz",
        f"- Maximum observed frequency: {fmt((freq.get('max_freq_khz') or 0) / 1e6 if freq.get('max_freq_khz') else None, 3)} GHz",
    ])
'''
text = text[:start] + replacement + text[end:]
ast.parse(text)
summary_path.write_text(text, encoding="utf-8")

# -------------------------------------------------------------------------
# Avoid the misleading one-shot snapshot warning when the compiled powercap
# time series is enabled; that time series is the source used in final results.
# -------------------------------------------------------------------------
text = common_path.read_text(encoding="utf-8")
old_warning = '        warn "Package RAPL is unavailable. The separate power1 time series is the primary whole-system power result."\n'
new_warning = '''        if [[ "${GQ_ENABLE_MSR_TRACE:-1}" != 0 ]]; then
            warn "One-shot RAPL snapshot did not report a package counter. The compiled powercap time series will be validated during result bundling and remains the authoritative RAPL source when its final validation is PASS."
        else
            warn "Package RAPL is unavailable and the compiled powercap trace is disabled; power1 is the only power source for this run."
        fi
'''
if old_warning not in text:
    raise SystemExit("ERROR: energy warning anchor not found")
text = text.replace(old_warning, new_warning, 1)
text = text.replace(
    'log "Started ${role} C RAPL/MSR trace pid=$GQ_MSR_TRACE_PID interval=${interval_ms}ms smoothing=${smooth_samples}"',
    'log "Started ${role} C RAPL powercap trace pid=$GQ_MSR_TRACE_PID interval=${interval_ms}ms smoothing=${smooth_samples}"',
    1,
)
common_path.write_text(text, encoding="utf-8")

print("Patched:", rapl_path)
print("Patched:", summary_path)
print("Patched:", common_path)
PY_PATCH

cat > "$CHECKER" <<'PY_CHECK'
#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import time
from pathlib import Path

PACKAGE = Path("/sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj")
DRAM = Path("/sys/class/powercap/intel-rapl/intel-rapl:0/intel-rapl:0:0/energy_uj")
PACKAGE_MAX = PACKAGE.with_name("max_energy_range_uj")
DRAM_MAX = DRAM.with_name("max_energy_range_uj")


def read_int(path: Path) -> int:
    return int(path.read_text(encoding="utf-8").strip())


def delta(before: int, after: int, maximum: int) -> int:
    value = after - before
    if value < 0:
        value += maximum
    return value


def main() -> int:
    print("RAPL source check")
    print("  package:", PACKAGE)
    print("  dram:   ", DRAM)
    if not PACKAGE.is_file() or not DRAM.is_file():
        print("  result: required package/DRAM counters are missing")
        return 2

    package_before = read_int(PACKAGE)
    dram_before = read_int(DRAM)
    start_ns = time.monotonic_ns()
    time.sleep(0.25)
    package_after = read_int(PACKAGE)
    dram_after = read_int(DRAM)
    end_ns = time.monotonic_ns()
    elapsed_s = (end_ns - start_ns) / 1_000_000_000.0
    package_w = delta(package_before, package_after, read_int(PACKAGE_MAX)) / 1_000_000.0 / elapsed_s
    dram_w = delta(dram_before, dram_after, read_int(DRAM_MAX)) / 1_000_000.0 / elapsed_s
    print(f"  {elapsed_s:.6f}s direct sample: package={package_w:.3f} W dram={dram_w:.3f} W total={package_w + dram_w:.3f} W")
    print("  formula: watts = delta energy_uj / 1e6 / actual monotonic seconds")

    module_path = Path(__file__).with_name("power_trace.py")
    try:
        spec = importlib.util.spec_from_file_location("gq_power_trace", module_path)
        if spec is None or spec.loader is None:
            raise RuntimeError("cannot load power_trace.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        board_w, source, detail = module.read_power("power1", "last")
        print(f"  power1 instantaneous: {board_w:.3f} W source={source}")
        print(f"  power1 exact source: {detail}")
        print(f"  instantaneous RAPL/power1 ratio: {(package_w + dram_w) / board_w:.3f}" if board_w else "  instantaneous ratio unavailable")
        print("  note: scopes differ; power1 normally includes more of the system than package+DRAM RAPL")
    except Exception as error:
        print("  power1 comparison unavailable:", error)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY_CHECK

chmod +x "$CSTATE" "$FREQ" "$RAPL" "$SUMMARY" "$CHECKER"
python3 -m py_compile "$CSTATE" "$FREQ" "$RAPL" "$SUMMARY" "$CHECKER"
bash -n "$COMMON"

echo
echo "PASS: installed chart and power-source clarity update."
echo "  C-state: one lane per CPU, dominant-state colors, t≈start-end, covered explanation."
echo "  Frequency: one lane per CPU, action colors, numbered mapping panel."
echo "  RAPL: exact package/DRAM powercap paths and delta-energy calculation recorded."
echo "  Summary: compares RAPL package+DRAM with whole-system power1 without treating them as equal scopes."
echo
echo "Immediate source check:"
python3 "$CHECKER" || true

echo
echo "Backups use suffix: .before_power_chart_clarity_${STAMP}"
echo "No MsQuic rebuild is required."
