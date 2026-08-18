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
RUNS = 5

TOP3_ENV = {
    "PRESSURE_UP": "450",
    "RX_QUEUE_HIGH": "48",
    "ACTIVE_TRANSFER_SLEEP_MIN_LEVEL": "16",
}

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


def parse_run(path: Path) -> tuple[float, list[float]]:
    text = path.read_text(encoding="utf-8", errors="replace")
    pattern = re.compile(
        r"\[GreenQUIC-P5\] request=(\d+)/5 complete_us=\d+ path=\S+ "
        r"duration_us=(\d+) success=1"
    )
    durations: dict[int, int] = {}
    for match in pattern.finditer(text):
        durations[int(match.group(1))] = int(match.group(2))
    if set(durations) != {1, 2, 3, 4, 5}:
        raise RuntimeError(f"missing successful P5 markers in {path}: {sorted(durations)}")

    ordered = [durations[i] for i in range(1, DOWNLOADS + 1)]
    per_download = [PAYLOAD_BYTES * 8.0 / us / 1000.0 for us in ordered]
    aggregate = PAYLOAD_BYTES * DOWNLOADS * 8.0 / sum(ordered) / 1000.0

    reported = re.findall(
        r"Aggregate goodput excluding gaps:\s*([0-9.]+)\s+Gbit/s", text
    )
    if reported and abs(float(reported[-1]) - aggregate) > 0.002:
        raise RuntimeError(
            f"goodput cross-check failed: computed={aggregate:.6f} "
            f"reported={float(reported[-1]):.6f}"
        )
    return aggregate, per_download


def cleanup(p5: Path, client_host: str) -> None:
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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--p5", type=Path, required=True)
    parser.add_argument("--runner", type=Path, required=True)
    parser.add_argument("--client-host", default="tinyman")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--summary", type=Path, required=True)
    parser.add_argument("--done", type=Path, required=True)
    parser.add_argument("--failed", type=Path, required=True)
    args = parser.parse_args()

    p5 = args.p5.resolve()
    runner = args.runner.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    args.done.unlink(missing_ok=True)
    args.failed.unlink(missing_ok=True)

    print("=" * 88, flush=True)
    print("P5 PLUS TOP3 COMBO: 5 RUNS x 5 DOWNLOADS", flush=True)
    print("PRESSURE_UP=450 RX_QUEUE_HIGH=48 ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16", flush=True)
    print("MODE=plus  IDLE=monitor  FALLBACK=short  RECORDERS=enabled", flush=True)
    print("=" * 88, flush=True)

    aggregates: list[float] = []
    downloads: list[list[float]] = []

    for rep in range(1, RUNS + 1):
        run_out = args.output / f"run{rep:02d}"
        runner_log = args.output / f"run{rep:02d}.runner.log"
        print(f"\n[{rep}/5] START", flush=True)

        cmd = [
            "bash", str(runner),
            "--client-host", args.client_host,
            "--client-dir", str(p5),
            "--client-bin", "/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop",
            "--downloads", "5",
            "--gap-seconds", "5",
            "--server-cooldown-seconds", "5",
            "--between-tests-seconds", "0",
            "--cstate-cpu", "19",
            "--runs", "1",
            "--mode-order", "balanced",
            "--seed", str(20260806 + rep),
            "--output-dir", str(run_out),
        ]
        for key, value in FIXED_ENV.items():
            cmd.extend(["--env", f"{key}={value}"])
        for key, value in TOP3_ENV.items():
            cmd.extend(["--env", f"{key}={value}"])

        with runner_log.open("w", encoding="utf-8") as handle:
            rc = subprocess.run(
                cmd,
                cwd=p5,
                stdout=handle,
                stderr=subprocess.STDOUT,
                check=False,
            ).returncode

        client_log = run_out / "client_rep01_plus.log"
        try:
            aggregate, per_download = parse_run(client_log)
        except Exception as exc:
            print(f"[{rep}/5] FAIL rc={rc}: {exc}", flush=True)
            try:
                print("\n".join(runner_log.read_text(errors="replace").splitlines()[-60:]), flush=True)
            except OSError:
                pass
            cleanup(p5, args.client_host)
            args.failed.write_text(f"failed_run={rep}\nrunner_rc={rc}\nerror={exc}\n", encoding="utf-8")
            return 2

        # The stripped no-chart runner can return 141 (SIGPIPE) after the final
        # successful download during display-pipeline teardown. If all five P5
        # success markers are present, keep the completed transport result.
        if rc != 0:
            print(
                f"[{rep}/5] NOTE runner rc={rc}, but all 5 downloads are verified; "
                "accepting completed transport result.",
                flush=True,
            )
            cleanup(p5, args.client_host)

        aggregates.append(aggregate)
        downloads.append(per_download)
        print(
            f"[{rep}/5] GOODPUT={aggregate:.4f} Gb/s "
            + " ".join(f"D{i+1}={value:.4f}" for i, value in enumerate(per_download)),
            flush=True,
        )

        if rep < RUNS:
            time.sleep(5)

    mean_value = statistics.mean(aggregates)
    std_value = statistics.stdev(aggregates)
    cv_value = std_value / mean_value * 100.0
    dmeans = [
        statistics.mean(downloads[run][pos] for run in range(RUNS))
        for pos in range(DOWNLOADS)
    ]

    summary = "\n".join([
        "",
        "=" * 88,
        "P5 PLUS TOP3 COMBO FINAL RESULT",
        "=" * 88,
        "PRESSURE_UP=450",
        "RX_QUEUE_HIGH=48",
        "ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16",
        "",
        "RUN GOODPUTS (Gb/s)",
        *[f"run{i+1}: {value:.4f}" for i, value in enumerate(aggregates)],
        "",
        f"MEAN: {mean_value:.4f} Gb/s",
        f"STD:  {std_value:.4f} Gb/s",
        f"CV:   {cv_value:.2f}%",
        f"MIN:  {min(aggregates):.4f} Gb/s",
        f"MAX:  {max(aggregates):.4f} Gb/s",
        "",
        "D1-D5 MEAN GOODPUTS (Gb/s)",
        " ".join(f"D{i+1}={value:.4f}" for i, value in enumerate(dmeans)),
        "",
        "5 runs x 5 sequential 8-GiB downloads; 5-s gaps excluded from goodput.",
        "monitor + short fixed; power/C-state/frequency recorders enabled.",
        "",
    ])
    args.summary.write_text(summary, encoding="utf-8")
    print(summary, flush=True)
    args.done.write_text("PASS\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
