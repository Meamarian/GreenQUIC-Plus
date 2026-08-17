#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import signal
import time
from pathlib import Path

STOP = False


def on_signal(_sig, _frame):
    global STOP
    STOP = True


def parse_cpu_list(text: str) -> list[int]:
    out: list[int] = []
    for part in text.split(','):
        part = part.strip()
        if not part:
            continue
        if '-' in part:
            a, b = part.split('-', 1)
            out.extend(range(int(a), int(b) + 1))
        else:
            out.append(int(part))
    out = sorted(set(out))
    if not out:
        raise ValueError('empty CPU list')
    return out


def read_proc_stat(wanted: set[int]) -> dict[int, tuple[int, int]]:
    rows: dict[int, tuple[int, int]] = {}
    with open('/proc/stat', 'r', encoding='utf-8', errors='replace') as f:
        for raw in f:
            if not raw.startswith('cpu') or raw.startswith('cpu '):
                continue
            name, *vals = raw.split()
            try:
                cpu = int(name[3:])
            except ValueError:
                continue
            if cpu not in wanted:
                continue
            nums = [int(x) for x in vals]
            # Linux /proc/stat fields: user nice system idle iowait irq softirq steal guest guest_nice.
            # guest times are already included in user/nice, so exclude them from total.
            idle = (nums[3] if len(nums) > 3 else 0) + (nums[4] if len(nums) > 4 else 0)
            total = sum(nums[:8])
            busy = total - idle
            rows[cpu] = (busy, total)
    return rows


def main() -> int:
    ap = argparse.ArgumentParser(description='Low-overhead cumulative /proc/stat sampler for selected CPUs.')
    ap.add_argument('--cpus', default='19,20,21,22,23,24')
    ap.add_argument('--interval-ms', type=float, default=20.0)
    ap.add_argument('--output', type=Path, required=True)
    args = ap.parse_args()
    if args.interval_ms <= 0:
        raise SystemExit('ERROR: --interval-ms must be positive')
    try:
        cpus = parse_cpu_list(args.cpus)
    except Exception as exc:
        raise SystemExit(f'ERROR: invalid --cpus: {exc}')

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    wanted = set(cpus)

    with args.output.open('w', newline='', encoding='utf-8') as f:
        w = csv.DictWriter(f, fieldnames=['monotonic_ns', 'cpu', 'busy_jiffies', 'total_jiffies'])
        w.writeheader()
        f.flush()
        next_t = time.monotonic()
        while not STOP:
            now_ns = time.monotonic_ns()
            rows = read_proc_stat(wanted)
            for cpu in cpus:
                if cpu not in rows:
                    continue
                busy, total = rows[cpu]
                w.writerow({'monotonic_ns': now_ns, 'cpu': cpu, 'busy_jiffies': busy, 'total_jiffies': total})
            f.flush()
            next_t += args.interval_ms / 1000.0
            delay = next_t - time.monotonic()
            if delay > 0:
                time.sleep(delay)
            else:
                next_t = time.monotonic()

    return 0


if __name__ == '__main__':
    raise SystemExit(main())
