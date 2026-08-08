#!/usr/bin/env python3
# GREENQUIC-SINGLE-RUN-CHARTS-V1
"""Large single-matrix GreenQUIC comparison charts.

Existing charts are not modified. For one finalized matrix this script creates
six additional figures, each comparing OFF/BASIC/PLUS for that matrix only:

  1. Client QUIC-side hint counts
  2. Server QUIC-side hint counts
  3. Client frequency-action counts
  4. Server frequency-action counts
  5. Client DPDK RX/TX packet counts
  6. Server DPDK RX/TX packet counts

Every figure is exported twice:
  * with_values/    -> numeric values above bars
  * without_values/ -> identical chart without bar-value labels

Style follows the user's P4 guide: large vector figures, visible horizontal grid,
thin black plot border, legend fully outside the plot border, normal-weight text,
OFF/BASIC/PLUS spacing, and y-axis maximum fixed to 1.20 * the largest bar.
"""
from __future__ import annotations

import argparse
import csv
import math
import re
import tempfile
from collections import defaultdict
from pathlib import Path
from statistics import mean

MODES = ("off", "basic", "plus")
ROLES = ("client", "server")

QUIC_FIELDS = (
    ("hint_ack_pending", "ACK pending"),
    ("hint_cubic_cwnd_blocked", "CUBIC CWND blocked"),
    ("hint_cubic_recovery", "CUBIC recovery begin"),
    ("hint_cubic_recovery_end", "CUBIC recovery end"),
    ("hint_cubic_ramping", "CUBIC ramping"),
    ("hint_server_file_tx_active", "Server file TX begin"),
    ("hint_server_file_tx_end", "Server file TX end"),
    ("hint_client_file_rx_active", "Client file RX begin"),
    ("hint_client_file_rx_end", "Client file RX end"),
)

FREQ_FIELDS = (
    ("freq_policy_up", "freq_up"),
    ("freq_policy_down", "freq_down"),
    ("freq_policy_min", "freq_min"),
    ("freq_policy_max_hard", "freq_max_hard"),
)

PACKET_FIELDS = (
    ("rx_packets", "RX packets"),
    ("tx_packets", "TX packets"),
)

# Large typography. The reference guide used 18/12/11/10; these are enlarged
# deliberately because these are standalone publication-size figures.
STYLE = {
    "font_family": "DejaVu Sans",
    "title_size": 24,
    "axis_label_size": 20,
    "x_tick_size": 18,
    "y_tick_size": 18,
    "legend_size": 16,
    "value_size": 14,
    "figure_width": 16.0,
    "figure_height": 9.5,
    "plot_left": 0.09,
    "plot_bottom": 0.16,
    "plot_width": 0.64,
    "plot_height": 0.70,
    "title_y": 0.955,
    "legend_x": 0.755,
    "legend_y": 0.52,
    "headroom_factor": 1.20,
    "case_spacing": 1.45,
    "grid_alpha": 0.35,
    "grid_linewidth": 0.9,
    "border_width": 1.0,
    "tick_pad": 10,
    "pdf_dpi": 300,
    "svg_dpi": 300,
}

SERIES_COLORS = (
    "#4C78A8", "#F58518", "#54A24B", "#E45756", "#72B7B2",
    "#B279A2", "#FF9DA6", "#9D755D", "#BAB0AC",
)
SERIES_HATCHES = ("", "//", "..", "xx", "\\\\", "++", "oo", "--", "**")

PACKET_RE = re.compile(
    r"GreenQUIC PACKETS\s+source=(?P<source>[^\s]+)\s+"
    r"rx_pkts=(?P<rx>\d+)\s+tx_pkts=(?P<tx>\d+)"
)


def _number(value: object) -> float:
    try:
        result = float(str(value).strip() or "0")
    except (TypeError, ValueError):
        return 0.0
    return result if math.isfinite(result) else 0.0


def _counter_csvs(matrix: Path, role: str) -> list[Path]:
    return sorted(matrix.glob(f"runs/{role}/rep*/*/details/*_greenquic_counters.csv"))


def _mode_from_path_or_row(path: Path, row: dict[str, str]) -> str:
    mode = str(row.get("mode", "")).strip().lower()
    if mode in MODES:
        return mode
    lower = str(path).lower()
    for candidate in MODES:
        if f"/{candidate}/" in lower or f"_{candidate}_" in lower:
            return candidate
    raise SystemExit(f"ERROR: cannot determine mode for {path}")


def load_counter_averages(matrix: Path) -> tuple[dict, dict]:
    values = {
        role: {mode: defaultdict(list) for mode in MODES}
        for role in ROLES
    }
    seen = {role: {mode: 0 for mode in MODES} for role in ROLES}
    fields = [name for name, _ in QUIC_FIELDS + FREQ_FIELDS]

    for role in ROLES:
        files = _counter_csvs(matrix, role)
        if not files:
            raise SystemExit(f"ERROR: no GreenQUIC counter CSVs found for {role}: {matrix}")
        for path in files:
            with path.open(newline="", encoding="utf-8") as handle:
                row = next(csv.DictReader(handle), None)
            if row is None:
                raise SystemExit(f"ERROR: empty counter CSV: {path}")
            mode = _mode_from_path_or_row(path, row)
            seen[role][mode] += 1
            for field in fields:
                values[role][mode][field].append(_number(row.get(field, 0)))

        missing = [mode for mode in MODES if seen[role][mode] == 0]
        if missing:
            raise SystemExit(
                f"ERROR: {role} matrix missing counter CSVs for: {', '.join(missing)}"
            )

    averages = {role: {mode: {} for mode in MODES} for role in ROLES}
    for role in ROLES:
        for mode in MODES:
            for field in fields:
                series = values[role][mode][field]
                averages[role][mode][field] = mean(series) if series else 0.0
    return averages, seen


def _candidate_logs(matrix: Path, role: str, mode: str) -> list[Path]:
    paths = []
    paths.extend(matrix.glob(f"runs/{role}/rep*/*/details/*_log.txt"))
    paths.extend(matrix.glob(f"{role}_rep*_{mode}.log"))
    paths.extend(matrix.glob(f"{role}_rep*_{mode}_timestamped.log"))
    filtered = []
    for path in paths:
        lower = str(path).lower()
        if f"/{mode}/" in lower or f"_{mode}_" in lower:
            filtered.append(path)
    return sorted(set(filtered))


def _last_packet_row(path: Path) -> tuple[int, int] | None:
    text = path.read_text(encoding="utf-8", errors="replace")
    matches = list(PACKET_RE.finditer(text))
    if not matches:
        return None
    match = matches[-1]
    return int(match.group("rx")), int(match.group("tx"))


def load_packet_averages(matrix: Path) -> tuple[dict, dict]:
    packet_values = {
        role: {mode: {"rx_packets": [], "tx_packets": []} for mode in MODES}
        for role in ROLES
    }
    packet_seen = {role: {mode: 0 for mode in MODES} for role in ROLES}

    for role in ROLES:
        for mode in MODES:
            for path in _candidate_logs(matrix, role, mode):
                row = _last_packet_row(path)
                if row is None:
                    continue
                rx, tx = row
                packet_values[role][mode]["rx_packets"].append(float(rx))
                packet_values[role][mode]["tx_packets"].append(float(tx))
                packet_seen[role][mode] += 1

            if packet_seen[role][mode] == 0:
                raise SystemExit(
                    f"ERROR: no process-end GreenQUIC PACKETS row found for {role}/{mode}. "
                    "Rebuild the P5 binaries so GREENQUIC-P5-DATAPATH-PACKET-TOTALS-V1 "
                    "is present, then rerun the matrix."
                )

    averages = {role: {mode: {} for mode in MODES} for role in ROLES}
    for role in ROLES:
        for mode in MODES:
            averages[role][mode]["rx_packets"] = mean(
                packet_values[role][mode]["rx_packets"]
            )
            averages[role][mode]["tx_packets"] = mean(
                packet_values[role][mode]["tx_packets"]
            )
    return averages, packet_seen


def _format_count(value: float) -> str:
    if abs(value - round(value)) < 1e-9:
        return f"{int(round(value)):,}"
    return f"{value:,.1f}"


def _grouped_offsets(count: int, width: float, gap: float) -> list[float]:
    step = width + gap
    center = (count - 1) / 2.0
    return [(index - center) * step for index in range(count)]


def _bar_geometry(series_count: int) -> tuple[float, float]:
    if series_count >= 8:
        return 0.075, 0.018
    if series_count >= 4:
        return 0.13, 0.035
    return 0.24, 0.08


def draw_chart(
    matrix: Path,
    averages: dict,
    role: str,
    fields,
    title: str,
    stem: str,
    show_values: bool,
) -> tuple[Path, Path]:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import matplotlib.ticker as mticker
    import numpy as np
    from matplotlib.patches import Patch

    plt.rcParams["font.family"] = STYLE["font_family"]
    plt.rcParams["font.weight"] = "normal"

    variant = "with_values" if show_values else "without_values"
    root = matrix / "tables" / "charts" / "single_run_comparison" / variant
    pdf_dir = root / "pdf"
    svg_dir = root / "svg"
    pdf_dir.mkdir(parents=True, exist_ok=True)
    svg_dir.mkdir(parents=True, exist_ok=True)

    x = np.arange(len(MODES), dtype=float) * STYLE["case_spacing"]
    bar_width, bar_gap = _bar_geometry(len(fields))
    offsets = _grouped_offsets(len(fields), bar_width, bar_gap)

    all_values = [
        float(averages[role][mode][field])
        for mode in MODES
        for field, _ in fields
    ]
    highest = max([0.0, *all_values])
    # User requirement: y-axis top is exactly 1.20x the largest plotted value.
    y_top = highest * STYLE["headroom_factor"] if highest > 0 else 1.2

    fig = plt.figure(figsize=(STYLE["figure_width"], STYLE["figure_height"]))
    ax = fig.add_axes([
        STYLE["plot_left"],
        STYLE["plot_bottom"],
        STYLE["plot_width"],
        STYLE["plot_height"],
    ])

    for index, (field, label) in enumerate(fields):
        series = [float(averages[role][mode][field]) for mode in MODES]
        bars = ax.bar(
            x + offsets[index],
            series,
            width=bar_width,
            color=SERIES_COLORS[index],
            hatch=SERIES_HATCHES[index],
            edgecolor="black",
            linewidth=0.35,
            label=label,
        )
        if show_values:
            for bar, value in zip(bars, series):
                ax.text(
                    bar.get_x() + bar.get_width() / 2.0,
                    value + y_top * 0.012,
                    _format_count(value),
                    ha="center",
                    va="bottom",
                    fontsize=STYLE["value_size"],
                    rotation=90 if len(fields) >= 8 else 0,
                    fontweight="normal",
                    clip_on=False,
                )

    ax.set_ylim(0, y_top)
    ax.set_ylabel("Mean count per repetition", fontsize=STYLE["axis_label_size"])
    ax.set_xticks(x, [mode.upper() for mode in MODES])
    ax.tick_params(
        axis="x",
        labelsize=STYLE["x_tick_size"],
        pad=STYLE["tick_pad"],
    )
    ax.tick_params(axis="y", labelsize=STYLE["y_tick_size"])
    ax.yaxis.set_major_locator(mticker.MaxNLocator(nbins=8, integer=True))
    ax.grid(
        axis="y",
        visible=True,
        alpha=STYLE["grid_alpha"],
        linewidth=STYLE["grid_linewidth"],
        linestyle="-",
    )
    ax.set_axisbelow(True)

    for spine in ax.spines.values():
        spine.set_linewidth(STYLE["border_width"])
        spine.set_color("black")

    fig.suptitle(
        title,
        y=STYLE["title_y"],
        fontsize=STYLE["title_size"],
        fontweight="normal",
    )

    handles = [
        Patch(
            facecolor=SERIES_COLORS[index],
            hatch=SERIES_HATCHES[index],
            edgecolor="black",
            label=label,
        )
        for index, (_field, label) in enumerate(fields)
    ]
    # Legend is deliberately in reserved figure space, fully outside axes border.
    fig.legend(
        handles=handles,
        loc="center left",
        bbox_to_anchor=(STYLE["legend_x"], STYLE["legend_y"]),
        frameon=True,
        ncol=1,
        fontsize=STYLE["legend_size"],
        borderaxespad=0.0,
    )

    pdf = pdf_dir / f"{stem}.pdf"
    svg = svg_dir / f"{stem}.svg"
    fig.savefig(pdf, format="pdf", dpi=STYLE["pdf_dpi"])
    fig.savefig(svg, format="svg", dpi=STYLE["svg_dpi"])
    plt.close(fig)
    return pdf, svg


def write_summary_csv(
    matrix: Path,
    counters: dict,
    counter_seen: dict,
    packets: dict,
    packet_seen: dict,
) -> Path:
    output = matrix / "tables" / "single_run_comparison_averages.csv"
    fields = [name for name, _ in QUIC_FIELDS + FREQ_FIELDS]
    columns = [
        "role", "mode", "counter_repetitions", "packet_repetitions",
        *fields, "rx_packets", "tx_packets",
    ]
    rows = []
    for role in ROLES:
        for mode in MODES:
            rows.append({
                "role": role,
                "mode": mode,
                "counter_repetitions": counter_seen[role][mode],
                "packet_repetitions": packet_seen[role][mode],
                **counters[role][mode],
                **packets[role][mode],
            })
    with output.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)
    return output


def render(matrix: Path) -> list[Path]:
    matrix = matrix.resolve()
    counters, counter_seen = load_counter_averages(matrix)
    packets, packet_seen = load_packet_averages(matrix)

    outputs = [
        write_summary_csv(matrix, counters, counter_seen, packets, packet_seen)
    ]

    specs = (
        (counters, "client", QUIC_FIELDS, "Client QUIC Hint Counts", "client_quic_hint_counts"),
        (counters, "server", QUIC_FIELDS, "Server QUIC Hint Counts", "server_quic_hint_counts"),
        (counters, "client", FREQ_FIELDS, "Client Frequency-Action Counts", "client_frequency_action_counts"),
        (counters, "server", FREQ_FIELDS, "Server Frequency-Action Counts", "server_frequency_action_counts"),
        (packets, "client", PACKET_FIELDS, "Client DPDK Packet Counts", "client_dpdk_packet_counts"),
        (packets, "server", PACKET_FIELDS, "Server DPDK Packet Counts", "server_dpdk_packet_counts"),
    )

    for show_values in (True, False):
        for averages, role, fields, title, stem in specs:
            pdf, svg = draw_chart(
                matrix, averages, role, fields, title, stem, show_values
            )
            outputs.extend((pdf, svg))

    print("[GreenQUIC] Single-run comparison charts generated")
    print("[GreenQUIC] charts=6 variants=2 vector_files=24")
    print(
        "[GreenQUIC] with values: "
        f"{matrix / 'tables/charts/single_run_comparison/with_values'}"
    )
    print(
        "[GreenQUIC] without values: "
        f"{matrix / 'tables/charts/single_run_comparison/without_values'}"
    )
    return outputs


def self_test() -> int:
    all_counter_fields = [name for name, _ in QUIC_FIELDS + FREQ_FIELDS]
    with tempfile.TemporaryDirectory(prefix="greenquic_single_run_charts_") as td:
        matrix = Path(td) / "matrix"
        for role in ROLES:
            for repetition in (1, 2):
                for mode in MODES:
                    details = (
                        matrix / "runs" / role / f"rep{repetition:02d}" / mode / "details"
                    )
                    details.mkdir(parents=True, exist_ok=True)
                    row = {
                        "schema": "greenquic-counters-csv-v1",
                        "source": "off_shell_baseline" if mode == "off" else "process_end_counters",
                        "mode": mode,
                    }
                    for index, field in enumerate(all_counter_fields, start=1):
                        multiplier = 0 if mode == "off" else (1 if mode == "basic" else 2)
                        row[field] = index * repetition * multiplier
                    csv_path = details / f"{role}_{mode}_greenquic_counters.csv"
                    with csv_path.open("w", newline="", encoding="utf-8") as handle:
                        writer = csv.DictWriter(handle, fieldnames=list(row))
                        writer.writeheader()
                        writer.writerow(row)

                    base_rx = 18_000_000 if role == "client" else 450_000
                    base_tx = 450_000 if role == "client" else 18_000_000
                    log_path = details / f"{role}_{mode}_log.txt"
                    log_path.write_text(
                        "[CPU 19] GreenQUIC PACKETS source=datapath_totals "
                        f"rx_pkts={base_rx + repetition} tx_pkts={base_tx + repetition}\n",
                        encoding="utf-8",
                    )

        outputs = render(matrix)
        pdfs = [path for path in outputs if path.suffix == ".pdf"]
        svgs = [path for path in outputs if path.suffix == ".svg"]
        if len(pdfs) != 12:
            raise SystemExit(f"ERROR: expected 12 PDFs, found {len(pdfs)}")
        if len(svgs) != 12:
            raise SystemExit(f"ERROR: expected 12 SVGs, found {len(svgs)}")
        missing = [str(path) for path in outputs if not path.is_file() or path.stat().st_size == 0]
        if missing:
            raise SystemExit("ERROR: missing/empty self-test outputs: " + ", ".join(missing))

    print("[GreenQUIC] single-run chart self-test: PASS")
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
