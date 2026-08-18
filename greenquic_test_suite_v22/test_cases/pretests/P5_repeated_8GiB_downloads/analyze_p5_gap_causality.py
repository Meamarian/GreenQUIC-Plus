#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import math
import re
import statistics
from pathlib import Path

PAYLOAD_BYTES = 8589934592
BITS = PAYLOAD_BYTES * 8.0
COMPLETE = re.compile(
    r"\[GreenQUIC-P5\]\s+request=(\d+)/(\d+).*?"
    r"\bduration_us=(\d+).*?\bsuccess=1"
)

HISTORICAL = {
    "off_aggregate_gbps": 9.179253,
    "off_steady_d2plus_gbps": 9.423551,
    "plus_aggregate_gbps": 9.881019,
    "plus_steady_d2plus_gbps": 10.486178,
}


def pct(new: float, base: float) -> float:
    return 100.0 * (new / base - 1.0) if base else math.nan


def mean_sd(v: list[float]) -> tuple[float, float]:
    if not v:
        return math.nan, math.nan
    return statistics.mean(v), statistics.stdev(v) if len(v) > 1 else 0.0


def parse_log(path: Path, downloads: int) -> dict[str, float]:
    rows: dict[int, int] = {}
    total = None
    for m in COMPLETE.finditer(path.read_text(encoding="utf-8", errors="replace")):
        idx, observed_total, duration_us = map(int, m.groups())
        rows[idx] = duration_us
        total = observed_total
    if total != downloads or any(i not in rows for i in range(1, downloads + 1)):
        raise RuntimeError(
            f"{path}: incomplete timing evidence total={total} "
            f"markers={sorted(rows)} expected_downloads={downloads}"
        )
    durations = [rows[i] for i in range(1, downloads + 1)]
    aggregate = BITS * downloads / (sum(durations) / 1_000_000.0) / 1e9
    d1 = BITS / (durations[0] / 1_000_000.0) / 1e9
    steady = (
        BITS * (downloads - 1) / (sum(durations[1:]) / 1_000_000.0) / 1e9
        if downloads > 1 else d1
    )
    return {
        "aggregate_gbps": aggregate,
        "d1_gbps": d1,
        "steady_d2plus_gbps": steady,
    }


def collect(case_dir: Path, mode: str, downloads: int) -> dict[str, object]:
    logs = sorted(case_dir.glob(f"client_rep??_{mode}.log"))
    if not logs:
        raise RuntimeError(f"no client logs for {case_dir.name} mode={mode}")
    runs = [parse_log(p, downloads) for p in logs]
    out: dict[str, object] = {"runs": len(runs)}
    for metric in ("aggregate_gbps", "d1_gbps", "steady_d2plus_gbps"):
        vals = [float(x[metric]) for x in runs]
        mean, sd = mean_sd(vals)
        out[f"{metric}_mean"] = mean
        out[f"{metric}_sd"] = sd
        out[f"{metric}_values"] = vals
    return out


def historical_derived() -> dict[str, float]:
    # Historical table has three downloads: 3/aggregate = 1/D1 + 2/steady.
    def d1(agg: float, steady: float) -> float:
        return 1.0 / (3.0 / agg - 2.0 / steady)
    off = d1(HISTORICAL["off_aggregate_gbps"], HISTORICAL["off_steady_d2plus_gbps"])
    plus = d1(HISTORICAL["plus_aggregate_gbps"], HISTORICAL["plus_steady_d2plus_gbps"])
    return {
        "off_implied_d1_gbps": off,
        "plus_implied_d1_gbps": plus,
        "plus_vs_off_implied_d1_pct": pct(plus, off),
        "plus_vs_off_steady_pct": pct(
            HISTORICAL["plus_steady_d2plus_gbps"],
            HISTORICAL["off_steady_d2plus_gbps"],
        ),
        "plus_vs_off_aggregate_pct": pct(
            HISTORICAL["plus_aggregate_gbps"],
            HISTORICAL["off_aggregate_gbps"],
        ),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", type=Path, required=True)
    ap.add_argument("--downloads", type=int, required=True)
    ap.add_argument("--signal-pp", type=float, default=5.0)
    args = ap.parse_args()

    root = args.root.resolve()
    gaps = [0, 1, 5]
    table: list[dict[str, object]] = []
    by_gap: dict[int, dict[str, dict[str, object]]] = {}

    for gap in gaps:
        by_gap[gap] = {}
        for mode in ("off", "plus"):
            name = f"gap{gap}_{mode}"
            case_dir = root / name
            if not case_dir.is_dir():
                raise SystemExit(f"ERROR: missing gap-causality case {case_dir}")
            stats = collect(case_dir, mode, args.downloads)
            by_gap[gap][mode] = stats
            table.append({
                "gap_seconds": gap,
                "mode": mode,
                "runs": stats["runs"],
                "aggregate_gbps_mean": stats["aggregate_gbps_mean"],
                "aggregate_gbps_sd": stats["aggregate_gbps_sd"],
                "d1_gbps_mean": stats["d1_gbps_mean"],
                "d1_gbps_sd": stats["d1_gbps_sd"],
                "steady_d2plus_gbps_mean": stats["steady_d2plus_gbps_mean"],
                "steady_d2plus_gbps_sd": stats["steady_d2plus_gbps_sd"],
            })

    deltas: list[dict[str, float]] = []
    for gap in gaps:
        off, plus = by_gap[gap]["off"], by_gap[gap]["plus"]
        row = {
            "gap_seconds": float(gap),
            "plus_vs_off_aggregate_pct": pct(
                float(plus["aggregate_gbps_mean"]), float(off["aggregate_gbps_mean"])
            ),
            "plus_vs_off_d1_pct": pct(
                float(plus["d1_gbps_mean"]), float(off["d1_gbps_mean"])
            ),
            "plus_vs_off_steady_pct": pct(
                float(plus["steady_d2plus_gbps_mean"]),
                float(off["steady_d2plus_gbps_mean"]),
            ),
        }
        row["steady_minus_d1_delta_pp"] = (
            row["plus_vs_off_steady_pct"] - row["plus_vs_off_d1_pct"]
        )
        deltas.append(row)

    d0 = next(x for x in deltas if x["gap_seconds"] == 0)
    d5 = next(x for x in deltas if x["gap_seconds"] == 5)
    gap_amplification = d5["plus_vs_off_steady_pct"] - d0["plus_vs_off_steady_pct"]

    evidence: list[str] = []
    if d5["plus_vs_off_steady_pct"] >= args.signal_pp and gap_amplification >= args.signal_pp:
        evidence.append(
            "The PLUS-minus-OFF steady-goodput advantage is at least the predeclared "
            "signal threshold at 5 s and grows by at least that many percentage points "
            "relative to gap=0. This supports a gap-conditioned carry-over mechanism."
        )
    if d5["steady_minus_d1_delta_pp"] >= args.signal_pp:
        evidence.append(
            "At gap=5 s, PLUS gains substantially more on D2+ than on D1. "
            "This supports an inter-download state/preconditioning effect rather than "
            "a constant per-packet speedup."
        )
    if d0["plus_vs_off_steady_pct"] >= 2.0:
        evidence.append(
            "PLUS still has a >=2% steady-goodput advantage with no configured inter-download "
            "gap, so an active-transfer timing/datapath effect may coexist with gap preconditioning."
        )
    else:
        evidence.append(
            "At gap=0 the PLUS-minus-OFF steady difference is <2%; if the 5-s signal is large, "
            "the dominant measured advantage is gap-conditioned rather than an always-on active-transfer speedup."
        )
    evidence.append(
        "A gap-conditioned result is consistent with lower polling power, thermal recovery, "
        "package/turbo headroom, and frequency-state carry-over. It does not by itself distinguish "
        "those mechanisms; use the recorded frequency/RAPL/C-state traces for that attribution."
    )

    with (root / "GAP_CAUSALITY_SUMMARY.tsv").open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(table[0].keys()), delimiter="\t")
        w.writeheader(); w.writerows(table)
    with (root / "GAP_CAUSALITY_DELTAS.tsv").open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(deltas[0].keys()), delimiter="\t")
        w.writeheader(); w.writerows(deltas)

    result = {
        "schema": "greenquic-p5-onecore-gap-causality-v1",
        "scope": "one DPDK owner, same Super binary, repeated 8-GiB single-connection downloads",
        "historical_table": HISTORICAL,
        "historical_derived": historical_derived(),
        "rows": table,
        "deltas": deltas,
        "gap5_minus_gap0_plus_off_steady_delta_pp": gap_amplification,
        "signal_threshold_pp": args.signal_pp,
        "evidence": evidence,
    }
    (root / "GAP_CAUSALITY_SUMMARY.json").write_text(
        json.dumps(result, indent=2) + "\n", encoding="utf-8"
    )

    md = [
        "# P5 one-core gap-causality result", "",
        "Primary question: does the PLUS goodput advantage grow after an idle gap, rather than appearing equally on the first transfer?", "",
        "| gap | OFF D1 | PLUS D1 | PLUS-OFF D1 | OFF D2+ | PLUS D2+ | PLUS-OFF D2+ | D2+ minus D1 delta |",
        "|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for d in deltas:
        gap = int(d["gap_seconds"]); off, plus = by_gap[gap]["off"], by_gap[gap]["plus"]
        md.append(
            f"| {gap}s | {off['d1_gbps_mean']:.6f} | {plus['d1_gbps_mean']:.6f} | "
            f"{d['plus_vs_off_d1_pct']:+.3f}% | {off['steady_d2plus_gbps_mean']:.6f} | "
            f"{plus['steady_d2plus_gbps_mean']:.6f} | {d['plus_vs_off_steady_pct']:+.3f}% | "
            f"{d['steady_minus_d1_delta_pp']:+.3f} pp |"
        )
    hd = historical_derived()
    md += ["", "## Historical clue", "",
        f"From the completed historical 3-download aggregate/steady table, the implied D1 values are {hd['off_implied_d1_gbps']:.6f} Gbit/s OFF and {hd['plus_implied_d1_gbps']:.6f} Gbit/s PLUS ({hd['plus_vs_off_implied_d1_pct']:+.3f}%), while historical D2+ was {hd['plus_vs_off_steady_pct']:+.3f}% PLUS versus OFF.",
        "", "## Interpretation", ""]
    md += [f"- {x}" for x in evidence]
    (root / "GAP_CAUSALITY_SUMMARY.md").write_text("\n".join(md) + "\n", encoding="utf-8")

    print("P5 GAP CAUSALITY SUMMARY")
    for d in deltas:
        print(f"gap={int(d['gap_seconds'])}s plus-off D1={d['plus_vs_off_d1_pct']:+.3f}% D2+={d['plus_vs_off_steady_pct']:+.3f}% carryover={d['steady_minus_d1_delta_pp']:+.3f}pp")
    print(f"gap5_minus_gap0_steady_delta={gap_amplification:+.3f}pp")
    for line in evidence: print(f"EVIDENCE: {line}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
