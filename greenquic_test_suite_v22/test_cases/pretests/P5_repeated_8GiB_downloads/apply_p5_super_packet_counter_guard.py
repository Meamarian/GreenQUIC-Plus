#!/usr/bin/env python3
"""Preserve P5 packet totals when the producer-only debug counter is disabled.

apply_p5_datapath_fix.py emits RxCounter/TxCounter once at teardown for P5 result
validation.  The original super transformer predates that dependency and its
`--debug-counters=0` switch removes all three debug counter updates.  For P5 we
must preserve RxCounter/TxCounter and eliminate only the unused multi-producer
TxEnqueueCounter write.
"""
from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: apply_p5_super_packet_counter_guard.py DEBUG_COUNTERS datapath.c")

debug = sys.argv[1]
path = Path(sys.argv[2])
if debug not in ("0", "1"):
    raise SystemExit("ERROR: DEBUG_COUNTERS must be 0 or 1")

text = path.read_text(encoding="utf-8")

if "GREENQUIC-P5-DATAPATH-PACKET-TOTALS-V1" not in text:
    raise SystemExit("ERROR: P5 packet-total fix marker is missing")

if debug == "0":
    replacements = {
        "    /* GREENQUIC-P5-SUPER: debugging RxCounter disabled. */":
            "    Dpdk->RxCounter += BuffersCount;",
        "    /* GREENQUIC-P5-SUPER: debugging TxCounter disabled. */":
            "    Dpdk->TxCounter += TxCount;",
    }
    for old, new in replacements.items():
        count = text.count(old)
        if count != 1:
            raise SystemExit(f"ERROR: packet-counter guard expected one anchor, found {count}: {old}")
        text = text.replace(old, new, 1)

    disabled = "    /* GREENQUIC-P5-SUPER: debugging TxEnqueueCounter disabled. */"
    if text.count(disabled) != 1:
        raise SystemExit("ERROR: TxEnqueueCounter was not independently disabled")

    if "Dpdk->TxEnqueueCounter++;" in text:
        raise SystemExit("ERROR: producer-side TxEnqueueCounter update is still present")

# P5 teardown validation requires both datapath totals to keep updating.
for required in ("Dpdk->RxCounter += BuffersCount;", "Dpdk->TxCounter += TxCount;"):
    if text.count(required) != 1:
        raise SystemExit(f"ERROR: required P5 packet-total update missing: {required}")

path.write_text(text, encoding="utf-8")
print(
    "P5 super packet-counter guard PASS: "
    + ("TxEnqueueCounter disabled; RxCounter/TxCounter preserved" if debug == "0" else "all original counters preserved")
)
