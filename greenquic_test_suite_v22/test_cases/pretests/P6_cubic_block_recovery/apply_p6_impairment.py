#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: apply_p6_impairment.py PATH_TO_datapath_raw_dpdk_linux.c")

path = Path(sys.argv[1])
src = path.read_text(encoding="utf-8")
marker = "GREENQUIC-P6-DETERMINISTIC-LOSS-V2"
if marker in src:
    print(f"{marker}: already applied")
    raise SystemExit(0)

# P6 must patch the Linux DPDK translation unit that is actually compiled.
# Insert after DPDK/GreenQUIC types and after GreenQuicTrackedTxBurst exists.
anchor = "static void\nGreenQuicOnTxPoll(\n"
insert = r'''
// GREENQUIC-P6-DETERMINISTIC-LOSS-V2
// P6-only deterministic server-download loss at the real Linux DPDK TX
// boundary. OFF/BASIC/PLUS all pass through this wrapper. ARP/control TX paths
// are intentionally left untouched. When a configured packet-count boundary
// falls inside a data burst, the entire burst is returned as unsent; the
// existing caller then frees those mbufs exactly as it does for a NIC TX miss.
// MsQuic has already accounted these QUIC packets as sent, so normal loss
// detection and CUBIC recovery observe real network loss.
//
// Environment variables:
//   GQ_P6_DROP_EVERY_N      0 disables; otherwise one data burst is dropped
//                           whenever this many eligible data packets pass.
//   GQ_P6_DROP_START_AFTER  protect the first N eligible data packets.
static BOOLEAN GreenQuicP6LossInitialized = FALSE;
static uint64_t GreenQuicP6DropEveryN = 0;
static uint64_t GreenQuicP6DropStartAfter = 10000;
static uint64_t GreenQuicP6TxEligible = 0;
static uint64_t GreenQuicP6TxDroppedPackets = 0;
static uint64_t GreenQuicP6TxDroppedBursts = 0;

static void
GreenQuicP6InitLoss(void)
{
    if (GreenQuicP6LossInitialized) {
        return;
    }
    const char* Every = getenv("GQ_P6_DROP_EVERY_N");
    const char* Start = getenv("GQ_P6_DROP_START_AFTER");
    if (Every != NULL && Every[0] != '\0') {
        GreenQuicP6DropEveryN = strtoull(Every, NULL, 10);
    }
    if (Start != NULL && Start[0] != '\0') {
        GreenQuicP6DropStartAfter = strtoull(Start, NULL, 10);
    }
    GreenQuicP6LossInitialized = TRUE;
    printf(
        "GreenQUIC P6 impairment: marker=%s drop_every_n=%" PRIu64
        " start_after=%" PRIu64 "\n",
        "GREENQUIC-P6-DETERMINISTIC-LOSS-V2",
        GreenQuicP6DropEveryN,
        GreenQuicP6DropStartAfter);
    fflush(stdout);
}

static BOOLEAN
GreenQuicP6ShouldDropDataBurst(
    _In_ DPDK_DATAPATH* Dpdk,
    _In_ uint16_t PacketCount
    )
{
    GreenQuicP6InitLoss();
    if (PacketCount == 0 ||
        GreenQuicP6DropEveryN == 0 ||
        Dpdk->GreenQuicProfile != GREENQUIC_PROFILE_SERVER_DOWNLOAD) {
        return FALSE;
    }

    const uint64_t Before = GreenQuicP6TxEligible;
    const uint64_t After = Before + (uint64_t)PacketCount;
    GreenQuicP6TxEligible = After;

    if (After <= GreenQuicP6DropStartAfter) {
        return FALSE;
    }

    const uint64_t EffectiveBefore =
        Before > GreenQuicP6DropStartAfter ?
            Before - GreenQuicP6DropStartAfter : 0;
    const uint64_t EffectiveAfter = After - GreenQuicP6DropStartAfter;

    return
        EffectiveBefore / GreenQuicP6DropEveryN !=
        EffectiveAfter / GreenQuicP6DropEveryN;
}

static uint16_t
GreenQuicP6DataTxBurst(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_ uint16_t PortId,
    _In_ uint16_t QueueId,
    _Inout_updates_(PacketCount) struct rte_mbuf** Packets,
    _In_ uint16_t PacketCount
    )
{
    if (GreenQuicP6ShouldDropDataBurst(Dpdk, PacketCount)) {
        GreenQuicP6TxDroppedPackets += PacketCount;
        ++GreenQuicP6TxDroppedBursts;
        if (GreenQuicP6TxDroppedBursts <= 5 ||
            (GreenQuicP6TxDroppedBursts % 100) == 0) {
            printf(
                "GreenQUIC P6 drop: eligible=%" PRIu64
                " dropped_packets=%" PRIu64
                " dropped_bursts=%" PRIu64
                " burst_packets=%u\n",
                GreenQuicP6TxEligible,
                GreenQuicP6TxDroppedPackets,
                GreenQuicP6TxDroppedBursts,
                PacketCount);
            fflush(stdout);
        }
        return 0;
    }

    if (Dpdk->GreenQuicMode == GREENQUIC_MODE_OFF) {
        // Preserve strict-OFF accounting when this burst is not impaired.
        return rte_eth_tx_burst(PortId, QueueId, Packets, PacketCount);
    }

    return GreenQuicTrackedTxBurst(PortId, QueueId, Packets, PacketCount);
}

'''

if src.count(anchor) != 1:
    raise SystemExit(
        f"ERROR: expected one GreenQuicOnTxPoll definition anchor, found {src.count(anchor)}"
    )
src = src.replace(anchor, insert + anchor, 1)

old = '''    const uint16_t TxCount =
        Dpdk->GreenQuicMode == GREENQUIC_MODE_OFF ?
            /* GREENQUIC-STRICT-OFF-V1: original DPDK TX hot path. */
            rte_eth_tx_burst(Interface->Port, 0, Buffers, BufferCount) :
            GreenQuicTrackedTxBurst(
                Interface->Port, 0, Buffers, BufferCount);
'''
new = '''    // GREENQUIC-P6-DETERMINISTIC-LOSS-V2: P6-only wrapper around the
    // common QUIC data-TX boundary. Existing post-TX cleanup remains unchanged.
    const uint16_t TxCount =
        GreenQuicP6DataTxBurst(
            Dpdk, Interface->Port, 0, Buffers, BufferCount);
'''

if src.count(old) != 1:
    raise SystemExit(
        f"ERROR: expected one Linux DPDK data-TX selection block, found {src.count(old)}"
    )
src = src.replace(old, new, 1)

path.write_text(src, encoding="utf-8")
print(f"Applied {marker} to {path}")
