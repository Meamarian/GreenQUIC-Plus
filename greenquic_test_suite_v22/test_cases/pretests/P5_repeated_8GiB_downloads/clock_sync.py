#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
import statistics
import subprocess
import time

REMOTE_PROBE = (
    "python3 -c 'import json,time; "
    "print(json.dumps({\"wall_ns\":time.time_ns(),\"monotonic_ns\":time.monotonic_ns()}))'"
)


def one_sample(host: str) -> dict[str, int]:
    command = [
        "ssh", "-n", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
        f"root@{host}", REMOTE_PROBE,
    ]
    wall0 = time.time_ns()
    mono0 = time.monotonic_ns()
    completed = subprocess.run(
        command,
        check=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=20,
    )
    mono1 = time.monotonic_ns()
    wall1 = time.time_ns()
    remote = json.loads(completed.stdout.strip().splitlines()[-1])
    remote_wall = int(remote["wall_ns"])
    remote_mono = int(remote["monotonic_ns"])
    mono_mid = (mono0 + mono1) // 2
    wall_mid = (wall0 + wall1) // 2
    rtt = mono1 - mono0
    return {
        "controller_send_wall_ns": wall0,
        "controller_receive_wall_ns": wall1,
        "controller_midpoint_wall_ns": wall_mid,
        "controller_send_monotonic_ns": mono0,
        "controller_receive_monotonic_ns": mono1,
        "controller_midpoint_monotonic_ns": mono_mid,
        "client_wall_ns": remote_wall,
        "client_monotonic_ns": remote_mono,
        "round_trip_ns": rtt,
        "client_minus_controller_offset_ns": remote_wall - wall_mid,
        "client_minus_controller_monotonic_offset_ns": remote_mono - mono_mid,
        "uncertainty_ns": (rtt + 1) // 2,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--samples", type=int, default=9)
    args = parser.parse_args()
    if args.samples < 1:
        raise SystemExit("ERROR: --samples must be positive")

    sample_count = max(args.samples, 9)
    samples = [one_sample(args.host) for _ in range(sample_count)]
    best = min(samples, key=lambda row: row["round_trip_ns"])
    wall_offsets = [row["client_minus_controller_offset_ns"] for row in samples]
    mono_offsets = [row["client_minus_controller_monotonic_offset_ns"] for row in samples]

    result = {
        "schema": "greenquic-p5-clock-sync-v2",
        "controller_host": "idex",
        "client_host": args.host,
        "method": "SSH midpoint estimate; best minimum-RTT sample; direct CLOCK_MONOTONIC-to-CLOCK_MONOTONIC mapping",
        "sample_count": len(samples),
        # Legacy wall-clock fields retained for compatibility.
        "client_minus_controller_offset_ns": best["client_minus_controller_offset_ns"],
        "round_trip_ns": best["round_trip_ns"],
        "uncertainty_ns": best["uncertainty_ns"],
        "offset_spread_ns": max(wall_offsets) - min(wall_offsets),
        "median_offset_ns": int(statistics.median(wall_offsets)),
        # D1/D2+ alignment uses these monotonic fields.
        "client_minus_controller_monotonic_offset_ns": best["client_minus_controller_monotonic_offset_ns"],
        "monotonic_uncertainty_ns": best["uncertainty_ns"],
        "monotonic_offset_spread_ns": max(mono_offsets) - min(mono_offsets),
        "median_monotonic_offset_ns": int(statistics.median(mono_offsets)),
        "samples": samples,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(
        "[P5-CLOCK-SYNC] "
        f"client_minus_server_mono_ms={result['client_minus_controller_monotonic_offset_ns']/1e6:.3f} "
        f"rtt_ms={result['round_trip_ns']/1e6:.3f} "
        f"uncertainty_ms={result['monotonic_uncertainty_ns']/1e6:.3f} "
        f"spread_ms={result['monotonic_offset_spread_ns']/1e6:.3f}",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
