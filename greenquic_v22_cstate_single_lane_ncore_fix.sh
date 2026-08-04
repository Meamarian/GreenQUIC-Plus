#!/usr/bin/env bash
set -euo pipefail

# Correct GreenQUIC V22 C-state layout:
#   - one C-state lane per traced CPU
#   - no wakeup lane, no black wakeup bar, no wakeup cap
#   - one compact block number above each stacked C-state bar
#   - wakeup count appears only in the concise mapping after the 1 cm gap
#   - deterministic CSTATE_COMPACT=N per CPU
#   - validates that compaction preserves counts, durations and wakeups
#
# Apply the same script on idex and tinyman.
# No MsQuic rebuild is required.

SUITE="${GQ_SUITE_ROOT:-/root/mohsen/greenquic_test_suite_v22}"
TARGET="$SUITE/common/bin/cstate_trace.py"

[[ -f "$TARGET" ]] || {
    echo "ERROR: missing $TARGET" >&2
    exit 1
}

STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="${TARGET}.before_single_lane_ncore_${STAMP}"
cp -a "$TARGET" "$BACKUP"

python3 - "$TARGET" <<'PY'
from __future__ import annotations

import ast
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
tree = ast.parse(source)

required_names = {
    node.name
    for node in tree.body
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
}

for required in (
    "timeline_plot",
    "compact_intervals",
    "choose_colors",
    "state_title",
    "env_int",
    "ensure_parent",
):
    if required not in required_names:
        raise SystemExit(
            f"ERROR: expected function {required!r} was not found in {path}"
        )


def replace_function(
    text: str,
    function_name: str,
    replacement: str,
) -> str:
    parsed = ast.parse(text)
    matches = [
        node
        for node in parsed.body
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
        and node.name == function_name
    ]

    if len(matches) != 1:
        raise SystemExit(
            f"ERROR: expected one top-level {function_name}, "
            f"found {len(matches)}"
        )

    node = matches[0]
    lines = text.splitlines(keepends=True)

    return (
        "".join(lines[: node.lineno - 1])
        + replacement.rstrip()
        + "\n\n"
        + "".join(lines[node.end_lineno :])
    )


compact_replacement = r'''
def compact_intervals(
    cpu: int,
    intervals: list[IdleInterval],
    compact_size: int,
) -> list[CompactBlock]:
    # CSTATE_COMPACT=N means exactly N completed idle intervals belonging to
    # this CPU in every full block. Different CPUs are never mixed.
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
                start_ns=min(item.start_ns for item in part),
                end_ns=max(item.end_ns for item in part),
                duration_by_state_ns=dict(duration_by_state),
                count_by_state=count_by_state,
                wakeups=sum(
                    item.end_event == "wake"
                    for item in part
                ),
            )
        )

    return blocks
'''

timeline_replacement = r'''
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

    cpus = sorted({item.cpu for item in intervals})
    states = sorted({item.state for item in intervals})

    if not cpus:
        raise ValueError("timeline_plot received no completed intervals")

    colors = choose_colors(states)

    intervals_by_cpu: dict[int, list[IdleInterval]] = {
        cpu: sorted(
            (
                item
                for item in intervals
                if item.cpu == cpu
            ),
            key=lambda item: (
                item.start_ns,
                item.end_ns,
                item.state,
                item.end_event,
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
            item
            for block in blocks
            for item in block.intervals
        ]

        raw_counts = Counter(item.state for item in raw)
        compacted_counts = Counter(
            item.state
            for item in compacted
        )

        raw_duration_ns: dict[int, int] = defaultdict(int)
        compacted_duration_ns: dict[int, int] = defaultdict(int)

        for item in raw:
            raw_duration_ns[item.state] += item.duration_ns

        for item in compacted:
            compacted_duration_ns[item.state] += item.duration_ns

        raw_wakeups = sum(
            item.end_event == "wake"
            for item in raw
        )
        compacted_wakeups = sum(
            block.wakeups
            for block in blocks
        )

        fingerprint_bytes = "\n".join(
            (
                f"{item.cpu},{item.state},"
                f"{item.start_ns},{item.end_ns},"
                f"{item.duration_ns},{item.end_event}"
            )
            for item in raw
        ).encode("utf-8")

        passed = (
            len(raw) == len(compacted)
            and raw_counts == compacted_counts
            and dict(raw_duration_ns)
                == dict(compacted_duration_ns)
            and raw_wakeups == compacted_wakeups
            and all(
                len(block.intervals) == compact_size
                for block in blocks[:-1]
            )
            and all(
                item.cpu == cpu
                for block in blocks
                for item in block.intervals
            )
        )

        validation[str(cpu)] = {
            "passed": passed,
            "raw_interval_count": len(raw),
            "compacted_interval_count": len(compacted),
            "compact_block_count": len(blocks),
            "full_block_size": compact_size,
            "last_block_size": (
                len(blocks[-1].intervals)
                if blocks
                else 0
            ),
            "raw_wakeups": raw_wakeups,
            "compacted_wakeups": compacted_wakeups,
            "raw_state_counts": {
                str(state): raw_counts[state]
                for state in sorted(raw_counts)
            },
            "compacted_state_counts": {
                str(state): compacted_counts[state]
                for state in sorted(compacted_counts)
            },
            "raw_state_duration_ns": {
                str(state): raw_duration_ns[state]
                for state in sorted(raw_duration_ns)
            },
            "compacted_state_duration_ns": {
                str(state): compacted_duration_ns[state]
                for state in sorted(compacted_duration_ns)
            },
            "raw_interval_fingerprint_sha256": (
                hashlib.sha256(fingerprint_bytes).hexdigest()
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
    lane_height_px = max(900, height_px)

    total_width_px = (
        timeline_width_px
        + one_cm_gap_px
        + mapping_width_px
    )
    total_height_px = lane_height_px * len(cpus)

    figure = plt.figure(
        figsize=(
            total_width_px / dpi,
            total_height_px / dpi,
        ),
        dpi=dpi,
    )

    grid = GridSpec(
        nrows=len(cpus),
        ncols=3,
        figure=figure,
        width_ratios=[
            timeline_width_px,
            one_cm_gap_px,
            mapping_width_px,
        ],
        wspace=0.0,
        hspace=0.32,
    )

    trace_end_ms = (
        max(item.end_ns for item in intervals)
        / 1_000_000.0
    )
    trace_span_ms = max(trace_end_ms, 0.001)

    minimum_visible_width_ms = max(
        trace_span_ms * 2.0 / timeline_width_px,
        0.000001,
    )

    timeline_axes = []
    mapping_axes = []

    for cpu_index in range(len(cpus)):
        timeline_axes.append(
            figure.add_subplot(grid[cpu_index, 0])
        )

        gap_axis = figure.add_subplot(
            grid[cpu_index, 1]
        )
        gap_axis.axis("off")

        mapping_axes.append(
            figure.add_subplot(grid[cpu_index, 2])
        )

    compact_metadata: dict[str, list[dict]] = {}

    for cpu_index, cpu in enumerate(cpus):
        axis = timeline_axes[cpu_index]
        mapping_axis = mapping_axes[cpu_index]
        blocks = blocks_by_cpu[cpu]

        compact_metadata[str(cpu)] = []

        maximum_idle_ms = max(
            (
                block.total_idle_ns / 1_000_000.0
                for block in blocks
            ),
            default=0.0,
        )
        label_padding_ms = max(
            maximum_idle_ms * 0.025,
            0.001,
        )

        mapping_lines: list[str] = []

        for block in blocks:
            start_ms = block.start_ns / 1_000_000.0
            end_ms = block.end_ns / 1_000_000.0

            block_span_ms = max(
                end_ms - start_ms,
                minimum_visible_width_ms,
            )
            center_ms = (start_ms + end_ms) / 2.0
            bar_width = max(
                block_span_ms * 0.78,
                minimum_visible_width_ms,
            )

            bottom_ms = 0.0

            for state in states:
                duration_ms = (
                    block.duration_by_state_ns.get(state, 0)
                    / 1_000_000.0
                )

                if duration_ms <= 0.0:
                    continue

                axis.bar(
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

            # One identifier for the complete compact block.
            # Wakeups are reported only in the mapping after the gap.
            axis.text(
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

            state_parts = [
                (
                    f"{state_title(cpu, state)} "
                    f"{block.count_by_state[state]}x/"
                    f"{block.duration_by_state_ns[state] / 1_000_000.0:.3f}ms"
                )
                for state in sorted(block.count_by_state)
            ]

            mapping_lines.append(
                (
                    f"{block.number}. "
                    f"N={len(block.intervals)} | "
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
                    "idle_total_ms": (
                        block.total_idle_ns / 1_000_000.0
                    ),
                    "state_interval_counts": {
                        str(state): block.count_by_state[state]
                        for state in sorted(block.count_by_state)
                    },
                    "state_duration_ms": {
                        str(state): (
                            block.duration_by_state_ns[state]
                            / 1_000_000.0
                        )
                        for state in sorted(
                            block.duration_by_state_ns
                        )
                    },
                }
            )

        axis.set_ylim(
            0.0,
            (
                maximum_idle_ms + label_padding_ms * 8.0
                if maximum_idle_ms > 0.0
                else 1.0
            ),
        )
        axis.set_xlim(
            -trace_span_ms * 0.005,
            trace_end_ms + trace_span_ms * 0.005,
        )
        axis.xaxis.set_major_locator(
            MaxNLocator(
                nbins=max_x_ticks,
                min_n_ticks=4,
            )
        )
        axis.grid(
            True,
            axis="y",
            linestyle="--",
            linewidth=0.7,
            alpha=0.35,
            zorder=0,
        )
        axis.tick_params(
            axis="both",
            labelsize=11,
        )
        axis.set_ylabel(
            "C-state residency\n(ms/block)",
            fontsize=13,
        )
        axis.set_xlabel(
            "Kernel cpu_idle trace time (ms)",
            fontsize=13,
        )
        axis.set_title(
            (
                f"CPU {cpu} — one compact C-state lane — "
                f"CSTATE_COMPACT={compact_size}"
            ),
            fontsize=16,
        )

        mapping_axis.axis("off")
        mapping_axis.text(
            0.0,
            1.0,
            (
                f"CPU {cpu} compact mapping\n"
                "Number -> N intervals, state count/duration, "
                "W wakeups, idle total, span"
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
            (
                "\n".join(mapping_lines)
                if mapping_lines
                else "No compact blocks."
            ),
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

    figure.legend(
        handles=legend_handles,
        loc="upper center",
        ncol=max(
            1,
            min(6, len(legend_handles)),
        ),
        fontsize=10,
        frameon=True,
        bbox_to_anchor=(0.5, 0.995),
    )

    figure.suptitle(
        (
            f"GreenQUIC {role} CPU-wise C-state timeline — "
            "one lane per CPU"
        ),
        fontsize=18,
        y=0.999,
    )

    figure.tight_layout(
        rect=(0.0, 0.0, 1.0, 0.980)
    )

    ensure_parent(output)
    figure.savefig(
        output,
        format="svg",
    )
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
        "kind": "cpuwise_cstate_single_lane_v4",
        "role": role,
        "cpus": cpus,
        "states": states,
        "compact_scope": "per_cpu",
        "compact_size_intervals_per_cpu": compact_size,
        "lanes_per_cpu": 1,
        "lane": "stacked_state_residency_ms_per_block",
        "wakeups_display": "mapping_only",
        "mapping_gap_cm": 1.0,
        "compaction_validation": validation,
        "compact_blocks_by_cpu": compact_metadata,
    }
'''

updated = replace_function(
    source,
    "compact_intervals",
    compact_replacement,
)

updated = replace_function(
    updated,
    "timeline_plot",
    timeline_replacement,
)

ast.parse(updated)

temporary = path.with_name(
    path.name + ".single_lane_tmp"
)
temporary.write_text(
    updated,
    encoding="utf-8",
)

compile(
    temporary.read_text(encoding="utf-8"),
    str(temporary),
    "exec",
)

temporary.replace(path)

print("Patched:", path)
PY

python3 -m py_compile "$TARGET"

echo
echo "PASS: corrected N-core C-state chart installed."
echo
echo "Layout:"
echo "  N traced CPUs -> N C-state lanes"
echo "  no wakeup lane"
echo "  no wakeup bar or black cap"
echo "  one compact number above each C-state bar"
echo "  wakeup count appears only as W=<count> in the mapping"
echo "  mapping begins after a 1 cm gap"
echo
echo "CSTATE_COMPACT=N is applied separately to each CPU."
echo "No MsQuic rebuild is required."
echo
echo "Backup:"
echo "  $BACKUP"
