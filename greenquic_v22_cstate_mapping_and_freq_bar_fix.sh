#!/usr/bin/env bash
set -euo pipefail

SUITE="${GQ_SUITE_ROOT:-/root/mohsen/greenquic_test_suite_v22}"
CSTATE="$SUITE/common/bin/cstate_trace.py"
FREQ="$SUITE/common/bin/frequency_trace.py"

python3 - "$CSTATE" "$FREQ" <<'PY'
from pathlib import Path
import ast
import datetime
import sys

cstate_path = Path(sys.argv[1])
freq_path = Path(sys.argv[2])
stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")

for path in (cstate_path, freq_path):
    if not path.is_file():
        raise SystemExit(f"ERROR: missing {path}")
    backup = path.with_name(path.name + f".before_chart_layout_{stamp}")
    backup.write_text(path.read_text(encoding="utf-8"), encoding="utf-8")

cstate_text = cstate_path.read_text(encoding="utf-8")
for item in (
    "def timeline_plot(",
    "\ndef histogram_plot(",
    "class CompactBlock",
    "def compact_intervals(",
):
    if item not in cstate_text:
        raise SystemExit(
            "ERROR: current cstate_trace.py does not have the expected "
            "bar-timeline implementation. Missing: " + item
        )

cstate_start = cstate_text.index("def timeline_plot(")
cstate_end = cstate_text.index("\ndef histogram_plot(", cstate_start)
cstate_function = 'def timeline_plot(\n    *,\n    output: Path,\n    role: str,\n    intervals: list[IdleInterval],\n    compact_size: int,\n    width_px: int,\n    height_px: int,\n    max_x_ticks: int,\n    annotate_every: int,\n    max_annotations: int,\n) -> dict:\n    import matplotlib\n    matplotlib.use("Agg")\n    import matplotlib.pyplot as plt\n    from matplotlib.gridspec import GridSpec\n    from matplotlib.patches import Patch\n    from matplotlib.ticker import MaxNLocator\n\n    cpus = sorted({item.cpu for item in intervals})\n    states = sorted({item.state for item in intervals})\n    colors = choose_colors(states)\n\n    intervals_by_cpu: dict[int, list[IdleInterval]] = {\n        cpu: [item for item in intervals if item.cpu == cpu]\n        for cpu in cpus\n    }\n    blocks_by_cpu: dict[int, list[CompactBlock]] = {\n        cpu: compact_intervals(cpu, intervals_by_cpu[cpu], compact_size)\n        for cpu in cpus\n    }\n\n    dpi = 100\n    timeline_width_px = max(1600, width_px)\n    mapping_width_px = env_int(\n        ["CSTATE_MAPPING_WIDTH_PX"],\n        default=5200,\n        minimum=1400,\n    )\n    gap_px = max(1, round(dpi / 2.54))  # exactly about 1 cm at 100 DPI\n    panel_height_px = max(900, height_px)\n    total_height_px = panel_height_px * max(1, len(cpus))\n    total_width_px = timeline_width_px + gap_px + mapping_width_px\n\n    fig = plt.figure(\n        figsize=(total_width_px / dpi, total_height_px / dpi),\n        dpi=dpi,\n    )\n    grid = GridSpec(\n        nrows=max(1, len(cpus)),\n        ncols=3,\n        figure=fig,\n        width_ratios=[timeline_width_px, gap_px, mapping_width_px],\n        wspace=0.0,\n        hspace=0.28,\n    )\n\n    axes_list = []\n    mapping_axes = []\n    for index in range(len(cpus)):\n        axes_list.append(fig.add_subplot(grid[index, 0]))\n        gap_axis = fig.add_subplot(grid[index, 1])\n        gap_axis.axis("off")\n        mapping_axes.append(fig.add_subplot(grid[index, 2]))\n\n    trace_end_ms = max(item.end_ns for item in intervals) / 1_000_000.0\n    trace_span_ms = max(trace_end_ms, 0.001)\n    min_visible_width_ms = max(\n        trace_span_ms * 2.0 / max(timeline_width_px, 1),\n        0.000_001,\n    )\n\n    legend_handles = [\n        Patch(\n            facecolor=colors[state],\n            edgecolor="black",\n            label=state_title(cpus[0], state),\n        )\n        for state in states\n    ]\n    legend_handles.append(\n        Patch(\n            facecolor="#111111",\n            edgecolor="black",\n            label=(\n                "Wakeups/idle exits distributed inside the same compact block "\n                "(symbolic black cap)"\n            ),\n        )\n    )\n\n    compact_metadata: dict[str, list[dict]] = {}\n\n    for panel_index, cpu in enumerate(cpus):\n        ax = axes_list[panel_index]\n        map_ax = mapping_axes[panel_index]\n        blocks = blocks_by_cpu[cpu]\n        compact_metadata[str(cpu)] = []\n\n        max_idle_ms = max(\n            (\n                block.total_idle_ns / 1_000_000.0\n                for block in blocks\n            ),\n            default=0.0,\n        )\n        wake_cap_height_ms = max(max_idle_ms * 0.045, 0.001)\n        number_padding_ms = max(max_idle_ms * 0.025, 0.001)\n\n        mapping_lines: list[str] = []\n\n        for block in blocks:\n            start_ms = block.start_ns / 1_000_000.0\n            end_ms = block.end_ns / 1_000_000.0\n            span_ms = max(end_ms - start_ms, min_visible_width_ms)\n            center_ms = (start_ms + end_ms) / 2.0\n            bar_width = max(span_ms * 0.78, min_visible_width_ms)\n\n            bottom_ms = 0.0\n            for state in states:\n                duration_ms = (\n                    block.duration_by_state_ns.get(state, 0)\n                    / 1_000_000.0\n                )\n                if duration_ms <= 0.0:\n                    continue\n\n                ax.bar(\n                    center_ms,\n                    duration_ms,\n                    width=bar_width,\n                    bottom=bottom_ms,\n                    color=colors[state],\n                    edgecolor="black",\n                    linewidth=0.45,\n                    align="center",\n                    zorder=3,\n                )\n                bottom_ms += duration_ms\n\n            # The black cap belongs to this same compact bar. It summarizes\n            # wakeups distributed between the colored idle intervals.\n            ax.bar(\n                center_ms,\n                wake_cap_height_ms,\n                width=bar_width,\n                bottom=bottom_ms,\n                color="#111111",\n                edgecolor="black",\n                linewidth=0.45,\n                align="center",\n                zorder=4,\n            )\n\n            # Only one compact identifier is shown on the chart.\n            ax.text(\n                center_ms,\n                bottom_ms + wake_cap_height_ms + number_padding_ms,\n                str(block.number),\n                ha="center",\n                va="bottom",\n                fontsize=11,\n                fontweight="bold",\n                color="#111111",\n                bbox={\n                    "boxstyle": "round,pad=0.18",\n                    "facecolor": "white",\n                    "edgecolor": "#333333",\n                    "alpha": 0.96,\n                },\n                clip_on=False,\n                zorder=11,\n            )\n\n            state_parts = []\n            for state in sorted(block.count_by_state):\n                state_parts.append(\n                    (\n                        f"{state_title(cpu, state)}: "\n                        f"{block.count_by_state[state]} intervals, "\n                        f"{block.duration_by_state_ns[state] / 1_000_000.0:.3f} ms"\n                    )\n                )\n\n            trace_block_span_ms = (\n                block.end_ns - block.start_ns\n            ) / 1_000_000.0\n            mapping_lines.append(\n                (\n                    f"{block.number}. {len(block.intervals)} intervals | "\n                    + " | ".join(state_parts)\n                    + (\n                        f" | wakeups {block.wakeups}"\n                        f" | idle {block.total_idle_ns / 1_000_000.0:.3f} ms"\n                        f" | span {trace_block_span_ms:.3f} ms"\n                    )\n                )\n            )\n\n            compact_metadata[str(cpu)].append(\n                {\n                    "block": block.number,\n                    "intervals": len(block.intervals),\n                    "start_ms": start_ms,\n                    "end_ms": end_ms,\n                    "idle_total_ms": block.total_idle_ns / 1_000_000.0,\n                    "wakeups_distributed_inside_block": block.wakeups,\n                    "state_interval_counts": {\n                        str(state): block.count_by_state[state]\n                        for state in sorted(block.count_by_state)\n                    },\n                    "state_duration_ms": {\n                        str(state): (\n                            block.duration_by_state_ns[state] / 1_000_000.0\n                        )\n                        for state in sorted(block.duration_by_state_ns)\n                    },\n                }\n            )\n\n        if max_idle_ms > 0.0:\n            ax.set_ylim(\n                0.0,\n                max_idle_ms + wake_cap_height_ms + number_padding_ms * 8.0,\n            )\n\n        ax.set_ylabel("Idle residency by C-state (ms)", fontsize=14)\n        ax.set_title(\n            (\n                f"CPU {cpu}: compact C-state bars over kernel-trace time "\n                f"— role={role} — {compact_size} intervals/bar"\n            ),\n            fontsize=17,\n        )\n        ax.grid(\n            True,\n            axis="y",\n            linestyle="--",\n            linewidth=0.7,\n            alpha=0.35,\n            zorder=0,\n        )\n        ax.tick_params(axis="both", labelsize=11)\n        ax.set_xlim(\n            -trace_span_ms * 0.005,\n            trace_end_ms + trace_span_ms * 0.005,\n        )\n        ax.xaxis.set_major_locator(\n            MaxNLocator(nbins=max_x_ticks, min_n_ticks=4)\n        )\n\n        # The middle GridSpec column is a real one-centimetre blank gap.\n        # The complete number-to-summary mapping is placed after that gap.\n        map_ax.axis("off")\n        mapping_title = (\n            f"CPU {cpu} compact-bar mapping\\n"\n            "Number → included intervals, states, wakeups and duration"\n        )\n        map_ax.text(\n            0.0,\n            1.0,\n            mapping_title,\n            transform=map_ax.transAxes,\n            ha="left",\n            va="top",\n            fontsize=13,\n            fontweight="bold",\n        )\n\n        line_count = max(1, len(mapping_lines))\n        mapping_font_size = max(\n            6.0,\n            min(11.0, 220.0 / line_count),\n        )\n        map_ax.text(\n            0.0,\n            0.94,\n            "\\n".join(mapping_lines),\n            transform=map_ax.transAxes,\n            ha="left",\n            va="top",\n            fontsize=mapping_font_size,\n            family="monospace",\n            linespacing=1.35,\n            wrap=True,\n        )\n\n    axes_list[-1].set_xlabel(\n        "Kernel cpu_idle trace time from first recorded event (ms)",\n        fontsize=14,\n    )\n\n    fig.legend(\n        handles=legend_handles,\n        loc="upper right",\n        bbox_to_anchor=(0.995, 0.995),\n        title="C-state / event legend",\n        title_fontsize=12,\n        fontsize=11,\n        frameon=True,\n        ncol=min(3, max(1, len(legend_handles))),\n    )\n    fig.suptitle(\n        (\n            "GreenQUIC Linux C-state compact bar timeline\\n"\n            "Each bar has one number; its complete concise explanation is "\n            "listed after the 1 cm gap"\n        ),\n        fontsize=20,\n        y=0.999,\n    )\n    fig.subplots_adjust(\n        left=0.04,\n        right=0.995,\n        bottom=0.06,\n        top=0.94,\n    )\n\n    ensure_parent(output)\n    fig.savefig(output, format="svg")\n    plt.close(fig)\n\n    return {\n        "compact_size_intervals": compact_size,\n        "compact_blocks_by_cpu": compact_metadata,\n        "timeline_x_axis": (\n            "relative kernel cpu_idle timestamp in milliseconds"\n        ),\n        "timeline_state_bar_unit": "milliseconds of idle residency",\n        "timeline_wakeup_encoding": (\n            "symbolic black cap inside the same numbered compact bar"\n        ),\n        "mapping_layout": (\n            "one number per bar; 1 cm blank column; concise mapping list"\n        ),\n        "mapping_gap_cm": 1.0,\n    }\n'
cstate_text = cstate_text[:cstate_start] + cstate_function + cstate_text[cstate_end:]
ast.parse(cstate_text)
cstate_path.write_text(cstate_text, encoding="utf-8")

freq_text = freq_path.read_text(encoding="utf-8")
freq_marker = "# GREENQUIC-V22-FREQUENCY-BAR-TIMELINE-V1"

if freq_marker not in freq_text:
    freq_text = freq_text.replace(
        "import argparse\nimport csv\nimport json\nimport re\n",
        "import argparse\nimport csv\nimport html\nimport json\n"
        "import math\nimport os\nimport re\n",
        1,
    )
    freq_text = freq_text.replace(
        "from pathlib import Path\nfrom typing import Any\n\n"
        "from gq_plot import write_line_svg\n",
        "from pathlib import Path\nfrom types import SimpleNamespace\n"
        "from typing import Any\n\nfrom gq_plot import settings\n",
        1,
    )

    if "from gq_plot import settings" not in freq_text:
        raise SystemExit("ERROR: could not replace the frequency plot import")

    freq_text = freq_text.replace(
        'if last_by_cpu.get(cpu) == freq and '
        'event.get("source") == "periodic_stats":',
        'if last_by_cpu.get(cpu) == freq:',
        1,
    )

    main_anchor = "\n\ndef main() -> int:\n"
    if main_anchor not in freq_text:
        raise SystemExit("ERROR: frequency_trace.py main anchor not found")

    freq_helpers = '# GREENQUIC-V22-FREQUENCY-BAR-TIMELINE-V1\n\ndef _env_int(name: str, default: int, minimum: int, maximum: int) -> int:\n    raw = os.environ.get(name)\n    if raw is None or raw.strip() == "":\n        return default\n    try:\n        value = int(raw)\n    except ValueError:\n        return default\n    return min(max(value, minimum), maximum)\n\n\ndef _nice_step(duration_ms: float, requested_ms: int, max_ticks: int) -> float:\n    if duration_ms <= 0.0:\n        return float(max(1, requested_ms))\n\n    minimum = max(float(requested_ms), duration_ms / max(1, max_ticks))\n    exponent = math.floor(math.log10(minimum))\n    base = 10.0 ** exponent\n\n    for factor in (1.0, 2.0, 5.0, 10.0):\n        candidate = factor * base\n        if candidate >= minimum:\n            return candidate\n\n    return 10.0 * base\n\n\ndef _frequency_intervals(\n    events: list[dict[str, Any]],\n    duration_ms: float,\n) -> dict[int, list[dict[str, Any]]]:\n    by_cpu: dict[int, list[dict[str, Any]]] = {}\n\n    for event in events:\n        by_cpu.setdefault(int(event["cpu"]), []).append(event)\n\n    result: dict[int, list[dict[str, Any]]] = {}\n\n    for cpu, rows in by_cpu.items():\n        rows.sort(key=lambda row: float(row["elapsed_ms"]))\n        intervals: list[dict[str, Any]] = []\n\n        for index, row in enumerate(rows):\n            start_ms = max(0.0, float(row["elapsed_ms"]))\n            end_ms = (\n                float(rows[index + 1]["elapsed_ms"])\n                if index + 1 < len(rows)\n                else max(duration_ms, start_ms)\n            )\n\n            if end_ms <= start_ms:\n                continue\n\n            intervals.append({\n                "cpu": cpu,\n                "start_ms": start_ms,\n                "end_ms": end_ms,\n                "duration_ms": end_ms - start_ms,\n                "freq_khz": int(row["freq_khz"]),\n                "freq_ghz": int(row["freq_khz"]) / 1_000_000.0,\n                "action": row.get("action"),\n                "source": row.get("source"),\n            })\n\n        result[cpu] = intervals\n\n    return result\n\n\ndef _write_frequency_bar_svg(\n    path: Path,\n    *,\n    role: str,\n    events: list[dict[str, Any]],\n    duration_ms: float,\n):\n    base = settings("freq", duration_ms)\n    intervals_by_cpu = _frequency_intervals(events, duration_ms)\n    cpus = sorted(intervals_by_cpu)\n\n    max_x_ms = max(\n        [duration_ms, 1.0]\n        + [\n            float(interval["end_ms"])\n            for rows in intervals_by_cpu.values()\n            for interval in rows\n        ]\n    )\n    max_freq_ghz = max(\n        [\n            float(interval["freq_ghz"])\n            for rows in intervals_by_cpu.values()\n            for interval in rows\n        ],\n        default=1.0,\n    )\n    y_max = max(1.0, math.ceil(max_freq_ghz * 10.0) / 10.0) * 1.08\n\n    left = 125\n    right = 55\n    top = 105\n    bottom = 100\n    lane_height = _env_int("GQ_FREQ_LANE_HEIGHT_PX", 430, 220, 1200)\n    width = max(base.width, 1400)\n    height = max(\n        base.height,\n        top + bottom + lane_height * max(1, len(cpus)),\n    )\n    plot_width = width - left - right\n\n    max_ticks = _env_int("GQ_FREQ_MAX_X_TICKS", 24, 4, 200)\n    requested_label_ms = _env_int(\n        "GQ_FREQ_PLOT_X_LABEL_MS",\n        _env_int("GQ_PLOT_X_LABEL_MS", 100, 1, 600000),\n        1,\n        600000,\n    )\n    tick_step_ms = _nice_step(\n        max_x_ms,\n        requested_label_ms,\n        max_ticks,\n    )\n\n    max_labels = _env_int("GQ_FREQ_MAX_BAR_LABELS", 80, 0, 10000)\n    total_bars = sum(len(rows) for rows in intervals_by_cpu.values())\n    label_stride = (\n        max(1, math.ceil(total_bars / max_labels))\n        if max_labels > 0\n        else total_bars + 1\n    )\n\n    palette = [\n        "#4E79A7",\n        "#F28E2B",\n        "#59A14F",\n        "#E15759",\n        "#B07AA1",\n        "#76B7B2",\n    ]\n\n    def x_pos(value_ms: float) -> float:\n        return (\n            left\n            + min(max(value_ms, 0.0), max_x_ms)\n            / max_x_ms\n            * plot_width\n        )\n\n    out = [\n        (\n            f\'<svg xmlns="http://www.w3.org/2000/svg" \'\n            f\'width="{width}" height="{height}" \'\n            f\'viewBox="0 0 {width} {height}">\'\n        ),\n        \'<rect width="100%" height="100%" fill="white"/>\',\n        (\n            f\'<text x="{width / 2:.1f}" y="34" text-anchor="middle" \'\n            f\'font-family="sans-serif" font-size="24">\'\n            f\'{html.escape(f"GreenQUIC {role} CPU frequency interval bars")}\'\n            \'</text>\'\n        ),\n        (\n            f\'<text x="{width / 2:.1f}" y="62" text-anchor="middle" \'\n            f\'font-family="sans-serif" font-size="15">\'\n            \'Bar height = frequency; bar width = time held at that frequency\'\n            \'</text>\'\n        ),\n    ]\n\n    plot_bottom = top + lane_height * max(1, len(cpus))\n    tick = 0.0\n\n    while tick <= max_x_ms + tick_step_ms * 0.001:\n        x = x_pos(tick)\n        out.append(\n            f\'<line x1="{x:.2f}" y1="{top}" x2="{x:.2f}" \'\n            f\'y2="{plot_bottom}" stroke="#dedede" stroke-width="1"/>\'\n        )\n        out.append(\n            f\'<text x="{x:.2f}" y="{plot_bottom + 34}" \'\n            f\'text-anchor="middle" font-family="monospace" font-size="13">\'\n            f\'{tick:g}</text>\'\n        )\n        tick += tick_step_ms\n\n    bar_counter = 0\n\n    for lane_index, cpu in enumerate(cpus):\n        lane_top = top + lane_index * lane_height\n        lane_bottom = lane_top + lane_height - 55\n        usable_height = lane_height - 95\n        color = palette[lane_index % len(palette)]\n\n        out.append(\n            f\'<rect x="{left}" y="{lane_top}" width="{plot_width}" \'\n            f\'height="{lane_height - 35}" fill="#fafafa" stroke="#aaaaaa"/>\'\n        )\n        out.append(\n            f\'<text x="{left - 16}" y="{lane_top + 24}" text-anchor="end" \'\n            f\'font-family="sans-serif" font-size="16" font-weight="bold">\'\n            f\'CPU {cpu}</text>\'\n        )\n\n        for y_index in range(6):\n            value = y_max * y_index / 5.0\n            y = lane_bottom - value / y_max * usable_height\n            out.append(\n                f\'<line x1="{left}" y1="{y:.2f}" x2="{width - right}" \'\n                f\'y2="{y:.2f}" stroke="#e6e6e6"/>\'\n            )\n            out.append(\n                f\'<text x="{left - 12}" y="{y + 5:.2f}" text-anchor="end" \'\n                f\'font-family="monospace" font-size="13">{value:.2f}</text>\'\n            )\n\n        for interval in intervals_by_cpu[cpu]:\n            x0 = x_pos(float(interval["start_ms"]))\n            x1 = x_pos(float(interval["end_ms"]))\n            bar_width = max(1.0, x1 - x0)\n            freq_ghz = float(interval["freq_ghz"])\n            bar_height = freq_ghz / y_max * usable_height\n            y = lane_bottom - bar_height\n\n            out.append(\n                f\'<rect x="{x0:.2f}" y="{y:.2f}" \'\n                f\'width="{bar_width:.2f}" height="{bar_height:.2f}" \'\n                f\'fill="{color}" stroke="black" stroke-width="0.6"/>\'\n            )\n\n            if (\n                max_labels > 0\n                and bar_counter % label_stride == 0\n                and bar_width >= 30.0\n            ):\n                label = f"{freq_ghz:.3f} GHz"\n                if interval.get("action"):\n                    label += f" | {interval[\'action\']}"\n\n                out.append(\n                    f\'<text x="{x0 + bar_width / 2:.2f}" \'\n                    f\'y="{max(lane_top + 18, y - 7):.2f}" \'\n                    f\'text-anchor="middle" font-family="sans-serif" \'\n                    f\'font-size="11">{html.escape(label)}</text>\'\n                )\n\n            bar_counter += 1\n\n        out.append(\n            f\'<line x1="{left}" y1="{lane_bottom}" \'\n            f\'x2="{width - right}" y2="{lane_bottom}" \'\n            f\'stroke="black" stroke-width="2"/>\'\n        )\n\n    out.extend([\n        (\n            f\'<text x="{width / 2:.1f}" y="{height - 24}" \'\n            f\'text-anchor="middle" font-family="sans-serif" font-size="17">\'\n            f\'Elapsed time [ms] — bounded labeled step {tick_step_ms:g} ms\'\n            \'</text>\'\n        ),\n        (\n            f\'<text x="28" y="{height / 2:.1f}" text-anchor="middle" \'\n            f\'font-family="sans-serif" font-size="17" \'\n            f\'transform="rotate(-90 28 {height / 2:.1f})">\'\n            \'Frequency [GHz]</text>\'\n        ),\n        \'</svg>\',\n    ])\n\n    path.write_text("\\n".join(out) + "\\n", encoding="utf-8")\n\n    return (\n        SimpleNamespace(\n            width=width,\n            height=height,\n            tick_ms=tick_step_ms,\n            label_ms=tick_step_ms,\n            min_px_per_tick=base.min_px_per_tick,\n        ),\n        intervals_by_cpu,\n    )'
    freq_text = freq_text.replace(
        main_anchor,
        "\n\n" + freq_helpers + main_anchor,
        1,
    )

    old_plot = '    cpus = sorted({int(row["cpu"]) for row in events})\n    series = []\n    for cpu in cpus:\n        points = [\n            (float(row["elapsed_ms"]), float(row["freq_khz"]) / 1_000_000.0)\n            for row in events if int(row["cpu"]) == cpu\n        ]\n        series.append({"label": f"CPU {cpu}", "points": points})\n\n    plot = None\n    if series:\n        plot = write_line_svg(\n            svg_path,\n            kind="freq",\n            title=f"GreenQUIC {args.role} CPU frequency over time",\n            y_label="Frequency [GHz]",\n            series=series,\n            duration_ms=duration_s * 1000.0,\n            step=True,\n            y_value_format=".3f",\n        )\n'
    new_plot = '    cpus = sorted({int(row["cpu"]) for row in events})\n\n    plot = None\n    intervals_by_cpu: dict[int, list[dict[str, Any]]] = {}\n    if events:\n        plot, intervals_by_cpu = _write_frequency_bar_svg(\n            svg_path,\n            role=args.role,\n            events=events,\n            duration_ms=duration_s * 1000.0,\n        )\n'

    if old_plot not in freq_text:
        raise SystemExit(
            "ERROR: current frequency step-line plotting block was not found"
        )

    freq_text = freq_text.replace(old_plot, new_plot, 1)

    freq_text = freq_text.replace(
        '        "events": events,\n'
        '        "plot": None if plot is None else {',
        '        "events": events,\n'
        '        "frequency_intervals_by_cpu": {\n'
        '            str(cpu): rows for cpu, rows in intervals_by_cpu.items()\n'
        '        },\n'
        '        "plot": None if plot is None else {',
        1,
    )
    freq_text = freq_text.replace(
        '            "width_px": plot.width,',
        '            "kind": "frequency_interval_bar_chart",\n'
        '            "width_px": plot.width,',
        1,
    )
    freq_text = freq_text.replace('        "measurement_note": (\n            "Event time is captured by the line-timestamp wrapper when a complete GreenQUIC "\n            "log row is received. Frequency actions are immediate log events; unchanged "\n            "intervals are represented as a step trace."\n        ),\n', '        "measurement_note": (\n            "Each vertical bar is one deduplicated frequency-residency interval. "\n            "Bar height is GHz and bar width is duration. Event timestamps come "\n            "from the line-timestamp wrapper; frequency before the first observed "\n            "event is not inferred."\n        ),\n', 1)

ast.parse(freq_text)
freq_path.write_text(freq_text, encoding="utf-8")

print("Patched:", cstate_path)
print("Patched:", freq_path)
print("PASS: chart layout changes installed.")

PY

python3 -m py_compile "$CSTATE" "$FREQ"

echo
echo "C-state timeline:"
echo "  - one number above each compact bar"
echo "  - no separate wakeup label"
echo "  - one 1 cm blank column after the timeline"
echo "  - concise number-to-summary mapping after the gap"
echo
echo "Frequency timeline:"
echo "  - vertical interval bars"
echo "  - bar height = frequency in GHz"
echo "  - bar width = time held at that frequency"
echo "  - one lane per CPU"
echo
echo "Useful controls:"
echo "  CSTATE_COMPACT=500"
echo "  CSTATE_MAPPING_WIDTH_PX=5200"
echo "  GQ_FREQ_MAX_X_TICKS=24"
echo "  GQ_FREQ_MAX_BAR_LABELS=80"
echo "  GQ_FREQ_LANE_HEIGHT_PX=430"
echo
echo "No MsQuic rebuild is required."
