#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, time
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument('--output', type=Path, required=True)
ap.add_argument('--event', required=True)
ap.add_argument('--run-id', default='')
ap.add_argument('--role', default='')
a = ap.parse_args()
a.output.parent.mkdir(parents=True, exist_ok=True)
row = {
    'schema': 'greenquic-p7-control-timeline-v1',
    'event': a.event,
    'run_id': a.run_id,
    'role': a.role,
    'monotonic_ns': time.monotonic_ns(),
    'wall_ns': time.time_ns(),
}
with a.output.open('a', encoding='utf-8') as f:
    f.write(json.dumps(row, separators=(',', ':')) + '\n')
print(json.dumps(row, separators=(',', ':')))
