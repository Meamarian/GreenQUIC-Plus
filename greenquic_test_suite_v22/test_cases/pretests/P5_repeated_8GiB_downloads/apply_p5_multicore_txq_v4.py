#!/usr/bin/env python3
from __future__ import annotations

"""Apply P5 multicore TXQ V3 plus sharded single-consumer compile cleanup.

The N architecture case intentionally combines Performance2's per-producer
sharded SPSC handoff with exactly one DPDK consumer. In that composition the
multicore transform still emits queue-routing helpers that are deliberately not
used by the sharded producer path. With -Werror, those dead helpers and the
queue-local TxRing variable make an otherwise valid single-consumer build fail.

V4 keeps V3 behavior unchanged for shared handoff. For sharded handoff only it:
  * removes the unused queue-local TxRing variable from CxPlatDpdkTx; and
  * marks the two deliberately unused multi-queue producer helpers as unused.

No sharded producer is routed to multiple DPDK consumers; N remains a
single-consumer experiment.
"""

from pathlib import Path
import subprocess
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: apply_p5_multicore_txq_v4.py PATH_TO_DATAPATH")

here = Path(__file__).resolve().parent
v3 = here / "apply_p5_multicore_txq_v3.py"
if not v3.is_file():
    raise SystemExit(f"ERROR: missing V3 transform dependency: {v3}")

path = Path(sys.argv[1])
subprocess.run([sys.executable, str(v3), str(path)], check=True)
text = path.read_text(encoding="utf-8", errors="replace")

# Shared-handoff profiles need all queue-routing helpers. Only the sharded
# single-consumer composition has intentionally dead producer-routing helpers.
if "txhandoff=sharded" not in text:
    print("P5 multicore TXQ V4 PASS: shared handoff unchanged")
    raise SystemExit(0)

old_txring = "    struct rte_ring* TxRing = GreenQuicGetTxRing(Dpdk, Interface, Core);\n"
count = text.count(old_txring)
if count != 1:
    raise SystemExit(
        f"ERROR: sharded V4 expected one queue-local TxRing declaration, found {count}"
    )
text = text.replace(old_txring, "", 1)

replacements = (
    (
        "static void\nGreenQuicSignalTxQueueWork(\n",
        "static __attribute__((unused)) void\nGreenQuicSignalTxQueueWork(\n",
        "GreenQuicSignalTxQueueWork",
    ),
    (
        "static uint16_t\nGreenQuicSelectTxQueue(\n",
        "static __attribute__((unused)) uint16_t\nGreenQuicSelectTxQueue(\n",
        "GreenQuicSelectTxQueue",
    ),
)
for old, new, label in replacements:
    n = text.count(old)
    if n != 1:
        raise SystemExit(f"ERROR: sharded V4 {label} definition count={n}, expected 1")
    text = text.replace(old, new, 1)

# Fail closed if the sharded consumer path was accidentally converted back to
# a queue-local software-ring consumer.
if "GreenQuicP2TxDequeueBurst(" not in text:
    raise SystemExit("ERROR: sharded V4 cannot prove GreenQuicP2TxDequeueBurst path")
if old_txring in text:
    raise SystemExit("ERROR: sharded V4 left an unused queue-local TxRing declaration")

path.write_text(text, encoding="utf-8")
print(
    "P5 multicore TXQ V4 PASS: sharded single-consumer composition keeps "
    "producer SPSC handoff and compiles without dead multi-queue helpers"
)
