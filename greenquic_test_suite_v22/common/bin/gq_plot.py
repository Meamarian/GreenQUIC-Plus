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
