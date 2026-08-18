#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import math
import re
import statistics
from pathlib import Path

COMPLETE = re.compile(
    r"^\[GreenQUIC-P5\] request=(\d+)/(\d+) complete_us=(\d+) path=(\S+) "
    r"duration_us=(\d+) success=(0|1)$"
)
BITS_PER_DOWNLOAD = 8589934592 * 8


def parse_ini(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith(("#", ";")) or "=" not in line:
            continue
        key, value = line.split("=", 1)
        out[key.strip()] = value.strip()
    return out


def per_run_goodputs(matrix: Path, downloads: int) -> dict[str, list[dict[str, float]]]:
    result: dict[str, list[dict[str, float]]] = {m: [] for m in ("off", "basic", "plus")}
    for mode in result:
        logs = sorted(matrix.glob(f"client_rep??_{mode}.log"))
        for path in logs:
            durations: dict[int, int] = {}
            total = None
            for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
                m = COMPLETE.match(raw.strip())
                if not m:
                    continue
                idx, observed_total = int(m.group(1)), int(m.group(2))
                if int(m.group(6)) != 1:
                    raise RuntimeError(f"failed P5 request in {path}: {raw}")
                durations[idx] = int(m.group(5))
                total = observed_total
            if total != downloads or len(durations) != downloads:
                raise RuntimeError(
                    f"{path}: completed markers={len(durations)} total={total}, expected {downloads}"
                )
            ordered = [durations[i] for i in range(1, downloads + 1)]
            aggregate = BITS_PER_DOWNLOAD * downloads / (sum(ordered) / 1_000_000.0) / 1e9
            d1 = BITS_PER_DOWNLOAD / (ordered[0] / 1_000_000.0) / 1e9
            if downloads >= 2:
                steady = (
                    BITS_PER_DOWNLOAD * (downloads - 1)
                    / (sum(ordered[1:]) / 1_000_000.0)
                    / 1e9
                )
            else:
                steady = aggregate
            result[mode].append({
                "aggregate_gbps": aggregate,
                "d1_gbps": d1,
                "steady_d2plus_gbps": steady,
            })
    return result


def unique_configs(matrix: Path, role: str, mode: str, suffix: str) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    seen: set[str] = set()
    base = matrix / "runs" / role
    if not base.is_dir():
        return rows
    for p in base.rglob(f"*_{suffix}.txt"):
        low = p.name.lower()
        if f"__{role}__{mode}" not in low:
            continue
        data = parse_ini(p)
        key = json.dumps(data, sort_keys=True)
        if key not in seen:
            rows.append(data)
            seen.add(key)
    return rows


def mean_sd(values: list[float]) -> tuple[float, float]:
    if not values:
        return 0.0, 0.0
    return statistics.mean(values), statistics.stdev(values) if len(values) > 1 else 0.0


def pct(a: float, b: float) -> float:
    return 100.0 * (a / b - 1.0) if b else 0.0


def tcrit_90(n: int) -> float:
    """Two-sided 90% CI critical value (t_0.95, n-1)."""
    if n <= 1:
        return math.inf
    table = {
        1: 6.314, 2: 2.920, 3: 2.353, 4: 2.132, 5: 2.015,
        6: 1.943, 7: 1.895, 8: 1.860, 9: 1.833, 10: 1.812,
        11: 1.796, 12: 1.782, 13: 1.771, 14: 1.761, 15: 1.753,
        16: 1.746, 17: 1.740, 18: 1.734, 19: 1.729, 20: 1.725,
        21: 1.721, 22: 1.717, 23: 1.714, 24: 1.711, 25: 1.708,
        26: 1.706, 27: 1.703, 28: 1.701, 29: 1.699, 30: 1.697,
    }
    df = n - 1
    return table.get(df, 1.645 if df > 30 else table[30])


def paired_equivalence(off_values: list[float], on_values: list[float], bound: float) -> dict[str, object]:
    if len(off_values) != len(on_values) or not off_values:
        raise RuntimeError("recorder equivalence requires equal non-empty repetition counts")
    deltas = [pct(off, on) for off, on in zip(off_values, on_values)]
    mean = statistics.mean(deltas)
    sd = statistics.stdev(deltas) if len(deltas) > 1 else 0.0
    if len(deltas) > 1:
        half = tcrit_90(len(deltas)) * sd / math.sqrt(len(deltas))
        lo, hi = mean - half, mean + half
    else:
        lo = hi = mean
    return {
        "paired_n": len(deltas),
        "paired_delta_pct_mean": mean,
        "paired_delta_pct_stdev": sd,
        "ci90_low_pct": lo,
        "ci90_high_pct": hi,
        "mean_within_bound": abs(mean) <= bound,
        "ci90_within_bound": lo >= -bound and hi <= bound,
    }


def validate_one_core_config(
    cfg: dict[str, str], *, role: str, mode: str, dpdk_lcore: int, quic_cpus: str
) -> list[str]:
    errors: list[str] = []
    expected = {
        "GreenQuicMode": mode,
        "GreenQuicEnableMultiCore": "0",
        "GreenQuicDpdkLcores": str(dpdk_lcore),
        "GreenQuicTxOwnerLcore": str(dpdk_lcore),
        "GreenQuicTxOwnerAlsoRx": "1",
        "GreenQuicQuicWorkerCpus": quic_cpus,
        "GreenQuicQuicProfile": "max_throughput",
    }
    for key, value in expected.items():
        got = cfg.get(key)
        if got != value:
            errors.append(f"{role} {mode}: {key}={got!r}, expected {value!r}")
    args = cfg.get("DpdkInitArgs", "")
    if not re.search(rf"(?:^|\s)-l\s+{dpdk_lcore}(?:\s|$)", args):
        errors.append(
            f"{role} {mode}: DpdkInitArgs does not prove exactly lcore {dpdk_lcore}: {args!r}"
        )
    pmap = cfg.get("GreenQuicPartitionDpdkMap", "")
    if not pmap:
        errors.append(f"{role} {mode}: GreenQuicPartitionDpdkMap missing")
    else:
        bad = [tok for tok in pmap.split(",") if tok and not tok.endswith(f":{dpdk_lcore}")]
        if bad:
            errors.append(f"{role} {mode}: partition map targets non-reference lcore(s): {bad}")
    return errors


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", type=Path, required=True)
    ap.add_argument("--downloads", type=int, required=True)
    ap.add_argument("--equivalence-pct", type=float, default=2.0)
    ap.add_argument("--mechanism-pct", type=float, default=2.0)
    ap.add_argument("--publication-min-runs", type=int, default=6)
    ap.add_argument("--dpdk-lcore", type=int, default=19)
    ap.add_argument("--quic-cpus", default="21,22,23,24")
    args = ap.parse_args()

    root = args.root.resolve()
    labels = [
        "full_recorders_on",
        "full_recorders_off",
        "nopwr_recorders_on",
        "nopwr_recorders_off",
        "freq_only_recorders_on",
        "sleep_only_recorders_on",
    ]
    matrices = {label: root / label for label in labels if (root / label).is_dir()}
    required = {
        "full_recorders_on", "full_recorders_off",
        "nopwr_recorders_on", "nopwr_recorders_off",
    }
    missing = sorted(required - matrices.keys())
    if missing:
        raise SystemExit(f"ERROR: required claim matrices missing: {missing}")

    manifest = root / "BINARY_MANIFEST.tsv"
    if not manifest.is_file():
        raise SystemExit(f"ERROR: binary manifest missing: {manifest}")
    with manifest.open(newline="", encoding="utf-8") as f:
        mrows = list(csv.DictReader(f, delimiter="\t"))
    by_host_artifact: dict[tuple[str, str], set[str]] = {}
    for row in mrows:
        by_host_artifact.setdefault((row["host"], row["artifact"]), set()).add(row["sha256"])
    binary_stable = bool(by_host_artifact) and all(len(v) == 1 for v in by_host_artifact.values())

    table: list[dict[str, object]] = []
    means: dict[tuple[str, str, str], float] = {}
    run_values: dict[tuple[str, str, str], list[float]] = {}
    config_errors: list[str] = []
    topology_errors: list[str] = []

    for label, matrix in matrices.items():
        gps = per_run_goodputs(matrix, args.downloads)
        for mode, run_rows in gps.items():
            if not run_rows:
                raise SystemExit(f"ERROR: no {mode} repetitions found in {matrix}")
            row: dict[str, object] = {"case": label, "mode": mode, "n": len(run_rows)}
            for metric in ("aggregate_gbps", "d1_gbps", "steady_d2plus_gbps"):
                vals = [float(x[metric]) for x in run_rows]
                mean, sd = mean_sd(vals)
                means[(label, mode, metric)] = mean
                run_values[(label, mode, metric)] = vals
                row[f"{metric}_mean"] = mean
                row[f"{metric}_stdev"] = sd
            table.append(row)

        for role in ("server", "client"):
            for mode in ("off", "basic", "plus"):
                dcfg = unique_configs(matrix, role, mode, "dpdk_config")
                if len(dcfg) != 1:
                    topology_errors.append(
                        f"{label} {role} {mode}: expected one unique dpdk config, found {len(dcfg)}"
                    )
                else:
                    topology_errors.extend(
                        validate_one_core_config(
                            dcfg[0], role=role, mode=mode,
                            dpdk_lcore=args.dpdk_lcore, quic_cpus=args.quic_cpus,
                        )
                    )

    pairs = [
        ("full", "full_recorders_on", "full_recorders_off"),
        ("nopwr", "nopwr_recorders_on", "nopwr_recorders_off"),
    ]
    equivalence: list[dict[str, object]] = []
    for family, on, off in pairs:
        for role in ("server", "client"):
            for mode in ("off", "basic", "plus"):
                for suffix in ("dpdk_config", "powermng_config"):
                    a = unique_configs(matrices[on], role, mode, suffix)
                    b = unique_configs(matrices[off], role, mode, suffix)
                    if len(a) != 1 or len(b) != 1 or a[0] != b[0]:
                        config_errors.append(
                            f"{family} {role} {mode} {suffix}: "
                            f"recorders_on unique={len(a)} recorders_off unique={len(b)} equal={a == b}"
                        )
        for mode in ("off", "basic", "plus"):
            for metric in ("aggregate_gbps", "steady_d2plus_gbps"):
                a = means[(on, mode, metric)]
                b = means[(off, mode, metric)]
                eq = paired_equivalence(
                    run_values[(off, mode, metric)],
                    run_values[(on, mode, metric)],
                    args.equivalence_pct,
                )
                equivalence.append({
                    "family": family,
                    "mode": mode,
                    "metric": metric,
                    "recorders_on_gbps": a,
                    "recorders_off_gbps": b,
                    "off_vs_on_pct": pct(b, a),
                    **eq,
                    "within_bound": bool(eq["mean_within_bound"]),
                })

    superiority: list[dict[str, object]] = []
    for label in matrices:
        row: dict[str, object] = {"case": label}
        for metric in ("aggregate_gbps", "steady_d2plus_gbps"):
            off = means[(label, "off", metric)]
            plus = means[(label, "plus", metric)]
            prefix = "aggregate" if metric == "aggregate_gbps" else "steady"
            row[f"off_{prefix}_gbps"] = off
            row[f"plus_{prefix}_gbps"] = plus
            row[f"plus_vs_off_{prefix}_pct"] = pct(plus, off)
        superiority.append(row)

    recording_pass = (
        binary_stable
        and not config_errors
        and not topology_errors
        and all(bool(x["mean_within_bound"]) for x in equivalence)
    )
    publication_recording_pass = (
        recording_pass
        and all(int(x["paired_n"]) >= args.publication_min_runs for x in equivalence)
        and all(bool(x["ci90_within_bound"]) for x in equivalence)
    )

    full_gain = pct(
        means[("full_recorders_on", "plus", "steady_d2plus_gbps")],
        means[("full_recorders_on", "off", "steady_d2plus_gbps")],
    )
    nopwr_gain = pct(
        means[("nopwr_recorders_on", "plus", "steady_d2plus_gbps")],
        means[("nopwr_recorders_on", "off", "steady_d2plus_gbps")],
    )
    freq_gain = (
        pct(means[("freq_only_recorders_on", "plus", "steady_d2plus_gbps")],
            means[("freq_only_recorders_on", "off", "steady_d2plus_gbps")])
        if ("freq_only_recorders_on", "plus", "steady_d2plus_gbps") in means else None
    )
    sleep_gain = (
        pct(means[("sleep_only_recorders_on", "plus", "steady_d2plus_gbps")],
            means[("sleep_only_recorders_on", "off", "steady_d2plus_gbps")])
        if ("sleep_only_recorders_on", "plus", "steady_d2plus_gbps") in means else None
    )
    mechanism_evidence: list[str] = []
    threshold = args.mechanism_pct
    freq_increment = None if freq_gain is None else freq_gain - nopwr_gain
    sleep_increment = None if sleep_gain is None else sleep_gain - nopwr_gain
    full_increment = full_gain - nopwr_gain
    if full_gain > threshold:
        if nopwr_gain > threshold:
            mechanism_evidence.append(
                f"PLUS retains a {nopwr_gain:+.3f}% steady advantage with GreenQUIC frequency and idle actions disabled; "
                "this establishes a mode-specific non-power/timing component in this screen."
            )
        else:
            mechanism_evidence.append(
                f"The full PLUS steady advantage is {full_gain:+.3f}%, while the no-power-action PLUS advantage is only "
                f"{nopwr_gain:+.3f}%; the enabled power actions are necessary to reproduce the >{threshold:.2f}% advantage in this screen."
            )
        if freq_increment is not None and freq_increment > threshold:
            mechanism_evidence.append(
                f"Enabling frequency control adds {freq_increment:+.3f} percentage points beyond the no-power PLUS-vs-OFF baseline; "
                "this supports a frequency/package-power contribution."
            )
        if sleep_increment is not None and sleep_increment > threshold:
            mechanism_evidence.append(
                f"Enabling idle/sleep control adds {sleep_increment:+.3f} percentage points beyond the no-power PLUS-vs-OFF baseline; "
                "this supports an idle/pacing/scheduler contribution."
            )
        if (freq_increment is not None and freq_increment > threshold and
                sleep_increment is not None and sleep_increment > threshold):
            mechanism_evidence.append(
                "Both power-action classes add >threshold incremental gain; report a mixed contribution until the TX-pacing probe separates timing from scheduler/package effects."
            )
        if (nopwr_gain > threshold and
                (freq_increment is None or freq_increment <= threshold) and
                (sleep_increment is None or sleep_increment <= threshold)):
            mechanism_evidence.append(
                "Neither partial power-action ablation adds >threshold gain beyond the no-power mode effect; do not attribute the PLUS advantage to DVFS or sleeping from this screen."
            )
    else:
        mechanism_evidence.append(
            f"The new full-policy PLUS steady advantage is {full_gain:+.3f}%, below the predeclared {threshold:.2f}% mechanism screen threshold; "
            "do not promote a goodput-mechanism claim from this run."
        )

    out = {
        "schema": "greenquic-p5-onecore-claim-proof-v2",
        "reference_topology": {
            "dpdk_lcore": args.dpdk_lcore,
            "quic_cpus": args.quic_cpus,
            "enable_multicore": 0,
        },
        "historical_reference": {
            "off_steady_d2plus_gbps": 9.423551,
            "plus_steady_d2plus_gbps": 10.486178,
            "source": "2026-08-15 promoted P5 Super Performance drain2+mbuf configuration",
        },
        "binary_stable": binary_stable,
        "topology_errors": topology_errors,
        "config_equivalence_errors": config_errors,
        "equivalence_bound_pct": args.equivalence_pct,
        "recording_invariance_status": "PASS" if recording_pass else "FAIL",
        "recording_publication_status": "PASS" if publication_recording_pass else "NOT_ESTABLISHED",
        "publication_min_runs": args.publication_min_runs,
        "mechanism_screen_threshold_pct": args.mechanism_pct,
        "goodput": table,
        "recording_equivalence": equivalence,
        "plus_vs_off": superiority,
        "interpretation": {
            "full_plus_gain_aggregate_pct": pct(
                means[("full_recorders_on", "plus", "aggregate_gbps")],
                means[("full_recorders_on", "off", "aggregate_gbps")],
            ),
            "full_plus_gain_steady_pct": full_gain,
            "nopwr_plus_gain_steady_pct": nopwr_gain,
            "sleep_only_plus_gain_steady_pct": sleep_gain,
            "freq_only_plus_gain_steady_pct": freq_gain,
            "full_increment_over_nopwr_pct_points": full_increment,
            "sleep_increment_over_nopwr_pct_points": sleep_increment,
            "freq_increment_over_nopwr_pct_points": freq_increment,
            "mechanism_evidence": mechanism_evidence,
        },
    }
    (root / "CLAIM_PROOF_SUMMARY.json").write_text(
        json.dumps(out, indent=2) + "\n", encoding="utf-8"
    )

    with (root / "CLAIM_GOODPUT.tsv").open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(table[0]), delimiter="\t")
        w.writeheader(); w.writerows(table)

    lines = [
        "# P5 one-core claim-proof result",
        "",
        f"Recording invariance quick screen: **{out['recording_invariance_status']}** "
        f"(predeclared active-goodput equivalence bound ±{args.equivalence_pct:.2f}%).",
        f"Recording invariance publication criterion (>= {args.publication_min_runs} paired repetitions and 90% CI fully inside the bound): "
        f"**{out['recording_publication_status']}**.",
        f"Binary bytes stable across all cases: **{'yes' if binary_stable else 'no'}**.",
        f"One-core topology/config errors: **{len(topology_errors)}**.",
        f"Recorder-pair dpdk.ini/powermng.ini equality errors: **{len(config_errors)}**.",
        "",
        "Historical reference: OFF steady D2+ 9.423551 Gbit/s; PLUS steady D2+ 10.486178 Gbit/s.",
        "New runs below are authoritative for the new claim; the historical values are context only.",
        "",
        "## PLUS versus strict OFF",
        "",
        "| case | OFF aggregate | PLUS aggregate | delta | OFF steady D2+ | PLUS steady D2+ | delta |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for row in superiority:
        lines.append(
            f"| {row['case']} | {row['off_aggregate_gbps']:.6f} | "
            f"{row['plus_aggregate_gbps']:.6f} | {row['plus_vs_off_aggregate_pct']:+.3f}% | "
            f"{row['off_steady_gbps']:.6f} | {row['plus_steady_gbps']:.6f} | "
            f"{row['plus_vs_off_steady_pct']:+.3f}% |"
        )
    lines += [
        "",
        "## Recorder equivalence",
        "",
        "| family | mode | metric | recorders ON | recorders OFF | paired delta | 90% CI | mean in bound | CI in bound |",
        "|---|---|---|---:|---:|---:|---:|---|---|",
    ]
    for row in equivalence:
        lines.append(
            f"| {row['family']} | {row['mode']} | {row['metric']} | "
            f"{row['recorders_on_gbps']:.6f} | {row['recorders_off_gbps']:.6f} | "
            f"{row['paired_delta_pct_mean']:+.3f}% | [{row['ci90_low_pct']:+.3f}%, {row['ci90_high_pct']:+.3f}%] | "
            f"{'yes' if row['mean_within_bound'] else 'NO'} | {'yes' if row['ci90_within_bound'] else 'NO'} |"
        )
    lines += ["", "## Mechanism-screen interpretation", ""]
    lines += [f"- {x}" for x in mechanism_evidence]
    lines += [
        "",
        "Interpretation rule: this suite proves only the same-binary, one-DPDK-owner "
        "strict-OFF versus GreenQUIC+ comparison under the captured P5 Super configuration. "
        "It does not prove that every upstream MsQuic-DPDK build behaves identically.",
    ]
    if topology_errors:
        lines += ["", "## Topology/config errors", ""] + [f"- {x}" for x in topology_errors]
    if config_errors:
        lines += ["", "## Recorder-pair config equality errors", ""] + [f"- {x}" for x in config_errors]
    (root / "CLAIM_PROOF_SUMMARY.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

    print(f"P5 ONE-CORE CLAIM recording invariance: {out['recording_invariance_status']}")
    print(f"P5 ONE-CORE CLAIM publication recording criterion: {out['recording_publication_status']}")
    print(
        f"binary_stable={int(binary_stable)} topology_errors={len(topology_errors)} "
        f"config_errors={len(config_errors)}"
    )
    for row in superiority:
        print(
            f"{row['case']}: aggregate OFF={row['off_aggregate_gbps']:.6f} "
            f"PLUS={row['plus_aggregate_gbps']:.6f} delta={row['plus_vs_off_aggregate_pct']:+.3f}% | "
            f"steady OFF={row['off_steady_gbps']:.6f} PLUS={row['plus_steady_gbps']:.6f} "
            f"delta={row['plus_vs_off_steady_pct']:+.3f}%"
        )
    print(f"RESULT: {root / 'CLAIM_PROOF_SUMMARY.md'}")
    return 0 if recording_pass else 2


if __name__ == "__main__":
    raise SystemExit(main())
