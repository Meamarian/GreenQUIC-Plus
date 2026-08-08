#!/usr/bin/env python3
"""Write GreenQUIC whole-run and active-transfer summaries."""
from __future__ import annotations

import argparse
import csv
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


def counter_details(path: Path | None) -> dict[str, Any]:
    if path is None or not path.is_file():
        return {}
    try:
        with path.open("r", encoding="utf-8", newline="") as handle:
            row = next(csv.DictReader(handle), None)
    except Exception:
        return {}
    if row is None:
        return {}

    text_fields = {"schema", "source", "mode", "lcores", "idle_mode"}
    result: dict[str, Any] = {}
    for key, value in row.items():
        if key in text_fields:
            result[key] = value or ""
            continue
        try:
            result[key] = int(value or 0)
        except (TypeError, ValueError):
            result[key] = value
    return result


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
    cstate = read_json(first(details, f"{args.stem}_cstate.json"))
    manifest = read_json(first(details, f"{args.stem}_download_manifest.json"))
    goodput = read_json(first(details, f"{args.stem}_goodput*.json"))
    transfer_file = read_json(first(details, f"{args.stem}_transfer_window.json"))
    log = log_details(first(details, f"{args.stem}_log.txt"))
    counters = counter_details(first(details, f"{args.stem}_greenquic_counters.csv"))
    transfer = msr.get("transfer_window") or {}
    whole = msr.get("whole_run") or msr

    repeated_downloads = "repeated" in args.test_name.lower()
    goodput_title = (
        "Goodput — First-RX to Last-TX Workload Window"
        if repeated_downloads else
        "Goodput — Active Transfer Only"
    )

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
        goodput_title,
        "-" * len(goodput_title),
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

    if repeated_downloads and args.role == "client" and transfer_duration > 0:
        lines.append(
            "- Repeated-download note: first-RX → last-TX spans the configured "
            "inter-download gaps. Use the P5 workload summary's aggregate "
            "goodput excluding gaps for transfer-only throughput."
        )

    rapl_transfer_title = (
        "RAPL Energy — First-RX to Last-TX Workload Window"
        if repeated_downloads else
        "RAPL Energy — Active Transfer Only"
    )
    lines.extend([
        "",
        rapl_transfer_title,
        "-" * len(rapl_transfer_title),
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
        source_paths = msr.get("source_paths") or {}
        source_verification = msr.get("source_verification") or {}
        lines.extend([
            f"- Source: {msr.get('source', 'unavailable')}",
            f"- Scope: {msr.get('source_scope', 'CPU package and DRAM RAPL domains')}",
            f"- Package counter: {source_paths.get('package_energy_uj', 'unavailable')}",
            f"- DRAM counter: {source_paths.get('dram_energy_uj', 'unavailable')}",
            f"- Package domain name: {source_verification.get('package_domain_name', 'unavailable')}",
            f"- DRAM domain name: {source_verification.get('dram_domain_name', 'unavailable')}",
            f"- Source validation: {'PASS' if source_verification.get('passed') else 'CHECK REQUIRED'}",
            f"- Power calculation: {msr.get('power_calculation', 'delta energy divided by actual sample time')}",
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
        f"- Source backend: {power.get('source', 'unavailable')}",
        f"- Exact source: {power.get('source_detail_last', 'unavailable')}",
        "- Sensor: power1 from lm-sensors or hwmon sysfs",
        "- Scope: whole-system/board power, not CPU-package RAPL",
        f"- Samples: {power.get('sample_count', 0)}",
        f"- Requested sampling interval: {power.get('sample_interval_ms_requested', 'unavailable')} ms",
        f"- Estimated cumulative energy: {fmt(power.get('estimated_energy_j_trapezoidal'), 3)} J",
        f"- Time-weighted average power: {fmt(power.get('average_power_w_time_weighted'), 3)} W",
        f"- Minimum / median / P95 / maximum: {fmt(power.get('power_w_min'))} / {fmt(power.get('power_w_median'))} / {fmt(power.get('power_w_p95'))} / {fmt(power.get('power_w_max'))} W",
    ])

    rapl_average = whole.get("average_total_power_w")
    board_average = power.get("average_power_w_time_weighted")
    if rapl_average is not None and board_average is not None:
        rapl_average_f = float(rapl_average)
        board_average_f = float(board_average)
        difference_w = board_average_f - rapl_average_f
        ratio = rapl_average_f / board_average_f if board_average_f else None
        lines.extend([
            "",
            "Power-Source Comparison — Whole Test",
            "------------------------------------",
            f"- RAPL package + DRAM average: {rapl_average_f:.3f} W",
            f"- power1 whole-system average: {board_average_f:.3f} W",
            f"- Whole-system minus RAPL: {difference_w:.3f} W",
            f"- RAPL / whole-system ratio: {fmt(ratio, 3)}",
            "- Interpretation: the values should not be equal because RAPL covers package + DRAM while power1 covers the board/system. The comparison is a scope cross-check, not an equality test.",
        ])

    lines.extend([
        "",
        "CPU Frequency",
        "-------------",
        f"- CPUs observed: {', '.join(str(value) for value in freq.get('cpus', [])) or 'none'}",
        f"- Timestamped frequency events: {freq.get('event_count', 0)}",
        f"- Minimum observed frequency: {fmt((freq.get('min_freq_khz') or 0) / 1e6 if freq.get('min_freq_khz') else None, 3)} GHz",
        f"- Maximum observed frequency: {fmt((freq.get('max_freq_khz') or 0) / 1e6 if freq.get('max_freq_khz') else None, 3)} GHz",
    ])

    if counters:
        policy_fields = [
            ("freq_max_hard", "freq_policy_max_hard"),
            ("freq_max_control", "freq_policy_max_control"),
            ("freq_up", "freq_policy_up"),
            ("freq_down", "freq_policy_down"),
            ("freq_min", "freq_policy_min"),
            ("txring_protect_up", "freq_policy_txring_protect_up"),
            ("off_fixed_max", "freq_policy_off_fixed_max"),
        ]
        rendered = ", ".join(
            f"{label}={int(counters.get(field, 0) or 0)}"
            for label, field in policy_fields
        )
        lines.append(f"- Frequency policy decisions: {rendered}")
        lines.append(
            "- Effective DVFS changes: "
            f"max={int(counters.get('freq_changed_max', 0) or 0)}, "
            f"up={int(counters.get('freq_changed_up', 0) or 0)}, "
            f"down={int(counters.get('freq_changed_down', 0) or 0)}, "
            f"min={int(counters.get('freq_changed_min', 0) or 0)}"
        )
        lines.append(
            "- DVFS API unchanged / errors: "
            f"{int(counters.get('freq_unchanged', 0) or 0)} / "
            f"{int(counters.get('freq_error', 0) or 0)}"
        )
    else:
        counts = log.get("freq_action_counts", {})
        if counts:
            rendered = ", ".join(
                f"{name}={counts[name]}" for name in sorted(counts)
            )
            lines.append(f"- Frequency actions (legacy log-derived): {rendered}")
        else:
            lines.append("- Frequency actions: none")

    lines.extend([
        "",
        "QUIC-Side Hint Events",
        "---------------------",
        # GREENQUIC-P5-HINT-COUNTER-SEMANTICS-V1
        "- Semantics: direct QUIC/app hook events; pulse counts are hook invocations, not distinct episodes or periodic samples.",
        f"- ACK_PENDING pulse calls: {int(counters.get('hint_ack_pending', 0) or 0)}",
        f"- CUBIC_CWND_BLOCKED pulse calls (send-allowance evaluations while blocked): {int(counters.get('hint_cubic_cwnd_blocked', 0) or 0)}",
        f"- CUBIC_RECOVERY begin lifecycle events: {int(counters.get('hint_cubic_recovery', 0) or 0)}",
        f"- CUBIC_RECOVERY successful end lifecycle events: {int(counters.get('hint_cubic_recovery_end', 0) or 0)}",
        f"- CUBIC_RAMPING CWND-growth pulse calls: {int(counters.get('hint_cubic_ramping', 0) or 0)}",
        f"- SERVER_FILE_TX_ACTIVE lifecycle begin / end: {int(counters.get('hint_server_file_tx_active', 0) or 0)} / {int(counters.get('hint_server_file_tx_end', 0) or 0)}",
        f"- CLIENT_FILE_RX_ACTIVE lifecycle begin / end: {int(counters.get('hint_client_file_rx_active', 0) or 0)} / {int(counters.get('hint_client_file_rx_end', 0) or 0)}",
        f"- Counter source: {counters.get('source', 'unavailable')}",
    ])

    timeout_count = int(
        counters.get("epoll_timeout", log.get("epoll_timeout", 0)) or 0
    )
    watchdog_us = counters.get("epoll_watchdog_us") or log.get("epoll_watchdog_us")
    idle_mode_value = counters.get("idle_mode")
    idle_mode_text = (
        str(idle_mode_value)
        if idle_mode_value
        else (", ".join(log.get("idle_modes", [])) or "none")
    )
    epoll_try = int(counters.get("epoll_try", log.get("epoll_try", 0)) or 0)
    epoll_wake = int(counters.get("epoll_wake", log.get("epoll_wake", 0)) or 0)
    lines.extend([
        "",
        "Idle and Wake Behavior",
        "----------------------",
        f"- Idle modes observed: {idle_mode_text}",
        f"- EPOLL attempts: {epoll_try}",
        f"- EPOLL wakeups: {epoll_wake}",
        f"- EPOLL RX-interrupt wakeups: {int(counters.get('epoll_rx_wake', 0) or 0)}",
        f"- EPOLL GreenQUIC-control wakeups: {int(counters.get('epoll_control_wake', 0) or 0)}",
        f"- EPOLL signal wakeups: {int(counters.get('epoll_signal_wake', 0) or 0)}",
        f"- RX interrupt-fd drains: {int(counters.get('epoll_rx_fd_drain', 0) or 0)}",
        f"- RX interrupt-fd drain errors: {int(counters.get('epoll_rx_fd_drain_error', 0) or 0)}",
    ])
    if watchdog_us is not None:
        timeout_ms = float(watchdog_us) / 1000.0
        total_s = timeout_count * float(watchdog_us) / 1_000_000.0
        lines.append(
            f"- EPOLL timeouts: {timeout_count} (configured timeout {timeout_ms:.3f} ms each; approximately {total_s:.3f} s total)"
        )
    else:
        lines.append(f"- EPOLL timeouts: {timeout_count}")

    lines.extend(["", "Linux C-state Trace", "-------------------"])
    if cstate:
        per_cpu = cstate.get("per_cpu") or {}
        total_entries = sum(int(v.get("entries", 0) or 0) for v in per_cpu.values())
        total_wakeups = sum(int(v.get("wakeups", 0) or 0) for v in per_cpu.values())
        state_counts = cstate.get("state_interval_counts") or {}
        state_idle_ms = cstate.get("state_total_idle_ms") or {}

        # GREENQUIC-V22-RAW-CSTATE-SUMMARY-FALLBACK-V1 (P5-local)
        if not state_counts:
            recovered_counts: Counter[str] = Counter()
            recovered_idle_ms: dict[str, float] = {}
            for cpu_row in per_cpu.values():
                for state, state_row in (cpu_row.get("states") or {}).items():
                    recovered_counts[str(state)] += int(state_row.get("entries", 0) or 0)
                    recovered_idle_ms[str(state)] = (
                        recovered_idle_ms.get(str(state), 0.0)
                        + float(state_row.get("total_idle_ns", 0) or 0) / 1_000_000.0
                    )
            state_counts = dict(recovered_counts)
            state_idle_ms = recovered_idle_ms
        completed_intervals = cstate.get("completed_idle_intervals")
        if completed_intervals is None and state_counts:
            completed_intervals = sum(int(value) for value in state_counts.values())
        lines.extend([
            f"- Trace clock: {cstate.get('clock', 'unavailable')}",
            f"- CPUs traced: {', '.join(str(v) for v in cstate.get('cpus', [])) or 'none'}",
            f"- cpu_idle entries: {total_entries}",
            f"- Wakeups / idle exits: {total_wakeups}",
            f"- Completed idle intervals: {completed_intervals if completed_intervals is not None else 'unavailable'}",
        ])
        if state_counts:
            rendered = ", ".join(
                f"state {state}={state_counts[state]} intervals/{float(state_idle_ms.get(state, 0.0)):.3f} ms"
                for state in sorted(state_counts, key=lambda value: int(value))
            )
            lines.append(f"- Per-state residency: {rendered}")
    else:
        lines.append("- Disabled or unavailable for this run.")

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
