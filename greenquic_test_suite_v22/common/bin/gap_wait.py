#!/usr/bin/env python3
from __future__ import annotations
import argparse
import time

ap = argparse.ArgumentParser()
ap.add_argument("--us", type=int, required=True)
args = ap.parse_args()
if args.us <= 0:
    raise SystemExit(0)
end = time.perf_counter_ns() + args.us * 1000
# Sleep for the coarse part, then spin for the final part. This controls only the
# explicit wait; a new process launch adds extra delay.
if args.us > 2000:
    time.sleep((args.us - 1000) / 1_000_000)
while time.perf_counter_ns() < end:
    pass
