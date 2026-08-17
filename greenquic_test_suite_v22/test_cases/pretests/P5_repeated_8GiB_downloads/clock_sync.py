#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import select
import statistics
import subprocess
import sys
import time
from pathlib import Path

REMOTE_PROBE = r'''python3 -u -c 'import json,sys,time
print("READY", flush=True)
for _ in sys.stdin:
    print(json.dumps({"wall_ns":time.time_ns(),"monotonic_ns":time.monotonic_ns()}), flush=True)' '''
FINAL_RE = re.compile(r"\[GreenQUIC-P5\]\s+request=(\d+)/(\d+)\s+complete_us=.*\bsuccess=1\b")


def _readline_timeout(pipe, timeout_s: float) -> str:
    ready, _, _ = select.select([pipe], [], [], timeout_s)
    if not ready:
        raise TimeoutError("clock-sync remote response timeout")
    line = pipe.readline()
    if not line:
        raise RuntimeError("clock-sync remote probe exited early")
    return line.strip()


def sample_session(proc) -> dict[str, int]:
    wall0 = time.time_ns()
    mono0 = time.monotonic_ns()
    proc.stdin.write("ping\n")
    proc.stdin.flush()
    remote = json.loads(_readline_timeout(proc.stdout, 5.0))
    mono1 = time.monotonic_ns()
    wall1 = time.time_ns()
    rtt = mono1 - mono0
    mono_mid = (mono0 + mono1) // 2
    wall_mid = (wall0 + wall1) // 2
    return {
        "controller_send_wall_ns": wall0,
        "controller_receive_wall_ns": wall1,
        "controller_midpoint_wall_ns": wall_mid,
        "controller_send_monotonic_ns": mono0,
        "controller_receive_monotonic_ns": mono1,
        "controller_midpoint_monotonic_ns": mono_mid,
        "client_wall_ns": int(remote["wall_ns"]),
        "client_monotonic_ns": int(remote["monotonic_ns"]),
        "round_trip_ns": rtt,
        "client_minus_controller_offset_ns": int(remote["wall_ns"]) - wall_mid,
        "client_minus_controller_monotonic_offset_ns": int(remote["monotonic_ns"]) - mono_mid,
        "uncertainty_ns": (rtt + 1) // 2,
    }


def collect(host: str, count: int) -> list[dict[str, int]]:
    command = [
        "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
        f"root@{host}", REMOTE_PROBE,
    ]
    proc = subprocess.Popen(
        command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    try:
        if _readline_timeout(proc.stdout, 15.0) != "READY":
            raise RuntimeError("clock-sync remote probe did not become ready")
        for _ in range(3):
            sample_session(proc)
        return [sample_session(proc) for _ in range(count)]
    finally:
        try:
            if proc.stdin:
                proc.stdin.close()
        except Exception:
            pass
        try:
            proc.wait(timeout=2)
        except Exception:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except Exception:
                proc.kill()


def result_from_samples(host: str, samples: list[dict[str, int]]) -> dict:
    best = min(samples, key=lambda r: r["round_trip_ns"])
    wall = [r["client_minus_controller_offset_ns"] for r in samples]
    mono = [r["client_minus_controller_monotonic_offset_ns"] for r in samples]
    return {
        "schema": "greenquic-p5-clock-sync-v4",
        "controller_host": "idex",
        "client_host": host,
        "method": "single persistent SSH session; 3 warm-up exchanges discarded; minimum-RTT midpoint estimate; direct CLOCK_MONOTONIC mapping",
        "sample_count": len(samples),
        "warmup_count": 3,
        "client_minus_controller_offset_ns": best["client_minus_controller_offset_ns"],
        "round_trip_ns": best["round_trip_ns"],
        "uncertainty_ns": best["uncertainty_ns"],
        "offset_spread_ns": max(wall) - min(wall),
        "median_offset_ns": int(statistics.median(wall)),
        "client_minus_controller_monotonic_offset_ns": best["client_minus_controller_monotonic_offset_ns"],
        "monotonic_uncertainty_ns": best["uncertainty_ns"],
        "monotonic_offset_spread_ns": max(mono) - min(mono),
        "median_monotonic_offset_ns": int(statistics.median(mono)),
        "controller_midpoint_monotonic_ns": best["controller_midpoint_monotonic_ns"],
        "client_monotonic_ns": best["client_monotonic_ns"],
        "samples": samples,
    }


def write_sync(host: str, out: Path, requested_samples: int) -> dict:
    count = max(requested_samples, 25)
    result = result_from_samples(host, collect(host, count))
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(
        "[P5-CLOCK-SYNC] "
        f"client_minus_server_mono_ms={result['client_minus_controller_monotonic_offset_ns']/1e6:.3f} "
        f"rtt_ms={result['round_trip_ns']/1e6:.3f} "
        f"uncertainty_ms={result['monotonic_uncertainty_ns']/1e6:.3f} "
        f"spread_ms={result['monotonic_offset_spread_ns']/1e6:.3f}",
        flush=True,
    )
    return result


def end_output_for(start_out: Path) -> Path:
    stem = start_out.stem
    if stem.startswith("clock_sync_"):
        stem = "clock_sync_end_" + stem[len("clock_sync_"):]
    else:
        stem = stem + "_end"
    return start_out.with_name(stem + start_out.suffix)


def client_log_for(start_out: Path) -> Path | None:
    stem = start_out.stem
    if not stem.startswith("clock_sync_"):
        return None
    run_id = stem[len("clock_sync_"):]
    return start_out.parent / f"client_{run_id}.log"


def final_download_seen(text: str) -> bool:
    for match in FINAL_RE.finditer(text):
        if int(match.group(1)) == int(match.group(2)):
            return True
    return False


def follow_until_final(host: str, out: Path, samples: int, log_path: Path, timeout_s: float) -> int:
    try:
        cpu = int(os.environ.get("P5_CLOCK_SYNC_FOLLOW_CPU", "0"))
        os.sched_setaffinity(0, {cpu})
    except Exception:
        pass

    deadline = time.monotonic() + timeout_s
    offset = 0
    while time.monotonic() < deadline:
        try:
            if log_path.is_file():
                with log_path.open("r", encoding="utf-8", errors="replace") as handle:
                    handle.seek(offset)
                    chunk = handle.read()
                    offset = handle.tell()
                if chunk and final_download_seen(chunk):
                    write_sync(host, out, samples)
                    return 0
        except OSError:
            pass
        time.sleep(0.10)
    return 5


def spawn_post_sync(host: str, start_out: Path, samples: int, timeout_s: float) -> None:
    log_path = client_log_for(start_out)
    if log_path is None:
        return
    end_out = end_output_for(start_out)
    command = [
        sys.executable,
        str(Path(__file__).resolve()),
        "--host", host,
        "--out", str(end_out),
        "--samples", str(samples),
        "--follow-log", str(log_path),
        "--follow-timeout-s", str(timeout_s),
    ]
    subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        close_fds=True,
    )


def self_test() -> int:
    assert end_output_for(Path("/x/clock_sync_rep01_plus.json")).name == "clock_sync_end_rep01_plus.json"
    assert client_log_for(Path("/x/clock_sync_rep01_plus.json")) == Path("/x/client_rep01_plus.log")
    assert final_download_seen("[GreenQUIC-P5] request=6/6 complete_us=123 path=x duration_us=1 success=1")
    assert not final_download_seen("[GreenQUIC-P5] request=5/6 complete_us=123 path=x duration_us=1 success=1")
    samples = [
        {
            "client_minus_controller_offset_ns": 100,
            "client_minus_controller_monotonic_offset_ns": 200,
            "round_trip_ns": 20,
            "uncertainty_ns": 10,
            "controller_midpoint_monotonic_ns": 1000,
            "client_monotonic_ns": 1200,
        },
        {
            "client_minus_controller_offset_ns": 110,
            "client_minus_controller_monotonic_offset_ns": 210,
            "round_trip_ns": 10,
            "uncertainty_ns": 5,
            "controller_midpoint_monotonic_ns": 2000,
            "client_monotonic_ns": 2210,
        },
    ]
    result = result_from_samples("tinyman", samples)
    assert result["client_minus_controller_monotonic_offset_ns"] == 210
    assert result["controller_midpoint_monotonic_ns"] == 2000
    print("clock_sync self-test PASS")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host")
    ap.add_argument("--out", type=Path)
    ap.add_argument("--samples", type=int, default=25)
    ap.add_argument("--follow-log", type=Path)
    ap.add_argument("--follow-timeout-s", type=float, default=600.0)
    ap.add_argument("--no-post-sync", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test()
    if not args.host or args.out is None:
        raise SystemExit("ERROR: --host and --out are required")
    if args.samples < 1:
        raise SystemExit("ERROR: --samples must be positive")

    if args.follow_log is not None:
        return follow_until_final(args.host, args.out, args.samples, args.follow_log, args.follow_timeout_s)

    write_sync(args.host, args.out, args.samples)
    drift_audit = os.environ.get("GQ_P5_CLOCK_DRIFT_AUDIT", "0").strip().lower() in {"1", "true", "yes", "on"}
    if drift_audit and not args.no_post_sync:
        spawn_post_sync(args.host, args.out, args.samples, args.follow_timeout_s)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
