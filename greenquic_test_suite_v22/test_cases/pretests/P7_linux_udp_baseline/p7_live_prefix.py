#!/usr/bin/env python3
from __future__ import annotations

import argparse
from datetime import datetime
import re
import sys
import time


def wall_timestamp() -> str:
    return datetime.now().astimezone().isoformat(timespec="milliseconds")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--role", choices=("server", "client"), required=True)
    ap.add_argument("--rep", type=int, required=True)
    ap.add_argument("--runs", type=int, required=True)
    ap.add_argument("--downloads", type=int, required=True)
    args = ap.parse_args()

    p5_start = re.compile(r"\[GreenQUIC-P5\] request=(\d+)/(\d+) start_us=")
    p5_done = re.compile(r"\[GreenQUIC-P5\] request=(\d+)/(\d+) complete_us=.*success=1")
    p5_gap = re.compile(r"\[GreenQUIC-P5\] gap_after=(\d+)")
    p7_start = re.compile(r"\[GreenQUIC-P7\] request=(\d+) start_us=")
    p7_done = re.compile(r"\[GreenQUIC-P7\] request=(\d+) complete_us=.*success=1")
    started = time.monotonic()
    base = f"[{'SERVER' if args.role == 'server' else 'CLIENT'}][REP {args.rep:02d}/{args.runs:02d}]"

    for raw in sys.stdin:
        line = raw.rstrip("\n")
        suffix = ""
        if args.role == "client":
            m = p5_start.search(line)
            if m:
                suffix = f"[GET {m.group(1)}/{m.group(2)} START]"
            else:
                m = p5_done.search(line)
                if m:
                    suffix = f"[GET {m.group(1)}/{m.group(2)} COMPLETE]"
                else:
                    m = p5_gap.search(line)
                    if m:
                        suffix = f"[GAP AFTER GET {m.group(1)}]"
        else:
            m = p7_start.search(line)
            if m:
                suffix = f"[GET {m.group(1)}/{args.downloads} START]"
            else:
                m = p7_done.search(line)
                if m:
                    suffix = f"[GET {m.group(1)}/{args.downloads} COMPLETE]"

        elapsed = time.monotonic() - started
        print(f"[{wall_timestamp()}][+{elapsed:09.3f}s]{base}{suffix} {line}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
