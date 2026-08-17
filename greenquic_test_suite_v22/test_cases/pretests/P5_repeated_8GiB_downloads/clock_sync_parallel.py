#!/usr/bin/env python3
from __future__ import annotations

"""Multicore-only adapter for P5/P7 parallel clock synchronization.

The base Performance2 clock_sync.py intentionally remains unchanged. This
adapter reuses its sampling/mapping implementation but extends completion
recognition to the parallel-batch marker used by the multicore experiment.
"""

import importlib.util
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BASE = HERE / "clock_sync.py"
spec = importlib.util.spec_from_file_location("greenquic_p5_clock_sync_base", BASE)
if spec is None or spec.loader is None:
    raise SystemExit(f"ERROR: cannot import base clock sync: {BASE}")
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)

PARALLEL_FINAL_RE = re.compile(
    r"\[GreenQUIC-PARALLEL\]\s+batch=1\s+complete_us=\d+\s+duration_us=\d+\s+"
    r"connections=(\d+)\s+connected=(\d+)\s+completed=(\d+)\s+success=1\b"
)


def final_download_seen(text: str) -> bool:
    if base.final_download_seen(text):
        return True
    for match in PARALLEL_FINAL_RE.finditer(text):
        connections, connected, completed = map(int, match.groups())
        if connections > 0 and connected == connections and completed == connections:
            return True
    return False


def spawn_post_sync(host: str, start_out: Path, samples: int, timeout_s: float) -> None:
    """Spawn this adapter, not the base script, for the end-of-run drift probe."""
    log_path = base.client_log_for(start_out)
    if log_path is None:
        return
    end_out = base.end_output_for(start_out)
    command = [
        sys.executable,
        str(Path(__file__).resolve()),
        "--host", host,
        "--out", str(end_out),
        "--samples", str(samples),
        "--follow-log", str(log_path),
        "--follow-timeout-s", str(timeout_s),
    ]
    subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        close_fds=True,
    )


# base.follow_until_final resolves these names from the base module at runtime.
base.final_download_seen = final_download_seen
base.spawn_post_sync = spawn_post_sync


def self_test() -> int:
    base.self_test()
    assert final_download_seen(
        "[GreenQUIC-PARALLEL] batch=1 complete_us=123 duration_us=100 "
        "connections=4 connected=4 completed=4 success=1"
    )
    assert not final_download_seen(
        "[GreenQUIC-PARALLEL] batch=1 complete_us=123 duration_us=100 "
        "connections=4 connected=4 completed=3 success=1"
    )
    assert not final_download_seen(
        "[GreenQUIC-PARALLEL] batch=1 complete_us=123 duration_us=100 "
        "connections=4 connected=4 completed=4 success=0"
    )
    print("parallel clock_sync adapter self-test PASS")
    return 0


if __name__ == "__main__":
    if "--self-test" in sys.argv[1:]:
        raise SystemExit(self_test())
    raise SystemExit(base.main())
