#!/usr/bin/env python3
from __future__ import annotations

import safe_cleanup_greenquic_processes as base

base.CMD_SUBSTRINGS = tuple(base.CMD_SUBSTRINGS) + (
    '/P5_repeated_8GiB_downloads/run_p5_parallel_off_case.sh',
    '/P5_repeated_8GiB_downloads/run_p5_bottleneck_case_diag.sh',
    '/P5_repeated_8GiB_downloads/run_p5_bottleneck_sweep.sh',
    '/P5_repeated_8GiB_downloads/run_p5_bottleneck_sweep_v2.sh',
    '/tmp/P5_BOTTLENECK_SWEEP_',
    '/tmp/P5_BOTTLENECK_',
    'cpu_busy_sampler.py',
)

if __name__ == '__main__':
    raise SystemExit(base.main())
