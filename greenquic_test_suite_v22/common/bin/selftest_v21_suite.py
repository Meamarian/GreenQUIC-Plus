#!/usr/bin/env python3
"""Regression tests for V21 configuration and idle-evidence validators."""
from __future__ import annotations
import argparse, importlib.util, subprocess, tempfile
from pathlib import Path


def load(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def mutate(path: Path, key: str, value: str) -> None:
    lines = path.read_text().splitlines()
    found = False
    out = []
    for line in lines:
        if line.startswith(key + "="):
            out.append(f"{key}={value}")
            found = True
        else:
            out.append(line)
    if not found:
        out.append(f"{key}={value}")
    path.write_text("\n".join(out) + "\n")


def stats_line(**overrides: str) -> str:
    values = {
        "lcore":"8","owns_rx":"1","owns_tx":"0","mode":"plus","profile":"server_download",
        "action":"monitor_rx","hardmax":"0","rxhard":"0","txhard":"0","control":"0",
        "rxctrl":"0","txctrl":"0","rxphysctrl":"0","txphysctrl":"0","rxburstp":"0",
        "rxqueuep":"0","txburstp":"0","txringp":"0","rxbursta":"0","rxqueuea":"0",
        "txbursta":"0","txringa":"0","rxfloor":"0","txfloor":"0","rxh":"0x0","txh":"0x0",
        "txring":"0","rxq":"0","rx_pkts":"0","tx_pkts":"0","rx_empty":"1000","tx_empty":"0",
        "rx_full":"0","tx_full":"0","slept_us":"0","cstate_attempt":"0","cstate_ok":"0",
        "cstate_req_last_us":"0","cstate_req_total_us":"0","cstate_actual_last_us":"0",
        "cstate_actual_total_us":"0","idle_mode":"monitor","monitor_try":"3","monitor_wake":"1",
        "monitor_timeout":"2","epoll_try":"0","epoll_wake":"0","epoll_timeout":"0","wake_signal":"0",
    }
    values.update(overrides)
    return "GreenQUIC " + " ".join(f"{k}={v}" for k,v in values.items())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--suite-root", type=Path, default=Path(__file__).resolve().parents[2])
    args = ap.parse_args()
    root = args.suite_root.resolve()
    validator = load(root / "common/bin/validate_v21_config.py", "gq_validator")
    base = root / "test_cases/v21_idle_modes/T10_short_software_sleep/server"
    errors, _ = validator.validate(base / "dpdk.ini", base / "powermng.ini", True)
    assert not errors, errors

    bad_cases = [
        ("GreenQuicIdleMode", "typo"),
        ("GreenQuicIdleWatchdogUs", "0"),
        ("GreenQuicEpollMaxEvents", "33"),
        ("GreenQuicEnableSleep", "maybe"),
        ("GreenQuicWorkWaitMinIdleUs", "-1"),
    ]
    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        for i, (key, value) in enumerate(bad_cases):
            dpdk = td / f"dpdk{i}.ini"
            power = td / f"power{i}.ini"
            dpdk.write_bytes((base / "dpdk.ini").read_bytes())
            power.write_bytes((base / "powermng.ini").read_bytes())
            mutate(power, key, value)
            errors, _ = validator.validate(dpdk, power, True)
            assert errors, f"invalid {key}={value} was accepted"

        log = td / "stats.log"
        log.write_text(stats_line() + "\n")
        subprocess.run([
            "python3", str(root / "common/bin/validate_v21_log.py"), str(log),
            "--require-all", "--expect-idle-mode", "monitor"
        ], check=True)
        subprocess.run([
            "python3", str(root / "common/bin/validate_v21_idle_evidence.py"), str(log),
            "--idle-mode", "monitor", "--require-actions", "monitor_rx",
            "--min-fields", "monitor_try:1,monitor_timeout:1",
            "--role-actions", "1:0:monitor_rx",
            "--role-min-fields", "1:0:monitor_try:1"
        ], check=True)
        # A pause overlapping ACK_PENDING must be rejected.
        badlog = td / "bad_hint.log"
        badlog.write_text(stats_line(action="optimized_pause_short", idle_mode="pause", txh="0x1") + "\n")
        proc = subprocess.run([
            "python3", str(root / "common/bin/validate_v21_idle_evidence.py"), str(badlog),
            "--idle-mode", "pause", "--forbid-hint-actions", "txh:0x1:optimized_pause"
        ])
        assert proc.returncode != 0, "hint/action overlap was not rejected"

    print("V21 validator and evidence self-tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
