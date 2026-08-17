#!/usr/bin/env python3
"""Strict post-run validation for P5 Performance2 multicore matrices."""
from __future__ import annotations

import argparse
import csv
import json
import re
from pathlib import Path

MODES = {"off", "basic", "plus"}
EXPECTED = {
    "GreenQuicEnableMultiCore": "1",
    "GreenQuicDpdkLcores": "19,20",
    "GreenQuicQuicWorkerCpus": "21,22,23,24",
    "GreenQuicPartitionDpdkMap": "0:19,1:19,2:20,3:20",
    "GreenQuicTxOwnerLcore": "19",
    "GreenQuicTxOwnerAlsoRx": "1",
}


def parse_ini(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith(("#", ";")) or "=" not in line:
            continue
        key, value = line.split("=", 1)
        out[key.strip()] = value.strip()
    return out


def infer(path: Path) -> tuple[str | None, int | None, str | None]:
    text = "/".join(path.parts[-10:]).lower()
    role = "server" if "server" in text else ("client" if "client" in text else None)
    m = re.search(r"rep(\d+)[_-](off|basic|plus)", text)
    if m:
        return role, int(m.group(1)), m.group(2)
    m = re.search(r"(off|basic|plus).*?rep[_-]?(\d+)", text)
    if m:
        return role, int(m.group(2)), m.group(1)
    return role, None, None


def one_csv_row(path: Path) -> dict[str, str]:
    with path.open(newline="", encoding="utf-8", errors="replace") as handle:
        rows = list(csv.DictReader(handle))
    if len(rows) != 1:
        raise ValueError(f"expected one CSV row, found {len(rows)}")
    return rows[0]


def parse_cpu_set(value: str) -> set[int]:
    out: set[int] = set()
    for token in value.replace(";", ",").replace(" ", "").split(","):
        if token:
            out.add(int(token))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--matrix", type=Path, required=True)
    ap.add_argument("--runs", type=int, required=True)
    ap.add_argument("--report-dir", type=Path)
    args = ap.parse_args()

    root = args.matrix.resolve()
    errors: list[str] = []
    warnings: list[str] = []

    configs: dict[tuple[str, int, str], Path] = {}
    for path in root.rglob("*_dpdk_config.txt"):
        role, rep, mode = infer(path)
        if role and rep and mode:
            configs[(role, rep, mode)] = path

    expected_keys = {
        (role, rep, mode)
        for role in ("server", "client")
        for rep in range(1, args.runs + 1)
        for mode in MODES
    }
    missing = sorted(expected_keys - set(configs))
    extra = sorted(set(configs) - expected_keys)
    if missing:
        errors.append(f"missing runtime dpdk configs: {missing}")
    if extra:
        warnings.append(f"extra runtime dpdk configs ignored: {extra}")

    for key, path in sorted(configs.items()):
        role, rep, mode = key
        cfg = parse_ini(path)
        for name, wanted in EXPECTED.items():
            got = cfg.get(name)
            if got != wanted:
                errors.append(
                    f"{role} rep{rep:02d} {mode}: {name}={got!r}, expected {wanted!r}"
                )
        if cfg.get("GreenQuicMode") != mode:
            errors.append(
                f"{role} rep{rep:02d} {mode}: GreenQuicMode={cfg.get('GreenQuicMode')!r}"
            )

    counters: dict[tuple[str, int, str], Path] = {}
    for path in root.rglob("*_greenquic_counters.csv"):
        role, rep, mode = infer(path)
        if role and rep and mode:
            counters[(role, rep, mode)] = path

    # BASIC/PLUS must emit a process-end counter row for both active DPDK lcores.
    for role in ("server", "client"):
        for rep in range(1, args.runs + 1):
            for mode in ("basic", "plus"):
                key = (role, rep, mode)
                path = counters.get(key)
                if path is None:
                    errors.append(f"{role} rep{rep:02d} {mode}: missing counter CSV")
                    continue
                try:
                    row = one_csv_row(path)
                    lcore_rows = int(row.get("lcore_rows", "0"))
                    lcores = parse_cpu_set(row.get("lcores", ""))
                except Exception as exc:
                    errors.append(f"{path}: invalid counter CSV: {exc}")
                    continue
                if lcore_rows != 2:
                    errors.append(
                        f"{role} rep{rep:02d} {mode}: lcore_rows={lcore_rows}, expected 2"
                    )
                if lcores != {19, 20}:
                    errors.append(
                        f"{role} rep{rep:02d} {mode}: counter lcores={sorted(lcores)}, expected [19, 20]"
                    )

    # Strict OFF has no GreenQUIC cleanup row; fixed-max is emitted once per
    # active DPDK CPU by the shell measurement layer.
    for role in ("server", "client"):
        for rep in range(1, args.runs + 1):
            key = (role, rep, "off")
            path = counters.get(key)
            if path is None:
                errors.append(f"{role} rep{rep:02d} off: missing counter CSV")
                continue
            try:
                row = one_csv_row(path)
                fixed = int(row.get("freq_policy_off_fixed_max", "0"))
                lcore_rows = int(row.get("lcore_rows", "0"))
            except Exception as exc:
                errors.append(f"{path}: invalid OFF counter CSV: {exc}")
                continue
            if lcore_rows != 0:
                errors.append(
                    f"{role} rep{rep:02d} off: unexpected GreenQUIC lcore rows={lcore_rows}"
                )
            if fixed != 2:
                errors.append(
                    f"{role} rep{rep:02d} off: fixed-max records={fixed}, expected 2"
                )

    cstates: dict[tuple[str, int, str], Path] = {}
    for path in root.rglob("*_cstate.json"):
        role, rep, mode = infer(path)
        if role and rep and mode:
            cstates[(role, rep, mode)] = path

    freqs: dict[tuple[str, int, str], Path] = {}
    for path in root.rglob("*_frequency_samples.jsonl"):
        role, rep, mode = infer(path)
        if role and rep and mode:
            freqs[(role, rep, mode)] = path

    # Recording must cover both DPDK CPUs on both endpoints for every mode.
    for key in sorted(expected_keys):
        role, rep, mode = key
        cp = cstates.get(key)
        if cp is None:
            errors.append(f"{role} rep{rep:02d} {mode}: missing C-state summary")
        else:
            try:
                data = json.loads(cp.read_text(encoding="utf-8"))
                cpus = {int(x) for x in data.get("cpus", [])}
            except Exception as exc:
                errors.append(f"{cp}: invalid C-state JSON: {exc}")
            else:
                if cpus != {19, 20}:
                    errors.append(
                        f"{role} rep{rep:02d} {mode}: C-state CPUs={sorted(cpus)}, expected [19, 20]"
                    )

        fp = freqs.get(key)
        if fp is None:
            errors.append(f"{role} rep{rep:02d} {mode}: missing frequency samples")
        else:
            seen: set[int] = set()
            try:
                for raw in fp.read_text(encoding="utf-8", errors="replace").splitlines():
                    try:
                        row = json.loads(raw)
                    except Exception:
                        continue
                    if row.get("type") == "line" and row.get("cpu") is not None:
                        seen.add(int(row["cpu"]))
            except Exception as exc:
                errors.append(f"{fp}: cannot parse frequency samples: {exc}")
            if not {19, 20}.issubset(seen):
                errors.append(
                    f"{role} rep{rep:02d} {mode}: frequency CPUs={sorted(seen)}, expected both 19 and 20"
                )

    # OFF isolation: no adaptive GreenQUIC policy action may leak into OFF.
    forbidden = re.compile(
        r"policy_action=(?:freq_max_control|freq_max_hard|freq_up|freq_down|"
        r"freq_min|sleep|pause|monitor|epoll|keep_pause|short_idle_pause|"
        r"txring_protect_up)"
    )
    for path in root.rglob("*_log.txt"):
        role, rep, mode = infer(path)
        if mode != "off":
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        if forbidden.search(text):
            errors.append(f"{role} rep{rep:02d} off: GreenQUIC policy activity found in {path}")

    if args.report_dir:
        semantics = args.report_dir / "MULTICORE_METRIC_SEMANTICS.json"
        if not semantics.is_file():
            errors.append(f"multicore report semantics missing: {semantics}")
        for path in args.report_dir.rglob("*.csv"):
            try:
                rows = list(csv.DictReader(path.open(newline="", encoding="utf-8", errors="replace")))
            except Exception:
                continue
            for row in rows:
                for name, value in row.items():
                    if "idle_fraction" not in str(name).lower():
                        continue
                    try:
                        number = float(str(value).split()[0])
                    except (TypeError, ValueError):
                        continue
                    if number < -1e-6 or number > 100.000001:
                        errors.append(f"{path}: {name}={number} outside 0..100%")

    audit = {
        "schema": "greenquic-p5-multicore-matrix-audit-v1",
        "matrix": str(root),
        "runs": args.runs,
        "expected_dataplane_cpus": [19, 20],
        "expected_quic_cpus": [21, 22, 23, 24],
        "expected_tx_owner": 19,
        "errors": errors,
        "warnings": warnings,
        "status": "PASS" if not errors else "FAIL",
        "rss_note": (
            "A single QUIC connection is one 5-tuple and may remain on one RSS RX queue. "
            "This audit validates multicore topology/isolation, not RX scaling across queues."
        ),
    }
    out = root / "multicore_validation.json"
    out.write_text(json.dumps(audit, indent=2) + "\n", encoding="utf-8")

    for warning in warnings:
        print(f"WARN: {warning}")
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        print(f"P5 MULTICORE VALIDATION FAIL: {len(errors)} error(s)")
        return 2

    print("P5 MULTICORE VALIDATION PASS")
    print("DPDK CPUs: 19,20 | QUIC CPUs: 21,22,23,24 | TX owner: 19")
    print("OFF/BASIC/PLUS topology and recording isolation verified")
    print("NOTE: one QUIC connection may hash to one RSS RX queue; this is not an RX-scaling proof.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
