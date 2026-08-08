#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
import statistics
import subprocess
import time


def one_sample(host: str) -> dict[str, int]:
    command = [
        "ssh",
        "-n",
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=10",
        f"root@{host}",
        "python3 -c 'import time; print(time.time_ns())'",
    ]
    t0 = time.time_ns()
    completed = subprocess.run(
        command,
        check=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=20,
    )
    t1 = time.time_ns()
    remote_ns = int(completed.stdout.strip().splitlines()[-1])
    midpoint_ns = (t0 + t1) // 2
    return {
        "controller_send_wall_ns": t0,
        "controller_receive_wall_ns": t1,
        "controller_midpoint_wall_ns": midpoint_ns,
        "client_wall_ns": remote_ns,
        "round_trip_ns": t1 - t0,
        "client_minus_controller_offset_ns": remote_ns - midpoint_ns,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--samples", type=int, default=5)
    args = parser.parse_args()

    if args.samples < 1:
        raise SystemExit("ERROR: --samples must be positive")

    samples = [one_sample(args.host) for _ in range(args.samples)]
    best = min(samples, key=lambda row: row["round_trip_ns"])
    offsets = [row["client_minus_controller_offset_ns"] for row in samples]

    result = {
        "schema": "greenquic-p5-clock-sync-v1",
        "controller_host": "idex",
        "client_host": args.host,
        "method": "SSH midpoint estimate; best minimum-RTT sample",
        "sample_count": len(samples),
        "client_minus_controller_offset_ns": best["client_minus_controller_offset_ns"],
        "round_trip_ns": best["round_trip_ns"],
        "uncertainty_ns": best["round_trip_ns"] // 2,
        "offset_spread_ns": max(offsets) - min(offsets),
        "median_offset_ns": int(statistics.median(offsets)),
        "samples": samples,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")

    print(
        "[P5-CLOCK-SYNC] "
        f"client_minus_server_ms={result['client_minus_controller_offset_ns'] / 1e6:.3f} "
        f"rtt_ms={result['round_trip_ns'] / 1e6:.3f} "
        f"uncertainty_ms={result['uncertainty_ns'] / 1e6:.3f}",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
