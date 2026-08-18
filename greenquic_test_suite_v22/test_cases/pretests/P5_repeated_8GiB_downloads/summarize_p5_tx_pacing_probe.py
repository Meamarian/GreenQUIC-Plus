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
STAT = re.compile(
    r"\[P5-TX-PACING\] backoff_ns=(\d+) sleep_us=(\d+) "
    r"empty_dequeues=(\d+) nonempty_dequeues=(\d+) dequeued_packets=(\d+) "
    r"bin1=(\d+) bin2_4=(\d+) bin5_8=(\d+) bin9_16=(\d+) bin17plus=(\d+)"
)
COMPLETE = re.compile(
    r"\[GreenQUIC-P5\]\s+request=(\d+)/(\d+).*?"
    r"\bduration_us=(\d+).*?\bsuccess=1"
)


def mean_sd(values: list[float]) -> tuple[float, float]:
    if not values:
        return math.nan, math.nan
    return statistics.mean(values), statistics.stdev(values) if len(values) > 1 else 0.0


def pct(new: float, base: float) -> float:
    return 100.0 * (new / base - 1.0) if base else math.nan


def parse_stat(path: Path) -> dict[str, int]:
    matches = list(STAT.finditer(path.read_text(encoding="utf-8", errors="replace")))
    if not matches:
        raise RuntimeError(f"missing [P5-TX-PACING] line: {path}")
    keys = (
        "backoff_ns", "sleep_us", "empty_dequeues", "nonempty_dequeues",
        "dequeued_packets", "bin1", "bin2_4", "bin5_8", "bin9_16", "bin17plus",
    )
    return {k: int(v) for k, v in zip(keys, matches[-1].groups())}


def parse_goodput(path: Path) -> dict[str, float]:
    text = path.read_text(encoding="utf-8", errors="replace")
    rows: dict[int, int] = {}
    total = None
    for m in COMPLETE.finditer(text):
        i, n, dur = int(m.group(1)), int(m.group(2)), int(m.group(3))
        total = n
        rows[i] = dur
    if total is None or len(rows) < total or any(i not in rows for i in range(1, total + 1)):
        raise RuntimeError(f"incomplete P5 request timing evidence: {path}")
    bits = PAYLOAD_BYTES * 8.0
    durations = [rows[i] for i in range(1, total + 1)]
    aggregate = bits * total / (sum(durations) / 1_000_000.0) / 1e9
    d1 = bits / (durations[0] / 1_000_000.0) / 1e9
    steady_rows = durations[1:]
    steady = bits * len(steady_rows) / (sum(steady_rows) / 1_000_000.0) / 1e9
    return {"aggregate_gbps": aggregate, "d1_gbps": d1, "steady_d2plus_gbps": steady}


def aggregate_role_stats(paths: list[Path]) -> dict[str, float]:
    stats = [parse_stat(p) for p in paths]
    if not stats:
        raise RuntimeError("no pacing stats")
    signature = {(s["backoff_ns"], s["sleep_us"]) for s in stats}
    if len(signature) != 1:
        raise RuntimeError(f"mixed pacing signatures across repetitions: {sorted(signature)}")
    sums = {k: sum(s[k] for s in stats) for k in (
        "empty_dequeues", "nonempty_dequeues", "dequeued_packets",
        "bin1", "bin2_4", "bin5_8", "bin9_16", "bin17plus",
    )}
    calls = sums["nonempty_dequeues"]
    packets = sums["dequeued_packets"]
    empty = sums["empty_dequeues"]
    return {
        "backoff_ns": stats[0]["backoff_ns"],
        "sleep_us": stats[0]["sleep_us"],
        **sums,
        "packets_per_nonempty_dequeue": packets / calls if calls else 0.0,
        "empty_per_nonempty_dequeue": empty / calls if calls else 0.0,
        "empty_dequeues_per_1m_packets": empty * 1_000_000.0 / packets if packets else 0.0,
        "bin1_pct": 100.0 * sums["bin1"] / calls if calls else 0.0,
        "bin2_4_pct": 100.0 * sums["bin2_4"] / calls if calls else 0.0,
        "bin5_8_pct": 100.0 * sums["bin5_8"] / calls if calls else 0.0,
        "bin9_16_pct": 100.0 * sums["bin9_16"] / calls if calls else 0.0,
        "bin17plus_pct": 100.0 * sums["bin17plus"] / calls if calls else 0.0,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", type=Path, required=True)
    args = ap.parse_args()
    root = args.root.resolve()

    rows: list[dict[str, object]] = []
    expected = [
        "p0_no_backoff", "p1_busy_250ns", "p2_busy_500ns",
        "p3_busy_1000ns", "p4_sleep_1us",
    ]
    for name in expected:
        case_dir = root / name
        if not case_dir.is_dir():
            raise SystemExit(f"ERROR: pacing case directory missing: {case_dir}")
        client_logs = sorted(case_dir.glob("client_rep??_off.log"))
        server_logs = sorted(case_dir.glob("server_rep??_off.log"))
        if not client_logs or not server_logs:
            raise SystemExit(f"ERROR: standard one-core P5 logs missing for {name}")

        gp = [parse_goodput(p) for p in client_logs]
        agg_mean, agg_sd = mean_sd([x["aggregate_gbps"] for x in gp])
        steady_mean, steady_sd = mean_sd([x["steady_d2plus_gbps"] for x in gp])
        d1_mean, d1_sd = mean_sd([x["d1_gbps"] for x in gp])
        server = aggregate_role_stats(server_logs)
        client = aggregate_role_stats(client_logs)

        if int(client["backoff_ns"]) != 0 or int(client["sleep_us"]) != 0:
            raise SystemExit(f"ERROR: client intervention leaked into {name}: {client}")

        rows.append({
            "case": name,
            "server_backoff_ns": int(server["backoff_ns"]),
            "server_sleep_us": int(server["sleep_us"]),
            "runs": len(client_logs),
            "aggregate_gbps_mean": agg_mean,
            "aggregate_gbps_sd": agg_sd,
            "d1_gbps_mean": d1_mean,
            "d1_gbps_sd": d1_sd,
            "steady_d2plus_gbps_mean": steady_mean,
            "steady_d2plus_gbps_sd": steady_sd,
            "server_empty_dequeues": int(server["empty_dequeues"]),
            "server_nonempty_dequeues": int(server["nonempty_dequeues"]),
            "server_dequeued_packets": int(server["dequeued_packets"]),
            "server_packets_per_nonempty_dequeue": float(server["packets_per_nonempty_dequeue"]),
            "server_empty_per_nonempty_dequeue": float(server["empty_per_nonempty_dequeue"]),
            "server_empty_dequeues_per_1m_packets": float(server["empty_dequeues_per_1m_packets"]),
            "server_bin1_pct": float(server["bin1_pct"]),
            "server_bin2_4_pct": float(server["bin2_4_pct"]),
            "server_bin5_8_pct": float(server["bin5_8_pct"]),
            "server_bin9_16_pct": float(server["bin9_16_pct"]),
            "server_bin17plus_pct": float(server["bin17plus_pct"]),
            "client_zero_backoff_runtime_proof": 1,
        })

    baseline = rows[0]
    for row in rows:
        row["aggregate_vs_baseline_pct"] = pct(
            float(row["aggregate_gbps_mean"]), float(baseline["aggregate_gbps_mean"])
        )
        row["steady_vs_baseline_pct"] = pct(
            float(row["steady_d2plus_gbps_mean"]), float(baseline["steady_d2plus_gbps_mean"])
        )
        row["server_batch_vs_baseline_pct"] = pct(
            float(row["server_packets_per_nonempty_dequeue"]),
            float(baseline["server_packets_per_nonempty_dequeue"]),
        )
        row["server_empty_rate_vs_baseline_pct"] = pct(
            float(row["server_empty_dequeues_per_1m_packets"]),
            float(baseline["server_empty_dequeues_per_1m_packets"]),
        )

    busy = [r for r in rows if int(r["server_backoff_ns"]) > 0 and int(r["server_sleep_us"]) == 0]
    sleep = [r for r in rows if int(r["server_sleep_us"]) > 0]
    best_busy = max(busy, key=lambda r: float(r["steady_d2plus_gbps_mean"])) if busy else None
    best_sleep = max(sleep, key=lambda r: float(r["steady_d2plus_gbps_mean"])) if sleep else None

    evidence: list[str] = []
    if best_busy and float(best_busy["steady_vs_baseline_pct"]) > 2.0:
        if float(best_busy["server_batch_vs_baseline_pct"]) > 2.0:
            evidence.append(
                "A non-yielding busy backoff improved steady goodput and server packets per non-empty dequeue by >2%; "
                "this supports producer/consumer pacing with larger effective TX batches as a causal contributor."
            )
        else:
            evidence.append(
                "A non-yielding busy backoff improved steady goodput by >2% without a >2% batch increase; "
                "timing at the handoff matters, but this probe does not establish micro-batching as the mechanism."
            )
        if float(best_busy["server_empty_rate_vs_baseline_pct"]) < -10.0:
            evidence.append(
                "The winning busy-backoff case also reduced empty TX-ring dequeues per million transmitted packets by >10%; "
                "this supports wasteful consumer polling/coherence pressure as part of the bottleneck, but is not direct cache-line proof."
            )
    if best_sleep and best_busy:
        extra = float(best_sleep["steady_vs_baseline_pct"]) - float(best_busy["steady_vs_baseline_pct"])
        if extra > 2.0:
            evidence.append(
                "The 1-us yielding sleep beats the best non-yielding busy backoff by >2 percentage points of steady goodput; "
                "an additional scheduler-donation and/or package-frequency effect is supported."
            )
    if not evidence:
        evidence.append(
            "The quick one-core pacing screen established no >2% causal mechanism signal; do not claim batching, scheduler donation, or polling relief from this screen."
        )

    out_tsv = root / "TX_PACING_SUMMARY.tsv"
    with out_tsv.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()), delimiter="\t")
        w.writeheader(); w.writerows(rows)

    result = {
        "schema": "greenquic-p5-onecore-tx-pacing-probe-v2",
        "scope": "one DPDK lcore, one QUIC connection, repeated 8-GiB downloads, server-only OFF TX empty-dequeue intervention",
        "historical_reference": {
            "off_steady_d2plus_gbps": 9.423551,
            "plus_steady_d2plus_gbps": 10.486178,
        },
        "baseline": baseline,
        "rows": rows,
        "best_busy": best_busy,
        "best_sleep": best_sleep,
        "evidence": evidence,
    }
    (root / "TX_PACING_SUMMARY.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")

    md = [
        "# P5 one-core TX pacing bottleneck result",
        "",
        "This probe uses the historical Super Performance execution shape: one DPDK lcore, one QUIC connection, repeated 8-GiB downloads. Only the server binary changes between pacing cases; the client is always the zero-backoff binary.",
        "",
        "| case | server intervention | aggregate | steady D2+ | steady delta | server pkts/nonempty dequeue | batch delta | empty dequeues / 1M packets |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for r in rows:
        intervention = f"{r['server_backoff_ns']} ns busy" if int(r["server_backoff_ns"]) else (
            f"{r['server_sleep_us']} us sleep" if int(r["server_sleep_us"]) else "none"
        )
        md.append(
            f"| {r['case']} | {intervention} | {r['aggregate_gbps_mean']:.6f} | "
            f"{r['steady_d2plus_gbps_mean']:.6f} | {r['steady_vs_baseline_pct']:+.3f}% | "
            f"{r['server_packets_per_nonempty_dequeue']:.3f} | {r['server_batch_vs_baseline_pct']:+.3f}% | "
            f"{r['server_empty_dequeues_per_1m_packets']:.1f} |"
        )
    md += ["", "## Causal interpretation", ""] + [f"- {x}" for x in evidence]
    md += [
        "",
        "Busy-backoff cases spin on the DPDK lcore and therefore do not voluntarily donate that CPU to Linux. A goodput gain in those cases isolates timing/batching/coherence effects from scheduler donation. The 1-us sleep case is intentionally separate because it may yield the CPU and change package power/frequency behavior.",
    ]
    (root / "TX_PACING_SUMMARY.md").write_text("\n".join(md) + "\n", encoding="utf-8")

    print(f"P5 ONE-CORE TX PACING SUMMARY: {out_tsv}")
    for r in rows:
        print(
            f"{r['case']}: aggregate={r['aggregate_gbps_mean']:.6f} "
            f"steady={r['steady_d2plus_gbps_mean']:.6f} Gbit/s "
            f"steady_delta={r['steady_vs_baseline_pct']:+.3f}% "
            f"server_packets/dequeue={r['server_packets_per_nonempty_dequeue']:.3f} "
            f"empty/1Mpkts={r['server_empty_dequeues_per_1m_packets']:.1f}"
        )
    for item in evidence:
        print("EVIDENCE:", item)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
