#!/usr/bin/env python3
"""Collect one GreenQUIC run: SVG visuals at top, details below details/."""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

COMMON_BIN = (Path(__file__).resolve().parent / "../../../common/bin").resolve()


def safe(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", value).strip("_")


def move(source: Path | None, target: Path) -> None:
    if source is None or not source.exists():
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        target.unlink()
    shutil.move(str(source), str(target))


def copy(source: Path | None, target: Path) -> None:
    if source is None or not source.exists():
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)


def latest(paths: list[Path]) -> Path | None:
    rows = [path for path in paths if path.exists()]
    return max(rows, key=lambda path: path.stat().st_mtime_ns) if rows else None


def environment_rows() -> list[str]:
    exact = {
        "WORK_WAIT_MIN_LEVEL", "WORK_WAIT_MIN_IDLE_US", "IDLE_WATCHDOG_US",
        "ENABLE_FREQ", "ENABLE_SLEEP", "ENABLE_CSTATE_IDLE", "ENABLE_MULTICORE",
        "RX_EMPTY_POLLS", "TX_EMPTY_POLLS", "PRESSURE_MAX", "PRESSURE_UP", "PRESSURE_KEEP",
        "FREQ_UP_PERIOD_US", "FREQ_DOWN_PERIOD_US", "FREQ_MIN_IDLE_US", "FREQ_PERIOD_US",
        "GQ_LOG_LEVEL", "GQ_STATS_PERIOD_US", "GQ_CLEANUP_DOWNLOADED_FILES",
        "GQ_POST_TRANSFER_WAIT_S", "GQ_POWER_SAMPLE_INTERVAL_MS",
        "GQ_POWER_SENSOR_MATCH", "GQ_POWER_SENSOR_OCCURRENCE",
        "GQ_ENABLE_MSR_TRACE", "GQ_REQUIRE_MSR_TRACE", "GQ_MSR_SAMPLE_INTERVAL_MS",
        "GQ_MSR_SMOOTH_SAMPLES", "GQ_MSR_PLOT_WIDTH_PX", "GQ_MSR_PLOT_HEIGHT_PX",
        "GQ_MSR_PLOT_X_TICK_MS", "GQ_MSR_PLOT_X_LABEL_MS", "GQ_MSR_PLOT_Y_TICKS",
        "GQ_MSR_HISTOGRAM_WIDTH_PX", "GQ_MSR_HISTOGRAM_HEIGHT_PX", "GQ_MSR_HISTOGRAM_BINS",
        "GQ_PLOT_WIDTH_PX", "GQ_PLOT_HEIGHT_PX", "GQ_PLOT_X_TICK_MS",
        "GQ_PLOT_X_LABEL_MS", "GQ_PLOT_Y_TICKS", "GQ_PLOT_MIN_PX_PER_TICK",
        "GQ_PLOT_MAX_WIDTH_PX", "GQ_POWER_PLOT_WIDTH_PX", "GQ_POWER_PLOT_HEIGHT_PX",
        "GQ_POWER_PLOT_X_TICK_MS", "GQ_POWER_PLOT_X_LABEL_MS",
        "GQ_FREQ_PLOT_WIDTH_PX", "GQ_FREQ_PLOT_HEIGHT_PX",
        "GQ_FREQ_PLOT_X_TICK_MS", "GQ_FREQ_PLOT_X_LABEL_MS",
    }
    prefixes = ("GQ_", "GREENQUIC_", "SERVER_", "CLIENT_", "CASE_", "CSTATE_", "SLEEP_")
    return [
        f"{key}={value}" for key, value in sorted(os.environ.items())
        if key in exact or key.startswith(prefixes)
    ]


def determine_stamp(result_root: Path, role: str, mode: str, supplied: str | None) -> str:
    if supplied:
        return supplied
    candidates: list[Path] = []
    candidates.extend(result_root.glob(f"{role}_power_{mode}_*.json"))
    candidates.extend(result_root.glob(f"{role}_msr_{mode}_*.csv"))
    candidates.extend(result_root.glob(f"{role}_transfer_{mode}_*.json"))
    if role == "client":
        candidates.extend(result_root.glob(f"client_download_manifest_{mode}_*.json"))
    source = latest(candidates)
    if source is None:
        raise SystemExit("ERROR: cannot determine the run timestamp")
    prefixes = (
        f"{role}_power_{mode}_",
        f"{role}_msr_{mode}_",
        f"{role}_transfer_{mode}_",
        f"client_download_manifest_{mode}_",
    )
    for prefix in prefixes:
        if source.name.startswith(prefix):
            return source.name[len(prefix):].rsplit(".", 1)[0]
    raise SystemExit("ERROR: unsupported timestamp source")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--test-dir", type=Path, required=True)
    parser.add_argument("--role", choices=("server", "client"), required=True)
    parser.add_argument("--mode", required=True)
    parser.add_argument("--stamp")
    args = parser.parse_args()

    # GREENQUIC-ENABLE-RECORD-V1: no summaries, SVGs or result folders when recording is disabled.
    if os.environ.get("ENABLE_RECORD", "1").strip().lower() in {"0", "false", "no", "off"}:
        return 0

    test_dir = args.test_dir.resolve()
    result_root = test_dir / "results"
    log_root = test_dir / "logs"
    runtime = test_dir / "runtime" / args.role
    stamp = determine_stamp(result_root, args.role, args.mode, args.stamp)
    test_name = test_dir.name
    run_name = safe(f"{stamp}__{test_name}__{args.role}__{args.mode}")
    run_dir = result_root / run_name
    retry = 1
    while run_dir.exists():
        run_dir = result_root / f"{run_name}__retry{retry}"
        retry += 1
    details = run_dir / "details"
    details.mkdir(parents=True)
    stem = run_dir.name

    move(log_root / f"{args.role}_{args.mode}_{stamp}.log", details / f"{stem}_log.txt")
    move(log_root / f"{args.role}_{args.mode}_{stamp}_timeline.jsonl", details / f"{stem}_timeline.jsonl")
    move(result_root / f"{args.role}_frequency_samples_{args.mode}_{stamp}.jsonl", details / f"{stem}_frequency_samples.jsonl")
    move(result_root / f"{args.role}_frequency_samples_{args.mode}_{stamp}_sampler.log", details / f"{stem}_frequency_sampler.txt")
    move(result_root / f"{args.role}_{args.mode}_{stamp}_v21_stats.csv", details / f"{stem}_stats.csv")
    move(
        result_root / f"{args.role}_{args.mode}_{stamp}_greenquic_counters.csv",
        details / f"{stem}_greenquic_counters.csv",
    )

    power_prefix = result_root / f"{args.role}_power_{args.mode}_{stamp}"
    move(Path(str(power_prefix) + ".json"), details / f"{stem}_power.json")
    move(Path(str(power_prefix) + ".csv"), details / f"{stem}_power.csv")
    move(Path(str(power_prefix) + "_python_lists.txt"), details / f"{stem}_power_lists.txt")
    move(Path(str(power_prefix) + "_sampler.log"), details / f"{stem}_power_sampler.txt")
    move(Path(str(power_prefix) + "_timeseries.svg"), run_dir / f"{stem}_power_timeseries.svg")
    move(Path(str(power_prefix) + "_energy_timeseries.svg"), run_dir / f"{stem}_energy_timeseries.svg")
    move(Path(str(power_prefix) + "_histogram.svg"), run_dir / f"{stem}_power_histogram.svg")
    move(result_root / f"{args.role}_energy_{args.mode}_{stamp}.json", details / f"{stem}_energy_snapshot.json")

    transfer_window = details / f"{stem}_transfer_window.json"
    move(
        result_root / f"{args.role}_transfer_{args.mode}_{stamp}.json",
        transfer_window,
    )

    msr_csv_source = result_root / f"{args.role}_msr_{args.mode}_{stamp}.csv"
    msr_log_source = result_root / f"{args.role}_msr_{args.mode}_{stamp}_sampler.log"
    msr_csv = details / f"{stem}_msr_power.csv"
    move(msr_csv_source, msr_csv)
    move(msr_log_source, details / f"{stem}_msr_sampler.txt")

    cstate_prefix = result_root / f"{args.role}_cstate_{args.mode}_{stamp}"
    cstate_csv = details / f"{stem}_cstate.csv"
    cstate_json = details / f"{stem}_cstate.json"
    move(Path(str(cstate_prefix) + ".csv"), cstate_csv)
    move(Path(str(cstate_prefix) + ".json"), cstate_json)
    move(Path(str(cstate_prefix) + "_sampler.log"), details / f"{stem}_cstate_sampler.txt")

    if args.role == "client":
        manifest = result_root / f"client_download_manifest_{args.mode}_{stamp}.json"
        if not manifest.exists():
            manifest = latest(list(result_root.glob(f"client_download_manifest_{args.mode}_*.json")))
        move(manifest, details / f"{stem}_download_manifest.json")
        goodput_rows = sorted(
            result_root.glob(f"*goodput*{args.mode}*.json"),
            key=lambda path: path.stat().st_mtime_ns,
            reverse=True,
        )
        if goodput_rows:
            move(goodput_rows[0], details / f"{stem}_goodput.json")

    copy(runtime / "dpdk.ini", details / f"{stem}_dpdk_config.txt")
    copy(runtime / "powermng.ini", details / f"{stem}_powermng_config.txt")
    copy(
        runtime / f"off_cpu_max_{stamp}.state",
        details / f"{stem}_off_cpu_max_original_state.txt",
    )
    copy(test_dir / "config.env", details / f"{stem}_test_config.txt")
    (details / f"{stem}_environment.txt").write_text(
        "\n".join(environment_rows()) + "\n", encoding="utf-8"
    )

    timeline = details / f"{stem}_timeline.jsonl"
    frequency_samples = details / f"{stem}_frequency_samples.jsonl"
    frequency_inputs = [p for p in (timeline, frequency_samples) if p.is_file()]
    if frequency_inputs:
        frequency_input = details / f"{stem}_frequency_input.jsonl"
        with frequency_input.open("w", encoding="utf-8") as output:
            for source in frequency_inputs:
                content = source.read_text(encoding="utf-8", errors="replace")
                output.write(content)
                if content and not content.endswith("\n"):
                    output.write("\n")
        frequency_prefix = details / f"{stem}_frequency"
        frequency_env = os.environ.copy()
        frequency_env["GQ_RESULT_MODE"] = args.mode
        subprocess.run([
            "python3", str((COMMON_BIN / "frequency_trace.py")),
            "--timeline", str(frequency_input),
            "--prefix", str(frequency_prefix),
            "--role", args.role,
        ], check=True, env=frequency_env)
        move(Path(str(frequency_prefix) + "_timeseries.svg"), run_dir / f"{stem}_frequency_timeseries.svg")

    msr_has_samples = False
    if msr_csv.is_file():
        data_rows = [
            raw for raw in msr_csv.read_text(encoding="utf-8", errors="replace").splitlines()
            if raw and not raw.startswith("#")
        ]
        msr_has_samples = len(data_rows) >= 2
    if msr_has_samples:
        command = [
            "python3", str((COMMON_BIN / "rapl_msr_trace.py")),
            "--csv", str(msr_csv),
            "--json", str(details / f"{stem}_msr_power.json"),
            "--timeseries-svg", str(run_dir / f"{stem}_msr_power_timeseries.svg"),
            "--histogram-svg", str(run_dir / f"{stem}_msr_power_histogram.svg"),
            "--energy-timeseries-svg", str(run_dir / f"{stem}_msr_energy_timeseries.svg"),
            "--role", args.role,
        ]
        if transfer_window.is_file():
            command.extend([
                "--transfer-window-json", str(transfer_window),
                "--transfer-timeseries-svg", str(run_dir / f"{stem}_msr_transfer_power_timeseries.svg"),
                "--transfer-histogram-svg", str(run_dir / f"{stem}_msr_transfer_power_histogram.svg"),
                "--transfer-energy-timeseries-svg", str(run_dir / f"{stem}_msr_transfer_energy_timeseries.svg"),
            ])
        subprocess.run(command, check=True)

    if cstate_csv.is_file() and cstate_json.is_file():
        # GREENQUIC-V22-CSTATE-CONDITIONAL-PLOT-V2
        import os as _gq_os
        _gq_cstate_requested = (
            _gq_os.environ.get(
                "ENABLE_CSTATE_RECORD", "0"
            ).strip().lower()
            in ("1", "true", "yes", "on")
        )
        _gq_cstate_has_data = False
        if _gq_cstate_requested:
            try:
                _gq_cstate_path = Path(cstate_csv)
                if _gq_cstate_path.is_file():
                    with _gq_cstate_path.open(
                        "r",
                        encoding="utf-8",
                        errors="replace",
                    ) as _gq_handle:
                        _gq_cstate_has_data = (
                            sum(1 for _ in _gq_handle) > 1
                        )
            except OSError as _gq_error:
                print(
                    "[GreenQUIC-Test:WARN] Cannot inspect "
                    f"C-state CSV: {_gq_error}"
                )
        
        if _gq_cstate_has_data:
            # GREENQUIC-V22-CSTATE-PLOT-BEST-EFFORT-V1 (P5-local)
            try:
                subprocess.run([
                    "python3", str((COMMON_BIN / "cstate_trace.py")),
                    "--csv", str(cstate_csv),
                    "--summary", str(cstate_json),
                    "--timeline-svg", str(run_dir / f"{stem}_cstate_timeseries.svg"),
                    "--histogram-svg", str(run_dir / f"{stem}_cstate_wakeup_histogram.svg"),
                    "--role", args.role,
                ], check=True)
            except subprocess.CalledProcessError as exc:
                print(
                    "[GreenQUIC-Test:WARN] C-state plot generation failed "
                    f"(rc={exc.returncode}); preserving raw C-state data and "
                    "continuing bundle/summary generation."
                )
        else:
            print(
                "[GreenQUIC-Test] Skipping C-state plots: "
                "recording disabled or no C-state samples."
            )

    metadata = {
        "schema": "greenquic-run-bundle-v4",
        "test_id": os.environ.get("TEST_ID", test_name.split("_", 1)[0]),
        "test_name": test_name,
        "role": args.role,
        "mode": args.mode,
        "stamp": stamp,
        "stem": stem,
        "layout": {"visuals": ".", "details": "details/"},
    }
    (details / f"{stem}_metadata.json").write_text(
        json.dumps(metadata, indent=2) + "\n", encoding="utf-8"
    )
    subprocess.run([
        "python3", str(Path(__file__).with_name("write_run_summary.py")),
        "--run-dir", str(run_dir), "--role", args.role, "--mode", args.mode,
        "--test-id", metadata["test_id"], "--test-name", test_name,
        "--stamp", stamp, "--stem", stem,
    ], check=True)

    unexpected = [
        path.name for path in run_dir.iterdir()
        if path.name != "details" and (not path.is_file() or path.suffix.lower() != ".svg")
    ]
    if unexpected:
        raise SystemExit("ERROR: non-SVG objects remain at run-folder top level: " + ", ".join(unexpected))

    print(f"\n[GreenQUIC-Test] Run result folder created: {run_dir}")
    print(f"[GreenQUIC-Test] SVG visuals: {run_dir}")
    print(f"[GreenQUIC-Test] Logs/configuration/data: {details}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

# GREENQUIC-V22-OFF-FULL-RESULTS-V1
