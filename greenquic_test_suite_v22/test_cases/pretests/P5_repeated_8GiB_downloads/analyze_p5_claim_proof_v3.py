#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import math
import re
import statistics
from pathlib import Path

BITS = 8589934592 * 8
COMPLETE = re.compile(
    r"^\[GreenQUIC-P5\] request=(\d+)/(\d+) complete_us=(\d+) path=(\S+) "
    r"duration_us=(\d+) success=(0|1)$"
)
MODES = ("off", "basic", "plus")
CASES = (
    "full_recorders_on", "full_recorders_off",
    "nopwr_recorders_on", "nopwr_recorders_off",
    "freq_only_recorders_on", "sleep_only_recorders_on",
)


def pct(new: float, base: float) -> float:
    return 100.0 * (new / base - 1.0) if base else 0.0


def mean_sd(xs: list[float]) -> tuple[float, float]:
    return statistics.mean(xs), statistics.stdev(xs) if len(xs) > 1 else 0.0


def t90(n: int) -> float:
    if n <= 1:
        return math.inf
    table = {1:6.314,2:2.920,3:2.353,4:2.132,5:2.015,6:1.943,7:1.895,8:1.860,
             9:1.833,10:1.812,11:1.796,12:1.782,13:1.771,14:1.761,15:1.753,
             16:1.746,17:1.740,18:1.734,19:1.729,20:1.725,21:1.721,22:1.717,
             23:1.714,24:1.711,25:1.708,26:1.706,27:1.703,28:1.701,29:1.699,30:1.697}
    return table.get(n - 1, 1.645)


def parse_ini(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if line and not line.startswith(("#", ";")) and "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def configs(matrix: Path, role: str, mode: str, suffix: str) -> list[dict[str, str]]:
    """Return unique configs selected by immutable bundle path, not leaf filename."""
    base = matrix / "runs" / role
    if not base.is_dir():
        return []
    seen: dict[str, dict[str, str]] = {}
    needle = f"__{role}__{mode}"
    for path in base.rglob(f"*_{suffix}.txt"):
        lineage = "/".join(x.lower() for x in path.relative_to(base).parts[:-1])
        if needle not in lineage:
            continue
        data = parse_ini(path)
        seen.setdefault(json.dumps(data, sort_keys=True), data)
    return list(seen.values())


def goodput(matrix: Path, downloads: int) -> dict[str, list[dict[str, float]]]:
    out: dict[str, list[dict[str, float]]] = {m: [] for m in MODES}
    for mode in MODES:
        for log in sorted(matrix.glob(f"client_rep??_{mode}.log")):
            d: dict[int, int] = {}
            total = None
            for line in log.read_text(encoding="utf-8", errors="replace").splitlines():
                m = COMPLETE.match(line.strip())
                if not m:
                    continue
                if int(m.group(6)) != 1:
                    raise RuntimeError(f"failed request: {log}: {line}")
                d[int(m.group(1))] = int(m.group(5))
                total = int(m.group(2))
            if total != downloads or sorted(d) != list(range(1, downloads + 1)):
                raise RuntimeError(f"incomplete timing evidence: {log}: total={total}, keys={sorted(d)}")
            ds = [d[i] for i in range(1, downloads + 1)]
            aggregate = BITS * downloads / (sum(ds) / 1e6) / 1e9
            d1 = BITS / (ds[0] / 1e6) / 1e9
            steady = BITS * (downloads - 1) / (sum(ds[1:]) / 1e6) / 1e9
            out[mode].append({"aggregate_gbps": aggregate, "d1_gbps": d1, "steady_d2plus_gbps": steady})
    return out


def topology_errors(cfg: dict[str, str], role: str, mode: str, lcore: int, qcpus: str) -> list[str]:
    expected = {
        "GreenQuicMode": mode,
        "GreenQuicEnableMultiCore": "0",
        "GreenQuicDpdkLcores": str(lcore),
        "GreenQuicTxOwnerLcore": str(lcore),
        "GreenQuicTxOwnerAlsoRx": "1",
        "GreenQuicQuicWorkerCpus": qcpus,
        "GreenQuicQuicProfile": "max_throughput",
    }
    err = [f"{role} {mode}: {k}={cfg.get(k)!r}, expected {v!r}" for k, v in expected.items() if cfg.get(k) != v]
    init = cfg.get("DpdkInitArgs", "")
    if not re.search(rf"(?:^|\s)-l\s+{lcore}(?:\s|$)", init):
        err.append(f"{role} {mode}: DpdkInitArgs does not prove -l {lcore}: {init!r}")
    pmap = cfg.get("GreenQuicPartitionDpdkMap", "")
    if not pmap:
        err.append(f"{role} {mode}: partition map missing")
    elif any(tok and not tok.endswith(f":{lcore}") for tok in pmap.split(",")):
        err.append(f"{role} {mode}: partition map targets another DPDK lcore: {pmap}")
    return err


def paired(off: list[float], on: list[float], bound: float) -> dict[str, object]:
    if len(off) != len(on) or not off:
        raise RuntimeError("recorder equivalence needs equal non-empty paired repetition counts")
    ds = [pct(a, b) for a, b in zip(off, on)]
    mean = statistics.mean(ds)
    sd = statistics.stdev(ds) if len(ds) > 1 else 0.0
    half = t90(len(ds)) * sd / math.sqrt(len(ds)) if len(ds) > 1 else 0.0
    lo, hi = mean - half, mean + half
    return {"paired_n":len(ds), "paired_delta_pct_mean":mean, "paired_delta_pct_stdev":sd,
            "ci90_low_pct":lo, "ci90_high_pct":hi, "mean_within_bound":abs(mean)<=bound,
            "ci90_within_bound":lo>=-bound and hi<=bound}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", type=Path, required=True)
    ap.add_argument("--downloads", type=int, required=True)
    ap.add_argument("--equivalence-pct", type=float, default=2.0)
    ap.add_argument("--mechanism-pct", type=float, default=2.0)
    ap.add_argument("--publication-min-runs", type=int, default=6)
    ap.add_argument("--dpdk-lcore", type=int, default=19)
    ap.add_argument("--quic-cpus", default="21,22,23,24")
    a = ap.parse_args()
    root = a.root.resolve()
    matrices = {x: root / x for x in CASES if (root / x).is_dir()}
    required = {"full_recorders_on","full_recorders_off","nopwr_recorders_on","nopwr_recorders_off"}
    if missing := sorted(required - matrices.keys()):
        raise SystemExit(f"ERROR: required matrices missing: {missing}")

    mf = root / "BINARY_MANIFEST.tsv"
    if not mf.is_file():
        raise SystemExit(f"ERROR: binary manifest missing: {mf}")
    with mf.open(newline="", encoding="utf-8") as f:
        mrows = list(csv.DictReader(f, delimiter="\t"))
    hashes: dict[tuple[str,str], set[str]] = {}
    for r in mrows:
        hashes.setdefault((r["host"], r["artifact"]), set()).add(r["sha256"])
    binary_stable = bool(hashes) and all(len(v) == 1 for v in hashes.values())

    means: dict[tuple[str,str,str], float] = {}
    values: dict[tuple[str,str,str], list[float]] = {}
    table: list[dict[str, object]] = []
    terr: list[str] = []
    for label, matrix in matrices.items():
        gp = goodput(matrix, a.downloads)
        for mode in MODES:
            if not gp[mode]:
                raise SystemExit(f"ERROR: no {mode} repetitions in {matrix}")
            row: dict[str, object] = {"case":label,"mode":mode,"n":len(gp[mode])}
            for metric in ("aggregate_gbps","d1_gbps","steady_d2plus_gbps"):
                xs = [r[metric] for r in gp[mode]]
                m, sd = mean_sd(xs)
                means[label,mode,metric] = m; values[label,mode,metric] = xs
                row[metric+"_mean"] = m; row[metric+"_stdev"] = sd
            table.append(row)
        for role in ("server","client"):
            for mode in MODES:
                cs = configs(matrix, role, mode, "dpdk_config")
                if len(cs) != 1:
                    terr.append(f"{label} {role} {mode}: expected one unique dpdk config, found {len(cs)}")
                else:
                    terr += topology_errors(cs[0], role, mode, a.dpdk_lcore, a.quic_cpus)

    cerr: list[str] = []
    eqrows: list[dict[str, object]] = []
    for family, on, off in (("full","full_recorders_on","full_recorders_off"),
                            ("nopwr","nopwr_recorders_on","nopwr_recorders_off")):
        for role in ("server","client"):
            for mode in MODES:
                for suffix in ("dpdk_config","powermng_config"):
                    x, y = configs(matrices[on],role,mode,suffix), configs(matrices[off],role,mode,suffix)
                    if len(x) != 1 or len(y) != 1 or x[0] != y[0]:
                        cerr.append(f"{family} {role} {mode} {suffix}: on={len(x)} off={len(y)} equal={x==y}")
        for mode in MODES:
            for metric in ("aggregate_gbps","steady_d2plus_gbps"):
                e = paired(values[off,mode,metric], values[on,mode,metric], a.equivalence_pct)
                eqrows.append({"family":family,"mode":mode,"metric":metric,
                    "recorders_on_gbps":means[on,mode,metric],"recorders_off_gbps":means[off,mode,metric],**e})

    superiority: list[dict[str, object]] = []
    for label in matrices:
        offa, plusa = means[label,"off","aggregate_gbps"], means[label,"plus","aggregate_gbps"]
        offs, pluss = means[label,"off","steady_d2plus_gbps"], means[label,"plus","steady_d2plus_gbps"]
        superiority.append({"case":label,"off_aggregate_gbps":offa,"plus_aggregate_gbps":plusa,
            "plus_vs_off_aggregate_pct":pct(plusa,offa),"off_steady_gbps":offs,"plus_steady_gbps":pluss,
            "plus_vs_off_steady_pct":pct(pluss,offs)})

    quick = binary_stable and not terr and not cerr and all(bool(x["mean_within_bound"]) for x in eqrows)
    publication = quick and all(int(x["paired_n"]) >= a.publication_min_runs and bool(x["ci90_within_bound"]) for x in eqrows)
    gain = lambda case: pct(means[case,"plus","steady_d2plus_gbps"], means[case,"off","steady_d2plus_gbps"])
    full, nopwr = gain("full_recorders_on"), gain("nopwr_recorders_on")
    freq = gain("freq_only_recorders_on") if "freq_only_recorders_on" in matrices else None
    sleep = gain("sleep_only_recorders_on") if "sleep_only_recorders_on" in matrices else None
    fi = None if freq is None else freq - nopwr
    si = None if sleep is None else sleep - nopwr
    ev: list[str] = []
    t = a.mechanism_pct
    if full <= t:
        ev.append(f"Full PLUS steady advantage {full:+.3f}% is <= {t:.2f}%; no mechanism claim from this screen.")
    else:
        if nopwr > t: ev.append(f"PLUS retains {nopwr:+.3f}% with DVFS+idle actions disabled: non-power/timing mode effect supported.")
        else: ev.append(f"Full PLUS gain is {full:+.3f}% but nopwr gain is {nopwr:+.3f}%: enabled power actions are necessary for the >{t:.2f}% gain in this screen.")
        if fi is not None and fi > t: ev.append(f"Frequency-only adds {fi:+.3f} percentage points beyond nopwr: frequency/package contribution supported.")
        if si is not None and si > t: ev.append(f"Sleep-only adds {si:+.3f} percentage points beyond nopwr: idle/pacing/scheduler contribution supported.")
        if nopwr > t and (fi is None or fi <= t) and (si is None or si <= t): ev.append("Partial power ablations add no >threshold increment beyond nopwr; do not attribute the mode advantage to DVFS/sleep from this screen.")

    out = {"schema":"greenquic-p5-onecore-claim-proof-v3","binary_stable":binary_stable,
        "recording_invariance_status":"PASS" if quick else "FAIL",
        "recording_publication_status":"PASS" if publication else "NOT_ESTABLISHED",
        "equivalence_bound_pct":a.equivalence_pct,"publication_min_runs":a.publication_min_runs,
        "topology_errors":terr,"config_equivalence_errors":cerr,"goodput":table,
        "recording_equivalence":eqrows,"plus_vs_off":superiority,
        "historical_reference":{"off_steady_d2plus_gbps":9.423551,"plus_steady_d2plus_gbps":10.486178},
        "interpretation":{"full_plus_gain_steady_pct":full,"nopwr_plus_gain_steady_pct":nopwr,
            "freq_only_plus_gain_steady_pct":freq,"sleep_only_plus_gain_steady_pct":sleep,
            "freq_increment_over_nopwr_pct_points":fi,"sleep_increment_over_nopwr_pct_points":si,
            "mechanism_evidence":ev}}
    (root/"CLAIM_PROOF_SUMMARY.json").write_text(json.dumps(out,indent=2)+"\n",encoding="utf-8")
    with (root/"CLAIM_GOODPUT.tsv").open("w",newline="",encoding="utf-8") as f:
        w=csv.DictWriter(f,fieldnames=list(table[0]),delimiter="\t"); w.writeheader(); w.writerows(table)
    lines=["# P5 one-core claim-proof result","",
        f"Recording invariance quick screen: **{out['recording_invariance_status']}** (±{a.equivalence_pct:.2f}%).",
        f"Publication criterion (>= {a.publication_min_runs} paired repetitions; 90% CI fully inside bound): **{out['recording_publication_status']}**.",
        f"Binary bytes stable: **{'yes' if binary_stable else 'no'}**. Topology errors: **{len(terr)}**. Config-equality errors: **{len(cerr)}**.","",
        "Historical context only: OFF steady D2+ 9.423551 Gbit/s; PLUS steady D2+ 10.486178 Gbit/s.","",
        "## PLUS versus strict OFF","",
        "| case | OFF aggregate | PLUS aggregate | delta | OFF steady D2+ | PLUS steady D2+ | delta |","|---|---:|---:|---:|---:|---:|---:|"]
    for r in superiority:
        lines.append(f"| {r['case']} | {r['off_aggregate_gbps']:.6f} | {r['plus_aggregate_gbps']:.6f} | {r['plus_vs_off_aggregate_pct']:+.3f}% | {r['off_steady_gbps']:.6f} | {r['plus_steady_gbps']:.6f} | {r['plus_vs_off_steady_pct']:+.3f}% |")
    lines += ["","## Recorder equivalence","",
        "| family | mode | metric | ON | OFF | paired delta | 90% CI | mean in bound | CI in bound |","|---|---|---|---:|---:|---:|---:|---|---|"]
    for r in eqrows:
        lines.append(f"| {r['family']} | {r['mode']} | {r['metric']} | {r['recorders_on_gbps']:.6f} | {r['recorders_off_gbps']:.6f} | {r['paired_delta_pct_mean']:+.3f}% | [{r['ci90_low_pct']:+.3f}%, {r['ci90_high_pct']:+.3f}%] | {'yes' if r['mean_within_bound'] else 'NO'} | {'yes' if r['ci90_within_bound'] else 'NO'} |")
    lines += ["","## Mechanism screen",""] + [f"- {x}" for x in ev]
    if terr: lines += ["","## Topology errors",""]+[f"- {x}" for x in terr]
    if cerr: lines += ["","## Config equality errors",""]+[f"- {x}" for x in cerr]
    (root/"CLAIM_PROOF_SUMMARY.md").write_text("\n".join(lines)+"\n",encoding="utf-8")
    print(f"P5 ONE-CORE CLAIM V3 recording invariance: {out['recording_invariance_status']}")
    print(f"P5 ONE-CORE CLAIM V3 publication criterion: {out['recording_publication_status']}")
    print(f"binary_stable={int(binary_stable)} topology_errors={len(terr)} config_errors={len(cerr)}")
    print(f"RESULT: {root/'CLAIM_PROOF_SUMMARY.md'}")
    return 0 if quick else 2


if __name__ == "__main__":
    raise SystemExit(main())
