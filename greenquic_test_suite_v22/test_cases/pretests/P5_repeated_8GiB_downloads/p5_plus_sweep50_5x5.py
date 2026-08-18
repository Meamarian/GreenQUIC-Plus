#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import statistics
import subprocess
import time
from pathlib import Path

PAYLOAD_BYTES = 8589934592
DOWNLOADS = 5
RUNS_PER_CONFIG = 5

# One-factor cases first, then combined policies. Anything not listed in a case
# is left at the normal P5 default. Idle mechanism and fallback are supplied by
# the caller and remain fixed for the complete sweep.
TESTS: list[tuple[str, dict[str, str]]] = [
    ("baseline", {}),
    ("max850", {"PRESSURE_MAX": "850"}),
    ("max800", {"PRESSURE_MAX": "800"}),
    ("max750", {"PRESSURE_MAX": "750"}),
    ("max700", {"PRESSURE_MAX": "700"}),
    ("up500", {"PRESSURE_UP": "500"}),
    ("up450", {"PRESSURE_UP": "450"}),
    ("up350", {"PRESSURE_UP": "350"}),
    ("up250", {"PRESSURE_UP": "250"}),
    ("keep200", {"PRESSURE_KEEP": "200"}),
    ("keep150", {"PRESSURE_KEEP": "150"}),
    ("keep100", {"PRESSURE_KEEP": "100"}),
    ("upPeriod400", {"FREQ_UP_PERIOD_US": "400"}),
    ("upPeriod250", {"FREQ_UP_PERIOD_US": "250"}),
    ("upPeriod125", {"FREQ_UP_PERIOD_US": "125"}),
    ("downPeriod7500", {"FREQ_DOWN_PERIOD_US": "7500"}),
    ("downPeriod10000", {"FREQ_DOWN_PERIOD_US": "10000"}),
    ("downPeriod20000", {"FREQ_DOWN_PERIOD_US": "20000"}),
    ("minIdle30ms", {"FREQ_MIN_IDLE_US": "30000"}),
    ("minIdle50ms", {"FREQ_MIN_IDLE_US": "50000"}),
    ("minIdle100ms", {"FREQ_MIN_IDLE_US": "100000"}),
    ("burstRise625", {
        "RX_BURST_RISE_ALPHA_PERMILLE": "625",
        "TX_BURST_RISE_ALPHA_PERMILLE": "625",
    }),
    ("burstRise750", {
        "RX_BURST_RISE_ALPHA_PERMILLE": "750",
        "TX_BURST_RISE_ALPHA_PERMILLE": "750",
    }),
    ("burstRise1000", {
        "RX_BURST_RISE_ALPHA_PERMILLE": "1000",
        "TX_BURST_RISE_ALPHA_PERMILLE": "1000",
    }),
    ("burstFall375", {
        "RX_BURST_FALL_ALPHA_PERMILLE": "375",
        "TX_BURST_FALL_ALPHA_PERMILLE": "375",
    }),
    ("burstFall250", {
        "RX_BURST_FALL_ALPHA_PERMILLE": "250",
        "TX_BURST_FALL_ALPHA_PERMILLE": "250",
    }),
    ("burstFall125", {
        "RX_BURST_FALL_ALPHA_PERMILLE": "125",
        "TX_BURST_FALL_ALPHA_PERMILLE": "125",
    }),
    ("backlogFall125", {
        "RX_QUEUE_FALL_ALPHA_PERMILLE": "125",
        "TX_RING_FALL_ALPHA_PERMILLE": "125",
    }),
    ("rxQueueHigh48", {"RX_QUEUE_HIGH": "48"}),
    ("rxQueueHigh32", {"RX_QUEUE_HIGH": "32"}),
    ("txRingHigh48", {"TX_RING_HIGH": "48"}),
    ("txRingHigh32", {"TX_RING_HIGH": "32"}),
    ("rxQueueSample32", {"RX_QUEUE_SAMPLE_PERIOD": "32"}),
    ("rxQueueSample16", {"RX_QUEUE_SAMPLE_PERIOD": "16"}),
    ("fullBurst600", {
        "FULL_BURST_COUNT": "4",
        "FULL_BURST_FLOOR": "600",
    }),
    ("fullBurst800", {
        "FULL_BURST_COUNT": "2",
        "FULL_BURST_FLOOR": "800",
    }),
    ("empty75k", {
        "RX_EMPTY_POLLS": "75000",
        "TX_EMPTY_POLLS": "75000",
    }),
    ("empty100k", {
        "RX_EMPTY_POLLS": "100000",
        "TX_EMPTY_POLLS": "100000",
    }),
    ("empty200k", {
        "RX_EMPTY_POLLS": "200000",
        "TX_EMPTY_POLLS": "200000",
    }),
    ("activeSleep8", {"ACTIVE_TRANSFER_SLEEP_MIN_LEVEL": "8"}),
    ("activeSleep16", {"ACTIVE_TRANSFER_SLEEP_MIN_LEVEL": "16"}),
    ("sleepLevelsHigher", {
        "SLEEP_SHORT_MIN_LEVEL": "4",
        "SLEEP_DATA_MIN_LEVEL": "8",
        "SLEEP_DEEP_MIN_LEVEL": "16",
    }),
    ("zeroBoundedSleep", {
        "ACK_SLEEP_US": "0",
        "DATA_SLEEP_US": "0",
        "MAX_SLEEP_US": "0",
    }),
    ("ackAggressive", {
        "ACK_CLIENT_FLOOR": "700",
        "ACK_OTHER_FLOOR": "650",
        "ACK_RX_HARDMAX_THRESHOLD": "800",
    }),
    ("cwndAggressive", {
        "CWND_GROWTH_NO_WORK_FLOOR": "650",
        "CWND_GROWTH_WORK_FLOOR": "700",
        "CWND_GROWTH_PHYSICAL_THRESHOLD": "150",
    }),
    ("recoveryAggressive", {
        "RECOVERY_FLOOR": "800",
        "RECOVERY_HARDMAX_PHYSICAL_THRESHOLD": "500",
    }),
    ("blockedAggressive", {
        "BLOCKED_RX_FLOOR": "600",
        "BLOCKED_SLEEP_GUARD_LEVEL": "4",
    }),
    ("previousStrong", {
        "PRESSURE_MAX": "800",
        "PRESSURE_UP": "350",
        "PRESSURE_KEEP": "150",
        "FREQ_UP_PERIOD_US": "250",
        "FREQ_DOWN_PERIOD_US": "10000",
        "RX_BURST_RISE_ALPHA_PERMILLE": "750",
        "TX_BURST_RISE_ALPHA_PERMILLE": "750",
        "RX_BURST_FALL_ALPHA_PERMILLE": "250",
        "TX_BURST_FALL_ALPHA_PERMILLE": "250",
    }),
    ("strongBacklogIdle", {
        "PRESSURE_MAX": "800",
        "PRESSURE_UP": "350",
        "PRESSURE_KEEP": "150",
        "FREQ_UP_PERIOD_US": "250",
        "FREQ_DOWN_PERIOD_US": "10000",
        "RX_BURST_RISE_ALPHA_PERMILLE": "750",
        "TX_BURST_RISE_ALPHA_PERMILLE": "750",
        "RX_BURST_FALL_ALPHA_PERMILLE": "250",
        "TX_BURST_FALL_ALPHA_PERMILLE": "250",
        "RX_QUEUE_HIGH": "48",
        "TX_RING_HIGH": "48",
        "RX_QUEUE_SAMPLE_PERIOD": "32",
        "RX_EMPTY_POLLS": "100000",
        "TX_EMPTY_POLLS": "100000",
        "ACTIVE_TRANSFER_SLEEP_MIN_LEVEL": "16",
    }),
    ("allAggressive", {
        "PRESSURE_MAX": "750",
        "PRESSURE_UP": "250",
        "PRESSURE_KEEP": "100",
        "FREQ_UP_PERIOD_US": "125",
        "FREQ_DOWN_PERIOD_US": "20000",
        "FREQ_MIN_IDLE_US": "50000",
        "RX_BURST_RISE_ALPHA_PERMILLE": "1000",
        "TX_BURST_RISE_ALPHA_PERMILLE": "1000",
        "RX_BURST_FALL_ALPHA_PERMILLE": "125",
        "TX_BURST_FALL_ALPHA_PERMILLE": "125",
        "RX_QUEUE_FALL_ALPHA_PERMILLE": "125",
        "TX_RING_FALL_ALPHA_PERMILLE": "125",
        "RX_QUEUE_HIGH": "48",
        "TX_RING_HIGH": "48",
        "RX_QUEUE_SAMPLE_PERIOD": "32",
        "FULL_BURST_COUNT": "2",
        "FULL_BURST_FLOOR": "800",
        "RX_EMPTY_POLLS": "100000",
        "TX_EMPTY_POLLS": "100000",
        "ACTIVE_TRANSFER_SLEEP_MIN_LEVEL": "16",
        "SLEEP_SHORT_MIN_LEVEL": "4",
        "SLEEP_DATA_MIN_LEVEL": "8",
        "SLEEP_DEEP_MIN_LEVEL": "16",
        "ACK_CLIENT_FLOOR": "700",
        "ACK_OTHER_FLOOR": "650",
        "ACK_RX_HARDMAX_THRESHOLD": "800",
        "CWND_GROWTH_NO_WORK_FLOOR": "650",
        "CWND_GROWTH_WORK_FLOOR": "700",
        "CWND_GROWTH_PHYSICAL_THRESHOLD": "150",
        "RECOVERY_FLOOR": "800",
        "RECOVERY_HARDMAX_PHYSICAL_THRESHOLD": "500",
        "BLOCKED_RX_FLOOR": "600",
        "BLOCKED_SLEEP_GUARD_LEVEL": "4",
    }),
]

if len(TESTS) != 50:
    raise RuntimeError(f"sweep definition has {len(TESTS)} tests, expected 50")

FIXED_ENV = {
    "ENABLE_RECORD": "1",
    "GQ_CLAIM_DISABLE_ACTIVE_RECORDERS": "0",
    "GQ_CLAIM_RECORDER_CPU": "auto",
    "GQ_LOG_LEVEL": "0",
    "ENABLE_FREQ": "1",
    "ENABLE_SLEEP": "1",
    "ENABLE_PAUSE": "1",
    "KEEP_PAUSE_ITERATIONS": "1",
    "SHORT_PAUSE_ITERATIONS": "1",
    "GQ_IDLE_MODE_OVERRIDE": "monitor",
    "GQ_IDLE_FALLBACK_OVERRIDE": "short",
    "WORK_WAIT_MIN_LEVEL": "1",
    "WORK_WAIT_MIN_IDLE_US": "20000",
    "IDLE_WATCHDOG_US": "1000000",
    "ALLOW_WORK_WAIT_DURING_ACTIVE_TRANSFER": "0",
    "FREQ_PERIOD_US": "10000",
    "NO_SLEEP_IF_TX_RING_NOT_EMPTY": "1",
    "TX_RING_PROTECT_UP": "1",
    "ENABLE_PHYSICAL_HARDMAX": "1",
    "ENABLE_ACK_RX_HARDMAX": "1",
    "ACK_BLOCKS_SLEEP": "1",
    "CWND_GROWTH_BLOCKS_SLEEP": "1",
    "ENABLE_RECOVERY_HARDMAX": "1",
    "RECOVERY_BLOCKS_SLEEP": "1",
    # Keep measurement overhead constant across every case.
    "GQ_POWER_SAMPLE_INTERVAL_MS": "1000",
    "GQ_ENABLE_MSR_TRACE": "1",
    "GQ_MSR_SAMPLE_INTERVAL_MS": "6",
    "GQ_MSR_SMOOTH_SAMPLES": "3",
    "GQ_FREQ_SAMPLE_INTERVAL_MS": "1",
    "GQ_POST_TRANSFER_WAIT_S": "0",
    "ENABLE_MULTICORE": "0",
    "SERVER_DPDK_LCORES": "19",
    "CLIENT_DPDK_LCORES": "19",
    "SERVER_TX_OWNER_LCORE": "19",
    "CLIENT_TX_OWNER_LCORE": "19",
    "SERVER_QUIC_CPUS": "21,22,23,24",
    "CLIENT_QUIC_CPUS": "21,22,23,24",
    "MSQUIC_EXECUTION_PROFILE": "max_throughput",
}


def parse_one_run(path: Path) -> tuple[float, list[float]]:
    text = path.read_text(encoding="utf-8", errors="replace")
    pattern = re.compile(
        r"\[GreenQUIC-P5\] request=(\d+)/5 complete_us=\d+ path=\S+ "
        r"duration_us=(\d+) success=1"
    )
    durations: dict[int, int] = {}
    for match in pattern.finditer(text):
        durations[int(match.group(1))] = int(match.group(2))
    if set(durations) != {1, 2, 3, 4, 5}:
        raise RuntimeError(
            f"missing successful P5 markers in {path.name}: {sorted(durations)}"
        )
    ordered = [durations[i] for i in range(1, DOWNLOADS + 1)]
    per_download = [PAYLOAD_BYTES * 8.0 / duration_us / 1000.0 for duration_us in ordered]
    aggregate = PAYLOAD_BYTES * DOWNLOADS * 8.0 / sum(ordered) / 1000.0

    reported = re.findall(
        r"Aggregate goodput excluding gaps:\s*([0-9.]+)\s+Gbit/s", text
    )
    if reported and abs(float(reported[-1]) - aggregate) > 0.002:
        raise RuntimeError(
            f"goodput cross-check failed: computed={aggregate:.6f}, "
            f"reported={float(reported[-1]):.6f}"
        )
    return aggregate, per_download


def cleanup_failed_case(p5: Path, client_host: str) -> None:
    subprocess.run(
        ["python3", str(p5 / "safe_cleanup_p5_bottleneck_processes.py")],
        cwd=p5,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    subprocess.run(
        [
            "ssh", client_host,
            f"cd {p5} && python3 ./safe_cleanup_p5_bottleneck_processes.py",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def config_text(config: dict[str, str]) -> str:
    if not config:
        return "defaults"
    return " ".join(f"{key}={value}" for key, value in config.items())


def render_summary(rows: list[dict[str, object]]) -> str:
    baseline = next(
        (float(row["mean"]) for row in rows if row["index"] == 1 and row["status"] == "OK"),
        None,
    )
    lines: list[str] = []
    lines.extend(["", "=" * 132, "P5 PLUS 50-CONFIG x 5-RUN GOODPUT SWEEP", "=" * 132])
    header = (
        f"{'TEST':<6}{'CONFIG':<24}{'MEAN':>10}{'STD':>10}{'CV%':>9}"
        f"{'MIN':>10}{'MAX':>10}{'DELTA%':>10}{'STATUS':>10}"
    )
    lines.extend([header, "-" * len(header)])
    for row in rows:
        if row["status"] != "OK":
            lines.append(
                f"T{int(row['index']):02d}   {str(row['name']):<24}"
                f"{'-':>10}{'-':>10}{'-':>9}{'-':>10}{'-':>10}{'-':>10}{'FAIL':>10}"
            )
            continue
        mean_value = float(row["mean"])
        delta = None if baseline is None else (mean_value - baseline) / baseline * 100.0
        delta_text = "N/A" if delta is None else f"{delta:+.2f}"
        lines.append(
            f"T{int(row['index']):02d}   {str(row['name']):<24}"
            f"{mean_value:>10.4f}{float(row['std']):>10.4f}{float(row['cv']):>9.2f}"
            f"{float(row['min']):>10.4f}{float(row['max']):>10.4f}"
            f"{delta_text:>10}{'OK':>10}"
        )

    good = [row for row in rows if row["status"] == "OK"]
    lines.extend(["", "=" * 105, "MEAN GOODPUT BY DOWNLOAD POSITION (5 independent runs)", "=" * 105])
    header2 = f"{'TEST':<6}{'CONFIG':<24}{'D1':>11}{'D2':>11}{'D3':>11}{'D4':>11}{'D5':>11}"
    lines.extend([header2, "-" * len(header2)])
    for row in good:
        d = list(row["download_means"])
        lines.append(
            f"T{int(row['index']):02d}   {str(row['name']):<24}"
            + "".join(f"{float(value):>11.4f}" for value in d)
        )

    ranked = sorted(good, key=lambda row: float(row["mean"]), reverse=True)
    lines.extend(["", "=" * 100, "TOP 10 BY 5-RUN MEAN ACTIVE GOODPUT", "=" * 100])
    top_header = (
        f"{'RANK':<6}{'TEST':<7}{'CONFIG':<28}{'MEAN':>11}{'STD':>11}{'CV%':>9}{'DELTA%':>11}"
    )
    lines.extend([top_header, "-" * len(top_header)])
    for rank, row in enumerate(ranked[:10], 1):
        mean_value = float(row["mean"])
        delta = None if baseline is None else (mean_value - baseline) / baseline * 100.0
        delta_text = "N/A" if delta is None else f"{delta:+.2f}"
        lines.append(
            f"{rank:<6}T{int(row['index']):02d}   {str(row['name']):<28}"
            f"{mean_value:>11.4f}{float(row['std']):>11.4f}{float(row['cv']):>9.2f}"
            f"{delta_text:>11}"
        )

    lines.extend([
        "",
        "Each configuration = 5 independent P5 PLUS runs x 5 sequential 8-GiB downloads.",
        "Primary score = mean of the five per-run aggregate active goodputs.",
        "STD = sample standard deviation across the five P5 runs; CV = STD / mean x 100.",
        "5-second inter-download gaps are excluded from goodput but remain in every workload.",
        "Power, C-state and frequency recording stays enabled in every run.",
    ])
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--p5", type=Path, required=True)
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--client-host", default="tinyman")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--done", type=Path, required=True)
    parser.add_argument("--failed", type=Path, required=True)
    parser.add_argument("--between-config-seconds", type=float, default=5.0)
    args = parser.parse_args()

    p5 = args.p5.resolve()
    runner = args.runner.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    args.done.unlink(missing_ok=True)
    args.failed.unlink(missing_ok=True)

    rows: list[dict[str, object]] = []
    failure_streak = 0
    aborted = False

    print("=" * 88, flush=True)
    print("P5 PLUS: 50 CONFIGURATIONS x 5 RUNS x 5 DOWNLOADS", flush=True)
    print("MODE=plus  IDLE=monitor  FALLBACK=short  RECORDERS=enabled", flush=True)
    print("=" * 88, flush=True)

    for zero_index, (name, config) in enumerate(TESTS):
        index = zero_index + 1
        case = f"T{index:02d}_{name}"
        case_out = args.output / case
        runner_log = args.output / f"{case}.runner.log"
        print(f"\n[{index:02d}/50] START {name}", flush=True)
        print(f"[{index:02d}/50] OVERRIDES: {config_text(config)}", flush=True)

        cmd = [
            "bash", str(runner),
            "--client-host", args.client_host,
            "--client-dir", str(p5),
            "--client-bin", "/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop",
            "--downloads", "5",
            "--gap-seconds", "5",
            "--server-cooldown-seconds", "5",
            "--between-tests-seconds", "5",
            "--cstate-cpu", "19",
            "--runs", str(RUNS_PER_CONFIG),
            "--mode-order", "balanced",
            "--seed", "20260806",
            "--output-dir", str(case_out),
        ]
        for key, value in FIXED_ENV.items():
            cmd.extend(["--env", f"{key}={value}"])
        for key, value in config.items():
            cmd.extend(["--env", f"{key}={value}"])

        with runner_log.open("w", encoding="utf-8") as handle:
            rc = subprocess.run(
                cmd,
                cwd=p5,
                stdout=handle,
                stderr=subprocess.STDOUT,
                check=False,
            ).returncode

        if rc != 0:
            failure_streak += 1
            rows.append({"index": index, "name": name, "status": "FAIL"})
            print(f"[{index:02d}/50] FAIL rc={rc}; log={runner_log}", flush=True)
            try:
                print("\n".join(runner_log.read_text(errors="replace").splitlines()[-50:]), flush=True)
            except OSError:
                pass
            cleanup_failed_case(p5, args.client_host)
            if failure_streak >= 3:
                print("ABORT: three consecutive configuration failures.", flush=True)
                aborted = True
                break
            time.sleep(args.between_config_seconds)
            continue

        aggregates: list[float] = []
        downloads: list[list[float]] = []
        parse_error: str | None = None
        for rep in range(1, RUNS_PER_CONFIG + 1):
            client_log = case_out / f"client_rep{rep:02d}_plus.log"
            if not client_log.is_file():
                parse_error = f"missing {client_log.name}"
                break
            try:
                aggregate, per_download = parse_one_run(client_log)
            except Exception as exc:  # preserve remaining sweep on one bad case
                parse_error = str(exc)
                break
            aggregates.append(aggregate)
            downloads.append(per_download)

        if parse_error is not None or len(aggregates) != RUNS_PER_CONFIG:
            failure_streak += 1
            rows.append({"index": index, "name": name, "status": "FAIL"})
            print(f"[{index:02d}/50] PARSE FAIL: {parse_error}", flush=True)
            cleanup_failed_case(p5, args.client_host)
            if failure_streak >= 3:
                print("ABORT: three consecutive configuration failures.", flush=True)
                aborted = True
                break
            time.sleep(args.between_config_seconds)
            continue

        failure_streak = 0
        mean_value = statistics.mean(aggregates)
        std_value = statistics.stdev(aggregates)
        cv_value = std_value / mean_value * 100.0
        download_means = [
            statistics.mean(downloads[run][position] for run in range(RUNS_PER_CONFIG))
            for position in range(DOWNLOADS)
        ]
        rows.append({
            "index": index,
            "name": name,
            "status": "OK",
            "runs": aggregates,
            "mean": mean_value,
            "std": std_value,
            "cv": cv_value,
            "min": min(aggregates),
            "max": max(aggregates),
            "download_means": download_means,
        })
        runs_text = ", ".join(f"{value:.4f}" for value in aggregates)
        d_text = " ".join(f"D{i + 1}={value:.4f}" for i, value in enumerate(download_means))
        print(
            f"[{index:02d}/50] RESULT mean={mean_value:.4f} Gb/s "
            f"std={std_value:.4f} CV={cv_value:.2f}% runs=[{runs_text}]",
            flush=True,
        )
        print(f"[{index:02d}/50] {d_text}", flush=True)
        if index < len(TESTS):
            time.sleep(args.between_config_seconds)

    summary = render_summary(rows)
    args.summary.write_text(summary, encoding="utf-8")
    print(summary, flush=True)

    successful = sum(row["status"] == "OK" for row in rows)
    if aborted or successful != 50:
        args.failed.write_text(
            f"completed_configs={len(rows)}\nsuccessful_configs={successful}\nexpected_configs=50\n",
            encoding="utf-8",
        )
        return 2

    args.done.write_text("PASS\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
