#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import signal
import time
from pathlib import Path

EXACT_COMM = {
    "quicinterop",
    "quicinteropserver",
    "gq_rapl_msr_sampler",
    "gq_cstate_trace",
}

CMD_SUBSTRINGS = (
    "/P5_repeated_8GiB_downloads/run_parallel_multicore_matrix.sh",
    "/P7_linux_udp_baseline/run_parallel_multicore_matrix.sh",
    "/P5_repeated_8GiB_downloads/run_matrix_from_idex.sh",
    "/P7_linux_udp_baseline/run_matrix_from_idex.sh",
    "/P5_repeated_8GiB_downloads/run_matrix_with_sheet.sh",
    "/P5_repeated_8GiB_downloads/run_client_parallel_multicore.sh",
    "/P5_repeated_8GiB_downloads/run_server_parallel_multicore.sh",
    "/P7_linux_udp_baseline/run_client_parallel_multicore.sh",
    "/P7_linux_udp_baseline/run_server_parallel_multicore.sh",
    "/P5_repeated_8GiB_downloads/run_role_p5.sh",
    "/tmp/P5_P7_MC_",
    "quic_cpu_activity_sampler.py",
    "frequency_sampler.py",
    "p7_frequency_sampler.py",
    "power_trace.py",
    "clock_sync_parallel.py",
)


def proc_ppid(pid: int) -> int | None:
    try:
        raw = Path(f"/proc/{pid}/stat").read_text(errors="replace")
        close = raw.rfind(")")
        if close < 0:
            return None
        fields = raw[close + 2 :].split()
        return int(fields[1])  # field 4 (ppid), fields[0] is field 3
    except (OSError, ValueError, IndexError):
        return None


def ancestry() -> set[int]:
    out: set[int] = set()
    pid = os.getpid()
    while pid > 1 and pid not in out:
        out.add(pid)
        parent = proc_ppid(pid)
        if parent is None or parent <= 1:
            break
        pid = parent
    return out


def proc_info(pid: int) -> tuple[int | None, str, str]:
    ppid = proc_ppid(pid)
    try:
        comm = Path(f"/proc/{pid}/comm").read_text(errors="replace").strip()
    except OSError:
        comm = ""
    try:
        data = Path(f"/proc/{pid}/cmdline").read_bytes()
        cmd = data.replace(b"\0", b" ").decode(errors="replace").strip()
    except OSError:
        cmd = ""
    return ppid, comm, cmd


def all_processes() -> dict[int, tuple[int | None, str, str]]:
    rows = {}
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        pid = int(p.name)
        rows[pid] = proc_info(pid)
    return rows


def directly_matches(comm: str, cmd: str) -> bool:
    if comm in EXACT_COMM:
        return True
    return any(token in cmd for token in CMD_SUBSTRINGS)


def target_rows() -> list[dict]:
    protected = ancestry() | {1}
    procs = all_processes()
    targets = {
        pid for pid, (_ppid, comm, cmd) in procs.items()
        if pid not in protected and directly_matches(comm, cmd)
    }

    # Include descendants of stale controllers/runners so a shell, tee, ssh,
    # recorder, or child binary cannot survive just because its own argv lacks
    # one of the project markers. Never cross into the current cleanup ancestry.
    changed = True
    while changed:
        changed = False
        for pid, (ppid, _comm, _cmd) in procs.items():
            if pid in protected or pid in targets:
                continue
            if ppid in targets:
                targets.add(pid)
                changed = True

    def depth(pid: int) -> int:
        d = 0
        seen = set()
        while pid in procs and pid not in seen:
            seen.add(pid)
            parent = procs[pid][0]
            if parent is None or parent <= 1:
                break
            pid = parent
            d += 1
        return d

    rows = []
    for pid in sorted(targets, key=lambda x: (depth(x), x), reverse=True):
        ppid, comm, cmd = procs[pid]
        rows.append({"pid": pid, "ppid": ppid, "comm": comm, "cmd": cmd})
    return rows


def send(rows: list[dict], sig: int) -> None:
    for row in rows:
        try:
            os.kill(int(row["pid"]), sig)
        except (ProcessLookupError, PermissionError):
            pass


def clear_gates() -> None:
    for pattern in (
        "/tmp/p5_start_gate_*",
        "/tmp/p7_*.gate",
        "/tmp/P5_P7_MC_*.state.PID",
    ):
        for path in Path("/tmp").glob(Path(pattern).name):
            try:
                path.unlink()
            except OSError:
                pass


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--json", type=Path)
    ap.add_argument("--marker", type=Path)
    ap.add_argument("--grace-seconds", type=float, default=2.0)
    args = ap.parse_args()

    before = target_rows()
    if args.check:
        result = {"host": os.uname().nodename, "targets": before, "status": "PASS" if not before else "FAIL"}
        if args.json:
            args.json.write_text(json.dumps(result, indent=2) + "\n")
        if before:
            for row in before:
                print(f"STALE pid={row['pid']} ppid={row['ppid']} comm={row['comm']} cmd={row['cmd']}")
            return 3
        print(f"SAFE CLEANUP CHECK PASS host={os.uname().nodename}: no stale GreenQUIC/P5/P7 processes")
        return 0

    print(f"SAFE CLEANUP START host={os.uname().nodename} protected_ancestry={sorted(ancestry())}")
    for row in before:
        print(f"TERM pid={row['pid']} ppid={row['ppid']} comm={row['comm']} cmd={row['cmd']}")
    send(before, signal.SIGTERM)
    time.sleep(max(0.0, args.grace_seconds))

    remaining = target_rows()
    for row in remaining:
        print(f"KILL pid={row['pid']} ppid={row['ppid']} comm={row['comm']} cmd={row['cmd']}")
    send(remaining, signal.SIGKILL)
    time.sleep(0.2)
    clear_gates()

    final = target_rows()
    status = "PASS" if not final else "FAIL"
    result = {
        "host": os.uname().nodename,
        "initial_targets": before,
        "after_term_targets": remaining,
        "final_targets": final,
        "status": status,
    }
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(result, indent=2) + "\n")
    if args.marker:
        args.marker.parent.mkdir(parents=True, exist_ok=True)
        args.marker.write_text(status + "\n")

    print(f"SAFE CLEANUP {status} host={os.uname().nodename} initial={len(before)} final={len(final)}")
    if final:
        for row in final:
            print(f"REMAINING pid={row['pid']} ppid={row['ppid']} comm={row['comm']} cmd={row['cmd']}")
        return 4
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
