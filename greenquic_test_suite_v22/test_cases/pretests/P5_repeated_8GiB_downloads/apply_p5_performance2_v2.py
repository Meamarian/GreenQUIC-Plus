#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path
import re

p = argparse.ArgumentParser(
    description="Apply second-stage P5 Performance2 TX/RX hot-path experiments."
)
p.add_argument("datapath")
p.add_argument("--tx-alloc-batch", type=int, default=1)
p.add_argument("--tx-enqueue-counter", choices=("0", "1"), default="1")
p.add_argument("--tx-meta-zero", choices=("0", "1"), default="1")
p.add_argument("--rx-pipe-prefetch", type=int, default=0)
p.add_argument("--shard-active-mask", choices=("0", "1"), default="0")
args = p.parse_args()

if args.tx_alloc_batch not in (1, 8, 16, 32):
    raise SystemExit("ERROR: --tx-alloc-batch must be 1,8,16,32")
if args.rx_pipe_prefetch not in (0, 2, 4):
    raise SystemExit("ERROR: --rx-pipe-prefetch must be 0,2,4")

path = Path(args.datapath)
text = path.read_text(encoding="utf-8")

for required in ("GREENQUIC-P5-SUPER-PERF-V2", "GREENQUIC-P5-PERFORMANCE2-V1"):
    if required not in text:
        raise SystemExit(f"ERROR: required marker missing: {required}")
if "GREENQUIC-P5-PERFORMANCE2-V2" in text:
    raise SystemExit("ERROR: performance2 V2 transform already applied")

v1 = re.search(
    r"GREENQUIC-P5-PERFORMANCE2-V1[^\"\n]*txhandoff=(?P<handoff>\w+)[^\"\n]*"
    r"rxprefetch=(?P<rxprefetch>[01])[^\"\n]*udpseg=(?P<udpseg>[01])",
    text,
)
if v1 is None:
    raise SystemExit("ERROR: cannot determine Performance2 V1 feature state")
if args.tx_meta_zero == "0" and v1.group("udpseg") != "0":
    raise SystemExit(
        "ERROR: --tx-meta-zero=0 is intentionally restricted to P5_P2_UDP_SEG=0; "
        "the experimental USO path adds metadata that must be initialized explicitly"
    )
if args.rx_pipe_prefetch and v1.group("rxprefetch") != "0":
    raise SystemExit(
        "ERROR: --rx-pipe-prefetch requires P5_P2_RX_PREFETCH=0 so only one RX prefetch strategy is active"
    )
if args.shard_active_mask == "1" and v1.group("handoff") != "sharded":
    raise SystemExit("ERROR: --shard-active-mask=1 requires P5_P2_TX_HANDOFF=sharded")


def replace_once(old: str, new: str, label: str) -> None:
    global text
    n = text.count(old)
    if n != 1:
        raise SystemExit(f"ERROR: {label}: expected exactly one anchor, found {n}")
    text = text.replace(old, new, 1)


alloc_function_anchor = """_IRQL_requires_max_(DISPATCH_LEVEL)\nCXPLAT_SEND_DATA*\nCxPlatDpRawTxAlloc("""
marker = (
    "GREENQUIC-P5-PERFORMANCE2-V2 "
    f"txalloc={args.tx_alloc_batch} "
    f"txenqcounter={args.tx_enqueue_counter} "
    f"txmetazero={args.tx_meta_zero} "
    f"rxpipe={args.rx_pipe_prefetch} "
    f"shardmask={args.shard_active_mask}"
)
insert = (
    "// GREENQUIC-P5-PERFORMANCE2-V2: isolated second-stage hot-path experiments.\n"
    "static const char GreenQuicP5Performance2V2Marker[] __attribute__((used)) =\n"
    f'    "{marker}";\n\n'
)

if args.tx_alloc_batch > 1:
    batch = args.tx_alloc_batch
    insert += f"""// Amortize TX mempool allocation without delaying or coalescing QUIC packets.
// Each producer thread refills a tiny TLS stash with rte_pktmbuf_alloc_bulk(),
// but every CxPlatDpRawTxAlloc() still returns exactly one mbuf immediately.
#define GREENQUIC_P2_V2_TX_ALLOC_BATCH {batch}U
typedef struct GREENQUIC_P2_V2_TX_ALLOC_CACHE {{
    struct rte_mempool* Pool;
    uint16_t Next;
    uint16_t Count;
    struct rte_mbuf* Mbufs[GREENQUIC_P2_V2_TX_ALLOC_BATCH];
}} GREENQUIC_P2_V2_TX_ALLOC_CACHE;

static __thread GREENQUIC_P2_V2_TX_ALLOC_CACHE
    GreenQuicP2V2TxAllocCache = {{0}};

static inline struct rte_mbuf*
GreenQuicP2V2TxMbufAlloc(
    _In_ struct rte_mempool* Pool
    )
{{
    GREENQUIC_P2_V2_TX_ALLOC_CACHE* Cache = &GreenQuicP2V2TxAllocCache;

    if (unlikely(Cache->Pool != Pool)) {{
        // A P5 process has one datapath lifetime. Reset the TLS stash if a
        // different pool is ever observed rather than reusing stale pointers.
        Cache->Pool = Pool;
        Cache->Next = 0U;
        Cache->Count = 0U;
    }}

    if (likely(Cache->Next < Cache->Count)) {{
        return Cache->Mbufs[Cache->Next++];
    }}

    Cache->Next = 0U;
    Cache->Count = 0U;
    if (likely(
            rte_pktmbuf_alloc_bulk(
                Pool,
                Cache->Mbufs,
                GREENQUIC_P2_V2_TX_ALLOC_BATCH) == 0)) {{
        Cache->Count = GREENQUIC_P2_V2_TX_ALLOC_BATCH;
        Cache->Next = 1U;
        return Cache->Mbufs[0];
    }}

    // Preserve original behavior if a bulk refill cannot be satisfied.
    return rte_pktmbuf_alloc(Pool);
}}

"""

replace_once(
    alloc_function_anchor,
    insert + alloc_function_anchor,
    "Performance2 V2 marker/helper insertion",
)

if args.tx_alloc_batch > 1:
    replace_once(
        "    struct rte_mbuf* Mbuf = rte_pktmbuf_alloc(Interface->TxMemoryPool);",
        "    struct rte_mbuf* Mbuf = GreenQuicP2V2TxMbufAlloc(Interface->TxMemoryPool);",
        "TX bulk-refill allocator",
    )

if args.tx_meta_zero == "0":
    # Keep all CXPLAT_SEND_DATA/CXPLAT_SEND_DATA_COMMON fields deterministic.
    # Only skip clearing the trailing DPDK-only pointers because those are
    # explicitly assigned immediately below. Completely removing initialization
    # is unsafe: fields such as ECN/common send state are consumed later.
    replace_once(
        "        CxPlatZeroMemory(Packet, sizeof(*Packet));",
        "        CxPlatZeroMemory((CXPLAT_SEND_DATA*)Packet, sizeof(CXPLAT_SEND_DATA));\n"
        "        /* GREENQUIC-P5-PERFORMANCE2-V2: DPDK-only trailing fields are assigned below. */",
        "TX private-metadata reduced zero",
    )

if args.tx_enqueue_counter == "0":
    producer_counter = "    Dpdk->TxEnqueueCounter++; // increase in any case, even if packet was dropped"
    already_disabled = "    /* GREENQUIC-P5-SUPER: debugging TxEnqueueCounter disabled. */"
    if text.count(producer_counter) == 1:
        text = text.replace(
            producer_counter,
            "    /* GREENQUIC-P5-PERFORMANCE2-V2: unused producer-side TxEnqueueCounter write removed. */",
            1,
        )
    elif text.count(already_disabled) == 1:
        pass
    else:
        raise SystemExit(
            "ERROR: producer TxEnqueueCounter anchor missing or ambiguous; "
            "refusing to alter required RxCounter/TxCounter accounting"
        )

if args.rx_pipe_prefetch:
    if "#include <rte_prefetch.h>" not in text:
        replace_once(
            "#include <rte_hexdump.h>\n",
            "#include <rte_hexdump.h>\n#include <rte_prefetch.h>\n",
            "pipelined RX prefetch include",
        )
    anchor = """    for (uint16_t Index = 0; Index < BuffersCount; ++Index) {
        struct rte_mbuf* Buffer = (struct rte_mbuf*)Buffers[Index];"""
    distance = args.rx_pipe_prefetch
    repl = f"""    for (uint16_t Index = 0; Index < BuffersCount; ++Index) {{
        const uint16_t GreenQuicP2V2PrefetchIndex = (uint16_t)(Index + {distance}U);
        if (GreenQuicP2V2PrefetchIndex < BuffersCount) {{
            struct rte_mbuf* GreenQuicP2V2PrefetchMbuf =
                (struct rte_mbuf*)Buffers[GreenQuicP2V2PrefetchIndex];
            rte_prefetch0(GreenQuicP2V2PrefetchMbuf);
            rte_prefetch0(
                ((uint8_t*)GreenQuicP2V2PrefetchMbuf->buf_addr) +
                GreenQuicP2V2PrefetchMbuf->data_off);
        }}
        struct rte_mbuf* Buffer = (struct rte_mbuf*)Buffers[Index];"""
    replace_once(anchor, repl, "pipelined RX prefetch")

if args.shard_active_mask == "1":
    replace_once(
        "static uint32_t GreenQuicP2TxConsumerCursor = 0U;",
        "static uint32_t GreenQuicP2TxConsumerCursor = 0U;\n"
        "static atomic_uint_fast64_t GreenQuicP2V2TxActiveMask = ATOMIC_VAR_INIT(0);",
        "sharded active-mask state",
    )
    enqueue_old = """        if (
            Slot >= 0 &&
            rte_ring_sp_enqueue(GreenQuicP2TxProducers[Slot].Ring, Mbuf) == 0) {
            return 0;
        }"""
    enqueue_new = """        if (
            Slot >= 0 &&
            rte_ring_sp_enqueue(GreenQuicP2TxProducers[Slot].Ring, Mbuf) == 0) {
            atomic_fetch_or_explicit(
                &GreenQuicP2V2TxActiveMask,
                1ULL << (uint32_t)Slot,
                memory_order_release);
            return 0;
        }"""
    replace_once(enqueue_old, enqueue_new, "sharded producer active-bit set")

    loop_old = """        for (uint32_t Step = 0; Step < Count && Total < MaxCount; ++Step) {
            const uint32_t Index = (Start + Step) % Count;
            if (GreenQuicP2TxProducers[Index].Interface != Interface) {
                continue;
            }
            const uint16_t Got =
                (uint16_t)rte_ring_sc_dequeue_burst(
                    GreenQuicP2TxProducers[Index].Ring,
                    (void**)&Buffers[Total],
                    (uint16_t)(MaxCount - Total),
                    NULL);
            if (Got != 0U) {
                Total = (uint16_t)(Total + Got);
                GreenQuicP2TxConsumerCursor = Index + 1U;
            }
        }"""
    loop_new = """        uint64_t Active = atomic_load_explicit(
            &GreenQuicP2V2TxActiveMask, memory_order_acquire);
        for (uint32_t Step = 0; Step < Count && Total < MaxCount && Active != 0U; ++Step) {
            const uint32_t Index = (Start + Step) % Count;
            const uint64_t Bit = 1ULL << Index;
            if ((Active & Bit) == 0U ||
                GreenQuicP2TxProducers[Index].Interface != Interface) {
                continue;
            }
            const uint16_t Got =
                (uint16_t)rte_ring_sc_dequeue_burst(
                    GreenQuicP2TxProducers[Index].Ring,
                    (void**)&Buffers[Total],
                    (uint16_t)(MaxCount - Total),
                    NULL);
            if (Got != 0U) {
                Total = (uint16_t)(Total + Got);
                GreenQuicP2TxConsumerCursor = Index + 1U;
            }
            if (rte_ring_empty(GreenQuicP2TxProducers[Index].Ring)) {
                atomic_fetch_and_explicit(
                    &GreenQuicP2V2TxActiveMask, ~Bit, memory_order_acq_rel);
                // Close the clear/enqueue race: a producer can enqueue between
                // the empty observation and the mask clear. Re-check and restore.
                if (!rte_ring_empty(GreenQuicP2TxProducers[Index].Ring)) {
                    atomic_fetch_or_explicit(
                        &GreenQuicP2V2TxActiveMask, Bit, memory_order_release);
                }
            }
            Active = atomic_load_explicit(
                &GreenQuicP2V2TxActiveMask, memory_order_acquire);
        }"""
    replace_once(loop_old, loop_new, "sharded active-ring consumer scan")

for required in ("Dpdk->RxCounter += BuffersCount;", "Dpdk->TxCounter += TxCount;"):
    if text.count(required) != 1:
        raise SystemExit(f"ERROR: required P5 packet-total update missing: {required}")

path.write_text(text, encoding="utf-8")
print(marker)
