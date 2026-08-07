#!/usr/bin/env bash
set -Eeuo pipefail

# GreenQUIC V22 reporting/debug repair
#
# Fixes the client /dev/null download-sink accounting bug and reorganizes every
# run into one self-contained result directory. This is a plain-text patch:
# no Base64, no downloads, and no hidden generated components.

SUITE="${1:-/root/mohsen/greenquic_test_suite_v22}"
COMMON="$SUITE/common/bin"
GQ_COMMON="$COMMON/gq_common.sh"
POWER_TRACE="$COMMON/power_trace.py"
GOODPUT="$COMMON/report_goodput.py"
BUNDLER="$COMMON/bundle_run_results.py"
SUMMARY="$COMMON/write_run_summary.py"
P0="$SUITE/test_cases/pretests/P0_smoke_1MiB/run_client.sh"
P1="$SUITE/test_cases/pretests/P1_goodput_off_10GiB/run_client.sh"
P2="$SUITE/test_cases/pretests/P2_goodput_basic_10GiB/run_client.sh"
MARKER='GREENQUIC-V22-RESULTS-DEBUG-FIX-V1'

for required in "$GQ_COMMON" "$POWER_TRACE" "$GOODPUT" "$P0" "$P1" "$P2"; do
    [[ -f "$required" ]] || {
        echo "ERROR: required file is missing: $required" >&2
        exit 1
    }
done

for proc in quicinterop quicinteropserver; do
    if pgrep -x "$proc" >/dev/null 2>&1; then
        echo "ERROR: $proc is running. Stop the client/server before patching." >&2
        pgrep -ax "$proc" >&2 || true
        exit 1
    fi
done

if ! grep -Fq 'GREENQUIC-V22-DOWNLOAD-CLEANUP-HOTFIX' "$GQ_COMMON"; then
    echo "ERROR: the previous GreenQUIC log/goodput patch is not installed." >&2
    exit 1
fi

if grep -Fq "$MARKER" "$GQ_COMMON"; then
    echo "The GreenQUIC V22 results/debug repair is already installed."
    exit 0
fi

backup_stamp="$(date +%Y%m%d_%H%M%S)"
for file in "$GQ_COMMON" "$POWER_TRACE" "$GOODPUT" "$P0" "$P1" "$P2"; do
    cp -a "$file" "$file.before_results_debug_fix_${backup_stamp}"
done

echo "Backups created with suffix .before_results_debug_fix_${backup_stamp}"

cat > "$SUMMARY" <<'PY'
#!/usr/bin/env python3
"""Create one human-readable GreenQUIC run summary.

The summary intentionally contains values, not artifact paths or file names.
"""
from __future__ import annotations

import argparse
import json
import math
import re
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


def clean_config(path: Path | None) -> list[str]:
    if path is None or not path.is_file():
        return []
    rows: list[str] = []
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        rows.append(raw.rstrip())
    return rows


def fmt(value: Any, digits: int = 3, missing: str = "unavailable") -> str:
    if value is None:
        return missing
    try:
        return f"{float(value):.{digits}f}"
    except (TypeError, ValueError):
        return str(value)


def parse_log(path: Path | None) -> dict[str, Any]:
    if path is None or not path.is_file():
        return {}
    text = path.read_text(encoding="utf-8", errors="replace")
    transmission = [int(v) for v in re.findall(
        r"(?mi)^\s*transmission time \[us\]:\s*(\d+)\s*$", text
    )]
    total_execution = [float(v) for v in re.findall(
        r"(?mi)^\s*Total execution time:\s*([0-9]+(?:\.[0-9]+)?)s\s*$", text
    )]
    completions = [
        {"name": Path(name.strip()).name, "duration_ms": int(ms)}
        for name, ms in re.findall(
            r"(?m)^\s*(.+?):\s*Completed download!\s*\((\d+)\s*ms\)\s*$", text
        )
    ]
    idle_modes = sorted(set(re.findall(r"\bidle_mode=([^\s]+)", text)))
    epoll_wakes = [int(v) for v in re.findall(r"\bepoll_wake=(\d+)", text)]
    epoll_tries = [int(v) for v in re.findall(r"\bepoll_try=(\d+)", text)]
    epoll_timeouts = [int(v) for v in re.findall(r"\bepoll_timeout=(\d+)", text)]
    frequencies = [int(v) for v in re.findall(r"\bfreq_khz=(\d+)", text)]
    freq_actions = re.findall(r"policy_action=([^\s]+)", text)
    return {
        "transmission_us": transmission[-1] if transmission else None,
        "total_execution_s": total_execution[-1] if total_execution else None,
        "completions": completions,
        "idle_modes": idle_modes,
        "epoll_wake": max(epoll_wakes, default=0),
        "epoll_try": max(epoll_tries, default=0),
        "epoll_timeout": max(epoll_timeouts, default=0),
        "freq_min_khz": min(frequencies) if frequencies else None,
        "freq_max_khz": max(frequencies) if frequencies else None,
        "freq_actions": freq_actions,
    }


def derive_goodput(
    manifest: dict[str, Any], log: dict[str, Any], role: str
) -> dict[str, Any]:
    if role != "client":
        return {
            "available": False,
            "reason": "Goodput is measured from the client download interval.",
        }
    payload_bytes = int(manifest.get("total_bytes", 0) or 0)
    duration_s: float | None = None
    timing_source = None
    if log.get("transmission_us"):
        duration_s = int(log["transmission_us"]) / 1_000_000.0
        timing_source = "client transmission timer (microsecond resolution)"
    elif len(log.get("completions", [])) == 1:
        duration_s = int(log["completions"][0]["duration_ms"]) / 1000.0
        timing_source = "MsQuic completion timer (millisecond resolution)"
    if payload_bytes <= 0 or duration_s is None or duration_s <= 0:
        return {
            "available": False,
            "payload_bytes": payload_bytes,
            "reason": "A successful payload size and download timer were not both available.",
        }
    bps = payload_bytes * 8.0 / duration_s
    crosscheck = None
    if len(log.get("completions", [])) == 1:
        ms_duration = int(log["completions"][0]["duration_ms"]) / 1000.0
        if ms_duration > 0:
            crosscheck = {
                "duration_s": ms_duration,
                "goodput_gbps": payload_bytes * 8.0 / ms_duration / 1e9,
            }
    return {
        "available": True,
        "definition": "payload bits divided by client download duration",
        "payload_bytes": payload_bytes,
        "payload_gib": payload_bytes / (1024 ** 3),
        "duration_s": duration_s,
        "timing_source": timing_source,
        "goodput_bps": bps,
        "goodput_mbps": bps / 1e6,
        "goodput_gbps": bps / 1e9,
        "msquic_crosscheck": crosscheck,
    }


def append_config(lines: list[str], title: str, rows: list[str]) -> None:
    lines.extend(["", title, "-" * len(title)])
    if not rows:
        lines.append("- No values were available.")
        return
    for row in rows:
        lines.append(f"- {row}")


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

    folder = args.run_dir
    power_path = first(folder, f"{args.stem}_power.json")
    manifest_path = first(folder, f"{args.stem}_download_manifest.json")
    log_path = first(folder, f"{args.stem}_log.txt")
    rapl_path = first(folder, f"{args.stem}_rapl.json")
    power = read_json(power_path)
    manifest = read_json(manifest_path)
    rapl = read_json(rapl_path)
    log = parse_log(log_path)
    goodput = derive_goodput(manifest, log, args.role)

    goodput_path = folder / f"{args.stem}_goodput.json"
    goodput_path.write_text(json.dumps(goodput, indent=2) + "\n", encoding="utf-8")

    completed = len(log.get("completions", []))
    status = "PASS"
    problems: list[str] = []
    if args.role == "client" and completed == 0:
        status = "FAIL"
        problems.append("No completed QUIC download was observed.")
    if args.role == "client" and not goodput.get("available"):
        status = "FAIL"
        problems.append(str(goodput.get("reason", "Goodput unavailable.")))
    if power.get("sample_count", 0) == 0:
        problems.append("No valid power1 samples were recorded.")

    lines: list[str] = [
        "=" * 68,
        "GreenQUIC Test Summary",
        "=" * 68,
        "",
        "Test",
        "----",
        f"- Test: {args.test_id} — {args.test_name}",
        f"- Role: {args.role}",
        f"- GreenQUIC mode: {args.mode}",
        f"- Run timestamp: {args.stamp}",
        f"- Status: {status}",
        "",
        "Transfer",
        "--------",
    ]

    if args.role == "client":
        lines.append(f"- Completed downloads: {completed}")
        if goodput.get("available"):
            lines.extend([
                f"- Payload: {goodput['payload_gib']:.3f} GiB ({goodput['payload_bytes']} bytes)",
                f"- Download duration: {goodput['duration_s']:.6f} s",
                f"- Goodput: {goodput['goodput_gbps']:.6f} Gbit/s",
                f"- Goodput: {goodput['goodput_mbps']:.3f} Mbit/s",
                f"- Timing source: {goodput['timing_source']}",
            ])
            cross = goodput.get("msquic_crosscheck")
            if cross:
                lines.append(
                    f"- MsQuic completion cross-check: {cross['goodput_gbps']:.6f} Gbit/s "
                    f"from {cross['duration_s']:.6f} s"
                )
        else:
            lines.append(f"- Goodput: unavailable — {goodput.get('reason')}")
    else:
        lines.extend([
            "- Goodput: client-side metric; not derived from the server listener lifetime.",
            f"- RX packets observed: {log.get('rx_packets', 'available in the detailed log')}",
        ])

    duration = None
    times = power.get("time_s_series") or []
    if times:
        try:
            duration = float(times[-1]) - float(times[0])
        except (TypeError, ValueError):
            duration = None
    lines.extend([
        "",
        "Whole-system Power",
        "------------------",
        "- Sensor: power1 from lm-sensors/sysfs",
        "- Scope: whole-system/board power, not CPU-package RAPL",
        f"- Samples: {power.get('sample_count', 0)}",
        f"- Requested sample interval: {power.get('sample_interval_ms_requested', 'unavailable')} ms",
        f"- Trace duration: {fmt(duration, 3)} s",
        f"- Estimated energy: {fmt(power.get('estimated_energy_j_trapezoidal'), 3)} J",
        f"- Time-weighted average power: {fmt(power.get('average_power_w_time_weighted'), 3)} W",
        f"- Minimum power: {fmt(power.get('power_w_min'), 3)} W",
        f"- Median power: {fmt(power.get('power_w_median'), 3)} W",
        f"- P95 power: {fmt(power.get('power_w_p95'), 3)} W",
        f"- Maximum power: {fmt(power.get('power_w_max'), 3)} W",
    ])

    lines.extend([
        "",
        "GreenQUIC Runtime",
        "-----------------",
        f"- Observed idle modes: {', '.join(log.get('idle_modes', [])) or 'none'}",
        f"- EPOLL attempts: {log.get('epoll_try', 0)}",
        f"- EPOLL wakeups: {log.get('epoll_wake', 0)}",
        f"- EPOLL timeouts: {log.get('epoll_timeout', 0)}",
        f"- Minimum observed frequency: {fmt((log.get('freq_min_khz') or 0) / 1e6 if log.get('freq_min_khz') else None, 3)} GHz",
        f"- Maximum observed frequency: {fmt((log.get('freq_max_khz') or 0) / 1e6 if log.get('freq_max_khz') else None, 3)} GHz",
        f"- Frequency actions observed: {', '.join(sorted(set(log.get('freq_actions', [])))) or 'none'}",
    ])

    cleanup = manifest.get("cleanup", {})
    if args.role == "client":
        lines.extend([
            "",
            "Client Storage Cleanup",
            "----------------------",
            "- Download target: persistent /dev/null sink",
            f"- Logical downloaded bytes measured: {manifest.get('total_bytes', 0)}",
            f"- Regular payload bytes left on disk: {cleanup.get('regular_bytes_remaining', 0)}",
            f"- /dev/null sinks preserved or restored: {cleanup.get('sinks_ready', 0)}",
        ])

    lines.extend([
        "",
        "Energy Counter Availability",
        "---------------------------",
        f"- Package RAPL available: {'yes' if rapl.get('rapl_available') else 'no'}",
    ])

    if problems:
        lines.extend(["", "Problems", "--------"])
        lines.extend(f"- {problem}" for problem in problems)

    append_config(lines, "Effective DPDK Configuration", clean_config(first(folder, f"{args.stem}_dpdk_config.txt")))
    append_config(lines, "Effective Power Configuration", clean_config(first(folder, f"{args.stem}_powermng_config.txt")))
    append_config(lines, "Test Configuration Snapshot", clean_config(first(folder, f"{args.stem}_test_config.txt")))
    append_config(lines, "Environment Overrides", clean_config(first(folder, f"{args.stem}_environment.txt")))

    lines.extend([
        "",
        "Interpretation Notes",
        "--------------------",
        "- Goodput excludes Ethernet, IP, UDP, QUIC headers, and retransmitted bytes.",
        "- The power1 energy estimate is trapezoidal integration of sampled whole-system watts.",
        "- Server energy covers server lifetime until Ctrl+C unless transfer windows are externally synchronized.",
        "",
    ])

    summary_path = folder / f"{args.stem}_summary.txt"
    summary_path.write_text("\n".join(lines), encoding="utf-8")
    print("\n" + "\n".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
chmod +x "$SUMMARY"

cat > "$BUNDLER" <<'PY'
#!/usr/bin/env python3
"""Move one GreenQUIC run's artifacts into one consistently named folder."""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
from pathlib import Path


def safe(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", text).strip("_")


def latest(paths: list[Path]) -> Path | None:
    existing = [p for p in paths if p.exists()]
    return max(existing, key=lambda p: p.stat().st_mtime_ns) if existing else None


def move_as(source: Path | None, target: Path) -> None:
    if source is None or not source.exists():
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        target.unlink()
    shutil.move(str(source), str(target))


def copy_as(source: Path | None, target: Path) -> None:
    if source is None or not source.exists():
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)


def relevant_environment() -> list[str]:
    exact = {
        "WORK_WAIT_MIN_LEVEL", "WORK_WAIT_MIN_IDLE_US", "IDLE_WATCHDOG_US",
        "ENABLE_FREQ", "ENABLE_SLEEP", "ENABLE_CSTATE_IDLE", "ENABLE_MULTICORE",
        "RX_EMPTY_POLLS", "TX_EMPTY_POLLS", "PRESSURE_MAX", "PRESSURE_UP",
        "PRESSURE_KEEP", "FREQ_UP_PERIOD_US", "FREQ_DOWN_PERIOD_US",
        "FREQ_MIN_IDLE_US", "GQ_LOG_LEVEL", "GQ_STATS_PERIOD_US",
        "GQ_CLEANUP_DOWNLOADED_FILES", "GQ_POWER_SAMPLE_INTERVAL_MS",
        "GQ_POWER_SENSOR_MATCH", "GQ_POWER_SENSOR_OCCURRENCE",
    }
    prefixes = ("GQ_", "GREENQUIC_", "SERVER_", "CLIENT_", "CASE_", "CSTATE_", "SLEEP_")
    rows = []
    for key, value in sorted(os.environ.items()):
        if key in exact or key.startswith(prefixes):
            rows.append(f"{key}={value}")
    return rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--test-dir", type=Path, required=True)
    parser.add_argument("--role", choices=("server", "client"), required=True)
    parser.add_argument("--mode", required=True)
    parser.add_argument("--stamp")
    args = parser.parse_args()

    test_dir = args.test_dir.resolve()
    result_root = test_dir / "results"
    log_root = test_dir / "logs"
    runtime = test_dir / "runtime" / args.role

    stamp = args.stamp
    manifest: Path | None = None
    if args.role == "client":
        manifests = sorted(
            result_root.glob(f"client_download_manifest_{args.mode}_*.json"),
            key=lambda p: p.stat().st_mtime_ns,
            reverse=True,
        )
        manifest = manifests[0] if manifests else None
        if stamp is None and manifest is not None:
            prefix = f"client_download_manifest_{args.mode}_"
            stamp = manifest.name[len(prefix):-5]
    if stamp is None:
        candidates = list(result_root.glob(f"{args.role}_power_{args.mode}_*.json"))
        source = latest(candidates)
        if source is not None:
            prefix = f"{args.role}_power_{args.mode}_"
            stamp = source.name[len(prefix):-5]
    if not stamp:
        raise SystemExit("ERROR: cannot determine the run timestamp")

    test_name = test_dir.name
    run_name = safe(f"{stamp}__{test_name}__{args.role}__{args.mode}")
    run_dir = result_root / run_name
    run_dir.mkdir(parents=True, exist_ok=False)
    stem = run_name

    # Primary log and validator output.
    move_as(log_root / f"{args.role}_{args.mode}_{stamp}.log", run_dir / f"{stem}_log.txt")
    move_as(result_root / f"{args.role}_{args.mode}_{stamp}_v21_stats.csv", run_dir / f"{stem}_stats.csv")

    # Power trace and compatibility energy measurement.
    move_as(result_root / f"{args.role}_power_{args.mode}_{stamp}.json", run_dir / f"{stem}_power.json")
    move_as(result_root / f"{args.role}_power_{args.mode}_{stamp}.csv", run_dir / f"{stem}_power.csv")
    move_as(result_root / f"{args.role}_power_{args.mode}_{stamp}_python_lists.txt", run_dir / f"{stem}_power_lists.txt")
    move_as(result_root / f"{args.role}_power_{args.mode}_{stamp}_timeseries.svg", run_dir / f"{stem}_power_timeseries.svg")
    move_as(result_root / f"{args.role}_power_{args.mode}_{stamp}_histogram.svg", run_dir / f"{stem}_power_histogram.svg")
    move_as(result_root / f"{args.role}_power_{args.mode}_{stamp}_sampler.log", run_dir / f"{stem}_power_sampler.txt")
    move_as(result_root / f"{args.role}_energy_{args.mode}_{stamp}.json", run_dir / f"{stem}_rapl.json")

    if args.role == "client":
        if manifest is None:
            manifest = result_root / f"client_download_manifest_{args.mode}_{stamp}.json"
        move_as(manifest, run_dir / f"{stem}_download_manifest.json")
        for candidate in list(result_root.glob(f"*goodput*{args.mode}*{stamp}*.json")):
            move_as(candidate, run_dir / f"{stem}_goodput_original.json")

    # Effective and source configurations. They are text snapshots so a result
    # folder remains understandable after later config changes.
    copy_as(runtime / "dpdk.ini", run_dir / f"{stem}_dpdk_config.txt")
    copy_as(runtime / "powermng.ini", run_dir / f"{stem}_powermng_config.txt")
    copy_as(test_dir / "config.env", run_dir / f"{stem}_test_config.txt")
    (run_dir / f"{stem}_environment.txt").write_text(
        "\n".join(relevant_environment()) + "\n", encoding="utf-8"
    )

    metadata = {
        "schema": "greenquic-run-bundle-v1",
        "test_id": os.environ.get("TEST_ID", test_name.split("_", 1)[0]),
        "test_name": test_name,
        "role": args.role,
        "mode": args.mode,
        "stamp": stamp,
        "stem": stem,
    }
    (run_dir / f"{stem}_metadata.json").write_text(
        json.dumps(metadata, indent=2) + "\n", encoding="utf-8"
    )

    summary = Path(__file__).with_name("write_run_summary.py")
    subprocess.run([
        "python3", str(summary),
        "--run-dir", str(run_dir),
        "--role", args.role,
        "--mode", args.mode,
        "--test-id", metadata["test_id"],
        "--test-name", test_name,
        "--stamp", stamp,
        "--stem", stem,
    ], check=True)

    print(f"\n[GreenQUIC-Test] Run bundle created: {run_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
chmod +x "$BUNDLER"

python3 - "$GQ_COMMON" "$POWER_TRACE" "$GOODPUT" "$P0" "$P1" "$P2" "$MARKER" <<'PY'
from __future__ import annotations

from pathlib import Path
import re
import sys

common_path, power_path, goodput_path, p0_path, p1_path, p2_path = map(Path, sys.argv[1:7])
marker = sys.argv[7]

# -------------------------------------------------------------------------
# Fix the manifest: the suite intentionally writes through /dev/null symlinks.
# Logical payload bytes therefore come from the successfully requested server
# object, not from the client sink's on-disk file size.
# -------------------------------------------------------------------------
text = common_path.read_text(encoding="utf-8")
write_start = text.find("write_client_download_manifest() {")
cleanup_start = text.find("cleanup_client_downloads() {", write_start)
run_client_start = text.find("\nrun_client() {", cleanup_start)
if min(write_start, cleanup_start, run_client_start) < 0:
    raise SystemExit("ERROR: manifest/cleanup function anchors were not found")

new_helpers = r'''write_client_download_manifest() {
    local start_wall_ns="$1" out="$2"
    python3 - \
        "$EFFECTIVE_DOWNLOAD_DIR" "$start_wall_ns" "$out" "$TEST_ID" "$WORKLOAD_KIND" \
        "$logf" "$GQ_COMMON_DIR/files/server_root" <<'PY_MANIFEST'
from __future__ import annotations

import json
import os
import re
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
start_ns = int(sys.argv[2])
out = Path(sys.argv[3])
test_id = sys.argv[4]
workload = sys.argv[5]
log_path = Path(sys.argv[6])
server_root = Path(sys.argv[7]).resolve()

text = log_path.read_text(encoding="utf-8", errors="replace") if log_path.is_file() else ""
completions = [
    {"reported_name": name.strip(), "duration_ms": int(milliseconds)}
    for name, milliseconds in re.findall(
        r"(?m)^\s*(.+?):\s*Completed download!\s*\((\d+)\s*ms\)\s*$", text
    )
]
rows = []
for completion in completions:
    basename = Path(completion["reported_name"]).name
    candidates = [server_root / basename]
    candidates.extend(server_root.rglob(basename))
    source = next((candidate for candidate in candidates if candidate.is_file()), None)
    if source is None:
        raise SystemExit(f"completed object has no server source file: {basename}")
    sink = root / basename
    sink_kind = "missing"
    sink_target = None
    if sink.is_symlink():
        sink_kind = "symlink"
        try:
            sink_target = str(sink.resolve(strict=False))
        except OSError:
            sink_target = os.readlink(sink)
    elif sink.is_file():
        sink_kind = "regular_file"
    elif sink.exists():
        sink_kind = "other"
    rows.append({
        "basename": basename,
        "reported_name": completion["reported_name"],
        "duration_ms": completion["duration_ms"],
        "logical_size_bytes": source.stat().st_size,
        "source_path": str(source),
        "sink_path": str(sink),
        "sink_kind_before_cleanup": sink_kind,
        "sink_target_before_cleanup": sink_target,
    })

data = {
    "schema": "greenquic-client-download-manifest-v2-logical-bytes",
    "test_id": test_id,
    "workload_kind": workload,
    "download_root": str(root),
    "start_wall_ns": start_ns,
    "file_count": len(rows),
    "total_bytes": sum(row["logical_size_bytes"] for row in rows),
    "files": rows,
    "measurement_note": (
        "Client outputs are /dev/null sinks. Logical payload bytes are taken from "
        "the server source objects only after MsQuic reports successful completion."
    ),
}
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
print(
    f"[GreenQUIC-Test] Download accounting: completed={data['file_count']} "
    f"logical_bytes={data['total_bytes']} persistent_payload_bytes=0"
)
PY_MANIFEST
}

cleanup_client_downloads() {
    local manifest="$1"
    [[ "${GQ_CLEANUP_DOWNLOADED_FILES:-1}" == 1 ]] || {
        log "Client cleanup is temporarily disabled for this wrapper; its EXIT trap owns cleanup."
        return 0
    }
    python3 - "$manifest" <<'PY_CLEANUP'
from __future__ import annotations

import json
from pathlib import Path
import sys

manifest = Path(sys.argv[1])
data = json.loads(manifest.read_text(encoding="utf-8"))
root = Path(data["download_root"]).resolve()
removed_regular_files = 0
removed_regular_bytes = 0
sinks_ready = 0

for row in data.get("files", []):
    sink = Path(row["sink_path"])
    try:
        sink.parent.resolve().relative_to(root)
    except ValueError:
        raise SystemExit(f"refusing to modify a sink outside the download root: {sink}")

    keep = False
    if sink.is_symlink():
        try:
            keep = sink.resolve(strict=False) == Path("/dev/null")
        except OSError:
            keep = False
    if not keep:
        if sink.is_file() and not sink.is_symlink():
            removed_regular_bytes += sink.stat().st_size
            removed_regular_files += 1
        if sink.exists() or sink.is_symlink():
            sink.unlink()
        sink.parent.mkdir(parents=True, exist_ok=True)
        sink.symlink_to("/dev/null")
    sinks_ready += 1

regular_bytes_remaining = 0
for row in data.get("files", []):
    sink = Path(row["sink_path"])
    if sink.is_file() and not sink.is_symlink():
        regular_bytes_remaining += sink.stat().st_size

data["cleanup"] = {
    "removed_regular_files": removed_regular_files,
    "removed_regular_bytes": removed_regular_bytes,
    "regular_bytes_remaining": regular_bytes_remaining,
    "sinks_ready": sinks_ready,
    "strategy": "preserve or restore each client output as a /dev/null symlink",
}
manifest.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
print(
    f"[GreenQUIC-Test] Client storage cleanup: removed_files={removed_regular_files} "
    f"removed_bytes={removed_regular_bytes} persistent_payload_bytes={regular_bytes_remaining} "
    f"dev_null_sinks_ready={sinks_ready}"
)
PY_CLEANUP
}
'''
text = text[:write_start] + new_helpers + text[run_client_start:]

# Add bundle finalization to the server EXIT handler after validation, power,
# and compatibility energy files have been completed.
server_global_anchor = '    GQ_SERVER_LABEL="$TEST_ID server $mode"\n'
if server_global_anchor not in text:
    raise SystemExit("ERROR: server global-variable anchor not found")
text = text.replace(
    server_global_anchor,
    server_global_anchor +
    '    GQ_SERVER_TEST_DIR="$TEST_DIR"\n'
    '    GQ_SERVER_RUNTIME="$runtime"\n',
    1,
)

server_finish_anchor = '''        energy_finish "$GQ_SERVER_ESTART" "$GQ_SERVER_EOUT" "$GQ_SERVER_LABEL" || energy_rc=$?
'''
if server_finish_anchor not in text:
    raise SystemExit("ERROR: server energy-finish anchor not found")
text = text.replace(
    server_finish_anchor,
    server_finish_anchor +
    '''        local bundle_rc=0
        python3 "$GQ_COMMON_DIR/bin/bundle_run_results.py" \
            --test-dir "$GQ_SERVER_TEST_DIR" --role server \
            --mode "$GQ_SERVER_MODE" --stamp "$GQ_SERVER_STAMP" || bundle_rc=$?
''',
    1,
)
server_rc_anchor = '''        [[ "$rc" == 0 && "$energy_rc" != 0 ]] && rc="$energy_rc"
'''
if server_rc_anchor not in text:
    raise SystemExit("ERROR: server final status anchor not found")
text = text.replace(
    server_rc_anchor,
    server_rc_anchor + '        [[ "$rc" == 0 && "$bundle_rc" != 0 ]] && rc="$bundle_rc"\n',
    1,
)

# Record the repair marker in the common runner.
text += f"\n# {marker}\n"
common_path.write_text(text, encoding="utf-8")

# -------------------------------------------------------------------------
# Make the terminal power report concise and readable. Arrays and artifact
# paths remain in JSON/list files, not in terminal summaries.
# -------------------------------------------------------------------------
power = power_path.read_text(encoding="utf-8")
start = power.find("def summary(args: argparse.Namespace) -> int:")
end = power.find("\n\ndef main() -> int:", start)
if start < 0 or end < 0:
    raise SystemExit("ERROR: power summary function anchors not found")
new_power_summary = r'''def summary(args: argparse.Namespace) -> int:
    data = json.loads(args.input.read_text(encoding="utf-8"))
    times = data.get("time_s_series") or []
    duration = None
    if times:
        duration = float(times[-1]) - float(times[0])

    def shown(value: object, digits: int = 3) -> str:
        if value is None:
            return "unavailable"
        return f"{float(value):.{digits}f}"

    print("\n=== GreenQUIC Power Summary ===")
    print(f"- Role: {data.get('role')}")
    print("- Sensor: power1 (whole-system/board power; not package RAPL)")
    print(f"- Samples: {data.get('sample_count', 0)}")
    print(f"- Requested interval: {data.get('sample_interval_ms_requested')} ms")
    print(f"- Trace duration: {shown(duration)} s")
    print(f"- Estimated energy: {shown(data.get('estimated_energy_j_trapezoidal'))} J")
    print(f"- Time-weighted average: {shown(data.get('average_power_w_time_weighted'))} W")
    print(f"- Minimum: {shown(data.get('power_w_min'))} W")
    print(f"- Median: {shown(data.get('power_w_median'))} W")
    print(f"- P95: {shown(data.get('power_w_p95'))} W")
    print(f"- Maximum: {shown(data.get('power_w_max'))} W")
    print()
    return 0
'''
power = power[:start] + new_power_summary + power[end:]
power_path.write_text(power, encoding="utf-8")

# -------------------------------------------------------------------------
# Make the goodput terminal report concise and remove all artifact paths.
# -------------------------------------------------------------------------
goodput = goodput_path.read_text(encoding="utf-8")
print_start = goodput.find('    print("\\n=== GreenQUIC client payload goodput ===")')
return_marker = goodput.find("    return 0\n", print_start)
if print_start < 0 or return_marker < 0:
    raise SystemExit("ERROR: goodput print block anchors not found")
new_goodput_print = r'''    print("\n=== GreenQUIC Goodput Summary ===")
    print(f"- Test: {args.test_id}")
    print(f"- GreenQUIC mode: {args.mode}")
    print(f"- Payload: {result['payload_gib']:.3f} GiB ({args.bytes} bytes)")
    print(f"- Download duration: {primary['duration_s']:.6f} s")
    print(f"- Goodput: {primary['goodput_gbps_decimal']:.6f} Gbit/s")
    print(f"- Goodput: {primary['goodput_mbps_decimal']:.3f} Mbit/s")
    print(f"- Timing source: {primary_source}")
    if completion_result is not None:
        print(
            f"- MsQuic completion cross-check: "
            f"{completion_result['goodput_gbps_decimal']:.6f} Gbit/s "
            f"from {completion_result['duration_s']:.6f} s"
        )
    print("- Scope: payload bytes only; protocol headers and retransmissions are excluded")
    print()
'''
goodput = goodput[:print_start] + new_goodput_print + goodput[return_marker:]
goodput_path.write_text(goodput, encoding="utf-8")

# -------------------------------------------------------------------------
# After each client wrapper has completed validation and goodput generation,
# move every artifact into its self-contained run folder.
# -------------------------------------------------------------------------
def append_bundle(path: Path, mode: str) -> None:
    body = path.read_text(encoding="utf-8")
    local_marker = "GREENQUIC-V22-RUN-BUNDLE-V1"
    if local_marker in body:
        return
    body = body.rstrip() + f'''\n\n# {local_marker}
python3 "$HERE/../../../common/bin/bundle_run_results.py" \\
    --test-dir "$HERE" --role client --mode "{mode}"
'''
    path.write_text(body, encoding="utf-8")

append_bundle(p0_path, "off")
append_bundle(p1_path, "off")
append_bundle(p2_path, "basic")
PY

python3 -m py_compile "$POWER_TRACE" "$GOODPUT" "$BUNDLER" "$SUMMARY"
bash -n "$GQ_COMMON" "$P0" "$P1" "$P2"

grep -Fq "$MARKER" "$GQ_COMMON" || {
    echo "ERROR: repair marker was not installed" >&2
    exit 1
}

cat <<'EOF'

PASS: GreenQUIC V22 results/debug repair installed.

What is fixed:
  - /dev/null download sinks are accounted by logical server payload size.
  - P1/P2 goodput is calculated after each successful single transfer.
  - Real client payload files are removed and /dev/null sinks are restored.
  - Every run gets one date/time + test + role + mode result folder.
  - Every artifact inside uses one common basename.
  - A readable summary.txt contains goodput, power, EPOLL/frequency behavior,
    cleanup status, effective DPDK/power settings, test config, and overrides.
  - Terminal power/goodput summaries use lists and do not print arrays or paths.

No MsQuic source was changed, so no rebuild is required.
EOF
