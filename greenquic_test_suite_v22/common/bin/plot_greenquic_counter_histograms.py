#!/usr/bin/env python3
# GREENQUIC-P5-COUNTER-HISTOGRAM-PLOTTER-V1
"""Additional P5 counter histograms.

This script intentionally does not modify or replace any existing P5 charts.
For one finalized matrix directory it creates four additional grouped-bar figures:
  * client CUBIC hint counts
  * server CUBIC hint counts
  * client frequency-action counts
  * server frequency-action counts

The matrix directory itself defines the running profile. No profile name or
profile-specific tuning is hard-coded here. Values are the arithmetic mean
per repetition for OFF/BASIC/PLUS in that matrix.
"""
from __future__ import annotations

import argparse
import csv
import math
import tempfile
from collections import defaultdict
from pathlib import Path
from statistics import mean

MODES = ("off", "basic", "plus")
ROLES = ("client", "server")

CUBIC_FIELDS = (
    ("hint_cubic_cwnd_blocked", "CWND blocked"),
    ("hint_cubic_recovery", "Recovery begin"),
    ("hint_cubic_recovery_end", "Recovery end"),
    ("hint_cubic_ramping", "CWND ramping"),
)

FREQ_FIELDS = (
    ("freq_policy_up", "freq_up"),
    ("freq_policy_down", "freq_down"),
    ("freq_policy_min", "freq_min"),
    ("freq_policy_max_hard", "freq_max_hard"),
)

STYLE = {
    "title_size": 18,
    "axis_label_size": 12,
    "x_tick_size": 11,
    "y_tick_size": 11,
    "legend_size": 10,
    "value_size": 10,
    "figure_width": 11.5,
    "figure_height": 6.8,
    "plot_left": 0.085,
    "plot_bottom": 0.18,
    "plot_width": 0.70,
    "plot_height": 0.66,
    "headroom_factor": 1.20,
    "bar_width": 0.13,
    "bar_gap": 0.055,
    "case_spacing": 1.30,
    "grid_alpha": 0.30,
    "border_width": 0.8,
}

COLORS = ("#4C78A8", "#F58518", "#54A24B", "#E45756")
HATCHES = ("", "//", "..", "xx")


def _number(value: object) -> float:
    try:
        return float(str(value).strip() or "0")
    except (TypeError, ValueError):
        return 0.0


def _counter_csvs(matrix: Path, role: str) -> list[Path]:
    return sorted(matrix.glob(f"runs/{role}/rep*/*/details/*_greenquic_counters.csv"))


def load_averages(matrix: Path) -> tuple[dict, list[dict[str, object]]]:
    values = {
        role: {mode: defaultdict(list) for mode in MODES}
        for role in ROLES
    }
    seen_runs = {
        role: {mode: 0 for mode in MODES}
        for role in ROLES
    }
    all_fields = [name for name, _ in CUBIC_FIELDS + FREQ_FIELDS]

    for role in ROLES:
        files = _counter_csvs(matrix, role)
        if not files:
            raise SystemExit(f"ERROR: no GreenQUIC counter CSVs found for {role}: {matrix}")
        for path in files:
            with path.open(newline="", encoding="utf-8") as handle:
                rows = list(csv.DictReader(handle))
            if len(rows) != 1:
                raise SystemExit(f"ERROR: expected exactly one row in {path}, found {len(rows)}")
            row = rows[0]
            mode = str(row.get("mode", "")).strip().lower()
            if mode not in MODES:
                raise SystemExit(f"ERROR: invalid/missing mode in {path}: {mode!r}")
            seen_runs[role][mode] += 1
            for field in all_fields:
                values[role][mode][field].append(_number(row.get(field, 0)))

        missing = [mode for mode in MODES if seen_runs[role][mode] == 0]
        if missing:
            raise SystemExit(
                f"ERROR: {role} matrix is missing counter CSVs for mode(s): {', '.join(missing)}"
            )

    averages = {
        role: {mode: {} for mode in MODES}
        for role in ROLES
    }
    summary_rows = []
    for role in ROLES:
        for mode in MODES:
            for field in all_fields:
                series = values[role][mode][field]
                averages[role][mode][field] = mean(series) if series else 0.0
            summary_rows.append({
                "role": role,
                "mode": mode,
                "repetitions": seen_runs[role][mode],
                **averages[role][mode],
            })
    return averages, summary_rows


def grouped_offsets(count: int, width: float, gap: float) -> list[float]:
    step = width + gap
    center = (count - 1) / 2.0
    return [(i - center) * step for i in range(count)]


def _format_count(value: float) -> str:
    if not math.isfinite(value):
        return "0"
    if abs(value - round(value)) < 1e-9:
        return str(int(round(value)))
    return f"{value:.1f}"


def draw_grouped_chart(matrix: Path, averages: dict, role: str, fields, title: str, stem: str):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import matplotlib.ticker as mticker
    import numpy as np
    from matplotlib.patches import Patch

    svg_dir = matrix / "tables" / "charts" / "counter_histograms" / "svg"
    pdf_dir = matrix / "tables" / "charts" / "counter_histograms" / "pdf"
    svg_dir.mkdir(parents=True, exist_ok=True)
    pdf_dir.mkdir(parents=True, exist_ok=True)

    x = np.arange(len(MODES), dtype=float) * STYLE["case_spacing"]
    offsets = grouped_offsets(len(fields), STYLE["bar_width"], STYLE["bar_gap"])
    all_values = [averages[role][mode][field] for mode in MODES for field, _ in fields]
    highest = max([0.0, *all_values])
    normal_top = highest if highest > 0 else 1.0
    y_top = max(1.2, normal_top * STYLE["headroom_factor"])

    fig = plt.figure(figsize=(STYLE["figure_width"], STYLE["figure_height"]))
    ax = fig.add_axes([
        STYLE["plot_left"], STYLE["plot_bottom"],
        STYLE["plot_width"], STYLE["plot_height"],
    ])

    for idx, (field, label) in enumerate(fields):
        series = [averages[role][mode][field] for mode in MODES]
        bars = ax.bar(
            x + offsets[idx], series,
            width=STYLE["bar_width"],
            color=COLORS[idx],
            hatch=HATCHES[idx],
            edgecolor="black",
            linewidth=0.25,
            label=label,
        )
        for bar, value in zip(bars, series):
            ax.text(
                bar.get_x() + bar.get_width() / 2.0,
                value + y_top * 0.008,
                _format_count(value),
                ha="center", va="bottom",
                fontsize=STYLE["value_size"],
            )

    ax.set_ylim(0, y_top)
    ax.set_ylabel("Mean count per repetition", fontsize=STYLE["axis_label_size"])
    ax.set_xticks(x, [mode.upper() for mode in MODES])
    ax.tick_params(axis="x", labelsize=STYLE["x_tick_size"], pad=8)
    ax.tick_params(axis="y", labelsize=STYLE["y_tick_size"])
    ax.yaxis.set_major_locator(mticker.MaxNLocator(nbins=8, integer=True))
    ax.grid(axis="y", alpha=STYLE["grid_alpha"], linewidth=0.7, linestyle="-")
    ax.set_axisbelow(True)
    for spine in ax.spines.values():
        spine.set_linewidth(STYLE["border_width"])
        spine.set_color("black")

    fig.suptitle(title, y=0.95, fontsize=STYLE["title_size"], fontweight="normal")
    handles = [
        Patch(facecolor=COLORS[i], hatch=HATCHES[i], edgecolor="black", label=label)
        for i, (_field, label) in enumerate(fields)
    ]
    fig.legend(
        handles=handles,
        loc="center left",
        bbox_to_anchor=(0.805, 0.52),
        frameon=True,
        ncol=1,
        fontsize=STYLE["legend_size"],
    )
    fig.text(
        0.44, 0.065,
        "OFF / BASIC / PLUS for this matrix only; bars are means across its repetitions.",
        ha="center", va="center", fontsize=10,
    )

    svg = svg_dir / f"{stem}.svg"
    pdf = pdf_dir / f"{stem}.pdf"
    fig.savefig(svg, format="svg", dpi=300)
    fig.savefig(pdf, format="pdf", dpi=300)
    plt.close(fig)
    return pdf, svg


def write_summary_csv(matrix: Path, rows) -> Path:
    path = matrix / "tables" / "counter_histogram_averages.csv"
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "role", "mode", "repetitions",
        *[name for name, _ in CUBIC_FIELDS],
        *[name for name, _ in FREQ_FIELDS],
    ]
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)
    return path


def render(matrix: Path) -> list[Path]:
    matrix = matrix.resolve()
    averages, rows = load_averages(matrix)
    outputs = [write_summary_csv(matrix, rows)]
    specs = (
        ("client", CUBIC_FIELDS, "P5 Client CUBIC Hint Counts", "p5_client_cubic_hint_counts"),
        ("server", CUBIC_FIELDS, "P5 Server CUBIC Hint Counts", "p5_server_cubic_hint_counts"),
        ("client", FREQ_FIELDS, "P5 Client Frequency-Action Counts", "p5_client_frequency_action_counts"),
        ("server", FREQ_FIELDS, "P5 Server Frequency-Action Counts", "p5_server_frequency_action_counts"),
    )
    for role, fields, title, stem in specs:
        pdf, svg = draw_grouped_chart(matrix, averages, role, fields, title, stem)
        outputs.extend((pdf, svg))
    print("[P5] Additional counter histograms generated: 4 charts / 8 vector files")
    for path in outputs:
        print(f"[P5] counter-chart output: {path}")
    return outputs


def self_test() -> int:
    fields = [name for name, _ in CUBIC_FIELDS + FREQ_FIELDS]
    with tempfile.TemporaryDirectory(prefix="p5_counter_hist_selftest_") as td:
        matrix = Path(td) / "matrix"
        for role in ROLES:
            for rep in (1, 2):
                for mode in MODES:
                    details = matrix / "runs" / role / f"rep{rep:02d}" / mode / "details"
                    details.mkdir(parents=True, exist_ok=True)
                    row = {
                        "schema": "greenquic-counters-csv-v1",
                        "source": "off_shell_baseline" if mode == "off" else "process_end_counters",
                        "mode": mode,
                    }
                    for i, field in enumerate(fields, start=1):
                        row[field] = 0 if mode == "off" else i * rep * (1 if mode == "basic" else 2)
                    path = details / f"{role}_{mode}_greenquic_counters.csv"
                    with path.open("w", newline="", encoding="utf-8") as handle:
                        writer = csv.DictWriter(handle, fieldnames=list(row))
                        writer.writeheader()
                        writer.writerow(row)
        outputs = render(matrix)
        missing = [str(p) for p in outputs if not p.is_file() or p.stat().st_size == 0]
        if missing:
            raise SystemExit("ERROR: self-test output missing/empty: " + ", ".join(missing))
        if len([p for p in outputs if p.suffix == ".pdf"]) != 4:
            raise SystemExit("ERROR: self-test did not create four PDFs")
        if len([p for p in outputs if p.suffix == ".svg"]) != 4:
            raise SystemExit("ERROR: self-test did not create four SVGs")
    print("[P5] counter histogram self-test: PASS")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--matrix", type=Path)
    group.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    render(args.matrix)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
