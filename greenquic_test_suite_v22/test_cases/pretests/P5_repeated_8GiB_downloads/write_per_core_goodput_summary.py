#!/usr/bin/env python3
from __future__ import annotations

"""Write normalized per-core goodput using runtime-verified QUIC CPU activity.

The output deliberately does NOT claim direct byte attribution to individual
CPUs.  Aggregate goodput is normalized by the fixed dataplane-core count and by
the number of QUIC CPUs that were proven active on both endpoints.
"""

import argparse
import csv
import json
from pathlib import Path


def load_activity(path: Path) -> tuple[list[int], list[int], str]:
    data = json.loads(path.read_text(encoding="utf-8"))
    targets = [int(x) for x in data.get("target_cpus", [])]
    active = [int(r["cpu"]) for r in data.get("rows", []) if r.get("active")]
    return sorted(targets), sorted(active), str(data.get("status", "UNKNOWN"))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--goodput", type=Path, required=True)
    ap.add_argument("--server-activity", type=Path, required=True)
    ap.add_argument("--client-activity", type=Path, required=True)
    ap.add_argument("--dataplane-cores", type=int, default=2)
    ap.add_argument("--output", type=Path, required=True)
    args = ap.parse_args()
    if args.dataplane_cores < 1:
        raise SystemExit("ERROR: --dataplane-cores must be positive")

    st, sa, ss = load_activity(args.server_activity)
    ct, ca, cs = load_activity(args.client_activity)
    if ss != "PASS" or cs != "PASS":
        raise SystemExit(f"ERROR: QUIC runtime activity not PASS: server={ss} client={cs}")
    if st != ct:
        raise SystemExit(f"ERROR: server/client QUIC CPU targets differ: {st} vs {ct}")
    common = sorted(set(sa) & set(ca))
    if common != st:
        raise SystemExit(
            f"ERROR: not every target QUIC CPU active on both endpoints: targets={st} server={sa} client={ca}"
        )

    rows = list(csv.DictReader(args.goodput.open(newline="", encoding="utf-8")))
    if not rows:
        raise SystemExit("ERROR: empty goodput CSV")
    fields = [
        "mode", "n", "mean_goodput_gbps", "stdev_goodput_gbps",
        "variance_goodput_gbps2", "min_goodput_gbps", "max_goodput_gbps",
        "dataplane_core_count", "normalized_goodput_per_dataplane_core_gbps",
        "verified_quic_core_count", "verified_quic_cpus",
        "normalized_goodput_per_verified_quic_core_gbps", "semantics",
    ]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for r in rows:
            mean = float(r["mean_goodput_gbps"])
            w.writerow({
                "mode": r["mode"],
                "n": r["n"],
                "mean_goodput_gbps": f"{mean:.6f}",
                "stdev_goodput_gbps": f"{float(r['stdev_goodput_gbps']):.6f}",
                "variance_goodput_gbps2": f"{float(r['variance_goodput_gbps2']):.6f}",
                "min_goodput_gbps": f"{float(r['min_goodput_gbps']):.6f}",
                "max_goodput_gbps": f"{float(r['max_goodput_gbps']):.6f}",
                "dataplane_core_count": args.dataplane_cores,
                "normalized_goodput_per_dataplane_core_gbps": f"{mean / args.dataplane_cores:.6f}",
                "verified_quic_core_count": len(common),
                "verified_quic_cpus": ";".join(map(str, common)),
                "normalized_goodput_per_verified_quic_core_gbps": f"{mean / len(common):.6f}",
                "semantics": "normalized aggregate goodput; not direct payload-byte attribution to a CPU",
            })

    print("PER-CORE GOODPUT SUMMARY (normalized; not direct byte attribution)")
    for r in csv.DictReader(args.output.open(newline="", encoding="utf-8")):
        print(
            f"  {r['mode'].upper()}: aggregate={float(r['mean_goodput_gbps']):.6f} Gbit/s "
            f"/ {r['dataplane_core_count']} dataplane={float(r['normalized_goodput_per_dataplane_core_gbps']):.6f} "
            f"/ {r['verified_quic_core_count']} verified QUIC={float(r['normalized_goodput_per_verified_quic_core_gbps']):.6f} Gbit/s/core"
        )
    print(f"CSV: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
