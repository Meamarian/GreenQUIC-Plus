#!/usr/bin/env python3

# ============================================================
# Configuration
# ============================================================

DEFAULT_INTERVAL_MS = 6.0
DEFAULT_DURATION_S = 15.0

# Keep 1 for raw 5 ms values.
# Use 3 for a 15 ms moving average or 5 for a 25 ms moving average.
SMOOTH_SAMPLES = 3

PACKAGE_ENERGY_PATH = (
    "/sys/class/powercap/intel-rapl/"
    "intel-rapl:0/energy_uj"
)

PACKAGE_MAX_PATH = (
    "/sys/class/powercap/intel-rapl/"
    "intel-rapl:0/max_energy_range_uj"
)

DRAM_ENERGY_PATH = (
    "/sys/class/powercap/intel-rapl/"
    "intel-rapl:0/intel-rapl:0:0/energy_uj"
)

DRAM_MAX_PATH = (
    "/sys/class/powercap/intel-rapl/"
    "intel-rapl:0/intel-rapl:0:0/max_energy_range_uj"
)

# ============================================================

import argparse
import collections
import os
import sys
import time


def read_integer_file(path):
    with open(path, "r", encoding="utf-8") as handle:
        return int(handle.read().strip())


def read_energy(fd):
    os.lseek(fd, 0, os.SEEK_SET)
    value = os.read(fd, 64)

    if not value:
        raise RuntimeError("Empty RAPL energy-counter read")

    return int(value.strip())


def counter_delta(current, previous, maximum):
    if current >= previous:
        return current - previous

    # Energy counter wrapped around.
    return maximum - previous + current


def average(values):
    return sum(values) / len(values)


def main():
    parser = argparse.ArgumentParser(
        description=(
            "Display Intel RAPL package and DRAM power in watts."
        )
    )

    parser.add_argument(
        "interval_ms",
        nargs="?",
        type=float,
        default=DEFAULT_INTERVAL_MS,
        help=f"sampling interval in milliseconds "
             f"(default: {DEFAULT_INTERVAL_MS})",
    )

    parser.add_argument(
        "duration_s",
        nargs="?",
        type=float,
        default=DEFAULT_DURATION_S,
        help=f"measurement duration in seconds "
             f"(default: {DEFAULT_DURATION_S})",
    )

    args = parser.parse_args()

    if args.interval_ms <= 0:
        parser.error("interval_ms must be greater than zero")

    if args.duration_s <= 0:
        parser.error("duration_s must be greater than zero")

    required_paths = [
        PACKAGE_ENERGY_PATH,
        PACKAGE_MAX_PATH,
        DRAM_ENERGY_PATH,
        DRAM_MAX_PATH,
    ]

    missing = [path for path in required_paths if not os.path.isfile(path)]

    if missing:
        print("ERROR: required RAPL files are unavailable:", file=sys.stderr)

        for path in missing:
            print(f"  {path}", file=sys.stderr)

        return 1

    package_fd = os.open(PACKAGE_ENERGY_PATH, os.O_RDONLY)
    dram_fd = os.open(DRAM_ENERGY_PATH, os.O_RDONLY)

    package_max = read_integer_file(PACKAGE_MAX_PATH)
    dram_max = read_integer_file(DRAM_MAX_PATH)

    package_history = collections.deque(
        maxlen=max(1, SMOOTH_SAMPLES)
    )
    dram_history = collections.deque(
        maxlen=max(1, SMOOTH_SAMPLES)
    )

    previous_package = read_energy(package_fd)
    previous_dram = read_energy(dram_fd)

    start_ns = time.monotonic_ns()
    previous_ns = start_ns

    interval_ns = int(args.interval_ms * 1_000_000)
    duration_ns = int(args.duration_s * 1_000_000_000)
    next_sample_ns = start_ns + interval_ns

    package_watt_sum = 0.0
    dram_watt_sum = 0.0
    measured_time_s = 0.0
    samples = 0

    print(
        f"Requested interval: {args.interval_ms:.3f} ms\n"
        f"Duration: {args.duration_s:.3f} s\n"
        f"Smoothing: {SMOOTH_SAMPLES} sample(s)\n"
    )

    print(
        f"{'time_ms':>12} "
        f"{'actual_ms':>12} "
        f"{'package_W':>12} "
        f"{'dram_W':>12} "
        f"{'total_W':>12}"
    )

    try:
        while True:
            now_ns = time.monotonic_ns()

            if now_ns - start_ns >= duration_ns:
                break

            remaining_ns = next_sample_ns - now_ns

            if remaining_ns > 0:
                time.sleep(remaining_ns / 1_000_000_000)

            package_value = read_energy(package_fd)
            dram_value = read_energy(dram_fd)
            sample_ns = time.monotonic_ns()

            elapsed_ns = sample_ns - previous_ns

            if elapsed_ns <= 0:
                next_sample_ns += interval_ns
                continue

            elapsed_s = elapsed_ns / 1_000_000_000

            package_delta_uj = counter_delta(
                package_value,
                previous_package,
                package_max,
            )

            dram_delta_uj = counter_delta(
                dram_value,
                previous_dram,
                dram_max,
            )

            package_w = (
                package_delta_uj / 1_000_000
            ) / elapsed_s

            dram_w = (
                dram_delta_uj / 1_000_000
            ) / elapsed_s

            package_history.append(package_w)
            dram_history.append(dram_w)

            displayed_package_w = average(package_history)
            displayed_dram_w = average(dram_history)
            displayed_total_w = (
                displayed_package_w + displayed_dram_w
            )

            print(
                f"{(sample_ns - start_ns) / 1_000_000:12.3f} "
                f"{elapsed_ns / 1_000_000:12.3f} "
                f"{displayed_package_w:12.3f} "
                f"{displayed_dram_w:12.3f} "
                f"{displayed_total_w:12.3f}",
                flush=True,
            )

            package_watt_sum += package_w * elapsed_s
            dram_watt_sum += dram_w * elapsed_s
            measured_time_s += elapsed_s
            samples += 1

            previous_package = package_value
            previous_dram = dram_value
            previous_ns = sample_ns

            # Absolute deadline prevents accumulated sleep drift.
            next_sample_ns += interval_ns

            if sample_ns > next_sample_ns:
                missed = (
                    sample_ns - next_sample_ns
                ) // interval_ns + 1

                next_sample_ns += missed * interval_ns

    except KeyboardInterrupt:
        print("\nMeasurement stopped by user.")

    finally:
        os.close(package_fd)
        os.close(dram_fd)

    if samples and measured_time_s > 0:
        average_package_w = package_watt_sum / measured_time_s
        average_dram_w = dram_watt_sum / measured_time_s

        print("\nSummary")
        print("-------")
        print(f"Samples: {samples}")
        print(f"Measured duration: {measured_time_s:.6f} s")
        print(f"Average package power: {average_package_w:.3f} W")
        print(f"Average DRAM power: {average_dram_w:.3f} W")
        print(
            f"Average package + DRAM power: "
            f"{average_package_w + average_dram_w:.3f} W"
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
