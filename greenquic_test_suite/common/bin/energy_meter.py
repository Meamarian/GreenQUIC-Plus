#!/usr/bin/env python3
"""Small RAPL interval meter with explicit package-counter validation."""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any


def read_domains() -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    root = Path("/sys/class/powercap")
    if not root.exists():
        return result
    for energy in root.glob("**/energy_uj"):
        domain = energy.parent
        try:
            name_file = domain / "name"
            name = name_file.read_text(encoding="utf-8").strip() if name_file.exists() else domain.name
            value = int(energy.read_text(encoding="utf-8").strip())
            max_file = domain / "max_energy_range_uj"
            maximum = int(max_file.read_text(encoding="utf-8").strip()) if max_file.exists() else 0
            result[str(domain)] = {
                "name": name,
                "energy_uj": value,
                "max_uj": maximum,
                "is_package": name.lower().startswith("package"),
            }
        except (OSError, ValueError):
            continue
    return result


def snapshot() -> dict[str, Any]:
    domains = read_domains()
    return {
        "wall_ns": time.time_ns(),
        "mono_ns": time.monotonic_ns(),
        "domains": domains,
        "package_available": any(row.get("is_package") for row in domains.values()),
    }


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def require_package_or_fail(snap: dict[str, Any], phase: str, required: bool) -> None:
    if required and not snap.get("package_available", False):
        raise RuntimeError(
            f"no package RAPL counter is readable during {phase}; "
            "energy results would be invalid. Set GQ_REQUIRE_RAPL=0 only for a non-energy dry run."
        )


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    start = sub.add_parser("start")
    start.add_argument("--out", type=Path, required=True)
    start.add_argument("--require-package", action="store_true")
    finish = sub.add_parser("finish")
    finish.add_argument("--start", type=Path, required=True)
    finish.add_argument("--out", type=Path, required=True)
    finish.add_argument("--label", default="")
    finish.add_argument("--require-package", action="store_true")
    args = ap.parse_args()

    try:
        if args.cmd == "start":
            snap = snapshot()
            require_package_or_fail(snap, "start", args.require_package)
            write_json(args.out, snap)
            return 0

        before = json.loads(args.start.read_text(encoding="utf-8"))
        after = snapshot()
        require_package_or_fail(before, "start snapshot", args.require_package)
        require_package_or_fail(after, "finish", args.require_package)

        rows: list[dict[str, Any]] = []
        total_package_j = 0.0
        problems: list[str] = []
        for domain, old in before.get("domains", {}).items():
            new = after.get("domains", {}).get(domain)
            if new is None:
                problems.append(f"counter disappeared: {domain}")
                continue
            delta = int(new["energy_uj"]) - int(old["energy_uj"])
            maximum = int(old.get("max_uj", 0))
            if delta < 0:
                if maximum <= 0:
                    problems.append(f"negative delta without max range: {domain}")
                    continue
                delta += maximum
            if delta < 0 or (maximum > 0 and delta > maximum):
                problems.append(f"invalid wrapped delta for {domain}: {delta} uJ")
                continue
            joules = delta / 1_000_000.0
            is_package = bool(old.get("is_package", False))
            rows.append({
                "path": domain,
                "name": old.get("name", ""),
                "joules": joules,
                "is_package": is_package,
            })
            if is_package:
                total_package_j += joules

        elapsed_s = (int(after["mono_ns"]) - int(before["mono_ns"])) / 1_000_000_000.0
        package_rows = [row for row in rows if row["is_package"]]
        output = {
            "label": args.label,
            "start_wall_ns": before.get("wall_ns"),
            "end_wall_ns": after.get("wall_ns"),
            "elapsed_s": elapsed_s,
            "total_package_j": total_package_j,
            "average_package_w": (total_package_j / elapsed_s) if elapsed_s > 0 and package_rows else None,
            "domains": rows,
            "rapl_available": bool(package_rows),
            "problems": problems,
        }
        write_json(args.out, output)
        print(json.dumps(output, indent=2))
        if args.require_package and (not package_rows or problems):
            return 3
        return 0
    except (OSError, ValueError, json.JSONDecodeError, RuntimeError) as exc:
        print(f"energy_meter: {exc}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
