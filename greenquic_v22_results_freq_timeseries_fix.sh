#!/usr/bin/env bash
set -Eeuo pipefail

# GreenQUIC V22 results + frequency/power/energy time-series repair.
#
# This patch is plain text. It preserves the existing GreenQUIC policy and
# datapath changes. It only repairs result handling and adds readable plots.
#
# Added outputs for each server/client run:
#   - one self-contained run folder using date/time, test, role and mode
#   - power time series
#   - cumulative-energy time series
#   - power histogram
#   - CPU-frequency time series
#   - raw log plus a timestamped JSONL log timeline
#   - goodput and a human-readable summary
#
# Plot environment variables:
#   GQ_PLOT_WIDTH_PX=24000
#   GQ_PLOT_HEIGHT_PX=700
#   GQ_PLOT_X_TICK_MS=10
#   GQ_PLOT_X_LABEL_MS=100
#   GQ_PLOT_MIN_PX_PER_TICK=12
#   GQ_PLOT_MAX_WIDTH_PX=120000
#   GQ_POWER_PLOT_WIDTH_PX=<optional override>
#   GQ_POWER_PLOT_HEIGHT_PX=<optional override>
#   GQ_FREQ_PLOT_WIDTH_PX=<optional override>
#   GQ_FREQ_PLOT_HEIGHT_PX=<optional override>
#
# The 10 ms x-axis tick is a display grid. It does not change the power sensor
# sampling interval. Configure actual power sampling separately with:
#   GQ_POWER_SAMPLE_INTERVAL_MS=1000

SUITE="${1:-/root/mohsen/greenquic_test_suite_v22}"
COMMON="$SUITE/common/bin"
GQ_COMMON="$COMMON/gq_common.sh"
POWER_TRACE="$COMMON/power_trace.py"
GOODPUT="$COMMON/report_goodput.py"
PLOT_UTILS="$COMMON/gq_plot.py"
TIMESTAMP_TEE="$COMMON/timestamp_tee.py"
FREQ_TRACE="$COMMON/frequency_trace.py"
BUNDLER="$COMMON/bundle_run_results.py"
SUMMARY="$COMMON/write_run_summary.py"
P0="$SUITE/test_cases/pretests/P0_smoke_1MiB/run_client.sh"
P1="$SUITE/test_cases/pretests/P1_goodput_off_10GiB/run_client.sh"
P2="$SUITE/test_cases/pretests/P2_goodput_basic_10GiB/run_client.sh"
MARKER='GREENQUIC-V22-RESULTS-FREQ-TIMESERIES-FIX-V2'

for required in "$GQ_COMMON" "$POWER_TRACE" "$GOODPUT" "$P0" "$P1" "$P2"; do
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

if ! grep -Fq 'GREENQUIC-V22-DOWNLOAD-CLEANUP-HOTFIX' "$GQ_COMMON"; then
    echo "ERROR: the GreenQUIC V22 log/goodput base patch is not installed." >&2
    exit 1
fi

if grep -Fq "$MARKER" "$GQ_COMMON"; then
    echo "The GreenQUIC V22 results/frequency time-series repair is already installed."
    exit 0
fi

backup_stamp="$(date +%Y%m%d_%H%M%S)"
for file in "$GQ_COMMON" "$POWER_TRACE" "$GOODPUT" "$P0" "$P1" "$P2"; do
    cp -a "$file" "$file.before_results_freq_fix_${backup_stamp}"
done
for file in "$PLOT_UTILS" "$TIMESTAMP_TEE" "$FREQ_TRACE" "$BUNDLER" "$SUMMARY"; do
    [[ -e "$file" ]] && cp -a "$file" "$file.before_results_freq_fix_${backup_stamp}"
done

echo "Backups created with suffix .before_results_freq_fix_${backup_stamp}"

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
    left: int = 110
    right: int = 50
    top: int = 70
    bottom: int = 100


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
        env_int("GQ_PLOT_HEIGHT_PX", 700, 400, 5000),
        400,
        5000,
    )
    tick_ms = env_int("GQ_PLOT_X_TICK_MS", 10, 1, 60000)
    label_ms = env_int("GQ_PLOT_X_LABEL_MS", 100, 1, 600000)
    min_px = env_int("GQ_PLOT_MIN_PX_PER_TICK", 12, 1, 200)
    max_width = env_int("GQ_PLOT_MAX_WIDTH_PX", 120000, 1200, 1000000)
    if label_ms < tick_ms:
        label_ms = tick_ms
    if label_ms % tick_ms != 0:
        label_ms = math.ceil(label_ms / tick_ms) * tick_ms
    tick_count = max(1, math.ceil(max(duration_ms, 0.0) / tick_ms))
    dynamic_width = 160 + tick_count * min_px
    width = min(max(base_width, dynamic_width), max_width)
    return PlotSettings(
        width=width,
        height=height,
        tick_ms=tick_ms,
        label_ms=label_ms,
        min_px_per_tick=min_px,
        max_width=max_width,
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
        f'<text x="{s.width/2:.1f}" y="34" text-anchor="middle" font-family="sans-serif" font-size="24">{html.escape(title)}</text>',
    ]

    tick = 0
    while tick <= math.ceil(xmax_ms / s.tick_ms) * s.tick_ms:
        x = _x(float(tick), xmax_ms, s)
        major = tick % s.label_ms == 0
        stroke = "#b8b8b8" if major else "#e8e8e8"
        out.append(
            f'<line x1="{x:.2f}" y1="{s.top}" x2="{x:.2f}" y2="{plot_bottom}" stroke="{stroke}" stroke-width="1"/>'
        )
        tick_len = 12 if major else 6
        out.append(
            f'<line x1="{x:.2f}" y1="{plot_bottom}" x2="{x:.2f}" y2="{plot_bottom+tick_len}" stroke="black"/>'
        )
        if major:
            out.append(
                f'<text x="{x:.2f}" y="{plot_bottom+34}" text-anchor="middle" font-family="monospace" font-size="13">{tick}</text>'
            )
        tick += s.tick_ms

    for index in range(6):
        value = ymin + (ymax - ymin) * index / 5.0
        y = _y(value, ymin, ymax, s)
        out.append(
            f'<line x1="{s.left}" y1="{y:.2f}" x2="{plot_right}" y2="{y:.2f}" stroke="#dedede"/>'
        )
        out.append(
            f'<text x="{s.left-12}" y="{y+5:.2f}" text-anchor="end" font-family="monospace" font-size="14">{format(value, y_value_format)}</text>'
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
            previous_y = points[0][1]
            for x_value, y_value in points[1:]:
                xp = _x(x_value, xmax_ms, s)
                commands.append(f'H {xp:.2f}')
                commands.append(f'V {_y(y_value, ymin, ymax, s):.2f}')
                previous_y = y_value
            commands.append(f'H {_x(xmax_ms, xmax_ms, s):.2f}')
            out.append(
                f'<path d="{" ".join(commands)}" fill="none" stroke="{color}" stroke-width="3"/>'
            )
        else:
            rendered = " ".join(
                f'{_x(x, xmax_ms, s):.2f},{_y(y, ymin, ymax, s):.2f}' for x, y in points
            )
            out.append(
                f'<polyline points="{rendered}" fill="none" stroke="{color}" stroke-width="3"/>'
            )
        for x_value, y_value in points:
            out.append(
                f'<circle cx="{_x(x_value, xmax_ms, s):.2f}" cy="{_y(y_value, ymin, ymax, s):.2f}" r="3" fill="{color}"/>'
            )
        legend_x = s.left + 20 + index * 220
        out.append(f'<line x1="{legend_x}" y1="54" x2="{legend_x+32}" y2="54" stroke="{color}" stroke-width="4"/>')
        out.append(
            f'<text x="{legend_x+42}" y="59" font-family="sans-serif" font-size="15">{html.escape(str(item.get("label", "series")))}</text>'
        )

    out.extend([
        f'<text x="{s.width/2:.1f}" y="{s.height-24}" text-anchor="middle" font-family="sans-serif" font-size="17">Elapsed time [ms] — minor tick {s.tick_ms} ms, labeled tick {s.label_ms} ms</text>',
        f'<text x="28" y="{s.height/2:.1f}" text-anchor="middle" font-family="sans-serif" font-size="17" transform="rotate(-90 28 {s.height/2:.1f})">{html.escape(y_label)}</text>',
        '</svg>',
    ])
    path.write_text("\n".join(out) + "\n", encoding="utf-8")
    return s
PY
chmod +x "$PLOT_UTILS"

cat > "$TIMESTAMP_TEE" <<'PY'
#!/usr/bin/env python3
"""Print application output unchanged while recording per-line timestamps."""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw-log", type=Path, required=True)
    parser.add_argument("--timeline", type=Path, required=True)
    args = parser.parse_args()

    args.raw_log.parent.mkdir(parents=True, exist_ok=True)
    args.timeline.parent.mkdir(parents=True, exist_ok=True)
    start_wall_ns = time.time_ns()
    start_mono_ns = time.monotonic_ns()

    with args.raw_log.open("w", encoding="utf-8", errors="replace") as raw_handle, \
         args.timeline.open("w", encoding="utf-8") as timeline_handle:
        timeline_handle.write(json.dumps({
            "type": "meta",
            "start_wall_ns": start_wall_ns,
            "start_monotonic_ns": start_mono_ns,
            "clock": "time.monotonic_ns captured when each complete log line reached the wrapper",
        }) + "\n")
        timeline_handle.flush()

        index = 0
        for received in sys.stdin:
            line = received if received.endswith("\n") else received + "\n"
            mono_ns = time.monotonic_ns()
            wall_ns = time.time_ns()
            raw_handle.write(line)
            raw_handle.flush()
            sys.stdout.write(line)
            sys.stdout.flush()
            timeline_handle.write(json.dumps({
                "type": "line",
                "index": index,
                "elapsed_s": (mono_ns - start_mono_ns) / 1e9,
                "wall_ns": wall_ns,
                "monotonic_ns": mono_ns,
                "line": line.rstrip("\r\n"),
            }, ensure_ascii=False) + "\n")
            timeline_handle.flush()
            index += 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
chmod +x "$TIMESTAMP_TEE"

cat > "$FREQ_TRACE" <<'PY'
#!/usr/bin/env python3
"""Create CPU-frequency traces from timestamped GreenQUIC log lines."""
from __future__ import annotations

import argparse
import csv
import json
import re
from pathlib import Path
from typing import Any

from gq_plot import write_line_svg

CPU_RE = re.compile(r"^\[CPU\s+(\d+)\]")
ACTION_RE = re.compile(r"\bpolicy_action=([^\s]+).*?\bafter_khz=(\d+)")
STATS_RE = re.compile(r"\bfreq_khz=(\d+)")


def read_events(path: Path) -> tuple[list[dict[str, Any]], float]:
    events: list[dict[str, Any]] = []
    duration_s = 0.0
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            row = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if row.get("type") != "line":
            continue
        elapsed_s = float(row.get("elapsed_s", 0.0))
        duration_s = max(duration_s, elapsed_s)
        line = str(row.get("line", ""))
        cpu_match = CPU_RE.search(line)
        if not cpu_match:
            continue
        cpu = int(cpu_match.group(1))
        action_match = ACTION_RE.search(line)
        stats_match = STATS_RE.search(line)
        if action_match:
            events.append({
                "elapsed_s": elapsed_s,
                "elapsed_ms": elapsed_s * 1000.0,
                "cpu": cpu,
                "freq_khz": int(action_match.group(2)),
                "source": "frequency_action",
                "action": action_match.group(1),
            })
        elif stats_match:
            events.append({
                "elapsed_s": elapsed_s,
                "elapsed_ms": elapsed_s * 1000.0,
                "cpu": cpu,
                "freq_khz": int(stats_match.group(1)),
                "source": "periodic_stats",
                "action": None,
            })
    return events, duration_s


def deduplicate(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    last_by_cpu: dict[int, int] = {}
    for event in events:
        cpu = int(event["cpu"])
        freq = int(event["freq_khz"])
        if last_by_cpu.get(cpu) == freq and event.get("source") == "periodic_stats":
            continue
        result.append(event)
        last_by_cpu[cpu] = freq
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeline", type=Path, required=True)
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument("--role", choices=("server", "client"), required=True)
    args = parser.parse_args()

    raw_events, duration_s = read_events(args.timeline)
    events = deduplicate(raw_events)
    args.prefix.parent.mkdir(parents=True, exist_ok=True)
    json_path = Path(str(args.prefix) + ".json")
    csv_path = Path(str(args.prefix) + ".csv")
    list_path = Path(str(args.prefix) + "_lists.txt")
    svg_path = Path(str(args.prefix) + "_timeseries.svg")

    cpus = sorted({int(row["cpu"]) for row in events})
    series = []
    for cpu in cpus:
        points = [
            (float(row["elapsed_ms"]), float(row["freq_khz"]) / 1_000_000.0)
            for row in events if int(row["cpu"]) == cpu
        ]
        series.append({"label": f"CPU {cpu}", "points": points})

    plot = None
    if series:
        plot = write_line_svg(
            svg_path,
            kind="freq",
            title=f"GreenQUIC {args.role} CPU frequency over time",
            y_label="Frequency [GHz]",
            series=series,
            duration_ms=duration_s * 1000.0,
            step=True,
            y_value_format=".3f",
        )

    frequencies = [int(row["freq_khz"]) for row in events]
    output = {
        "schema": "greenquic-frequency-trace-v2",
        "role": args.role,
        "timeline_duration_s": duration_s,
        "event_count_raw": len(raw_events),
        "event_count": len(events),
        "cpus": cpus,
        "min_freq_khz": min(frequencies) if frequencies else None,
        "max_freq_khz": max(frequencies) if frequencies else None,
        "events": events,
        "plot": None if plot is None else {
            "width_px": plot.width,
            "height_px": plot.height,
            "x_tick_ms": plot.tick_ms,
            "x_label_ms": plot.label_ms,
            "min_px_per_tick": plot.min_px_per_tick,
        },
        "measurement_note": (
            "Event time is captured by the line-timestamp wrapper when a complete GreenQUIC "
            "log row is received. Frequency actions are immediate log events; unchanged "
            "intervals are represented as a step trace."
        ),
    }
    json_path.write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")
    with csv_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=[
            "elapsed_s", "elapsed_ms", "cpu", "freq_khz", "source", "action"
        ])
        writer.writeheader()
        writer.writerows(events)
    list_path.write_text(
        "frequency_events = " + repr(events) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
chmod +x "$FREQ_TRACE"

cat > "$POWER_TRACE" <<'PY'
#!/usr/bin/env python3
"""GreenQUIC whole-system power and cumulative-energy sampler."""
from __future__ import annotations

import argparse
import csv
import html
import json
import math
import os
import re
import signal
import statistics
import subprocess
import time
from pathlib import Path
from typing import Any

from gq_plot import write_line_svg

_STOP = False


def request_stop(_signum: int, _frame: object) -> None:
    global _STOP
    _STOP = True


def percentile(values: list[float], p: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * p
    low, high = math.floor(position), math.ceil(position)
    if low == high:
        return ordered[low]
    fraction = position - low
    return ordered[low] * (1.0 - fraction) + ordered[high] * fraction


def unit_to_watts(value: float, unit: str) -> float:
    normalized = unit.replace("µ", "u").lower()
    factors = {"w": 1.0, "kw": 1000.0, "mw": 1e-3, "uw": 1e-6, "nw": 1e-9}
    if normalized not in factors:
        raise ValueError(f"unsupported power unit: {unit}")
    return value * factors[normalized]


def read_from_sensors(match: str, occurrence: str) -> tuple[float, str, str]:
    completed = subprocess.run(
        ["sensors"], check=False, capture_output=True, text=True, timeout=5.0
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or f"exit status {completed.returncode}"
        raise RuntimeError(f"sensors failed: {detail}")
    matching = [line.strip() for line in completed.stdout.splitlines() if match.lower() in line.lower()]
    if not matching:
        raise RuntimeError(f"no sensors line contains {match!r}")
    line = matching[0] if occurrence == "first" else matching[-1]
    found = re.search(
        rf"{re.escape(match)}\s*:\s*([+-]?\d+(?:\.\d+)?)\s*(kW|mW|uW|µW|nW|W)\b",
        line,
        re.IGNORECASE,
    )
    if found is None:
        found = re.search(r"([+-]?\d+(?:\.\d+)?)\s*(kW|mW|uW|µW|nW|W)\b", line, re.IGNORECASE)
    if found is None:
        raise RuntimeError(f"cannot parse watts from sensors line: {line}")
    return unit_to_watts(float(found.group(1)), found.group(2)), "lm-sensors", line


def read_from_sysfs(match: str, occurrence: str) -> tuple[float, str, str]:
    candidates: list[Path] = []
    for name in ("power1_average", "power1_input"):
        candidates.extend(sorted(Path("/sys/class/hwmon").glob(f"hwmon*/{name}")))
    readable: list[tuple[Path, str]] = []
    for path in candidates:
        if not os.access(path, os.R_OK):
            continue
        name_file = path.parent / "name"
        sensor_name = name_file.read_text(encoding="utf-8").strip() if name_file.exists() else path.parent.name
        description = f"{sensor_name}:{path.name}"
        if match.lower() in description.lower() or match.lower() == "power1":
            readable.append((path, description))
    if not readable:
        readable = [(p, str(p)) for p in candidates if os.access(p, os.R_OK)]
    if not readable:
        raise RuntimeError("no readable hwmon power1 sensor")
    path, description = readable[0] if occurrence == "first" else readable[-1]
    raw = float(path.read_text(encoding="utf-8").strip())
    return raw / 1_000_000.0, "hwmon-sysfs", f"{description} raw_uw={raw:g} path={path}"


def read_power(match: str, occurrence: str) -> tuple[float, str, str]:
    problems: list[str] = []
    try:
        return read_from_sensors(match, occurrence)
    except Exception as exc:
        problems.append(str(exc))
    try:
        return read_from_sysfs(match, occurrence)
    except Exception as exc:
        problems.append(str(exc))
    raise RuntimeError("; ".join(problems))


def cumulative_energy(samples: list[dict[str, Any]]) -> list[float]:
    totals = [0.0] if samples else []
    for left, right in zip(samples, samples[1:]):
        dt = float(right["elapsed_s"]) - float(left["elapsed_s"])
        increment = 0.0
        if dt > 0:
            increment = (float(left["power_w"]) + float(right["power_w"])) * 0.5 * dt
        totals.append(totals[-1] + increment)
    return totals


def histogram_svg(path: Path, role: str, values: list[float]) -> None:
    if not values:
        return
    width = int(os.environ.get("GQ_HISTOGRAM_WIDTH_PX", "1800"))
    height = int(os.environ.get("GQ_HISTOGRAM_HEIGHT_PX", "700"))
    width = min(max(width, 900), 20000)
    height = min(max(height, 400), 5000)
    left, right, top, bottom = 100, 50, 70, 100
    plot_w, plot_h = width - left - right, height - top - bottom
    bins = min(20, max(1, math.ceil(math.sqrt(len(values)))))
    low, high = min(values), max(values)
    if high <= low:
        low -= 0.5
        high += 0.5
    step = (high - low) / bins
    counts = [0] * bins
    for value in values:
        counts[min(bins - 1, max(0, int((value - low) / step)))] += 1
    max_count = max(counts) or 1
    bar_w = plot_w / bins
    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        '<rect width="100%" height="100%" fill="white"/>',
        f'<text x="{width/2}" y="35" text-anchor="middle" font-family="sans-serif" font-size="24">{html.escape(f"GreenQUIC {role} power1 histogram")}</text>',
        f'<line x1="{left}" y1="{top}" x2="{left}" y2="{top+plot_h}" stroke="black" stroke-width="2"/>',
        f'<line x1="{left}" y1="{top+plot_h}" x2="{left+plot_w}" y2="{top+plot_h}" stroke="black" stroke-width="2"/>',
    ]
    for index, count in enumerate(counts):
        bar_h = plot_h * count / max_count
        x = left + index * bar_w + 2
        y = top + plot_h - bar_h
        out.append(f'<rect x="{x:.2f}" y="{y:.2f}" width="{max(1.0, bar_w-4):.2f}" height="{bar_h:.2f}" fill="#d9e8f5" stroke="#1f77b4"/>')
    out.extend([
        f'<text x="{width/2}" y="{height-28}" text-anchor="middle" font-family="sans-serif" font-size="17">Power [W]</text>',
        f'<text x="30" y="{height/2}" text-anchor="middle" font-family="sans-serif" font-size="17" transform="rotate(-90 30 {height/2})">Sample count</text>',
        f'<text x="{left}" y="{top+plot_h+30}" text-anchor="middle" font-family="monospace" font-size="14">{low:.2f}</text>',
        f'<text x="{left+plot_w}" y="{top+plot_h+30}" text-anchor="middle" font-family="monospace" font-size="14">{high:.2f}</text>',
        '</svg>',
    ])
    path.write_text("\n".join(out) + "\n", encoding="utf-8")


def record(args: argparse.Namespace) -> int:
    global _STOP
    _STOP = False
    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)
    prefix: Path = args.prefix
    prefix.parent.mkdir(parents=True, exist_ok=True)
    paths = {
        "json": Path(str(prefix) + ".json"),
        "csv": Path(str(prefix) + ".csv"),
        "lists": Path(str(prefix) + "_python_lists.txt"),
        "power_svg": Path(str(prefix) + "_timeseries.svg"),
        "energy_svg": Path(str(prefix) + "_energy_timeseries.svg"),
        "hist_svg": Path(str(prefix) + "_histogram.svg"),
    }
    start_wall_ns = time.time_ns()
    start_mono_ns = time.monotonic_ns()
    interval_ns = int(args.interval_ms * 1_000_000)
    next_sample_ns = start_mono_ns
    samples: list[dict[str, Any]] = []
    problems: list[str] = []
    source = "unavailable"
    source_detail = ""

    while not _STOP:
        now_ns = time.monotonic_ns()
        if args.duration_s is not None and (now_ns - start_mono_ns) / 1e9 >= args.duration_s:
            break
        if now_ns < next_sample_ns:
            time.sleep(min(0.05, (next_sample_ns - now_ns) / 1e9))
            continue
        mono_ns, wall_ns = time.monotonic_ns(), time.time_ns()
        try:
            watts, source, source_detail = read_power(args.sensor_match, args.sensor_occurrence)
            samples.append({
                "sample_index": len(samples),
                "wall_ns": wall_ns,
                "monotonic_ns": mono_ns,
                "elapsed_s": (mono_ns - start_mono_ns) / 1e9,
                "power_w": watts,
                "source_line": source_detail,
            })
        except RuntimeError as exc:
            message = str(exc)
            if not problems or problems[-1] != message:
                problems.append(message)
        next_sample_ns += interval_ns
        if next_sample_ns <= mono_ns:
            next_sample_ns = mono_ns + interval_ns

    final_mono_ns, final_wall_ns = time.monotonic_ns(), time.time_ns()
    if not samples or final_mono_ns - int(samples[-1]["monotonic_ns"]) >= 1_000_000:
        try:
            watts, source, source_detail = read_power(args.sensor_match, args.sensor_occurrence)
            samples.append({
                "sample_index": len(samples),
                "wall_ns": final_wall_ns,
                "monotonic_ns": final_mono_ns,
                "elapsed_s": (final_mono_ns - start_mono_ns) / 1e9,
                "power_w": watts,
                "source_line": source_detail,
            })
        except RuntimeError as exc:
            message = str(exc)
            if not problems or problems[-1] != message:
                problems.append(message)

    powers = [float(row["power_w"]) for row in samples]
    times = [float(row["elapsed_s"]) for row in samples]
    cumulative = cumulative_energy(samples)
    energy_j = cumulative[-1] if cumulative else None
    covered_s = times[-1] - times[0] if len(times) >= 2 else 0.0
    average = energy_j / covered_s if energy_j is not None and covered_s > 0 else (powers[0] if len(powers) == 1 else None)
    duration_ms = (times[-1] if times else 0.0) * 1000.0

    power_plot = energy_plot = None
    if samples:
        power_plot = write_line_svg(
            paths["power_svg"], kind="power",
            title=f"GreenQUIC {args.role} whole-system power over time",
            y_label="Power [W]",
            series=[{"label": "power1", "points": [(t * 1000.0, p) for t, p in zip(times, powers)]}],
            duration_ms=duration_ms, step=False, y_value_format=".2f",
        )
        energy_plot = write_line_svg(
            paths["energy_svg"], kind="power",
            title=f"GreenQUIC {args.role} cumulative whole-system energy",
            y_label="Cumulative energy [J]",
            series=[{"label": "integrated energy", "points": [(t * 1000.0, e) for t, e in zip(times, cumulative)]}],
            duration_ms=duration_ms, step=False, y_value_format=".2f",
        )
        histogram_svg(paths["hist_svg"], args.role, powers)

    output: dict[str, Any] = {
        "schema": "greenquic-power1-trace-v2",
        "label": args.label,
        "role": args.role,
        "sensor_kind": "whole-system power1 (lm-sensors or hwmon)",
        "source": source,
        "source_detail_last": source_detail,
        "sensor_match": args.sensor_match,
        "sensor_occurrence": args.sensor_occurrence,
        "start_wall_ns": start_wall_ns,
        "end_wall_ns": time.time_ns(),
        "elapsed_s": (time.monotonic_ns() - start_mono_ns) / 1e9,
        "sample_interval_ms_requested": args.interval_ms,
        "sample_count": len(samples),
        "time_s_series": times,
        "power_w_series": powers,
        "cumulative_energy_j_series": cumulative,
        "samples": samples,
        "estimated_energy_j_trapezoidal": energy_j,
        "integration_covered_s": covered_s,
        "average_power_w_time_weighted": average,
        "power_w_min": min(powers) if powers else None,
        "power_w_max": max(powers) if powers else None,
        "power_w_mean_samples": statistics.fmean(powers) if powers else None,
        "power_w_median": statistics.median(powers) if powers else None,
        "power_w_p95": percentile(powers, 0.95),
        "plot": None if power_plot is None else {
            "width_px": power_plot.width,
            "height_px": power_plot.height,
            "x_tick_ms": power_plot.tick_ms,
            "x_label_ms": power_plot.label_ms,
            "min_px_per_tick": power_plot.min_px_per_tick,
        },
        "problems": problems,
        "measurement_note": (
            "power1 is whole-system/board power, not CPU package RAPL. Energy is "
            "trapezoidal integration of timestamped power samples. The 10 ms axis "
            "grid is display resolution and does not imply 10 ms power sampling."
        ),
    }
    paths["json"].write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")
    with paths["csv"].open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=[
            "sample_index", "elapsed_s", "wall_ns", "power_w", "cumulative_energy_j", "source_line"
        ])
        writer.writeheader()
        for row, energy in zip(samples, cumulative):
            writer.writerow({
                "sample_index": row["sample_index"], "elapsed_s": row["elapsed_s"],
                "wall_ns": row["wall_ns"], "power_w": row["power_w"],
                "cumulative_energy_j": energy, "source_line": row["source_line"],
            })
    paths["lists"].write_text(
        "time_s = " + repr(times) + "\n" +
        "power_w = " + repr(powers) + "\n" +
        "cumulative_energy_j = " + repr(cumulative) + "\n",
        encoding="utf-8",
    )
    return 0 if samples else 4


def shown(value: object, digits: int = 3) -> str:
    if value is None:
        return "unavailable"
    return f"{float(value):.{digits}f}"


def summary(args: argparse.Namespace) -> int:
    data = json.loads(args.input.read_text(encoding="utf-8"))
    times = data.get("time_s_series") or []
    duration = float(times[-1]) - float(times[0]) if times else None
    plot = data.get("plot") or {}
    print("\n=== GreenQUIC Power and Energy Summary ===")
    print(f"- Role: {data.get('role')}")
    print("- Sensor: power1, whole-system/board power; not package RAPL")
    print(f"- Samples: {data.get('sample_count', 0)}")
    print(f"- Actual sample interval requested: {data.get('sample_interval_ms_requested')} ms")
    print(f"- Trace duration: {shown(duration)} s")
    print(f"- Estimated cumulative energy: {shown(data.get('estimated_energy_j_trapezoidal'))} J")
    print(f"- Time-weighted average power: {shown(data.get('average_power_w_time_weighted'))} W")
    print(f"- Power range: {shown(data.get('power_w_min'))}–{shown(data.get('power_w_max'))} W")
    print(f"- Median / P95: {shown(data.get('power_w_median'))} / {shown(data.get('power_w_p95'))} W")
    if plot:
        print(f"- Plot size: {plot.get('width_px')} × {plot.get('height_px')} px")
        print(f"- X-axis minor tick: {plot.get('x_tick_ms')} ms")
        print(f"- X-axis labeled tick: {plot.get('x_label_ms')} ms")
    print("- Note: axis tick spacing does not change the sensor sampling interval")
    print()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    rec = sub.add_parser("record")
    rec.add_argument("--role", choices=("server", "client"), required=True)
    rec.add_argument("--label", default="")
    rec.add_argument("--prefix", type=Path, required=True)
    rec.add_argument("--interval-ms", type=int, default=1000)
    rec.add_argument("--sensor-match", default="power1")
    rec.add_argument("--sensor-occurrence", choices=("first", "last"), default="last")
    rec.add_argument("--duration-s", type=float)
    show = sub.add_parser("summary")
    show.add_argument("--input", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "record":
        if args.interval_ms < 50:
            parser.error("--interval-ms must be at least 50; lm-sensors is not a reliable 10 ms sampler")
        return record(args)
    return summary(args)


if __name__ == "__main__":
    raise SystemExit(main())
PY
chmod +x "$POWER_TRACE"

cat > "$GOODPUT" <<'PY'
#!/usr/bin/env python3
"""Calculate GreenQUIC payload goodput from the client download interval."""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


def calculate(payload_bytes: int, duration_s: float) -> dict[str, float]:
    if payload_bytes <= 0 or duration_s <= 0:
        raise ValueError("payload bytes and duration must be positive")
    bps = payload_bytes * 8.0 / duration_s
    return {
        "duration_s": duration_s,
        "goodput_bps": bps,
        "goodput_mbps_decimal": bps / 1e6,
        "goodput_gbps_decimal": bps / 1e9,
    }


def derive_log(energy: Path, mode: str) -> Path | None:
    match = re.fullmatch(rf"client_energy_{re.escape(mode)}_(.+)\.json", energy.name)
    logs = energy.parent.parent / "logs"
    if match:
        exact = logs / f"client_{mode}_{match.group(1)}.log"
        if exact.is_file():
            return exact
    candidates = sorted(logs.glob(f"client_{mode}_*.log"), key=lambda p: p.stat().st_mtime_ns, reverse=True)
    return candidates[0] if candidates else None


def parse_log(path: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8", errors="replace")
    transmission = [int(v) for v in re.findall(r"(?mi)^\s*transmission time \[us\]:\s*(\d+)\s*$", text)]
    completions = [
        {"file": name.strip(), "duration_ms": int(ms)}
        for name, ms in re.findall(r"(?m)^\s*(.+?):\s*Completed download!\s*\((\d+)\s*ms\)\s*$", text)
    ]
    return {"transmission_us": transmission, "completions": completions}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--energy", type=Path, required=True)
    parser.add_argument("--client-log", type=Path)
    parser.add_argument("--bytes", type=int, required=True)
    parser.add_argument("--mode", required=True)
    parser.add_argument("--test-id", required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    log_path = args.client_log or derive_log(args.energy, args.mode)
    parsed = parse_log(log_path) if log_path and log_path.is_file() else {"transmission_us": [], "completions": []}
    transmission = parsed["transmission_us"]
    completions = parsed["completions"]
    if transmission:
        duration_s = transmission[-1] / 1_000_000.0
        source = "client transmission timer, microsecond resolution"
    elif len(completions) == 1:
        duration_s = completions[0]["duration_ms"] / 1000.0
        source = "MsQuic completion timer, millisecond resolution"
    else:
        energy = json.loads(args.energy.read_text(encoding="utf-8"))
        duration_s = float(energy.get("elapsed_s") or 0.0)
        source = "whole client process interval fallback"
    primary = calculate(args.bytes, duration_s)
    cross = None
    if len(completions) == 1:
        cross = calculate(args.bytes, completions[0]["duration_ms"] / 1000.0)
    result = {
        "schema": "greenquic-goodput-v2",
        "test_id": args.test_id,
        "mode": args.mode,
        "definition": "successfully downloaded payload bits divided by client download duration",
        "payload_bytes": args.bytes,
        "payload_gib": args.bytes / (1024 ** 3),
        "timing_source": source,
        "primary": primary,
        "msquic_completion_crosscheck": cross,
        "scope_note": "Protocol headers and retransmitted bytes are excluded.",
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")

    print("\n=== GreenQUIC Goodput Summary ===")
    print(f"- Test: {args.test_id}")
    print(f"- GreenQUIC mode: {args.mode}")
    print(f"- Payload: {result['payload_gib']:.3f} GiB ({args.bytes} bytes)")
    print(f"- Download duration: {primary['duration_s']:.6f} s")
    print(f"- Goodput: {primary['goodput_gbps_decimal']:.6f} Gbit/s")
    print(f"- Goodput: {primary['goodput_mbps_decimal']:.3f} Mbit/s")
    print(f"- Timing source: {source}")
    if cross is not None:
        print(f"- MsQuic completion cross-check: {cross['goodput_gbps_decimal']:.6f} Gbit/s")
    print("- Scope: payload bytes only; protocol headers and retransmissions are excluded")
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
chmod +x "$GOODPUT"

cat > "$SUMMARY" <<'PY'
#!/usr/bin/env python3
"""Write one readable summary for a GreenQUIC run bundle."""
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
        raw.rstrip() for raw in path.read_text(encoding="utf-8", errors="replace").splitlines()
        if raw.strip() and not raw.lstrip().startswith("#")
    ]


def log_details(path: Path | None) -> dict[str, Any]:
    if path is None or not path.is_file():
        return {}
    text = path.read_text(encoding="utf-8", errors="replace")
    transmission = [int(v) for v in re.findall(r"(?mi)^\s*transmission time \[us\]:\s*(\d+)\s*$", text)]
    completions = [(name.strip(), int(ms)) for name, ms in re.findall(
        r"(?m)^\s*(.+?):\s*Completed download!\s*\((\d+)\s*ms\)\s*$", text
    )]
    return {
        "transmission_us": transmission[-1] if transmission else None,
        "completions": completions,
        "idle_modes": sorted(set(re.findall(r"\bidle_mode=([^\s]+)", text))),
        "epoll_try": max([int(v) for v in re.findall(r"\bepoll_try=(\d+)", text)] or [0]),
        "epoll_wake": max([int(v) for v in re.findall(r"\bepoll_wake=(\d+)", text)] or [0]),
        "epoll_timeout": max([int(v) for v in re.findall(r"\bepoll_timeout=(\d+)", text)] or [0]),
        "freq_actions": sorted(set(re.findall(r"policy_action=([^\s]+)", text))),
    }


def append_config(lines: list[str], title: str, rows: list[str]) -> None:
    lines.extend(["", title, "-" * len(title)])
    if rows:
        lines.extend(f"- {row}" for row in rows)
    else:
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

    folder = args.run_dir
    power = read_json(first(folder, f"{args.stem}_power.json"))
    freq = read_json(first(folder, f"{args.stem}_frequency.json"))
    manifest = read_json(first(folder, f"{args.stem}_download_manifest.json"))
    goodput = read_json(first(folder, f"{args.stem}_goodput*.json"))
    rapl = read_json(first(folder, f"{args.stem}_rapl.json"))
    log = log_details(first(folder, f"{args.stem}_log.txt"))

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
            lines.append(f"- MsQuic completion cross-check: {fmt(cross.get('goodput_gbps_decimal'), 6)} Gbit/s")
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

    power_plot = power.get("plot") or {}
    lines.extend([
        "",
        "Whole-system Power and Energy",
        "-----------------------------",
        "- Sensor: power1 from lm-sensors/sysfs",
        "- Scope: whole-system/board power, not CPU-package RAPL",
        f"- Samples: {power.get('sample_count', 0)}",
        f"- Actual sampling interval requested: {power.get('sample_interval_ms_requested', 'unavailable')} ms",
        f"- Estimated cumulative energy: {fmt(power.get('estimated_energy_j_trapezoidal'), 3)} J",
        f"- Time-weighted average power: {fmt(power.get('average_power_w_time_weighted'), 3)} W",
        f"- Minimum / median / P95 / maximum: {fmt(power.get('power_w_min'))} / {fmt(power.get('power_w_median'))} / {fmt(power.get('power_w_p95'))} / {fmt(power.get('power_w_max'))} W",
        f"- Time-series plot size: {power_plot.get('width_px', 'unavailable')} × {power_plot.get('height_px', 'unavailable')} px",
        f"- Time-axis minor tick: {power_plot.get('x_tick_ms', 'unavailable')} ms",
        f"- Time-axis labeled tick: {power_plot.get('x_label_ms', 'unavailable')} ms",
    ])

    freq_plot = freq.get("plot") or {}
    lines.extend([
        "",
        "CPU Frequency",
        "-------------",
        f"- CPUs observed: {', '.join(str(v) for v in freq.get('cpus', [])) or 'none'}",
        f"- Timestamped frequency events: {freq.get('event_count', 0)}",
        f"- Minimum observed frequency: {fmt((freq.get('min_freq_khz') or 0) / 1e6 if freq.get('min_freq_khz') else None, 3)} GHz",
        f"- Maximum observed frequency: {fmt((freq.get('max_freq_khz') or 0) / 1e6 if freq.get('max_freq_khz') else None, 3)} GHz",
        f"- Frequency actions: {', '.join(log.get('freq_actions', [])) or 'none'}",
        f"- Time-series plot size: {freq_plot.get('width_px', 'unavailable')} × {freq_plot.get('height_px', 'unavailable')} px",
        f"- Time-axis minor tick: {freq_plot.get('x_tick_ms', 'unavailable')} ms",
        f"- Time-axis labeled tick: {freq_plot.get('x_label_ms', 'unavailable')} ms",
    ])

    lines.extend([
        "",
        "Idle and Wake Behavior",
        "----------------------",
        f"- Idle modes observed: {', '.join(log.get('idle_modes', [])) or 'none'}",
        f"- EPOLL attempts: {log.get('epoll_try', 0)}",
        f"- EPOLL wakeups: {log.get('epoll_wake', 0)}",
        f"- EPOLL timeouts: {log.get('epoll_timeout', 0)}",
    ])

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
        "- A 10 ms x-axis tick is a display grid, not a 10 ms power-sampling claim.",
        "- Frequency timestamps are captured when each complete log row reaches the wrapper.",
        "- Goodput counts application payload bytes only; protocol overhead and retransmissions are excluded.",
        f"- Package RAPL available: {'yes' if rapl.get('rapl_available') else 'no'}",
    ])

    append_config(lines, "Effective DPDK Configuration", config_rows(first(folder, f"{args.stem}_dpdk_config.txt")))
    append_config(lines, "Effective Power Configuration", config_rows(first(folder, f"{args.stem}_powermng_config.txt")))
    append_config(lines, "Test Configuration Snapshot", config_rows(first(folder, f"{args.stem}_test_config.txt")))
    append_config(lines, "Environment Overrides", config_rows(first(folder, f"{args.stem}_environment.txt")))
    lines.append("")

    summary_path = folder / f"{args.stem}_summary.txt"
    summary_path.write_text("\n".join(lines), encoding="utf-8")
    print("\n" + "\n".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
chmod +x "$SUMMARY"

cat > "$BUNDLER" <<'PY'
#!/usr/bin/env python3
"""Collect one GreenQUIC run into one consistently named folder."""
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
    return max(rows, key=lambda p: p.stat().st_mtime_ns) if rows else None


def environment_rows() -> list[str]:
    exact = {
        "WORK_WAIT_MIN_LEVEL", "WORK_WAIT_MIN_IDLE_US", "IDLE_WATCHDOG_US",
        "ENABLE_FREQ", "ENABLE_SLEEP", "ENABLE_CSTATE_IDLE", "ENABLE_MULTICORE",
        "RX_EMPTY_POLLS", "TX_EMPTY_POLLS", "PRESSURE_MAX", "PRESSURE_UP", "PRESSURE_KEEP",
        "FREQ_UP_PERIOD_US", "FREQ_DOWN_PERIOD_US", "FREQ_MIN_IDLE_US",
        "GQ_LOG_LEVEL", "GQ_STATS_PERIOD_US", "GQ_CLEANUP_DOWNLOADED_FILES",
        "GQ_POWER_SAMPLE_INTERVAL_MS", "GQ_POWER_SENSOR_MATCH", "GQ_POWER_SENSOR_OCCURRENCE",
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
    if role == "client":
        candidates.extend(result_root.glob(f"client_download_manifest_{mode}_*.json"))
    source = latest(list(candidates))
    if source is None:
        raise SystemExit("ERROR: cannot determine the run timestamp")
    for prefix in (f"{role}_power_{mode}_", f"client_download_manifest_{mode}_"):
        if source.name.startswith(prefix):
            return source.name[len(prefix):-5]
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
    suffix = 1
    while run_dir.exists():
        run_dir = result_root / f"{run_name}__retry{suffix}"
        suffix += 1
    run_dir.mkdir(parents=True)
    stem = run_dir.name

    raw_log = log_root / f"{args.role}_{args.mode}_{stamp}.log"
    timeline = log_root / f"{args.role}_{args.mode}_{stamp}_timeline.jsonl"
    move(raw_log, run_dir / f"{stem}_log.txt")
    move(timeline, run_dir / f"{stem}_timeline.jsonl")
    move(result_root / f"{args.role}_{args.mode}_{stamp}_v21_stats.csv", run_dir / f"{stem}_stats.csv")

    power_prefix = result_root / f"{args.role}_power_{args.mode}_{stamp}"
    move(Path(str(power_prefix) + ".json"), run_dir / f"{stem}_power.json")
    move(Path(str(power_prefix) + ".csv"), run_dir / f"{stem}_power.csv")
    move(Path(str(power_prefix) + "_python_lists.txt"), run_dir / f"{stem}_power_lists.txt")
    move(Path(str(power_prefix) + "_timeseries.svg"), run_dir / f"{stem}_power_timeseries.svg")
    move(Path(str(power_prefix) + "_energy_timeseries.svg"), run_dir / f"{stem}_energy_timeseries.svg")
    move(Path(str(power_prefix) + "_histogram.svg"), run_dir / f"{stem}_power_histogram.svg")
    move(Path(str(power_prefix) + "_sampler.log"), run_dir / f"{stem}_power_sampler.txt")
    move(result_root / f"{args.role}_energy_{args.mode}_{stamp}.json", run_dir / f"{stem}_rapl.json")

    if args.role == "client":
        manifest = result_root / f"client_download_manifest_{args.mode}_{stamp}.json"
        if not manifest.exists():
            manifest = latest(list(result_root.glob(f"client_download_manifest_{args.mode}_*.json")))
        move(manifest, run_dir / f"{stem}_download_manifest.json")
        goodput_rows = sorted(result_root.glob(f"*goodput*{args.mode}*.json"), key=lambda p: p.stat().st_mtime_ns, reverse=True)
        if goodput_rows:
            move(goodput_rows[0], run_dir / f"{stem}_goodput.json")

    copy(runtime / "dpdk.ini", run_dir / f"{stem}_dpdk_config.txt")
    copy(runtime / "powermng.ini", run_dir / f"{stem}_powermng_config.txt")
    copy(test_dir / "config.env", run_dir / f"{stem}_test_config.txt")
    (run_dir / f"{stem}_environment.txt").write_text("\n".join(environment_rows()) + "\n", encoding="utf-8")

    timeline_in_bundle = run_dir / f"{stem}_timeline.jsonl"
    if timeline_in_bundle.is_file():
        frequency_prefix = run_dir / f"{stem}_frequency"
        subprocess.run([
            "python3", str(Path(__file__).with_name("frequency_trace.py")),
            "--timeline", str(timeline_in_bundle),
            "--prefix", str(frequency_prefix),
            "--role", args.role,
        ], check=True)

    metadata = {
        "schema": "greenquic-run-bundle-v2",
        "test_id": os.environ.get("TEST_ID", test_name.split("_", 1)[0]),
        "test_name": test_name,
        "role": args.role,
        "mode": args.mode,
        "stamp": stamp,
        "stem": stem,
    }
    (run_dir / f"{stem}_metadata.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    subprocess.run([
        "python3", str(Path(__file__).with_name("write_run_summary.py")),
        "--run-dir", str(run_dir), "--role", args.role, "--mode", args.mode,
        "--test-id", metadata["test_id"], "--test-name", test_name,
        "--stamp", stamp, "--stem", stem,
    ], check=True)
    print(f"\n[GreenQUIC-Test] Run result folder created: {run_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
chmod +x "$BUNDLER"

python3 - "$GQ_COMMON" "$P0" "$P1" "$P2" "$MARKER" <<'PY'
from __future__ import annotations

from pathlib import Path
import re
import sys

common_path, p0_path, p1_path, p2_path = map(Path, sys.argv[1:5])
marker = sys.argv[5]
text = common_path.read_text(encoding="utf-8")

# Replace client download accounting and cleanup. Client sinks may be /dev/null
# symlinks, so logical bytes come from the successfully completed server object.
start = text.find("write_client_download_manifest() {")
cleanup = text.find("cleanup_client_downloads() {", start)
run_client = text.find("\nrun_client() {", cleanup)
if min(start, cleanup, run_client) < 0:
    raise SystemExit("ERROR: manifest/cleanup function anchors were not found")

helpers = r'''write_client_download_manifest() {
    local start_wall_ns="$1" out="$2"
    python3 - \
        "$EFFECTIVE_DOWNLOAD_DIR" "$start_wall_ns" "$out" "$TEST_ID" "$WORKLOAD_KIND" \
        "$logf" "$GQ_COMMON_DIR/files/server_root" <<'PY_MANIFEST'
from __future__ import annotations

import json
import os
import re
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
start_ns = int(sys.argv[2])
out = Path(sys.argv[3])
test_id = sys.argv[4]
workload = sys.argv[5]
log_path = Path(sys.argv[6])
server_root = Path(sys.argv[7]).resolve()
text = log_path.read_text(encoding="utf-8", errors="replace") if log_path.is_file() else ""
completions = [
    {"reported_name": name.strip(), "duration_ms": int(ms)}
    for name, ms in re.findall(r"(?m)^\s*(.+?):\s*Completed download!\s*\((\d+)\s*ms\)\s*$", text)
]
rows = []
for completion in completions:
    basename = Path(completion["reported_name"]).name
    candidates = [server_root / basename]
    candidates.extend(server_root.rglob(basename))
    source = next((candidate for candidate in candidates if candidate.is_file()), None)
    if source is None:
        raise SystemExit(f"completed object has no server source file: {basename}")
    sink = root / basename
    if sink.is_symlink():
        sink_kind = "symlink"
        sink_target = str(sink.resolve(strict=False))
    elif sink.is_file():
        sink_kind = "regular_file"
        sink_target = None
    elif sink.exists():
        sink_kind = "other"
        sink_target = None
    else:
        sink_kind = "missing"
        sink_target = None
    rows.append({
        "basename": basename,
        "reported_name": completion["reported_name"],
        "duration_ms": completion["duration_ms"],
        "logical_size_bytes": source.stat().st_size,
        "source_path": str(source),
        "sink_path": str(sink),
        "sink_kind_before_cleanup": sink_kind,
        "sink_target_before_cleanup": sink_target,
    })
data = {
    "schema": "greenquic-client-download-manifest-v2-logical-bytes",
    "test_id": test_id,
    "workload_kind": workload,
    "download_root": str(root),
    "start_wall_ns": start_ns,
    "file_count": len(rows),
    "total_bytes": sum(row["logical_size_bytes"] for row in rows),
    "files": rows,
}
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
print(f"[GreenQUIC-Test] Download accounting: completed={data['file_count']} logical_bytes={data['total_bytes']}")
PY_MANIFEST
}

cleanup_client_downloads() {
    local manifest="$1"
    [[ "${GQ_CLEANUP_DOWNLOADED_FILES:-1}" == 1 ]] || return 0
    python3 - "$manifest" <<'PY_CLEANUP'
from __future__ import annotations

import json
from pathlib import Path
import sys

manifest = Path(sys.argv[1])
data = json.loads(manifest.read_text(encoding="utf-8"))
root = Path(data["download_root"]).resolve()
removed_files = 0
removed_bytes = 0
sinks_ready = 0
for row in data.get("files", []):
    sink = Path(row["sink_path"])
    try:
        sink.parent.resolve().relative_to(root)
    except ValueError:
        raise SystemExit(f"refusing to modify a sink outside the download root: {sink}")
    keep = sink.is_symlink() and sink.resolve(strict=False) == Path("/dev/null")
    if not keep:
        if sink.is_file() and not sink.is_symlink():
            removed_bytes += sink.stat().st_size
            removed_files += 1
        if sink.exists() or sink.is_symlink():
            sink.unlink()
        sink.parent.mkdir(parents=True, exist_ok=True)
        sink.symlink_to("/dev/null")
    sinks_ready += 1
remaining = sum(
    Path(row["sink_path"]).stat().st_size
    for row in data.get("files", [])
    if Path(row["sink_path"]).is_file() and not Path(row["sink_path"]).is_symlink()
)
data["cleanup"] = {
    "removed_regular_files": removed_files,
    "removed_regular_bytes": removed_bytes,
    "regular_bytes_remaining": remaining,
    "sinks_ready": sinks_ready,
    "strategy": "preserve or restore each client output as a /dev/null symlink",
}
manifest.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
print(f"[GreenQUIC-Test] Client storage cleanup: removed_files={removed_files} removed_bytes={removed_bytes} persistent_payload_bytes={remaining}")
PY_CLEANUP
}
'''
text = text[:start] + helpers + text[run_client:]

# Add timestamped log paths.
server_log_anchor = '    local logf="$TEST_DIR/logs/server_${mode}_${stamp}.log"\n'
if server_log_anchor not in text:
    raise SystemExit("ERROR: server log anchor not found")
text = text.replace(
    server_log_anchor,
    server_log_anchor + '    local timelinef="$TEST_DIR/logs/server_${mode}_${stamp}_timeline.jsonl"\n',
    1,
)
client_log_anchor = '    local logf="$TEST_DIR/logs/client_${mode}_${stamp}.log"\n'
if client_log_anchor not in text:
    raise SystemExit("ERROR: client log anchor not found")
text = text.replace(
    client_log_anchor,
    client_log_anchor + '    local timelinef="$TEST_DIR/logs/client_${mode}_${stamp}_timeline.jsonl"\n',
    1,
)

# Replace tee with a wrapper that prints the original row unchanged, writes the
# raw validator log, and records a timestamped JSONL copy.
server_pipe = '        2>&1 | tee "$logf"\n'
if server_pipe not in text:
    raise SystemExit("ERROR: server output-pipeline anchor not found")
text = text.replace(
    server_pipe,
    '        2>&1 | python3 "$GQ_COMMON_DIR/bin/timestamp_tee.py" --raw-log "$logf" --timeline "$timelinef"\n',
    1,
)
client_pipe = '    ) 2>&1 | tee "$logf" || rc=${PIPESTATUS[0]}\n'
if client_pipe not in text:
    raise SystemExit("ERROR: client output-pipeline anchor not found")
text = text.replace(
    client_pipe,
    '    ) 2>&1 | python3 "$GQ_COMMON_DIR/bin/timestamp_tee.py" --raw-log "$logf" --timeline "$timelinef" || rc=${PIPESTATUS[0]}\n',
    1,
)

# The previous failed repair assumed an exact label. Match the real server
# label regardless of the UNSYNCHRONIZED_LISTENER_LIFETIME suffix.
label_match = re.search(r'(?m)^(\s*)GQ_SERVER_LABEL=.*$', text)
if not label_match:
    raise SystemExit("ERROR: server label assignment not found")
label_line_end = text.find("\n", label_match.end())
if label_line_end < 0:
    label_line_end = label_match.end()
insert = '\n    GQ_SERVER_TEST_DIR="$TEST_DIR"'
if 'GQ_SERVER_TEST_DIR="$TEST_DIR"' not in text:
    text = text[:label_line_end] + insert + text[label_line_end:]

# Extend the server EXIT handler and bundle after power/log/energy finalization.
text, count = re.subn(
    r'local check_rc=0 energy_rc=0 power_rc=0(?: bundle_rc=0)?',
    'local check_rc=0 energy_rc=0 power_rc=0 bundle_rc=0',
    text,
    count=1,
)
if count != 1:
    raise SystemExit("ERROR: server finish local-status anchor not found")
energy_line = '        energy_finish "$GQ_SERVER_ESTART" "$GQ_SERVER_EOUT" "$GQ_SERVER_LABEL" || energy_rc=$?\n'
if energy_line not in text:
    raise SystemExit("ERROR: server energy-finish anchor not found")
if '--role server' not in text[text.find('gq_server_finish()'):text.find('trap gq_server_finish')]:
    text = text.replace(
        energy_line,
        energy_line +
        '        python3 "$GQ_COMMON_DIR/bin/bundle_run_results.py" --test-dir "$GQ_SERVER_TEST_DIR" --role server --mode "$GQ_SERVER_MODE" --stamp "$GQ_SERVER_STAMP" || bundle_rc=$?\n',
        1,
    )
status_line = '        [[ "$rc" == 0 && "$energy_rc" != 0 ]] && rc="$energy_rc"\n'
if status_line not in text:
    raise SystemExit("ERROR: server status anchor not found")
if 'bundle_rc" != 0' not in text[text.find('gq_server_finish()'):text.find('trap gq_server_finish')]:
    text = text.replace(
        status_line,
        status_line + '        [[ "$rc" == 0 && "$bundle_rc" != 0 ]] && rc="$bundle_rc"\n',
        1,
    )

text += f"\n# {marker}\n"
common_path.write_text(text, encoding="utf-8")

# Append bundling after each pretest's own validation/goodput code. Remove any
# older bundle block first so the retry is deterministic.
def append_bundle(path: Path, mode: str) -> None:
    body = path.read_text(encoding="utf-8")
    body = re.sub(
        r'\n# GREENQUIC-V22-RUN-BUNDLE-V1\npython3 .*?bundle_run_results\.py.*?(?=\Z)',
        '', body, flags=re.S,
    )
    body = re.sub(
        r'\n# GREENQUIC-V22-RUN-BUNDLE-V2\npython3 .*?bundle_run_results\.py.*?(?=\Z)',
        '', body, flags=re.S,
    )
    body = body.rstrip() + f'''\n\n# GREENQUIC-V22-RUN-BUNDLE-V2
python3 "$HERE/../../../common/bin/bundle_run_results.py" \\
    --test-dir "$HERE" --role client --mode "{mode}"
'''
    path.write_text(body, encoding="utf-8")

append_bundle(p0_path, "off")
append_bundle(p1_path, "off")
append_bundle(p2_path, "basic")
PY

python3 -m py_compile \
    "$PLOT_UTILS" "$TIMESTAMP_TEE" "$FREQ_TRACE" "$POWER_TRACE" \
    "$GOODPUT" "$BUNDLER" "$SUMMARY"
bash -n "$GQ_COMMON" "$P0" "$P1" "$P2"

grep -Fq "$MARKER" "$GQ_COMMON" || {
    echo "ERROR: repair marker was not installed" >&2
    exit 1
}

cat <<'EOF'

PASS: GreenQUIC V22 results, goodput and time-series repair installed.

Default plot controls:
  GQ_PLOT_WIDTH_PX=24000
  GQ_PLOT_HEIGHT_PX=700
  GQ_PLOT_X_TICK_MS=10
  GQ_PLOT_X_LABEL_MS=100
  GQ_PLOT_MIN_PX_PER_TICK=12
  GQ_PLOT_MAX_WIDTH_PX=120000

The 10 ms tick is the SVG time-axis grid. Actual power samples still use
GQ_POWER_SAMPLE_INTERVAL_MS, which defaults to 1000 ms.

No MsQuic C source was changed, so no rebuild is required.
EOF
