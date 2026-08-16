#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import importlib.util
import json
import math
from pathlib import Path

HERE = Path(__file__).resolve().parent
BASE = HERE / "build_d1_d2plus_report.py"
spec = importlib.util.spec_from_file_location("gq_d1d2_power_base", BASE)
if spec is None or spec.loader is None:
    raise SystemExit(f"ERROR: cannot import {BASE}")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

BIN_NS = 50_000_000
PLOT_STEP_S = 0.05


def read_rapl(path, shift=0):
    rows = mod.read_csv(path)
    out = []
    for row in rows:
        end = mod.finite(row.get("sample_monotonic_ns"))
        dt_ms = mod.finite(row.get("actual_interval_ms"))
        pk = mod.finite(row.get("package_delta_j"))
        dr = mod.finite(row.get("dram_delta_j")) or 0.0
        if None in (end, dt_ms, pk) or dt_ms <= 0:
            continue
        start = int(round(end - dt_ms * 1_000_000.0)) + int(shift)
        finish = int(end) + int(shift)
        if finish > start:
            out.append((start, finish, float(pk + dr)))
    return out


def sync_shift(root: Path, rep: int, mode: str):
    path = root / f"clock_sync_rep{rep:02d}_{mode}.json"
    try:
        data = json.loads(path.read_text())
        return int(data["client_minus_controller_monotonic_offset_ns"])
    except Exception:
        return None


def accepted_server(root: Path):
    path = root / "the_sheet_rules_all" / "d1_d2plus" / "alignment_quality.json"
    try:
        data = json.loads(path.read_text())
    except Exception:
        return {}
    out = {}
    for row in data.get("records", []):
        key = (int(row.get("repetition", 0)), str(row.get("mode", "")))
        out[key] = bool((row.get("server_alignment") or {}).get("accepted"))
    return out


def clipped_segments(trace, window):
    s, e = window
    out = []
    for a, b, energy in trace:
        lo = max(a, s)
        hi = min(b, e)
        if hi <= lo:
            continue
        frac = (hi - lo) / (b - a)
        out.append((lo, hi, energy * frac, energy / ((b - a) / 1e9)))
    return out


def raw_curve(trace, window):
    s, _ = window
    seg = clipped_segments(trace, window)
    if not seg:
        return None
    x = [((a + b) / 2 - s) / 1e9 for a, b, _ej, _w in seg]
    y = [w for _a, _b, _ej, w in seg]
    return mod.np.array(x, float), mod.np.array(y, float)


def smooth_curve(trace, window, bin_ns=BIN_NS):
    s, e = window
    if e <= s:
        return None
    xs = []
    ys = []
    a = s
    while a < e:
        b = min(e, a + bin_ns)
        energy = 0.0
        covered = 0
        for x, y, ej, _w in clipped_segments(trace, (a, b)):
            energy += ej
            covered += y - x
        if covered > 0:
            xs.append(((a + b) / 2 - s) / 1e9)
            ys.append(energy / (covered / 1e9))
        a = b
    if not xs:
        return None
    return mod.np.array(xs, float), mod.np.array(ys, float)


def cumulative_curve(trace, window):
    s, _ = window
    seg = clipped_segments(trace, window)
    if not seg:
        return None
    x = [0.0]
    y = [0.0]
    total = 0.0
    for _a, b, ej, _w in seg:
        total += ej
        x.append((b - s) / 1e9)
        y.append(total)
    return mod.np.array(x, float), mod.np.array(y, float)


def combine(curves, kind, duration_s):
    if not curves:
        return None
    if len(curves) == 1:
        return curves[0]
    if kind == "smoothed":
        step = BIN_NS / 1e9
    elif kind == "raw":
        step = 0.006
    else:
        step = 0.01
    max_common = min(float(x[-1]) for x, y in curves if len(x))
    max_common = min(max_common, duration_s)
    grid = mod.np.arange(0.0, max_common + step * 0.25, step)
    if len(grid) < 2:
        return None
    vals = []
    for x, y in curves:
        if kind == "cumulative":
            vals.append(mod.np.interp(grid, x, y, left=0.0, right=y[-1]))
        else:
            vals.append(mod.np.interp(grid, x, y))
    return grid, sum(vals)


def endpoint_curve(record, endpoint, window, kind):
    trace = record.get(endpoint)
    if not trace:
        return None
    if kind == "raw":
        return raw_curve(trace, window)
    if kind == "smoothed":
        return smooth_curve(trace, window)
    return cumulative_curve(trace, window)


def build_records(root: Path):
    files = mod.discover(root)
    accepted = accepted_server(root)
    records = {}
    reps = sorted({rep for role, rep, mode in files})
    for rep in reps:
        for mode in mod.MODES:
            cb = files.get(("client", rep, mode))
            sb = files.get(("server", rep, mode))
            if not cb:
                continue
            metrics = mod.load_metrics(cb)
            windows = mod.windows(metrics)
            if len(windows) < 2:
                continue
            record = {
                "rep": rep,
                "mode": mode,
                "groups": mod.groups(windows),
                "client": read_rapl(cb.get("msr"), 0),
            }
            if sb and accepted.get((rep, mode), False):
                shift = sync_shift(root, rep, mode)
                if shift is not None:
                    record["server"] = read_rapl(sb.get("msr"), shift)
            records[(rep, mode)] = record
    return records


def request_curves(records, mode, group, endpoint, kind):
    curves = []
    for (rep, m), record in records.items():
        if m != mode:
            continue
        for window in record["groups"][group]:
            duration_s = (window[1] - window[0]) / 1e9
            endpoints = ("client", "server") if endpoint == "combined" else (endpoint,)
            parts = []
            for ep in endpoints:
                c = endpoint_curve(record, ep, window, kind)
                if c is None:
                    parts = []
                    break
                parts.append(c)
            c = combine(parts, kind, duration_s)
            if c is not None:
                curves.append(c)
    return curves


def draw(out: Path, index: int, name: str, title: str, endpoint: str, kind: str, mode_filter=None):
    records = RECORDS
    ylabel = "Cumulative RAPL energy (J)" if kind == "cumulative" else "RAPL power (W)"
    for variance in (False, True):
        fig, ax = mod.plt.subplots(figsize=(14, 8))
        made = False
        modes = mod.MODES if mode_filter is None else (mode_filter,)
        for mode in modes:
            for group, label, ls in (("d1", "D1", "-"), ("d2plus", "D2+", "--")):
                curves = request_curves(records, mode, group, endpoint, kind)
                if not curves:
                    continue
                max_common = min(float(x[-1]) for x, y in curves if len(x))
                grid = mod.np.arange(0.0, max_common, PLOT_STEP_S)
                if len(grid) < 2:
                    continue
                arr = mod.np.vstack([
                    mod.np.interp(grid, x, y, left=(0.0 if kind == "cumulative" else y[0]), right=y[-1])
                    for x, y in curves
                ])
                mu = arr.mean(0)
                sd = arr.std(0, ddof=1) if len(arr) > 1 else mod.np.zeros_like(mu)
                ax.plot(grid, mu, ls=ls, label=f"{mod.MODE_NAMES[mode]} {label}")
                if variance:
                    ax.fill_between(grid, mu - sd, mu + sd, alpha=.12)
                made = True
        if made:
            ax.set_xlabel("Elapsed from request start (s)")
            ax.set_ylabel(ylabel)
            ax.set_title(title)
            ax.grid(alpha=.25)
            ax.legend()
        else:
            ax.axis("off")
            ax.text(.5, .5, "No aligned RAPL samples", ha="center")
        folder = out / ("with_variance" if variance else "without_variance")
        (folder / "svg").mkdir(parents=True, exist_ok=True)
        (folder / "pdf").mkdir(parents=True, exist_ok=True)
        fig.savefig(folder / "svg" / f"{index:02d}_{name}.svg", bbox_inches="tight")
        fig.savefig(folder / "pdf" / f"{index:02d}_{name}.pdf", bbox_inches="tight")
        mod.plt.close(fig)


def update_manifest(root: Path):
    out = root / "the_sheet_rules_all" / "d1_d2plus"
    path = out / "manifest.json"
    try:
        data = json.loads(path.read_text())
    except Exception:
        data = {}
    data["power_timeseries_semantics"] = {
        "raw": "per-RAPL-interval power positioned at clipped interval midpoint",
        "smoothed": "50-ms energy-weighted bins from clipped RAPL intervals",
        "cumulative_energy": "actual clipped RAPL joules accumulated from request start",
        "variance": "across aligned request curves; D2+ includes later-download curves",
    }
    path.write_text(json.dumps(data, indent=2) + "\n")


def self_test():
    trace = [(i * 1_000_000_000, (i + 1) * 1_000_000_000, 10.0) for i in range(7)]
    window = (0, 7_000_000_000)
    raw = raw_curve(trace, window)
    smooth = smooth_curve(trace, window)
    cumulative = cumulative_curve(trace, window)
    assert raw is not None and max(abs(v - 10.0) for v in raw[1]) < 1e-9
    assert smooth is not None and max(abs(v - 10.0) for v in smooth[1]) < 1e-9
    assert cumulative is not None and abs(float(cumulative[1][-1]) - 70.0) < 1e-9
    print("D1/D2+ power timeseries self-test PASS")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", type=Path)
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.input is None:
        raise SystemExit("ERROR: --input is required")
    root = args.input.resolve()
    global RECORDS
    RECORDS = build_records(root)
    if not RECORDS:
        raise SystemExit("ERROR: no D1/D2+ records found")
    out = root / "the_sheet_rules_all" / "d1_d2plus"
    specs = [
        (48, "server_power_raw", "Server RAPL power aligned to request start: D1 vs D2+", "server", "raw", None),
        (49, "server_power_smoothed", "Server RAPL power aligned (50-ms energy-weighted): D1 vs D2+", "server", "smoothed", None),
        (50, "server_cumulative_energy", "Server cumulative RAPL energy aligned to request start", "server", "cumulative", None),
        (51, "client_power_raw", "Client RAPL power aligned to request start: D1 vs D2+", "client", "raw", None),
        (52, "client_power_smoothed", "Client RAPL power aligned (50-ms energy-weighted): D1 vs D2+", "client", "smoothed", None),
        (53, "client_cumulative_energy", "Client cumulative RAPL energy aligned to request start", "client", "cumulative", None),
        (54, "combined_power_raw", "Combined endpoint RAPL power aligned to request start", "combined", "raw", None),
        (55, "combined_power_smoothed", "Combined endpoint RAPL power aligned (50-ms energy-weighted)", "combined", "smoothed", None),
        (56, "combined_cumulative_energy", "Combined endpoint cumulative RAPL energy aligned", "combined", "cumulative", None),
        (57, "off_endpoints_power_raw", f"{mod.MODE_NAMES['off']} endpoint RAPL power: D1 vs D2+", "combined", "raw", "off"),
        (58, "off_endpoints_power_smoothed", f"{mod.MODE_NAMES['off']} endpoint RAPL power (50-ms): D1 vs D2+", "combined", "smoothed", "off"),
        (59, "basic_endpoints_power_raw", f"{mod.MODE_NAMES['basic']} endpoint RAPL power: D1 vs D2+", "combined", "raw", "basic"),
        (60, "basic_endpoints_power_smoothed", f"{mod.MODE_NAMES['basic']} endpoint RAPL power (50-ms): D1 vs D2+", "combined", "smoothed", "basic"),
        (61, "plus_endpoints_power_raw", f"{mod.MODE_NAMES['plus']} endpoint RAPL power: D1 vs D2+", "combined", "raw", "plus"),
        (62, "plus_endpoints_power_smoothed", f"{mod.MODE_NAMES['plus']} endpoint RAPL power (50-ms): D1 vs D2+", "combined", "smoothed", "plus"),
    ]
    for spec in specs:
        draw(out, *spec)
    update_manifest(root)
    print("P5 D1/D2+ power timeseries rebuilt with raw/smoothed/cumulative semantics")
    return 0


RECORDS = {}
if __name__ == "__main__":
    raise SystemExit(main())
