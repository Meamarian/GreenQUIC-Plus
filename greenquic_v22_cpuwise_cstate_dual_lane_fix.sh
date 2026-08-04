#!/usr/bin/env bash
set -euo pipefail

SUITE="${GQ_SUITE_ROOT:-/root/mohsen/greenquic_test_suite_v22}"
CSTATE="$SUITE/common/bin/cstate_trace.py"

python3 - "$CSTATE" <<'PY'
from pathlib import Path
import ast
import datetime
import sys

cstate_path = Path(sys.argv[1])
stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
if not cstate_path.is_file():
    raise SystemExit(f"ERROR: missing {cstate_path}")
backup = cstate_path.with_name(cstate_path.name + f".before_cpuwise_dual_lane_{stamp}")
backup.write_text(cstate_path.read_text(encoding="utf-8"), encoding="utf-8")

text = cstate_path.read_text(encoding="utf-8")
for item in (
    "def timeline_plot(",
    "\ndef histogram_plot(",
    "class CompactBlock",
    "def compact_intervals(",
):
    if item not in text:
        raise SystemExit(
            "ERROR: current cstate_trace.py does not have the expected compact-bar implementation. Missing: " + item
        )

start = text.index("def timeline_plot(")
end = text.index("\ndef histogram_plot(", start)
replacement = '''def timeline_plot(
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

    cpus = sorted({item.cpu for item in intervals})
    states = sorted({item.state for item in intervals})
    colors = choose_colors(states)

    intervals_by_cpu: dict[int, list[IdleInterval]] = {
        cpu: [item for item in intervals if item.cpu == cpu]
        for cpu in cpus
    }
    blocks_by_cpu: dict[int, list[CompactBlock]] = {
        cpu: compact_intervals(cpu, intervals_by_cpu[cpu], compact_size)
        for cpu in cpus
    }

    dpi = 100
    timeline_width_px = max(1800, width_px)
    mapping_width_px = env_int(["CSTATE_MAPPING_WIDTH_PX"], default=5200, minimum=1400)
    gap_px = max(1, round(dpi / 2.54))  # about 1 cm at 100 DPI
    cpu_panel_height_px = max(1100, height_px)
    total_height_px = cpu_panel_height_px * max(1, len(cpus))
    total_width_px = timeline_width_px + gap_px + mapping_width_px

    fig = plt.figure(
        figsize=(total_width_px / dpi, total_height_px / dpi),
        dpi=dpi,
    )
    grid = GridSpec(
        nrows=max(1, len(cpus) * 2),
        ncols=3,
        figure=fig,
        width_ratios=[timeline_width_px, gap_px, mapping_width_px],
        wspace=0.0,
        hspace=0.32,
    )

    idle_axes = []
    wake_axes = []
    mapping_axes = []
    for index in range(len(cpus)):
        idle_axes.append(fig.add_subplot(grid[index * 2, 0]))
        wake_axes.append(fig.add_subplot(grid[index * 2 + 1, 0]))
        gap_axis = fig.add_subplot(grid[index * 2 : index * 2 + 2, 1])
        gap_axis.axis("off")
        mapping_axes.append(fig.add_subplot(grid[index * 2 : index * 2 + 2, 2]))

    trace_end_ms = max(item.end_ns for item in intervals) / 1_000_000.0
    trace_span_ms = max(trace_end_ms, 0.001)
    min_visible_width_ms = max(trace_span_ms * 2.0 / max(timeline_width_px, 1), 0.000_001)

    compact_metadata: dict[str, list[dict]] = {}

    for panel_index, cpu in enumerate(cpus):
        idle_ax = idle_axes[panel_index]
        wake_ax = wake_axes[panel_index]
        map_ax = mapping_axes[panel_index]
        blocks = blocks_by_cpu[cpu]
        compact_metadata[str(cpu)] = []

        max_idle_ms = max((block.total_idle_ns / 1_000_000.0 for block in blocks), default=0.0)
        max_wake = max((block.wakeups for block in blocks), default=0)
        idle_label_pad = max(max_idle_ms * 0.025, 0.001)

        mapping_lines: list[str] = []

        for block in blocks:
            start_ms = block.start_ns / 1_000_000.0
            end_ms = block.end_ns / 1_000_000.0
            span_ms = max(end_ms - start_ms, min_visible_width_ms)
            center_ms = (start_ms + end_ms) / 2.0
            bar_width = max(span_ms * 0.78, min_visible_width_ms)

            bottom_ms = 0.0
            for state in states:
                duration_ms = block.duration_by_state_ns.get(state, 0) / 1_000_000.0
                if duration_ms <= 0.0:
                    continue
                idle_ax.bar(
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

            idle_ax.text(
                center_ms,
                bottom_ms + idle_label_pad,
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

            wake_height = max(block.wakeups, 0)
            wake_ax.bar(
                center_ms,
                wake_height,
                width=bar_width,
                color="#111111",
                edgecolor="black",
                linewidth=0.45,
                align="center",
                zorder=4,
            )

            state_parts = []
            for state in sorted(block.count_by_state):
                state_parts.append(
                    f"{state_title(cpu, state)}: {block.count_by_state[state]} intervals, {block.duration_by_state_ns[state] / 1_000_000.0:.3f} ms"
                )

            trace_block_span_ms = (block.end_ns - block.start_ns) / 1_000_000.0
            mapping_lines.append(
                f"{block.number}. {len(block.intervals)} intervals | "
                + " | ".join(state_parts)
                + f" | wakeups {block.wakeups} | idle {block.total_idle_ns / 1_000_000.0:.3f} ms | span {trace_block_span_ms:.3f} ms"
            )

            compact_metadata[str(cpu)].append({
                "block": block.number,
                "intervals": len(block.intervals),
                "start_ms": start_ms,
                "end_ms": end_ms,
                "idle_total_ms": block.total_idle_ns / 1_000_000.0,
                "wakeups": block.wakeups,
                "state_interval_counts": {str(state): block.count_by_state[state] for state in sorted(block.count_by_state)},
                "state_duration_ms": {str(state): (block.duration_by_state_ns[state] / 1_000_000.0) for state in sorted(block.duration_by_state_ns)},
            })

        idle_ymax = max_idle_ms + idle_label_pad * 8.0 if max_idle_ms > 0.0 else 1.0
        idle_ax.set_ylim(0.0, idle_ymax)
        wake_ax.set_ylim(0.0, max(1.0, max_wake * 1.25 if max_wake > 0 else 1.0))

        idle_ax.set_ylabel("Idle residency\n(ms)", fontsize=13)
        wake_ax.set_ylabel("Wakeups\n(count)", fontsize=13)
        idle_ax.set_title(
            f"CPU {cpu}: lane 1 = compact idle-state bars, lane 2 = wakeup-count bars — role={role} — {compact_size} intervals/bar",
            fontsize=16,
        )

        for axis in (idle_ax, wake_ax):
            axis.grid(True, axis="y", linestyle="--", linewidth=0.7, alpha=0.35, zorder=0)
            axis.tick_params(axis="both", labelsize=11)
            axis.set_xlim(-trace_span_ms * 0.005, trace_end_ms + trace_span_ms * 0.005)
            axis.xaxis.set_major_locator(MaxNLocator(nbins=max_x_ticks, min_n_ticks=4))

        idle_ax.tick_params(axis="x", labelbottom=False)
        wake_ax.set_xlabel("Elapsed time [ms]", fontsize=14)

        map_ax.axis("off")
        mapping_title = (
            f"CPU {cpu} compact-bar mapping\\n"
            "Number → included intervals, states, wakeups and duration"
        )
        map_ax.text(
            0.0,
            1.0,
            mapping_title,
            transform=map_ax.transAxes,
            ha="left",
            va="top",
            fontsize=14,
            fontweight="bold",
        )
        map_ax.text(
            0.0,
            0.965,
            "",
            transform=map_ax.transAxes,
            ha="left",
            va="top",
            fontsize=10,
        )
        map_ax.text(
            0.0,
            0.94,
            "\\n".join(mapping_lines) if mapping_lines else "No compact bars.",
            transform=map_ax.transAxes,
            ha="left",
            va="top",
            fontsize=10,
            family="monospace",
            linespacing=1.35,
            wrap=True,
        )

    legend_handles = [
        Patch(facecolor=colors[state], edgecolor="black", label=state_title(cpus[0], state))
        for state in states
    ]
    legend_handles.append(Patch(facecolor="#111111", edgecolor="black", label="Wakeup-count bar in the second lane"))

    fig.legend(
        handles=legend_handles,
        loc="upper center",
        ncol=max(2, min(6, len(legend_handles))),
        fontsize=11,
        frameon=True,
        bbox_to_anchor=(0.5, 0.995),
    )

    fig.suptitle(
        f"GreenQUIC {role} CPU-wise compact C-state timeline — two lanes per CPU",
        fontsize=18,
        y=0.999,
    )
    fig.tight_layout(rect=(0.0, 0.0, 1.0, 0.982))
    fig.savefig(output, format="svg")
    plt.close(fig)

    return {
        "kind": "cpuwise_compact_cstate_dual_lane",
        "role": role,
        "cpus": cpus,
        "states": states,
        "compact_size": compact_size,
        "layout": {
            "lanes_per_cpu": 2,
            "lane_1": "idle_state_residency_ms",
            "lane_2": "wakeups_count",
            "gap_cm": 1.0,
            "mapping_after_gap": True,
        },
        "compact_blocks_by_cpu": compact_metadata,
    }
'''
text = text[:start] + replacement + text[end:]
ast.parse(text)
cstate_path.write_text(text, encoding="utf-8")
print("Patched:", cstate_path)
print("Backup:", backup)
print("PASS: CPU-wise dual-lane C-state chart installed.")
PY

python3 -m py_compile "$CSTATE"

echo
echo "Installed CPU-wise dual-lane C-state layout:"
echo "  - C-state data remain tied to CPU IDs"
echo "  - each CPU now gets 2 lanes"
echo "      lane 1 = compact C-state residency bars"
echo "      lane 2 = compact wakeup-count bars"
echo "  - one compact number label above each upper bar"
echo "  - 1 cm gap after timeline, then compact-number mapping"
echo "  - wakeup information stays in the mapping too"
echo
echo "Useful controls:"
echo "  ENABLE_CSTATE_RECORD=1"
echo "  CSTATE_COMPACT=500"
echo "  CSTATE_MAPPING_WIDTH_PX=5200"
echo "  GQ_PLOT_WIDTH_PX=24000"
echo "  GQ_PLOT_HEIGHT_PX=3500"
echo "  GQ_PLOT_X_TICK_MS=1000"
echo "  GQ_PLOT_X_LABEL_MS=1000"
echo
echo "No MsQuic rebuild is required."
