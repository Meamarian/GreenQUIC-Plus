#!/usr/bin/env python3
"""Pin E810 data queue IRQs round-robin over a dataplane CPU list."""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


def parse_cpu_list(value: str) -> list[int]:
    out: set[int] = set()
    for token in value.replace(" ", "").split(","):
        if not token:
            continue
        if "-" in token:
            a, b = map(int, token.split("-", 1))
            if b < a:
                raise ValueError(token)
            out.update(range(a, b + 1))
        else:
            out.add(int(token))
    if not out:
        raise ValueError("empty CPU list")
    return sorted(out)


def parse_affinity(value: str) -> set[int]:
    return set(parse_cpu_list(value.strip()))


def queue_index(text: str) -> tuple[int, str]:
    match = re.search(r"(?i)txrx[-_]?(\d+)", text)
    return (int(match.group(1)) if match else 1_000_000, text)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--iface", required=True)
    ap.add_argument("--cpus", required=True)
    ap.add_argument("--state-dir", type=Path, required=True)
    ap.add_argument("--expected-queues", type=int, default=0)
    args = ap.parse_args()

    cpus = parse_cpu_list(args.cpus)
    if args.expected_queues and len(cpus) != args.expected_queues:
        raise SystemExit(
            f"ERROR: expected-queues={args.expected_queues} but CPU list has {len(cpus)} CPUs"
        )

    msi = Path(f"/sys/class/net/{args.iface}/device/msi_irqs")
    if not msi.is_dir():
        raise SystemExit(f"ERROR: MSI IRQ directory missing: {msi}")

    allowed_irqs = {int(path.name) for path in msi.iterdir() if path.name.isdigit()}
    if not allowed_irqs:
        raise SystemExit(f"ERROR: no MSI IRQs found for {args.iface}")

    lines = Path("/proc/interrupts").read_text(
        encoding="utf-8", errors="replace"
    ).splitlines()

    rows: list[tuple[int, str]] = []
    for line in lines:
        match = re.match(r"^\s*(\d+):", line)
        if not match:
            continue
        irq = int(match.group(1))
        if irq not in allowed_irqs:
            continue
        # Intel ice data queue vectors are named TxRx. Do not treat admin/misc
        # vectors as dataplane queues.
        if "txrx" not in line.lower():
            continue
        rows.append((irq, line.strip()))

    rows.sort(key=lambda item: queue_index(item[1]))
    if args.expected_queues and len(rows) < args.expected_queues:
        raise SystemExit(
            f"ERROR: found only {len(rows)} TxRx queue IRQs for {args.iface}; "
            f"expected at least {args.expected_queues}"
        )
    if not rows:
        raise SystemExit(
            f"ERROR: no TxRx data queue IRQs found for {args.iface}; "
            "refusing to guess which MSI-X vectors carry data"
        )

    args.state_dir.mkdir(parents=True, exist_ok=True)
    audit = {
        "schema": "greenquic-p7-multicore-irq-map-v1",
        "iface": args.iface,
        "cpus": cpus,
        "expected_queues": args.expected_queues,
        "queue_irq_count": len(rows),
        "mappings": [],
    }

    for index, (irq, label) in enumerate(rows):
        target = cpus[index % len(cpus)]
        affinity = Path(f"/proc/irq/{irq}/smp_affinity_list")
        if not affinity.is_file():
            raise SystemExit(f"ERROR: missing affinity file for IRQ {irq}")
        before = affinity.read_text().strip()
        try:
            affinity.write_text(f"{target}\n")
        except OSError as exc:
            raise SystemExit(f"ERROR: cannot pin IRQ {irq} to CPU {target}: {exc}")
        after = affinity.read_text().strip()
        try:
            effective = parse_affinity(after)
        except Exception as exc:
            raise SystemExit(
                f"ERROR: cannot parse effective affinity IRQ {irq}: {after!r}: {exc}"
            )
        if effective != {target}:
            raise SystemExit(
                f"ERROR: IRQ {irq} affinity verification failed: "
                f"target={target} effective={after!r}"
            )
        audit["mappings"].append(
            {
                "queue_order": index,
                "irq": irq,
                "label": label,
                "cpu": target,
                "before": before,
                "after": after,
            }
        )

    used = {int(row["cpu"]) for row in audit["mappings"]}
    if len(cpus) > 1 and not set(cpus).issubset(used):
        raise SystemExit(
            f"ERROR: not every requested dataplane CPU received a queue IRQ: "
            f"requested={cpus} used={sorted(used)}"
        )

    out = args.state_dir / "multicore_irq_map.json"
    out.write_text(json.dumps(audit, indent=2) + "\n", encoding="utf-8")
    print(
        f"P7 multicore IRQ mapping PASS: iface={args.iface} "
        f"queue_irqs={len(rows)} cpus={','.join(map(str, cpus))}"
    )
    for row in audit["mappings"]:
        print(f"  IRQ {row['irq']} -> CPU {row['cpu']} :: {row['label']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
