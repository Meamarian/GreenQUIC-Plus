#!/usr/bin/env python3
from __future__ import annotations

"""Write normalized goodput and report observed QUIC-worker CPU activity.

Configured QUIC CPUs are part of the experiment contract. Actual use of every
configured worker CPU is diagnostic scheduler/partition evidence, not a hard
fairness requirement. Aggregate goodput is therefore normalized by the fixed
configured dataplane-core count and configured QUIC-core count. A second field
also reports normalization by CPUs that were observed active on both endpoints,
without claiming direct byte attribution to a CPU.
"""

import argparse
import csv
import json
from pathlib import Path


def load_activity(path: Path) -> tuple[list[int], list[int], str]:
    data = json.loads(path.read_text(encoding="utf-8"))
    targets = sorted(int(x) for x in data.get("target_cpus", []))
    active = sorted(int(r["cpu"]) for r in data.get("rows", []) if r.get("active"))
    return targets, active, str(data.get("status", "UNKNOWN"))


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
    if st != ct:
        raise SystemExit(f"ERROR: server/client configured QUIC CPU sets differ: {st} vs {ct}")
    if not st:
        raise SystemExit("ERROR: configured QUIC CPU set is empty")
    common = sorted(set(sa) & set(ca))

    rows = list(csv.DictReader(args.goodput.open(newline="", encoding="utf-8")))
    if not rows:
        raise SystemExit("ERROR: empty goodput CSV")
    fields = [
        "mode", "n", "mean_goodput_gbps", "stdev_goodput_gbps",
        "variance_goodput_gbps2", "min_goodput_gbps", "max_goodput_gbps",
        "dataplane_core_count", "normalized_goodput_per_dataplane_core_gbps",
        "configured_quic_core_count", "configured_quic_cpus",
        "normalized_goodput_per_configured_quic_core_gbps",
        "server_active_quic_core_count", "server_active_quic_cpus", "server_quic_activity_status",
        "client_active_quic_core_count", "client_active_quic_cpus", "client_quic_activity_status",
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
                "configured_quic_core_count": len(st),
                "configured_quic_cpus": ";".join(map(str, st)),
                "normalized_goodput_per_configured_quic_core_gbps": f"{mean / len(st):.6f}",
                "server_active_quic_core_count": len(sa),
                "server_active_quic_cpus": ";".join(map(str, sa)),
                "server_quic_activity_status": ss,
                "client_active_quic_core_count": len(ca),
                "client_active_quic_cpus": ";".join(map(str, ca)),
                "client_quic_activity_status": cs,
                "verified_quic_core_count": len(common),
                "verified_quic_cpus": ";".join(map(str, common)),
                "normalized_goodput_per_verified_quic_core_gbps": (
                    f"{mean / len(common):.6f}" if common else ""
                ),
                "semantics": (
                    "normalized aggregate goodput; configured CPUs are the fairness contract; "
                    "observed active QUIC CPUs are diagnostic and are not direct payload-byte attribution"
                ),
            })

    print("PER-CORE GOODPUT SUMMARY (normalized; not direct byte attribution)")
    print(
        f"  QUIC configured={st}; server active={sa} ({ss}); client active={ca} ({cs}); "
        f"common active={common}"
    )
    for r in csv.DictReader(args.output.open(newline="", encoding="utf-8")):
        verified = r["normalized_goodput_per_verified_quic_core_gbps"] or "n/a"
        print(
            f"  {r['mode'].upper()}: aggregate={float(r['mean_goodput_gbps']):.6f} Gbit/s "
            f"/ {r['dataplane_core_count']} dataplane={float(r['normalized_goodput_per_dataplane_core_gbps']):.6f} "
            f"/ {r['configured_quic_core_count']} configured QUIC={float(r['normalized_goodput_per_configured_quic_core_gbps']):.6f} "
            f"/ common-active QUIC={verified} Gbit/s/core"
        )
    if ss != "PASS" or cs != "PASS":
        print("WARN: not every configured QUIC worker CPU was observed active; this is diagnostic only and does not invalidate/stop traffic.")
    print(f"CSV: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
