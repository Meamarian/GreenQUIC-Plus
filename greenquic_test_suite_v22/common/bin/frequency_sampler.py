#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, signal, time
from pathlib import Path

running = True


def stop(_signum, _frame):
    global running
    running = False


def parse_list(value):
    out = set()
    for token in value.replace(" ", "").split(","):
        if not token:
            continue
        if "-" in token:
            a, b = map(int, token.split("-", 1))
            out.update(range(a, b + 1))
        else:
            out.add(int(token))
    return sorted(out)


def config_cpus(path):
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" not in raw:
            continue
        key, value = raw.split("=", 1)
        if key.strip() == "GreenQuicDpdkLcores":
            return parse_list(value)
    raise SystemExit("GreenQuicDpdkLcores missing")


def read_khz(cpu):
    root = Path(f"/sys/devices/system/cpu/cpu{cpu}/cpufreq")
    for name in ("scaling_cur_freq", "cpuinfo_cur_freq"):
        try:
            value = int((root / name).read_text().strip())
            if value > 0:
                return value
        except (OSError, ValueError):
            pass
    return None


def clock_bridge(phase, attempts=9):
    """Return a low-uncertainty MONOTONIC_RAW -> MONOTONIC calibration.

    CLOCK_MONOTONIC_RAW is read immediately before and after CLOCK_MONOTONIC.
    Of several attempts we retain the bracket with the smallest RAW span.
    The RAW timestamp is the bracket midpoint and uncertainty is half the span.
    """
    raw_clock = getattr(time, "CLOCK_MONOTONIC_RAW", None)
    if raw_clock is None:
        return None
    best = None
    for _ in range(max(1, attempts)):
        raw_before = time.clock_gettime_ns(raw_clock)
        mono = time.monotonic_ns()
        raw_after = time.clock_gettime_ns(raw_clock)
        span = max(0, raw_after - raw_before)
        candidate = (span, raw_before, raw_after, mono)
        if best is None or candidate[0] < best[0]:
            best = candidate
    if best is None:
        return None
    span, raw_before, raw_after, mono = best
    raw_mid = (raw_before + raw_after) // 2
    return {
        "type": "clock_bridge",
        "schema": "greenquic-clock-bridge-v1",
        "phase": phase,
        "monotonic_ns": int(mono),
        "monotonic_raw_ns": int(raw_mid),
        "offset_ns": int(mono - raw_mid),
        "uncertainty_ns": int((span + 1) // 2),
        "raw_bracket_span_ns": int(span),
    }


def emit_bridge(out, phase):
    row = clock_bridge(phase)
    if row is not None:
        out.write(json.dumps(row, separators=(",", ":")) + "\n")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--config", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--interval-ms", type=float, default=10.0)
    a = p.parse_args()
    if a.interval_ms <= 0:
        raise SystemExit("interval must be positive")
    cpus = config_cpus(a.config)
    a.output.parent.mkdir(parents=True, exist_ok=True)
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    start = time.monotonic_ns()
    interval = int(a.interval_ms * 1_000_000)
    deadline = start
    with a.output.open("w", encoding="utf-8", buffering=1) as out:
        # GREENQUIC-CLOCK-BRIDGE-V1: this lets report generation map the
        # cpu_idle tracer's mono_raw timestamps into the MONOTONIC domain used
        # by request markers, frequency samples and RAPL samples.
        emit_bridge(out, "start")
        while running:
            now = time.monotonic_ns()
            elapsed = (now - start) / 1e9
            for cpu in cpus:
                khz = read_khz(cpu)
                if khz is not None:
                    out.write(json.dumps({
                        "type": "line",
                        "elapsed_s": elapsed,
                        "line": f"[CPU {cpu}] GreenQUIC RECORD freq_khz={khz}",
                    }, separators=(",", ":")) + "\n")
            deadline += interval
            delay = deadline - time.monotonic_ns()
            if delay > 0:
                time.sleep(delay / 1e9)
            else:
                deadline = time.monotonic_ns()
        emit_bridge(out, "end")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
# GREENQUIC-ENABLE-RECORD-V1
