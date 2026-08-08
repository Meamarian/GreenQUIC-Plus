#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import re
from collections import defaultdict
from pathlib import Path
from statistics import mean
from typing import Any

MODES = ("off", "basic", "plus")
LOG_RE = re.compile(r"^(server|client)_rep(\d+)_(off|basic|plus)\.log$")
STATE_RE = re.compile(
    r"state\s+(\d+)\s*=\s*(\d+)\s+intervals?"
    r"\s*/\s*([0-9]+(?:\.[0-9]+)?)\s*(us|ms|s)",
    re.IGNORECASE,
)
SCALE = {"us": 1e-6, "ms": 1e-3, "s": 1.0}


def load_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def state_name(mapping: dict[str, Any], index: int) -> str:
    row = mapping.get("states", {}).get(str(index), {})
    name = str(row.get("name") or f"state{index}")
    return f"{name} (state{index})"


def parse_residency(log: Path) -> dict[int, dict[str, float]]:
    text = log.read_text(encoding="utf-8", errors="replace")
    line = ""
    for candidate in text.splitlines():
        if "- Per-state residency:" in candidate:
            line = candidate.split("- Per-state residency:", 1)[1].strip()
    result: dict[int, dict[str, float]] = {}
    for state, intervals, duration, unit in STATE_RE.findall(line):
        index = int(state)
        result[index] = {
            "intervals": float(intervals),
            "residency_s": float(duration) * SCALE[unit.lower()],
        }
    return result


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--matrix", type=Path, required=True)
    args = parser.parse_args()

    matrix = args.matrix.resolve()
    tables = matrix / "tables"
    charts = tables / "charts"
    config = matrix / "configuration"
    tables.mkdir(parents=True, exist_ok=True)
    charts.mkdir(parents=True, exist_ok=True)

    mappings = {
        "server": load_json(config / "cpuidle_server.json"),
        "client": load_json(config / "cpuidle_client.json"),
    }

    rows: list[dict[str, Any]] = []
    grouped: dict[tuple[str, str, int], list[float]] = defaultdict(list)
    states_seen: dict[str, set[int]] = {"server": set(), "client": set()}

    for log in sorted(matrix.glob("*_rep*_*.log")):
        match = LOG_RE.match(log.name)
        if not match:
            continue
        role, repetition, mode = match.group(1), int(match.group(2)), match.group(3)
        parsed = parse_residency(log)
        for index, values in parsed.items():
            states_seen[role].add(index)
            grouped[(role, mode, index)].append(values["residency_s"])
            rows.append({
                "role": role,
                "repetition": repetition,
                "mode": mode,
                "state_index": index,
                "state_name": state_name(mappings[role], index),
                "intervals": int(values["intervals"]),
                "residency_s": values["residency_s"],
            })

    csv_path = tables / "cstate_residency_named_all_runs.csv"
    with csv_path.open("w", newline="", encoding="utf-8") as handle:
        columns = [
            "role", "repetition", "mode", "state_index",
            "state_name", "intervals", "residency_s",
        ]
        writer = csv.DictWriter(handle, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)

    mapping_md = ["# CPUIdle state mapping", ""]
    for role in ("server", "client"):
        mapping = mappings[role]
        mapping_md.extend([
            f"## {role.title()}",
            "",
            f"- Host: `{mapping.get('host', 'unknown')}`",
            f"- CPU: `{mapping.get('cpu', 'unknown')}`",
            "",
            "| Linux index | Real name | Description | Exit latency | Target residency |",
            "|---:|---|---|---:|---:|",
        ])
        for key, row in sorted(
            mapping.get("states", {}).items(),
            key=lambda item: int(item[0]),
        ):
            mapping_md.append(
                f"| state{key} | {row.get('name', '')} | "
                f"{row.get('description', '')} | "
                f"{row.get('exit_latency_us', 'N/A')} us | "
                f"{row.get('target_residency_us', 'N/A')} us |"
            )
        mapping_md.append("")
    (tables / "cpuidle_state_mapping.md").write_text(
        "\n".join(mapping_md) + "\n", encoding="utf-8"
    )

    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        import numpy as np

        series: list[tuple[str, list[float]]] = []
        for role in ("server", "client"):
            for index in sorted(states_seen[role]):
                values = [
                    mean(grouped[(role, mode, index)])
                    if grouped[(role, mode, index)] else 0.0
                    for mode in MODES
                ]
                series.append(
                    (f"{role.title()} {state_name(mappings[role], index)}", values)
                )

        if series:
            x = np.arange(len(MODES))
            width = min(0.82 / len(series), 0.20)
            start = -width * (len(series) - 1) / 2

            fig, ax = plt.subplots(figsize=(13, 7))
            for position, (label, values) in enumerate(series):
                bars = ax.bar(x + start + position * width, values, width, label=label)
                for bar in bars:
                    height = float(bar.get_height())
                    if math.isfinite(height) and height > 0:
                        ax.annotate(
                            f"{height:.3f}",
                            xy=(bar.get_x() + bar.get_width() / 2, height),
                            xytext=(0, 3),
                            textcoords="offset points",
                            ha="center",
                            va="bottom",
                            fontsize=7,
                            rotation=90,
                        )
            ax.set_title("Linux CPUIdle residency by real C-state name")
            ax.set_ylabel("Average residency per run (s)")
            ax.set_xticks(x, [mode.upper() for mode in MODES])
            ax.legend(fontsize=8, ncols=2)
            ax.grid(axis="y", alpha=0.3)
            fig.tight_layout()
            fig.savefig(
                charts / "linux_cstate_residency_by_mode.svg",
                format="svg",
            )
            plt.close(fig)
    except Exception as exc:
        print(f"[P5:WARN] named C-state chart was not generated: {exc}")

    # GREENQUIC-P5-COUNTER-HISTOGRAMS-V1
    # Additional charts only. Existing P5/P4 chart files are not modified.
    import subprocess as _gq_subprocess
    import sys as _gq_sys
    _gq_counter_plotter = (
        Path(__file__).resolve().parents[3]
        / "common" / "bin" / "plot_greenquic_counter_histograms.py"
    )
    if not _gq_counter_plotter.is_file():
        raise SystemExit(f"ERROR: missing P5 counter histogram plotter: {_gq_counter_plotter}")
    _gq_subprocess.run(
        [_gq_sys.executable, str(_gq_counter_plotter), "--matrix", str(matrix)],
        check=True,
    )

    server_bundles = sorted((matrix / "runs" / "server").glob("rep*/*"))
    client_bundles = sorted((matrix / "runs" / "client").glob("rep*/*"))
    server_summaries = sorted((matrix / "runs" / "server").glob("rep*/*/details/*_summary.txt"))
    client_summaries = sorted((matrix / "runs" / "client").glob("rep*/*/details/*_summary.txt"))
    env_server = sorted((config / "run_env").glob("*_server_effective.env"))
    env_client = sorted((config / "run_env").glob("*_client_effective.env"))

    manifest_rows: list[dict[str, Any]] = []
    for path in sorted(p for p in matrix.rglob("*") if p.is_file()):
        manifest_rows.append({
            "path": str(path.relative_to(matrix)),
            "bytes": path.stat().st_size,
            "sha256": sha256(path),
        })

    matrix_config = load_json(matrix / "matrix_config.json")
    expected = int(matrix_config.get("repetitions_per_mode", 0)) * 3
    integrity = {
        "schema": "greenquic-p5-unified-matrix-v1",
        "matrix": str(matrix),
        "expected_runs_per_role": expected,
        "server_run_bundles": len(server_bundles),
        "client_run_bundles": len(client_bundles),
        "server_run_summaries": len(server_summaries),
        "client_run_summaries": len(client_summaries),
        "server_effective_env_snapshots": len(env_server),
        "client_effective_env_snapshots": len(env_client),
        "cpuidle_server_valid": bool(mappings["server"].get("valid")),
        "cpuidle_client_valid": bool(mappings["client"].get("valid")),
        "all_run_bundles_present": (
            expected > 0
            and len(server_bundles) == expected
            and len(client_bundles) == expected
        ),
        "all_run_summaries_present": (
            expected > 0
            and len(server_summaries) == expected
            and len(client_summaries) == expected
        ),
        "all_env_snapshots_present": (
            expected > 0
            and len(env_server) == expected
            and len(env_client) == expected
        ),
        "files": manifest_rows,
    }
    (matrix / "matrix_integrity.json").write_text(
        json.dumps(integrity, indent=2) + "\n",
        encoding="utf-8",
    )

    readme = (
        "# Unified P5 matrix result\n\n"
        "This directory is self-contained.\n\n"
        "- Raw matrix logs and aligned RAPL JSON: matrix root\n"
        "- Matrix tables and SVG charts: `tables/`\n"
        "- Server run bundles: `runs/server/`\n"
        "- Client run bundles copied from tinyman: `runs/client/`\n"
        "- Static and per-run effective configuration: `configuration/`\n"
        "- CPUIdle index-to-name mapping: `tables/cpuidle_state_mapping.md`\n"
        "- File hashes and completeness checks: `matrix_integrity.json`\n\n"
        f"Expected bundles per endpoint: {expected}\n"
        f"Server bundles found: {len(server_bundles)}\n"
        f"Client bundles found: {len(client_bundles)}\n"
        f"Server summaries found: {len(server_summaries)}\n"
        f"Client summaries found: {len(client_summaries)}\n"
    )
    (matrix / "README.md").write_text(readme, encoding="utf-8")

    if expected and (
        len(server_bundles) != expected
        or len(client_bundles) != expected
        or len(server_summaries) != expected
        or len(client_summaries) != expected
        or len(env_server) != expected
        or len(env_client) != expected
    ):
        raise SystemExit(
            "ERROR: unified matrix is incomplete; inspect matrix_integrity.json"
        )

    print("[P5] Unified matrix integrity: PASS")
    print(f"[P5] Named CPUIdle chart: {charts / 'linux_cstate_residency_by_mode.svg'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
