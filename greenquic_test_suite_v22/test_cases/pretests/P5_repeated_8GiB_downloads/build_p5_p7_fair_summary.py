#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

ORDER = ("linux", "off", "basic", "plus")


def read_csv(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        return []
    try:
        return list(csv.DictReader(path.open(newline="", encoding="utf-8")))
    except Exception:
        return []


def read_json(path: Path) -> dict:
    if not path.is_file():
        return {"status": "MISSING"}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        return {"status": "INVALID", "error": str(exc)}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--p5-matrix", type=Path, required=True)
    ap.add_argument("--p7-matrix", type=Path, required=True)
    ap.add_argument("--p5-rc", type=int, required=True)
    ap.add_argument("--p7-rc", type=int, required=True)
    ap.add_argument("--output", type=Path, required=True)
    args = ap.parse_args()

    p5 = args.p5_matrix
    p7 = args.p7_matrix
    goodput_rows = (
        read_csv(p7 / "parallel_tables" / "parallel_goodput_summary.csv")
        + read_csv(p5 / "parallel_tables" / "parallel_goodput_summary.csv")
    )
    percore_rows = (
        read_csv(p7 / "parallel_tables" / "parallel_goodput_per_core_summary.csv")
        + read_csv(p5 / "parallel_tables" / "parallel_goodput_per_core_summary.csv")
    )
    by = {str(r.get("mode", "")).lower(): r for r in goodput_rows}
    cb = {str(r.get("mode", "")).lower(): r for r in percore_rows}

    p5fair = read_json(p5 / "P5_FAIRNESS_STATUS.json")
    p7fair = read_json(p7 / "P7_FAIRNESS_STATUS.json")
    p5dpdk = read_json(p5 / "dpdk_lcore_activity_validation.json")
    p7cpu = read_json(p7 / "parallel_irq_activity_validation.json")

    present = [m for m in ORDER if m in by]
    missing = [m for m in ORDER if m not in by]
    fair_valid = (
        not missing
        and args.p5_rc == 0
        and args.p7_rc == 0
        and p5fair.get("fairness_status") == "PASS"
        and p7fair.get("fairness_status") == "PASS"
    )

    linux_mean = float(by["linux"]["mean_goodput_gbps"]) if "linux" in by else None
    off_mean = float(by["off"]["mean_goodput_gbps"]) if "off" in by else None
    fields = [
        "case", "present", "n", "mean_goodput_gbps", "stdev_goodput_gbps",
        "variance_goodput_gbps2", "min_goodput_gbps", "max_goodput_gbps",
        "normalized_goodput_per_2_dataplane_cores_gbps",
        "configured_quic_core_count", "configured_quic_cpus",
        "server_active_quic_cpus", "client_active_quic_cpus", "common_active_quic_cpus",
        "delta_vs_linux_pct", "delta_vs_off_pct",
        "dataplane_activity_status", "fair_comparison_valid",
    ]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields, delimiter="\t")
        w.writeheader()
        for mode in ORDER:
            r = by.get(mode)
            c = cb.get(mode, {})
            is_p5 = mode != "linux"
            dp_status = (
                p5dpdk.get("status", "MISSING") if is_p5
                else p7cpu.get("status", "MISSING")
            )
            if r is None:
                w.writerow({
                    "case": mode.upper(), "present": 0,
                    "dataplane_activity_status": dp_status,
                    "fair_comparison_valid": 1 if fair_valid else 0,
                })
                continue
            mean = float(r["mean_goodput_gbps"])
            w.writerow({
                "case": mode.upper(),
                "present": 1,
                "n": r.get("n", ""),
                "mean_goodput_gbps": f"{mean:.6f}",
                "stdev_goodput_gbps": f"{float(r.get('stdev_goodput_gbps', 0) or 0):.6f}",
                "variance_goodput_gbps2": f"{float(r.get('variance_goodput_gbps2', 0) or 0):.6f}",
                "min_goodput_gbps": f"{float(r.get('min_goodput_gbps', mean) or mean):.6f}",
                "max_goodput_gbps": f"{float(r.get('max_goodput_gbps', mean) or mean):.6f}",
                "normalized_goodput_per_2_dataplane_cores_gbps": c.get("normalized_goodput_per_dataplane_core_gbps", ""),
                "configured_quic_core_count": c.get("configured_quic_core_count", ""),
                "configured_quic_cpus": c.get("configured_quic_cpus", ""),
                "server_active_quic_cpus": c.get("server_active_quic_cpus", ""),
                "client_active_quic_cpus": c.get("client_active_quic_cpus", ""),
                "common_active_quic_cpus": c.get("verified_quic_cpus", ""),
                "delta_vs_linux_pct": f"{((mean/linux_mean)-1)*100:.3f}" if linux_mean else "",
                "delta_vs_off_pct": f"{((mean/off_mean)-1)*100:.3f}" if off_mean else "",
                "dataplane_activity_status": dp_status,
                "fair_comparison_valid": 1 if fair_valid else 0,
            })

    status = {
        "schema": "greenquic-p5-p7-fair-comparison-v1",
        "p5_phase_rc": args.p5_rc,
        "p7_phase_rc": args.p7_rc,
        "cases_present": present,
        "cases_missing": missing,
        "p5_fairness_status": p5fair.get("fairness_status", "MISSING"),
        "p7_fairness_status": p7fair.get("fairness_status", "MISSING"),
        "p5_dpdk_lcore_activity_status": p5dpdk.get("status", "MISSING"),
        "p7_linux_dataplane_cpu_activity_status": p7cpu.get("status", "MISSING"),
        "quic_worker_activity_is_hard_gate": False,
        "fair_comparison_valid": fair_valid,
        "fairness_contract": {
            "workload": "4 simultaneous QUIC connections, 8 GiB each",
            "p5_dataplane": "DPDK CPU19/CPU20 each own RX/TX queue; both must process RX+TX packets",
            "p7_dataplane": "Linux two combined queues pinned to CPU19/CPU20; both must show queue IRQ and NET_RX activity",
            "quic_workers": "configured CPU21-24 on both P5 and P7; actual scheduler use is reported, not required on every CPU",
            "mtu": 1500,
        },
    }
    status_path = args.output.with_suffix(args.output.suffix + ".status.json")
    status_path.write_text(json.dumps(status, indent=2) + "\n", encoding="utf-8")

    print("\nFINAL FAIR GOODPUT SUMMARY: LINUX vs OFF vs BASIC vs PLUS")
    print(args.output.read_text(encoding="utf-8"), end="")
    print("FAIR COMPARISON VALID:", "YES" if fair_valid else "NO")
    print("  P5 DPDK CPU19/20 activity:", status["p5_dpdk_lcore_activity_status"])
    print("  P7 Linux CPU19/20 activity:", status["p7_linux_dataplane_cpu_activity_status"])
    print("  QUIC CPU21-24 use: diagnostic only, not a stop condition")
    if missing:
        print("  Missing cases:", ",".join(missing))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
