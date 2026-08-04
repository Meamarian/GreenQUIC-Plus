#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import time
from pathlib import Path

PACKAGE = Path("/sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj")
DRAM = Path("/sys/class/powercap/intel-rapl/intel-rapl:0/intel-rapl:0:0/energy_uj")
PACKAGE_MAX = PACKAGE.with_name("max_energy_range_uj")
DRAM_MAX = DRAM.with_name("max_energy_range_uj")


def read_int(path: Path) -> int:
    return int(path.read_text(encoding="utf-8").strip())


def delta(before: int, after: int, maximum: int) -> int:
    value = after - before
    if value < 0:
        value += maximum
    return value


def main() -> int:
    print("RAPL source check")
    print("  package:", PACKAGE)
    print("  dram:   ", DRAM)
    if not PACKAGE.is_file() or not DRAM.is_file():
        print("  result: required package/DRAM counters are missing")
        return 2

    package_before = read_int(PACKAGE)
    dram_before = read_int(DRAM)
    start_ns = time.monotonic_ns()
    time.sleep(0.25)
    package_after = read_int(PACKAGE)
    dram_after = read_int(DRAM)
    end_ns = time.monotonic_ns()
    elapsed_s = (end_ns - start_ns) / 1_000_000_000.0
    package_w = delta(package_before, package_after, read_int(PACKAGE_MAX)) / 1_000_000.0 / elapsed_s
    dram_w = delta(dram_before, dram_after, read_int(DRAM_MAX)) / 1_000_000.0 / elapsed_s
    print(f"  {elapsed_s:.6f}s direct sample: package={package_w:.3f} W dram={dram_w:.3f} W total={package_w + dram_w:.3f} W")
    print("  formula: watts = delta energy_uj / 1e6 / actual monotonic seconds")

    module_path = Path(__file__).with_name("power_trace.py")
    try:
        spec = importlib.util.spec_from_file_location("gq_power_trace", module_path)
        if spec is None or spec.loader is None:
            raise RuntimeError("cannot load power_trace.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        board_w, source, detail = module.read_power("power1", "last")
        print(f"  power1 instantaneous: {board_w:.3f} W source={source}")
        print(f"  power1 exact source: {detail}")
        print(f"  instantaneous RAPL/power1 ratio: {(package_w + dram_w) / board_w:.3f}" if board_w else "  instantaneous ratio unavailable")
        print("  note: scopes differ; power1 normally includes more of the system than package+DRAM RAPL")
    except Exception as error:
        print("  power1 comparison unavailable:", error)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
