#!/usr/bin/env python3
"""Anchor/regression self-test for apply_p5_performance2.py.

Build a compact synthetic datapath containing the anchors emitted by the measured
P5 super-performance transform, then verify every performance2 feature alone and
in combination. This does not replace compiling/running on the DPDK hosts.
"""
from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
TRANSFORM = HERE / "apply_p5_performance2.py"

FIXTURE = r'''#include <rte_hexdump.h>
#include <sys/eventfd.h>
static const char BaseMarker[]="GREENQUIC-P5-SUPER-PERF-V2";
typedef struct DPDK_TX_PACKET {
    int Common;
    struct rte_mbuf* Mbuf;
    DPDK_DATAPATH* Dpdk;
    DPDK_INTERFACE* Interface;
} DPDK_TX_PACKET;
void priv(void) { const char* s="RTE_ALIGN_CEIL(sizeof(DPDK_TX_PACKET), RTE_MBUF_PRIV_ALIGN)"; }
void init(void) {
    GreenQuicConfigureRoles(
        Dpdk, &DeviceInfo, &PortConfig, &rx_rings, &tx_rings);
}
void guards(void) {
    if (rte_ring_count(Interface->TxRingBuffer)) {}
    if (rte_ring_count(Interface->TxRingBuffer)) {}
    if (rte_ring_count(Interface->TxRingBuffer)) {}
    if (rte_ring_count(Interface->TxRingBuffer)) {}
    if (rte_ring_count(Interface->TxRingBuffer)) {}
}
void CxPlatDpRawTxEnqueue(void) {
    if (unlikely(rte_ring_mp_enqueue(Interface->TxRingBuffer, Packet->Mbuf) != 0)) {}
}
void CxPlatDpdkRx(void) {
    uint16_t PacketCount = 0;
    for (uint16_t Index = 0; Index < BuffersCount; ++Index) {
    }
}
void CxPlatDpdkTx(void) {
    const uint32_t RingBefore = rte_ring_count(Interface->TxRingBuffer);
    const uint16_t BufferCount =
        (uint16_t)rte_ring_sc_dequeue_burst(
            Interface->TxRingBuffer,
            (void**)Buffers,
            Dpdk->TxBurstSize,
            NULL);
    QuicTraceEvent(
        DatapathTxDequeue,
        "[data] %u packets dequeued from TX ring (now %u entries).",
        BufferCount,
        rte_ring_count(Interface->TxRingBuffer));
    const uint16_t TxCount =
        Dpdk->GreenQuicMode == GREENQUIC_MODE_OFF ?
            /* GREENQUIC-STRICT-OFF-V1: original DPDK TX hot path. */
            rte_eth_tx_burst(Interface->Port, 0, Buffers, BufferCount) :
            GreenQuicTrackedTxBurst(
                Interface->Port, 0, Buffers, BufferCount);
    Dpdk->TxCounter += TxCount;
    if (Dpdk->GreenQuicMode != GREENQUIC_MODE_OFF) {
        GreenQuicOnTxPoll(
            Dpdk, Core, RingBefore, BufferCount, TxCount);
    }
    if (unlikely(TxCount < BufferCount)) {
        for (uint16_t Index = TxCount; Index < BufferCount; ++Index) {
            rte_pktmbuf_free(Buffers[Index]);
        }
    }
    if (GreenQuicSuperDrainBudget > 1 && TxCount == BufferCount) {
        const uint32_t GreenQuicSuperBacklog =
            rte_ring_count(Interface->TxRingBuffer);
    }
}
'''

CASES = {
    "baseline": [],
    "diagnostics": ["--diag-interval-us", "100000"],
    "sharded": ["--tx-handoff", "sharded", "--tx-producer-ring-size", "1024"],
    "rx_prefetch": ["--rx-prefetch", "1"],
    "udp_seg": ["--udp-seg", "1", "--udp-seg-max", "4"],
    "combined": [
        "--diag-interval-us", "100000",
        "--tx-handoff", "sharded",
        "--tx-producer-ring-size", "1024",
        "--rx-prefetch", "1",
        "--udp-seg", "1",
        "--udp-seg-max", "4",
    ],
}


def require(text: str, needle: str, case: str) -> None:
    if needle not in text:
        raise RuntimeError(f"{case}: expected marker missing: {needle}")


def main() -> int:
    if not TRANSFORM.is_file():
        raise SystemExit(f"missing transformer: {TRANSFORM}")
    with tempfile.TemporaryDirectory(prefix="p5-performance2-selftest-") as td:
        root = Path(td)
        for name, args in CASES.items():
            src = root / f"{name}.c"
            src.write_text(FIXTURE, encoding="utf-8")
            cp = subprocess.run(
                [sys.executable, str(TRANSFORM), str(src), *args],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            if cp.returncode != 0:
                raise RuntimeError(f"{name}: transform failed rc={cp.returncode}\n{cp.stdout}")
            out = src.read_text(encoding="utf-8")
            require(out, "GREENQUIC-P5-PERFORMANCE2-V1", name)
            if "--diag-interval-us" in args:
                require(out, "[P5-PERF2-DIAG]", name)
            if "sharded" in args:
                require(out, "GreenQuicP2TxDequeueBurst", name)
                require(out, "GreenQuicP2TxTlsSharedFallback", name)
            if "--rx-prefetch" in args:
                require(out, "GreenQuicP2PrefetchIndex", name)
            if "--udp-seg" in args:
                require(out, "GreenQuicP2UdpSegCoalesce", name)
                require(out, "GreenQuicP2LogicalPerPhysical", name)
                require(out, "GreenQuicP2Udp->Length", name)
        print(f"P5 performance2 transformer self-test PASS ({len(CASES)} cases)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
