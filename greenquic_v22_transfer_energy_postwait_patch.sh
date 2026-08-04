#!/usr/bin/env bash
set -Eeuo pipefail

# GreenQUIC V22 active-transfer energy, post-transfer tail, detailed charts,
# frequency-action counts, and EPOLL timeout-duration reporting.
#
# Requires the previously installed C RAPL/layout patch:
#   GREENQUIC-V22-C-RAPL-MSR-RESULT-LAYOUT-DEFAULTS-V2
#
# Measurement boundaries added by this patch:
#   - active transfer: first DPDK RX packet -> last DPDK TX packet
#   - whole run: sampler start -> sampler stop
#
# The active-transfer boundary is recorded inside the split DPDK backend with
# CLOCK_MONOTONIC timestamps. RAPL intervals are clipped proportionally at the
# start/end boundaries. QUIC packets are encrypted, so the DPDK backend cannot
# classify the final TX packet specifically as ACK versus CONNECTION_CLOSE;
# the report names the measurable boundary accurately as "last DPDK TX".

REPO="${1:-/root/mohsen/msquic}"
SUITE="${2:-/root/mohsen/greenquic_test_suite_v22}"

SRC="$REPO/src/platform/datapath_raw_dpdk_linux.c"
BUILD="$REPO/build-greenquic"
DPDK="$REPO/deps/dpdk-install"
COMMON="$SUITE/common/bin"
GQ_COMMON="$COMMON/gq_common.sh"
BUILD_HELPERS="$COMMON/build_helpers.sh"
SAMPLER_C="$COMMON/rapl_msr_sampler.c"
SAMPLER_BIN="$COMMON/gq_rapl_msr_sampler"
MSR_TRACE="$COMMON/rapl_msr_trace.py"
BUNDLER="$COMMON/bundle_run_results.py"
SUMMARY="$COMMON/write_run_summary.py"
PLOT_UTILS="$COMMON/gq_plot.py"
MARKER='GREENQUIC-V22-ACTIVE-TRANSFER-ENERGY-POSTWAIT-V1'
SOURCE_MARKER='GREENQUIC-V22-DPDK-TRANSFER-WINDOW-V1'

for required in \
    "$SRC" "$GQ_COMMON" "$BUILD_HELPERS" "$SAMPLER_C" \
    "$MSR_TRACE" "$BUNDLER" "$SUMMARY" "$PLOT_UTILS"; do
    [[ -f "$required" ]] || {
        echo "ERROR: required file is missing: $required" >&2
        exit 1
    }
done

for process_name in quicinterop quicinteropserver; do
    if pgrep -x "$process_name" >/dev/null 2>&1; then
        echo "ERROR: $process_name is running. Stop client/server before patching." >&2
        pgrep -ax "$process_name" >&2 || true
        exit 1
    fi
done

if ! grep -Fq 'GREENQUIC-V22-C-RAPL-MSR-RESULT-LAYOUT-DEFAULTS-V2' "$GQ_COMMON"; then
    echo "ERROR: install greenquic_v22_c_rapl_layout_defaults_patch.sh first." >&2
    exit 1
fi

if grep -Fq "$MARKER" "$GQ_COMMON"; then
    echo "The active-transfer energy/post-wait patch is already installed."
    exit 0
fi

stamp="$(date +%Y%m%d_%H%M%S)"
for file in \
    "$SRC" "$GQ_COMMON" "$BUILD_HELPERS" "$SAMPLER_C" \
    "$MSR_TRACE" "$BUNDLER" "$SUMMARY" "$PLOT_UTILS"; do
    cp -a "$file" "$file.before_transfer_energy_${stamp}"
done

echo "Backups created with suffix .before_transfer_energy_${stamp}"

# ---------------------------------------------------------------------------
# 1. Record the endpoint packet window in the active split DPDK backend.
# ---------------------------------------------------------------------------
python3 - "$SRC" "$SOURCE_MARKER" <<'PY'
from __future__ import annotations

from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
marker = sys.argv[2]
text = path.read_text(encoding="utf-8")

if marker in text:
    raise SystemExit(0)

required = [
    "GREENQUIC-V22-SPLIT-LINUX-DPDK-PORT",
    "rte_eth_rx_burst",
    "rte_eth_tx_burst",
]
missing = [token for token in required if token not in text]
if missing:
    raise SystemExit("ERROR: unsupported DPDK source shape; missing: " + ", ".join(missing))

for include in (
    "#include <stdatomic.h>\n",
    "#include <inttypes.h>\n",
    "#include <time.h>\n",
    "#include <stdlib.h>\n",
    "#include <stdio.h>\n",
):
    if include.strip() not in text:
        matches = list(re.finditer(r"(?m)^#include[^\n]*\n", text))
        if not matches:
            raise SystemExit("ERROR: no include anchor found in DPDK source")
        position = matches[-1].end()
        text = text[:position] + include + text[position:]

rx_count = len(re.findall(r"\brte_eth_rx_burst\s*\(", text))
tx_count = len(re.findall(r"\brte_eth_tx_burst\s*\(", text))
if rx_count < 1 or tx_count < 1:
    raise SystemExit(
        f"ERROR: expected at least one RX and TX burst call; rx={rx_count} tx={tx_count}"
    )

# Replace calls before inserting wrappers so the wrappers still call DPDK.
text = re.sub(r"\brte_eth_rx_burst\s*\(", "GreenQuicTrackedRxBurst(", text)
text = re.sub(r"\brte_eth_tx_burst\s*\(", "GreenQuicTrackedTxBurst(", text)

matches = list(re.finditer(r"(?m)^#include[^\n]*\n", text))
insert_at = matches[-1].end()
block = r'''

// GREENQUIC-V22-DPDK-TRANSFER-WINDOW-V1
// Endpoint-local packet window used to align high-resolution RAPL samples.
// Start: first non-empty DPDK RX burst.
// End:   last non-empty DPDK TX burst before process termination.
static atomic_uint_fast64_t GreenQuicTransferFirstRxNs = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t GreenQuicTransferLastRxNs = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t GreenQuicTransferLastTxNs = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t GreenQuicTransferRxPackets = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t GreenQuicTransferTxPackets = ATOMIC_VAR_INIT(0);

static inline uint64_t
GreenQuicTransferMonotonicNs(void)
{
    struct timespec Value;
    if (clock_gettime(CLOCK_MONOTONIC, &Value) != 0) {
        return 0;
    }
    return (uint64_t)Value.tv_sec * 1000000000ULL + (uint64_t)Value.tv_nsec;
}

static inline void
GreenQuicTransferOnRx(uint16_t Count)
{
    if (Count == 0) {
        return;
    }
    const uint64_t NowNs = GreenQuicTransferMonotonicNs();
    if (NowNs == 0) {
        return;
    }
    uint64_t Expected = 0;
    (void)atomic_compare_exchange_strong_explicit(
        &GreenQuicTransferFirstRxNs,
        &Expected,
        NowNs,
        memory_order_relaxed,
        memory_order_relaxed);
    atomic_store_explicit(&GreenQuicTransferLastRxNs, NowNs, memory_order_relaxed);
    atomic_fetch_add_explicit(
        &GreenQuicTransferRxPackets, (uint64_t)Count, memory_order_relaxed);
}

static inline void
GreenQuicTransferOnTx(uint16_t Count)
{
    if (Count == 0) {
        return;
    }
    const uint64_t NowNs = GreenQuicTransferMonotonicNs();
    if (NowNs == 0) {
        return;
    }
    atomic_store_explicit(&GreenQuicTransferLastTxNs, NowNs, memory_order_relaxed);
    atomic_fetch_add_explicit(
        &GreenQuicTransferTxPackets, (uint64_t)Count, memory_order_relaxed);
}

static inline uint16_t
GreenQuicTrackedRxBurst(
    uint16_t PortId,
    uint16_t QueueId,
    struct rte_mbuf** Packets,
    const uint16_t PacketCount
    )
{
    const uint16_t Result = rte_eth_rx_burst(PortId, QueueId, Packets, PacketCount);
    GreenQuicTransferOnRx(Result);
    return Result;
}

static inline uint16_t
GreenQuicTrackedTxBurst(
    uint16_t PortId,
    uint16_t QueueId,
    struct rte_mbuf** Packets,
    const uint16_t PacketCount
    )
{
    const uint16_t Result = rte_eth_tx_burst(PortId, QueueId, Packets, PacketCount);
    GreenQuicTransferOnTx(Result);
    return Result;
}

__attribute__((destructor))
static void
GreenQuicTransferWindowWrite(void)
{
    const char* OutputPath = getenv("GQ_TRANSFER_WINDOW_FILE");
    if (OutputPath == NULL || OutputPath[0] == '\0') {
        return;
    }

    const uint64_t FirstRxNs = atomic_load_explicit(
        &GreenQuicTransferFirstRxNs, memory_order_relaxed);
    const uint64_t LastRxNs = atomic_load_explicit(
        &GreenQuicTransferLastRxNs, memory_order_relaxed);
    const uint64_t LastTxNs = atomic_load_explicit(
        &GreenQuicTransferLastTxNs, memory_order_relaxed);
    const uint64_t EndNs = LastTxNs > FirstRxNs ? LastTxNs : LastRxNs;
    const uint64_t RxPackets = atomic_load_explicit(
        &GreenQuicTransferRxPackets, memory_order_relaxed);
    const uint64_t TxPackets = atomic_load_explicit(
        &GreenQuicTransferTxPackets, memory_order_relaxed);
    const char* Role = getenv("GQ_TRANSFER_ROLE");
    if (Role == NULL || Role[0] == '\0') {
        Role = "unknown";
    }

    char TemporaryPath[4096];
    const int Written = snprintf(
        TemporaryPath,
        sizeof(TemporaryPath),
        "%s.tmp.%ld",
        OutputPath,
        (long)getpid());
    if (Written <= 0 || (size_t)Written >= sizeof(TemporaryPath)) {
        return;
    }

    FILE* Output = fopen(TemporaryPath, "w");
    if (Output == NULL) {
        return;
    }

    const double DurationS =
        FirstRxNs != 0 && EndNs > FirstRxNs ?
            (double)(EndNs - FirstRxNs) / 1000000000.0 : 0.0;

    fprintf(Output, "{\n");
    fprintf(Output, "  \"schema\": \"greenquic-dpdk-transfer-window-v1\",\n");
    fprintf(Output, "  \"role\": \"%s\",\n", Role);
    fprintf(Output, "  \"clock\": \"CLOCK_MONOTONIC\",\n");
    fprintf(Output, "  \"start_boundary\": \"first non-empty DPDK RX burst\",\n");
    fprintf(Output, "  \"end_boundary\": \"last non-empty DPDK TX burst before process termination\",\n");
    fprintf(Output, "  \"first_rx_monotonic_ns\": %" PRIu64 ",\n", FirstRxNs);
    fprintf(Output, "  \"last_rx_monotonic_ns\": %" PRIu64 ",\n", LastRxNs);
    fprintf(Output, "  \"last_tx_monotonic_ns\": %" PRIu64 ",\n", LastTxNs);
    fprintf(Output, "  \"window_end_monotonic_ns\": %" PRIu64 ",\n", EndNs);
    fprintf(Output, "  \"duration_s\": %.9f,\n", DurationS);
    fprintf(Output, "  \"rx_packets\": %" PRIu64 ",\n", RxPackets);
    fprintf(Output, "  \"tx_packets\": %" PRIu64 ",\n", TxPackets);
    fprintf(Output, "  \"valid\": %s\n", FirstRxNs != 0 && EndNs > FirstRxNs ? "true" : "false");
    fprintf(Output, "}\n");

    if (fclose(Output) == 0) {
        (void)rename(TemporaryPath, OutputPath);
    } else {
        (void)unlink(TemporaryPath);
    }
}
'''
text = text[:insert_at] + block + text[insert_at:]
text += f"\n// {marker}\n"
path.write_text(text, encoding="utf-8")
print(f"Patched DPDK RX calls: {rx_count}")
print(f"Patched DPDK TX calls: {tx_count}")
PY

# ---------------------------------------------------------------------------
# 2. Add absolute CLOCK_MONOTONIC timestamps to each compiled RAPL sample.
# ---------------------------------------------------------------------------
python3 - "$SAMPLER_C" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

if "sample_monotonic_ns,elapsed_ms" not in text:
    old = '''    fprintf(Output, "# schema=greenquic-rapl-msr-c-v1\\n");
    fprintf(Output, "# requested_interval_ms=%.6f\\n", IntervalMs);'''
    new = '''    fprintf(Output, "# schema=greenquic-rapl-msr-c-v2\\n");
    fprintf(Output, "# start_monotonic_ns=%" PRIu64 "\\n", StartNs);
    fprintf(Output, "# requested_interval_ms=%.6f\\n", IntervalMs);'''
    if old not in text:
        raise SystemExit("ERROR: sampler metadata anchor not found")
    text = text.replace(old, new, 1)

    old = '''        "elapsed_ms,actual_interval_ms,package_energy_uj,dram_energy_uj,"
        "package_delta_j,dram_delta_j,package_power_w,dram_power_w,total_power_w,"
        "package_power_smoothed_w,dram_power_smoothed_w,total_power_smoothed_w\\n");'''
    new = '''        "sample_monotonic_ns,elapsed_ms,actual_interval_ms,package_energy_uj,dram_energy_uj,"
        "package_delta_j,dram_delta_j,package_power_w,dram_power_w,total_power_w,"
        "package_power_smoothed_w,dram_power_smoothed_w,total_power_smoothed_w\\n");'''
    if old not in text:
        raise SystemExit("ERROR: sampler CSV-header anchor not found")
    text = text.replace(old, new, 1)

    old = '''        fprintf(Output,
            "%.6f,%.6f,%" PRIu64 ",%" PRIu64 ",%.9f,%.9f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f\\n",
            (double)(SampleNs - StartNs) / 1000000.0,
            (double)DeltaNs / 1000000.0,'''
    new = '''        fprintf(Output,
            "%" PRIu64 ",%.6f,%.6f,%" PRIu64 ",%" PRIu64 ",%.9f,%.9f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f\\n",
            SampleNs,
            (double)(SampleNs - StartNs) / 1000000.0,
            (double)DeltaNs / 1000000.0,'''
    if old not in text:
        raise SystemExit("ERROR: sampler row-format anchor not found")
    text = text.replace(old, new, 1)

path.write_text(text, encoding="utf-8")
PY

# ---------------------------------------------------------------------------
# 3. Replace the SVG plot helper with per-source timing and denser Y ticks.
# ---------------------------------------------------------------------------
cat > "$PLOT_UTILS" <<'PY'
#!/usr/bin/env python3
"""Shared wide SVG plotting helpers for GreenQUIC result artifacts."""
from __future__ import annotations

import html
import math
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


@dataclass(frozen=True)
class PlotSettings:
    width: int
    height: int
    tick_ms: int
    label_ms: int
    min_px_per_tick: int
    max_width: int
    y_ticks: int
    left: int = 130
    right: int = 70
    top: int = 100
    bottom: int = 140


def env_int(name: str, default: int, minimum: int, maximum: int) -> int:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    try:
        value = int(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer, got {raw!r}") from exc
    if not minimum <= value <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}, got {value}")
    return value


def settings(kind: str, duration_ms: float) -> PlotSettings:
    kind_upper = kind.upper()
    base_width = env_int(
        f"GQ_{kind_upper}_PLOT_WIDTH_PX",
        env_int("GQ_PLOT_WIDTH_PX", 24000, 1200, 500000),
        1200,
        500000,
    )
    height = env_int(
        f"GQ_{kind_upper}_PLOT_HEIGHT_PX",
        env_int("GQ_PLOT_HEIGHT_PX", 3500, 400, 20000),
        400,
        20000,
    )
    global_tick = env_int("GQ_PLOT_X_TICK_MS", 1000, 1, 60000)
    global_label = env_int("GQ_PLOT_X_LABEL_MS", 1000, 1, 600000)
    tick_ms = env_int(f"GQ_{kind_upper}_PLOT_X_TICK_MS", global_tick, 1, 60000)
    label_ms = env_int(f"GQ_{kind_upper}_PLOT_X_LABEL_MS", global_label, 1, 600000)
    min_px = env_int(
        f"GQ_{kind_upper}_PLOT_MIN_PX_PER_TICK",
        env_int("GQ_PLOT_MIN_PX_PER_TICK", 12, 1, 200),
        1,
        200,
    )
    max_width = env_int("GQ_PLOT_MAX_WIDTH_PX", 120000, 1200, 1000000)
    y_ticks = env_int(
        f"GQ_{kind_upper}_PLOT_Y_TICKS",
        env_int("GQ_PLOT_Y_TICKS", 21, 2, 101),
        2,
        101,
    )
    if label_ms < tick_ms:
        label_ms = tick_ms
    if label_ms % tick_ms != 0:
        label_ms = math.ceil(label_ms / tick_ms) * tick_ms
    tick_count = max(1, math.ceil(max(duration_ms, 0.0) / tick_ms))
    dynamic_width = 200 + tick_count * min_px
    width = min(max(base_width, dynamic_width), max_width)
    return PlotSettings(
        width=width,
        height=height,
        tick_ms=tick_ms,
        label_ms=label_ms,
        min_px_per_tick=min_px,
        max_width=max_width,
        y_ticks=y_ticks,
    )


def _x(value_ms: float, xmax_ms: float, s: PlotSettings) -> float:
    plot_w = s.width - s.left - s.right
    if xmax_ms <= 0:
        return float(s.left)
    return s.left + max(0.0, min(value_ms, xmax_ms)) / xmax_ms * plot_w


def _y(value: float, ymin: float, ymax: float, s: PlotSettings) -> float:
    plot_h = s.height - s.top - s.bottom
    if ymax <= ymin:
        return s.top + plot_h / 2.0
    return s.top + plot_h - (value - ymin) / (ymax - ymin) * plot_h


def _nice_range(values: Iterable[float]) -> tuple[float, float]:
    rows = list(values)
    if not rows:
        return 0.0, 1.0
    low, high = min(rows), max(rows)
    if high <= low:
        padding = max(1.0, abs(low) * 0.05)
    else:
        padding = max((high - low) * 0.08, 1e-9)
    return low - padding, high + padding


def write_line_svg(
    path: Path,
    *,
    kind: str,
    title: str,
    y_label: str,
    series: list[dict[str, object]],
    duration_ms: float,
    step: bool = False,
    y_value_format: str = ".2f",
) -> PlotSettings:
    s = settings(kind, duration_ms)
    xmax_ms = max(float(duration_ms), float(s.tick_ms))
    all_y = [
        float(y)
        for item in series
        for _x_value, y in item.get("points", [])  # type: ignore[union-attr]
    ]
    ymin, ymax = _nice_range(all_y)
    plot_bottom = s.height - s.bottom
    plot_right = s.width - s.right
    palette = ["#1f77b4", "#d62728", "#2ca02c", "#9467bd", "#ff7f0e", "#17becf"]

    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{s.width}" height="{s.height}" viewBox="0 0 {s.width} {s.height}">',
        '<rect width="100%" height="100%" fill="white"/>',
        f'<text x="{s.width/2:.1f}" y="48" text-anchor="middle" font-family="sans-serif" font-size="32">{html.escape(title)}</text>',
    ]

    tick = 0
    while tick <= math.ceil(xmax_ms / s.tick_ms) * s.tick_ms:
        x = _x(float(tick), xmax_ms, s)
        major = tick % s.label_ms == 0
        stroke = "#a8a8a8" if major else "#e4e4e4"
        out.append(
            f'<line x1="{x:.2f}" y1="{s.top}" x2="{x:.2f}" y2="{plot_bottom}" stroke="{stroke}" stroke-width="1"/>'
        )
        tick_len = 16 if major else 8
        out.append(
            f'<line x1="{x:.2f}" y1="{plot_bottom}" x2="{x:.2f}" y2="{plot_bottom+tick_len}" stroke="black"/>'
        )
        if major:
            out.append(
                f'<text x="{x:.2f}" y="{plot_bottom+48}" text-anchor="middle" font-family="monospace" font-size="18">{tick}</text>'
            )
        tick += s.tick_ms

    for index in range(s.y_ticks):
        fraction = index / (s.y_ticks - 1)
        value = ymin + (ymax - ymin) * fraction
        y = _y(value, ymin, ymax, s)
        out.append(
            f'<line x1="{s.left}" y1="{y:.2f}" x2="{plot_right}" y2="{y:.2f}" stroke="#dedede"/>'
        )
        out.append(
            f'<text x="{s.left-16}" y="{y+6:.2f}" text-anchor="end" font-family="monospace" font-size="18">{format(value, y_value_format)}</text>'
        )

    out.extend([
        f'<line x1="{s.left}" y1="{s.top}" x2="{s.left}" y2="{plot_bottom}" stroke="black" stroke-width="2"/>',
        f'<line x1="{s.left}" y1="{plot_bottom}" x2="{plot_right}" y2="{plot_bottom}" stroke="black" stroke-width="2"/>',
    ])

    for index, item in enumerate(series):
        points = [(float(x), float(y)) for x, y in item.get("points", [])]  # type: ignore[union-attr]
        if not points:
            continue
        color = palette[index % len(palette)]
        if step:
            commands = [f'M {_x(points[0][0], xmax_ms, s):.2f} {_y(points[0][1], ymin, ymax, s):.2f}']
            for x_value, y_value in points[1:]:
                xp = _x(x_value, xmax_ms, s)
                commands.append(f'H {xp:.2f}')
                commands.append(f'V {_y(y_value, ymin, ymax, s):.2f}')
            commands.append(f'H {_x(xmax_ms, xmax_ms, s):.2f}')
            out.append(
                f'<path d="{" ".join(commands)}" fill="none" stroke="{color}" stroke-width="4"/>'
            )
        else:
            rendered = " ".join(
                f'{_x(x, xmax_ms, s):.2f},{_y(y, ymin, ymax, s):.2f}' for x, y in points
            )
            out.append(
                f'<polyline points="{rendered}" fill="none" stroke="{color}" stroke-width="4"/>'
            )
        legend_x = s.left + 20 + index * 320
        out.append(f'<line x1="{legend_x}" y1="76" x2="{legend_x+46}" y2="76" stroke="{color}" stroke-width="5"/>')
        out.append(
            f'<text x="{legend_x+58}" y="83" font-family="sans-serif" font-size="20">{html.escape(str(item.get("label", "series")))}</text>'
        )

    out.extend([
        f'<text x="{s.width/2:.1f}" y="{s.height-38}" text-anchor="middle" font-family="sans-serif" font-size="22">Elapsed time [ms] — minor tick {s.tick_ms} ms, labeled tick {s.label_ms} ms</text>',
        f'<text x="36" y="{s.height/2:.1f}" text-anchor="middle" font-family="sans-serif" font-size="22" transform="rotate(-90 36 {s.height/2:.1f})">{html.escape(y_label)}</text>',
        '</svg>',
    ])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(out) + "\n", encoding="utf-8")
    return s
PY
chmod +x "$PLOT_UTILS"

# ---------------------------------------------------------------------------
# 4. Produce both whole-run and active-transfer RAPL reports and SVGs.
# ---------------------------------------------------------------------------
cat > "$MSR_TRACE" <<'PY'
#!/usr/bin/env python3
"""Summarize and plot whole-run plus DPDK-active-window RAPL samples."""
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
            rows.append({
                key: float(value)
                for key, value in row.items()
                if key is not None and value is not None
            })
        except ValueError:
            continue
    return metadata, rows


def histogram_svg(path: Path, values: list[float], role: str, scope: str) -> None:
    width = env_int("GQ_MSR_HISTOGRAM_WIDTH_PX", 24000, 800, 120000)
    height = env_int("GQ_MSR_HISTOGRAM_HEIGHT_PX", 3500, 400, 20000)
    bins = env_int("GQ_MSR_HISTOGRAM_BINS", 100, 5, 1000)
    left, right, top, bottom = 150, 80, 110, 150
    plot_w, plot_h = width - left - right, height - top - bottom
    if not values:
        path.write_text(
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}">'
            '<text x="40" y="60" font-family="sans-serif">No RAPL samples available.</text></svg>\n',
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
        f'<text x="{width/2:.1f}" y="54" text-anchor="middle" font-family="sans-serif" font-size="34">GreenQUIC {html.escape(role)} RAPL power distribution — {html.escape(scope)}</text>',
    ]
    for index, count in enumerate(counts):
        x = left + index * bar_w
        h = count / max_count * plot_h
        out.append(
            f'<rect x="{x:.2f}" y="{top + plot_h - h:.2f}" width="{max(1.0, bar_w - 1.0):.2f}" height="{h:.2f}" fill="#1f77b4"/>'
        )
    out.extend([
        f'<line x1="{left}" y1="{top}" x2="{left}" y2="{top+plot_h}" stroke="black" stroke-width="2"/>',
        f'<line x1="{left}" y1="{top+plot_h}" x2="{left+plot_w}" y2="{top+plot_h}" stroke="black" stroke-width="2"/>',
        f'<text x="{left}" y="{top+plot_h+48}" text-anchor="middle" font-family="monospace" font-size="20">{low:.2f}</text>',
        f'<text x="{left+plot_w}" y="{top+plot_h+48}" text-anchor="middle" font-family="monospace" font-size="20">{high:.2f}</text>',
        f'<text x="{width/2:.1f}" y="{height-42}" text-anchor="middle" font-family="sans-serif" font-size="24">Smoothed package + DRAM power [W]</text>',
        f'<text x="42" y="{height/2:.1f}" text-anchor="middle" font-family="sans-serif" font-size="24" transform="rotate(-90 42 {height/2:.1f})">Sample count</text>',
        '</svg>',
    ])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(out) + "\n", encoding="utf-8")


def scope_metrics(rows: list[dict[str, float]], duration_s: float) -> dict[str, Any]:
    intervals = [row["actual_interval_ms"] for row in rows]
    total_smooth = [row["total_power_smoothed_w"] for row in rows]
    package_energy = sum(row["package_delta_j"] for row in rows)
    dram_energy = sum(row["dram_delta_j"] for row in rows)
    return {
        "sample_count": len(rows),
        "duration_s": duration_s,
        "actual_interval_ms_min": min(intervals) if intervals else None,
        "actual_interval_ms_median": statistics.median(intervals) if intervals else None,
        "actual_interval_ms_p95": percentile(intervals, 0.95),
        "actual_interval_ms_max": max(intervals) if intervals else None,
        "package_energy_j": package_energy,
        "dram_energy_j": dram_energy,
        "total_energy_j": package_energy + dram_energy,
        "average_package_power_w": package_energy / duration_s if duration_s > 0 else None,
        "average_dram_power_w": dram_energy / duration_s if duration_s > 0 else None,
        "average_total_power_w": (package_energy + dram_energy) / duration_s if duration_s > 0 else None,
        "smoothed_total_power_w_min": min(total_smooth) if total_smooth else None,
        "smoothed_total_power_w_median": statistics.median(total_smooth) if total_smooth else None,
        "smoothed_total_power_w_p95": percentile(total_smooth, 0.95),
        "smoothed_total_power_w_max": max(total_smooth) if total_smooth else None,
    }


def write_scope_plots(
    *,
    rows: list[dict[str, float]],
    role: str,
    scope: str,
    power_svg: Path,
    energy_svg: Path,
    histogram: Path,
    duration_ms: float,
) -> tuple[Any, Any]:
    elapsed_ms = [row["elapsed_ms"] for row in rows]
    package_smooth = [row["package_power_smoothed_w"] for row in rows]
    dram_smooth = [row["dram_power_smoothed_w"] for row in rows]
    total_smooth = [row["total_power_smoothed_w"] for row in rows]

    power_plot = write_line_svg(
        power_svg,
        kind="msr",
        title=f"GreenQUIC {role} RAPL package and DRAM power — {scope}",
        y_label="Power [W]",
        series=[
            {"label": "Package", "points": list(zip(elapsed_ms, package_smooth))},
            {"label": "DRAM", "points": list(zip(elapsed_ms, dram_smooth))},
            {"label": "Package + DRAM", "points": list(zip(elapsed_ms, total_smooth))},
        ],
        duration_ms=duration_ms,
        step=False,
        y_value_format=".2f",
    )
    histogram_svg(histogram, total_smooth, role, scope)

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
        energy_svg,
        kind="msr",
        title=f"GreenQUIC {role} RAPL cumulative energy — {scope}",
        y_label="Energy [J]",
        series=[
            {"label": "Package", "points": list(zip(elapsed_ms, cumulative_package))},
            {"label": "DRAM", "points": list(zip(elapsed_ms, cumulative_dram))},
            {"label": "Package + DRAM", "points": list(zip(elapsed_ms, cumulative_total))},
        ],
        duration_ms=duration_ms,
        step=False,
        y_value_format=".3f",
    )
    return power_plot, energy_plot


def read_window(path: Path | None) -> dict[str, Any]:
    if path is None or not path.is_file():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    if not value.get("valid"):
        return {}
    start = int(value.get("first_rx_monotonic_ns", 0) or 0)
    end = int(value.get("window_end_monotonic_ns", 0) or 0)
    return value if start > 0 and end > start else {}


def clip_rows(
    rows: list[dict[str, float]],
    start_ns: int,
    end_ns: int,
) -> list[dict[str, float]]:
    clipped: list[dict[str, float]] = []
    for row in rows:
        sample_end = int(row.get("sample_monotonic_ns", 0))
        interval_ns = max(1, int(row["actual_interval_ms"] * 1_000_000.0))
        sample_start = sample_end - interval_ns
        overlap_start = max(sample_start, start_ns)
        overlap_end = min(sample_end, end_ns)
        if overlap_end <= overlap_start:
            continue
        fraction = (overlap_end - overlap_start) / interval_ns
        item = dict(row)
        item["elapsed_ms"] = (overlap_end - start_ns) / 1_000_000.0
        item["actual_interval_ms"] = (overlap_end - overlap_start) / 1_000_000.0
        item["package_delta_j"] = row["package_delta_j"] * fraction
        item["dram_delta_j"] = row["dram_delta_j"] * fraction
        clipped.append(item)
    return clipped


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", type=Path, required=True)
    parser.add_argument("--json", type=Path, required=True)
    parser.add_argument("--timeseries-svg", type=Path, required=True)
    parser.add_argument("--histogram-svg", type=Path, required=True)
    parser.add_argument("--energy-timeseries-svg", type=Path, required=True)
    parser.add_argument("--transfer-window-json", type=Path)
    parser.add_argument("--transfer-timeseries-svg", type=Path)
    parser.add_argument("--transfer-histogram-svg", type=Path)
    parser.add_argument("--transfer-energy-timeseries-svg", type=Path)
    parser.add_argument("--role", choices=("server", "client"), required=True)
    args = parser.parse_args()

    metadata, rows = read_csv(args.csv)
    if not rows:
        raise SystemExit(f"ERROR: no valid RAPL samples in {args.csv}")
    if "sample_monotonic_ns" not in rows[0]:
        raise SystemExit("ERROR: RAPL CSV lacks sample_monotonic_ns; rebuild the helper")

    whole_duration_ms = rows[-1]["elapsed_ms"]
    whole_power_plot, whole_energy_plot = write_scope_plots(
        rows=rows,
        role=args.role,
        scope="whole run",
        power_svg=args.timeseries_svg,
        energy_svg=args.energy_timeseries_svg,
        histogram=args.histogram_svg,
        duration_ms=whole_duration_ms,
    )
    whole = scope_metrics(rows, whole_duration_ms / 1000.0)

    requested_interval = float(metadata.get("requested_interval_ms", "nan"))
    smoothing_samples = int(float(metadata.get("smoothing_samples", "0")))
    result: dict[str, Any] = {
        "schema": "greenquic-rapl-msr-summary-v2",
        "source": "Linux Intel RAPL powercap counters sampled by compiled C helper",
        "role": args.role,
        "requested_interval_ms": requested_interval,
        "smoothing_samples": smoothing_samples,
        "nominal_smoothing_window_ms": requested_interval * smoothing_samples,
        "whole_run": whole,
        "transfer_window": None,
        **whole,
        "power_plot": {
            "width_px": whole_power_plot.width,
            "height_px": whole_power_plot.height,
            "x_tick_ms": whole_power_plot.tick_ms,
            "x_label_ms": whole_power_plot.label_ms,
        },
        "energy_plot": {
            "width_px": whole_energy_plot.width,
            "height_px": whole_energy_plot.height,
            "x_tick_ms": whole_energy_plot.tick_ms,
            "x_label_ms": whole_energy_plot.label_ms,
        },
    }

    window = read_window(args.transfer_window_json)
    if window:
        start_ns = int(window["first_rx_monotonic_ns"])
        end_ns = int(window["window_end_monotonic_ns"])
        transfer_rows = clip_rows(rows, start_ns, end_ns)
        if transfer_rows:
            transfer_duration_s = (end_ns - start_ns) / 1_000_000_000.0
            transfer = scope_metrics(transfer_rows, transfer_duration_s)
            transfer.update({
                "start_monotonic_ns": start_ns,
                "end_monotonic_ns": end_ns,
                "boundary": "first DPDK RX packet to last DPDK TX packet",
                "rx_packets": window.get("rx_packets"),
                "tx_packets": window.get("tx_packets"),
                "interval_boundary_energy_proration": True,
            })
            if not all((
                args.transfer_timeseries_svg,
                args.transfer_histogram_svg,
                args.transfer_energy_timeseries_svg,
            )):
                raise SystemExit("ERROR: transfer SVG paths are incomplete")
            transfer_power_plot, transfer_energy_plot = write_scope_plots(
                rows=transfer_rows,
                role=args.role,
                scope="active transfer",
                power_svg=args.transfer_timeseries_svg,
                energy_svg=args.transfer_energy_timeseries_svg,
                histogram=args.transfer_histogram_svg,
                duration_ms=transfer_duration_s * 1000.0,
            )
            transfer["power_plot"] = {
                "width_px": transfer_power_plot.width,
                "height_px": transfer_power_plot.height,
                "x_tick_ms": transfer_power_plot.tick_ms,
                "x_label_ms": transfer_power_plot.label_ms,
            }
            transfer["energy_plot"] = {
                "width_px": transfer_energy_plot.width,
                "height_px": transfer_energy_plot.height,
                "x_tick_ms": transfer_energy_plot.tick_ms,
                "x_label_ms": transfer_energy_plot.label_ms,
            }
            result["transfer_window"] = transfer

    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
chmod +x "$MSR_TRACE"

# ---------------------------------------------------------------------------
# 5. Bundle transfer-window metadata and active-transfer SVGs.
# ---------------------------------------------------------------------------
cat > "$BUNDLER" <<'PY'
#!/usr/bin/env python3
"""Collect one GreenQUIC run: SVG visuals at top, details below details/."""
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
        "FREQ_UP_PERIOD_US", "FREQ_DOWN_PERIOD_US", "FREQ_MIN_IDLE_US", "FREQ_PERIOD_US",
        "GQ_LOG_LEVEL", "GQ_STATS_PERIOD_US", "GQ_CLEANUP_DOWNLOADED_FILES",
        "GQ_POST_TRANSFER_WAIT_S", "GQ_POWER_SAMPLE_INTERVAL_MS",
        "GQ_POWER_SENSOR_MATCH", "GQ_POWER_SENSOR_OCCURRENCE",
        "GQ_ENABLE_MSR_TRACE", "GQ_REQUIRE_MSR_TRACE", "GQ_MSR_SAMPLE_INTERVAL_MS",
        "GQ_MSR_SMOOTH_SAMPLES", "GQ_MSR_PLOT_WIDTH_PX", "GQ_MSR_PLOT_HEIGHT_PX",
        "GQ_MSR_PLOT_X_TICK_MS", "GQ_MSR_PLOT_X_LABEL_MS", "GQ_MSR_PLOT_Y_TICKS",
        "GQ_MSR_HISTOGRAM_WIDTH_PX", "GQ_MSR_HISTOGRAM_HEIGHT_PX", "GQ_MSR_HISTOGRAM_BINS",
        "GQ_PLOT_WIDTH_PX", "GQ_PLOT_HEIGHT_PX", "GQ_PLOT_X_TICK_MS",
        "GQ_PLOT_X_LABEL_MS", "GQ_PLOT_Y_TICKS", "GQ_PLOT_MIN_PX_PER_TICK",
        "GQ_PLOT_MAX_WIDTH_PX", "GQ_POWER_PLOT_WIDTH_PX", "GQ_POWER_PLOT_HEIGHT_PX",
        "GQ_POWER_PLOT_X_TICK_MS", "GQ_POWER_PLOT_X_LABEL_MS",
        "GQ_FREQ_PLOT_WIDTH_PX", "GQ_FREQ_PLOT_HEIGHT_PX",
        "GQ_FREQ_PLOT_X_TICK_MS", "GQ_FREQ_PLOT_X_LABEL_MS",
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
    candidates.extend(result_root.glob(f"{role}_transfer_{mode}_*.json"))
    if role == "client":
        candidates.extend(result_root.glob(f"client_download_manifest_{mode}_*.json"))
    source = latest(candidates)
    if source is None:
        raise SystemExit("ERROR: cannot determine the run timestamp")
    prefixes = (
        f"{role}_power_{mode}_",
        f"{role}_msr_{mode}_",
        f"{role}_transfer_{mode}_",
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

    transfer_window = details / f"{stem}_transfer_window.json"
    move(
        result_root / f"{args.role}_transfer_{args.mode}_{stamp}.json",
        transfer_window,
    )

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
        command = [
            "python3", str(Path(__file__).with_name("rapl_msr_trace.py")),
            "--csv", str(msr_csv),
            "--json", str(details / f"{stem}_msr_power.json"),
            "--timeseries-svg", str(run_dir / f"{stem}_msr_power_timeseries.svg"),
            "--histogram-svg", str(run_dir / f"{stem}_msr_power_histogram.svg"),
            "--energy-timeseries-svg", str(run_dir / f"{stem}_msr_energy_timeseries.svg"),
            "--role", args.role,
        ]
        if transfer_window.is_file():
            command.extend([
                "--transfer-window-json", str(transfer_window),
                "--transfer-timeseries-svg", str(run_dir / f"{stem}_msr_transfer_power_timeseries.svg"),
                "--transfer-histogram-svg", str(run_dir / f"{stem}_msr_transfer_power_histogram.svg"),
                "--transfer-energy-timeseries-svg", str(run_dir / f"{stem}_msr_transfer_energy_timeseries.svg"),
            ])
        subprocess.run(command, check=True)

    metadata = {
        "schema": "greenquic-run-bundle-v4",
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

# ---------------------------------------------------------------------------
# 6. Rewrite the concise summary with exact counts and timeout durations.
# ---------------------------------------------------------------------------
cat > "$SUMMARY" <<'PY'
#!/usr/bin/env python3
"""Write GreenQUIC whole-run and active-transfer summaries."""
from __future__ import annotations

import argparse
import json
import re
from collections import Counter
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
    actions = Counter(re.findall(r"policy_action=([^\s]+)", text))
    watchdogs = [int(value) for value in re.findall(r"\bwatchdog_us=(\d+)", text)]
    return {
        "transmission_us": transmission[-1] if transmission else None,
        "completions": completions,
        "idle_modes": sorted(set(re.findall(r"\bidle_mode=([^\s]+)", text))),
        "epoll_try": max([int(value) for value in re.findall(r"\bepoll_try=(\d+)", text)] or [0]),
        "epoll_wake": max([int(value) for value in re.findall(r"\bepoll_wake=(\d+)", text)] or [0]),
        "epoll_timeout": max([int(value) for value in re.findall(r"\bepoll_timeout=(\d+)", text)] or [0]),
        "epoll_watchdog_us": watchdogs[-1] if watchdogs else None,
        "freq_action_counts": dict(actions),
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
    transfer_file = read_json(first(details, f"{args.stem}_transfer_window.json"))
    log = log_details(first(details, f"{args.stem}_log.txt"))
    transfer = msr.get("transfer_window") or {}
    whole = msr.get("whole_run") or msr

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
        "Goodput — Active Transfer Only",
        "------------------------------",
    ]

    payload = int(manifest.get("total_bytes", 0) or 0)
    transfer_duration = float(transfer.get("duration_s", 0) or 0)
    primary = goodput.get("primary") or {}
    if args.role == "client" and payload > 0 and transfer_duration > 0:
        gbps = payload * 8.0 / transfer_duration / 1e9
        lines.extend([
            "- Timing boundary: first DPDK RX packet → last DPDK TX packet",
            f"- Payload: {payload / (1024 ** 3):.3f} GiB",
            f"- Active-transfer duration: {transfer_duration:.9f} s",
            f"- Goodput: {gbps:.6f} Gbit/s",
            f"- Goodput: {gbps * 1000.0:.3f} Mbit/s",
        ])
        if primary:
            lines.append(
                f"- MsQuic timer cross-check: {fmt(primary.get('goodput_gbps_decimal'), 6)} Gbit/s"
            )
    elif args.role == "client" and primary:
        lines.extend([
            f"- Payload: {fmt(goodput.get('payload_gib'), 3)} GiB",
            f"- Download duration: {fmt(primary.get('duration_s'), 6)} s",
            f"- Goodput: {fmt(primary.get('goodput_gbps_decimal'), 6)} Gbit/s",
            f"- Timing source: {goodput.get('timing_source', 'unavailable')}",
        ])
    elif args.role == "client":
        lines.append("- Goodput: unavailable because the packet window or payload accounting is missing.")
    else:
        lines.append("- Goodput is reported by the client; server transfer energy is reported below.")

    lines.extend([
        "",
        "RAPL Energy — Active Transfer Only",
        "----------------------------------",
    ])
    if transfer:
        lines.extend([
            "- Boundary: first DPDK RX packet → last DPDK TX packet",
            f"- Duration: {fmt(transfer.get('duration_s'), 9)} s",
            f"- RAPL samples overlapping window: {transfer.get('sample_count', 0)}",
            f"- Package energy: {fmt(transfer.get('package_energy_j'), 6)} J",
            f"- DRAM energy: {fmt(transfer.get('dram_energy_j'), 6)} J",
            f"- Package + DRAM energy: {fmt(transfer.get('total_energy_j'), 6)} J",
            f"- Average package power: {fmt(transfer.get('average_package_power_w'), 3)} W",
            f"- Average DRAM power: {fmt(transfer.get('average_dram_power_w'), 3)} W",
            f"- Average package + DRAM power: {fmt(transfer.get('average_total_power_w'), 3)} W",
            f"- RX packets observed: {transfer.get('rx_packets', transfer_file.get('rx_packets', 'unavailable'))}",
            f"- TX packets observed: {transfer.get('tx_packets', transfer_file.get('tx_packets', 'unavailable'))}",
        ])
    else:
        lines.append("- Active-transfer RAPL window unavailable for this run.")

    lines.extend([
        "",
        "RAPL Energy — Whole Test",
        "------------------------",
    ])
    if msr:
        lines.extend([
            f"- Duration: {fmt(whole.get('duration_s'), 6)} s",
            f"- Samples: {whole.get('sample_count', 0)}",
            f"- Requested sampling interval: {fmt(msr.get('requested_interval_ms'), 3)} ms",
            f"- Smoothing: {msr.get('smoothing_samples', 0)} samples ({fmt(msr.get('nominal_smoothing_window_ms'), 3)} ms nominal window)",
            f"- Actual interval median / P95 / maximum: {fmt(whole.get('actual_interval_ms_median'), 3)} / {fmt(whole.get('actual_interval_ms_p95'), 3)} / {fmt(whole.get('actual_interval_ms_max'), 3)} ms",
            f"- Package energy: {fmt(whole.get('package_energy_j'), 3)} J",
            f"- DRAM energy: {fmt(whole.get('dram_energy_j'), 3)} J",
            f"- Package + DRAM energy: {fmt(whole.get('total_energy_j'), 3)} J",
            f"- Average package + DRAM power: {fmt(whole.get('average_total_power_w'), 3)} W",
        ])
    else:
        lines.append("- RAPL trace unavailable for this run.")

    lines.extend([
        "",
        "Whole-System Power and Energy — Whole Test",
        "------------------------------------------",
        "- Sensor: power1 from lm-sensors/sysfs",
        "- Scope: whole-system/board power, not CPU-package RAPL",
        f"- Samples: {power.get('sample_count', 0)}",
        f"- Requested sampling interval: {power.get('sample_interval_ms_requested', 'unavailable')} ms",
        f"- Estimated cumulative energy: {fmt(power.get('estimated_energy_j_trapezoidal'), 3)} J",
        f"- Time-weighted average power: {fmt(power.get('average_power_w_time_weighted'), 3)} W",
        f"- Minimum / median / P95 / maximum: {fmt(power.get('power_w_min'))} / {fmt(power.get('power_w_median'))} / {fmt(power.get('power_w_p95'))} / {fmt(power.get('power_w_max'))} W",
        "",
        "CPU Frequency",
        "-------------",
        f"- CPUs observed: {', '.join(str(value) for value in freq.get('cpus', [])) or 'none'}",
        f"- Timestamped frequency events: {freq.get('event_count', 0)}",
        f"- Minimum observed frequency: {fmt((freq.get('min_freq_khz') or 0) / 1e6 if freq.get('min_freq_khz') else None, 3)} GHz",
        f"- Maximum observed frequency: {fmt((freq.get('max_freq_khz') or 0) / 1e6 if freq.get('max_freq_khz') else None, 3)} GHz",
    ])

    counts = log.get("freq_action_counts", {})
    if counts:
        rendered = ", ".join(f"{name}={counts[name]}" for name in sorted(counts))
        lines.append(f"- Frequency actions: {rendered}")
    else:
        lines.append("- Frequency actions: none")

    timeout_count = int(log.get("epoll_timeout", 0) or 0)
    watchdog_us = log.get("epoll_watchdog_us")
    lines.extend([
        "",
        "Idle and Wake Behavior",
        "----------------------",
        f"- Idle modes observed: {', '.join(log.get('idle_modes', [])) or 'none'}",
        f"- EPOLL attempts: {log.get('epoll_try', 0)}",
        f"- EPOLL wakeups: {log.get('epoll_wake', 0)}",
    ])
    if watchdog_us is not None:
        timeout_ms = float(watchdog_us) / 1000.0
        total_s = timeout_count * float(watchdog_us) / 1_000_000.0
        lines.append(
            f"- EPOLL timeouts: {timeout_count} (configured timeout {timeout_ms:.3f} ms each; approximately {total_s:.3f} s total)"
        )
    else:
        lines.append(f"- EPOLL timeouts: {timeout_count}")

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
        "- Active-transfer timestamps are captured in the DPDK RX/TX path with CLOCK_MONOTONIC.",
        "- RAPL boundary intervals are prorated by their exact overlap with the packet window.",
        "- The end boundary is the final DPDK TX packet; encrypted QUIC packet type is not inferred.",
        "- The post-transfer wait belongs only to the whole-test report, not active-transfer energy or goodput.",
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

# ---------------------------------------------------------------------------
# 7. Add defaults, endpoint window paths, and the 4-second client tail.
# ---------------------------------------------------------------------------
python3 - "$GQ_COMMON" "$MARKER" <<'PY'
from __future__ import annotations

from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
marker = sys.argv[2]
text = path.read_text(encoding="utf-8")

if marker in text:
    raise SystemExit(0)

# Tighten frequency policy/log observation without running it per packet.
replacements = {
    ': "${GQ_STATS_PERIOD_US:=1000000}"': ': "${GQ_STATS_PERIOD_US:=100000}"',
}
for old, new in replacements.items():
    if old in text:
        text = text.replace(old, new, 1)

# Insert defaults once near the existing suite-wide defaults.
default_anchor = ': "${GQ_MSR_SMOOTH_SAMPLES:=3}"\n'
if default_anchor not in text:
    raise SystemExit("ERROR: suite-wide MSR default anchor not found")
defaults = '''\
: "${GQ_POST_TRANSFER_WAIT_S:=4}"
: "${FREQ_PERIOD_US:=10000}"
: "${GQ_PLOT_HEIGHT_PX:=3500}"
: "${GQ_PLOT_Y_TICKS:=21}"
: "${GQ_POWER_PLOT_X_TICK_MS:=1000}"
: "${GQ_POWER_PLOT_X_LABEL_MS:=1000}"
: "${GQ_MSR_PLOT_X_TICK_MS:=10}"
: "${GQ_MSR_PLOT_X_LABEL_MS:=100}"
: "${GQ_MSR_PLOT_Y_TICKS:=21}"
: "${GQ_FREQ_PLOT_X_TICK_MS:=10}"
: "${GQ_FREQ_PLOT_X_LABEL_MS:=100}"
: "${GQ_FREQ_PLOT_Y_TICKS:=21}"
'''
if 'GQ_POST_TRANSFER_WAIT_S:=4' not in text:
    text = text.replace(default_anchor, default_anchor + defaults, 1)

export_anchor = 'export GQ_MSR_SAMPLE_INTERVAL_MS GQ_MSR_SMOOTH_SAMPLES\n'
if export_anchor not in text:
    raise SystemExit("ERROR: suite-wide export anchor not found")
exports = '''\
export GQ_POST_TRANSFER_WAIT_S FREQ_PERIOD_US
export GQ_PLOT_HEIGHT_PX GQ_PLOT_Y_TICKS
export GQ_POWER_PLOT_X_TICK_MS GQ_POWER_PLOT_X_LABEL_MS
export GQ_MSR_PLOT_X_TICK_MS GQ_MSR_PLOT_X_LABEL_MS GQ_MSR_PLOT_Y_TICKS
export GQ_FREQ_PLOT_X_TICK_MS GQ_FREQ_PLOT_X_LABEL_MS GQ_FREQ_PLOT_Y_TICKS
'''
if 'export GQ_POST_TRANSFER_WAIT_S FREQ_PERIOD_US' not in text:
    text = text.replace(export_anchor, export_anchor + exports, 1)

# Server endpoint-local transfer-window path, exported before process launch.
server_local = '    local msr_csv="$TEST_DIR/results/server_msr_${mode}_${stamp}.csv"\n'
if server_local not in text:
    raise SystemExit("ERROR: server MSR-path anchor not found")
server_insert = (
    server_local +
    '    local transfer_window="$TEST_DIR/results/server_transfer_${mode}_${stamp}.json"\n'
    '    GQ_TRANSFER_WINDOW_FILE="$transfer_window"\n'
    '    GQ_TRANSFER_ROLE=server\n'
    '    export GQ_TRANSFER_WINDOW_FILE GQ_TRANSFER_ROLE\n'
)
text = text.replace(server_local, server_insert, 1)

client_local = '    local msr_csv="$TEST_DIR/results/client_msr_${mode}_${stamp}.csv"\n'
if client_local not in text:
    raise SystemExit("ERROR: client MSR-path anchor not found")
client_insert = (
    client_local +
    '    local transfer_window="$TEST_DIR/results/client_transfer_${mode}_${stamp}.json"\n'
    '    GQ_TRANSFER_WINDOW_FILE="$transfer_window"\n'
    '    GQ_TRANSFER_ROLE=client\n'
    '    export GQ_TRANSFER_WINDOW_FILE GQ_TRANSFER_ROLE\n'
)
text = text.replace(client_local, client_insert, 1)

# Keep both power samplers alive for a configurable tail after successful client exit.
stop_anchor = '    msr_trace_stop "$msr_pid" || msr_rc=$?\n'
if stop_anchor not in text:
    raise SystemExit("ERROR: client MSR-stop anchor not found")
wait_block = '''\
    if [[ "$rc" == 0 ]]; then
        local post_transfer_wait_s="${GQ_POST_TRANSFER_WAIT_S:-4}"
        if [[ "$post_transfer_wait_s" != 0 && "$post_transfer_wait_s" != 0.0 ]]; then
            log "Client transport finished; keeping whole-test energy samplers active for ${post_transfer_wait_s}s."
            sleep "$post_transfer_wait_s"
        fi
    fi
'''
text = text.replace(stop_anchor, wait_block + stop_anchor, 1)

text += f"\n# {marker}\n"
path.write_text(text, encoding="utf-8")
PY

# ---------------------------------------------------------------------------
# 8. Build helpers and MsQuic binaries, then validate installed scripts.
# ---------------------------------------------------------------------------
"$BUILD_HELPERS"

export PKG_CONFIG_PATH="$DPDK/lib/pkgconfig:$DPDK/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LIBRARY_PATH="$DPDK/lib:$DPDK/lib/x86_64-linux-gnu${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LD_LIBRARY_PATH="$DPDK/lib:$DPDK/lib/x86_64-linux-gnu:$DPDK/lib/dpdk/pmds-22.0${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

pkg-config --exists libdpdk || {
    echo "ERROR: libdpdk is not visible through PKG_CONFIG_PATH" >&2
    exit 1
}

python3 -m py_compile "$MSR_TRACE" "$BUNDLER" "$SUMMARY" "$PLOT_UTILS"
bash -n "$GQ_COMMON" "$BUILD_HELPERS"

[[ -x "$SAMPLER_BIN" ]] || {
    echo "ERROR: compiled RAPL sampler is missing: $SAMPLER_BIN" >&2
    exit 1
}

echo "Building MsQuic with DPDK $(pkg-config --modversion libdpdk)..."
cmake --build "$BUILD" --target quicinteropserver quicinterop -j"$(nproc)"

for binary in \
    "$BUILD/bin/Release/quicinteropserver" \
    "$BUILD/bin/Release/quicinterop"; do
    [[ -x "$binary" ]] || {
        echo "ERROR: expected binary is missing: $binary" >&2
        exit 1
    }
done

grep -Fq "$SOURCE_MARKER" "$SRC" || {
    echo "ERROR: DPDK transfer-window marker was not installed" >&2
    exit 1
}
grep -Fq "$MARKER" "$GQ_COMMON" || {
    echo "ERROR: runner marker was not installed" >&2
    exit 1
}

cat <<'DONE'

PASS: active-transfer energy and post-transfer-tail patch installed.

New defaults:
  GQ_POST_TRANSFER_WAIT_S=4
  GQ_MSR_SAMPLE_INTERVAL_MS=6
  GQ_MSR_SMOOTH_SAMPLES=3
  GQ_MSR_PLOT_X_TICK_MS=10
  GQ_MSR_PLOT_X_LABEL_MS=100
  GQ_FREQ_PLOT_X_TICK_MS=10
  GQ_FREQ_PLOT_X_LABEL_MS=100
  GQ_POWER_PLOT_X_TICK_MS=1000
  GQ_POWER_PLOT_X_LABEL_MS=1000
  GQ_PLOT_HEIGHT_PX=3500
  GQ_PLOT_Y_TICKS=21
  FREQ_PERIOD_US=10000
  GQ_STATS_PERIOD_US=100000

The client runner keeps whole-test power samplers alive for four seconds after
quicinterop exits. Active-transfer goodput and RAPL energy exclude that tail.
DONE
