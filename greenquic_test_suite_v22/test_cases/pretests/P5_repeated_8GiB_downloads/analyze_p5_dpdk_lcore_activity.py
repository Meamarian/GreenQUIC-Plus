#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import re
from collections import defaultdict
from pathlib import Path

EXPECTED_LCORES = (19, 20)
MODES = ("off", "basic", "plus")
PAT = re.compile(
    r"\[GreenQUIC-MC\] LCORE_STATS schema=greenquic-mc-lcore-v1 "
    r"lcore=(\d+) rxq=(\d+) txq=(\d+) owns_rx=(\d+) owns_tx=(\d+) "
    r"rx_pkts=(\d+) tx_pkts=(\d+) total_pkts=(\d+)"
)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--matrix", type=Path, required=True)
    ap.add_argument("--runs", type=int, required=True)
    ap.add_argument("--min-share-pct", type=float, default=1.0)
    args = ap.parse_args()

    root = args.matrix.resolve()
    out_dir = root / "parallel_tables"
    out_dir.mkdir(parents=True, exist_ok=True)
    rows: list[dict] = []
    errors: list[str] = []
    warnings: list[str] = []

    for role in ("server", "client"):
        for rep in range(1, args.runs + 1):
            for mode in MODES:
                path = root / f"{role}_rep{rep:02d}_{mode}.log"
                if not path.is_file():
                    errors.append(f"{role} rep{rep:02d} {mode}: missing controller log {path.name}")
                    continue
                found = PAT.findall(path.read_text(encoding="utf-8", errors="replace"))
                by_lcore: dict[int, tuple[int, int, int, int, int, int, int]] = {}
                for match in found:
                    lcore, rxq, txq, owns_rx, owns_tx, rx, tx, total = map(int, match)
                    by_lcore[lcore] = (rxq, txq, owns_rx, owns_tx, rx, tx, total)
                missing = set(EXPECTED_LCORES) - set(by_lcore)
                if missing:
                    errors.append(
                        f"{role} rep{rep:02d} {mode}: LCORE_STATS missing CPUs {sorted(missing)}"
                    )
                    continue
                endpoint_total = sum(by_lcore[cpu][6] for cpu in EXPECTED_LCORES)
                for cpu in EXPECTED_LCORES:
                    rxq, txq, owns_rx, owns_tx, rx, tx, total = by_lcore[cpu]
                    share = (100.0 * total / endpoint_total) if endpoint_total else 0.0
                    engaged = total > 0
                    bidirectional = rx > 0 and tx > 0
                    meaningful = share >= args.min_share_pct
                    row = {
                        "role": role,
                        "repetition": rep,
                        "mode": mode,
                        "lcore": cpu,
                        "rx_queue": rxq,
                        "tx_queue": txq,
                        "owns_rx": owns_rx,
                        "owns_tx": owns_tx,
                        "rx_packets": rx,
                        "tx_packets": tx,
                        "total_packets": total,
                        "packet_share_pct": share,
                        "engaged": engaged,
                        "bidirectional": bidirectional,
                        "meaningful_share": meaningful,
                        "log": str(path),
                    }
                    rows.append(row)
                    if not engaged:
                        errors.append(
                            f"{role} rep{rep:02d} {mode}: DPDK CPU{cpu} processed zero RX+TX packets"
                        )
                    elif not meaningful:
                        warnings.append(
                            f"{role} rep{rep:02d} {mode}: DPDK CPU{cpu} packet share={share:.3f}% "
                            f"(<{args.min_share_pct:.3f}%)"
                        )
                    if not bidirectional:
                        warnings.append(
                            f"{role} rep{rep:02d} {mode}: DPDK CPU{cpu} is engaged but one direction is zero "
                            f"(rx={rx}, tx={tx}); this is valid workload/RSS evidence, not an idle core"
                        )

    csv_path = out_dir / "dpdk_lcore_activity.csv"
    fields = [
        "role", "repetition", "mode", "lcore", "rx_queue", "tx_queue",
        "owns_rx", "owns_tx", "rx_packets", "tx_packets", "total_packets",
        "packet_share_pct", "engaged", "bidirectional", "meaningful_share", "log",
    ]
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for row in rows:
            out = dict(row)
            out["packet_share_pct"] = f"{row['packet_share_pct']:.6f}"
            out["engaged"] = int(row["engaged"])
            out["bidirectional"] = int(row["bidirectional"])
            out["meaningful_share"] = int(row["meaningful_share"])
            w.writerow(out)

    grouped: dict[tuple[str, str, int], dict[str, float]] = defaultdict(
        lambda: {"rx": 0.0, "tx": 0.0, "total": 0.0, "share_sum": 0.0, "n": 0.0}
    )
    for row in rows:
        key = (row["role"], row["mode"], row["lcore"])
        g = grouped[key]
        g["rx"] += row["rx_packets"]
        g["tx"] += row["tx_packets"]
        g["total"] += row["total_packets"]
        g["share_sum"] += row["packet_share_pct"]
        g["n"] += 1

    summary_path = out_dir / "dpdk_lcore_activity_summary.csv"
    with summary_path.open("w", newline="", encoding="utf-8") as f:
        fields2 = [
            "role", "mode", "lcore", "runs", "total_rx_packets", "total_tx_packets",
            "total_packets", "mean_packet_share_pct",
        ]
        w = csv.DictWriter(f, fieldnames=fields2)
        w.writeheader()
        for key in sorted(grouped):
            role, mode, cpu = key
            g = grouped[key]
            n = int(g["n"])
            w.writerow({
                "role": role,
                "mode": mode,
                "lcore": cpu,
                "runs": n,
                "total_rx_packets": int(g["rx"]),
                "total_tx_packets": int(g["tx"]),
                "total_packets": int(g["total"]),
                "mean_packet_share_pct": f"{g['share_sum'] / n:.6f}" if n else "0.000000",
            })

    result = {
        "schema": "greenquic-p5-dpdk-lcore-activity-v1",
        "matrix": str(root),
        "expected_lcores": list(EXPECTED_LCORES),
        "engagement_rule": "rx_packets + tx_packets > 0 for each DPDK lcore on each endpoint/run/mode",
        "meaningful_share_threshold_pct": args.min_share_pct,
        "direction_note": (
            "RX or TX may legitimately be zero on one lcore for a directional workload/RSS outcome. "
            "The authoritative engagement test is total dataplane packets, while both directions are reported separately."
        ),
        "rows": rows,
        "errors": errors,
        "warnings": warnings,
        "status": "PASS" if not errors else "FAIL",
    }
    json_path = root / "dpdk_lcore_activity_validation.json"
    json_path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")

    print("P5 DPDK PER-LCORE ACTIVITY")
    for row in rows:
        print(
            f"  {row['role']} rep{row['repetition']:02d} {row['mode'].upper()} CPU{row['lcore']}: "
            f"RX={row['rx_packets']} (q{row['rx_queue']}) "
            f"TX={row['tx_packets']} (q{row['tx_queue']}) "
            f"TOTAL={row['total_packets']} share={row['packet_share_pct']:.3f}% "
            f"engaged={int(row['engaged'])}"
        )
    for warning in warnings:
        print("WARN:", warning)
    if errors:
        for error in errors:
            print("ERROR:", error)
        print(f"P5 DPDK LCORE ACTIVITY FAIL: {len(errors)} error(s); results preserved")
        return 2
    print("P5 DPDK LCORE ACTIVITY PASS: CPU19 and CPU20 processed dataplane packets in every endpoint/run/mode")
    print(f"CSV: {csv_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
