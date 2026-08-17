#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import re
import sys

MARKER = "GREENQUIC-P5-MULTICORE-TXQ-V1"

if len(sys.argv) != 2:
    raise SystemExit("usage: apply_p5_multicore_txq.py PATH_TO_DATAPATH")

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
if MARKER in text:
    print(f"{MARKER} already present: {path}")
    raise SystemExit(0)


def replace_once(old: str, new: str, label: str) -> None:
    global text
    n = text.count(old)
    if n != 1:
        raise SystemExit(f"ERROR: {label}: expected one anchor, found {n}")
    text = text.replace(old, new, 1)


def function_slice(name: str, next_name: str) -> tuple[int, int, str]:
    start = text.find(name)
    if start < 0:
        raise SystemExit(f"ERROR: function anchor missing: {name}")
    # Walk back to the nearest static/IRQL declaration so replacements remain
    # scoped to the intended C function.
    back = max(text.rfind("\nstatic", 0, start), text.rfind("\n_IRQL", 0, start))
    if back >= 0:
        start = back + 1
    end = text.find(next_name, start + len(name))
    if end < 0:
        raise SystemExit(f"ERROR: next function anchor missing after {name}: {next_name}")
    return start, end, text[start:end]


def replace_in_function(name: str, next_name: str, old: str, new: str, label: str, minimum: int = 1) -> None:
    global text
    start, end, body = function_slice(name, next_name)
    n = body.count(old)
    if n < minimum:
        raise SystemExit(f"ERROR: {label}: expected >= {minimum} scoped anchors, found {n}")
    body = body.replace(old, new)
    text = text[:start] + body + text[end:]


# Interface owns one software ring per NIC TX queue in multicore mode. Queue 0
# aliases the existing TxRingBuffer so the single-core path remains unchanged.
replace_once(
    "    struct rte_ring* TxRingBuffer;\n",
    "    struct rte_ring* TxRingBuffer;\n"
    "    /* GREENQUIC-P5-MULTICORE-TXQ-V1 */\n"
    "    struct rte_ring* TxRingByQueue[RTE_MAX_LCORE];\n",
    "DPDK interface TX ring field",
)

replace_once(
    "    uint16_t GreenQuicTxOwnerLcore;  // dedicated shared-ring TX consumer\n"
    "    BOOLEAN GreenQuicTxOwnerConfigured;\n",
    "    uint16_t GreenQuicTxOwnerLcore;  // queue-0 owner / legacy compatibility\n"
    "    BOOLEAN GreenQuicTxOwnerConfigured;\n"
    "    /* GREENQUIC-P5-MULTICORE-TXQ-V1 */\n"
    "    uint16_t GreenQuicTxQueueByLcore[RTE_MAX_LCORE];\n"
    "    uint16_t GreenQuicTxOwnerByQueue[RTE_MAX_LCORE];\n"
    "    uint16_t GreenQuicTxOwnerCount;\n"
    "    atomic_uint_fast64_t GreenQuicMcRxPacketsByQueue[RTE_MAX_LCORE];\n"
    "    atomic_uint_fast64_t GreenQuicMcTxPacketsByQueue[RTE_MAX_LCORE];\n"
    "    atomic_uint_fast64_t GreenQuicMcTxHashFallbacks;\n",
    "DPDK TX-owner fields",
)

# Prototypes are inserted next to the existing ownership helpers.
replace_once(
    "static BOOLEAN GreenQuicLcoreOwnsTx(_In_ const DPDK_DATAPATH* Dpdk, _In_ uint16_t Core);\n",
    "static BOOLEAN GreenQuicLcoreOwnsTx(_In_ const DPDK_DATAPATH* Dpdk, _In_ uint16_t Core);\n"
    "static uint16_t GreenQuicGetTxQueueId(_In_ const DPDK_DATAPATH* Dpdk, _In_ uint16_t Core);\n"
    "static struct rte_ring* GreenQuicGetTxRing(_In_ const DPDK_DATAPATH* Dpdk, _In_ DPDK_INTERFACE* Interface, _In_ uint16_t Core);\n"
    "static void GreenQuicSignalTxQueueWork(_Inout_ DPDK_DATAPATH* Dpdk, _In_ uint16_t QueueId);\n"
    "static uint16_t GreenQuicSelectTxQueue(_Inout_ DPDK_DATAPATH* Dpdk, _In_ const struct rte_mbuf* Mbuf);\n",
    "TX ownership prototypes",
)

# Initialize both maps in GreenQuicConfigureRoles.
replace_once(
    "    for (uint16_t Index = 0; Index < RTE_MAX_LCORE; ++Index) {\n"
    "        Dpdk->GreenQuicRxQueueByLcore[Index] = UINT16_MAX;\n"
    "    }\n"
    "    Dpdk->GreenQuicRxOwnerCount = 0;\n",
    "    for (uint16_t Index = 0; Index < RTE_MAX_LCORE; ++Index) {\n"
    "        Dpdk->GreenQuicRxQueueByLcore[Index] = UINT16_MAX;\n"
    "        Dpdk->GreenQuicTxQueueByLcore[Index] = UINT16_MAX;\n"
    "        Dpdk->GreenQuicTxOwnerByQueue[Index] = UINT16_MAX;\n"
    "    }\n"
    "    Dpdk->GreenQuicRxOwnerCount = 0;\n"
    "    Dpdk->GreenQuicTxOwnerCount = 0;\n",
    "role-map initialization",
)

# Replace the one-TX-queue multicore assignment with one TX queue per active
# RX/DPDK lcore. The experiment fails closed if the NIC cannot provide enough
# TX queues; silently falling back would make the P5/P7 comparison invalid.
replace_once(
    "        Dpdk->GreenQuicRxOwnerCount = NextRxQueue;\n"
    "        Dpdk->GreenQuicQueueCount = NextRxQueue;\n"
    "        *RxRings = NextRxQueue == 0 ? 1 : NextRxQueue;\n"
    "        *TxRings = 1;\n",
    "        Dpdk->GreenQuicRxOwnerCount = NextRxQueue;\n"
    "        Dpdk->GreenQuicQueueCount = NextRxQueue;\n"
    "        *RxRings = NextRxQueue == 0 ? 1 : NextRxQueue;\n\n"
    "        uint16_t NextTxQueue = 0;\n"
    "        const uint16_t MaxTxQueues =\n"
    "            DeviceInfo->max_tx_queues == 0 ? 1 : DeviceInfo->max_tx_queues;\n"
    "        if (Dpdk->GreenQuicEnableTx) {\n"
    "            RTE_LCORE_FOREACH(Lcore) {\n"
    "                if (Lcore >= RTE_MAX_LCORE ||\n"
    "                    Dpdk->GreenQuicRxQueueByLcore[Lcore] == UINT16_MAX) {\n"
    "                    continue;\n"
    "                }\n"
    "                if (NextTxQueue >= MaxTxQueues) {\n"
    "                    fprintf(stderr,\n"
    "                        \"GreenQUIC multicore TX: NIC has only %hu TX queues for %hu DPDK owners.\\n\",\n"
    "                        MaxTxQueues, NextRxQueue);\n"
    "                    break;\n"
    "                }\n"
    "                Dpdk->GreenQuicTxQueueByLcore[Lcore] = NextTxQueue;\n"
    "                Dpdk->GreenQuicTxOwnerByQueue[NextTxQueue] = (uint16_t)Lcore;\n"
    "                if (NextTxQueue == 0) {\n"
    "                    Dpdk->GreenQuicTxOwnerLcore = (uint16_t)Lcore;\n"
    "                    Dpdk->GreenQuicTxOwnerConfigured = TRUE;\n"
    "                }\n"
    "                ++NextTxQueue;\n"
    "            }\n"
    "            if (NextTxQueue != NextRxQueue || NextTxQueue < 2) {\n"
    "                fprintf(stderr,\n"
    "                    \"GreenQUIC multicore TX requires one TX queue per DPDK RX owner; rx=%hu tx=%hu max_tx=%hu.\\n\",\n"
    "                    NextRxQueue, NextTxQueue, MaxTxQueues);\n"
    "                NextTxQueue = 0;\n"
    "            }\n"
    "        }\n"
    "        Dpdk->GreenQuicTxOwnerCount = NextTxQueue;\n"
    "        *TxRings = NextTxQueue == 0 ? 1 : NextTxQueue;\n",
    "multicore TX ring count",
)

# Single-core compatibility map.
replace_once(
    "        if (Dpdk->GreenQuicEnableTx && !Dpdk->SeparateTxThread) {\n"
    "            Dpdk->GreenQuicTxOwnerLcore = MainLcore;\n"
    "        }\n"
    "        *RxRings = 1;\n"
    "        *TxRings = 1;\n",
    "        if (Dpdk->GreenQuicEnableTx && !Dpdk->SeparateTxThread) {\n"
    "            Dpdk->GreenQuicTxOwnerLcore = MainLcore;\n"
    "            if (MainLcore < RTE_MAX_LCORE) {\n"
    "                Dpdk->GreenQuicTxQueueByLcore[MainLcore] = 0;\n"
    "                Dpdk->GreenQuicTxOwnerByQueue[0] = MainLcore;\n"
    "                Dpdk->GreenQuicTxOwnerCount = 1;\n"
    "            }\n"
    "        }\n"
    "        *RxRings = 1;\n"
    "        *TxRings = 1;\n",
    "single-core TX compatibility map",
)

# Ownership is queue-map based in multicore; legacy/single-core behavior stays
# on GreenQuicTxOwnerLcore.
replace_once(
    "    return Dpdk->GreenQuicEnableTx &&\n"
    "        Core == Dpdk->GreenQuicTxOwnerLcore;\n"
    "}\n\nstatic void\nGreenQuicGetDirectionalHintsForCore(",
    "    if (!Dpdk->GreenQuicEnableTx) {\n"
    "        return FALSE;\n"
    "    }\n"
    "    if (!Dpdk->GreenQuicEnableMultiCore) {\n"
    "        return Core == Dpdk->GreenQuicTxOwnerLcore;\n"
    "    }\n"
    "    return Core < RTE_MAX_LCORE &&\n"
    "        Dpdk->GreenQuicTxQueueByLcore[Core] != UINT16_MAX;\n"
    "}\n\n"
    "static uint16_t\n"
    "GreenQuicGetTxQueueId(\n"
    "    _In_ const DPDK_DATAPATH* Dpdk,\n"
    "    _In_ uint16_t Core\n"
    "    )\n"
    "{\n"
    "    if (Dpdk->GreenQuicEnableMultiCore && Core < RTE_MAX_LCORE &&\n"
    "        Dpdk->GreenQuicTxQueueByLcore[Core] != UINT16_MAX) {\n"
    "        return Dpdk->GreenQuicTxQueueByLcore[Core];\n"
    "    }\n"
    "    return 0;\n"
    "}\n\n"
    "static struct rte_ring*\n"
    "GreenQuicGetTxRing(\n"
    "    _In_ const DPDK_DATAPATH* Dpdk,\n"
    "    _In_ DPDK_INTERFACE* Interface,\n"
    "    _In_ uint16_t Core\n"
    "    )\n"
    "{\n"
    "    const uint16_t QueueId = GreenQuicGetTxQueueId(Dpdk, Core);\n"
    "    if (QueueId < RTE_MAX_LCORE && Interface->TxRingByQueue[QueueId] != NULL) {\n"
    "        return Interface->TxRingByQueue[QueueId];\n"
    "    }\n"
    "    return Interface->TxRingBuffer;\n"
    "}\n\nstatic void\nGreenQuicGetDirectionalHintsForCore(",
    "TX ownership helper",
)

# Policy/idle logic must observe each owner's local software ring rather than
# queue 0. These functions are untouched by the Performance2 hot-path patchers.
for fn, nxt in (
    ("GreenQuicCanEnterWorkWait(", "GreenQuicSignalLcoreWork("),
    ("GreenQuicTryCStateIdle(", "GreenQuicOnRxPoll("),
    ("GreenQuicApplyPolicy(", "GreenQuicMaybePrintStats("),
):
    replace_in_function(
        fn,
        nxt,
        "rte_ring_count(Interface->TxRingBuffer)",
        "rte_ring_count(GreenQuicGetTxRing(Dpdk, Interface, Core))",
        f"local TX ring in {fn}",
    )

# Add queue-specific wakeup selection. Queue 0 remains compatible with the old
# helper and OFF still bypasses all wake bookkeeping through SignalLcoreWork.
replace_once(
    "static uint64_t\nGreenQuicWatchdogDeadline(",
    "static void\n"
    "GreenQuicSignalTxQueueWork(\n"
    "    _Inout_ DPDK_DATAPATH* Dpdk,\n"
    "    _In_ uint16_t QueueId\n"
    "    )\n"
    "{\n"
    "    if (Dpdk->GreenQuicEnableMultiCore && QueueId < RTE_MAX_LCORE &&\n"
    "        Dpdk->GreenQuicTxOwnerByQueue[QueueId] != UINT16_MAX) {\n"
    "        GreenQuicSignalLcoreWork(Dpdk, Dpdk->GreenQuicTxOwnerByQueue[QueueId]);\n"
    "        return;\n"
    "    }\n"
    "    GreenQuicSignalTxWork(Dpdk);\n"
    "}\n\nstatic uint64_t\nGreenQuicWatchdogDeadline(",
    "queue-specific TX wake helper",
)

# Create extra software rings after role discovery and before rte_eth_dev_configure.
replace_once(
    "    GreenQuicConfigureRoles(\n"
    "        Dpdk, &DeviceInfo, &PortConfig, &rx_rings, &tx_rings);\n\n"
    "    // Set MTU\n",
    "    GreenQuicConfigureRoles(\n"
    "        Dpdk, &DeviceInfo, &PortConfig, &rx_rings, &tx_rings);\n\n"
    "    for (uint16_t q = 0; q < RTE_MAX_LCORE; ++q) {\n"
    "        Dpdk->Interface.TxRingByQueue[q] = NULL;\n"
    "    }\n"
    "    Dpdk->Interface.TxRingByQueue[0] = Dpdk->Interface.TxRingBuffer;\n"
    "    if (Dpdk->GreenQuicEnableMultiCore && Dpdk->GreenQuicEnableTx) {\n"
    "        if (Dpdk->GreenQuicTxOwnerCount != tx_rings || tx_rings < 2) {\n"
    "            fprintf(stderr,\n"
    "                \"GreenQUIC multicore TX queue topology invalid: owners=%hu tx_rings=%hu.\\n\",\n"
    "                Dpdk->GreenQuicTxOwnerCount, tx_rings);\n"
    "            Status = QUIC_STATUS_INVALID_STATE;\n"
    "            goto Error;\n"
    "        }\n"
    "        for (uint16_t q = 1; q < tx_rings; ++q) {\n"
    "            char RingName[32];\n"
    "            snprintf(RingName, sizeof(RingName), \"TxRing%hu\", q);\n"
    "            Dpdk->Interface.TxRingByQueue[q] = rte_ring_create(\n"
    "                RingName,\n"
    "                Dpdk->TxRingSize,\n"
    "                rte_eth_dev_socket_id(Port),\n"
    "                RING_F_MP_HTS_ENQ | RING_F_SC_DEQ);\n"
    "            if (Dpdk->Interface.TxRingByQueue[q] == NULL) {\n"
    "                fprintf(stderr, \"GreenQUIC failed to create %s.\\n\", RingName);\n"
    "                Status = QUIC_STATUS_OUT_OF_MEMORY;\n"
    "                goto Error;\n"
    "            }\n"
    "        }\n"
    "    }\n\n"
    "    // Set MTU\n",
    "extra multicore software TX rings",
)

# Extra rings must be freed before queue 0. Also emit mode-independent queue
# counters so OFF/BASIC/PLUS all prove whether both queues carried traffic.
replace_once(
    "    if (Dpdk->Interface.TxRingBuffer) {\n"
    "        rte_ring_free(Dpdk->Interface.TxRingBuffer);\n"
    "    }\n",
    "    if (Dpdk->GreenQuicEnableMultiCore) {\n"
    "        printf(\"[GreenQUIC-MC] QUEUE_STATS schema=greenquic-mc-queue-v1\");\n"
    "        for (uint16_t q = 0; q < Dpdk->GreenQuicRxOwnerCount; ++q) {\n"
    "            printf(\" rxq%hu=%\" PRIuFAST64, q,\n"
    "                atomic_load_explicit(&Dpdk->GreenQuicMcRxPacketsByQueue[q], memory_order_relaxed));\n"
    "        }\n"
    "        for (uint16_t q = 0; q < Dpdk->GreenQuicTxOwnerCount; ++q) {\n"
    "            printf(\" txq%hu=%\" PRIuFAST64, q,\n"
    "                atomic_load_explicit(&Dpdk->GreenQuicMcTxPacketsByQueue[q], memory_order_relaxed));\n"
    "        }\n"
    "        printf(\" tx_hash_fallback=%\" PRIuFAST64 \"\\n\",\n"
    "            atomic_load_explicit(&Dpdk->GreenQuicMcTxHashFallbacks, memory_order_relaxed));\n"
    "    }\n"
    "    for (uint16_t q = 1; q < RTE_MAX_LCORE; ++q) {\n"
    "        if (Dpdk->Interface.TxRingByQueue[q] != NULL) {\n"
    "            rte_ring_free(Dpdk->Interface.TxRingByQueue[q]);\n"
    "            Dpdk->Interface.TxRingByQueue[q] = NULL;\n"
    "        }\n"
    "    }\n"
    "    if (Dpdk->Interface.TxRingBuffer) {\n"
    "        rte_ring_free(Dpdk->Interface.TxRingBuffer);\n"
    "        Dpdk->Interface.TxRingBuffer = NULL;\n"
    "    }\n",
    "TX ring cleanup",
)

# Count all RX packets before mode-specific processing returns. This metric is
# intentionally outside GreenQUIC policy so OFF can be validated too.
replace_once(
    "    if (unlikely(BuffersCount == 0)) {\n"
    "        return;\n"
    "    }\n\n"
    "    Dpdk->RxCounter += BuffersCount;\n",
    "    if (unlikely(BuffersCount == 0)) {\n"
    "        return;\n"
    "    }\n\n"
    "    if (Dpdk->GreenQuicEnableMultiCore && QueueId < RTE_MAX_LCORE) {\n"
    "        atomic_fetch_add_explicit(\n"
    "            &Dpdk->GreenQuicMcRxPacketsByQueue[QueueId],\n"
    "            BuffersCount,\n"
    "            memory_order_relaxed);\n"
    "    }\n"
    "    Dpdk->RxCounter += BuffersCount;\n",
    "mode-independent RX queue counter",
)

# Stable IPv4/UDP 4-tuple hash. Forced distinct client source ports make each
# QUIC connection a distinct flow. Same flow => same TX queue => no cross-queue
# reordering inside a connection. This logic is mode-independent.
enqueue_anchor = "_IRQL_requires_max_(DISPATCH_LEVEL)\nvoid\nCxPlatDpRawTxEnqueue("
insert = r'''// GREENQUIC-P5-MULTICORE-TXQ-V1
static uint16_t
GreenQuicSelectTxQueue(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_ const struct rte_mbuf* Mbuf
    )
{
    if (!Dpdk->GreenQuicEnableMultiCore || Dpdk->GreenQuicTxOwnerCount <= 1) {
        return 0;
    }
    const uint8_t* Base = rte_pktmbuf_mtod(Mbuf, const uint8_t*);
    const uint32_t Length = rte_pktmbuf_data_len(Mbuf);
    const uint32_t L2 = Mbuf->l2_len;
    if (Base == NULL || Length < L2 + 20U) {
        atomic_fetch_add_explicit(&Dpdk->GreenQuicMcTxHashFallbacks, 1, memory_order_relaxed);
        return 0;
    }
    const uint8_t* Ip = Base + L2;
    if ((Ip[0] >> 4) != 4U || Ip[9] != 17U) {
        atomic_fetch_add_explicit(&Dpdk->GreenQuicMcTxHashFallbacks, 1, memory_order_relaxed);
        return 0;
    }
    const uint32_t Ihl = (uint32_t)(Ip[0] & 0x0fU) * 4U;
    if (Ihl < 20U || Length < L2 + Ihl + 8U) {
        atomic_fetch_add_explicit(&Dpdk->GreenQuicMcTxHashFallbacks, 1, memory_order_relaxed);
        return 0;
    }
    const uint8_t* Udp = Ip + Ihl;
    uint32_t Hash = 2166136261u;
    for (uint32_t i = 12; i < 20; ++i) {
        Hash = (Hash ^ Ip[i]) * 16777619u;
    }
    for (uint32_t i = 0; i < 4; ++i) {
        Hash = (Hash ^ Udp[i]) * 16777619u;
    }
    return (uint16_t)(Hash % Dpdk->GreenQuicTxOwnerCount);
}

'''
idx = text.find(enqueue_anchor)
if idx < 0:
    raise SystemExit("ERROR: TxEnqueue function anchor missing")
text = text[:idx] + insert + text[idx:]

# Scope-rewrite enqueue to the selected software ring and selected owner's wake.
start, end, body = function_slice("CxPlatDpRawTxEnqueue(", "CxPlatDpdkTx(")
if "Interface->TxRingBuffer" not in body:
    raise SystemExit("ERROR: TxEnqueue no longer contains shared ring anchor")
# Declare routing immediately after Dpdk/Interface are available. Performance2
# may add diagnostics around this point, so anchor only the common declarations.
decl = "    DPDK_DATAPATH* Dpdk = Packet->Dpdk;\n    DPDK_INTERFACE* Interface = Packet->Interface;\n"
if decl not in body:
    raise SystemExit("ERROR: TxEnqueue Dpdk/Interface declarations changed")
body = body.replace(
    decl,
    decl +
    "    const uint16_t TxQueueId = GreenQuicSelectTxQueue(Dpdk, Packet->Mbuf);\n"
    "    struct rte_ring* TxRing =\n"
    "        TxQueueId < RTE_MAX_LCORE && Interface->TxRingByQueue[TxQueueId] != NULL ?\n"
    "            Interface->TxRingByQueue[TxQueueId] : Interface->TxRingBuffer;\n",
    1,
)
body = body.replace("Interface->TxRingBuffer", "TxRing")
body = body.replace("GreenQuicSignalTxWork(Dpdk);", "GreenQuicSignalTxQueueWork(Dpdk, TxQueueId);")
text = text[:start] + body + text[end:]

# Scope-rewrite the TX consumer. Performance2 may have changed drain batching,
# but every dequeue/ring-count and every NIC burst in this function must use
# the lcore's queue. The transform therefore operates structurally on the
# function body instead of a whole-function string.
start, end, body = function_slice("CxPlatDpdkTx(", "CxPlatDpdkRxWorkerThread(")
# Replace the old one-owner guard if it survived Performance2.
body = body.replace(
    "    if (Dpdk->GreenQuicEnableMultiCore &&\n"
    "        Core != Dpdk->GreenQuicTxOwnerLcore) {\n"
    "        return;\n"
    "    }\n",
    "    if (Dpdk->GreenQuicEnableMultiCore && !GreenQuicLcoreOwnsTx(Dpdk, Core)) {\n"
    "        return;\n"
    "    }\n",
)
# Insert queue/ring declarations after Interface.
anchor = "    DPDK_INTERFACE* Interface = &Dpdk->Interface;\n"
if anchor not in body:
    raise SystemExit("ERROR: CxPlatDpdkTx Interface declaration changed")
body = body.replace(
    anchor,
    anchor +
    "    const uint16_t TxQueueId = GreenQuicGetTxQueueId(Dpdk, Core);\n"
    "    struct rte_ring* TxRing = GreenQuicGetTxRing(Dpdk, Interface, Core);\n",
    1,
)
body = body.replace("Interface->TxRingBuffer", "TxRing")
# Handle both tracked and direct burst forms without touching unrelated calls.
body = re.sub(
    r"(GreenQuicTrackedTxBurst\(\s*Interface->Port,\s*)0(\s*,)",
    r"\1TxQueueId\2",
    body,
)
body = re.sub(
    r"(rte_eth_tx_burst\(\s*Interface->Port,\s*)0(\s*,)",
    r"\1TxQueueId\2",
    body,
)
# Count successfully transmitted packets per NIC queue after the existing
# TxCounter update when possible; otherwise after GreenQuicOnTxPoll.
if "Dpdk->TxCounter += TxCount;" in body:
    body = body.replace(
        "    Dpdk->TxCounter += TxCount;\n",
        "    Dpdk->TxCounter += TxCount;\n"
        "    if (Dpdk->GreenQuicEnableMultiCore && TxQueueId < RTE_MAX_LCORE && TxCount != 0) {\n"
        "        atomic_fetch_add_explicit(\n"
        "            &Dpdk->GreenQuicMcTxPacketsByQueue[TxQueueId],\n"
        "            TxCount,\n"
        "            memory_order_relaxed);\n"
        "    }\n",
        1,
    )
else:
    # Performance2 may replace debugging TxCounter. Put the count before the
    # first GreenQuicOnTxPoll call, which remains mandatory for BASIC/PLUS.
    marker = "    GreenQuicOnTxPoll("
    pos = body.find(marker)
    if pos < 0:
        raise SystemExit("ERROR: cannot place multicore TX packet counter")
    body = body[:pos] + (
        "    if (Dpdk->GreenQuicEnableMultiCore && TxQueueId < RTE_MAX_LCORE && TxCount != 0) {\n"
        "        atomic_fetch_add_explicit(\n"
        "            &Dpdk->GreenQuicMcTxPacketsByQueue[TxQueueId],\n"
        "            TxCount,\n"
        "            memory_order_relaxed);\n"
        "    }\n"
    ) + body[pos:]
text = text[:start] + body + text[end:]

# Verify that no old shared-ring policy references survive in the key paths.
for fn, nxt in (
    ("GreenQuicCanEnterWorkWait(", "GreenQuicSignalLcoreWork("),
    ("GreenQuicTryCStateIdle(", "GreenQuicOnRxPoll("),
    ("GreenQuicApplyPolicy(", "GreenQuicMaybePrintStats("),
    ("CxPlatDpdkTx(", "CxPlatDpdkRxWorkerThread("),
):
    _, _, body = function_slice(fn, nxt)
    if "Interface->TxRingBuffer" in body:
        raise SystemExit(f"ERROR: shared TX ring reference remains in {fn}")

text = "/* " + MARKER + " */\n" + text
path.write_text(text, encoding="utf-8")
print(f"P5 multicore two-TX-queue transform applied: {path}")
