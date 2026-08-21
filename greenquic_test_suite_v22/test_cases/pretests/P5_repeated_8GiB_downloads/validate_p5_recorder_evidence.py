#!/usr/bin/env python3
"""Validate final-paper P5 recorder placement from durable run evidence.

The final P5 controller logs the actual housekeeping CPU selected for every
asynchronous recorder. Older validation incorrectly required ``*_affinity.txt``
sidecar files after matrix bundling, but those sidecars are not guaranteed to be
retained in the final matrix tree. This validator therefore uses the durable
per-run logs plus ``matrix_integrity.json`` as the authoritative evidence.

RUN ON: SERVER role after a P5 matrix, or use --self-test anywhere.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import tempfile
from pathlib import Path

MODES = ("off", "basic", "plus")
ROLES = ("server", "client")
PROTECTED_CPUS = {19, 21, 22, 23, 24}


def fail(message: str) -> None:
    raise RuntimeError(message)


def load_integrity(matrix_dir: Path, runs: int) -> dict:
    path = matrix_dir / "matrix_integrity.json"
    if not path.is_file():
        fail(f"missing P5 matrix integrity file: {path}")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:  # pragma: no cover - defensive runtime message
        fail(f"cannot parse {path}: {exc}")

    expected = runs * len(MODES)
    for key in (
        "expected_runs_per_role",
        "server_run_bundles",
        "client_run_bundles",
        "server_run_summaries",
        "client_run_summaries",
    ):
        value = data.get(key)
        if value != expected:
            fail(f"{key}: expected {expected}, found {value!r}")
    for key in (
        "all_run_bundles_present",
        "all_run_summaries_present",
        "all_env_snapshots_present",
    ):
        if data.get(key) is not True:
            fail(f"{key} is not true")
    return data


def patterns_for(role: str) -> dict[str, re.Pattern[str]]:
    q = re.escape(role)
    return {
        "power1": re.compile(rf"Started {q} whole-system power1 trace .*?recorder_cpu=(\d+)"),
        "rapl_msr": re.compile(rf"Started {q} C RAPL powercap trace .*?recorder_cpu=(\d+)"),
        "cstate": re.compile(rf"Started {q} Linux cpu_idle trace .*?reader_cpu=(\d+)"),
        "frequency": re.compile(rf"Started {q} CPU-frequency trace .*?recorder_cpu=(\d+)"),
    }


def validate(matrix_dir: Path, runs: int, output: Path | None) -> dict:
    matrix_dir = matrix_dir.resolve()
    integrity = load_integrity(matrix_dir, runs)
    records: list[dict] = []
    by_role: dict[str, set[int]] = {role: set() for role in ROLES}

    for rep in range(1, runs + 1):
        for mode in MODES:
            for role in ROLES:
                log_path = matrix_dir / f"{role}_rep{rep:02d}_{mode}.log"
                if not log_path.is_file():
                    fail(f"missing canonical P5 run log: {log_path}")
                text = log_path.read_text(encoding="utf-8", errors="replace")
                evidence: dict[str, int] = {}
                for kind, pattern in patterns_for(role).items():
                    matches = pattern.findall(text)
                    if len(matches) != 1:
                        fail(
                            f"{log_path.name}: expected exactly one {kind} recorder CPU "
                            f"evidence line, found {len(matches)}"
                        )
                    cpu = int(matches[0])
                    if cpu in PROTECTED_CPUS:
                        fail(
                            f"{log_path.name}: {kind} recorder ran on protected paper CPU {cpu}; "
                            f"protected={sorted(PROTECTED_CPUS)}"
                        )
                    evidence[kind] = cpu
                    by_role[role].add(cpu)
                records.append(
                    {
                        "role": role,
                        "rep": rep,
                        "mode": mode,
                        "log": str(log_path.relative_to(matrix_dir)),
                        "recorders": evidence,
                    }
                )

    expected_logs = runs * len(MODES) * len(ROLES)
    if len(records) != expected_logs:
        fail(f"expected {expected_logs} validated P5 logs, found {len(records)}")

    sidecars = sorted(str(p.relative_to(matrix_dir)) for p in matrix_dir.rglob("*_affinity.txt"))
    result = {
        "schema": "greenquic.p5-recorder-evidence.v2",
        "matrix_dir": str(matrix_dir),
        "runs": runs,
        "modes": list(MODES),
        "roles": list(ROLES),
        "protected_paper_cpus": sorted(PROTECTED_CPUS),
        "validated_canonical_logs": len(records),
        "expected_canonical_logs": expected_logs,
        "validated_recorder_start_records": len(records) * 4,
        "unique_housekeeping_cpus_by_role": {
            role: sorted(cpus) for role, cpus in by_role.items()
        },
        "affinity_sidecars_found": len(sidecars),
        "affinity_sidecars_required": False,
        "affinity_sidecars": sidecars,
        "matrix_integrity": {
            key: integrity.get(key)
            for key in (
                "expected_runs_per_role",
                "server_run_bundles",
                "client_run_bundles",
                "server_run_summaries",
                "client_run_summaries",
                "all_run_bundles_present",
                "all_run_summaries_present",
                "all_env_snapshots_present",
            )
        },
        "records": records,
    }

    if output is not None:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")

    return result


def self_test() -> None:
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        runs = 2
        expected = runs * len(MODES)
        integrity = {
            "expected_runs_per_role": expected,
            "server_run_bundles": expected,
            "client_run_bundles": expected,
            "server_run_summaries": expected,
            "client_run_summaries": expected,
            "all_run_bundles_present": True,
            "all_run_summaries_present": True,
            "all_env_snapshots_present": True,
        }
        (root / "matrix_integrity.json").write_text(json.dumps(integrity), encoding="utf-8")
        for rep in range(1, runs + 1):
            for mode in MODES:
                for role in ROLES:
                    text = "\n".join(
                        [
                            f"[GreenQUIC-Test] Started {role} whole-system power1 trace pid=1 interval=1000ms recorder_cpu=1 prefix=x",
                            f"[GreenQUIC-Test] Started {role} C RAPL powercap trace pid=2 interval=6ms smoothing=3 recorder_cpu=1",
                            f"[GreenQUIC-Test] Started {role} Linux cpu_idle trace pid=3 traced_cpus=19 reader_cpu=1 clock=mono_raw",
                            f"[GreenQUIC-Test] Started {role} CPU-frequency trace pid=4 interval=1ms recorder_cpu=1",
                        ]
                    )
                    (root / f"{role}_rep{rep:02d}_{mode}.log").write_text(text + "\n", encoding="utf-8")
        out = root / "evidence.json"
        result = validate(root, runs, out)
        assert result["validated_canonical_logs"] == 12
        assert result["validated_recorder_start_records"] == 48
        assert result["affinity_sidecars_found"] == 0
        assert result["affinity_sidecars_required"] is False
        assert out.is_file()
    print("P5 RECORDER EVIDENCE SELF-TEST PASS")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--matrix-dir", type=Path)
    parser.add_argument("--runs", type=int)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return 0
    if args.matrix_dir is None or args.runs is None:
        parser.error("--matrix-dir and --runs are required unless --self-test is used")
    if args.runs <= 0:
        parser.error("--runs must be positive")

    try:
        result = validate(args.matrix_dir, args.runs, args.output)
    except RuntimeError as exc:
        print(f"P5 RECORDER EVIDENCE VALIDATION: FAIL\n{exc}", file=sys.stderr)
        return 1

    print("P5 RECORDER EVIDENCE VALIDATION: PASS")
    print(f"matrix={result['matrix_dir']}")
    print(f"canonical_logs={result['validated_canonical_logs']}")
    print(f"recorder_start_records={result['validated_recorder_start_records']}")
    print(
        "housekeeping_cpus="
        + json.dumps(result["unique_housekeeping_cpus_by_role"], sort_keys=True)
    )
    print(
        f"affinity_sidecars={result['affinity_sidecars_found']} "
        "(optional; durable log evidence is authoritative)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
