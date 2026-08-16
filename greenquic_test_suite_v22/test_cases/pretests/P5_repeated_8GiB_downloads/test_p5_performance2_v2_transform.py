#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
TRANSFORM = HERE / "apply_p5_performance2_v2.py"


def fixture(udpseg: int = 0) -> str:
    return f'''/* GREENQUIC-P5-SUPER-PERF-V2 */
static const char GreenQuicP5Performance2Marker[] __attribute__((used)) =
    "GREENQUIC-P5-PERFORMANCE2-V1 diag_us=0 diag_ms=3000 txhandoff=shared txpring=1024 rxprefetch=0 udpseg={udpseg} udpsegmax=4";

void FakeRx(void) {{
    Dpdk->RxCounter += BuffersCount;
}}

_IRQL_requires_max_(DISPATCH_LEVEL)
CXPLAT_SEND_DATA*
CxPlatDpRawTxAlloc(
        _In_ CXPLAT_SOCKET_RAW* Socket,
        _Inout_ CXPLAT_SEND_CONFIG* Config
)
{{
    DPDK_DATAPATH* Dpdk = (DPDK_DATAPATH*)Socket->RawDatapath;
    QUIC_ADDRESS_FAMILY Family = QuicAddrGetFamily(&Config->Route->RemoteAddress);
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


def run(args: list[str], udpseg: int = 0, should_pass: bool = True) -> str:
    with tempfile.TemporaryDirectory(prefix="p5-p2-v2-") as td:
        p = Path(td) / "datapath.c"
        p.write_text(fixture(udpseg), encoding="utf-8")
        cp = subprocess.run(
            [sys.executable, str(TRANSFORM), str(p), *args],
            text=True,
            capture_output=True,
        )
        if should_pass and cp.returncode != 0:
            raise SystemExit(f"transform failed: {cp.stderr}\n{cp.stdout}")
        if not should_pass:
            if cp.returncode == 0:
                raise SystemExit("expected transform failure")
            return cp.stderr + cp.stdout
        return p.read_text(encoding="utf-8")


base = run([])
assert "GREENQUIC-P5-PERFORMANCE2-V2 txalloc=1 txenqcounter=1 txmetazero=1" in base
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
assert "all required TX metadata fields are assigned below" in nozero
assert "CxPlatZeroMemory(Packet, sizeof(*Packet));" not in nozero

lean = run([
    "--tx-alloc-batch", "16",
    "--tx-enqueue-counter", "0",
    "--tx-meta-zero", "0",
])
assert "GREENQUIC_P2_V2_TX_ALLOC_BATCH 16U" in lean
assert "TxEnqueueCounter write removed" in lean
assert "CxPlatZeroMemory(Packet, sizeof(*Packet));" not in lean

err = run(["--tx-meta-zero", "0"], udpseg=1, should_pass=False)
assert "restricted to P5_P2_UDP_SEG=0" in err

print("P5 PERFORMANCE2 V2 TRANSFORM SELFTEST PASS")
