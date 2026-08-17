#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import sys

MARKER = "GREENQUIC-P5-MULTICORE-LCORE-STATS-V1"
RUNTIME_SCHEMA = "greenquic-mc-lcore-v1"

if len(sys.argv) != 2:
    raise SystemExit("usage: apply_p5_multicore_lcore_stats.py PATH_TO_DATAPATH")

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

if MARKER in text:
    print(f"{MARKER} already present: {path}")
    raise SystemExit(0)

required = (
    "GREENQUIC-P5-MULTICORE-TXQ-V1",
    "GreenQuicMcRxPacketsByQueue",
    "GreenQuicMcTxPacketsByQueue",
    "GreenQuicRxQueueByLcore",
    "GreenQuicTxQueueByLcore",
    "greenquic-mc-queue-v1",
)
missing = [item for item in required if item not in text]
if missing:
    raise SystemExit(
        "ERROR: per-lcore stats transform requires multicore TXQ transform first; missing: "
        + ", ".join(missing)
    )

anchor = '''        printf(" tx_hash_fallback=%" PRIuFAST64 "\\n",
            atomic_load_explicit(&Dpdk->GreenQuicMcTxHashFallbacks, memory_order_relaxed));
    }
    for (uint16_t q = 1; q < RTE_MAX_LCORE; ++q) {
'''

insert = '''        printf(" tx_hash_fallback=%" PRIuFAST64 "\\n",
            atomic_load_explicit(&Dpdk->GreenQuicMcTxHashFallbacks, memory_order_relaxed));

        /* GREENQUIC-P5-MULTICORE-LCORE-STATS-V1
         * Queue counters above prove traffic distribution, but a queue number is
         * not itself a CPU. Emit the role map and the queue counters together so
         * every run has direct lcore->RX/TX work evidence, including OFF mode. */
        unsigned int GqMcStatsLcore;
        RTE_LCORE_FOREACH(GqMcStatsLcore) {
            if (GqMcStatsLcore >= RTE_MAX_LCORE) {
                continue;
            }
            const uint16_t RxQueueId = Dpdk->GreenQuicRxQueueByLcore[GqMcStatsLcore];
            const uint16_t TxQueueId = Dpdk->GreenQuicTxQueueByLcore[GqMcStatsLcore];
            const BOOLEAN OwnsRx = RxQueueId != UINT16_MAX;
            const BOOLEAN OwnsTx = TxQueueId != UINT16_MAX;
            if (!OwnsRx && !OwnsTx) {
                continue;
            }
            const uint64_t RxPackets =
                OwnsRx ? (uint64_t)atomic_load_explicit(
                    &Dpdk->GreenQuicMcRxPacketsByQueue[RxQueueId],
                    memory_order_relaxed) : 0;
            const uint64_t TxPackets =
                OwnsTx ? (uint64_t)atomic_load_explicit(
                    &Dpdk->GreenQuicMcTxPacketsByQueue[TxQueueId],
                    memory_order_relaxed) : 0;
            printf(
                "[GreenQUIC-MC] LCORE_STATS schema=greenquic-mc-lcore-v1 "
                "lcore=%u rxq=%hu txq=%hu owns_rx=%u owns_tx=%u "
                "rx_pkts=%" PRIu64 " tx_pkts=%" PRIu64 " total_pkts=%" PRIu64 "\\n",
                GqMcStatsLcore,
                OwnsRx ? RxQueueId : UINT16_MAX,
                OwnsTx ? TxQueueId : UINT16_MAX,
                OwnsRx ? 1U : 0U,
                OwnsTx ? 1U : 0U,
                RxPackets,
                TxPackets,
                RxPackets + TxPackets);
        }
    }
    for (uint16_t q = 1; q < RTE_MAX_LCORE; ++q) {
'''

count = text.count(anchor)
if count != 1:
    raise SystemExit(
        f"ERROR: queue-stats cleanup anchor count={count}, expected exactly 1"
    )

text = text.replace(anchor, insert, 1)
text = f"/* {MARKER} */\n" + text
path.write_text(text, encoding="utf-8")
print(f"P5 multicore per-lcore runtime stats transform applied: {path}")
