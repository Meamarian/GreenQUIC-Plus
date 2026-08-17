#!/usr/bin/env python3
from __future__ import annotations

"""Apply P5 multicore TXQ V3 plus Performance2 composition fixes.

The N architecture case intentionally combines Performance2's per-producer
sharded SPSC handoff with exactly one DPDK consumer. In that composition the
multicore transform still emits queue-routing helpers that are deliberately not
used by the sharded producer/consumer path. With -Werror, those dead helpers
and the queue-local TxRing variable make an otherwise valid single-consumer
build fail.

The O UDP-seg architecture case keeps shared handoff, but Performance2 replaces
``Dpdk->TxCounter += TxCount`` with a logical-packet update. V3's legacy fallback
then places the per-lcore physical TX counter before ``TxCount`` is declared.
V4 moves that counter immediately after the logical TxCounter update, where
``TxCount`` is in scope and still represents the number of physical packets
successfully transmitted by this NIC queue.

V4 therefore:
  * preserves V3 behavior for normal shared-handoff profiles;
  * fixes per-lcore TX-counter placement for UDP segmentation; and
  * for sharded handoff only, removes/marks deliberately dead multi-queue
    routing pieces while keeping the one-consumer SPSC handoff unchanged.

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

# V3's normal placement key is ``Dpdk->TxCounter += TxCount``. UDP segmentation
# intentionally replaces that update with GreenQuicP2LogicalTxCount, so V3 falls
# back to an older GreenQuicOnTxPoll anchor that can occur before TxCount exists.
# Keep the queue-engagement metric physical: count the actual TxCount sent on the
# NIC queue, but place the accounting only after TxCount is declared and consumed
# by the logical TxCounter update.
mc_tx_counter = (
    "    if (Dpdk->GreenQuicEnableMultiCore && TxQueueId < RTE_MAX_LCORE && TxCount != 0) {\n"
    "        atomic_fetch_add_explicit(\n"
    "            &Dpdk->GreenQuicMcTxPacketsByQueue[TxQueueId],\n"
    "            TxCount,\n"
    "            memory_order_relaxed);\n"
    "    }\n"
)
udp_fixed = False
if "udpseg=1" in text:
    logical_update = "    Dpdk->TxCounter += GreenQuicP2LogicalTxCount;\n"
    tx_decl = "    const uint16_t TxCount =\n"
    if text.count(logical_update) != 1:
        raise SystemExit(
            f"ERROR: UDP V4 logical TxCounter update count={text.count(logical_update)}, expected 1"
        )
    if text.count(mc_tx_counter) != 1:
        raise SystemExit(
            f"ERROR: UDP V4 multicore TX counter block count={text.count(mc_tx_counter)}, expected 1"
        )
    if text.count(tx_decl) != 1:
        raise SystemExit(
            f"ERROR: UDP V4 TxCount declaration count={text.count(tx_decl)}, expected 1"
        )

    # Remove the misplaced V3 fallback block and reinsert it after the logical
    # TxCounter update. At that point TxCount has already been declared by the
    # UDP-seg TX statement and is safe to use for physical queue engagement.
    text = text.replace(mc_tx_counter, "", 1)
    text = text.replace(logical_update, logical_update + mc_tx_counter, 1)
    if text.find(mc_tx_counter) < text.find(tx_decl):
        raise SystemExit("ERROR: UDP V4 multicore TX counter still precedes TxCount declaration")
    udp_fixed = True

# Shared-handoff profiles need all queue-routing helpers. Only the sharded
# single-consumer composition has intentionally dead queue-routing helpers.
if "txhandoff=sharded" not in text:
    if udp_fixed:
        path.write_text(text, encoding="utf-8")
        print(
            "P5 multicore TXQ V4 PASS: shared UDP-seg handoff keeps physical "
            "per-lcore TX accounting after TxCount declaration"
        )
    else:
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
        "static struct rte_ring*\nGreenQuicGetTxRing(\n",
        "static __attribute__((unused)) struct rte_ring*\nGreenQuicGetTxRing(\n",
        "GreenQuicGetTxRing",
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
