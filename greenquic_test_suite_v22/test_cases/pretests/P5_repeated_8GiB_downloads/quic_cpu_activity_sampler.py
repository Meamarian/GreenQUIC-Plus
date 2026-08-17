#!/usr/bin/env python3
from __future__ import annotations

"""Measure process CPU-time actually executed on selected QUIC CPUs.

This is intentionally a runtime proof, not an affinity/configuration proof and
not a payload-byte attribution mechanism.  The sampler finds every process
whose /proc/PID/exe resolves to the requested executable, samples all of its
threads, and attributes each thread's CPU-time delta to the Linux `processor`
field reported in /proc/PID/task/TID/stat.  When a thread is restricted to one
CPU through Cpus_allowed_list, that CPU-time is also tracked separately as
`single_cpu_pinned_time_s`.

At finite sampling cadence a migratable thread can move between observations,
so per-CPU time is an activity measurement rather than a scheduler trace.  For
the GreenQUIC multicore validation the important invariant is that every
requested QUIC CPU accumulates non-zero process CPU time while the exact MsQuic
binary is running.
"""

import argparse
import csv
import json
import os
import signal
import sys
import time
from pathlib import Path


def parse_cpu_list(text: str) -> set[int]:
    out: set[int] = set()
    for token in text.strip().replace(" ", "").split(","):
        if not token:
            continue
        if "-" in token:
            a, b = map(int, token.split("-", 1))
            if b < a:
                raise ValueError(f"invalid CPU range: {token}")
            out.update(range(a, b + 1))
        else:
            out.add(int(token))
    return out


def parse_stat(raw: str) -> tuple[int, int, int]:
    """Return utime ticks, stime ticks, last processor from /proc/*/stat."""
    close = raw.rfind(")")
    if close < 0:
        raise ValueError("malformed proc stat")
    fields = raw[close + 2 :].split()
    # fields[0] is field 3 (state). Therefore utime=14 -> 11,
    # stime=15 -> 12, processor=39 -> 36.
    return int(fields[11]), int(fields[12]), int(fields[36])


def allowed_list(status: Path) -> set[int]:
    try:
        for raw in status.read_text(encoding="utf-8", errors="replace").splitlines():
            if raw.startswith("Cpus_allowed_list:"):
                return parse_cpu_list(raw.split(":", 1)[1])
    except OSError:
        pass
    return set()


def matching_pids(executable: Path) -> list[int]:
    target = executable.resolve()
    out: list[int] = []
    for proc in Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        try:
            exe = (proc / "exe").resolve(strict=True)
        except (OSError, RuntimeError):
            continue
        if exe == target:
            out.append(int(proc.name))
    return out


def process_name(pid: int, tid: int) -> str:
    try:
        return Path(f"/proc/{pid}/task/{tid}/comm").read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return ""


def snapshot(executable: Path) -> dict[tuple[int, int], tuple[int, int, set[int], str]]:
    rows: dict[tuple[int, int], tuple[int, int, set[int], str]] = {}
    for pid in matching_pids(executable):
        task = Path(f"/proc/{pid}/task")
        try:
            tids = list(task.iterdir())
        except OSError:
            continue
        for tdir in tids:
            if not tdir.name.isdigit():
                continue
            tid = int(tdir.name)
            try:
                utime, stime, cpu = parse_stat((tdir / "stat").read_text(encoding="utf-8", errors="replace"))
            except (OSError, ValueError, IndexError):
                continue
            rows[(pid, tid)] = (utime + stime, cpu, allowed_list(tdir / "status"), process_name(pid, tid))
    return rows


def write_outputs(
    executable: Path,
    cpus: list[int],
    cpu_ticks: dict[int, int],
    pinned_ticks: dict[int, int],
    sample_hits: dict[int, int],
    tids: dict[int, set[str]],
    seen_pids: set[int],
    samples: int,
    interval_ms: float,
    min_cpu_time_s: float,
    started_ns: int,
    json_path: Path,
    csv_path: Path | None,
) -> dict:
    hz = int(os.sysconf(os.sysconf_names["SC_CLK_TCK"]))
    rows = []
    for cpu in cpus:
        seconds = cpu_ticks[cpu] / hz
        pinned = pinned_ticks[cpu] / hz
        rows.append({
            "cpu": cpu,
            "cpu_time_s": seconds,
            "single_cpu_pinned_time_s": pinned,
            "sample_hits": sample_hits[cpu],
            "active": seconds >= min_cpu_time_s,
            "threads": sorted(tids[cpu]),
        })
    status = "PASS" if seen_pids and all(row["active"] for row in rows) else "FAIL"
    result = {
        "schema": "greenquic-quic-cpu-runtime-activity-v1",
        "executable": str(executable.resolve()),
        "target_cpus": cpus,
        "clock_ticks_per_second": hz,
        "sample_interval_ms": interval_ms,
        "minimum_cpu_time_s_per_cpu": min_cpu_time_s,
        "sample_count": samples,
        "seen_pids": sorted(seen_pids),
        "duration_s": max(0.0, (time.monotonic_ns() - started_ns) / 1e9),
        "semantics": (
            "Process thread CPU-time deltas are attributed to the Linux processor field at each sample. "
            "This proves runtime activity on each requested CPU; it does not directly attribute payload bytes or goodput to a CPU."
        ),
        "rows": rows,
        "status": status,
    }
    json_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    if csv_path is not None:
        csv_path.parent.mkdir(parents=True, exist_ok=True)
        with csv_path.open("w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=[
                "cpu", "cpu_time_s", "single_cpu_pinned_time_s", "sample_hits", "active", "threads"
            ])
            w.writeheader()
            for row in rows:
                w.writerow({
                    **row,
                    "cpu_time_s": f"{row['cpu_time_s']:.6f}",
                    "single_cpu_pinned_time_s": f"{row['single_cpu_pinned_time_s']:.6f}",
                    "active": 1 if row["active"] else 0,
                    "threads": ";".join(row["threads"]),
                })
    return result


def self_test() -> int:
    assert parse_cpu_list("19,21-24") == {19, 21, 22, 23, 24}
    raw = "123 (worker thread) R " + " ".join(str(i) for i in range(3, 53))
    utime, stime, cpu = parse_stat(raw)
    assert utime == 14 and stime == 15 and cpu == 39, (utime, stime, cpu)
    print("quic_cpu_activity_sampler self-test PASS")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", type=Path)
    ap.add_argument("--cpus", default="21,22,23,24")
    ap.add_argument("--json", type=Path)
    ap.add_argument("--csv", type=Path)
    ap.add_argument("--interval-ms", type=float, default=5.0)
    ap.add_argument("--min-cpu-time-s", type=float, default=0.005)
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if args.binary is None or args.json is None:
        raise SystemExit("ERROR: --binary and --json are required")
    if not args.binary.is_file():
        raise SystemExit(f"ERROR: binary not found: {args.binary}")
    cpus = sorted(parse_cpu_list(args.cpus))
    if not cpus:
        raise SystemExit("ERROR: empty --cpus")
    if args.interval_ms <= 0 or args.min_cpu_time_s <= 0:
        raise SystemExit("ERROR: interval/min CPU time must be positive")

    stop = False
    def request_stop(_sig, _frame):
        nonlocal stop
        stop = True
    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)

    hz = int(os.sysconf(os.sysconf_names["SC_CLK_TCK"]))
    cpu_ticks = {cpu: 0 for cpu in cpus}
    pinned_ticks = {cpu: 0 for cpu in cpus}
    sample_hits = {cpu: 0 for cpu in cpus}
    tids = {cpu: set() for cpu in cpus}
    seen_pids: set[int] = set()
    previous: dict[tuple[int, int], tuple[int, int, set[int], str]] = {}
    samples = 0
    started_ns = time.monotonic_ns()

    while not stop:
        current = snapshot(args.binary)
        samples += 1
        for (pid, tid), (ticks, cpu, allowed, name) in current.items():
            seen_pids.add(pid)
            old = previous.get((pid, tid))
            if old is None:
                continue
            delta = ticks - old[0]
            if delta <= 0 or cpu not in cpu_ticks:
                continue
            # Guard against impossible deltas from PID/TID reuse.
            if delta > hz * 10:
                continue
            cpu_ticks[cpu] += delta
            sample_hits[cpu] += 1
            tids[cpu].add(f"{pid}/{tid}:{name}")
            if allowed == {cpu}:
                pinned_ticks[cpu] += delta
        previous = current
        time.sleep(args.interval_ms / 1000.0)

    result = write_outputs(
        args.binary, cpus, cpu_ticks, pinned_ticks, sample_hits, tids,
        seen_pids, samples, args.interval_ms, args.min_cpu_time_s,
        started_ns, args.json, args.csv,
    )
    print("QUIC CPU RUNTIME ACTIVITY", result["status"])
    for row in result["rows"]:
        print(
            f"  CPU{row['cpu']}: cpu_time={row['cpu_time_s']:.6f}s "
            f"single_cpu_pinned={row['single_cpu_pinned_time_s']:.6f}s "
            f"hits={row['sample_hits']} active={int(row['active'])}"
        )
    return 0 if result["status"] == "PASS" else 3


if __name__ == "__main__":
    raise SystemExit(main())
