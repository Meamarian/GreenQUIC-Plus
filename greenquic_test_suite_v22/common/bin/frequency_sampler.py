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
        if not token: continue
        if "-" in token:
            a, b = map(int, token.split("-", 1)); out.update(range(a, b + 1))
        else: out.add(int(token))
    return sorted(out)

def config_cpus(path):
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" not in raw: continue
        key, value = raw.split("=", 1)
        if key.strip() == "GreenQuicDpdkLcores": return parse_list(value)
    raise SystemExit("GreenQuicDpdkLcores missing")

def read_khz(cpu):
    root = Path(f"/sys/devices/system/cpu/cpu{cpu}/cpufreq")
    for name in ("scaling_cur_freq", "cpuinfo_cur_freq"):
        try:
            value = int((root / name).read_text().strip())
            if value > 0: return value
        except (OSError, ValueError): pass
    return None

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--config", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--interval-ms", type=float, default=10.0)
    a = p.parse_args()
    if a.interval_ms <= 0: raise SystemExit("interval must be positive")
    cpus = config_cpus(a.config)
    a.output.parent.mkdir(parents=True, exist_ok=True)
    signal.signal(signal.SIGINT, stop); signal.signal(signal.SIGTERM, stop)
    start = time.monotonic_ns(); interval = int(a.interval_ms * 1_000_000); deadline = start
    with a.output.open("w", encoding="utf-8", buffering=1) as out:
        while running:
            now = time.monotonic_ns(); elapsed = (now - start) / 1e9
            for cpu in cpus:
                khz = read_khz(cpu)
                if khz is not None:
                    out.write(json.dumps({"type":"line","elapsed_s":elapsed,"line":f"[CPU {cpu}] GreenQUIC RECORD freq_khz={khz}"}, separators=(",", ":")) + "\n")
            deadline += interval
            delay = deadline - time.monotonic_ns()
            if delay > 0: time.sleep(delay / 1e9)
            else: deadline = time.monotonic_ns()
    return 0

if __name__ == "__main__": raise SystemExit(main())
# GREENQUIC-ENABLE-RECORD-V1
