#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path
import re

p = argparse.ArgumentParser(
    description="Apply second-stage P5 Performance2 TX hot-path experiments."
)
p.add_argument("datapath")
p.add_argument("--tx-alloc-batch", type=int, default=1)
p.add_argument("--tx-enqueue-counter", choices=("0", "1"), default="1")
p.add_argument("--tx-meta-zero", choices=("0", "1"), default="1")
args = p.parse_args()

if args.tx_alloc_batch not in (1, 8, 16, 32):
    raise SystemExit("ERROR: --tx-alloc-batch must be 1,8,16,32")

path = Path(args.datapath)
text = path.read_text(encoding="utf-8")

for required in ("GREENQUIC-P5-SUPER-PERF-V2", "GREENQUIC-P5-PERFORMANCE2-V1"):
    if required not in text:
        raise SystemExit(f"ERROR: required marker missing: {required}")
if "GREENQUIC-P5-PERFORMANCE2-V2" in text:
    raise SystemExit("ERROR: performance2 V2 transform already applied")

v1 = re.search(
    r"GREENQUIC-P5-PERFORMANCE2-V1[^\"\n]*udpseg=(?P<udpseg>[01])",
    text,
)
if v1 is None:
    raise SystemExit("ERROR: cannot determine Performance2 V1 UDP segmentation state")
if args.tx_meta_zero == "0" and v1.group("udpseg") != "0":
    raise SystemExit(
        "ERROR: --tx-meta-zero=0 is intentionally restricted to P5_P2_UDP_SEG=0; "
        "the experimental USO path adds metadata that must be initialized explicitly"
    )


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
    f"txmetazero={args.tx_meta_zero}"
)
insert = (
    "// GREENQUIC-P5-PERFORMANCE2-V2: isolated second-stage TX experiments.\n"
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

    // A pool switch can only occur across datapath lifetimes. Never dereference
    // stale cached pointers from an old pool; just reset the tiny TLS stash.
    if (unlikely(Cache->Pool != Pool)) {{
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

    // Preserve the original allocation behavior under temporary pool pressure.
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
    replace_once(
        "        CxPlatZeroMemory(Packet, sizeof(*Packet));",
        "        /* GREENQUIC-P5-PERFORMANCE2-V2: all required TX metadata fields are assigned below. */",
        "TX private-metadata whole-struct zero",
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

for required in ("Dpdk->RxCounter += BuffersCount;", "Dpdk->TxCounter += TxCount;"):
    if text.count(required) != 1:
        raise SystemExit(f"ERROR: required P5 packet-total update missing: {required}")

path.write_text(text, encoding="utf-8")
print(marker)
