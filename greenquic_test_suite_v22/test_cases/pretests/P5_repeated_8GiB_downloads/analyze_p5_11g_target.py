#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import math
import re
import statistics
from pathlib import Path

PAYLOAD = 8589934592
BITS = PAYLOAD * 8.0
HISTORICAL_PLUS_STEADY_GBPS = 10.486178
COMPLETE = re.compile(
    r"\[GreenQUIC-P5\]\s+request=(\d+)/(\d+).*?\bduration_us=(\d+).*?\bsuccess=1"
)


def mean_sd(values: list[float]) -> tuple[float, float]:
    return (
        statistics.mean(values),
        statistics.stdev(values) if len(values) > 1 else 0.0,
    )


def pct(new: float, base: float) -> float:
    return 100.0 * (new / base - 1.0) if base else math.nan


def tcrit90(n: int) -> float:
    table = {
        1: 6.314,
        2: 2.920,
        3: 2.353,
        4: 2.132,
        5: 2.015,
        6: 1.943,
        7: 1.895,
        8: 1.860,
        9: 1.833,
        10: 1.812,
        11: 1.796,
        12: 1.782,
        13: 1.771,
        14: 1.761,
        15: 1.753,
        16: 1.746,
        17: 1.740,
        18: 1.734,
        19: 1.729,
        20: 1.725,
        21: 1.721,
        22: 1.717,
        23: 1.714,
        24: 1.711,
        25: 1.708,
        26: 1.706,
        27: 1.703,
        28: 1.701,
        29: 1.699,
        30: 1.697,
    }
    if n <= 1:
        return math.inf
    df = n - 1
    return table.get(df, 1.645 if df > 30 else table[30])


def parse_log(path: Path, downloads: int) -> tuple[float, float]:
    rows: dict[int, int] = {}
    total = None
    text = path.read_text(encoding="utf-8", errors="replace")
    for match in COMPLETE.finditer(text):
        idx, observed_total, duration_us = map(int, match.groups())
        rows[idx] = duration_us
        total = observed_total
    if total != downloads or any(i not in rows for i in range(1, downloads + 1)):
        raise RuntimeError(f"incomplete timing evidence: {path}")
    durations = [rows[i] for i in range(1, downloads + 1)]
    aggregate = BITS * downloads / (sum(durations) / 1e6) / 1e9
    steady = (
        BITS * (downloads - 1) / (sum(durations[1:]) / 1e6) / 1e9
        if downloads > 1
        else aggregate
    )
    return aggregate, steady


def stats_from_logs(logs: list[Path], downloads: int) -> dict[str, object]:
    if not logs:
        raise RuntimeError("no PLUS client logs")
    values = [parse_log(path, downloads) for path in logs]
    aggregate_values = [v[0] for v in values]
    steady_values = [v[1] for v in values]
    aggregate_mean, aggregate_sd = mean_sd(aggregate_values)
    steady_mean, steady_sd = mean_sd(steady_values)
    return {
        "n": len(values),
        "aggregate_mean": aggregate_mean,
        "aggregate_sd": aggregate_sd,
        "steady_mean": steady_mean,
        "steady_sd": steady_sd,
        "aggregate_values": aggregate_values,
        "steady_values": steady_values,
        "steady_min": min(steady_values),
        "steady_max": max(steady_values),
    }


def stats(case_dir: Path, downloads: int) -> dict[str, object]:
    return stats_from_logs(sorted(case_dir.glob("client_rep??_plus.log")), downloads)


def screen(root: Path, downloads: int, target: float) -> None:
    spec = root / "SCREEN_CASES.tsv"
    rows: list[dict[str, object]] = []
    for row in csv.DictReader(spec.open(encoding="utf-8"), delimiter="\t"):
        measured = stats(root / row["case"], downloads)
        rows.append(
            {
                **row,
                **measured,
                "target_reached_screen": float(measured["steady_mean"]) >= target,
            }
        )
    if not rows:
        raise SystemExit("ERROR: no 11G screen cases")

    by_case = {str(row["case"]): row for row in rows}
    baseline = by_case.get("s0_super_default")
    if baseline is None:
        raise SystemExit("ERROR: s0_super_default missing from screen")
    baseline_steady = float(baseline["steady_mean"])
    for row in rows:
        row["steady_vs_super_pct"] = pct(float(row["steady_mean"]), baseline_steady)

    rows.sort(
        key=lambda row: (float(row["steady_mean"]), float(row["aggregate_mean"])),
        reverse=True,
    )
    winner = rows[0]

    fields = [
        "case",
        "binary_profile",
        "rx_empty_polls",
        "tx_empty_polls",
        "active_transfer_sleep_min_level",
        "n",
        "aggregate_mean",
        "aggregate_sd",
        "steady_mean",
        "steady_sd",
        "steady_min",
        "steady_max",
        "steady_vs_super_pct",
        "target_reached_screen",
    ]
    with (root / "SCREEN_SUMMARY.tsv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, delimiter="\t", extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)

    (root / "WINNER.env").write_text(
        "\n".join(
            [
                f"winner_case={winner['case']}",
                f"winner_binary_profile={winner['binary_profile']}",
                f"winner_rx_empty_polls={winner['rx_empty_polls']}",
                f"winner_tx_empty_polls={winner['tx_empty_polls']}",
                f"winner_active_transfer_sleep_min_level={winner['active_transfer_sleep_min_level']}",
                f"winner_screen_steady_gbps={float(winner['steady_mean']):.9f}",
                f"winner_screen_vs_super_pct={float(winner['steady_vs_super_pct']):.6f}",
                f"target_gbps={target:.6f}",
            ]
        )
        + "\n",
        encoding="utf-8",
    )

    output = {
        "schema": "greenquic-p5-onecore-11g-screen-v2",
        "target_gbps": target,
        "historical_plus_steady_d2plus_gbps": HISTORICAL_PLUS_STEADY_GBPS,
        "baseline": baseline,
        "winner": winner,
        "rows": rows,
        "rule": "screen is directional only; target requires paired repeated validation",
    }
    (root / "SCREEN_SUMMARY.json").write_text(
        json.dumps(output, indent=2) + "\n", encoding="utf-8"
    )

    print(
        f"11G SCREEN WINNER case={winner['case']} "
        f"steady={float(winner['steady_mean']):.6f} Gbit/s "
        f"vs_super={float(winner['steady_vs_super_pct']):+.3f}%"
    )
    if float(winner["steady_mean"]) >= target:
        print("11G SCREEN HIT (directional only; repeated validation still required)")
    else:
        print("11G SCREEN BELOW TARGET; validating best candidate anyway")
    if float(winner["steady_vs_super_pct"]) <= 2.0:
        print("11G SCREEN: no >2% structural tuning signal versus Super reference")


def validation(root: Path, downloads: int, target: float, min_robust: int) -> None:
    validation_root = root / "validation"
    winner_logs = sorted(validation_root.glob("rep??_winner/client_rep??_plus.log"))
    reference_logs = sorted(validation_root.glob("rep??_super_reference/client_rep??_plus.log"))
    winner = stats_from_logs(winner_logs, downloads)
    reference = stats_from_logs(reference_logs, downloads)

    winner_values = [float(x) for x in winner["steady_values"]]
    reference_values = [float(x) for x in reference["steady_values"]]
    if len(winner_values) != len(reference_values):
        raise SystemExit(
            "ERROR: paired validation repetition count mismatch: "
            f"winner={len(winner_values)} reference={len(reference_values)}"
        )

    n = len(winner_values)
    mean = float(winner["steady_mean"])
    sd = float(winner["steady_sd"])
    half = tcrit90(n) * sd / math.sqrt(n) if n > 1 else math.inf
    lo, hi = (
        (mean - half, mean + half)
        if math.isfinite(half)
        else (float("-inf"), float("inf"))
    )
    mean_pass = mean >= target
    single_hit = max(winner_values) >= target
    robust = n >= min_robust and lo >= target

    paired_rows = []
    for index, (winner_gbps, reference_gbps) in enumerate(
        zip(winner_values, reference_values), start=1
    ):
        paired_rows.append(
            {
                "rep": index,
                "winner_steady_gbps": winner_gbps,
                "reference_steady_gbps": reference_gbps,
                "winner_minus_reference_gbps": winner_gbps - reference_gbps,
                "winner_vs_reference_pct": pct(winner_gbps, reference_gbps),
                "winner_target_hit": int(winner_gbps >= target),
            }
        )
    paired_pct = [float(row["winner_vs_reference_pct"]) for row in paired_rows]
    paired_delta = [float(row["winner_minus_reference_gbps"]) for row in paired_rows]

    output = {
        "schema": "greenquic-p5-onecore-11g-validation-v2",
        "target_gbps": target,
        "historical_plus_steady_d2plus_gbps": HISTORICAL_PLUS_STEADY_GBPS,
        "winner": winner,
        "super_reference": reference,
        "winner_vs_reference_pct": pct(mean, float(reference["steady_mean"])),
        "winner_minus_reference_gbps": mean - float(reference["steady_mean"]),
        "winner_vs_historical_pct": pct(mean, HISTORICAL_PLUS_STEADY_GBPS),
        "winner_ci90_low_gbps": lo,
        "winner_ci90_high_gbps": hi,
        "single_run_target_hit": single_hit,
        "mean_target_pass": mean_pass,
        "robust_target_pass": robust,
        "robust_min_runs": min_robust,
        "paired_winner_vs_reference_pct_mean": statistics.mean(paired_pct),
        "paired_winner_minus_reference_gbps_mean": statistics.mean(paired_delta),
        "paired_rows": paired_rows,
        "validation_order": "alternating paired reference/winner order",
    }
    (root / "VALIDATION_SUMMARY.json").write_text(
        json.dumps(output, indent=2) + "\n", encoding="utf-8"
    )

    with (root / "VALIDATION_SUMMARY.tsv").open("w", newline="", encoding="utf-8") as handle:
        fields = [
            "case",
            "n",
            "aggregate_mean",
            "aggregate_sd",
            "steady_mean",
            "steady_sd",
            "steady_min",
            "steady_max",
            "ci90_low",
            "ci90_high",
            "target_pass",
        ]
        writer = csv.DictWriter(handle, fieldnames=fields, delimiter="\t")
        writer.writeheader()
        writer.writerow(
            {
                "case": "winner",
                "n": n,
                "aggregate_mean": winner["aggregate_mean"],
                "aggregate_sd": winner["aggregate_sd"],
                "steady_mean": mean,
                "steady_sd": sd,
                "steady_min": winner["steady_min"],
                "steady_max": winner["steady_max"],
                "ci90_low": lo,
                "ci90_high": hi,
                "target_pass": int(mean_pass),
            }
        )
        writer.writerow(
            {
                "case": "super_reference",
                "n": reference["n"],
                "aggregate_mean": reference["aggregate_mean"],
                "aggregate_sd": reference["aggregate_sd"],
                "steady_mean": reference["steady_mean"],
                "steady_sd": reference["steady_sd"],
                "steady_min": reference["steady_min"],
                "steady_max": reference["steady_max"],
                "ci90_low": "NA",
                "ci90_high": "NA",
                "target_pass": int(float(reference["steady_mean"]) >= target),
            }
        )

    with (root / "VALIDATION_PAIRED.tsv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(paired_rows[0].keys()), delimiter="\t")
        writer.writeheader()
        writer.writerows(paired_rows)

    print(
        f"11G VALIDATION winner steady={mean:.6f} sd={sd:.6f} n={n} "
        f"min={float(winner['steady_min']):.6f} max={float(winner['steady_max']):.6f} "
        f"CI90=[{lo:.6f},{hi:.6f}]"
    )
    print(
        f"SUPER REFERENCE steady={float(reference['steady_mean']):.6f} Gbit/s; "
        f"winner_delta={pct(mean, float(reference['steady_mean'])):+.3f}%"
    )
    if mean_pass:
        print("11G PASS (repeated validation mean >= target)")
    elif single_hit:
        print("11G SINGLE-RUN HIT ONLY (validation mean remains below target)")
    else:
        print("11G TARGET NOT REACHED")

    if robust:
        print("11G ROBUST PASS (90% CI lower bound >= target)")
    elif n >= min_robust:
        print("11G ROBUST PASS NOT ESTABLISHED")
    else:
        print(
            f"11G ROBUST TEST NOT ELIGIBLE: n={n} < required {min_robust} repetitions"
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--phase", choices=["screen", "validation"], required=True)
    parser.add_argument("--downloads", type=int, required=True)
    parser.add_argument("--target-gbps", type=float, default=11.0)
    parser.add_argument("--robust-min-runs", type=int, default=6)
    args = parser.parse_args()
    if args.phase == "screen":
        screen(args.root.resolve(), args.downloads, args.target_gbps)
    else:
        validation(
            args.root.resolve(),
            args.downloads,
            args.target_gbps,
            args.robust_min_runs,
        )


if __name__ == "__main__":
    main()
