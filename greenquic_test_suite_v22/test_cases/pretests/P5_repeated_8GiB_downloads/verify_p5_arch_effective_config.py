#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import re
from pathlib import Path


FORBIDDEN_RUNTIME_KEYS = {
    "RxMbufPoolSize",
    "TxMbufPoolSize",
}


def parse_ini(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith(("#", ";")) or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def norm_csv(value: str) -> str:
    return ",".join(x.strip() for x in value.split(",") if x.strip())


def role_from(path: Path) -> str:
    name = path.name.lower()
    parts = [x.lower() for x in path.parts]
    if name.startswith("server_") or "server" in parts:
        return "server"
    if name.startswith("client_") or "client" in parts:
        return "client"
    return "unknown"


def main() -> int:
    ap = argparse.ArgumentParser(description="Verify effective P5 architecture runtime topology from generated dpdk.ini artifacts.")
    ap.add_argument("--case-dir", type=Path, required=True)
    ap.add_argument("--dpdk-lcores", required=True)
    ap.add_argument("--quic-cpus", required=True)
    ap.add_argument("--partition-map", required=True)
    ap.add_argument("--affinitize", choices=("0", "1"), required=True)
    ap.add_argument("--execution-profile", required=True)
    ap.add_argument("--enable-multicore", choices=("0", "1"), required=True)
    args = ap.parse_args()

    root = args.case_dir.resolve()
    expected = {
        "GreenQuicMode": "off",
        "GreenQuicDpdkLcores": norm_csv(args.dpdk_lcores),
        "GreenQuicEnableMultiCore": args.enable_multicore,
        "GreenQuicQuicWorkerCpus": norm_csv(args.quic_cpus),
        "GreenQuicQuicAffinitize": args.affinitize,
        "GreenQuicPartitionDpdkMap": norm_csv(args.partition_map),
        "GreenQuicQuicProfile": args.execution_profile,
    }

    candidates = sorted({p.resolve() for p in root.rglob("*_dpdk.ini") if p.is_file()})
    # Also accept an unprefixed runtime dpdk.ini if a controller failure left it
    # in the case tree. It is still useful effective-config evidence.
    candidates += [
        p.resolve() for p in root.rglob("dpdk.ini")
        if p.is_file() and p.resolve() not in candidates
    ]

    rows: list[dict[str, object]] = []
    global_errors: list[str] = []
    roles_seen: set[str] = set()

    for path in candidates:
        values = parse_ini(path)
        # Ignore unrelated INIs that are not GreenQUIC runtime topology files.
        if "GreenQuicDpdkLcores" not in values or "GreenQuicQuicWorkerCpus" not in values:
            continue
        role = role_from(path)
        roles_seen.add(role)
        errors: list[str] = []
        forbidden_present = sorted(FORBIDDEN_RUNTIME_KEYS.intersection(values))
        if forbidden_present:
            errors.append(
                "unsupported runtime key(s) present: " + ",".join(forbidden_present)
            )
        for key, want in expected.items():
            got = values.get(key, "")
            if key in {"GreenQuicDpdkLcores", "GreenQuicQuicWorkerCpus", "GreenQuicPartitionDpdkMap"}:
                got = norm_csv(got)
            if got != want:
                errors.append(f"{key}: expected {want!r}, got {got!r}")
        init_args = values.get("DpdkInitArgs", "")
        if not re.search(rf"(?:^|\s)-l\s+{re.escape(expected['GreenQuicDpdkLcores'])}(?:\s|$)", init_args):
            errors.append(
                f"DpdkInitArgs: expected '-l {expected['GreenQuicDpdkLcores']}', got {init_args!r}"
            )
        rows.append({
            "role": role,
            "path": str(path),
            "status": "PASS" if not errors else "FAIL",
            "errors": " | ".join(errors),
            **{f"actual_{k}": values.get(k, "") for k in expected},
            "forbidden_runtime_keys": ",".join(forbidden_present),
        })

    if not rows:
        global_errors.append("no generated GreenQUIC dpdk.ini artifacts found")
    if "server" not in roles_seen:
        global_errors.append("no server effective dpdk.ini evidence found")
    if "client" not in roles_seen:
        global_errors.append("no client effective dpdk.ini evidence found")
    failed_rows = [r for r in rows if r["status"] != "PASS"]
    if failed_rows:
        global_errors.append(f"{len(failed_rows)} effective-config artifact(s) do not match requested topology")

    status = "PASS" if not global_errors else "FAIL"
    out = {
        "schema": "greenquic-p5-arch-effective-config-v3",
        "status": status,
        "expected": expected,
        "forbidden_runtime_keys": sorted(FORBIDDEN_RUNTIME_KEYS),
        "roles_seen": sorted(roles_seen),
        "artifacts_checked": len(rows),
        "errors": global_errors,
        "rows": rows,
    }
    json_path = root / "ARCH_EFFECTIVE_CONFIG.json"
    csv_path = root / "ARCH_EFFECTIVE_CONFIG.csv"
    json_path.write_text(json.dumps(out, indent=2) + "\n", encoding="utf-8")
    fields = ["role", "path", "status", "errors", "forbidden_runtime_keys"] + [f"actual_{k}" for k in expected]
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for row in rows:
            w.writerow(row)

    print(f"P5 ARCH EFFECTIVE CONFIG {status}: artifacts={len(rows)} roles={','.join(sorted(roles_seen)) or '-'}")
    for err in global_errors:
        print(f"  ERROR: {err}")
    for row in failed_rows[:10]:
        print(f"  MISMATCH {row['path']}: {row['errors']}")
    return 0 if status == "PASS" else 3


if __name__ == "__main__":
    raise SystemExit(main())
