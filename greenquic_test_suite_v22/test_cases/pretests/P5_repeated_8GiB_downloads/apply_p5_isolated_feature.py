#!/usr/bin/env python3
"""Apply exactly one isolated P5 DPDK feature on top of the cache128 baseline.

No feature is combined with another feature. GreenQUIC and GreenQUIC+ policy is
never modified here. The caller must first restore/apply the cache128 static
baseline, then invoke this transformer for one feature only.
"""

from pathlib import Path
import re
import sys

FEATURES = {
    "txretry1": "GREENQUIC-P5-ISO-TXRETRY1-V1",
    "udpcksum": "GREENQUIC-P5-ISO-UDPCKSUM-V1",
    "lockfree": "GREENQUIC-P5-ISO-LOCKFREE-V1",
    "counters": "GREENQUIC-P5-ISO-COUNTERS-V1",
    "rxalloc4": "GREENQUIC-P5-ISO-RXALLOC4-V1",
}

if len(sys.argv) != 3:
    raise SystemExit(
        "usage: apply_p5_isolated_feature.py "
        "{txretry1|udpcksum|lockfree|counters|rxalloc4} datapath_raw_dpdk_linux.c"
    )

feature = sys.argv[1].strip().lower()
path = Path(sys.argv[2])
if feature not in FEATURES:
    raise SystemExit("ERROR: unknown isolated feature %r" % feature)

text = path.read_text(encoding="utf-8")
marker = FEATURES[feature]

for other in FEATURES.values():
    if other in text:
        raise SystemExit(
            f"ERROR: isolated-feature source already contains marker {other}; "
            "restore cache128 baseline before applying another feature"
        )


def once(old, new, label):
    global text
    n = text.count(old)
    if n != 1:
        raise SystemExit(f"ERROR: {label}: expected one anchor, found {n}")
    text = text.replace(old, new, 1)


def add_marker(extra_headers=""):
    anchor = "#include <rte_hexdump.h>\n"
    ident = re.sub(r"[^A-Za-z0-9]", "_", feature)
    replacement = (
        anchor
        + extra_headers
        + f'\nstatic const char GreenQuicP5Iso_{ident}[] __attribute__((used)) = '
        + f'"{marker}";\n'
    )
    once(anchor, replacement, "isolated feature marker")


if feature == "txretry1":
    add_marker()
    old = """    const uint16_t TxCount =
        Dpdk->GreenQuicMode == GREENQUIC_MODE_OFF ?
            /* GREENQUIC-STRICT-OFF-V1: original DPDK TX hot path. */
            rte_eth_tx_burst(Interface->Port, 0, Buffers, BufferCount) :
            GreenQuicTrackedTxBurst(
                Interface->Port, 0, Buffers, BufferCount);
"""
    new = """    uint16_t TxCount =
        Dpdk->GreenQuicMode == GREENQUIC_MODE_OFF ?
            /* GREENQUIC-STRICT-OFF-V1: original DPDK TX hot path. */
            rte_eth_tx_burst(Interface->Port, 0, Buffers, BufferCount) :
            GreenQuicTrackedTxBurst(
                Interface->Port, 0, Buffers, BufferCount);

    /* GREENQUIC-P5-ISO-TXRETRY1-V1: one retry of an unsent TX tail. */
    if (unlikely(TxCount < BufferCount)) {
        const uint16_t Remaining = BufferCount - TxCount;
        const uint16_t Retried =
            Dpdk->GreenQuicMode == GREENQUIC_MODE_OFF ?
                rte_eth_tx_burst(
                    Interface->Port, 0, &Buffers[TxCount], Remaining) :
                GreenQuicTrackedTxBurst(
                    Interface->Port, 0, &Buffers[TxCount], Remaining);
        TxCount = (uint16_t)(TxCount + Retried);
    }
"""
    once(old, new, "TX retry")

elif feature == "udpcksum":
    add_marker("#include <rte_ip.h>\n#include <rte_udp.h>\n")

    offload_anchor = """    // Set Tx L4 checksum offload to TRUE, s.t. the checksum is not calculated
    // NOTE: this is a q&d fix to test the impact of L4 checksum calculation in software
    Dpdk->Interface.OffloadStatus.Transmit.TransportLayerXsum = TRUE;
"""
    offload_new = offload_anchor + r'''
    /* GREENQUIC-P5-ISO-UDPCKSUM-V1: unconditional experiment for this build. */
    if ((DeviceInfo.tx_offload_capa & RTE_ETH_TX_OFFLOAD_UDP_CKSUM) == 0) {
        fprintf(stderr,
            "P5 isolated UDP checksum experiment: NIC/PMD does not advertise "
            "RTE_ETH_TX_OFFLOAD_UDP_CKSUM\n");
        Status = QUIC_STATUS_INTERNAL_ERROR;
        goto Error;
    }
    PortConfig.txmode.offloads |= RTE_ETH_TX_OFFLOAD_UDP_CKSUM;
    printf("P5 isolated UDP checksum experiment: checksum_active=1\n");
'''
    once(offload_anchor, offload_new, "UDP checksum ethdev configuration")

    old = """    DPDK_INTERFACE* Interface = Packet->Interface;
    Packet->Mbuf->data_len = (uint16_t)Packet->Buffer.Length;
    //Packet->Mbuf->ol_flags = RTE_MBUF_F_TX_IPV4 | RTE_MBUF_F_TX_IP_CKSUM | RTE_MBUF_F_TX_UDP_CKSUM;

    DPDK_DATAPATH* Dpdk = Packet->Dpdk;"""
    new = r"""    DPDK_INTERFACE* Interface = Packet->Interface;
    Packet->Mbuf->data_len = (uint16_t)Packet->Buffer.Length;

    DPDK_DATAPATH* Dpdk = Packet->Dpdk;
    /* GREENQUIC-P5-ISO-UDPCKSUM-V1: prepare UDP checksum metadata. */
    {
        uint8_t* Frame = rte_pktmbuf_mtod(Packet->Mbuf, uint8_t*);
        uint8_t* Network = Frame + Packet->Mbuf->l2_len;
        uint8_t* Transport = Network + Packet->Mbuf->l3_len;
        struct rte_udp_hdr* Udp = (struct rte_udp_hdr*)Transport;

        if (Packet->Mbuf->l3_len == sizeof(IPV4_HEADER)) {
            struct rte_ipv4_hdr* Ip4 = (struct rte_ipv4_hdr*)Network;
            if (Ip4->next_proto_id == IPPROTO_UDP) {
                const uint64_t Flags =
                    RTE_MBUF_F_TX_IPV4 | RTE_MBUF_F_TX_UDP_CKSUM;
                Packet->Mbuf->ol_flags |= Flags;
                Udp->dgram_cksum = 0;
                Udp->dgram_cksum = rte_ipv4_phdr_cksum(Ip4, Flags);
            }
        } else if (Packet->Mbuf->l3_len == sizeof(IPV6_HEADER)) {
            struct rte_ipv6_hdr* Ip6 = (struct rte_ipv6_hdr*)Network;
            if (Ip6->proto == IPPROTO_UDP) {
                const uint64_t Flags =
                    RTE_MBUF_F_TX_IPV6 | RTE_MBUF_F_TX_UDP_CKSUM;
                Packet->Mbuf->ol_flags |= Flags;
                Udp->dgram_cksum = 0;
                Udp->dgram_cksum = rte_ipv6_phdr_cksum(Ip6, Flags);
            }
        }
    }"""
    once(old, new, "per-packet UDP checksum metadata")

elif feature == "lockfree":
    add_marker()
    old = """    if (!Dpdk->Interface.OffloadStatus.Transmit.Lockfree) {
        CxPlatLockAcquire(&Interface->TxLock);
    }
    const uint16_t TxCount =
        Dpdk->GreenQuicMode == GREENQUIC_MODE_OFF ?
            /* GREENQUIC-STRICT-OFF-V1: original DPDK TX hot path. */
            rte_eth_tx_burst(Interface->Port, 0, Buffers, BufferCount) :
            GreenQuicTrackedTxBurst(
                Interface->Port, 0, Buffers, BufferCount);
    if (!Dpdk->Interface.OffloadStatus.Transmit.Lockfree) {
        CxPlatLockRelease(&Interface->TxLock);
    }
"""
    new = """    /* GREENQUIC-P5-ISO-LOCKFREE-V1: standard P5 uses one DPDK core;
     * this experiment removes only the software TX lock from this build. */
    const uint16_t TxCount =
        Dpdk->GreenQuicMode == GREENQUIC_MODE_OFF ?
            /* GREENQUIC-STRICT-OFF-V1: original DPDK TX hot path. */
            rte_eth_tx_burst(Interface->Port, 0, Buffers, BufferCount) :
            GreenQuicTrackedTxBurst(
                Interface->Port, 0, Buffers, BufferCount);
"""
    once(old, new, "forced TX lock-free")

elif feature == "counters":
    add_marker()

    once(
        "    uint16_t TxRingSize;\n\n    BOOLEAN SeparateRxThread;",
        """    uint16_t TxRingSize;

    /* GREENQUIC-P5-ISO-COUNTERS-V1: counters-only experiment. */
    uint64_t P5IsoTxPartialBursts;
    uint64_t P5IsoTxDroppedPackets;
    uint64_t P5IsoTxRingHighWater;
    uint64_t P5IsoTxLockAcquires;
    uint64_t P5IsoRxAllocExtraAttempts;
    uint64_t P5IsoRxAllocFailures;

    BOOLEAN SeparateRxThread;""",
        "counter fields",
    )

    once(
        """            uint32_t RetryCount = 0;
            do {
                NewPacket = CxPlatPoolAlloc(&Dpdk->AdditionalInfoPool);
            } while (NewPacket == NULL && ++RetryCount < 10);
            if (NewPacket == NULL) {""",
        """            uint32_t RetryCount = 0;
            uint32_t AttemptCount = 0;
            do {
                NewPacket = CxPlatPoolAlloc(&Dpdk->AdditionalInfoPool);
                ++AttemptCount;
            } while (NewPacket == NULL && ++RetryCount < 10);
            if (AttemptCount > 1U) {
                Dpdk->P5IsoRxAllocExtraAttempts += AttemptCount - 1U;
            }
            if (NewPacket == NULL) {
                ++Dpdk->P5IsoRxAllocFailures;""",
        "RX allocation counters",
    )

    once(
        """    const uint32_t RingBefore = rte_ring_count(Interface->TxRingBuffer);
    const uint16_t BufferCount =""",
        """    const uint32_t RingBefore = rte_ring_count(Interface->TxRingBuffer);
    if (RingBefore > Dpdk->P5IsoTxRingHighWater) {
        Dpdk->P5IsoTxRingHighWater = RingBefore;
    }
    const uint16_t BufferCount =""",
        "TX ring high-water counter",
    )

    once(
        """    if (!Dpdk->Interface.OffloadStatus.Transmit.Lockfree) {
        CxPlatLockAcquire(&Interface->TxLock);
    }
""",
        """    if (!Dpdk->Interface.OffloadStatus.Transmit.Lockfree) {
        ++Dpdk->P5IsoTxLockAcquires;
        CxPlatLockAcquire(&Interface->TxLock);
    }
""",
        "TX lock counter",
    )

    once(
        """    if (unlikely(TxCount < BufferCount)) {
        for (uint16_t Index = TxCount; Index < BufferCount; ++Index) {
            rte_pktmbuf_free(Buffers[Index]);
        }
        QuicTraceEvent(""",
        """    if (unlikely(TxCount < BufferCount)) {
        ++Dpdk->P5IsoTxPartialBursts;
        Dpdk->P5IsoTxDroppedPackets += BufferCount - TxCount;
        for (uint16_t Index = TxCount; Index < BufferCount; ++Index) {
            rte_pktmbuf_free(Buffers[Index]);
        }
        QuicTraceEvent(""",
        "partial TX counters",
    )

    anchor = """    /* GREENQUIC-P5-DATAPATH-PACKET-TOTALS-V1
     * Existing datapath totals, emitted once after all workers stop."""
    if anchor not in text:
        raise SystemExit("ERROR: apply_p5_datapath_fix.py must run first")
    telemetry = r'''    /* GREENQUIC-P5-ISO-COUNTERS-V1 process-end diagnostics. */
    printf(
        "[GreenQUIC-P5-ISO-COUNTERS] tx_partial_bursts=%" PRIu64
        " tx_dropped_packets=%" PRIu64 " tx_ring_highwater=%" PRIu64
        " tx_lock_acquires=%" PRIu64 " rx_alloc_extra_attempts=%" PRIu64
        " rx_alloc_failures=%" PRIu64 "\n",
        Dpdk->P5IsoTxPartialBursts,
        Dpdk->P5IsoTxDroppedPackets,
        Dpdk->P5IsoTxRingHighWater,
        Dpdk->P5IsoTxLockAcquires,
        Dpdk->P5IsoRxAllocExtraAttempts,
        Dpdk->P5IsoRxAllocFailures);
    fflush(stdout);

'''
    text = text.replace(anchor, telemetry + anchor, 1)

elif feature == "rxalloc4":
    add_marker()
    old = """            uint32_t RetryCount = 0;
            do {
                NewPacket = CxPlatPoolAlloc(&Dpdk->AdditionalInfoPool);
            } while (NewPacket == NULL && ++RetryCount < 10);
            if (NewPacket == NULL) {"""
    new = """            uint32_t RetryCount = 0;
            do {
                NewPacket = CxPlatPoolAlloc(&Dpdk->AdditionalInfoPool);
            } while (NewPacket == NULL && ++RetryCount < 4);
            if (NewPacket == NULL) {"""
    once(old, new, "RX allocation attempts 4")

if marker not in text:
    raise SystemExit(f"ERROR: generated source missing marker {marker}")

path.write_text(text, encoding="utf-8")
print(f"P5 isolated feature applied: feature={feature} marker={marker}")
