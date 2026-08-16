#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
TRANSFORM = HERE / "apply_p5_performance2_v2.py"


def fixture(udpseg: int = 0, handoff: str = "shared", rxprefetch: int = 0) -> str:
    sharded = r'''
static uint32_t GreenQuicP2TxConsumerCursor = 0U;
static int GreenQuicP2TxEnqueue(DPDK_DATAPATH* Dpdk, DPDK_INTERFACE* Interface, struct rte_mbuf* Mbuf)
{
    if (!GreenQuicP2TxTlsSharedFallback) {
        const int Slot = GreenQuicP2TxGetProducerSlot(Dpdk, Interface);
        if (
            Slot >= 0 &&
            rte_ring_sp_enqueue(GreenQuicP2TxProducers[Slot].Ring, Mbuf) == 0) {
            return 0;
        }
        GreenQuicP2TxTlsSharedFallback = TRUE;
    }
    return rte_ring_mp_enqueue(Interface->TxRingBuffer, Mbuf);
}
static uint16_t GreenQuicP2TxDequeueBurst(DPDK_INTERFACE* Interface, struct rte_mbuf** Buffers, uint16_t MaxCount, uint32_t* BacklogBefore)
{
    uint16_t Total = 0U;
    const uint32_t Count = atomic_load_explicit(&GreenQuicP2TxProducerCount, memory_order_acquire);
    if (Count != 0U) {
        const uint32_t Start = GreenQuicP2TxConsumerCursor % Count;
        for (uint32_t Step = 0; Step < Count && Total < MaxCount; ++Step) {
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
        }
    }
    return Total;
}
''' if handoff == "sharded" else ""
    return f'''/* GREENQUIC-P5-SUPER-PERF-V2 */
#include <rte_hexdump.h>
static const char GreenQuicP5Performance2Marker[] __attribute__((used)) =
    "GREENQUIC-P5-PERFORMANCE2-V1 diag_us=0 diag_ms=3000 txhandoff={handoff} txpring=1024 rxprefetch={rxprefetch} udpseg={udpseg} udpsegmax=4";
{sharded}
void FakeRx(void) {{
    Dpdk->RxCounter += BuffersCount;
    uint16_t PacketCount = 0;
    for (uint16_t Index = 0; Index < BuffersCount; ++Index) {{
        struct rte_mbuf* Buffer = (struct rte_mbuf*)Buffers[Index];
        PacketCount += Buffer != 0;
    }}
}}

_IRQL_requires_max_(DISPATCH_LEVEL)
CXPLAT_SEND_DATA*
CxPlatDpRawTxAlloc(
        _In_ CXPLAT_SOCKET_RAW* Socket,
        _Inout_ CXPLAT_SEND_CONFIG* Config
)
{{
    DPDK_DATAPATH* Dpdk = (DPDK_DATAPATH*)Socket->RawDatapath;
    DPDK_INTERFACE* Interface = (DPDK_INTERFACE*)Config->Route->Queue;
    struct rte_mbuf* Mbuf = rte_pktmbuf_alloc(Interface->TxMemoryPool);
    DPDK_TX_PACKET* Packet = NULL;
    if (likely(Mbuf)) {{
        Packet = (DPDK_TX_PACKET*)rte_mbuf_to_priv(Mbuf);
        CxPlatZeroMemory(Packet, sizeof(*Packet));
        Packet->Interface = Interface;
        Packet->Mbuf = Mbuf;
        Packet->Dpdk = Dpdk;
        Packet->Buffer.Length = Config->MaxPacketSize;
    }}
    return (CXPLAT_SEND_DATA*)Packet;
}}

void CxPlatDpRawTxEnqueue(void) {{
    Dpdk->TxEnqueueCounter++; // increase in any case, even if packet was dropped
}}

void CxPlatDpdkTx(void) {{
    Dpdk->TxCounter += TxCount;
}}
'''


def run(args: list[str], *, udpseg: int = 0, handoff: str = "shared", rxprefetch: int = 0, should_pass: bool = True) -> str:
    with tempfile.TemporaryDirectory(prefix="p5-p2-v2-") as td:
        p = Path(td) / "datapath.c"
        p.write_text(fixture(udpseg, handoff, rxprefetch), encoding="utf-8")
        cp = subprocess.run([sys.executable, str(TRANSFORM), str(p), *args], text=True, capture_output=True)
        if should_pass and cp.returncode != 0:
            raise SystemExit(f"transform failed: {cp.stderr}\n{cp.stdout}")
        if not should_pass:
            if cp.returncode == 0:
                raise SystemExit("expected transform failure")
            return cp.stderr + cp.stdout
        return p.read_text(encoding="utf-8")


base = run([])
assert "txalloc=1 txenqcounter=1 txmetazero=1 rxpipe=0 shardmask=0" in base
assert "rte_pktmbuf_alloc(Interface->TxMemoryPool)" in base
assert "CxPlatZeroMemory(Packet, sizeof(*Packet));" in base
assert "Dpdk->TxEnqueueCounter++;" in base

bulk = run(["--tx-alloc-batch", "16"])
assert "GREENQUIC_P2_V2_TX_ALLOC_BATCH 16U" in bulk
assert "rte_pktmbuf_alloc_bulk" in bulk
assert "GreenQuicP2V2TxMbufAlloc(Interface->TxMemoryPool)" in bulk

nocounter = run(["--tx-enqueue-counter", "0"])
assert "TxEnqueueCounter write removed" in nocounter
assert "Dpdk->TxEnqueueCounter++;" not in nocounter
assert "Dpdk->RxCounter += BuffersCount;" in nocounter
assert "Dpdk->TxCounter += TxCount;" in nocounter

nozero = run(["--tx-meta-zero", "0"])
assert "required non-USO TX fields are explicitly assigned below" in nozero
assert "CxPlatZeroMemory(Packet, sizeof(*Packet));" not in nozero

rxpipe = run(["--rx-pipe-prefetch", "4"])
assert "GreenQuicP2V2PrefetchIndex" in rxpipe
assert "Index + 4U" in rxpipe
assert "#include <rte_prefetch.h>" in rxpipe

mask = run(["--shard-active-mask", "1"], handoff="sharded")
assert "GreenQuicP2V2TxActiveMask" in mask
assert "atomic_fetch_or_explicit" in mask
assert "rte_ring_empty" in mask

lean = run(["--tx-alloc-batch", "16", "--tx-enqueue-counter", "0", "--tx-meta-zero", "0", "--rx-pipe-prefetch", "4"])
assert "GREENQUIC_P2_V2_TX_ALLOC_BATCH 16U" in lean
assert "TxEnqueueCounter write removed" in lean
assert "CxPlatZeroMemory(Packet, sizeof(*Packet));" not in lean
assert "GreenQuicP2V2PrefetchIndex" in lean

err = run(["--tx-meta-zero", "0"], udpseg=1, should_pass=False)
assert "restricted to P5_P2_UDP_SEG=0" in err
err = run(["--rx-pipe-prefetch", "4"], rxprefetch=1, should_pass=False)
assert "requires P5_P2_RX_PREFETCH=0" in err
err = run(["--shard-active-mask", "1"], handoff="shared", should_pass=False)
assert "requires P5_P2_TX_HANDOFF=sharded" in err

print("P5 PERFORMANCE2 V2 TRANSFORM SELFTEST PASS")
