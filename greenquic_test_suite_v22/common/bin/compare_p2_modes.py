#!/usr/bin/env python3
"""Compare the latest bundled P2 client OFF and BASIC results."""
from __future__ import annotations

import argparse
import json
from pathlib import Path


def latest_run(result_root: Path, mode: str) -> Path:
    rows = [
        path
        for path in result_root.glob(
            f"*__P2_goodput_basic_10GiB__client__{mode}*"
        )
        if path.is_dir() and (path / "details").is_dir()
    ]
    if not rows:
        raise SystemExit(
            f"ERROR: no bundled P2 client result found for mode={mode}"
        )
    return max(rows, key=lambda path: path.stat().st_mtime_ns)


def load_goodput(run_dir: Path) -> tuple[float, float, Path]:
    rows = list((run_dir / "details").glob("*_goodput.json"))
    if len(rows) != 1:
        raise SystemExit(
            f"ERROR: expected one goodput JSON in {run_dir / 'details'}"
        )
    path = rows[0]
    data = json.loads(path.read_text(encoding="utf-8"))
    primary = data.get("primary", data)
    return (
        float(primary.get("goodput_gbps_decimal", 0.0)),
        float(primary.get("duration_s", primary.get("elapsed_s", 0.0))),
        path,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--test-dir",
        type=Path,
        default=Path(
            "/root/mohsen/greenquic_test_suite_v22/"
            "test_cases/pretests/P2_goodput_basic_10GiB"
        ),
    )
    args = parser.parse_args()

    result_root = args.test_dir.resolve() / "results"
    off_run = latest_run(result_root, "off")
    basic_run = latest_run(result_root, "basic")
    off_gbps, off_s, off_json = load_goodput(off_run)
    basic_gbps, basic_s, basic_json = load_goodput(basic_run)

    speed_delta = (
        (basic_gbps - off_gbps) / off_gbps * 100.0
        if off_gbps > 0.0
        else float("nan")
    )
    time_delta = (
        (basic_s - off_s) / off_s * 100.0
        if off_s > 0.0
        else float("nan")
    )

    print("\n=== P2 OFF vs BASIC client comparison ===")
    print(f"OFF:   {off_gbps:.6f} Gbit/s | {off_s:.6f} s")
    print(f"BASIC: {basic_gbps:.6f} Gbit/s | {basic_s:.6f} s")
    print(f"BASIC goodput relative to OFF: {speed_delta:+.2f}%")
    print(f"BASIC duration relative to OFF: {time_delta:+.2f}%")
    print(f"OFF run:   {off_run}")
    print(f"BASIC run: {basic_run}")
    print(f"OFF goodput JSON:   {off_json}")
    print(f"BASIC goodput JSON: {basic_json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
