#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import socket
from pathlib import Path


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return ""


def read_number(path: Path) -> int | None:
    value = read_text(path)
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cpu", type=int, required=True)
    parser.add_argument("--role", choices=("server", "client"), required=True)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()

    root = Path(f"/sys/devices/system/cpu/cpu{args.cpu}/cpuidle")
    states: dict[str, dict[str, object]] = {}

    if root.is_dir():
        def state_index(path: Path) -> int:
            try:
                return int(path.name.removeprefix("state"))
            except ValueError:
                return 10**9

        for state_dir in sorted(root.glob("state*"), key=state_index):
            index = state_index(state_dir)
            if index == 10**9:
                continue
            states[str(index)] = {
                "index": index,
                "linux_state": state_dir.name,
                "name": read_text(state_dir / "name") or f"state{index}",
                "description": read_text(state_dir / "desc"),
                "exit_latency_us": read_number(state_dir / "latency"),
                "target_residency_us": read_number(state_dir / "residency"),
            }

    payload = {
        "schema": "greenquic-p5-cpuidle-map-v1",
        "host": socket.gethostname(),
        "role": args.role,
        "cpu": args.cpu,
        "sysfs_root": str(root),
        "states": states,
        "valid": bool(states),
    }
    rendered = json.dumps(payload, indent=2) + "\n"

    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(rendered, encoding="utf-8")
    else:
        print(rendered, end="")

    return 0 if states else 1


if __name__ == "__main__":
    raise SystemExit(main())
