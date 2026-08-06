#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from statistics import mean


REQUEST_RE = re.compile(
    r"^\[GreenQUIC-P4\] request=(\d+)/(\d+) "
    r"(start|complete)_us=(\d+) path=(\S+)"
    r"(?: duration_us=(\d+) success=(0|1))?$"
)
GAP_RE = re.compile(
    r"^\[GreenQUIC-P4\] gap_after=(\d+) requested_us=(\d+) actual_us=(\d+)$"
)


def fmt(value: float, digits: int = 6) -> str:
    return f"{value:.{digits}f}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--mode", choices=("off", "basic", "plus"), required=True)
    parser.add_argument("--downloads", type=int, required=True)
    parser.add_argument("--gap-us", type=int, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--text-out", type=Path, required=True)
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    text = args.log.read_text(encoding="utf-8", errors="replace")
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))

    starts: dict[int, dict[str, object]] = {}
    completions: dict[int, dict[str, object]] = {}
    gaps: dict[int, dict[str, int]] = {}

    for raw in text.splitlines():
        line = raw.strip()
        match = REQUEST_RE.match(line)
        if match:
            index = int(match.group(1))
            total = int(match.group(2))
            kind = match.group(3)
            timestamp_us = int(match.group(4))
            path = match.group(5)
            if kind == "start":
                starts[index] = {
                    "index": index,
                    "total": total,
                    "start_us": timestamp_us,
                    "path": path,
                }
            else:
                completions[index] = {
                    "index": index,
                    "total": total,
                    "complete_us": timestamp_us,
                    "path": path,
                    "duration_us": int(match.group(6) or 0),
                    "success": int(match.group(7) or 0),
                }
            continue

        match = GAP_RE.match(line)
        if match:
            index = int(match.group(1))
            gaps[index] = {
                "after_request": index,
                "requested_us": int(match.group(2)),
                "actual_us": int(match.group(3)),
            }

    expected = args.downloads
    if len(starts) != expected or len(completions) != expected:
        raise SystemExit(
            "ERROR: P4 markers are incomplete: "
            f"starts={len(starts)} completions={len(completions)} expected={expected}. "
            "Use the separately built P4 quicinterop binary."
        )

    for index in range(1, expected + 1):
        if index not in starts or index not in completions:
            raise SystemExit(f"ERROR: missing P4 request marker for index {index}")
        if completions[index]["success"] != 1:
            raise SystemExit(f"ERROR: P4 download {index} failed")
        if starts[index]["path"] != completions[index]["path"]:
            raise SystemExit(f"ERROR: request path changed for download {index}")

    expected_gaps = max(0, expected - 1)
    if args.gap_us > 0 and len(gaps) != expected_gaps:
        raise SystemExit(
            f"ERROR: observed {len(gaps)}/{expected_gaps} required P4 gap markers"
        )

    total_bytes = int(manifest.get("total_bytes", 0))
    file_count = int(manifest.get("file_count", 0))
    if file_count != expected:
        raise SystemExit(
            f"ERROR: manifest has {file_count} downloads; expected {expected}"
        )
    if total_bytes <= 0:
        raise SystemExit("ERROR: manifest total_bytes is not positive")

    durations_us = [int(completions[i]["duration_us"]) for i in range(1, expected + 1)]
    if any(value <= 0 for value in durations_us):
        raise SystemExit("ERROR: at least one P4 download duration is not positive")

    first_start_us = int(starts[1]["start_us"])
    last_complete_us = int(completions[expected]["complete_us"])
    workload_elapsed_us = last_complete_us - first_start_us
    if workload_elapsed_us <= 0:
        raise SystemExit("ERROR: P4 workload elapsed time is not positive")

    actual_gaps_us = [gaps[i]["actual_us"] for i in sorted(gaps)]
    requested_gap_total_us = args.gap_us * expected_gaps
    active_download_us = sum(durations_us)

    metrics = {
        "schema": "greenquic-p4-repeated-downloads-v1",
        "mode": args.mode,
        "processes": {"client": 1},
        "quic_connections": 1,
        "streams": expected,
        "downloads_configured": expected,
        "downloads_observed": file_count,
        "payload_bytes_per_download": total_bytes // expected,
        "payload_bytes_total": total_bytes,
        "gap_requested_us_each": args.gap_us,
        "gap_requested_us_total": requested_gap_total_us,
        "gap_actual_us": actual_gaps_us,
        "gap_actual_us_total": sum(actual_gaps_us),
        "download_duration_us": durations_us,
        "download_duration_us_total": active_download_us,
        "workload_elapsed_us": workload_elapsed_us,
        "goodput_active_downloads_gbps": total_bytes * 8.0 / active_download_us / 1000.0,
        "goodput_workload_including_gaps_gbps": total_bytes * 8.0 / workload_elapsed_us / 1000.0,
        "requests": [
            {
                **starts[i],
                **completions[i],
            }
            for i in range(1, expected + 1)
        ],
        "gaps": [gaps[i] for i in sorted(gaps)],
    }

    lines = [
        "",
        "=== GreenQUIC P4 Workload Summary ===",
        f"- GreenQUIC mode: {args.mode}",
        "- Client processes: 1",
        "- QUIC connections: 1",
        f"- Sequential streams/downloads: {expected}",
        f"- Payload per download: {metrics['payload_bytes_per_download'] / (1024 ** 3):.3f} GiB",
        f"- Total payload: {total_bytes / (1024 ** 3):.3f} GiB",
        f"- Configured gap: {args.gap_us / 1_000_000.0:.6f} s",
        f"- Configured total gap time: {requested_gap_total_us / 1_000_000.0:.6f} s",
        f"- Observed total gap time: {sum(actual_gaps_us) / 1_000_000.0:.6f} s",
        f"- Sum of download durations: {active_download_us / 1_000_000.0:.6f} s",
        f"- Average download duration: {mean(durations_us) / 1_000_000.0:.6f} s",
        f"- Minimum download duration: {min(durations_us) / 1_000_000.0:.6f} s",
        f"- Maximum download duration: {max(durations_us) / 1_000_000.0:.6f} s",
        f"- Workload elapsed time including gaps: {workload_elapsed_us / 1_000_000.0:.6f} s",
        f"- Aggregate goodput excluding gaps: {metrics['goodput_active_downloads_gbps']:.6f} Gbit/s",
        f"- Aggregate goodput including gaps: {metrics['goodput_workload_including_gaps_gbps']:.6f} Gbit/s",
        "- Energy comparison rule: use whole-test RAPL across OFF/BASIC/PLUS; "
        "the configured inter-download gaps are part of this workload.",
        "- Packet-window note: BASIC/PLUS first-RX-to-last-TX includes the inter-download gaps; "
        "strict OFF intentionally reports that field as N/A.",
        "",
    ]

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(metrics, indent=2) + "\n", encoding="utf-8")
    args.text_out.write_text("\n".join(lines), encoding="utf-8")
    if not args.quiet:
        print("\n".join(lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
