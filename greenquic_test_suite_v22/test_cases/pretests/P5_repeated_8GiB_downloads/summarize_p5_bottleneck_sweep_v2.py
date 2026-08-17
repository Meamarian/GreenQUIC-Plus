#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import re
from pathlib import Path

CASE_RE = re.compile(r"^[A-P]_")
SCREENING_THRESHOLD_PCT = 3.0


def pct(value: float, baseline: float) -> float:
    return ((value / baseline) - 1.0) * 100.0 if baseline else 0.0


def read_env(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.is_file():
        return out
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" not in raw or raw.lstrip().startswith("#"):
            continue
        key, value = raw.split("=", 1)
        out[key.strip()] = value.strip()
    return out


def number(row: dict, key: str, default: float = 0.0) -> float:
    try:
        return float(row.get(key, default))
    except (TypeError, ValueError):
        return default


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()

    rows: list[dict] = []
    case_dirs = sorted(
        path for path in root.iterdir()
        if path.is_dir() and CASE_RE.match(path.name)
    )

    for case_dir in case_dirs:
        summary_path = case_dir / "bottleneck_tables/case_summary.json"
        case_cfg = read_env(case_dir / "BOTTLENECK_CASE_CONFIG.env")
        build_cfg = read_env(case_dir / "BUILD_PROFILE.env")
        base = {
            "case": case_dir.name,
            "reference": build_cfg.get("comparison_reference", ""),
            "build_profile": build_cfg.get("build_profile", ""),
            "quic_cpus": case_cfg.get("quic_cpus", ""),
            "dpdk_cpus": case_cfg.get("dpdk_lcores", ""),
        }

        if not summary_path.is_file():
            rows.append({**base, "status": "MISSING_OR_FAILED"})
            continue

        try:
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
        except Exception as exc:
            rows.append({**base, "status": f"INVALID:{exc}"})
            continue

        dpdk_cpus = [int(cpu) for cpu in summary.get("dpdk_cpus", [])]
        quic_cpus = [
            int(cpu)
            for cpu in case_cfg.get("quic_cpus", "").split(",")
            if cpu.strip().isdigit()
        ]

        row = {
            **base,
            "status": "PASS",
            "runs": int(summary.get("runs", 0)),
            "connections": int(summary.get("connections", 0)),
            "mean_goodput_gbps": number(summary, "aggregate_goodput_gbps_mean"),
            "stdev_goodput_gbps": number(summary, "aggregate_goodput_gbps_stdev"),
            "mean_connection_goodput_gbps": number(summary, "mean_connection_goodput_gbps_mean"),
            "combined_rapl_w": number(summary, "combined_rapl_w_mean"),
            "all_configured_dpdk_lcores_engaged": int(
                bool(summary.get("all_configured_dpdk_lcores_engaged"))
            ),
            "tx_hash_fallback_total": int(summary.get("tx_hash_fallback_total", 0)),
        }

        for role in ("server", "client"):
            for cpu in range(19, 25):
                row[f"{role}_cpu{cpu}_busy_pct"] = number(
                    summary, f"{role}_cpu{cpu}_busy_pct_mean"
                )
            row[f"{role}_configured_dpdk_busy_max_pct"] = max(
                [row[f"{role}_cpu{cpu}_busy_pct"] for cpu in dpdk_cpus],
                default=0.0,
            )
            row[f"{role}_configured_quic_busy_max_pct"] = max(
                [row.get(f"{role}_cpu{cpu}_busy_pct", 0.0) for cpu in quic_cpus],
                default=0.0,
            )

        rows.append(row)

    passed = [row for row in rows if row.get("status") == "PASS"]
    by_case = {row["case"]: row for row in passed}

    for row in passed:
        reference = (
            row
            if row.get("reference") == "self"
            else by_case.get(row.get("reference", ""))
        )
        row["delta_vs_reference_pct"] = (
            pct(number(row, "mean_goodput_gbps"), number(reference or {}, "mean_goodput_gbps"))
            if reference
            else ""
        )

        if row["case"] in ("A_1c_baseline", "B_2c_baseline"):
            row["effect_class"] = "reference"
        elif row["delta_vs_reference_pct"] == "":
            row["effect_class"] = "no reference"
        elif float(row["delta_vs_reference_pct"]) >= SCREENING_THRESHOLD_PCT:
            row["effect_class"] = "material positive"
        elif float(row["delta_vs_reference_pct"]) <= -SCREENING_THRESHOLD_PCT:
            row["effect_class"] = "material negative"
        else:
            row["effect_class"] = "no material change (<3%)"

    fields: list[str] = []
    for row in rows:
        for key in row:
            if key not in fields:
                fields.append(key)

    csv_path = root / "BOTTLENECK_SWEEP_SUMMARY.csv"
    with csv_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)

    text = [
        "P5 BOTTLENECK SWEEP V2 SUMMARY -- 16 CASES",
        "All cases: OFF mode, same simultaneous 8GiB downloads, repetitions and MTU 1500.",
        "A/B isolate DPDK core count with identical binary bits; C-P are one-variable perturbations.",
        "Sharded handoff is excluded because it is not a clean two-TX-consumer perturbation.",
        "Each perturbation has an explicit reference; +/-3% is the screening threshold.",
        "",
        "case                         goodput   SD      reference                  delta    power    DPDK QCPUs       effect",
    ]

    for row in rows:
        if row.get("status") != "PASS":
            text.append(f"{row['case']:<28} {row.get('status')}")
            continue
        delta = row.get("delta_vs_reference_pct", "")
        delta_text = "   n/a " if delta == "" else f"{float(delta):+7.2f}%"
        text.append(
            f"{row['case']:<28} "
            f"{number(row, 'mean_goodput_gbps'):>7.3f} "
            f"{number(row, 'stdev_goodput_gbps'):>6.3f}  "
            f"{str(row.get('reference', '')):<25} "
            f"{delta_text} "
            f"{number(row, 'combined_rapl_w'):>7.1f}W  "
            f"{row.get('all_configured_dpdk_lcores_engaged', 0)}    "
            f"{str(row.get('quic_cpus', '')):<10} "
            f"{row.get('effect_class', '')}"
        )

    baseline_1c = by_case.get("A_1c_baseline")
    baseline_2c = by_case.get("B_2c_baseline")
    text.append("")
    if baseline_1c and baseline_2c:
        delta = pct(
            number(baseline_2c, "mean_goodput_gbps"),
            number(baseline_1c, "mean_goodput_gbps"),
        )
        text.extend(
            [
                f"Core scaling A->B: {delta:+.3f}%",
                "  " + (
                    "MATERIAL core-count effect"
                    if abs(delta) >= SCREENING_THRESHOLD_PCT
                    else "NO material core-count effect"
                ),
            ]
        )

    groups = {
        "producer-ring sync": ("C_1c_ring_mp", "D_1c_ring_rts"),
        "TX allocation": ("E_2c_txalloc1", "F_2c_txalloc32"),
        "RX pipeline": ("G_2c_rxpipe0", "H_2c_rxpipe4"),
        "TX consumer batching": ("I_2c_txburst32", "J_2c_txburst64", "K_2c_drain4"),
        "RX burst": ("L_2c_rxburst64",),
        "TX metadata": ("M_2c_txmetazero0",),
        "OFF bookkeeping": ("N_2c_skipoffcount", "O_2c_debug0"),
        "ring capacity": ("P_2c_ring8192",),
    }

    text.extend(["", "Localization flags:"])
    for label, names in groups.items():
        present = [by_case[name] for name in names if name in by_case]
        positive = [
            row for row in present
            if row.get("delta_vs_reference_pct", "") != ""
            and float(row["delta_vs_reference_pct"]) >= SCREENING_THRESHOLD_PCT
        ]
        negative = [
            row for row in present
            if row.get("delta_vs_reference_pct", "") != ""
            and float(row["delta_vs_reference_pct"]) <= -SCREENING_THRESHOLD_PCT
        ]
        if positive:
            text.append(
                "  " + label + ": POSITIVE -> " + ", ".join(
                    f"{row['case']} {float(row['delta_vs_reference_pct']):+.2f}%"
                    for row in positive
                )
            )
        elif negative:
            text.append(
                "  " + label + ": SENSITIVE NEGATIVE -> " + ", ".join(
                    f"{row['case']} {float(row['delta_vs_reference_pct']):+.2f}%"
                    for row in negative
                )
            )
        elif present:
            text.append(f"  {label}: no >=3% effect")
        else:
            text.append(f"  {label}: missing/failed")

    ranked = sorted(
        passed,
        key=lambda row: number(row, "mean_goodput_gbps"),
        reverse=True,
    )
    if ranked:
        text.extend(
            [
                "",
                f"Best observed: {ranked[0]['case']} = {number(ranked[0], 'mean_goodput_gbps'):.6f} Gbit/s",
            ]
        )

    text.extend(
        [
            "",
            "Before assigning causality inspect case lcore_activity.csv, CPU19-24 busy columns, and exact quic_cpu_activity JSON.",
            "DPDK per-lcore RX/TX packet engagement is the authoritative dataplane-core evidence.",
        ]
    )

    text_path = root / "BOTTLENECK_SWEEP_SUMMARY.txt"
    text_path.write_text("\n".join(text) + "\n", encoding="utf-8")
    print(text_path.read_text(encoding="utf-8"), end="")
    print("CSV:", csv_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
