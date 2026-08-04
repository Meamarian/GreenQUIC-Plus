#!/usr/bin/env python3
"""Calculate GreenQUIC payload goodput from the client download interval."""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


def calculate(payload_bytes: int, duration_s: float) -> dict[str, float]:
    if payload_bytes <= 0 or duration_s <= 0:
        raise ValueError("payload bytes and duration must be positive")
    bps = payload_bytes * 8.0 / duration_s
    return {
        "duration_s": duration_s,
        "goodput_bps": bps,
        "goodput_mbps_decimal": bps / 1e6,
        "goodput_gbps_decimal": bps / 1e9,
    }


def derive_log(energy: Path, mode: str) -> Path | None:
    match = re.fullmatch(rf"client_energy_{re.escape(mode)}_(.+)\.json", energy.name)
    logs = energy.parent.parent / "logs"
    if match:
        exact = logs / f"client_{mode}_{match.group(1)}.log"
        if exact.is_file():
            return exact
    candidates = sorted(logs.glob(f"client_{mode}_*.log"), key=lambda p: p.stat().st_mtime_ns, reverse=True)
    return candidates[0] if candidates else None


def parse_log(path: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8", errors="replace")
    transmission = [int(v) for v in re.findall(r"(?mi)^\s*transmission time \[us\]:\s*(\d+)\s*$", text)]
    completions = [
        {"file": name.strip(), "duration_ms": int(ms)}
        for name, ms in re.findall(r"(?m)^\s*(.+?):\s*Completed download!\s*\((\d+)\s*ms\)\s*$", text)
    ]
    return {"transmission_us": transmission, "completions": completions}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--energy", type=Path, required=True)
    parser.add_argument("--client-log", type=Path)
    parser.add_argument("--bytes", type=int, required=True)
    parser.add_argument("--mode", required=True)
    parser.add_argument("--test-id", required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    log_path = args.client_log or derive_log(args.energy, args.mode)
    parsed = parse_log(log_path) if log_path and log_path.is_file() else {"transmission_us": [], "completions": []}
    transmission = parsed["transmission_us"]
    completions = parsed["completions"]
    if transmission:
        duration_s = transmission[-1] / 1_000_000.0
        source = "client transmission timer, microsecond resolution"
    elif len(completions) == 1:
        duration_s = completions[0]["duration_ms"] / 1000.0
        source = "MsQuic completion timer, millisecond resolution"
    else:
        energy = json.loads(args.energy.read_text(encoding="utf-8"))
        duration_s = float(energy.get("elapsed_s") or 0.0)
        source = "whole client process interval fallback"
    primary = calculate(args.bytes, duration_s)
    cross = None
    if len(completions) == 1:
        cross = calculate(args.bytes, completions[0]["duration_ms"] / 1000.0)
    result = {
        "schema": "greenquic-goodput-v2",
        "test_id": args.test_id,
        "mode": args.mode,
        "definition": "successfully downloaded payload bits divided by client download duration",
        "payload_bytes": args.bytes,
        "payload_gib": args.bytes / (1024 ** 3),
        "timing_source": source,
        "primary": primary,
        "msquic_completion_crosscheck": cross,
        "scope_note": "Protocol headers and retransmitted bytes are excluded.",
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")

    print("\n=== GreenQUIC Goodput Summary ===")
    print(f"- Test: {args.test_id}")
    print(f"- GreenQUIC mode: {args.mode}")
    print(f"- Payload: {result['payload_gib']:.3f} GiB ({args.bytes} bytes)")
    print(f"- Download duration: {primary['duration_s']:.6f} s")
    print(f"- Goodput: {primary['goodput_gbps_decimal']:.6f} Gbit/s")
    print(f"- Goodput: {primary['goodput_mbps_decimal']:.3f} Mbit/s")
    print(f"- Timing source: {source}")
    if cross is not None:
        print(f"- MsQuic completion cross-check: {cross['goodput_gbps_decimal']:.6f} Gbit/s")
    print("- Scope: payload bytes only; protocol headers and retransmissions are excluded")
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
