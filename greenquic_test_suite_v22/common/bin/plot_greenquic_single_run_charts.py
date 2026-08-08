#!/usr/bin/env python3
# GREENQUIC-SINGLE-RUN-CHARTS-V2
"""Large single-matrix GreenQUIC comparison charts.

This is additive only. Existing chart files/folders are never modified.
For one finalized matrix it creates the full 22-chart comparison set using
OFF/BASIC/PLUS from that matrix only (no left/right profile split).

Every chart is exported twice:
  * with_values/    -> numeric values above bars
  * without_values/ -> identical chart without bar-value labels

Style follows the supplied P4 guide: large figures and typography, horizontal
grid, thin black axes border, legend fully outside the plot border, normal font
weight, and 20% y-axis headroom above the largest plotted value.
"""
from __future__ import annotations

import argparse
import csv
import json
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
PACKET_FIELDS = (("rx_packets", "RX packets"), ("tx_packets", "TX packets"))

MODE_COLORS = {"off": "#4C78A8", "basic": "#F58518", "plus": "#54A24B"}
SERIES_COLORS = (
    "#4C78A8", "#F58518", "#54A24B", "#E45756", "#72B7B2",
    "#B279A2", "#FF9DA6", "#9D755D", "#BAB0AC",
)
SERIES_HATCHES = ("", "//", "..", "xx", "\\\\", "++", "oo", "--", "**")

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
    "plot_left": 0.085,
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

PACKET_RE = re.compile(
    r"GreenQUIC PACKETS\s+source=(?P<source>[^\s]+)\s+"
    r"rx_pkts=(?P<rx>\d+)\s+tx_pkts=(?P<tx>\d+)"
)
NUMBER_RE = re.compile(r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?")


def _finite(value: object, default: float = 0.0) -> float:
    try:
        result = float(str(value).strip())
    except (TypeError, ValueError):
        return default
    return result if math.isfinite(result) else default


def _first_number(value: object, default: float = 0.0) -> float:
    if value is None:
        return default
    match = NUMBER_RE.search(str(value))
    return float(match.group(0)) if match else default


def _read_csv(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        return []
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def _rows_by_mode(path: Path) -> dict[str, dict[str, str]]:
    rows = {}
    for row in _read_csv(path):
        mode = str(row.get("mode", "")).strip().lower()
        if mode in MODES:
            rows[mode] = row
    return rows


def _role_table_number(row: dict[str, str], exact: str, tokens: tuple[str, ...]) -> float:
    if exact in row:
        return _first_number(row.get(exact), 0.0)
    for key, value in row.items():
        lower = key.lower()
        if all(token in lower for token in tokens):
            return _first_number(value, 0.0)
    return 0.0


def load_core_metrics(matrix: Path) -> tuple[dict, list[int]]:
    tables = matrix / "tables"
    combined = _rows_by_mode(tables / "combined_endpoint_mode_averages.csv")
    client_rows = _rows_by_mode(tables / "client_mode_averages.csv")
    server_rows = _rows_by_mode(tables / "server_mode_averages.csv")

    behavior_rows = _read_csv(tables / "power_management_behavior_mode_averages.csv")
    behavior = {}
    state_ids = set()
    for row in behavior_rows:
        role = str(row.get("role", "")).strip().lower()
        mode = str(row.get("mode", "")).strip().lower()
        if role in ROLES and mode in MODES:
            behavior[(role, mode)] = row
        for key in row:
            match = re.fullmatch(r"cstate_state_(\d+)_residency_s", key)
            if match:
                state_ids.add(int(match.group(1)))

    data = {role: {mode: {} for mode in MODES} for role in ROLES}
    for mode in MODES:
        c = combined.get(mode, {})
        data["client"][mode].update({
            "goodput_excluding_gaps_gbps": _finite(c.get("goodput_excluding_gaps_gbps")),
            "goodput_including_gaps_gbps": _finite(c.get("goodput_including_gaps_gbps")),
            "rapl_average_power_w": _finite(c.get("client_average_power_w")),
            "rapl_energy_per_gib_j": _finite(c.get("client_rapl_j_per_gib")),
        })
        data["server"][mode]["rapl_average_power_w"] = _finite(c.get("server_average_power_w"))

        for role, role_rows in (("client", client_rows), ("server", server_rows)):
            rr = role_rows.get(mode, {})
            data[role][mode]["acpi_average_power_w"] = _role_table_number(
                rr,
                "whole_system_power_and_energy_whole_test__time_weighted_average_power",
                ("whole_system_power", "average_power"),
            )
            b = behavior.get((role, mode), {})
            data[role][mode].update({
                "idle_entries": _finite(b.get("cstate_idle_entries")),
                "freq_min_ghz": _finite(b.get("frequency_min_ghz")),
                "freq_max_ghz": _finite(b.get("frequency_max_ghz")),
                "freq_trace_events": _finite(b.get("frequency_events")),
            })
            for state in sorted(state_ids):
                data[role][mode][f"cstate_{state}"] = _finite(
                    b.get(f"cstate_state_{state}_residency_s")
                )

    return data, sorted(state_ids)


def load_cstate_labels(matrix: Path, role: str, state_ids: list[int]) -> dict[int, str]:
    path = matrix / "configuration" / f"cpuidle_{role}.json"
    mapping = {}
    if path.is_file():
        try:
            obj = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            obj = {}
        states = obj.get("states", {}) if isinstance(obj, dict) else {}
        for state in state_ids:
            row = states.get(str(state), {}) if isinstance(states, dict) else {}
            name = str(row.get("name", "")).strip()
            mapping[state] = name.upper() if name else f"STATE{state}"
    for state in state_ids:
        mapping.setdefault(state, f"STATE{state}")
    return mapping


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
    fields = [name for name, _ in QUIC_FIELDS + FREQ_FIELDS]
    values = {role: {mode: defaultdict(list) for mode in MODES} for role in ROLES}
    seen = {role: {mode: 0 for mode in MODES} for role in ROLES}
    for role in ROLES:
        files = _counter_csvs(matrix, role)
        if not files:
            raise SystemExit(f"ERROR: no GreenQUIC counter CSVs found for {role}: {matrix}")
        for path in files:
            rows = _read_csv(path)
            if not rows:
                raise SystemExit(f"ERROR: empty counter CSV: {path}")
            row = rows[0]
            mode = _mode_from_path_or_row(path, row)
            seen[role][mode] += 1
            for field in fields:
                values[role][mode][field].append(_finite(row.get(field)))
        missing = [mode for mode in MODES if seen[role][mode] == 0]
        if missing:
            raise SystemExit(f"ERROR: {role} missing counter CSVs for: {', '.join(missing)}")
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
    result = []
    for path in paths:
        lower = str(path).lower()
        if f"/{mode}/" in lower or f"_{mode}_" in lower:
            result.append(path)
    return sorted(set(result))


def _last_packet_row(path: Path) -> tuple[int, int] | None:
    matches = list(PACKET_RE.finditer(path.read_text(encoding="utf-8", errors="replace")))
    if not matches:
        return None
    return int(matches[-1].group("rx")), int(matches[-1].group("tx"))


def load_packet_averages(matrix: Path) -> tuple[dict, dict]:
    values = {
        role: {mode: {"rx_packets": [], "tx_packets": []} for mode in MODES}
        for role in ROLES
    }
    seen = {role: {mode: 0 for mode in MODES} for role in ROLES}
    for role in ROLES:
        for mode in MODES:
            for path in _candidate_logs(matrix, role, mode):
                row = _last_packet_row(path)
                if row is None:
                    continue
                rx, tx = row
                values[role][mode]["rx_packets"].append(float(rx))
                values[role][mode]["tx_packets"].append(float(tx))
                seen[role][mode] += 1
            if seen[role][mode] == 0:
                raise SystemExit(
                    f"ERROR: no GreenQUIC PACKETS row for {role}/{mode}; rebuild P5 and rerun."
                )
    averages = {role: {mode: {} for mode in MODES} for role in ROLES}
    for role in ROLES:
        for mode in MODES:
            for field, _ in PACKET_FIELDS:
                averages[role][mode][field] = mean(values[role][mode][field])
    return averages, seen


def _format_value(value: float, decimals: int = 1) -> str:
    if abs(value - round(value)) < 1e-9 and decimals == 0:
        return f"{int(round(value)):,}"
    if value == 0:
        return "0"
    return f"{value:,.{decimals}f}"


def _root(matrix: Path, show_values: bool) -> Path:
    variant = "with_values" if show_values else "without_values"
    return matrix / "tables" / "charts" / "single_run_comparison" / variant


def _new_axis(title: str, ylabel: str):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import numpy as np

    plt.rcParams["font.family"] = STYLE["font_family"]
    plt.rcParams["font.weight"] = "normal"
    fig = plt.figure(figsize=(STYLE["figure_width"], STYLE["figure_height"]), facecolor="white")
    ax = fig.add_axes([
        STYLE["plot_left"], STYLE["plot_bottom"], STYLE["plot_width"], STYLE["plot_height"]
    ])
    for spine in ax.spines.values():
        spine.set_linewidth(STYLE["border_width"])
        spine.set_color("black")
    ax.set_ylabel(ylabel, fontsize=STYLE["axis_label_size"])
    ax.tick_params(axis="x", labelsize=STYLE["x_tick_size"], pad=STYLE["tick_pad"])
    ax.tick_params(axis="y", labelsize=STYLE["y_tick_size"])
    ax.grid(axis="y", visible=True, alpha=STYLE["grid_alpha"],
            linewidth=STYLE["grid_linewidth"], linestyle="-")
    ax.set_axisbelow(True)
    fig.suptitle(title, y=STYLE["title_y"], fontsize=STYLE["title_size"], fontweight="normal")
    x = np.arange(len(MODES), dtype=float) * STYLE["case_spacing"]
    ax.set_xticks(x, [mode.upper() for mode in MODES])
    return fig, ax, x


def _set_y(ax, values: list[float], log: bool = False) -> float:
    finite_values = [float(v) for v in values if math.isfinite(float(v))]
    vmax = max([0.0, *finite_values])
    top = vmax * STYLE["headroom_factor"] if vmax > 0 else 1.2
    if log:
        positive = [v for v in finite_values if v > 0]
        ymin = max(min(positive) / 10.0, 1e-3) if positive else 1e-3
        if top <= ymin:
            top = ymin * 10.0
        ax.set_yscale("log")
        ax.set_ylim(ymin, top)
    else:
        ax.set_ylim(0, top)
    return top


def _legend(fig, handles):
    legend = fig.legend(
        handles=handles,
        loc="center left",
        bbox_to_anchor=(STYLE["legend_x"], STYLE["legend_y"]),
        frameon=True,
        ncol=1,
        fontsize=STYLE["legend_size"],
        borderaxespad=0.0,
    )
    if legend.get_frame() is not None:
        legend.get_frame().set_linewidth(0.8)


def _save(fig, matrix: Path, stem: str, show_values: bool) -> tuple[Path, Path]:
    root = _root(matrix, show_values)
    pdf_dir, svg_dir = root / "pdf", root / "svg"
    pdf_dir.mkdir(parents=True, exist_ok=True)
    svg_dir.mkdir(parents=True, exist_ok=True)
    pdf, svg = pdf_dir / f"{stem}.pdf", svg_dir / f"{stem}.svg"
    fig.savefig(pdf, format="pdf", dpi=STYLE["pdf_dpi"])
    fig.savefig(svg, format="svg", dpi=STYLE["svg_dpi"])
    import matplotlib.pyplot as plt
    plt.close(fig)
    return pdf, svg


def _mode_handles():
    from matplotlib.patches import Patch
    return [Patch(facecolor=MODE_COLORS[m], edgecolor="black", label=m.upper()) for m in MODES]


def _label(ax, x: float, value: float, ytop: float, decimals: int, rotation: int = 0):
    ax.text(
        x, value + ytop * 0.012, _format_value(value, decimals),
        ha="center", va="bottom", fontsize=STYLE["value_size"],
        rotation=rotation, fontweight="normal", clip_on=False,
    )


def plot_simple(matrix: Path, data: dict, role: str, metric: str, title: str,
                ylabel: str, stem: str, show_values: bool, decimals: int = 1,
                log: bool = False) -> tuple[Path, Path]:
    fig, ax, x = _new_axis(title, ylabel)
    values = [float(data[role][mode].get(metric, 0.0)) for mode in MODES]
    ytop = _set_y(ax, values, log=log)
    for xx, mode, value in zip(x, MODES, values):
        plotted = value if not log or value > 0 else ax.get_ylim()[0]
        ax.bar(xx, plotted, width=0.62, color=MODE_COLORS[mode], edgecolor="black", linewidth=0.35)
        if show_values:
            if log and value <= 0:
                ax.text(xx, ax.get_ylim()[0] * 1.25, "0", ha="center", va="bottom",
                        fontsize=STYLE["value_size"])
            else:
                _label(ax, xx, value, ytop, decimals)
    _legend(fig, _mode_handles())
    return _save(fig, matrix, stem, show_values)


def plot_goodput(matrix: Path, data: dict, show_values: bool) -> tuple[Path, Path]:
    from matplotlib.patches import Patch
    fig, ax, x = _new_axis("Client Goodput", "Goodput (Gbit/s)")
    excl = [data["client"][m].get("goodput_excluding_gaps_gbps", 0.0) for m in MODES]
    incl = [data["client"][m].get("goodput_including_gaps_gbps", 0.0) for m in MODES]
    ytop = _set_y(ax, excl + incl)
    width, gap = 0.27, 0.06
    offset = (width + gap) / 2.0
    for xx, mode, a, b in zip(x, MODES, excl, incl):
        ax.bar(xx - offset, a, width=width, color=MODE_COLORS[mode], edgecolor="black", linewidth=0.35)
        ax.bar(xx + offset, b, width=width, color=MODE_COLORS[mode], alpha=0.55,
               hatch="//", edgecolor="black", linewidth=0.35)
        if show_values:
            _label(ax, xx - offset, a, ytop, 2)
            _label(ax, xx + offset, b, ytop, 2)
    handles = _mode_handles() + [
        Patch(facecolor="#bdbdbd", edgecolor="black", label="Excluding gaps"),
        Patch(facecolor="#bdbdbd", alpha=0.55, hatch="//", edgecolor="black", label="Including gaps"),
    ]
    _legend(fig, handles)
    return _save(fig, matrix, "01_client_goodput", show_values)


def _offsets(count: int, width: float, gap: float) -> list[float]:
    step = width + gap
    center = (count - 1) / 2.0
    return [(i - center) * step for i in range(count)]


def plot_grouped(matrix: Path, data: dict, role: str, fields, title: str, ylabel: str,
                 stem: str, show_values: bool, decimals: int = 0) -> tuple[Path, Path]:
    from matplotlib.patches import Patch
    fig, ax, x = _new_axis(title, ylabel)
    count = len(fields)
    if count >= 8:
        width, gap = 0.075, 0.018
    elif count >= 4:
        width, gap = 0.13, 0.035
    else:
        width, gap = 0.24, 0.08
    offsets = _offsets(count, width, gap)
    all_values = [float(data[role][mode].get(field, 0.0)) for mode in MODES for field, _ in fields]
    ytop = _set_y(ax, all_values)
    for i, (field, label) in enumerate(fields):
        values = [float(data[role][mode].get(field, 0.0)) for mode in MODES]
        bars = ax.bar(
            x + offsets[i], values, width=width,
            color=SERIES_COLORS[i % len(SERIES_COLORS)],
            hatch=SERIES_HATCHES[i % len(SERIES_HATCHES)],
            edgecolor="black", linewidth=0.35,
        )
        if show_values:
            rotation = 90 if count >= 4 else 0
            for bar, value in zip(bars, values):
                _label(ax, bar.get_x() + bar.get_width() / 2.0, value, ytop, decimals, rotation)
    handles = [
        Patch(facecolor=SERIES_COLORS[i % len(SERIES_COLORS)],
              hatch=SERIES_HATCHES[i % len(SERIES_HATCHES)], edgecolor="black", label=label)
        for i, (_field, label) in enumerate(fields)
    ]
    _legend(fig, handles)
    return _save(fig, matrix, stem, show_values)


def plot_cstate(matrix: Path, data: dict, role: str, state_ids: list[int],
                state_labels: dict[int, str], stem: str, show_values: bool) -> tuple[Path, Path]:
    fields = tuple((f"cstate_{state}", state_labels[state]) for state in state_ids)
    title = f"{role.title()} C-State Residency"
    return plot_grouped(matrix, data, role, fields, title, "Residency (s)", stem, show_values, 3)


def plot_frequency_range(matrix: Path, data: dict, role: str, stem: str,
                         show_values: bool) -> tuple[Path, Path]:
    from matplotlib.patches import Patch
    fig, ax, x = _new_axis(f"{role.title()} Observed CPU-Frequency Range", "Frequency (GHz)")
    mins = [data[role][m].get("freq_min_ghz", 0.0) for m in MODES]
    maxs = [data[role][m].get("freq_max_ghz", 0.0) for m in MODES]
    ytop = _set_y(ax, mins + maxs)
    width, gap = 0.27, 0.10
    offsets = _offsets(2, width, gap)
    for xx, mode, mn, mx in zip(x, MODES, mins, maxs):
        ax.bar(xx + offsets[0], mn, width=width, color=MODE_COLORS[mode], alpha=0.45,
               edgecolor="black", linewidth=0.35)
        ax.bar(xx + offsets[1], mx, width=width, color=MODE_COLORS[mode], alpha=1.0,
               edgecolor="black", linewidth=0.35)
        if show_values:
            _label(ax, xx + offsets[0], mn, ytop, 3)
            _label(ax, xx + offsets[1], mx, ytop, 3)
    handles = _mode_handles() + [
        Patch(facecolor="#8c8c8c", alpha=0.45, label="Minimum"),
        Patch(facecolor="#8c8c8c", alpha=1.0, label="Maximum"),
    ]
    _legend(fig, handles)
    return _save(fig, matrix, stem, show_values)


def add_counter_metrics(data: dict, counters: dict):
    for role in ROLES:
        for mode in MODES:
            for field, _ in QUIC_FIELDS + FREQ_FIELDS:
                data[role][mode][field] = float(counters[role][mode].get(field, 0.0))
            data[role][mode]["total_frequency_actions"] = sum(
                float(counters[role][mode].get(field, 0.0)) for field, _ in FREQ_FIELDS
            )


def add_packet_metrics(data: dict, packets: dict):
    for role in ROLES:
        for mode in MODES:
            for field, _ in PACKET_FIELDS:
                data[role][mode][field] = float(packets[role][mode].get(field, 0.0))


def write_summary_csv(matrix: Path, data: dict, counter_seen: dict, packet_seen: dict) -> Path:
    path = matrix / "tables" / "single_run_comparison_averages.csv"
    metric_keys = sorted({key for role in ROLES for mode in MODES for key in data[role][mode]})
    columns = ["role", "mode", "counter_repetitions", "packet_repetitions", *metric_keys]
    rows = []
    for role in ROLES:
        for mode in MODES:
            rows.append({
                "role": role, "mode": mode,
                "counter_repetitions": counter_seen[role][mode],
                "packet_repetitions": packet_seen[role][mode],
                **data[role][mode],
            })
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns, extrasaction="ignore")
        writer.writeheader(); writer.writerows(rows)
    return path


def render(matrix: Path) -> list[Path]:
    matrix = matrix.resolve()
    data, state_ids = load_core_metrics(matrix)
    counters, counter_seen = load_counter_averages(matrix)
    packets, packet_seen = load_packet_averages(matrix)
    add_counter_metrics(data, counters)
    add_packet_metrics(data, packets)

    state_labels = {
        role: load_cstate_labels(matrix, role, state_ids)
        for role in ROLES
    }

    outputs = [write_summary_csv(matrix, data, counter_seen, packet_seen)]
    for show_values in (True, False):
        outputs.extend(plot_goodput(matrix, data, show_values))
        outputs.extend(plot_simple(matrix, data, "client", "rapl_average_power_w",
            "Client RAPL Average Power", "Package + DRAM power (W)",
            "02_client_rapl_average_power", show_values, 1))
        outputs.extend(plot_simple(matrix, data, "client", "rapl_energy_per_gib_j",
            "Client RAPL Energy Efficiency", "RAPL energy (J/GiB)",
            "03_client_rapl_energy_per_gib", show_values, 1))
        outputs.extend(plot_simple(matrix, data, "client", "acpi_average_power_w",
            "Client ACPI Average Power", "Board / ACPI power (W)",
            "04_client_acpi_average_power", show_values, 1))
        outputs.extend(plot_simple(matrix, data, "client", "idle_entries",
            "Client Linux Idle Entries", "CPU-idle entries / averaged run",
            "05_client_linux_idle_entries", show_values, 0, log=True))
        outputs.extend(plot_cstate(matrix, data, "client", state_ids, state_labels["client"],
            "06_client_cstate_residency", show_values))
        outputs.extend(plot_frequency_range(matrix, data, "client",
            "07_client_cpu_frequency_range", show_values))
        outputs.extend(plot_grouped(matrix, data, "client", FREQ_FIELDS,
            "Client Frequency-Action Counts", "Action count",
            "08_client_frequency_action_counts", show_values, 0))
        outputs.extend(plot_simple(matrix, data, "client", "total_frequency_actions",
            "Client Total Frequency Actions", "Total action count",
            "09_client_total_frequency_actions", show_values, 0))
        outputs.extend(plot_simple(matrix, data, "client", "freq_trace_events",
            "Client Total Frequency Trace Events", "Timestamped frequency events",
            "10_client_total_frequency_events", show_values, 0))

        outputs.extend(plot_simple(matrix, data, "server", "rapl_average_power_w",
            "Server RAPL Average Power", "Package + DRAM power (W)",
            "11_server_rapl_average_power", show_values, 1))
        outputs.extend(plot_simple(matrix, data, "server", "acpi_average_power_w",
            "Server ACPI Average Power", "Board / ACPI power (W)",
            "12_server_acpi_average_power", show_values, 1))
        outputs.extend(plot_simple(matrix, data, "server", "idle_entries",
            "Server Linux Idle Entries", "CPU-idle entries / averaged run",
            "13_server_linux_idle_entries", show_values, 0, log=True))
        outputs.extend(plot_cstate(matrix, data, "server", state_ids, state_labels["server"],
            "14_server_cstate_residency", show_values))
        outputs.extend(plot_frequency_range(matrix, data, "server",
            "15_server_cpu_frequency_range", show_values))
        outputs.extend(plot_grouped(matrix, data, "server", FREQ_FIELDS,
            "Server Frequency-Action Counts", "Action count",
            "16_server_frequency_action_counts", show_values, 0))
        outputs.extend(plot_simple(matrix, data, "server", "total_frequency_actions",
            "Server Total Frequency Actions", "Total action count",
            "17_server_total_frequency_actions", show_values, 0))
        outputs.extend(plot_simple(matrix, data, "server", "freq_trace_events",
            "Server Total Frequency Trace Events", "Timestamped frequency events",
            "18_server_total_frequency_events", show_values, 0))

        outputs.extend(plot_grouped(matrix, data, "client", QUIC_FIELDS,
            "Client QUIC Hint Counts", "Mean count per repetition",
            "19_client_quic_hint_counts", show_values, 0))
        outputs.extend(plot_grouped(matrix, data, "server", QUIC_FIELDS,
            "Server QUIC Hint Counts", "Mean count per repetition",
            "20_server_quic_hint_counts", show_values, 0))
        outputs.extend(plot_grouped(matrix, data, "client", PACKET_FIELDS,
            "Client DPDK Packet Counts", "Mean packet count per repetition",
            "21_client_dpdk_packet_counts", show_values, 0))
        outputs.extend(plot_grouped(matrix, data, "server", PACKET_FIELDS,
            "Server DPDK Packet Counts", "Mean packet count per repetition",
            "22_server_dpdk_packet_counts", show_values, 0))

    print("[GreenQUIC] Full single-run comparison chart set generated")
    print("[GreenQUIC] charts=22 variants=2 pdf=44 svg=44 vector_files=88")
    print(f"[GreenQUIC] with values: {_root(matrix, True)}")
    print(f"[GreenQUIC] without values: {_root(matrix, False)}")
    return outputs


def self_test() -> int:
    counter_fields = [name for name, _ in QUIC_FIELDS + FREQ_FIELDS]
    with tempfile.TemporaryDirectory(prefix="greenquic_single_run_charts_v2_") as td:
        matrix = Path(td) / "matrix"
        tables = matrix / "tables"
        config = matrix / "configuration"
        tables.mkdir(parents=True); config.mkdir(parents=True)

        combined_fields = [
            "mode", "goodput_excluding_gaps_gbps", "goodput_including_gaps_gbps",
            "client_average_power_w", "server_average_power_w", "client_rapl_j_per_gib",
        ]
        with (tables / "combined_endpoint_mode_averages.csv").open("w", newline="") as h:
            w = csv.DictWriter(h, fieldnames=combined_fields); w.writeheader()
            for i, mode in enumerate(MODES, 1):
                w.writerow({"mode": mode, "goodput_excluding_gaps_gbps": 8.0-i*.2,
                    "goodput_including_gaps_gbps": 5.5-i*.1, "client_average_power_w": 100-i*3,
                    "server_average_power_w": 120-i*2, "client_rapl_j_per_gib": 180-i*4})

        role_field = "whole_system_power_and_energy_whole_test__time_weighted_average_power"
        for role in ROLES:
            with (tables / f"{role}_mode_averages.csv").open("w", newline="") as h:
                w = csv.DictWriter(h, fieldnames=["mode", role_field]); w.writeheader()
                for i, mode in enumerate(MODES, 1): w.writerow({"mode": mode, role_field: 190-i*4})

        behavior_fields = ["role", "mode", "cstate_idle_entries", "frequency_min_ghz",
                           "frequency_max_ghz", "frequency_events"]
        for state in range(4): behavior_fields.append(f"cstate_state_{state}_residency_s")
        with (tables / "power_management_behavior_mode_averages.csv").open("w", newline="") as h:
            w = csv.DictWriter(h, fieldnames=behavior_fields); w.writeheader()
            for role in ROLES:
                for i, mode in enumerate(MODES, 1):
                    row = {"role": role, "mode": mode, "cstate_idle_entries": i*1000,
                           "frequency_min_ghz": .8, "frequency_max_ghz": 3.6,
                           "frequency_events": i*1500}
                    for state in range(4): row[f"cstate_state_{state}_residency_s"] = i*(state+1)*.5
                    w.writerow(row)

        mapping = {"states": {str(i): {"name": name} for i, name in enumerate(("POLL", "C1", "C1E", "C6"))}}
        for role in ROLES:
            (config / f"cpuidle_{role}.json").write_text(json.dumps(mapping), encoding="utf-8")

        for role in ROLES:
            for repetition in (1, 2):
                for mode in MODES:
                    details = matrix / "runs" / role / f"rep{repetition:02d}" / mode / "details"
                    details.mkdir(parents=True, exist_ok=True)
                    row = {"mode": mode}
                    mult = 0 if mode == "off" else (1 if mode == "basic" else 2)
                    for j, field in enumerate(counter_fields, 1): row[field] = j*repetition*mult
                    with (details / f"{role}_{mode}_greenquic_counters.csv").open("w", newline="") as h:
                        w = csv.DictWriter(h, fieldnames=list(row)); w.writeheader(); w.writerow(row)
                    rx = (18_000_000 if role == "client" else 450_000) + repetition
                    tx = (450_000 if role == "client" else 18_000_000) + repetition
                    (details / f"{role}_{mode}_log.txt").write_text(
                        f"GreenQUIC PACKETS source=datapath_totals rx_pkts={rx} tx_pkts={tx}\n",
                        encoding="utf-8")

        outputs = render(matrix)
        pdfs = [p for p in outputs if p.suffix == ".pdf"]
        svgs = [p for p in outputs if p.suffix == ".svg"]
        if len(pdfs) != 44: raise SystemExit(f"ERROR: expected 44 PDFs, found {len(pdfs)}")
        if len(svgs) != 44: raise SystemExit(f"ERROR: expected 44 SVGs, found {len(svgs)}")
        missing = [str(p) for p in outputs if not p.is_file() or p.stat().st_size == 0]
        if missing: raise SystemExit("ERROR: missing/empty self-test outputs: " + ", ".join(missing))
    print("[GreenQUIC] full 22-chart single-run self-test: PASS")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--matrix", type=Path)
    group.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test: return self_test()
    render(args.matrix)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
