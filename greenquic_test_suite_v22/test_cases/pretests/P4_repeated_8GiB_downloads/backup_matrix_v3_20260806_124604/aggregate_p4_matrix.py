#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import math
import re
from collections import defaultdict
from pathlib import Path
from statistics import mean
from typing import Any


LOG_NAME_RE = re.compile(r"^(client|server)_rep(\d+)_(off|basic|plus)\.log$")
NUMBER_RE = re.compile(r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?")
BULLET_RE = re.compile(r"^- ([^:]+):\s*(.*)$")


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
            if key in rows:
                suffix = 2
                while f"{key}_{suffix}" in rows:
                    suffix += 1
                key = f"{key}_{suffix}"
            rows[key] = value
    return rows


def numeric_template(value: str) -> tuple[str, list[float]]:
    numbers = [float(item) for item in NUMBER_RE.findall(value)]
    template = NUMBER_RE.sub("{}", value)
    return template, numbers


def average_values(values: list[str], expected_count: int) -> str:
    available = [value for value in values if value and value.upper() not in {"N/A", "UNAVAILABLE"}]
    if not available:
        return "N/A"

    templates = [numeric_template(value) for value in available]
    template = templates[0][0]
    number_count = len(templates[0][1])
    numeric_compatible = (
        number_count > 0
        and all(item[0] == template and len(item[1]) == number_count for item in templates)
    )

    suffix = "" if len(available) == expected_count else f" (n={len(available)}/{expected_count})"
    if numeric_compatible:
        means = [
            mean(item[1][position] for item in templates)
            for position in range(number_count)
        ]
        rendered = template
        for value in means:
            formatted = f"{value:.6f}".rstrip("0").rstrip(".")
            rendered = rendered.replace("{}", formatted, 1)
        return rendered + suffix

    unique = sorted(set(available))
    if len(unique) == 1:
        return unique[0] + suffix
    return "VARIES" + suffix


def extract_number(value: str | None) -> float | None:
    if not value:
        return None
    match = NUMBER_RE.search(value)
    return float(match.group(0)) if match else None


def read_runs(folder: Path, role: str) -> list[dict[str, Any]]:
    runs = []
    for path in sorted(folder.glob(f"{role}_rep*_*.log")):
        match = LOG_NAME_RE.match(path.name)
        if not match or match.group(1) != role:
            continue
        rows = parse_sections(path.read_text(encoding="utf-8", errors="replace"))

        payload_gib = extract_number(
            rows.get("greenquic_p4_workload_summary__total_payload")
        )
        rapl_energy_j = extract_number(
            rows.get("rapl_energy_whole_test__package_dram_energy")
        )
        board_energy_j = extract_number(
            rows.get("whole_system_power_and_energy_whole_test__estimated_cumulative_energy")
        )
        if payload_gib and payload_gib > 0:
            if rapl_energy_j is not None:
                rows["derived__rapl_energy_per_gib"] = (
                    f"{rapl_energy_j / payload_gib:.6f} J/GiB"
                )
            if board_energy_j is not None:
                rows["derived__board_energy_per_gib"] = (
                    f"{board_energy_j / payload_gib:.6f} J/GiB"
                )

        runs.append({
            "role": role,
            "repetition": int(match.group(2)),
            "mode": match.group(3),
            "log": str(path),
            **rows,
        })
    return runs


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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--runs", type=int, required=True)
    args = parser.parse_args()

    output = args.input / "tables"
    output.mkdir(parents=True, exist_ok=True)

    all_averages: dict[str, dict[str, str]] = {}
    for role in ("client", "server"):
        runs = read_runs(args.input, role)
        if not runs:
            continue
        columns = ["role", "repetition", "mode", "log"] + sorted(
            {key for row in runs for key in row if key not in {"role", "repetition", "mode", "log"}}
        )
        write_csv(output / f"{role}_all_runs.csv", runs, columns)

        averages = []
        for mode in ("off", "basic", "plus"):
            mode_rows = [row for row in runs if row["mode"] == mode]
            average_row: dict[str, str] = {"role": role, "mode": mode}
            for column in columns[4:]:
                average_row[column] = average_values(
                    [str(row.get(column, "N/A")) for row in mode_rows],
                    args.runs,
                )
            averages.append(average_row)
            all_averages[f"{role}:{mode}"] = average_row

        comparison_fields: list[str] = []
        if role == "client":
            by_mode = {row["mode"]: row for row in averages}
            off = by_mode.get("off", {})
            derived_specs = [
                (
                    "derived_comparison__rapl_energy_saving_vs_off",
                    "rapl_energy_whole_test__package_dram_energy",
                    "saving",
                ),
                (
                    "derived_comparison__rapl_average_power_reduction_vs_off",
                    "rapl_energy_whole_test__average_package_dram_power",
                    "saving",
                ),
                (
                    "derived_comparison__board_energy_saving_vs_off",
                    "whole_system_power_and_energy_whole_test__estimated_cumulative_energy",
                    "saving",
                ),
                (
                    "derived_comparison__goodput_reduction_vs_off_excluding_gaps",
                    "greenquic_p4_workload_summary__aggregate_goodput_excluding_gaps",
                    "reduction",
                ),
                (
                    "derived_comparison__goodput_reduction_vs_off_including_gaps",
                    "greenquic_p4_workload_summary__aggregate_goodput_including_gaps",
                    "reduction",
                ),
                (
                    "derived_comparison__workload_time_increase_vs_off",
                    "greenquic_p4_workload_summary__workload_elapsed_time_including_gaps",
                    "increase",
                ),
            ]
            comparison_fields = [item[0] for item in derived_specs]
            for derived_key, source_key, direction in derived_specs:
                baseline = extract_number(off.get(source_key))
                for row in averages:
                    current = extract_number(row.get(source_key))
                    if baseline is None or baseline == 0 or current is None:
                        row[derived_key] = "N/A"
                    elif direction in {"saving", "reduction"}:
                        row[derived_key] = f"{(baseline - current) / baseline * 100.0:.3f}%"
                    else:
                        row[derived_key] = f"{(current - baseline) / baseline * 100.0:.3f}%"

        average_columns = ["role", "mode"] + columns[4:] + comparison_fields
        write_csv(output / f"{role}_mode_averages.csv", averages, average_columns)

    key_map = [
        ("Downloads", "greenquic_p4_workload_summary__sequential_streams_downloads"),
        ("Total payload", "greenquic_p4_workload_summary__total_payload"),
        ("Gap", "greenquic_p4_workload_summary__configured_gap"),
        ("Workload time", "greenquic_p4_workload_summary__workload_elapsed_time_including_gaps"),
        ("Goodput excl. gaps", "greenquic_p4_workload_summary__aggregate_goodput_excluding_gaps"),
        ("Goodput incl. gaps", "greenquic_p4_workload_summary__aggregate_goodput_including_gaps"),
        ("Goodput loss vs OFF excl.", "derived_comparison__goodput_reduction_vs_off_excluding_gaps"),
        ("Goodput loss vs OFF incl.", "derived_comparison__goodput_reduction_vs_off_including_gaps"),
        ("Workload time vs OFF", "derived_comparison__workload_time_increase_vs_off"),
        ("Workload-window RAPL", "rapl_energy_active_transfer_only__package_dram_energy"),
        ("RAPL energy", "rapl_energy_whole_test__package_dram_energy"),
        ("RAPL saving vs OFF", "derived_comparison__rapl_energy_saving_vs_off"),
        ("RAPL J/GiB", "derived__rapl_energy_per_gib"),
        ("RAPL avg power", "rapl_energy_whole_test__average_package_dram_power"),
        ("RAPL power reduction", "derived_comparison__rapl_average_power_reduction_vs_off"),
        ("Board energy", "whole_system_power_and_energy_whole_test__estimated_cumulative_energy"),
        ("Board saving vs OFF", "derived_comparison__board_energy_saving_vs_off"),
        ("Board J/GiB", "derived__board_energy_per_gib"),
        ("Board avg power", "whole_system_power_and_energy_whole_test__time_weighted_average_power"),
        ("Min frequency", "cpu_frequency__minimum_observed_frequency"),
        ("Max frequency", "cpu_frequency__maximum_observed_frequency"),
        ("EPOLL attempts", "idle_and_wake_behavior__epoll_attempts"),
        ("EPOLL wakeups", "idle_and_wake_behavior__epoll_wakeups"),
        ("EPOLL timeouts", "idle_and_wake_behavior__epoll_timeouts"),
        ("C-state intervals", "linux_c_state_trace__completed_idle_intervals"),
    ]

    comparison_rows = []
    for mode in ("off", "basic", "plus"):
        row = all_averages.get(f"client:{mode}", {})
        comparison_rows.append([mode.upper()] + [row.get(key, "N/A") for _, key in key_map])

    comparison_columns = ["Mode"] + [label for label, _ in key_map]
    comparison = markdown_table(comparison_columns, comparison_rows)
    (output / "client_key_comparison.md").write_text(comparison + "\n", encoding="utf-8")

    print()
    print("=== P4 averaged client comparison ===")
    print(comparison)
    print()
    print(f"Full per-run and average tables: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
