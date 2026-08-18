#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import math
import shutil
import statistics
import tempfile
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

VARS = ("without_variance", "with_variance")
VALS = ("without_values", "with_values")
CSTATE_ORDER = ("POLL", "C1", "C1E", "C6")


def num(v):
    try:
        x = float(v)
        return x if math.isfinite(x) else None
    except Exception:
        return None


def stat(values):
    vals = [
        float(x)
        for x in values
        if x is not None and math.isfinite(float(x))
    ]
    if not vals:
        return 0, None, None, None
    if len(vals) == 1:
        return 1, vals[0], None, None
    return len(vals), statistics.mean(vals), statistics.stdev(vals), statistics.variance(vals)


def js(path):
    return json.loads(path.read_text())


def endpoint(root, endpoint_name):
    return [
        (d, js(d / "summary.json"))
        for d in sorted((root / "runs" / endpoint_name).glob("rep*"))
        if (d / "summary.json").is_file()
    ]


def rapl(summary, scope, key):
    return num(
        ((((summary.get("scopes") or {}).get(scope) or {}).get("rapl") or {}).get(key))
    )


def freq(summary, scope, cpu):
    return num(
        (((summary.get("scopes") or {}).get(scope) or {})
         .get("frequency") or {})
        .get(str(cpu), {})
        .get("mean_ghz")
    )


def workload_duration(summary):
    us = num(summary.get("workload_elapsed_us"))
    return us / 1e6 if us is not None and us >= 0 else None


def aligned_duration(summary):
    windows = summary.get("windows") or {}
    pre = windows.get("pre_cool") or []
    post = windows.get("post_cool") or []
    if not pre or not post:
        return None
    try:
        a0 = int(pre[0][0])
        a1 = int(pre[0][1])
        b0 = int(post[-1][0])
        b1 = int(post[-1][1])
    except (TypeError, ValueError, IndexError):
        return None
    if a1 <= a0 or b1 <= b0 or b1 < a0:
        return None
    return (b1 - a0) / 1e9


def cstate_available(summary):
    """Return True only when this repetition contains usable C-state events.

    Older P7 summaries do not carry an explicit recorder-status field. For those
    files, any non-empty scope C-state map proves the recorder produced usable
    events. A completely empty set of scope maps is treated as unavailable, not
    as 0% residency.
    """
    explicit = summary.get("cstate_available")
    if explicit is not None:
        return bool(explicit)
    scopes = summary.get("scopes") or {}
    return any(
        isinstance((scope_data or {}).get("cstate"), dict)
        and bool((scope_data or {}).get("cstate"))
        for scope_data in scopes.values()
        if isinstance(scope_data, dict)
    )


def cstate_states(summaries):
    names = set()
    for summary in summaries:
        if not cstate_available(summary):
            continue
        for scope_data in (summary.get("scopes") or {}).values():
            if not isinstance(scope_data, dict):
                continue
            for entry in ((scope_data.get("cstate") or {}).values()):
                if not isinstance(entry, dict):
                    continue
                state = str(entry.get("state") or "").strip().upper()
                if state:
                    names.add(state)
    ordered = [state for state in CSTATE_ORDER if state in names]
    ordered.extend(sorted(state for state in names if state not in CSTATE_ORDER))
    return ordered


def cstate_pct(summary, scope, state):
    """Phase residency percentage for one state.

    If the repetition has a valid C-state recorder but this particular state is
    absent from the phase map, that is a measured 0% for this phase. If the
    recorder has no usable C-state data at all, return None so the repetition is
    excluded rather than converted to zero.
    """
    if not cstate_available(summary):
        return None
    scope_data = ((summary.get("scopes") or {}).get(scope) or {})
    duration = num(scope_data.get("duration_s"))
    if duration is None or duration <= 0:
        return None
    seconds = 0.0
    for entry in ((scope_data.get("cstate") or {}).values()):
        if not isinstance(entry, dict):
            continue
        name = str(entry.get("state") or "").strip().upper()
        sec = num(entry.get("seconds"))
        if name == state and sec is not None and sec >= 0:
            seconds += sec
    return 100.0 * seconds / duration


def cstate_series(server, client, scope, states):
    series = {}
    if any(cstate_available(s) for s in server):
        series["Server"] = [
            [cstate_pct(s, scope, state) for s in server]
            for state in states
        ]
    if any(cstate_available(c) for c in client):
        series["Client"] = [
            [cstate_pct(c, scope, state) for c in client]
            for state in states
        ]
    return series


def ensure(path):
    path.mkdir(parents=True, exist_ok=True)
    return path


def bar(report, n, name, title, ylabel, cats, series, stats, manifest):
    cache = {label: [stat(v) for v in groups] for label, groups in series.items()}
    if not any(x[1] is not None for group in cache.values() for x in group):
        return

    for label, ss in cache.items():
        for cat, (nn, mu, sd, var) in zip(cats, ss):
            stats.append([n, name, label, cat, nn, mu, sd, var])

    x = np.arange(len(cats))
    width = min(0.78 / max(1, len(series)), 0.28)
    for variance_variant in VARS:
        for values_variant in VALS:
            fig, ax = plt.subplots(figsize=(12, 7))
            for j, (label, ss) in enumerate(cache.items()):
                means = [np.nan if s[1] is None else s[1] for s in ss]
                errs = [
                    0
                    if variance_variant == "without_variance" or s[2] is None
                    else s[2]
                    for s in ss
                ]
                pos = x + (j - (len(series) - 1) / 2) * width
                bars = ax.bar(
                    pos,
                    means,
                    width,
                    label=label,
                    yerr=errs if variance_variant == "with_variance" else None,
                    capsize=5,
                )
                if values_variant == "with_values":
                    for patch, mu, err, s in zip(bars, means, errs, ss):
                        if math.isfinite(mu):
                            annotation = f"{mu:.3f}"
                            if variance_variant == "with_variance" and s[2] is not None:
                                annotation += f"\nSD={s[2]:.3f}"
                            ax.annotate(
                                annotation,
                                (patch.get_x() + patch.get_width() / 2, mu + err),
                                xytext=(0, 5),
                                textcoords="offset points",
                                ha="center",
                                fontsize=8,
                            )
            ax.set_title(title, fontweight="normal")
            ax.set_ylabel(ylabel)
            ax.set_xticks(x, cats)
            ax.grid(axis="y", alpha=0.3)
            ax.set_axisbelow(True)
            ax.set_ylim(bottom=0)
            if len(series) > 1:
                ax.legend(loc="center left", bbox_to_anchor=(1.01, 0.5))
            fig.tight_layout()
            for ext in ("svg", "pdf"):
                path = ensure(report / "charts" / variance_variant / ext / values_variant) / f"{n:02d}_{name}.{ext}"
                fig.savefig(path, bbox_inches="tight", dpi=300)
                manifest.append([
                    n,
                    name,
                    variance_variant,
                    values_variant,
                    ext,
                    str(path.relative_to(report)),
                ])
                if variance_variant == "without_variance":
                    shutil.copy2(path, ensure(report / "charts" / ext / values_variant) / path.name)
            plt.close(fig)


def read_rapl(path):
    if not path.is_file():
        return []
    lines = [
        line
        for line in path.read_text(errors="replace").splitlines()
        if line and not line.startswith("#")
    ]
    return list(csv.DictReader(lines)) if lines else []


def read_freq(path, cpu):
    out = []
    if not path.is_file():
        return out
    for line in path.read_text(errors="replace").splitlines():
        try:
            row = json.loads(line)
        except Exception:
            continue
        try:
            if row.get("type") == "line" and int(row["cpu"]) == cpu:
                out.append((int(row["monotonic_ns"]), float(row["freq_khz"]) / 1e6))
        except Exception:
            pass
    return out


def phases(summary):
    windows = summary.get("windows") or {}
    out = []
    if windows.get("pre_cool"):
        out.append(("Pre", *windows["pre_cool"][0]))
    active = windows.get("active") or []
    gaps = windows.get("gap") or []
    for i, window in enumerate(active):
        out.append((f"D{i + 1}", *window))
        if i < len(gaps):
            out.append((f"Gap{i + 1}", *gaps[i]))
    if windows.get("post_cool"):
        out.append(("Post", *windows["post_cool"][0]))
    return out


def interp(samples, a, b, n=60):
    q = [(t, v) for t, v in samples if a <= t <= b]
    if not q:
        return np.full(n, np.nan)
    x = np.array([(t - a) / (b - a) for t, _v in q])
    y = np.array([v for _t, v in q])
    z = np.linspace(0, 1, n)
    return np.interp(z, x, y, left=y[0], right=y[-1]) if len(q) > 1 else np.full(n, y[0])


def timeseries(report, root, endpoint_name, kind, cpu, n, name, title, ylabel, manifest):
    runs = endpoint(root, endpoint_name)
    seq = [phases(s) for _d, s in runs]
    if not seq:
        return
    labels = [x[0] for x in seq[0]]
    if any([x[0] for x in q] != labels for q in seq):
        return

    mats = []
    durs = []
    for (run_dir, _summary), q in zip(runs, seq):
        if kind == "rapl":
            samples = [
                (
                    int(float(row["sample_monotonic_ns"])),
                    float(row.get("total_power_smoothed_w") or row.get("total_power_w")),
                )
                for row in read_rapl(run_dir / "rapl.csv")
            ]
        else:
            samples = read_freq(run_dir / "frequency.jsonl", cpu)
        mats.append([interp(samples, a, b) for _label, a, b in q])
        durs.append([(b - a) / 1e9 for _label, a, b in q])

    dur = np.nanmean(np.array(durs), axis=0)
    xs = []
    parts = []
    bounds = [0]
    cur = 0
    for j, phase_duration in enumerate(dur):
        xs.append(np.linspace(cur, cur + phase_duration, 60))
        cur += phase_duration
        bounds.append(cur)
        parts.append(np.array([m[j] for m in mats]))
    X = np.concatenate(xs)
    A = np.concatenate(parts, axis=1)
    M = np.nanmean(A, axis=0)
    SD = np.nanstd(A, axis=0, ddof=1) if len(runs) > 1 else np.full_like(M, np.nan)

    for variance_variant in VARS:
        for values_variant in VALS:
            fig, ax = plt.subplots(figsize=(14, 7))
            ax.plot(X, M, label=f"{endpoint_name.title()} mean (n={len(runs)})")
            if variance_variant == "with_variance" and np.isfinite(SD).any():
                ax.fill_between(X, M - SD, M + SD, alpha=0.18, label="±1 SD")
            for bound in bounds[1:-1]:
                ax.axvline(bound, lw=0.8, alpha=0.3)
            for j, label in enumerate(labels):
                ax.text(
                    (bounds[j] + bounds[j + 1]) / 2,
                    1.01,
                    label,
                    transform=ax.get_xaxis_transform(),
                    ha="center",
                    fontsize=8,
                )
            ax.set_title(title, fontweight="normal")
            ax.set_xlabel("Phase-aligned elapsed time (s)")
            ax.set_ylabel(ylabel)
            ax.grid(alpha=0.25)
            ax.legend()
            fig.tight_layout()
            for ext in ("svg", "pdf"):
                path = ensure(report / "charts" / variance_variant / ext / values_variant) / f"{n:02d}_{name}.{ext}"
                fig.savefig(path, bbox_inches="tight", dpi=300)
                manifest.append([
                    n,
                    name,
                    variance_variant,
                    values_variant,
                    ext,
                    str(path.relative_to(report)),
                ])
                if variance_variant == "without_variance":
                    shutil.copy2(path, ensure(report / "charts" / ext / values_variant) / path.name)
            plt.close(fig)


def build(root, report):
    rows = list(csv.DictReader((root / "p7_all_runs.csv").open()))
    server = [x[1] for x in endpoint(root, "server")]
    client = [x[1] for x in endpoint(root, "client")]
    if not rows or len(server) != len(client):
        raise SystemExit("P7 summaries incomplete")

    text = (root / "matrix_config.env").read_text()
    cpu = int(text.split("dataplane_cpu=", 1)[1].splitlines()[0]) if "dataplane_cpu=" in text else 19
    stats = []
    manifest = []
    warnings = []
    col = lambda key: [num(row.get(key)) for row in rows]

    bar(report, 1, "active_goodput", "Linux UDP active-download goodput", "Gbit/s", ["MsQuic-Linux"], {"Goodput": [col("goodput_gbps")]}, stats, manifest)
    bar(report, 2, "gap_inclusive_goodput", "Linux UDP gap-inclusive goodput", "Gbit/s", ["MsQuic-Linux"], {"Goodput": [col("gap_inclusive_goodput_gbps")]}, stats, manifest)

    for n, scope in ((3, "active"), (4, "gap"), (5, "combined")):
        bar(
            report,
            n,
            f"{scope}_energy",
            f"RAPL energy — {scope}",
            "J",
            ["Server", "Client"],
            {"CPU package + DRAM": [[rapl(s, scope, "total_j") for s in server], [rapl(c, scope, "total_j") for c in client]]},
            stats,
            manifest,
        )
    for n, scope in ((6, "active"), (7, "gap"), (8, "combined")):
        bar(
            report,
            n,
            f"{scope}_power",
            f"Average RAPL power — {scope}",
            "W",
            ["Server", "Client"],
            {"CPU package + DRAM": [[rapl(s, scope, "total_w") for s in server], [rapl(c, scope, "total_w") for c in client]]},
            stats,
            manifest,
        )

    bar(report, 9, "active_j_per_gbit", "Combined active energy cost", "J/Gbit", ["Server + Client"], {"Energy cost": [col("combined_active_j_per_useful_gbit")]}, stats, manifest)
    bar(report, 10, "combined_j_per_gbit", "Combined D1→Dn energy cost", "J/Gbit", ["Server + Client"], {"Energy cost": [col("combined_combined_j_per_useful_gbit")]}, stats, manifest)

    for n, scope in ((11, "active"), (12, "gap"), (13, "combined")):
        bar(
            report,
            n,
            f"{scope}_frequency",
            f"CPU{cpu} mean frequency — {scope}",
            "GHz",
            ["Server", "Client"],
            {f"CPU{cpu}": [[freq(s, scope, cpu) for s in server], [freq(c, scope, cpu) for c in client]]},
            stats,
            manifest,
        )

    timeseries(report, root, "server", "rapl", cpu, 14, "server_rapl_over_time", "Server RAPL power over pre-cool, downloads and gaps", "W", manifest)
    timeseries(report, root, "client", "rapl", cpu, 15, "client_rapl_over_time", "Client RAPL power over pre-cool, downloads and gaps", "W", manifest)
    timeseries(report, root, "server", "freq", cpu, 16, "server_frequency_over_time", f"Server CPU{cpu} frequency over pre-cool, downloads and gaps", "GHz", manifest)
    timeseries(report, root, "client", "freq", cpu, 17, "client_frequency_over_time", f"Client CPU{cpu} frequency over pre-cool, downloads and gaps", "GHz", manifest)

    bar(
        report,
        18,
        "duration_breakdown",
        "Transfer, gap-window, and aligned duration",
        "Seconds",
        ["MsQuic-Linux"],
        {
            "Workload": [[workload_duration(c) for c in client]],
            "Client aligned": [[aligned_duration(c) for c in client]],
            "Server aligned": [[aligned_duration(s) for s in server]],
        },
        stats,
        manifest,
    )

    # P7 C-state data is already phase-aligned in each run's summary.json. Promote
    # it to the same report/statistics hierarchy as power and frequency.
    states = cstate_states(server + client)
    if states:
        active_series = cstate_series(server, client, "active", states)
        gap_series = cstate_series(server, client, "gap", states)
        bar(
            report,
            19,
            "active_cstate_residency",
            f"CPU{cpu} C-state residency — active transfers",
            "Residency (% of active duration)",
            states,
            active_series,
            stats,
            manifest,
        )
        bar(
            report,
            20,
            "gap_cstate_residency",
            f"CPU{cpu} C-state residency — inter-download gaps",
            "Residency (% of gap duration)",
            states,
            gap_series,
            stats,
            manifest,
        )
    else:
        warnings.append("No usable C-state recorder data was found on either endpoint; charts 19/20 were omitted.")

    if not any(cstate_available(c) for c in client):
        warnings.append("Client C-state recorder data unavailable; C-state charts omit the client series rather than treating it as zero.")
    if not any(cstate_available(s) for s in server):
        warnings.append("Server C-state recorder data unavailable; C-state charts omit the server series rather than treating it as zero.")

    with (report / "chart_statistics.csv").open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["chart", "name", "series", "category", "n", "mean", "sd", "variance"])
        writer.writerows(stats)
    with (report / "chart_manifest.csv").open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["chart", "name", "variance", "values", "format", "path"])
        writer.writerows(manifest)

    (report / "validation_report.json").write_text(
        json.dumps(
            {
                "schema": "greenquic-p7-report-v1",
                "repetitions": len(rows),
                "chart_numbers": sorted({x[0] for x in manifest}),
                "variant_files": len(manifest),
                "warnings": warnings,
            },
            indent=2,
        )
        + "\n"
    )
    (report / "README.txt").write_text(
        "P7 Linux UDP report. Same P5 chart-variant convention; Linux-equivalent metrics only. "
        "Chart 18 mirrors the P5 workload/client-aligned/server-aligned duration breakdown for the single MsQuic-Linux mode. "
        "Charts 19 and 20 report phase-normalized CPU C-state residency for active transfers and inter-download gaps. "
        "A state absent from a valid recorder repetition is counted as 0% for that repetition; an endpoint with no usable C-state recorder data is omitted rather than converted to zero. "
        "DPDK-only pressure/action/hint charts are intentionally absent.\n"
    )
    print(f"P7 report: {report}")
    print(f"P7 charts: {len(set(x[0] for x in manifest))} chart numbers, {len(manifest)} variant files")


def selftest():
    valid = {
        "scopes": {
            "active": {
                "duration_s": 2.0,
                "cstate": {"2": {"state": "C1E", "seconds": 1.5, "intervals": 3}},
            },
            "gap": {
                "duration_s": 1.0,
                "cstate": {"3": {"state": "C6", "seconds": 0.9, "intervals": 2}},
            },
        }
    }
    missing = {
        "scopes": {
            "active": {"duration_s": 2.0, "cstate": {}},
            "gap": {"duration_s": 1.0, "cstate": {}},
        }
    }
    assert abs(cstate_pct(valid, "active", "C1E") - 75.0) < 1e-12
    assert cstate_pct(valid, "active", "C6") == 0.0
    assert cstate_pct(missing, "active", "C6") is None

    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        (root / "runs/server/rep01").mkdir(parents=True)
        (root / "runs/client/rep01").mkdir(parents=True)
        base = 1_000_000_000
        windows = {
            "pre_cool": [[base, base + 1_000_000_000]],
            "active": [[base + 1_000_000_000, base + 2_000_000_000]],
            "gap": [[base + 2_000_000_000, base + 3_000_000_000]],
            "combined": [[base + 1_000_000_000, base + 3_000_000_000]],
            "post_cool": [[base + 3_000_000_000, base + 4_000_000_000]],
        }
        for endpoint_name in ("server", "client"):
            scopes = {
                name: {
                    "duration_s": sum((b - a) for a, b in phase_windows) / 1e9,
                    "rapl": {"total_j": 80, "total_w": 80},
                    "frequency": {"19": {"mean_ghz": 2.2}},
                    "cstate": {},
                }
                for name, phase_windows in windows.items()
            }
            if endpoint_name == "server":
                scopes["active"]["cstate"] = {
                    "2": {"state": "C1E", "seconds": 0.9, "intervals": 9},
                    "3": {"state": "C6", "seconds": 0.1, "intervals": 1},
                }
                scopes["gap"]["cstate"] = {
                    "3": {"state": "C6", "seconds": 0.95, "intervals": 4},
                }
            summary = {"windows": windows, "scopes": scopes}
            if endpoint_name == "client":
                summary["workload_elapsed_us"] = 2_000_000
            run_dir = root / f"runs/{endpoint_name}/rep01"
            (run_dir / "summary.json").write_text(json.dumps(summary))
            (run_dir / "rapl.csv").write_text(
                "sample_monotonic_ns,actual_interval_ms,total_power_w,total_power_smoothed_w\n"
                + "".join(f"{base + i * 10_000_000},10,80,80\n" for i in range(401))
            )
            (run_dir / "frequency.jsonl").write_text(
                "".join(
                    json.dumps(
                        {
                            "type": "line",
                            "monotonic_ns": base + i * 10_000_000,
                            "cpu": 19,
                            "freq_khz": 2_200_000,
                        }
                    )
                    + "\n"
                    for i in range(401)
                )
            )

        (root / "p7_all_runs.csv").write_text(
            "repetition,goodput_gbps,gap_inclusive_goodput_gbps,combined_active_j_per_useful_gbit,combined_combined_j_per_useful_gbit\n"
            "1,8,8,20,20\n"
        )
        (root / "matrix_config.env").write_text("dataplane_cpu=19\n")
        out = root / "the_sheet_rules_all"
        build(root, out)

        for chart in (18, 19, 20):
            name = {
                18: "duration_breakdown",
                19: "active_cstate_residency",
                20: "gap_cstate_residency",
            }[chart]
            svg = out / "charts" / "without_variance" / "svg" / "with_values" / f"{chart:02d}_{name}.svg"
            if not svg.is_file():
                raise AssertionError(f"chart {chart} was not generated")

        validation = json.loads((out / "validation_report.json").read_text())
        for chart in (18, 19, 20):
            if chart not in validation.get("chart_numbers", []):
                raise AssertionError(f"chart {chart} missing from manifest validation")

        rows = list(csv.DictReader((out / "chart_statistics.csv").open()))
        duration = {
            row["series"]: float(row["mean"])
            for row in rows
            if row["name"] == "duration_breakdown"
        }
        if duration != {"Workload": 2.0, "Client aligned": 4.0, "Server aligned": 4.0}:
            raise AssertionError(f"unexpected duration metrics: {duration}")

        cstate_rows = [row for row in rows if row["name"] in {"active_cstate_residency", "gap_cstate_residency"}]
        if not cstate_rows:
            raise AssertionError("C-state chart statistics were not generated")
        if any(row["series"] == "Client" for row in cstate_rows):
            raise AssertionError("missing client C-state recorder must not become a zero-valued Client series")
        active = {
            row["category"]: (int(row["n"]), float(row["mean"]))
            for row in cstate_rows
            if row["name"] == "active_cstate_residency" and row["series"] == "Server"
        }
        if active.get("C1E") != (1, 90.0) or active.get("C6") != (1, 10.0):
            raise AssertionError(f"unexpected active C-state statistics: {active}")

        print("P7 report self-test PASS")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--matrix-dir", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        selftest()
        return
    if not args.matrix_dir:
        parser.error("--matrix-dir required")
    output = args.output or args.matrix_dir / "the_sheet_rules_all"
    ensure(output)
    build(args.matrix_dir.resolve(), output.resolve())


if __name__ == "__main__":
    main()
