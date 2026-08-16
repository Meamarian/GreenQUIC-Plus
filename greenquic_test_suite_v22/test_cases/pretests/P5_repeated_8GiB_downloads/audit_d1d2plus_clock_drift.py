#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import time
from pathlib import Path


def finite(value):
    try:
        x = float(value)
        return x if math.isfinite(x) else None
    except (TypeError, ValueError):
        return None


def load_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def sync_path(root: Path, rep: int, mode: str, end: bool = False) -> Path:
    prefix = "clock_sync_end_" if end else "clock_sync_"
    return root / f"{prefix}rep{rep:02d}_{mode}.json"


def wait_for(path: Path, seconds: float) -> bool:
    deadline = time.monotonic() + max(0.0, seconds)
    while time.monotonic() <= deadline:
        if path.is_file():
            return True
        time.sleep(0.10)
    return path.is_file()


def monotonic_offset(sync: dict | None):
    if not sync:
        return None
    return finite(sync.get("client_minus_controller_monotonic_offset_ns"))


def monotonic_uncertainty(sync: dict | None):
    if not sync:
        return None
    return finite(sync.get("monotonic_uncertainty_ns"))


def audit(root: Path, wait_seconds: float, max_drift_ms: float, max_uncertainty_ms: float) -> dict:
    qpath = root / "the_sheet_rules_all" / "d1_d2plus" / "alignment_quality.json"
    quality = load_json(qpath)
    if not quality:
        raise SystemExit(f"ERROR: missing/invalid alignment quality file: {qpath}")

    max_drift_ns = max_drift_ms * 1e6
    max_uncertainty_ns = max_uncertainty_ms * 1e6
    all_pass = bool(quality.get("pass", False))
    worst_edge_ns = 0.0

    for record in quality.get("records", []):
        rep = int(record.get("repetition", 0) or 0)
        mode = str(record.get("mode", ""))
        start_path = sync_path(root, rep, mode, False)
        end_path = sync_path(root, rep, mode, True)
        start_sync = load_json(start_path)
        if not end_path.is_file():
            wait_for(end_path, wait_seconds)
        end_sync = load_json(end_path)

        start_off = monotonic_offset(start_sync)
        end_off = monotonic_offset(end_sync)
        start_unc = monotonic_uncertainty(start_sync)
        end_unc = monotonic_uncertainty(end_sync)
        complete = None not in (start_off, end_off, start_unc, end_unc)
        drift_ns = (end_off - start_off) if complete else None
        drift_abs_ns = abs(drift_ns) if drift_ns is not None else None

        drift_pass = bool(
            complete
            and drift_abs_ns <= max_drift_ns
            and start_unc <= max_uncertainty_ns
            and end_unc <= max_uncertainty_ns
        )

        server = record.get("server") or {}
        old_server_edge = finite(server.get("conservative_edge_uncertainty_ns")) or 0.0
        if complete:
            server_edge = old_server_edge + drift_abs_ns + end_unc
            server["conservative_edge_uncertainty_ns"] = int(math.ceil(server_edge))
            server["post_clock_sync_uncertainty_ns"] = int(end_unc)
            server["measured_clock_offset_drift_ns"] = int(drift_ns)
            server["measured_clock_offset_drift_abs_ns"] = int(drift_abs_ns)
        else:
            server_edge = float("inf")

        client = record.get("client") or {}
        client_edge = finite(client.get("conservative_edge_uncertainty_ns")) or 0.0
        if math.isfinite(server_edge):
            worst_edge_ns = max(worst_edge_ns, client_edge, server_edge)

        record["clock_drift_validation"] = {
            "pass": drift_pass,
            "start_file": str(start_path),
            "end_file": str(end_path),
            "start_schema": start_sync.get("schema") if start_sync else None,
            "end_schema": end_sync.get("schema") if end_sync else None,
            "start_offset_ns": int(start_off) if start_off is not None else None,
            "end_offset_ns": int(end_off) if end_off is not None else None,
            "offset_drift_ns": int(drift_ns) if drift_ns is not None else None,
            "offset_drift_ms": drift_ns / 1e6 if drift_ns is not None else None,
            "start_uncertainty_ms": start_unc / 1e6 if start_unc is not None else None,
            "end_uncertainty_ms": end_unc / 1e6 if end_unc is not None else None,
            "mapping_note": (
                "server traces use the pre-run direct CLOCK_MONOTONIC offset; "
                "the post-run sync measures offset drift across the workload, and "
                "the full measured drift is added to the conservative edge uncertainty"
            ),
        }
        record["server"] = server
        record["client"] = client
        record["pass"] = bool(record.get("pass", False) and drift_pass)
        all_pass = all_pass and record["pass"]

    median_ms = finite(quality.get("median_active_duration_ms"))
    if median_ms and median_ms > 0 and worst_edge_ns > 0:
        accuracy = 100.0 * (1.0 - min(1.0, (2.0 * worst_edge_ns) / (median_ms * 1e6)))
    else:
        accuracy = None

    thresholds = quality.setdefault("thresholds", {})
    thresholds["max_clock_offset_drift_ms"] = max_drift_ms
    thresholds["max_post_clock_sync_uncertainty_ms"] = max_uncertainty_ms
    quality["schema"] = "greenquic-d1d2plus-alignment-quality-v2"
    quality["pass"] = all_pass
    quality["worst_conservative_edge_uncertainty_ms"] = worst_edge_ns / 1e6 if worst_edge_ns else None
    quality["temporal_alignment_accuracy_pct"] = accuracy
    quality["accuracy_definition"] = (
        "100*(1-2*worst_conservative_edge_uncertainty/median_active_duration); "
        "edge uncertainty includes RAPL cadence, frequency cadence/read span, "
        "clock-bridge uncertainty, pre-run cross-host sync uncertainty, and "
        "measured pre-to-post CLOCK_MONOTONIC offset drift. This is temporal/window "
        "alignment accuracy, not Intel RAPL absolute electrical accuracy."
    )
    quality["cross_host_drift_method"] = (
        "pre-run and post-final-download direct CLOCK_MONOTONIC sync; no SSH probes are "
        "performed during an active transfer"
    )
    qpath.write_text(json.dumps(quality, indent=2) + "\n", encoding="utf-8")

    mpath = root / "the_sheet_rules_all" / "d1_d2plus" / "manifest.json"
    manifest = load_json(mpath)
    if manifest:
        manifest["clock_drift_validation"] = "alignment_quality.json"
        manifest["clock_sync_semantics"] = (
            "pre-run monotonic mapping plus post-final-download drift audit; "
            "no sync traffic during active downloads"
        )
        mpath.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    return quality


def self_test() -> int:
    import tempfile
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        out = root / "the_sheet_rules_all" / "d1_d2plus"
        out.mkdir(parents=True)
        (out / "alignment_quality.json").write_text(json.dumps({
            "schema": "x",
            "pass": True,
            "median_active_duration_ms": 7000.0,
            "worst_conservative_edge_uncertainty_ms": 6.0,
            "thresholds": {},
            "records": [{
                "repetition": 1,
                "mode": "plus",
                "pass": True,
                "client": {"conservative_edge_uncertainty_ns": 6_000_000},
                "server": {"conservative_edge_uncertainty_ns": 6_500_000},
            }],
        }) + "\n")
        (out / "manifest.json").write_text("{}\n")
        for end, offset, unc in [(False, 100_000, 100_000), (True, 160_000, 120_000)]:
            p = sync_path(root, 1, "plus", end)
            p.write_text(json.dumps({
                "schema": "greenquic-p5-clock-sync-v4",
                "client_minus_controller_monotonic_offset_ns": offset,
                "monotonic_uncertainty_ns": unc,
            }) + "\n")
        q = audit(root, 0, 5.0, 5.0)
        assert q["pass"] is True
        drift = q["records"][0]["clock_drift_validation"]["offset_drift_ns"]
        assert drift == 60_000
        assert q["temporal_alignment_accuracy_pct"] > 99.7
    print("clock drift audit self-test PASS")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", type=Path)
    ap.add_argument("--wait-seconds", type=float, default=10.0)
    ap.add_argument("--max-drift-ms", type=float, default=5.0)
    ap.add_argument("--max-uncertainty-ms", type=float, default=5.0)
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if args.input is None:
        raise SystemExit("ERROR: --input is required")
    q = audit(args.input.resolve(), args.wait_seconds, args.max_drift_ms, args.max_uncertainty_ms)
    acc = q.get("temporal_alignment_accuracy_pct")
    edge = q.get("worst_conservative_edge_uncertainty_ms")
    print(
        f"P5 CLOCK DRIFT AUDIT pass={1 if q.get('pass') else 0} "
        f"worst_edge_ms={edge if edge is not None else 'N/A'} "
        f"temporal_accuracy_pct={acc if acc is not None else 'N/A'}"
    )
    return 0 if q.get("pass") else 4


if __name__ == "__main__":
    raise SystemExit(main())
