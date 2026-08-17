#!/usr/bin/env python3
"""Strict validation for the P7 two-CPU Linux baseline."""
from __future__ import annotations

import argparse
import json
from pathlib import Path


def env_map(path: Path) -> dict[str, str]:
    out = {}
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" in raw:
            key, value = raw.split("=", 1)
            out[key.strip()] = value.strip()
    return out


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--matrix", type=Path, required=True)
    ap.add_argument("--runs", type=int, required=True)
    ap.add_argument("--report-dir", type=Path)
    args = ap.parse_args()

    root = args.matrix.resolve()
    errors: list[str] = []
    cfg_path = root / "matrix_config.env"
    if not cfg_path.is_file():
        raise SystemExit(f"ERROR: missing {cfg_path}")
    cfg = env_map(cfg_path)

    expected = {
        "dataplane_cpu": "19,20",
        "quic_cpus": "21,22,23,24",
        "pin_irq": "1",
        "pin_quic": "1",
        "disable_rps": "1",
        "combined_channels": "2",
        "stop_irqbalance": "1",
        "enable_record": "1",
    }
    for key, wanted in expected.items():
        got = cfg.get(key)
        if got != wanted:
            errors.append(f"matrix_config {key}={got!r}, expected {wanted!r}")

    for endpoint in ("server", "client"):
        path = root / "setup" / f"{endpoint}_multicore_irq_map.json"
        if not path.is_file():
            errors.append(f"missing {endpoint} IRQ map: {path}")
            continue
        try:
            data = read_json(path)
            mappings = data.get("mappings") or []
            used = {int(row["cpu"]) for row in mappings}
            after = {str(row.get("after", "")) for row in mappings}
        except Exception as exc:
            errors.append(f"invalid {endpoint} IRQ map: {exc}")
            continue
        if used != {19, 20}:
            errors.append(
                f"{endpoint} queue IRQs use CPUs={sorted(used)}, expected [19, 20]"
            )
        if len(mappings) < 2:
            errors.append(f"{endpoint} has only {len(mappings)} mapped TxRx IRQs")
        if any("," in value or "-" in value for value in after):
            errors.append(
                f"{endpoint} queue IRQ mapping is not single-CPU per queue: {sorted(after)}"
            )

    for endpoint in ("server", "client"):
        rep_dirs = sorted((root / "runs" / endpoint).glob("rep*"))
        if len(rep_dirs) != args.runs:
            errors.append(
                f"{endpoint}: found {len(rep_dirs)} run directories, expected {args.runs}"
            )
        for rep_index, run_dir in enumerate(rep_dirs, 1):
            summary_path = run_dir / "summary.json"
            mapping_path = run_dir / "cstate_mapping.json"
            freq_path = run_dir / "frequency.jsonl"
            if not summary_path.is_file():
                errors.append(f"{endpoint} rep{rep_index:02d}: summary missing")
                continue
            summary = read_json(summary_path)

            if not mapping_path.is_file():
                errors.append(f"{endpoint} rep{rep_index:02d}: C-state mapping missing")
            else:
                try:
                    mapping = read_json(mapping_path)
                    mapped = {int(x) for x in (mapping.get("cpus") or {}).keys()}
                except Exception as exc:
                    errors.append(
                        f"{endpoint} rep{rep_index:02d}: invalid C-state mapping: {exc}"
                    )
                else:
                    if mapped != {19, 20}:
                        errors.append(
                            f"{endpoint} rep{rep_index:02d}: C-state CPUs={sorted(mapped)}, expected [19, 20]"
                        )

            seen: set[int] = set()
            if not freq_path.is_file():
                errors.append(f"{endpoint} rep{rep_index:02d}: frequency trace missing")
            else:
                for raw in freq_path.read_text(
                    encoding="utf-8", errors="replace"
                ).splitlines():
                    try:
                        row = json.loads(raw)
                    except Exception:
                        continue
                    if row.get("type") == "line" and row.get("cpu") is not None:
                        seen.add(int(row["cpu"]))
                if not {19, 20}.issubset(seen):
                    errors.append(
                        f"{endpoint} rep{rep_index:02d}: frequency CPUs={sorted(seen)}, expected both 19 and 20"
                    )

            for scope in ("active", "gap", "combined"):
                freq = (
                    ((summary.get("scopes") or {}).get(scope) or {})
                    .get("frequency") or {}
                )
                missing = {19, 20} - {int(key) for key in freq.keys()}
                if missing:
                    errors.append(
                        f"{endpoint} rep{rep_index:02d} {scope}: summary frequency missing CPUs {sorted(missing)}"
                    )

                scope_row = ((summary.get("scopes") or {}).get(scope) or {})
                duration = scope_row.get("duration_s")
                states = scope_row.get("cstate") or {}
                try:
                    duration_f = float(duration)
                    idle_cpu_s = sum(
                        float((row or {}).get("seconds", 0.0))
                        for row in states.values()
                    )
                except Exception:
                    continue
                if duration_f > 0:
                    normalized = idle_cpu_s / (duration_f * 2.0) * 100.0
                    if normalized < -1e-6 or normalized > 100.000001:
                        errors.append(
                            f"{endpoint} rep{rep_index:02d} {scope}: normalized "
                            f"C-state idle fraction={normalized:.6f}% outside 0..100"
                        )

    if args.report_dir:
        validation = args.report_dir / "multicore" / "multicore_validation.json"
        if not validation.is_file():
            errors.append(f"multicore report validation missing: {validation}")
        else:
            try:
                data = read_json(validation)
                if data.get("status") != "PASS":
                    errors.append(
                        f"multicore report status={data.get('status')!r}, expected PASS"
                    )
            except Exception as exc:
                errors.append(f"invalid multicore report validation: {exc}")

    audit = {
        "schema": "greenquic-p7-multicore-matrix-audit-v1",
        "matrix": str(root),
        "runs": args.runs,
        "dataplane_cpus": [19, 20],
        "quic_cpus": [21, 22, 23, 24],
        "combined_channels": 2,
        "errors": errors,
        "status": "PASS" if not errors else "FAIL",
        "rss_note": (
            "A single QUIC connection may hash to one Linux RX queue. "
            "This validates a two-queue/two-CPU baseline, not RX scaling."
        ),
    }
    (root / "multicore_validation.json").write_text(
        json.dumps(audit, indent=2) + "\n", encoding="utf-8"
    )

    if errors:
        for error in errors:
            print("ERROR:", error)
        print(f"P7 MULTICORE VALIDATION FAIL: {len(errors)} error(s)")
        return 2

    print("P7 MULTICORE VALIDATION PASS")
    print("dataplane CPUs=19,20 combined_channels=2 QUIC CPUs=21,22,23,24")
    print("NOTE: single QUIC connection does not prove RSS scaling across both queues.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
