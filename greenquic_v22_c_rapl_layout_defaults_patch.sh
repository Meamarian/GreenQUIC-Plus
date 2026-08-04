#!/usr/bin/env bash
set -Eeuo pipefail

# GreenQUIC V22 C RAPL/MSR sampler and clean result-layout patch.
#
# This patch adds a compiled C sampler that runs beside each GreenQUIC client
# and server process. It reads Linux Intel RAPL powercap energy counters at a
# configurable interval, derives package/DRAM watts, and records raw plus
# moving-average values.
#
# Defaults:
#   GQ_ENABLE_MSR_TRACE=1
#   GQ_REQUIRE_MSR_TRACE=0
#   GQ_MSR_SAMPLE_INTERVAL_MS=6
#   GQ_MSR_SMOOTH_SAMPLES=3
#
# Suite-wide defaults (still overridable per command):
#   GQ_MODE_OVERRIDE=basic
#   WORK_WAIT_MIN_LEVEL=1
#   GQ_IDLE_MODE_OVERRIDE=epoll
#   GQ_LOG_LEVEL=1
#   GQ_STATS_PERIOD_US=1000000
#   GQ_PLOT_X_TICK_MS=1000
#   GQ_PLOT_X_LABEL_MS=1000
#   GQ_POWER_SAMPLE_INTERVAL_MS=1000
#
# New bundle layout:
#   <run-folder>/*.svg         visual results only
#   <run-folder>/details/*     logs, CSV, JSON, summary and configurations

SUITE="${1:-/root/mohsen/greenquic_test_suite_v22}"
COMMON="$SUITE/common/bin"
GQ_COMMON="$COMMON/gq_common.sh"
BUILD_HELPERS="$COMMON/build_helpers.sh"
SAMPLER_C="$COMMON/rapl_msr_sampler.c"
SAMPLER_BIN="$COMMON/gq_rapl_msr_sampler"
MSR_TRACE="$COMMON/rapl_msr_trace.py"
BUNDLER="$COMMON/bundle_run_results.py"
SUMMARY="$COMMON/write_run_summary.py"
PLOT_UTILS="$COMMON/gq_plot.py"
MARKER='GREENQUIC-V22-C-RAPL-MSR-RESULT-LAYOUT-DEFAULTS-V2'

for required in "$GQ_COMMON" "$BUILD_HELPERS" "$BUNDLER" "$SUMMARY" "$PLOT_UTILS"; do
    [[ -f "$required" ]] || {
        echo "ERROR: required file is missing: $required" >&2
        exit 1
    }
done

for proc in quicinterop quicinteropserver; do
    if pgrep -x "$proc" >/dev/null 2>&1; then
        echo "ERROR: $proc is running. Stop the client/server before patching." >&2
        pgrep -ax "$proc" >&2 || true
        exit 1
    fi
done

if ! grep -Fq 'GREENQUIC-V22-RESULTS-FREQ-TIMESERIES-FIX-V2' "$GQ_COMMON"; then
    echo "ERROR: install greenquic_v22_results_freq_timeseries_fix.sh first." >&2
    exit 1
fi

if grep -Fq "$MARKER" "$GQ_COMMON"; then
    echo "The C RAPL/MSR and clean result-layout patch is already installed."
    exit 0
fi

stamp="$(date +%Y%m%d_%H%M%S)"
for file in "$GQ_COMMON" "$BUILD_HELPERS" "$BUNDLER" "$SUMMARY"; do
    cp -a "$file" "$file.before_c_rapl_layout_${stamp}"
done
for file in "$SAMPLER_C" "$SAMPLER_BIN" "$MSR_TRACE"; do
    [[ -e "$file" ]] && cp -a "$file" "$file.before_c_rapl_layout_${stamp}"
done

echo "Backups created with suffix .before_c_rapl_layout_${stamp}"

cat > "$SAMPLER_C" <<'C'
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define DEFAULT_INTERVAL_MS 6.0
#define DEFAULT_SMOOTH_SAMPLES 3U
#define DEFAULT_PACKAGE_ENERGY "/sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj"
#define DEFAULT_PACKAGE_MAX "/sys/class/powercap/intel-rapl/intel-rapl:0/max_energy_range_uj"
#define DEFAULT_DRAM_ENERGY "/sys/class/powercap/intel-rapl/intel-rapl:0/intel-rapl:0:0/energy_uj"
#define DEFAULT_DRAM_MAX "/sys/class/powercap/intel-rapl/intel-rapl:0/intel-rapl:0:0/max_energy_range_uj"

static volatile sig_atomic_t StopRequested = 0;

static void
OnSignal(int Signal)
{
    (void)Signal;
    StopRequested = 1;
}

static void
Usage(const char* Program)
{
    fprintf(stderr,
        "Usage: %s --output FILE [--interval-ms N] [--smooth-samples N] "
        "[--duration-s N]\n", Program);
}

static bool
ParseDouble(const char* Text, double* Value)
{
    char* End = NULL;
    errno = 0;
    double Parsed = strtod(Text, &End);
    if (errno != 0 || End == Text || *End != '\0') {
        return false;
    }
    *Value = Parsed;
    return true;
}

static bool
ParseUnsigned(const char* Text, unsigned* Value)
{
    char* End = NULL;
    errno = 0;
    unsigned long Parsed = strtoul(Text, &End, 10);
    if (errno != 0 || End == Text || *End != '\0' || Parsed > 1000000UL) {
        return false;
    }
    *Value = (unsigned)Parsed;
    return true;
}

static bool
ReadCounterFd(int Fd, uint64_t* Value)
{
    char Buffer[64];
    if (lseek(Fd, 0, SEEK_SET) < 0) {
        return false;
    }
    ssize_t Length = read(Fd, Buffer, sizeof(Buffer) - 1U);
    if (Length <= 0) {
        return false;
    }
    Buffer[Length] = '\0';
    char* End = NULL;
    errno = 0;
    unsigned long long Parsed = strtoull(Buffer, &End, 10);
    if (errno != 0 || End == Buffer) {
        return false;
    }
    *Value = (uint64_t)Parsed;
    return true;
}

static bool
ReadCounterPath(const char* Path, uint64_t* Value)
{
    int Fd = open(Path, O_RDONLY | O_CLOEXEC);
    if (Fd < 0) {
        return false;
    }
    bool Result = ReadCounterFd(Fd, Value);
    close(Fd);
    return Result;
}

static uint64_t
CounterDelta(uint64_t Current, uint64_t Previous, uint64_t Maximum)
{
    return Current >= Previous ? Current - Previous : Maximum - Previous + Current;
}

static uint64_t
TimespecToNs(const struct timespec* Value)
{
    return (uint64_t)Value->tv_sec * 1000000000ULL + (uint64_t)Value->tv_nsec;
}

static struct timespec
NsToTimespec(uint64_t Value)
{
    struct timespec Result;
    Result.tv_sec = (time_t)(Value / 1000000000ULL);
    Result.tv_nsec = (long)(Value % 1000000000ULL);
    return Result;
}

static int
SleepUntil(uint64_t DeadlineNs)
{
    struct timespec Deadline = NsToTimespec(DeadlineNs);
    while (!StopRequested) {
        int Result = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &Deadline, NULL);
        if (Result == 0) {
            return 0;
        }
        if (Result != EINTR) {
            errno = Result;
            return -1;
        }
    }
    return 0;
}

int
main(int Argc, char** Argv)
{
    const char* OutputPath = NULL;
    const char* PackageEnergyPath = DEFAULT_PACKAGE_ENERGY;
    const char* PackageMaxPath = DEFAULT_PACKAGE_MAX;
    const char* DramEnergyPath = DEFAULT_DRAM_ENERGY;
    const char* DramMaxPath = DEFAULT_DRAM_MAX;
    double IntervalMs = DEFAULT_INTERVAL_MS;
    double DurationS = 0.0;
    unsigned SmoothSamples = DEFAULT_SMOOTH_SAMPLES;

    for (int Index = 1; Index < Argc; ++Index) {
        if (strcmp(Argv[Index], "--output") == 0 && Index + 1 < Argc) {
            OutputPath = Argv[++Index];
        } else if (strcmp(Argv[Index], "--interval-ms") == 0 && Index + 1 < Argc) {
            if (!ParseDouble(Argv[++Index], &IntervalMs)) {
                fprintf(stderr, "ERROR: invalid --interval-ms value\n");
                return 2;
            }
        } else if (strcmp(Argv[Index], "--smooth-samples") == 0 && Index + 1 < Argc) {
            if (!ParseUnsigned(Argv[++Index], &SmoothSamples)) {
                fprintf(stderr, "ERROR: invalid --smooth-samples value\n");
                return 2;
            }
        } else if (strcmp(Argv[Index], "--duration-s") == 0 && Index + 1 < Argc) {
            if (!ParseDouble(Argv[++Index], &DurationS)) {
                fprintf(stderr, "ERROR: invalid --duration-s value\n");
                return 2;
            }
        } else if (strcmp(Argv[Index], "--package-energy-path") == 0 && Index + 1 < Argc) {
            PackageEnergyPath = Argv[++Index];
        } else if (strcmp(Argv[Index], "--package-max-path") == 0 && Index + 1 < Argc) {
            PackageMaxPath = Argv[++Index];
        } else if (strcmp(Argv[Index], "--dram-energy-path") == 0 && Index + 1 < Argc) {
            DramEnergyPath = Argv[++Index];
        } else if (strcmp(Argv[Index], "--dram-max-path") == 0 && Index + 1 < Argc) {
            DramMaxPath = Argv[++Index];
        } else if (strcmp(Argv[Index], "--help") == 0 || strcmp(Argv[Index], "-h") == 0) {
            Usage(Argv[0]);
            return 0;
        } else {
            Usage(Argv[0]);
            return 2;
        }
    }

    if (OutputPath == NULL || IntervalMs < 1.0 || IntervalMs > 60000.0 ||
        SmoothSamples < 1U || SmoothSamples > 10000U || DurationS < 0.0) {
        fprintf(stderr, "ERROR: invalid sampler configuration\n");
        Usage(Argv[0]);
        return 2;
    }

    uint64_t PackageMax = 0, DramMax = 0;
    if (!ReadCounterPath(PackageMaxPath, &PackageMax) ||
        !ReadCounterPath(DramMaxPath, &DramMax) || PackageMax == 0 || DramMax == 0) {
        fprintf(stderr, "ERROR: RAPL maximum-energy ranges are unavailable\n");
        return 3;
    }

    int PackageFd = open(PackageEnergyPath, O_RDONLY | O_CLOEXEC);
    int DramFd = open(DramEnergyPath, O_RDONLY | O_CLOEXEC);
    if (PackageFd < 0 || DramFd < 0) {
        fprintf(stderr, "ERROR: RAPL package or DRAM energy counter is unavailable: %s\n", strerror(errno));
        if (PackageFd >= 0) close(PackageFd);
        if (DramFd >= 0) close(DramFd);
        return 3;
    }

    FILE* Output = fopen(OutputPath, "w");
    if (Output == NULL) {
        fprintf(stderr, "ERROR: cannot create %s: %s\n", OutputPath, strerror(errno));
        close(PackageFd);
        close(DramFd);
        return 4;
    }
    setvbuf(Output, NULL, _IOFBF, 1024U * 1024U);

    double* PackageHistory = calloc(SmoothSamples, sizeof(double));
    double* DramHistory = calloc(SmoothSamples, sizeof(double));
    if (PackageHistory == NULL || DramHistory == NULL) {
        fprintf(stderr, "ERROR: cannot allocate smoothing history\n");
        free(PackageHistory);
        free(DramHistory);
        fclose(Output);
        close(PackageFd);
        close(DramFd);
        return 5;
    }

    signal(SIGINT, OnSignal);
    signal(SIGTERM, OnSignal);

    uint64_t PreviousPackage = 0, PreviousDram = 0;
    if (!ReadCounterFd(PackageFd, &PreviousPackage) || !ReadCounterFd(DramFd, &PreviousDram)) {
        fprintf(stderr, "ERROR: initial RAPL counter read failed\n");
        free(PackageHistory);
        free(DramHistory);
        fclose(Output);
        close(PackageFd);
        close(DramFd);
        return 6;
    }

    struct timespec StartTime;
    if (clock_gettime(CLOCK_MONOTONIC, &StartTime) != 0) {
        fprintf(stderr, "ERROR: clock_gettime failed: %s\n", strerror(errno));
        return 6;
    }
    uint64_t StartNs = TimespecToNs(&StartTime);
    uint64_t PreviousNs = StartNs;
    uint64_t IntervalNs = (uint64_t)(IntervalMs * 1000000.0 + 0.5);
    uint64_t DurationNs = DurationS > 0.0 ? (uint64_t)(DurationS * 1000000000.0 + 0.5) : 0ULL;
    uint64_t NextNs = StartNs + IntervalNs;

    fprintf(Output, "# schema=greenquic-rapl-msr-c-v1\n");
    fprintf(Output, "# requested_interval_ms=%.6f\n", IntervalMs);
    fprintf(Output, "# smoothing_samples=%u\n", SmoothSamples);
    fprintf(Output, "# package_energy_path=%s\n", PackageEnergyPath);
    fprintf(Output, "# dram_energy_path=%s\n", DramEnergyPath);
    fprintf(Output,
        "elapsed_ms,actual_interval_ms,package_energy_uj,dram_energy_uj,"
        "package_delta_j,dram_delta_j,package_power_w,dram_power_w,total_power_w,"
        "package_power_smoothed_w,dram_power_smoothed_w,total_power_smoothed_w\n");

    uint64_t Samples = 0;
    unsigned HistoryCount = 0;
    unsigned HistoryIndex = 0;
    double PackageHistorySum = 0.0;
    double DramHistorySum = 0.0;
    double PackageEnergyTotal = 0.0;
    double DramEnergyTotal = 0.0;

    while (!StopRequested) {
        struct timespec NowTime;
        if (clock_gettime(CLOCK_MONOTONIC, &NowTime) != 0) {
            break;
        }
        uint64_t NowNs = TimespecToNs(&NowTime);
        if (DurationNs != 0ULL && NowNs - StartNs >= DurationNs) {
            break;
        }
        if (SleepUntil(NextNs) != 0 || StopRequested) {
            break;
        }

        uint64_t PackageValue = 0, DramValue = 0;
        if (!ReadCounterFd(PackageFd, &PackageValue) || !ReadCounterFd(DramFd, &DramValue)) {
            fprintf(stderr, "ERROR: RAPL counter read failed after %" PRIu64 " samples\n", Samples);
            break;
        }
        if (clock_gettime(CLOCK_MONOTONIC, &NowTime) != 0) {
            break;
        }
        uint64_t SampleNs = TimespecToNs(&NowTime);
        uint64_t DeltaNs = SampleNs - PreviousNs;
        if (DeltaNs == 0ULL) {
            NextNs += IntervalNs;
            continue;
        }

        uint64_t PackageDeltaUj = CounterDelta(PackageValue, PreviousPackage, PackageMax);
        uint64_t DramDeltaUj = CounterDelta(DramValue, PreviousDram, DramMax);
        double DeltaS = (double)DeltaNs / 1000000000.0;
        double PackageDeltaJ = (double)PackageDeltaUj / 1000000.0;
        double DramDeltaJ = (double)DramDeltaUj / 1000000.0;
        double PackageW = PackageDeltaJ / DeltaS;
        double DramW = DramDeltaJ / DeltaS;

        if (HistoryCount == SmoothSamples) {
            PackageHistorySum -= PackageHistory[HistoryIndex];
            DramHistorySum -= DramHistory[HistoryIndex];
        } else {
            ++HistoryCount;
        }
        PackageHistory[HistoryIndex] = PackageW;
        DramHistory[HistoryIndex] = DramW;
        PackageHistorySum += PackageW;
        DramHistorySum += DramW;
        HistoryIndex = (HistoryIndex + 1U) % SmoothSamples;

        double PackageSmoothW = PackageHistorySum / (double)HistoryCount;
        double DramSmoothW = DramHistorySum / (double)HistoryCount;

        fprintf(Output,
            "%.6f,%.6f,%" PRIu64 ",%" PRIu64 ",%.9f,%.9f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f\n",
            (double)(SampleNs - StartNs) / 1000000.0,
            (double)DeltaNs / 1000000.0,
            PackageValue,
            DramValue,
            PackageDeltaJ,
            DramDeltaJ,
            PackageW,
            DramW,
            PackageW + DramW,
            PackageSmoothW,
            DramSmoothW,
            PackageSmoothW + DramSmoothW);

        PackageEnergyTotal += PackageDeltaJ;
        DramEnergyTotal += DramDeltaJ;
        ++Samples;
        if ((Samples % 128ULL) == 0ULL) {
            fflush(Output);
        }

        PreviousPackage = PackageValue;
        PreviousDram = DramValue;
        PreviousNs = SampleNs;
        NextNs += IntervalNs;
        if (SampleNs > NextNs) {
            uint64_t Missed = (SampleNs - NextNs) / IntervalNs + 1ULL;
            NextNs += Missed * IntervalNs;
        }
    }

    struct timespec EndTime;
    clock_gettime(CLOCK_MONOTONIC, &EndTime);
    double MeasuredS = (double)(TimespecToNs(&EndTime) - StartNs) / 1000000000.0;
    fflush(Output);
    fclose(Output);
    close(PackageFd);
    close(DramFd);
    free(PackageHistory);
    free(DramHistory);

    fprintf(stdout, "GreenQUIC C RAPL/MSR sampler finished\n");
    fprintf(stdout, "requested_interval_ms=%.6f\n", IntervalMs);
    fprintf(stdout, "smoothing_samples=%u\n", SmoothSamples);
    fprintf(stdout, "samples=%" PRIu64 "\n", Samples);
    fprintf(stdout, "measured_duration_s=%.6f\n", MeasuredS);
    fprintf(stdout, "package_energy_j=%.6f\n", PackageEnergyTotal);
    fprintf(stdout, "dram_energy_j=%.6f\n", DramEnergyTotal);
    if (MeasuredS > 0.0) {
        fprintf(stdout, "average_package_w=%.6f\n", PackageEnergyTotal / MeasuredS);
        fprintf(stdout, "average_dram_w=%.6f\n", DramEnergyTotal / MeasuredS);
        fprintf(stdout, "average_total_w=%.6f\n", (PackageEnergyTotal + DramEnergyTotal) / MeasuredS);
    }
    return Samples == 0ULL ? 7 : 0;
}
C

cat > "$BUILD_HELPERS" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
CC_BIN="${CC:-cc}"
command -v "$CC_BIN" >/dev/null 2>&1 || {
    echo "ERROR: C compiler not found. Set CC or install cc/gcc/clang." >&2
    exit 1
}

"$CC_BIN" -std=c11 -O2 -Wall -Wextra -Werror \
    "$HERE/gap_wait.c" -o "$HERE/gap_wait"
chmod +x "$HERE/gap_wait"
echo "Built $HERE/gap_wait"

"$CC_BIN" -std=c11 -O2 -Wall -Wextra -Werror \
    "$HERE/rapl_msr_sampler.c" -o "$HERE/gq_rapl_msr_sampler"
chmod +x "$HERE/gq_rapl_msr_sampler"
echo "Built $HERE/gq_rapl_msr_sampler"
SH
chmod +x "$BUILD_HELPERS"

cat > "$MSR_TRACE" <<'PY'
#!/usr/bin/env python3
"""Summarize and plot the GreenQUIC C RAPL/MSR sample stream."""
from __future__ import annotations

import argparse
import csv
import html
import json
import math
import os
import statistics
from pathlib import Path
from typing import Any

from gq_plot import write_line_svg


def percentile(values: list[float], q: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * q
    low = math.floor(position)
    high = math.ceil(position)
    if low == high:
        return ordered[low]
    fraction = position - low
    return ordered[low] * (1.0 - fraction) + ordered[high] * fraction


def env_int(name: str, default: int, minimum: int, maximum: int) -> int:
    raw = os.environ.get(name)
    if not raw:
        return default
    value = int(raw)
    if not minimum <= value <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return value


def read_csv(path: Path) -> tuple[dict[str, str], list[dict[str, float]]]:
    metadata: dict[str, str] = {}
    data_lines: list[str] = []
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if raw.startswith("# ") and "=" in raw:
            key, value = raw[2:].split("=", 1)
            metadata[key.strip()] = value.strip()
        elif raw and not raw.startswith("#"):
            data_lines.append(raw)
    if not data_lines:
        return metadata, []
    rows: list[dict[str, float]] = []
    for row in csv.DictReader(data_lines):
        try:
            rows.append({key: float(value) for key, value in row.items() if key is not None and value is not None})
        except ValueError:
            continue
    return metadata, rows


def histogram_svg(path: Path, values: list[float], role: str) -> None:
    width = env_int("GQ_MSR_HISTOGRAM_WIDTH_PX", 1800, 800, 20000)
    height = env_int("GQ_MSR_HISTOGRAM_HEIGHT_PX", 700, 400, 5000)
    bins = env_int("GQ_MSR_HISTOGRAM_BINS", 60, 5, 500)
    left, right, top, bottom = 110, 50, 70, 95
    plot_w, plot_h = width - left - right, height - top - bottom
    if not values:
        path.write_text(
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}">'
            '<text x="40" y="60" font-family="sans-serif">No RAPL/MSR samples available.</text></svg>\n',
            encoding="utf-8",
        )
        return
    low, high = min(values), max(values)
    if high <= low:
        high = low + 1.0
    counts = [0] * bins
    for value in values:
        index = min(bins - 1, int((value - low) / (high - low) * bins))
        counts[index] += 1
    max_count = max(counts) or 1
    bar_w = plot_w / bins
    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        '<rect width="100%" height="100%" fill="white"/>',
        f'<text x="{width/2:.1f}" y="34" text-anchor="middle" font-family="sans-serif" font-size="24">GreenQUIC {html.escape(role)} RAPL/MSR total-power distribution</text>',
    ]
    for index, count in enumerate(counts):
        x = left + index * bar_w
        h = count / max_count * plot_h
        out.append(f'<rect x="{x:.2f}" y="{top + plot_h - h:.2f}" width="{max(1.0, bar_w - 1.0):.2f}" height="{h:.2f}" fill="#1f77b4"/>')
    out.extend([
        f'<line x1="{left}" y1="{top}" x2="{left}" y2="{top+plot_h}" stroke="black" stroke-width="2"/>',
        f'<line x1="{left}" y1="{top+plot_h}" x2="{left+plot_w}" y2="{top+plot_h}" stroke="black" stroke-width="2"/>',
        f'<text x="{left}" y="{top+plot_h+32}" text-anchor="middle" font-family="monospace" font-size="14">{low:.2f}</text>',
        f'<text x="{left+plot_w}" y="{top+plot_h+32}" text-anchor="middle" font-family="monospace" font-size="14">{high:.2f}</text>',
        f'<text x="{width/2:.1f}" y="{height-24}" text-anchor="middle" font-family="sans-serif" font-size="17">Smoothed package + DRAM power [W]</text>',
        f'<text x="28" y="{height/2:.1f}" text-anchor="middle" font-family="sans-serif" font-size="17" transform="rotate(-90 28 {height/2:.1f})">Sample count</text>',
        '</svg>',
    ])
    path.write_text("\n".join(out) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", type=Path, required=True)
    parser.add_argument("--json", type=Path, required=True)
    parser.add_argument("--timeseries-svg", type=Path, required=True)
    parser.add_argument("--histogram-svg", type=Path, required=True)
    parser.add_argument("--energy-timeseries-svg", type=Path, required=True)
    parser.add_argument("--role", choices=("server", "client"), required=True)
    args = parser.parse_args()

    metadata, rows = read_csv(args.csv)
    if not rows:
        raise SystemExit(f"ERROR: no valid RAPL/MSR samples in {args.csv}")

    elapsed_ms = [row["elapsed_ms"] for row in rows]
    intervals = [row["actual_interval_ms"] for row in rows]
    package_smooth = [row["package_power_smoothed_w"] for row in rows]
    dram_smooth = [row["dram_power_smoothed_w"] for row in rows]
    total_smooth = [row["total_power_smoothed_w"] for row in rows]
    package_energy = sum(row["package_delta_j"] for row in rows)
    dram_energy = sum(row["dram_delta_j"] for row in rows)
    duration_s = elapsed_ms[-1] / 1000.0

    args.timeseries_svg.parent.mkdir(parents=True, exist_ok=True)
    plot = write_line_svg(
        args.timeseries_svg,
        kind="msr",
        title=f"GreenQUIC {args.role} RAPL/MSR package and DRAM power",
        y_label="Power [W]",
        series=[
            {"label": "Package", "points": list(zip(elapsed_ms, package_smooth))},
            {"label": "DRAM", "points": list(zip(elapsed_ms, dram_smooth))},
            {"label": "Package + DRAM", "points": list(zip(elapsed_ms, total_smooth))},
        ],
        duration_ms=elapsed_ms[-1],
        step=False,
        y_value_format=".2f",
    )
    histogram_svg(args.histogram_svg, total_smooth, args.role)

    cumulative_package: list[float] = []
    cumulative_dram: list[float] = []
    cumulative_total: list[float] = []
    package_running = 0.0
    dram_running = 0.0
    for row in rows:
        package_running += row["package_delta_j"]
        dram_running += row["dram_delta_j"]
        cumulative_package.append(package_running)
        cumulative_dram.append(dram_running)
        cumulative_total.append(package_running + dram_running)

    energy_plot = write_line_svg(
        args.energy_timeseries_svg,
        kind="msr",
        title=f"GreenQUIC {args.role} RAPL/MSR cumulative energy",
        y_label="Energy [J]",
        series=[
            {"label": "Package", "points": list(zip(elapsed_ms, cumulative_package))},
            {"label": "DRAM", "points": list(zip(elapsed_ms, cumulative_dram))},
            {"label": "Package + DRAM", "points": list(zip(elapsed_ms, cumulative_total))},
        ],
        duration_ms=elapsed_ms[-1],
        step=False,
        y_value_format=".3f",
    )

    requested_interval = float(metadata.get("requested_interval_ms", "nan"))
    smoothing_samples = int(float(metadata.get("smoothing_samples", "0")))
    result: dict[str, Any] = {
        "schema": "greenquic-rapl-msr-summary-v1",
        "source": "Linux Intel RAPL powercap counters sampled by compiled C helper",
        "role": args.role,
        "sample_count": len(rows),
        "duration_s": duration_s,
        "requested_interval_ms": requested_interval,
        "smoothing_samples": smoothing_samples,
        "nominal_smoothing_window_ms": requested_interval * smoothing_samples,
        "actual_interval_ms_min": min(intervals),
        "actual_interval_ms_median": statistics.median(intervals),
        "actual_interval_ms_p95": percentile(intervals, 0.95),
        "actual_interval_ms_max": max(intervals),
        "package_energy_j": package_energy,
        "dram_energy_j": dram_energy,
        "total_energy_j": package_energy + dram_energy,
        "average_package_power_w": package_energy / duration_s if duration_s > 0 else None,
        "average_dram_power_w": dram_energy / duration_s if duration_s > 0 else None,
        "average_total_power_w": (package_energy + dram_energy) / duration_s if duration_s > 0 else None,
        "smoothed_total_power_w_min": min(total_smooth),
        "smoothed_total_power_w_median": statistics.median(total_smooth),
        "smoothed_total_power_w_p95": percentile(total_smooth, 0.95),
        "smoothed_total_power_w_max": max(total_smooth),
        "power_plot": {
            "width_px": plot.width,
            "height_px": plot.height,
            "x_tick_ms": plot.tick_ms,
            "x_label_ms": plot.label_ms,
        },
        "energy_plot": {
            "width_px": energy_plot.width,
            "height_px": energy_plot.height,
            "x_tick_ms": energy_plot.tick_ms,
            "x_label_ms": energy_plot.label_ms,
        },
    }
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
chmod +x "$MSR_TRACE"

cat > "$BUNDLER" <<'PY'
#!/usr/bin/env python3
"""Collect one GreenQUIC run: SVGs at top level, all details below details/."""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
from pathlib import Path


def safe(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", value).strip("_")


def move(source: Path | None, target: Path) -> None:
    if source is None or not source.exists():
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        target.unlink()
    shutil.move(str(source), str(target))


def copy(source: Path | None, target: Path) -> None:
    if source is None or not source.exists():
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)


def latest(paths: list[Path]) -> Path | None:
    rows = [path for path in paths if path.exists()]
    return max(rows, key=lambda path: path.stat().st_mtime_ns) if rows else None


def environment_rows() -> list[str]:
    exact = {
        "WORK_WAIT_MIN_LEVEL", "WORK_WAIT_MIN_IDLE_US", "IDLE_WATCHDOG_US",
        "ENABLE_FREQ", "ENABLE_SLEEP", "ENABLE_CSTATE_IDLE", "ENABLE_MULTICORE",
        "RX_EMPTY_POLLS", "TX_EMPTY_POLLS", "PRESSURE_MAX", "PRESSURE_UP", "PRESSURE_KEEP",
        "FREQ_UP_PERIOD_US", "FREQ_DOWN_PERIOD_US", "FREQ_MIN_IDLE_US",
        "GQ_LOG_LEVEL", "GQ_STATS_PERIOD_US", "GQ_CLEANUP_DOWNLOADED_FILES",
        "GQ_POWER_SAMPLE_INTERVAL_MS", "GQ_POWER_SENSOR_MATCH", "GQ_POWER_SENSOR_OCCURRENCE",
        "GQ_ENABLE_MSR_TRACE", "GQ_REQUIRE_MSR_TRACE", "GQ_MSR_SAMPLE_INTERVAL_MS",
        "GQ_MSR_SMOOTH_SAMPLES", "GQ_MSR_PLOT_WIDTH_PX", "GQ_MSR_PLOT_HEIGHT_PX",
        "GQ_MSR_HISTOGRAM_WIDTH_PX", "GQ_MSR_HISTOGRAM_HEIGHT_PX", "GQ_MSR_HISTOGRAM_BINS",
        "GQ_PLOT_WIDTH_PX", "GQ_PLOT_HEIGHT_PX", "GQ_PLOT_X_TICK_MS",
        "GQ_PLOT_X_LABEL_MS", "GQ_PLOT_MIN_PX_PER_TICK", "GQ_PLOT_MAX_WIDTH_PX",
        "GQ_POWER_PLOT_WIDTH_PX", "GQ_POWER_PLOT_HEIGHT_PX",
        "GQ_FREQ_PLOT_WIDTH_PX", "GQ_FREQ_PLOT_HEIGHT_PX",
    }
    prefixes = ("GQ_", "GREENQUIC_", "SERVER_", "CLIENT_", "CASE_", "CSTATE_", "SLEEP_")
    return [
        f"{key}={value}" for key, value in sorted(os.environ.items())
        if key in exact or key.startswith(prefixes)
    ]


def determine_stamp(result_root: Path, role: str, mode: str, supplied: str | None) -> str:
    if supplied:
        return supplied
    candidates: list[Path] = []
    candidates.extend(result_root.glob(f"{role}_power_{mode}_*.json"))
    candidates.extend(result_root.glob(f"{role}_msr_{mode}_*.csv"))
    if role == "client":
        candidates.extend(result_root.glob(f"client_download_manifest_{mode}_*.json"))
    source = latest(candidates)
    if source is None:
        raise SystemExit("ERROR: cannot determine the run timestamp")
    prefixes = (
        f"{role}_power_{mode}_",
        f"{role}_msr_{mode}_",
        f"client_download_manifest_{mode}_",
    )
    for prefix in prefixes:
        if source.name.startswith(prefix):
            return source.name[len(prefix):].rsplit(".", 1)[0]
    raise SystemExit("ERROR: unsupported timestamp source")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--test-dir", type=Path, required=True)
    parser.add_argument("--role", choices=("server", "client"), required=True)
    parser.add_argument("--mode", required=True)
    parser.add_argument("--stamp")
    args = parser.parse_args()

    test_dir = args.test_dir.resolve()
    result_root = test_dir / "results"
    log_root = test_dir / "logs"
    runtime = test_dir / "runtime" / args.role
    stamp = determine_stamp(result_root, args.role, args.mode, args.stamp)
    test_name = test_dir.name
    run_name = safe(f"{stamp}__{test_name}__{args.role}__{args.mode}")
    run_dir = result_root / run_name
    retry = 1
    while run_dir.exists():
        run_dir = result_root / f"{run_name}__retry{retry}"
        retry += 1
    details = run_dir / "details"
    details.mkdir(parents=True)
    stem = run_dir.name

    move(log_root / f"{args.role}_{args.mode}_{stamp}.log", details / f"{stem}_log.txt")
    move(log_root / f"{args.role}_{args.mode}_{stamp}_timeline.jsonl", details / f"{stem}_timeline.jsonl")
    move(result_root / f"{args.role}_{args.mode}_{stamp}_v21_stats.csv", details / f"{stem}_stats.csv")

    power_prefix = result_root / f"{args.role}_power_{args.mode}_{stamp}"
    move(Path(str(power_prefix) + ".json"), details / f"{stem}_power.json")
    move(Path(str(power_prefix) + ".csv"), details / f"{stem}_power.csv")
    move(Path(str(power_prefix) + "_python_lists.txt"), details / f"{stem}_power_lists.txt")
    move(Path(str(power_prefix) + "_sampler.log"), details / f"{stem}_power_sampler.txt")
    move(Path(str(power_prefix) + "_timeseries.svg"), run_dir / f"{stem}_power_timeseries.svg")
    move(Path(str(power_prefix) + "_energy_timeseries.svg"), run_dir / f"{stem}_energy_timeseries.svg")
    move(Path(str(power_prefix) + "_histogram.svg"), run_dir / f"{stem}_power_histogram.svg")
    move(result_root / f"{args.role}_energy_{args.mode}_{stamp}.json", details / f"{stem}_energy_snapshot.json")

    msr_csv_source = result_root / f"{args.role}_msr_{args.mode}_{stamp}.csv"
    msr_log_source = result_root / f"{args.role}_msr_{args.mode}_{stamp}_sampler.log"
    msr_csv = details / f"{stem}_msr_power.csv"
    move(msr_csv_source, msr_csv)
    move(msr_log_source, details / f"{stem}_msr_sampler.txt")

    if args.role == "client":
        manifest = result_root / f"client_download_manifest_{args.mode}_{stamp}.json"
        if not manifest.exists():
            manifest = latest(list(result_root.glob(f"client_download_manifest_{args.mode}_*.json")))
        move(manifest, details / f"{stem}_download_manifest.json")
        goodput_rows = sorted(
            result_root.glob(f"*goodput*{args.mode}*.json"),
            key=lambda path: path.stat().st_mtime_ns,
            reverse=True,
        )
        if goodput_rows:
            move(goodput_rows[0], details / f"{stem}_goodput.json")

    copy(runtime / "dpdk.ini", details / f"{stem}_dpdk_config.txt")
    copy(runtime / "powermng.ini", details / f"{stem}_powermng_config.txt")
    copy(test_dir / "config.env", details / f"{stem}_test_config.txt")
    (details / f"{stem}_environment.txt").write_text(
        "\n".join(environment_rows()) + "\n", encoding="utf-8"
    )

    timeline = details / f"{stem}_timeline.jsonl"
    if timeline.is_file():
        frequency_prefix = details / f"{stem}_frequency"
        subprocess.run([
            "python3", str(Path(__file__).with_name("frequency_trace.py")),
            "--timeline", str(timeline),
            "--prefix", str(frequency_prefix),
            "--role", args.role,
        ], check=True)
        move(Path(str(frequency_prefix) + "_timeseries.svg"), run_dir / f"{stem}_frequency_timeseries.svg")

    msr_has_samples = False
    if msr_csv.is_file():
        data_rows = [
            raw for raw in msr_csv.read_text(encoding="utf-8", errors="replace").splitlines()
            if raw and not raw.startswith("#")
        ]
        msr_has_samples = len(data_rows) >= 2
    if msr_has_samples:
        subprocess.run([
            "python3", str(Path(__file__).with_name("rapl_msr_trace.py")),
            "--csv", str(msr_csv),
            "--json", str(details / f"{stem}_msr_power.json"),
            "--timeseries-svg", str(run_dir / f"{stem}_msr_power_timeseries.svg"),
            "--histogram-svg", str(run_dir / f"{stem}_msr_power_histogram.svg"),
            "--energy-timeseries-svg", str(run_dir / f"{stem}_msr_energy_timeseries.svg"),
            "--role", args.role,
        ], check=True)

    metadata = {
        "schema": "greenquic-run-bundle-v3",
        "test_id": os.environ.get("TEST_ID", test_name.split("_", 1)[0]),
        "test_name": test_name,
        "role": args.role,
        "mode": args.mode,
        "stamp": stamp,
        "stem": stem,
        "layout": {"visuals": ".", "details": "details/"},
    }
    (details / f"{stem}_metadata.json").write_text(
        json.dumps(metadata, indent=2) + "\n", encoding="utf-8"
    )
    subprocess.run([
        "python3", str(Path(__file__).with_name("write_run_summary.py")),
        "--run-dir", str(run_dir), "--role", args.role, "--mode", args.mode,
        "--test-id", metadata["test_id"], "--test-name", test_name,
        "--stamp", stamp, "--stem", stem,
    ], check=True)

    unexpected = [
        path.name for path in run_dir.iterdir()
        if path.name != "details" and (not path.is_file() or path.suffix.lower() != ".svg")
    ]
    if unexpected:
        raise SystemExit("ERROR: non-SVG objects remain at run-folder top level: " + ", ".join(unexpected))

    print(f"\n[GreenQUIC-Test] Run result folder created: {run_dir}")
    print(f"[GreenQUIC-Test] SVG visuals: {run_dir}")
    print(f"[GreenQUIC-Test] Logs/configuration/data: {details}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
chmod +x "$BUNDLER"

cat > "$SUMMARY" <<'PY'
#!/usr/bin/env python3
"""Write a readable GreenQUIC summary; keep terminal output concise."""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


def read_json(path: Path | None) -> dict[str, Any]:
    if path is None or not path.is_file():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def first(folder: Path, pattern: str) -> Path | None:
    rows = sorted(folder.glob(pattern))
    return rows[0] if rows else None


def fmt(value: Any, digits: int = 3) -> str:
    if value is None:
        return "unavailable"
    try:
        return f"{float(value):.{digits}f}"
    except Exception:
        return str(value)


def config_rows(path: Path | None) -> list[str]:
    if path is None or not path.is_file():
        return []
    return [
        raw.rstrip()
        for raw in path.read_text(encoding="utf-8", errors="replace").splitlines()
        if raw.strip() and not raw.lstrip().startswith("#")
    ]


def log_details(path: Path | None) -> dict[str, Any]:
    if path is None or not path.is_file():
        return {}
    text = path.read_text(encoding="utf-8", errors="replace")
    transmission = [int(value) for value in re.findall(
        r"(?mi)^\s*transmission time \[us\]:\s*(\d+)\s*$", text
    )]
    completions = [(name.strip(), int(ms)) for name, ms in re.findall(
        r"(?m)^\s*(.+?):\s*Completed download!\s*\((\d+)\s*ms\)\s*$", text
    )]
    return {
        "transmission_us": transmission[-1] if transmission else None,
        "completions": completions,
        "idle_modes": sorted(set(re.findall(r"\bidle_mode=([^\s]+)", text))),
        "epoll_try": max([int(value) for value in re.findall(r"\bepoll_try=(\d+)", text)] or [0]),
        "epoll_wake": max([int(value) for value in re.findall(r"\bepoll_wake=(\d+)", text)] or [0]),
        "epoll_timeout": max([int(value) for value in re.findall(r"\bepoll_timeout=(\d+)", text)] or [0]),
        "freq_actions": sorted(set(re.findall(r"policy_action=([^\s]+)", text))),
    }


def append_config(lines: list[str], title: str, rows: list[str]) -> None:
    lines.extend(["", title, "-" * len(title)])
    lines.extend((f"- {row}" for row in rows),)
    if not rows:
        lines.append("- No values were available.")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--role", choices=("server", "client"), required=True)
    parser.add_argument("--mode", required=True)
    parser.add_argument("--test-id", required=True)
    parser.add_argument("--test-name", required=True)
    parser.add_argument("--stamp", required=True)
    parser.add_argument("--stem", required=True)
    args = parser.parse_args()

    details = args.run_dir / "details"
    power = read_json(first(details, f"{args.stem}_power.json"))
    msr = read_json(first(details, f"{args.stem}_msr_power.json"))
    freq = read_json(first(details, f"{args.stem}_frequency.json"))
    manifest = read_json(first(details, f"{args.stem}_download_manifest.json"))
    goodput = read_json(first(details, f"{args.stem}_goodput*.json"))
    log = log_details(first(details, f"{args.stem}_log.txt"))

    lines = [
        "=" * 72,
        "GreenQUIC Run Summary",
        "=" * 72,
        "",
        "Run",
        "---",
        f"- Test: {args.test_id} — {args.test_name}",
        f"- Role: {args.role}",
        f"- GreenQUIC mode: {args.mode}",
        f"- Timestamp: {args.stamp}",
        "",
        "Goodput",
        "-------",
    ]

    primary = goodput.get("primary") or {}
    if args.role == "client" and primary:
        lines.extend([
            f"- Payload: {fmt(goodput.get('payload_gib'), 3)} GiB",
            f"- Download duration: {fmt(primary.get('duration_s'), 6)} s",
            f"- Goodput: {fmt(primary.get('goodput_gbps_decimal'), 6)} Gbit/s",
            f"- Goodput: {fmt(primary.get('goodput_mbps_decimal'), 3)} Mbit/s",
            f"- Timing source: {goodput.get('timing_source', 'unavailable')}",
        ])
        cross = goodput.get("msquic_completion_crosscheck") or {}
        if cross:
            lines.append(
                f"- MsQuic completion cross-check: {fmt(cross.get('goodput_gbps_decimal'), 6)} Gbit/s"
            )
    elif args.role == "client":
        payload = int(manifest.get("total_bytes", 0) or 0)
        duration = (log.get("transmission_us") or 0) / 1_000_000.0
        if payload > 0 and duration > 0:
            gbps = payload * 8.0 / duration / 1e9
            lines.extend([
                f"- Payload: {payload / (1024 ** 3):.3f} GiB",
                f"- Download duration: {duration:.6f} s",
                f"- Goodput: {gbps:.6f} Gbit/s",
            ])
        else:
            lines.append("- Goodput: unavailable because payload accounting or the client timer is missing.")
    else:
        lines.append("- Goodput: measured at the client; not derived from server listener lifetime.")

    lines.extend([
        "",
        "Whole-system Power and Energy",
        "-----------------------------",
        "- Sensor: power1 from lm-sensors/sysfs",
        "- Scope: whole-system/board power, not CPU-package RAPL",
        f"- Samples: {power.get('sample_count', 0)}",
        f"- Requested sampling interval: {power.get('sample_interval_ms_requested', 'unavailable')} ms",
        f"- Estimated cumulative energy: {fmt(power.get('estimated_energy_j_trapezoidal'), 3)} J",
        f"- Time-weighted average power: {fmt(power.get('average_power_w_time_weighted'), 3)} W",
        f"- Minimum / median / P95 / maximum: {fmt(power.get('power_w_min'))} / {fmt(power.get('power_w_median'))} / {fmt(power.get('power_w_p95'))} / {fmt(power.get('power_w_max'))} W",
        "",
        "RAPL/MSR Package and DRAM Power",
        "--------------------------------",
    ])
    if msr:
        lines.extend([
            "- Source: Intel RAPL powercap counters sampled by the compiled C helper",
            f"- Samples: {msr.get('sample_count', 0)}",
            f"- Requested sampling interval: {fmt(msr.get('requested_interval_ms'), 3)} ms",
            f"- Smoothing: {msr.get('smoothing_samples', 0)} samples ({fmt(msr.get('nominal_smoothing_window_ms'), 3)} ms nominal window)",
            f"- Actual interval median / P95 / maximum: {fmt(msr.get('actual_interval_ms_median'), 3)} / {fmt(msr.get('actual_interval_ms_p95'), 3)} / {fmt(msr.get('actual_interval_ms_max'), 3)} ms",
            f"- Package energy: {fmt(msr.get('package_energy_j'), 3)} J",
            f"- DRAM energy: {fmt(msr.get('dram_energy_j'), 3)} J",
            f"- Average package power: {fmt(msr.get('average_package_power_w'), 3)} W",
            f"- Average DRAM power: {fmt(msr.get('average_dram_power_w'), 3)} W",
            f"- Average package + DRAM power: {fmt(msr.get('average_total_power_w'), 3)} W",
            f"- Smoothed total minimum / median / P95 / maximum: {fmt(msr.get('smoothed_total_power_w_min'))} / {fmt(msr.get('smoothed_total_power_w_median'))} / {fmt(msr.get('smoothed_total_power_w_p95'))} / {fmt(msr.get('smoothed_total_power_w_max'))} W",
        ])
    else:
        lines.append("- RAPL/MSR trace unavailable for this run.")

    lines.extend([
        "",
        "CPU Frequency",
        "-------------",
        f"- CPUs observed: {', '.join(str(value) for value in freq.get('cpus', [])) or 'none'}",
        f"- Timestamped frequency events: {freq.get('event_count', 0)}",
        f"- Minimum observed frequency: {fmt((freq.get('min_freq_khz') or 0) / 1e6 if freq.get('min_freq_khz') else None, 3)} GHz",
        f"- Maximum observed frequency: {fmt((freq.get('max_freq_khz') or 0) / 1e6 if freq.get('max_freq_khz') else None, 3)} GHz",
        f"- Frequency actions: {', '.join(log.get('freq_actions', [])) or 'none'}",
        "",
        "Idle and Wake Behavior",
        "----------------------",
        f"- Idle modes observed: {', '.join(log.get('idle_modes', [])) or 'none'}",
        f"- EPOLL attempts: {log.get('epoll_try', 0)}",
        f"- EPOLL wakeups: {log.get('epoll_wake', 0)}",
        f"- EPOLL timeouts: {log.get('epoll_timeout', 0)}",
    ])

    terminal_end = len(lines)

    if args.role == "client":
        cleanup = manifest.get("cleanup") or {}
        lines.extend([
            "",
            "Client Storage",
            "--------------",
            f"- Logical downloaded bytes: {manifest.get('total_bytes', 0)}",
            f"- Regular downloaded payload bytes left on disk: {cleanup.get('regular_bytes_remaining', 0)}",
            f"- /dev/null sinks preserved or restored: {cleanup.get('sinks_ready', 0)}",
        ])

    lines.extend([
        "",
        "Measurement Notes",
        "-----------------",
        "- RAPL/MSR watts are interval averages derived from cumulative energy-counter differences.",
        "- The C sampler runs as a separate helper so it does not execute on the DPDK polling lcore.",
        "- Frequency timestamps are captured when each complete log row reaches the wrapper.",
        "- Goodput counts application payload bytes only; protocol overhead and retransmissions are excluded.",
    ])

    append_config(lines, "Effective DPDK Configuration", config_rows(first(details, f"{args.stem}_dpdk_config.txt")))
    append_config(lines, "Effective Power Configuration", config_rows(first(details, f"{args.stem}_powermng_config.txt")))
    append_config(lines, "Test Configuration Snapshot", config_rows(first(details, f"{args.stem}_test_config.txt")))
    append_config(lines, "Environment Overrides", config_rows(first(details, f"{args.stem}_environment.txt")))
    lines.append("")

    summary_path = details / f"{args.stem}_summary.txt"
    summary_path.write_text("\n".join(lines), encoding="utf-8")
    print("\n" + "\n".join(lines[:terminal_end]).rstrip() + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
chmod +x "$SUMMARY"

python3 - "$GQ_COMMON" "$MARKER" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
marker = sys.argv[2]
text = path.read_text(encoding="utf-8")

if marker in text:
    raise SystemExit(0)

defaults_marker = "# GREENQUIC-V22-SUITE-WIDE-DEFAULTS-V1"
if defaults_marker not in text:
    defaults_anchor = 'SUITE_ROOT="$(cd -- "$GQ_COMMON_DIR/.." && pwd)"\n'
    if defaults_anchor not in text:
        raise SystemExit("ERROR: SUITE_ROOT anchor not found")
    defaults = r'''

# GREENQUIC-V22-SUITE-WIDE-DEFAULTS-V1
# Defaults requested for normal GreenQUIC executions. Any value supplied in the
# command environment takes precedence over these assignments.
: "${GQ_MODE_OVERRIDE:=basic}"
: "${WORK_WAIT_MIN_LEVEL:=1}"
: "${GQ_IDLE_MODE_OVERRIDE:=epoll}"
: "${GQ_LOG_LEVEL:=1}"
: "${GQ_STATS_PERIOD_US:=1000000}"
: "${GQ_PLOT_X_TICK_MS:=1000}"
: "${GQ_PLOT_X_LABEL_MS:=1000}"
: "${GQ_POWER_SAMPLE_INTERVAL_MS:=1000}"
: "${GQ_ENABLE_MSR_TRACE:=1}"
: "${GQ_REQUIRE_MSR_TRACE:=0}"
: "${GQ_MSR_SAMPLE_INTERVAL_MS:=6}"
: "${GQ_MSR_SMOOTH_SAMPLES:=3}"
export GQ_MODE_OVERRIDE WORK_WAIT_MIN_LEVEL GQ_IDLE_MODE_OVERRIDE
export GQ_LOG_LEVEL GQ_STATS_PERIOD_US
export GQ_PLOT_X_TICK_MS GQ_PLOT_X_LABEL_MS GQ_POWER_SAMPLE_INTERVAL_MS
export GQ_ENABLE_MSR_TRACE GQ_REQUIRE_MSR_TRACE
export GQ_MSR_SAMPLE_INTERVAL_MS GQ_MSR_SMOOTH_SAMPLES
'''
    text = text.replace(defaults_anchor, defaults_anchor + defaults, 1)

functions = r'''
# GREENQUIC-V22-C-RAPL-MSR-RESULT-LAYOUT-DEFAULTS-V2
msr_trace_start() {
    local role="$1" output_csv="$2"
    GQ_MSR_TRACE_PID=""
    [[ "${GQ_ENABLE_MSR_TRACE:-1}" == 0 ]] && return 0

    local sampler="$GQ_COMMON_DIR/bin/gq_rapl_msr_sampler"
    local interval_ms="${GQ_MSR_SAMPLE_INTERVAL_MS:-6}"
    local smooth_samples="${GQ_MSR_SMOOTH_SAMPLES:-3}"
    local sampler_log="${output_csv%.csv}_sampler.log"

    if [[ ! -x "$sampler" ]]; then
        if [[ "${GQ_REQUIRE_MSR_TRACE:-0}" == 1 ]]; then
            die "Compiled RAPL/MSR sampler is missing: $sampler"
        fi
        warn "Compiled RAPL/MSR sampler is unavailable; continuing without it."
        return 0
    fi

    "$sampler" \
        --output "$output_csv" \
        --interval-ms "$interval_ms" \
        --smooth-samples "$smooth_samples" \
        >"$sampler_log" 2>&1 &
    GQ_MSR_TRACE_PID=$!

    sleep 0.05
    if ! kill -0 "$GQ_MSR_TRACE_PID" 2>/dev/null; then
        local rc=0
        wait "$GQ_MSR_TRACE_PID" || rc=$?
        GQ_MSR_TRACE_PID=""
        if [[ "${GQ_REQUIRE_MSR_TRACE:-0}" == 1 ]]; then
            die "RAPL/MSR sampler failed to start; inspect $sampler_log"
        fi
        warn "RAPL/MSR sampler failed to start (rc=$rc); continuing without it."
        return 0
    fi

    log "Started ${role} C RAPL/MSR trace pid=$GQ_MSR_TRACE_PID interval=${interval_ms}ms smoothing=${smooth_samples}"
}

msr_trace_stop() {
    local pid="${1:-}"
    [[ -n "$pid" ]] || return 0
    if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
    fi
    local rc=0
    wait "$pid" || rc=$?
    if [[ "$rc" != 0 ]]; then
        if [[ "${GQ_REQUIRE_MSR_TRACE:-0}" == 1 ]]; then
            return "$rc"
        fi
        warn "RAPL/MSR sampler stopped with rc=$rc; the transport result is preserved."
    fi
    return 0
}
'''

anchor = "\nrun_server() {"
if anchor not in text:
    raise SystemExit("ERROR: run_server anchor not found")
text = text.replace(anchor, functions + anchor, 1)

server_local = '    local power_prefix="$TEST_DIR/results/server_power_${mode}_${stamp}"\n'
if server_local not in text:
    raise SystemExit("ERROR: server power-prefix anchor not found")
text = text.replace(
    server_local,
    server_local + '    local msr_csv="$TEST_DIR/results/server_msr_${mode}_${stamp}.csv"\n',
    1,
)

server_start = '    power_trace_start server "$power_prefix" "$TEST_ID server $mode UNSYNCHRONIZED_LISTENER_LIFETIME"\n'
if server_start not in text:
    raise SystemExit("ERROR: server power-start anchor not found")
text = text.replace(
    server_start,
    server_start +
    '    msr_trace_start server "$msr_csv"\n'
    '    GQ_SERVER_MSR_PID="${GQ_MSR_TRACE_PID:-}"\n',
    1,
)

text, count = re.subn(
    r'local check_rc=0 energy_rc=0 power_rc=0 bundle_rc=0',
    'local check_rc=0 energy_rc=0 power_rc=0 msr_rc=0 bundle_rc=0',
    text,
    count=1,
)
if count != 1:
    raise SystemExit("ERROR: server status-variable anchor not found")

server_stop = '        power_trace_stop "${GQ_SERVER_POWER_PID:-}" "$GQ_SERVER_POWER_PREFIX" || power_rc=$?\n'
if server_stop not in text:
    raise SystemExit("ERROR: server power-stop anchor not found")
text = text.replace(
    server_stop,
    '        msr_trace_stop "${GQ_SERVER_MSR_PID:-}" || msr_rc=$?\n' + server_stop,
    1,
)

server_status = '        [[ "$rc" == 0 && "$power_rc" != 0 ]] && rc="$power_rc"\n'
if server_status not in text:
    raise SystemExit("ERROR: server result-status anchor not found")
text = text.replace(
    server_status,
    server_status + '        [[ "$rc" == 0 && "$msr_rc" != 0 ]] && rc="$msr_rc"\n',
    1,
)

client_local = '    local power_prefix="$TEST_DIR/results/client_power_${mode}_${stamp}"\n'
if client_local not in text:
    raise SystemExit("ERROR: client power-prefix anchor not found")
text = text.replace(
    client_local,
    client_local + '    local msr_csv="$TEST_DIR/results/client_msr_${mode}_${stamp}.csv"\n',
    1,
)

client_start = '    power_trace_start client "$power_prefix" "$TEST_ID client $mode"\n'
if client_start not in text:
    raise SystemExit("ERROR: client power-start anchor not found")
text = text.replace(
    client_start,
    client_start +
    '    msr_trace_start client "$msr_csv"\n'
    '    local msr_pid="${GQ_MSR_TRACE_PID:-}"\n',
    1,
)

client_status = '    local rc=0 energy_rc=0 power_rc=0 manifest_rc=0 cleanup_rc=0\n'
if client_status not in text:
    raise SystemExit("ERROR: client status-variable anchor not found")
text = text.replace(
    client_status,
    '    local rc=0 energy_rc=0 power_rc=0 msr_rc=0 manifest_rc=0 cleanup_rc=0\n',
    1,
)

client_stop = '    power_trace_stop "$power_pid" "$power_prefix" || power_rc=$?\n'
if client_stop not in text:
    raise SystemExit("ERROR: client power-stop anchor not found")
text = text.replace(
    client_stop,
    '    msr_trace_stop "$msr_pid" || msr_rc=$?\n' + client_stop,
    1,
)

client_return = '    [[ "$power_rc" == 0 ]] || return "$power_rc"\n'
if client_return not in text:
    raise SystemExit("ERROR: client return-status anchor not found")
text = text.replace(
    client_return,
    client_return + '    [[ "$msr_rc" == 0 ]] || return "$msr_rc"\n',
    1,
)

text += f"\n# {marker}\n"
path.write_text(text, encoding="utf-8")
PY

"$BUILD_HELPERS"

python3 -m py_compile "$MSR_TRACE" "$BUNDLER" "$SUMMARY" "$PLOT_UTILS"
bash -n "$GQ_COMMON" "$BUILD_HELPERS"

# Verify that the requested verbose plot geometry rows are absent from summary.
if grep -Fq -- '- Time-series plot size:' "$SUMMARY" || \
   grep -Fq -- '- Time-axis minor tick:' "$SUMMARY" || \
   grep -Fq -- '- Time-axis labeled tick:' "$SUMMARY"; then
    echo "ERROR: plot geometry rows still exist in the summary writer" >&2
    exit 1
fi

grep -Fq "$MARKER" "$GQ_COMMON" || {
    echo "ERROR: installation marker was not added" >&2
    exit 1
}

cat <<'EOF'

PASS: C RAPL/MSR sampling and clean result layout installed.

RAPL/MSR defaults:
  GQ_MSR_SAMPLE_INTERVAL_MS=6
  GQ_MSR_SMOOTH_SAMPLES=3

Suite-wide execution defaults:
  GQ_MODE_OVERRIDE=basic
  WORK_WAIT_MIN_LEVEL=1
  GQ_IDLE_MODE_OVERRIDE=epoll
  GQ_LOG_LEVEL=1
  GQ_STATS_PERIOD_US=1000000
  GQ_PLOT_X_TICK_MS=1000
  GQ_PLOT_X_LABEL_MS=1000
  GQ_POWER_SAMPLE_INTERVAL_MS=1000

Each future run folder contains only SVG files at its top level.
All CSV, JSON, logs, summary and configuration snapshots are stored in details/.
No MsQuic rebuild is required; the compiled sampler is a separate helper and
therefore does not execute on the DPDK polling lcore.
EOF
