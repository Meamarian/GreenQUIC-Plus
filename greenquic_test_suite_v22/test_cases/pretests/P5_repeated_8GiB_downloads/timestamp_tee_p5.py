#!/usr/bin/env python3
"""Print application output unchanged while recording per-line timestamps."""
from __future__ import annotations

import argparse
import json
import signal
import sys
import time
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw-log", type=Path, required=True)
    parser.add_argument("--timeline", type=Path, required=True)
    args = parser.parse_args()

    # GREENQUIC-P5-TIMESTAMP-SIGINT-SAFE-V1
    # The controller gracefully SIGINTs quicinteropserver. This logger must
    # survive and drain the server pipe through EOF so the final GreenQUIC
    # COUNTERS line and cleanup output reach the raw log and timeline.
    signal.signal(signal.SIGINT, signal.SIG_IGN)

    # Native MsQuic/DPDK output may contain non-UTF-8 bytes.
    sys.stdin.reconfigure(encoding="utf-8", errors="replace")
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

    args.raw_log.parent.mkdir(parents=True, exist_ok=True)
    args.timeline.parent.mkdir(parents=True, exist_ok=True)
    start_wall_ns = time.time_ns()
    start_mono_ns = time.monotonic_ns()

    with args.raw_log.open("w", encoding="utf-8", errors="replace") as raw_handle, \
         args.timeline.open("w", encoding="utf-8") as timeline_handle:
        timeline_handle.write(json.dumps({
            "type": "meta",
            "start_wall_ns": start_wall_ns,
            "start_monotonic_ns": start_mono_ns,
            "clock": "time.monotonic_ns captured when each complete log line reached the wrapper",
        }) + "\n")
        timeline_handle.flush()

        index = 0
        for received in sys.stdin:
            line = received if received.endswith("\n") else received + "\n"
            mono_ns = time.monotonic_ns()
            wall_ns = time.time_ns()
            raw_handle.write(line)
            raw_handle.flush()
            sys.stdout.write(line)
            sys.stdout.flush()
            timeline_handle.write(json.dumps({
                "type": "line",
                "index": index,
                "elapsed_s": (mono_ns - start_mono_ns) / 1e9,
                "wall_ns": wall_ns,
                "monotonic_ns": mono_ns,
                "line": line.rstrip("\r\n"),
            }, ensure_ascii=False) + "\n")
            timeline_handle.flush()
            index += 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
