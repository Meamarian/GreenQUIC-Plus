#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: apply_p6_impairment.py PATH_TO_datapath_raw_dpdk_linux.c")

path = Path(sys.argv[1])
src = path.read_text(encoding="utf-8")
marker = "GREENQUIC-P6-DETERMINISTIC-LOSS-V2"
exact_marker = "GREENQUIC-P6-EXACT-ONE-PACKET-LOSS-V1"
if exact_marker in src:
    print(f"{exact_marker}: already applied")
    raise SystemExit(0)

# P6 patches only the isolated Linux DPDK translation unit that is actually
# compiled. OFF/BASIC/PLUS all pass through the same P6 data-TX wrapper.
anchor = "static void\nGreenQuicOnTxPoll(\n"
insert = r'''
// GREENQUIC-P6-DETERMINISTIC-LOSS-V2
// GREENQUIC-P6-EXACT-ONE-PACKET-LOSS-V1
// P6-only deterministic server-download loss at the real Linux DPDK TX
// boundary. When a configured packet-count boundary is crossed, exactly ONE
// packet is withheld from the end of that data burst. The existing caller then
// frees that single unsent mbuf through its normal TxCount < BufferCount path.
// No mbuf is freed here, so there is no double-free path.
//
// OFF/BASIC/PLUS therefore get the same loss rule and exactly one packet per
// loss event, independent of their DPDK burst size. ARP/control TX paths remain
// untouched. MsQuic has already accounted the QUIC packet as sent, so normal
// loss detection and CUBIC recovery observe real network loss.
//
// Environment variables:
//   GQ_P6_DROP_EVERY_N      0 disables; otherwise one packet is dropped whenever
//                           this many eligible server data packets are crossed.
//   GQ_P6_DROP_START_AFTER  protect the first N eligible server data packets.
static BOOLEAN GreenQuicP6LossInitialized = FALSE;
static uint64_t GreenQuicP6DropEveryN = 0;
static uint64_t GreenQuicP6DropStartAfter = 10000;
static uint64_t GreenQuicP6TxEligible = 0;
static uint64_t GreenQuicP6TxDroppedPackets = 0;
static uint64_t GreenQuicP6TxDropEvents = 0;

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
        "GreenQUIC P6 impairment: marker=%s exact_marker=%s drop_every_n=%" PRIu64
        " start_after=%" PRIu64 "\n",
        "GREENQUIC-P6-DETERMINISTIC-LOSS-V2",
        "GREENQUIC-P6-EXACT-ONE-PACKET-LOSS-V1",
        GreenQuicP6DropEveryN,
        GreenQuicP6DropStartAfter);
    fflush(stdout);
}

static BOOLEAN
GreenQuicP6ShouldDropOneDataPacket(
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
    uint16_t SendCount = PacketCount;

    if (GreenQuicP6ShouldDropOneDataPacket(Dpdk, PacketCount)) {
        // Drop exactly the final packet in this burst. We intentionally leave
        // Packets[SendCount] in place for the caller's existing unsent cleanup.
        --SendCount;
        ++GreenQuicP6TxDroppedPackets;
        ++GreenQuicP6TxDropEvents;
        if (GreenQuicP6TxDropEvents <= 5 ||
            (GreenQuicP6TxDropEvents % 100) == 0) {
            printf(
                "GreenQUIC P6 drop: eligible=%" PRIu64
                " dropped_packets=%" PRIu64
                " drop_events=%" PRIu64
                " original_burst_packets=%u sent_attempt_packets=%u\n",
                GreenQuicP6TxEligible,
                GreenQuicP6TxDroppedPackets,
                GreenQuicP6TxDropEvents,
                PacketCount,
                SendCount);
            fflush(stdout);
        }
    }

    if (SendCount == 0) {
        return 0;
    }

    if (Dpdk->GreenQuicMode == GREENQUIC_MODE_OFF) {
        // Preserve the strict-OFF direct DPDK TX path when packets are sent.
        return rte_eth_tx_burst(PortId, QueueId, Packets, SendCount);
    }

    return GreenQuicTrackedTxBurst(PortId, QueueId, Packets, SendCount);
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
new = '''    // GREENQUIC-P6-EXACT-ONE-PACKET-LOSS-V1: P6-only wrapper around
    // the common QUIC data-TX boundary. Existing post-TX cleanup is unchanged.
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
print(f"Applied {marker} + {exact_marker} to {path}")
