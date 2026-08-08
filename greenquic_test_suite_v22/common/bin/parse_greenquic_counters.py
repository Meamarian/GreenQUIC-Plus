#!/usr/bin/env python3
# Aggregate mandatory GreenQUIC process-end counters into one CSV row.
# The C datapath emits these counters regardless of GQ_LOG_LEVEL.

from __future__ import annotations

import argparse
import csv
import re
from pathlib import Path

LINE_RE = re.compile(
    r"\[CPU\s+(?P<cpu>\d+)\]\s+GreenQUIC COUNTERS\s+(?P<body>.*)$"
)
PAIR_RE = re.compile(r"\b([A-Za-z0-9_]+)=([^\s]+)")

SUM_FIELDS = [
    "epoll_try",
    "epoll_wake",
    "epoll_timeout",
    "epoll_rx_wake",
    "epoll_control_wake",
    "epoll_signal_wake",
    "epoll_rx_fd_drain",
    "epoll_rx_fd_drain_error",
    "wake_signal",
    "freq_policy_max_hard",
    "freq_policy_max_control",
    "freq_policy_up",
    "freq_policy_down",
    "freq_policy_min",
    "freq_policy_txring_protect_up",
    "freq_policy_off_fixed_max",
    "freq_changed_max",
    "freq_changed_up",
    "freq_changed_down",
    "freq_changed_min",
    "freq_unchanged",
    "freq_error",
]

HINT_FIELDS = [
    "hint_ack_pending",
    "hint_cubic_cwnd_blocked",
    "hint_cubic_recovery",
    "hint_cubic_recovery_end",
    "hint_cubic_ramping",
    "hint_server_file_tx_active",
    "hint_server_file_tx_end",
    "hint_client_file_rx_active",
    "hint_client_file_rx_end",
]

FIELDNAMES = [
    "schema",
    "source",
    "mode",
    "lcore_rows",
    "lcores",
    "idle_mode",
    "epoll_watchdog_us",
    *SUM_FIELDS,
    *HINT_FIELDS,
]


def as_int(value: str | None) -> int:
    try:
        return int(value or "0", 0)
    except (TypeError, ValueError):
        return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("log", type=Path)
    parser.add_argument("--mode", required=True, choices=("off", "basic", "plus"))
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    text = args.log.read_text(encoding="utf-8", errors="replace")
    rows: list[tuple[int, dict[str, str]]] = []
    for raw in text.splitlines():
        match = LINE_RE.search(raw)
        if match is None:
            continue
        pairs = dict(PAIR_RE.findall(match.group("body")))
        if pairs.get("schema") != "greenquic-counters-v1":
            continue
        rows.append((int(match.group("cpu")), pairs))

    result: dict[str, object] = {
        "schema": "greenquic-counters-csv-v1",
        "source": "process_end_counters" if rows else "off_shell_baseline",
        "mode": args.mode,
        "lcore_rows": len(rows),
        "lcores": ";".join(str(cpu) for cpu in sorted({cpu for cpu, _ in rows})),
        "idle_mode": "none",
        "epoll_watchdog_us": 0,
    }
    for field in SUM_FIELDS + HINT_FIELDS:
        result[field] = 0

    if rows:
        idle_modes = sorted({
            pairs.get("idle_mode", "")
            for _, pairs in rows
            if pairs.get("idle_mode")
        })
        result["idle_mode"] = "+".join(idle_modes) if idle_modes else "unknown"
        result["epoll_watchdog_us"] = max(
            as_int(pairs.get("epoll_watchdog_us")) for _, pairs in rows
        )
        for field in SUM_FIELDS:
            if field == "freq_policy_off_fixed_max":
                continue
            result[field] = sum(as_int(pairs.get(field)) for _, pairs in rows)
        # Hint counters are process-global and repeated per lcore.
        for field in HINT_FIELDS:
            result[field] = max(as_int(pairs.get(field)) for _, pairs in rows)
    elif args.mode != "off":
        raise SystemExit(
            "ERROR: BASIC/PLUS log contains no greenquic-counters-v1 final "
            "record. Rebuild MsQuic after applying the patch."
        )

    # Strict OFF has no GreenQUIC datapath cleanup record by design.
    result["freq_policy_off_fixed_max"] = len(
        re.findall(r"\bpolicy_action=off_fixed_max\b", text)
    )

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDNAMES)
        writer.writeheader()
        writer.writerow(result)

    print(
        f"greenquic_counter_rows={len(rows)} "
        f"mode={args.mode} out={args.out}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
