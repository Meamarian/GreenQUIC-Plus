#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import sys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--role", choices=("server", "client"), required=True)
    parser.add_argument("--test-index", type=int, required=True)
    parser.add_argument("--total-tests", type=int, required=True)
    parser.add_argument("--mode", required=True)
    parser.add_argument("--downloads", type=int, required=True)
    args = parser.parse_args()

    request_start = re.compile(
        r"\[GreenQUIC-P4\] request=(\d+)/(\d+) start_us="
    )
    request_complete = re.compile(
        r"\[GreenQUIC-P4\] request=(\d+)/(\d+) complete_us="
    )
    gap = re.compile(r"\[GreenQUIC-P4\] gap_after=(\d+)")
    get_count = 0

    base = (
        f"[{'SERVER' if args.role == 'server' else 'CLIENT'}]"
        f"[TEST {args.test_index:02d}/{args.total_tests:02d}]"
        f"[MODE={args.mode}]"
    )

    for raw in sys.stdin:
        line = raw.rstrip("\n")
        suffix = ""
        if args.role == "server" and "GET" in line:
            get_count += 1
            suffix = f"[GET {get_count}/{args.downloads}]"
        elif args.role == "client":
            match = request_start.search(line)
            if match:
                suffix = f"[DOWNLOAD {match.group(1)}/{match.group(2)} START]"
            else:
                match = request_complete.search(line)
                if match:
                    suffix = f"[DOWNLOAD {match.group(1)}/{match.group(2)} COMPLETE]"
                else:
                    match = gap.search(line)
                    if match:
                        suffix = f"[GAP AFTER DOWNLOAD {match.group(1)}]"
        print(f"{base}{suffix} {line}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
