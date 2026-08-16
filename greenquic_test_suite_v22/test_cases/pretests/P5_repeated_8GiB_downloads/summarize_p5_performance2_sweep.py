#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import re
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("result_root", type=Path)
    args = ap.parse_args()
    root = args.result_root
    table = root / "comparison_table.tsv"
    if not table.is_file():
        raise SystemExit(f"ERROR: missing {table}")

    rows = list(csv.DictReader(table.open(encoding="utf-8"), delimiter="\t"))
    out_rows = []
    aliases = {
        "udp_seg2": "baseline",
        "udp_seg4": "baseline",
        "udp_seg8": "baseline",
        "sharded_udp4": "sharded_1024",
        "all_p2": "sharded_rxprefetch",
    }

    for row in rows:
        idx = row["index"]
        profile = row["profile"]
        log = root / "logs" / f"run_{idx}_{profile}.log"
        text = log.read_text(errors="replace") if log.is_file() else ""
        states = re.findall(r"\[P5-PERF2-USO\].*?requested=1 active=([01])", text)
        uso_requested = profile in aliases
        if uso_requested:
            uso_active = "1" if states and all(v == "1" for v in states) else "0"
        else:
            uso_active = "NA"
        fully_active = "1"
        effective = profile
        if uso_requested and uso_active == "0":
            fully_active = "0"
            effective = aliases[profile]
        out_rows.append({
            **row,
            "effective_profile": effective,
            "uso_requested": "1" if uso_requested else "0",
            "uso_active": uso_active,
            "requested_config_fully_active": fully_active,
        })

    fields = list(rows[0].keys()) + [
        "effective_profile",
        "uso_requested",
        "uso_active",
        "requested_config_fully_active",
    ] if rows else []
    out = root / "effective_comparison.tsv"
    with out.open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields, delimiter="\t")
        w.writeheader()
        w.writerows(out_rows)

    print("\nEFFECTIVE PERFORMANCE2 CONFIGURATIONS")
    for row in out_rows:
        extra = ""
        if row["requested_config_fully_active"] == "0":
            extra = f"  [USO INACTIVE -> effective={row['effective_profile']}]"
        print(
            f"{row['index']} {row['profile']:<22} "
            f"PLUS_steady={row.get('plus_steady','NA')} "
            f"avg_steady={row.get('avg_steady','NA')}{extra}"
        )

    inactive = [r for r in out_rows if r["requested_config_fully_active"] == "0"]
    if inactive:
        print("\nWARNING: UDP segmentation was requested but did not become active for:")
        for row in inactive:
            print(f"  {row['profile']} -> {row['effective_profile']}")
        print("Do not attribute a goodput change in these rows to UDP segmentation.")

    # Rank unique effective configurations only, preferring PLUS steady then 3-mode mean.
    best = {}
    for row in out_rows:
        def val(name: str) -> float:
            try:
                return float(row[name])
            except Exception:
                return float("-inf")
        key = row["effective_profile"]
        score = (val("plus_steady"), val("avg_steady"), val("worst_steady"))
        if key not in best or score > best[key][0]:
            best[key] = (score, row)
    ranking = sorted(best.values(), key=lambda x: x[0], reverse=True)
    rank_out = root / "effective_ranking.tsv"
    rank_fields = ["rank", "effective_profile", "source_profile", "plus_steady", "avg_steady", "worst_steady", "uso_active"]
    with rank_out.open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=rank_fields, delimiter="\t")
        w.writeheader()
        for i, (_, row) in enumerate(ranking, 1):
            w.writerow({
                "rank": i,
                "effective_profile": row["effective_profile"],
                "source_profile": row["profile"],
                "plus_steady": row.get("plus_steady", "NA"),
                "avg_steady": row.get("avg_steady", "NA"),
                "worst_steady": row.get("worst_steady", "NA"),
                "uso_active": row["uso_active"],
            })
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
