#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path


def get(d, *ks):
    for k in ks:
        if not isinstance(d, dict):
            return None
        d = d.get(k)
    return d


def fmt(v, unit="", digits=6):
    if not isinstance(v, (int, float)) or not math.isfinite(float(v)):
        return "N/A"
    return f"{float(v):.{digits}f}{(' ' + unit) if unit else ''}"


def print_rep(root: Path, rep: int) -> None:
    cdir = root / "runs" / "client" / f"rep{rep:02d}"
    sdir = root / "runs" / "server" / f"rep{rep:02d}"
    cp = cdir / "summary.json"
    sp = sdir / "summary.json"
    if not cp.is_file() or not sp.is_file():
        raise SystemExit(f"missing P7 summary for repetition {rep}: {cp} / {sp}")
    c = json.loads(cp.read_text())
    s = json.loads(sp.read_text())

    downloads = int(c.get("downloads") or 0)
    per = int(c.get("payload_bytes_per_download") or 0)
    total = int(c.get("useful_bytes") or 0)
    active_us = c.get("download_duration_us_total")
    workload_us = c.get("workload_elapsed_us")
    gp = c.get("goodput_active_downloads_gbps", c.get("goodput_gbps"))
    gp_gap = c.get("goodput_workload_including_gaps_gbps", c.get("gap_inclusive_goodput_gbps"))

    se = get(s, "scopes", "active", "rapl", "total_j")
    ce = get(c, "scopes", "active", "rapl", "total_j")
    spw = get(s, "scopes", "active", "rapl", "total_w")
    cpw = get(c, "scopes", "active", "rapl", "total_w")
    ee = se + ce if isinstance(se, (int, float)) and isinstance(ce, (int, float)) else None
    pp = spw + cpw if isinstance(spw, (int, float)) and isinstance(cpw, (int, float)) else None

    print("\n=== P7 Linux Workload Summary ===")
    print(f"- Repetition: {rep}")
    print(f"- Client processes: 1")
    print(f"- QUIC connections: 1")
    print(f"- Sequential streams/downloads: {downloads}")
    print(f"- Payload per download: {per / (1024 ** 3):.3f} GiB")
    print(f"- Total payload: {total / (1024 ** 3):.3f} GiB")
    print(f"- Sum of download durations: {fmt(active_us / 1e6 if isinstance(active_us, (int, float)) else None, 's')}")
    print(f"- Workload elapsed time including gaps: {fmt(workload_us / 1e6 if isinstance(workload_us, (int, float)) else None, 's')}")
    print(f"- Aggregate goodput excluding gaps: {fmt(gp, 'Gbit/s')}")
    print(f"- Aggregate goodput including gaps: {fmt(gp_gap, 'Gbit/s')}")
    print(f"- Active RAPL energy: server {fmt(se, 'J')} | client {fmt(ce, 'J')} | combined {fmt(ee, 'J')}")
    print(f"- Active RAPL power:  server {fmt(spw, 'W')} | client {fmt(cpw, 'W')} | combined {fmt(pp, 'W')}")
    print("- Goodput rule: identical to P5: total payload bits divided by the sum of client-reported per-download duration_us; gap-inclusive goodput uses first request start to last request completion.")


def print_matrix(root: Path) -> None:
    p = root / "p7_statistics.json"
    if not p.is_file():
        raise SystemExit(f"missing P7 matrix statistics: {p}")
    s = json.loads(p.read_text())

    def line(key, label, unit):
        v = s.get(key, {}) or {}
        n = int(v.get("n") or 0)
        mu = v.get("mean")
        sd = v.get("sd")
        if not isinstance(mu, (int, float)):
            return f"- {label}: N/A (n={n})"
        if not isinstance(sd, (int, float)):
            return f"- {label}: {mu:.6f} {unit} (n={n}; SD N/A)"
        return f"- {label}: {mu:.6f} ± {sd:.6f} {unit} (n={n})"

    print("\n=== P7 Linux Matrix Summary — BEFORE CHART GENERATION ===")
    for key, label, unit in (
        ("goodput_gbps", "Aggregate goodput excluding gaps", "Gbit/s"),
        ("gap_inclusive_goodput_gbps", "Aggregate goodput including gaps", "Gbit/s"),
        ("combined_active_energy_j", "Combined active RAPL energy", "J"),
        ("combined_active_power_w", "Combined active RAPL power", "W"),
        ("combined_active_j_per_useful_gbit", "Combined active energy cost", "J/Gbit"),
        ("combined_combined_energy_j", "Combined D1→Dn RAPL energy", "J"),
        ("combined_combined_j_per_useful_gbit", "Combined D1→Dn energy cost", "J/Gbit"),
    ):
        print(line(key, label, unit))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--matrix-dir", type=Path, required=True)
    group = ap.add_mutually_exclusive_group(required=True)
    group.add_argument("--rep", type=int)
    group.add_argument("--matrix", action="store_true")
    args = ap.parse_args()
    if args.rep is not None:
        print_rep(args.matrix_dir, args.rep)
    else:
        print_matrix(args.matrix_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
