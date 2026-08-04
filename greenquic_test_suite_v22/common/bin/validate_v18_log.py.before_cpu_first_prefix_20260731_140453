#!/usr/bin/env python3
"""Validate every final V18 GreenQUIC diagnostic-stat line."""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REQUIRED = {
    "lcore", "owns_rx", "owns_tx", "action", "hardmax", "control",
    "rxctrl", "txctrl", "rxphysctrl", "txphysctrl",
    "rxburstp", "rxqueuep", "txburstp", "txringp",
    "rxbursta", "rxqueuea", "txbursta", "txringa",
    "rxfloor", "txfloor", "rxh", "txh", "txring", "rxq",
    "rx_empty", "tx_empty", "slept_us",
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("log", type=Path)
    ap.add_argument("--require-all", action="store_true")
    args = ap.parse_args()
    try:
        raw_lines = args.log.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    lines = [(no, text) for no, text in enumerate(raw_lines, 1) if text.startswith("GreenQUIC lcore=")]
    if not lines:
        print("ERROR: no final V18 GreenQUIC stats lines found", file=sys.stderr)
        return 2 if args.require_all else 0

    errors: list[str] = []
    all_keys: set[str] = set()
    for no, line in lines:
        keys = {m.group(1) for m in re.finditer(r"\b([A-Za-z0-9_]+)=([^\s]+)", line)}
        all_keys.update(keys)
        missing = sorted(REQUIRED - keys)
        if missing:
            errors.append(f"line {no} missing: {', '.join(missing)}")

    print(f"stats_lines={len(lines)}")
    print("fields=" + ",".join(sorted(all_keys)))
    if errors:
        for error in errors[:20]:
            print("ERROR: " + error, file=sys.stderr)
        if len(errors) > 20:
            print(f"ERROR: {len(errors) - 20} additional malformed stats lines", file=sys.stderr)
        return 2 if args.require_all else 0

    print("Every final V18 separated-signal diagnostic line has the required fields.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
