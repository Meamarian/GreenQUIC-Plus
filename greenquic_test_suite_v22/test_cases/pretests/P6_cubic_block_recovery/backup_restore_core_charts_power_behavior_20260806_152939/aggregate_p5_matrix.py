#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import math
import re
from pathlib import Path
from statistics import mean, stdev
from typing import Any, Iterable

LOG_NAME_RE = re.compile(r"^(client|server)_rep(\d+)_(off|basic|plus)\.log$")
ALIGNED_NAME_RE = re.compile(r"^aligned_(client|server)_rep(\d+)_(off|basic|plus)\.json$")
CLOCK_NAME_RE = re.compile(r"^clock_sync_rep(\d+)_(off|basic|plus)\.json$")
NUMBER_RE = re.compile(r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?")
BULLET_RE = re.compile(r"^- ([^:]+):\s*(.*)$")
MODES = ("off", "basic", "plus")


def normalize(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", text.lower()).strip("_")


def parse_sections(text: str) -> dict[str, str]:
    rows: dict[str, str] = {}
    current = "general"
    lines = text.splitlines()
    for index, raw in enumerate(lines):
        line = raw.strip()
        if line.startswith("=== ") and line.endswith(" ==="):
            current = line[4:-4].strip()
            continue
        if index + 1 < len(lines):
            underline = lines[index + 1].strip()
            if line and len(underline) >= 3 and set(underline) <= {"-", "="}:
                current = line
                continue
        match = BULLET_RE.match(line)
        if match:
            key = f"{normalize(current)}__{normalize(match.group(1))}"
            value = match.group(2).strip() or "N/A"
            rows[key] = value
    return rows


def numeric_template(value: str) -> tuple[str, list[float]]:
    numbers = [float(item) for item in NUMBER_RE.findall(value)]
    return NUMBER_RE.sub("{}", value), numbers


def average_values(values: list[str], expected_count: int) -> str:
    available = [value for value in values if value and value.upper() not in {"N/A", "UNAVAILABLE"}]
    if not available:
        return "N/A"
    templates = [numeric_template(value) for value in available]
    template = templates[0][0]
    count = len(templates[0][1])
    compatible = count > 0 and all(t == template and len(nums) == count for t, nums in templates)
    suffix = "" if len(available) == expected_count else f" (n={len(available)}/{expected_count})"
    if compatible:
        averages = [mean(nums[position] for _, nums in templates) for position in range(count)]
        rendered = template
        for value in averages:
            rendered = rendered.replace("{}", f"{value:.6f}".rstrip("0").rstrip("."), 1)
        return rendered + suffix
    unique = sorted(set(available))
    return (unique[0] if len(unique) == 1 else "VARIES") + suffix


def extract_number(value: str | None) -> float | None:
    if not value:
        return None
    match = NUMBER_RE.search(value)
    return float(match.group(0)) if match else None


def finite(value: Any) -> float | None:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def fmt(value: float | None, digits: int = 3, suffix: str = "") -> str:
    if value is None:
        return "N/A"
    return f"{value:.{digits}f}{suffix}"


def safe_mean(values: Iterable[float | None]) -> float | None:
    rows = [value for value in values if value is not None]
    return mean(rows) if rows else None


def safe_std(values: Iterable[float | None]) -> float | None:
    rows = [value for value in values if value is not None]
    if not rows:
        return None
    return stdev(rows) if len(rows) > 1 else 0.0


def percent_saving(baseline: float | None, current: float | None) -> float | None:
    if baseline is None or current is None or baseline == 0:
        return None
    return (baseline - current) / baseline * 100.0


def percent_increase(baseline: float | None, current: float | None) -> float | None:
    if baseline is None or current is None or baseline == 0:
        return None
    return (current - baseline) / baseline * 100.0


def read_runs(folder: Path, role: str) -> list[dict[str, Any]]:
    runs: list[dict[str, Any]] = []
    for path in sorted(folder.glob(f"{role}_rep*_*.log")):
        match = LOG_NAME_RE.match(path.name)
        if not match or match.group(1) != role:
            continue
        rows = parse_sections(path.read_text(encoding="utf-8", errors="replace"))
        payload_gib = extract_number(rows.get("greenquic_p5_workload_summary__total_payload"))
        rapl_energy_j = extract_number(rows.get("rapl_energy_whole_test__package_dram_energy"))
        board_energy_j = extract_number(rows.get("whole_system_power_and_energy_whole_test__estimated_cumulative_energy"))
        if payload_gib and payload_gib > 0:
            if rapl_energy_j is not None:
                rows["derived__rapl_energy_per_gib"] = f"{rapl_energy_j / payload_gib:.6f} J/GiB"
            if board_energy_j is not None:
                rows["derived__board_energy_per_gib"] = f"{board_energy_j / payload_gib:.6f} J/GiB"
        runs.append({
            "role": role,
            "repetition": int(match.group(2)),
            "mode": match.group(3),
            "log": str(path),
            **rows,
        })
    return runs


def read_aligned(folder: Path) -> dict[tuple[str, int, str], dict[str, Any]]:
    rows: dict[tuple[str, int, str], dict[str, Any]] = {}
    for path in sorted(folder.glob("aligned_*_rep*_*.json")):
        match = ALIGNED_NAME_RE.match(path.name)
        if not match:
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            data = {}
        data["source_file"] = str(path)
        rows[(match.group(1), int(match.group(2)), match.group(3))] = data
    return rows


def read_clock_sync(folder: Path) -> dict[tuple[int, str], dict[str, Any]]:
    rows: dict[tuple[int, str], dict[str, Any]] = {}
    for path in sorted(folder.glob("clock_sync_rep*_*.json")):
        match = CLOCK_NAME_RE.match(path.name)
        if not match:
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            data = {}
        data["source_file"] = str(path)
        rows[(int(match.group(1)), match.group(2))] = data
    return rows


def write_csv(path: Path, rows: list[dict[str, Any]], columns: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow({column: row.get(column, "N/A") for column in columns})


def markdown_table(columns: list[str], rows: list[list[str]]) -> str:
    widths = [len(column) for column in columns]
    for row in rows:
        for index, value in enumerate(row):
            widths[index] = max(widths[index], len(value))
    def render(row: list[str]) -> str:
        return "| " + " | ".join(value.ljust(widths[i]) for i, value in enumerate(row)) + " |"
    output = [render(columns), "| " + " | ".join("-" * width for width in widths) + " |"]
    output.extend(render(row) for row in rows)
    return "\n".join(output)


def write_full_role_tables(input_dir: Path, output: Path, expected_runs: int) -> dict[str, list[dict[str, Any]]]:
    role_runs: dict[str, list[dict[str, Any]]] = {}
    for role in ("client", "server"):
        runs = read_runs(input_dir, role)
        role_runs[role] = runs
        if not runs:
            continue
        columns = ["role", "repetition", "mode", "log"] + sorted(
            {key for row in runs for key in row if key not in {"role", "repetition", "mode", "log"}}
        )
        write_csv(output / f"{role}_all_runs.csv", runs, columns)
        averages: list[dict[str, Any]] = []
        for mode in MODES:
            mode_rows = [row for row in runs if row["mode"] == mode]
            avg: dict[str, Any] = {"role": role, "mode": mode}
            for column in columns[4:]:
                avg[column] = average_values([str(row.get(column, "N/A")) for row in mode_rows], expected_runs)
            averages.append(avg)
        write_csv(output / f"{role}_mode_averages.csv", averages, ["role", "mode"] + columns[4:])
    return role_runs


def build_combined_rows(
    client_runs: list[dict[str, Any]],
    aligned: dict[tuple[str, int, str], dict[str, Any]],
    clock_sync: dict[tuple[int, str], dict[str, Any]],
) -> list[dict[str, Any]]:
    clients = {(int(row["repetition"]), str(row["mode"])): row for row in client_runs}
    keys = sorted({(rep, mode) for _, rep, mode in aligned} | set(clients))
    result: list[dict[str, Any]] = []
    for rep, mode in keys:
        client_log = clients.get((rep, mode), {})
        server_energy = aligned.get(("server", rep, mode), {})
        client_energy = aligned.get(("client", rep, mode), {})
        server_j = finite(server_energy.get("total_energy_j"))
        client_j = finite(client_energy.get("total_energy_j"))
        server_w = finite(server_energy.get("average_total_power_w"))
        client_w = finite(client_energy.get("average_total_power_w"))
        combined_j = server_j + client_j if server_j is not None and client_j is not None else None
        combined_w = server_w + client_w if server_w is not None and client_w is not None else None
        payload_gib = extract_number(client_log.get("greenquic_p5_workload_summary__total_payload"))
        sync = clock_sync.get((rep, mode), {})
        offset_ns = finite(sync.get("client_minus_controller_offset_ns"))
        sync_rtt_ms = None
        sync_uncertainty_ms = None
        clock_offset_ms = None
        start_skew_ms = None
        end_skew_ms = None
        if offset_ns is not None:
            clock_offset_ms = offset_ns / 1e6
            sync_rtt = finite(sync.get("round_trip_ns"))
            sync_uncertainty = finite(sync.get("uncertainty_ns"))
            sync_rtt_ms = sync_rtt / 1e6 if sync_rtt is not None else None
            sync_uncertainty_ms = sync_uncertainty / 1e6 if sync_uncertainty is not None else None
            if server_energy.get("start_wall_time_ns") and client_energy.get("start_wall_time_ns"):
                adjusted_client_start = int(client_energy["start_wall_time_ns"]) - int(offset_ns)
                start_skew_ms = abs(int(server_energy["start_wall_time_ns"]) - adjusted_client_start) / 1e6
            if server_energy.get("end_wall_time_ns") and client_energy.get("end_wall_time_ns"):
                adjusted_client_end = int(client_energy["end_wall_time_ns"]) - int(offset_ns)
                end_skew_ms = abs(int(server_energy["end_wall_time_ns"]) - adjusted_client_end) / 1e6
        duration_mismatch_ms = None
        server_duration = finite(server_energy.get("duration_s"))
        client_duration = finite(client_energy.get("duration_s"))
        if server_duration is not None and client_duration is not None:
            duration_mismatch_ms = abs(server_duration - client_duration) * 1000.0
        result.append({
            "repetition": rep,
            "mode": mode,
            "workload_duration_s": extract_number(client_log.get("greenquic_p5_workload_summary__workload_elapsed_time_including_gaps")),
            "goodput_excluding_gaps_gbps": extract_number(client_log.get("greenquic_p5_workload_summary__aggregate_goodput_excluding_gaps")),
            "goodput_including_gaps_gbps": extract_number(client_log.get("greenquic_p5_workload_summary__aggregate_goodput_including_gaps")),
            "payload_gib": payload_gib,
            "client_aligned_duration_s": finite(client_energy.get("duration_s")),
            "server_aligned_duration_s": finite(server_energy.get("duration_s")),
            "client_rapl_energy_j": client_j,
            "server_rapl_energy_j": server_j,
            "combined_rapl_energy_j": combined_j,
            "client_average_power_w": client_w,
            "server_average_power_w": server_w,
            "combined_average_power_w": combined_w,
            "client_rapl_j_per_gib": client_j / payload_gib if client_j is not None and payload_gib else None,
            "server_rapl_j_per_gib": server_j / payload_gib if server_j is not None and payload_gib else None,
            "combined_rapl_j_per_gib": combined_j / payload_gib if combined_j is not None and payload_gib else None,
            "window_start_skew_ms": start_skew_ms,
            "window_end_skew_ms": end_skew_ms,
            "window_duration_mismatch_ms": duration_mismatch_ms,
            "client_clock_offset_ms": clock_offset_ms,
            "clock_sync_rtt_ms": sync_rtt_ms,
            "clock_sync_uncertainty_ms": sync_uncertainty_ms,
            "clock_sync_file": sync.get("source_file", "N/A"),
            "client_aligned_valid": bool(client_energy.get("valid")),
            "server_aligned_valid": bool(server_energy.get("valid")),
            "client_aligned_file": client_energy.get("source_file", "N/A"),
            "server_aligned_file": server_energy.get("source_file", "N/A"),
        })
    return result


def average_combined(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    numeric_fields = [
        "workload_duration_s", "goodput_excluding_gaps_gbps", "goodput_including_gaps_gbps",
        "payload_gib", "client_aligned_duration_s", "server_aligned_duration_s",
        "client_rapl_energy_j", "server_rapl_energy_j", "combined_rapl_energy_j",
        "client_average_power_w", "server_average_power_w", "combined_average_power_w",
        "client_rapl_j_per_gib", "server_rapl_j_per_gib", "combined_rapl_j_per_gib",
        "window_start_skew_ms", "window_end_skew_ms", "window_duration_mismatch_ms",
        "client_clock_offset_ms", "clock_sync_rtt_ms", "clock_sync_uncertainty_ms",
    ]
    averages: list[dict[str, Any]] = []
    for mode in MODES:
        mode_rows = [row for row in rows if row["mode"] == mode]
        avg: dict[str, Any] = {
            "mode": mode,
            "valid_runs": len(mode_rows),
            "energy_valid_runs": sum(
                finite(row.get("combined_rapl_energy_j")) is not None for row in mode_rows
            ),
        }
        for field in numeric_fields:
            values = [finite(row.get(field)) for row in mode_rows]
            avg[field] = safe_mean(values)
            avg[f"{field}_stddev"] = safe_std(values)
        averages.append(avg)

    by_mode = {row["mode"]: row for row in averages}
    off = by_mode.get("off", {})
    for row in averages:
        row["client_energy_saving_vs_off_pct"] = percent_saving(
            finite(off.get("client_rapl_energy_j")), finite(row.get("client_rapl_energy_j"))
        )
        row["server_energy_saving_vs_off_pct"] = percent_saving(
            finite(off.get("server_rapl_energy_j")), finite(row.get("server_rapl_energy_j"))
        )
        row["combined_energy_saving_vs_off_pct"] = percent_saving(
            finite(off.get("combined_rapl_energy_j")), finite(row.get("combined_rapl_energy_j"))
        )
        row["client_power_saving_vs_off_pct"] = percent_saving(
            finite(off.get("client_average_power_w")), finite(row.get("client_average_power_w"))
        )
        row["server_power_saving_vs_off_pct"] = percent_saving(
            finite(off.get("server_average_power_w")), finite(row.get("server_average_power_w"))
        )
        row["combined_power_saving_vs_off_pct"] = percent_saving(
            finite(off.get("combined_average_power_w")), finite(row.get("combined_average_power_w"))
        )
        row["goodput_reduction_excluding_gaps_pct"] = percent_saving(
            finite(off.get("goodput_excluding_gaps_gbps")), finite(row.get("goodput_excluding_gaps_gbps"))
        )
        row["goodput_reduction_including_gaps_pct"] = percent_saving(
            finite(off.get("goodput_including_gaps_gbps")), finite(row.get("goodput_including_gaps_gbps"))
        )
        row["workload_time_increase_vs_off_pct"] = percent_increase(
            finite(off.get("workload_duration_s")), finite(row.get("workload_duration_s"))
        )
    return averages


def create_charts(output: Path, averages: list[dict[str, Any]]) -> list[Path]:
    # P5-FOUR-CHARTS-V2: exactly four publication charts.
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        import numpy as np
    except Exception as exc:
        print(f"[P5:WARN] SVG chart generation skipped: {exc}")
        return []

    charts = output / "charts"
    charts.mkdir(parents=True, exist_ok=True)
    for old in charts.glob("*.svg"):
        old.unlink()

    labels = [row["mode"].upper() for row in averages]
    x = np.arange(len(labels))
    created: list[Path] = []

    def number(row: dict[str, Any], key: str) -> float:
        value = finite(row.get(key))
        return value if value is not None else math.nan

    def annotate(ax, bars, digits: int = 1, suffix: str = "") -> None:
        for bar in bars:
            height = float(bar.get_height())
            if not math.isfinite(height):
                continue
            va = "bottom" if height >= 0 else "top"
            offset = 3 if height >= 0 else -3
            ax.annotate(
                f"{height:.{digits}f}{suffix}",
                xy=(bar.get_x() + bar.get_width() / 2, height),
                xytext=(0, offset),
                textcoords="offset points",
                ha="center",
                va=va,
                fontsize=8,
            )

    width = 0.25

    fig, ax = plt.subplots(figsize=(10, 6))
    server_j = [number(row, "server_rapl_energy_j") for row in averages]
    client_j = [number(row, "client_rapl_energy_j") for row in averages]
    combined_j = [number(row, "combined_rapl_energy_j") for row in averages]
    b1 = ax.bar(x - width, server_j, width, label="Server")
    b2 = ax.bar(x, client_j, width, label="Client")
    b3 = ax.bar(x + width, combined_j, width, label="Server + client")
    ax.set_title("Total RAPL energy by mode")
    ax.set_ylabel("Package + DRAM energy (J)")
    ax.set_xticks(x, labels)
    ax.legend()
    ax.grid(axis="y", alpha=0.3)
    annotate(ax, b1); annotate(ax, b2); annotate(ax, b3)
    fig.tight_layout()
    out = charts / "total_rapl_energy_joules.svg"
    fig.savefig(out, format="svg")
    plt.close(fig)
    created.append(out)

    fig, ax = plt.subplots(figsize=(10, 6))
    server_w = [number(row, "server_average_power_w") for row in averages]
    client_w = [number(row, "client_average_power_w") for row in averages]
    combined_w = [number(row, "combined_average_power_w") for row in averages]
    b1 = ax.bar(x - width, server_w, width, label="Server")
    b2 = ax.bar(x, client_w, width, label="Client")
    b3 = ax.bar(x + width, combined_w, width, label="Server + client")
    ax.set_title("Average RAPL power by mode")
    ax.set_ylabel("Average package + DRAM power (W)")
    ax.set_xticks(x, labels)
    ax.legend()
    ax.grid(axis="y", alpha=0.3)
    annotate(ax, b1); annotate(ax, b2); annotate(ax, b3)
    fig.tight_layout()
    out = charts / "average_rapl_power_watts.svg"
    fig.savefig(out, format="svg")
    plt.close(fig)
    created.append(out)

    comparison = [row for row in averages if row["mode"] != "off"]
    cx = np.arange(len(comparison))
    fig, ax = plt.subplots(figsize=(10, 6))
    server_save = [number(row, "server_power_saving_vs_off_pct") for row in comparison]
    client_save = [number(row, "client_power_saving_vs_off_pct") for row in comparison]
    combined_save = [number(row, "combined_power_saving_vs_off_pct") for row in comparison]
    b1 = ax.bar(cx - width, server_save, width, label="Server")
    b2 = ax.bar(cx, client_save, width, label="Client")
    b3 = ax.bar(cx + width, combined_save, width, label="Server + client")
    ax.axhline(0, linewidth=0.8)
    ax.set_title("Average-power saving versus OFF")
    ax.set_ylabel("Power saving (%) — positive is lower power")
    ax.set_xticks(cx, [row["mode"].upper() for row in comparison])
    ax.legend()
    ax.grid(axis="y", alpha=0.3)
    annotate(ax, b1, 2, "%"); annotate(ax, b2, 2, "%"); annotate(ax, b3, 2, "%")
    fig.tight_layout()
    out = charts / "power_saving_vs_off_percent.svg"
    fig.savefig(out, format="svg")
    plt.close(fig)
    created.append(out)

    fig, ax = plt.subplots(figsize=(9, 6))
    width2 = 0.35
    good_ex = [number(row, "goodput_reduction_excluding_gaps_pct") for row in comparison]
    good_in = [number(row, "goodput_reduction_including_gaps_pct") for row in comparison]
    b1 = ax.bar(cx - width2 / 2, good_ex, width2, label="Excluding inter-download gaps")
    b2 = ax.bar(cx + width2 / 2, good_in, width2, label="Including inter-download gaps")
    ax.axhline(0, linewidth=0.8)
    ax.set_title("Goodput reduction versus OFF")
    ax.set_ylabel("Goodput reduction (%) — positive is worse")
    ax.set_xticks(cx, [row["mode"].upper() for row in comparison])
    ax.legend()
    ax.grid(axis="y", alpha=0.3)
    annotate(ax, b1, 2, "%"); annotate(ax, b2, 2, "%")
    fig.tight_layout()
    out = charts / "goodput_reduction_vs_off_percent.svg"
    fig.savefig(out, format="svg")
    plt.close(fig)
    created.append(out)

    return created


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--runs", type=int, required=True)
    args = parser.parse_args()

    input_dir = args.input.resolve()
    output = input_dir / "tables"
    output.mkdir(parents=True, exist_ok=True)

    role_runs = write_full_role_tables(input_dir, output, args.runs)
    aligned = read_aligned(input_dir)
    clock_sync = read_clock_sync(input_dir)
    combined_runs = build_combined_rows(role_runs.get("client", []), aligned, clock_sync)

    combined_columns = [
        "repetition", "mode", "workload_duration_s", "goodput_excluding_gaps_gbps",
        "goodput_including_gaps_gbps", "payload_gib", "client_aligned_duration_s",
        "server_aligned_duration_s", "client_rapl_energy_j", "server_rapl_energy_j",
        "combined_rapl_energy_j", "client_average_power_w", "server_average_power_w",
        "combined_average_power_w", "client_rapl_j_per_gib", "server_rapl_j_per_gib",
        "combined_rapl_j_per_gib", "window_start_skew_ms", "window_end_skew_ms",
        "window_duration_mismatch_ms", "client_clock_offset_ms", "clock_sync_rtt_ms",
        "clock_sync_uncertainty_ms", "clock_sync_file", "client_aligned_valid",
        "server_aligned_valid", "client_aligned_file", "server_aligned_file",
    ]
    write_csv(output / "combined_endpoint_all_runs.csv", combined_runs, combined_columns)

    averages = average_combined(combined_runs)
    average_columns = ["mode", "valid_runs", "energy_valid_runs"] + [
        key for key in averages[0] if key not in {"mode", "valid_runs", "energy_valid_runs"}
    ] if averages else ["mode", "valid_runs", "energy_valid_runs"]
    write_csv(output / "combined_endpoint_mode_averages.csv", averages, average_columns)

    table_rows: list[list[str]] = []
    for row in averages:
        table_rows.append([
            row["mode"].upper(),
            str(row.get("valid_runs", 0)),
            str(row.get("energy_valid_runs", 0)),
            fmt(finite(row.get("goodput_excluding_gaps_gbps")), 3),
            fmt(finite(row.get("goodput_reduction_excluding_gaps_pct")), 3, "%"),
            fmt(finite(row.get("goodput_including_gaps_gbps")), 3),
            fmt(finite(row.get("goodput_reduction_including_gaps_pct")), 3, "%"),
            fmt(finite(row.get("client_rapl_energy_j")), 3),
            fmt(finite(row.get("server_rapl_energy_j")), 3),
            fmt(finite(row.get("combined_rapl_energy_j")), 3),
            fmt(finite(row.get("client_average_power_w")), 3),
            fmt(finite(row.get("client_power_saving_vs_off_pct")), 3, "%"),
            fmt(finite(row.get("server_average_power_w")), 3),
            fmt(finite(row.get("server_power_saving_vs_off_pct")), 3, "%"),
            fmt(finite(row.get("combined_average_power_w")), 3),
            fmt(finite(row.get("combined_power_saving_vs_off_pct")), 3, "%"),
            fmt(finite(row.get("client_aligned_duration_s")), 3),
            fmt(finite(row.get("server_aligned_duration_s")), 3),
            fmt(finite(row.get("workload_duration_s")), 3),
            fmt(finite(row.get("window_start_skew_ms")), 3),
            fmt(finite(row.get("window_end_skew_ms")), 3),
            fmt(finite(row.get("window_duration_mismatch_ms")), 3),
            fmt(finite(row.get("clock_sync_uncertainty_ms")), 3),
        ])
    columns = [
        "Mode", "N", "Energy N",
        "Goodput excl. gaps", "Goodput reduction excl.",
        "Goodput incl. gaps", "Goodput reduction incl.",
        "Client RAPL J", "Server RAPL J", "Total RAPL J",
        "Client avg W", "Client power saving",
        "Server avg W", "Server power saving",
        "Total avg W", "Total power saving",
        "Client window s", "Server window s", "Download+gaps s",
        "Start skew ms", "End skew ms", "Duration mismatch ms", "Clock uncertainty ms",
    ]
    comparison = markdown_table(columns, table_rows)
    (output / "combined_endpoint_comparison.md").write_text(comparison + "\n", encoding="utf-8")

    charts = create_charts(output, averages)

    print()
    print("=== P5 aligned server + client comparison ===")
    print(comparison)
    print()
    if combined_runs:
        max_start_skew = max((row.get("window_start_skew_ms") or 0.0) for row in combined_runs)
        max_end_skew = max((row.get("window_end_skew_ms") or 0.0) for row in combined_runs)
        print(f"- Maximum endpoint start-window skew: {max_start_skew:.3f} ms")
        print(f"- Maximum endpoint end-window skew: {max_end_skew:.3f} ms")
        max_uncertainty = max((row.get("clock_sync_uncertainty_ms") or 0.0) for row in combined_runs)
        print(f"- Maximum clock-sync uncertainty: {max_uncertainty:.3f} ms")
        threshold_ms = max(1500.0, 2.0 * max_uncertainty)
        if max_start_skew > threshold_ms or max_end_skew > threshold_ms:
            print(
                f"- WARNING: calibrated endpoint window skew exceeded {threshold_ms:.3f} ms; "
                "inspect aligned JSON and clock-sync files before publication."
            )
    else:
        print("- Aligned endpoint RAPL files unavailable; server + client cells are N/A.")
    print(f"- Full tables: {output}")
    print(f"- SVG charts: {output / 'charts'}")
    for chart in charts:
        print(f"  - {chart.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
