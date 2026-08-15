#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path
import re

p = argparse.ArgumentParser(
    description="Apply opt-in P5 performance2 experiments after the measured super-performance transform."
)
p.add_argument("datapath")
p.add_argument("--diag-interval-us", type=int, default=0)
p.add_argument("--diag-duration-ms", type=int, default=3000)
p.add_argument("--tx-handoff", choices=("shared", "sharded"), default="shared")
p.add_argument("--tx-producer-ring-size", type=int, default=1024)
p.add_argument("--rx-prefetch", choices=("0", "1"), default="0")
p.add_argument("--udp-seg", choices=("0", "1"), default="0")
p.add_argument("--udp-seg-max", type=int, default=4)
args = p.parse_args()

if args.diag_interval_us < 0:
    raise SystemExit("ERROR: --diag-interval-us must be >= 0")
if args.diag_duration_ms < 0:
    raise SystemExit("ERROR: --diag-duration-ms must be >= 0")
if args.tx_producer_ring_size not in (256, 512, 1024, 2048, 4096):
    raise SystemExit("ERROR: --tx-producer-ring-size must be 256,512,1024,2048,4096")
if args.udp_seg_max not in (2, 4, 8):
    raise SystemExit("ERROR: --udp-seg-max must be 2,4,8")

path = Path(args.datapath)
text = path.read_text(encoding="utf-8")

if "GREENQUIC-P5-PERFORMANCE2-V1" in text:
    raise SystemExit("ERROR: performance2 transform already applied")
if "GREENQUIC-P5-SUPER-PERF-V2" not in text:
    raise SystemExit("ERROR: performance2 requires the measured super-performance transform first")


def replace_once(old: str, new: str, label: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"ERROR: {label}: expected exactly one anchor, found {count}")
    text = text.replace(old, new, 1)


marker = (
    "GREENQUIC-P5-PERFORMANCE2-V1 "
    f"diag_us={args.diag_interval_us} diag_ms={args.diag_duration_ms} "
    f"txhandoff={args.tx_handoff} txpring={args.tx_producer_ring_size} "
    f"rxprefetch={args.rx_prefetch} udpseg={args.udp_seg} udpsegmax={args.udp_seg_max}"
)
include_anchor = "#include <rte_hexdump.h>\n"
replace_once(
    include_anchor,
    include_anchor
    + "\nstatic const char GreenQuicP5Performance2Marker[] __attribute__((used)) =\n"
      f'    "{marker}";\n',
    "performance2 marker",
)

# 1) Short-interval startup diagnostics. Opt-in because printing perturbs throughput.
if args.diag_interval_us > 0:
    ring_anchor = "    const uint32_t RingBefore = rte_ring_count(Interface->TxRingBuffer);"
    if ring_anchor not in text:
        m = re.search(r"(?m)^    const uint32_t RingBefore = .+;$", text)
        if not m:
            raise SystemExit("ERROR: startup diagnostics: RingBefore anchor missing")
        ring_anchor = m.group(0)
    interval = args.diag_interval_us
    duration_us = args.diag_duration_ms * 1000
    diag = ring_anchor + f'''
    static uint64_t GreenQuicP2DiagStartTsc[RTE_MAX_LCORE] = {{0}};
    static uint64_t GreenQuicP2DiagLastTsc[RTE_MAX_LCORE] = {{0}};
    if (Core < RTE_MAX_LCORE && RingBefore != 0U) {{
        const uint64_t GreenQuicP2DiagNow = rte_get_tsc_cycles();
        const uint64_t GreenQuicP2DiagHz = rte_get_tsc_hz();
        if (GreenQuicP2DiagStartTsc[Core] == 0U) {{
            GreenQuicP2DiagStartTsc[Core] = GreenQuicP2DiagNow;
            GreenQuicP2DiagLastTsc[Core] = GreenQuicP2DiagNow;
        }}
        const uint64_t GreenQuicP2DiagElapsedUs =
            (GreenQuicP2DiagNow - GreenQuicP2DiagStartTsc[Core]) * 1000000ULL /
            GreenQuicP2DiagHz;
        const uint64_t GreenQuicP2DiagSinceLastUs =
            (GreenQuicP2DiagNow - GreenQuicP2DiagLastTsc[Core]) * 1000000ULL /
            GreenQuicP2DiagHz;
        if (
            GreenQuicP2DiagElapsedUs <= {duration_us}ULL &&
            GreenQuicP2DiagSinceLastUs >= {interval}ULL) {{
            GreenQuicP2DiagLastTsc[Core] = GreenQuicP2DiagNow;
            fprintf(
                stderr,
                "[P5-PERF2-DIAG] elapsed_us=%" PRIu64
                " core=%u mode=%u ring=%u rx_packets=%" PRIu64
                " tx_packets=%" PRIu64 "\\n",
                GreenQuicP2DiagElapsedUs,
                (unsigned)Core,
                (unsigned)Dpdk->GreenQuicMode,
                (unsigned)RingBefore,
                (uint64_t)Dpdk->RxCounter,
                (uint64_t)Dpdk->TxCounter);
        }}
    }}'''
    replace_once(ring_anchor, diag, "startup diagnostics insertion")

# 2) Optional per-producer SPSC handoff. The raw send contract is one packet per call,
# so true producer-side bulk reservation would otherwise delay the tail packet.
if args.tx_handoff == "sharded":
    linux_include = "#include <sys/eventfd.h>\n"
    replace_once(
        linux_include,
        linux_include + "#include <sys/syscall.h>\n",
        "SYS_gettid include",
    )

    original_count = "rte_ring_count(Interface->TxRingBuffer)"
    count_occurrences = text.count(original_count)
    if count_occurrences < 5:
        raise SystemExit(
            f"ERROR: sharded TX handoff: expected >=5 ring-count sites, found {count_occurrences}"
        )
    text = text.replace(original_count, "GreenQuicP2TxBacklog(Interface)")

    replace_once(
        "rte_ring_mp_enqueue(Interface->TxRingBuffer, Packet->Mbuf)",
        "GreenQuicP2TxEnqueue(Dpdk, Interface, Packet->Mbuf)",
        "sharded producer enqueue",
    )

    dequeue_pattern = re.compile(
        r"    const uint16_t BufferCount =\n"
        r"        \(uint16_t\)rte_ring_sc_dequeue_burst\(\n"
        r"            Interface->TxRingBuffer,\n"
        r"            \(void\*\*\)Buffers,\n"
        r"            Dpdk->TxBurstSize,\n"
        r"            NULL\);"
    )
    repl = '''    const uint16_t BufferCount =
        GreenQuicP2TxDequeueBurst(
            Interface,
            Buffers,
            Dpdk->TxBurstSize,
            NULL);'''
    text, n = dequeue_pattern.subn(repl, text, count=1)
    if n != 1:
        raise SystemExit(f"ERROR: sharded TX handoff: dequeue anchor found {n} times")

    packet_anchor = "} DPDK_TX_PACKET;\n"
    helper = f'''}} DPDK_TX_PACKET;

// GREENQUIC-P5-PERFORMANCE2-V1: optional sharded producer handoff.
#define GREENQUIC_P2_MAX_TX_PRODUCERS 32U
typedef struct GREENQUIC_P2_TX_PRODUCER {{
    long Tid;
    DPDK_INTERFACE* Interface;
    struct rte_ring* Ring;
}} GREENQUIC_P2_TX_PRODUCER;

static GREENQUIC_P2_TX_PRODUCER
    GreenQuicP2TxProducers[GREENQUIC_P2_MAX_TX_PRODUCERS];
static atomic_uint GreenQuicP2TxProducerCount = ATOMIC_VAR_INIT(0);
static atomic_flag GreenQuicP2TxProducerCreateLock = ATOMIC_FLAG_INIT;
static __thread int GreenQuicP2TxTlsSlot = -1;
static __thread BOOLEAN GreenQuicP2TxTlsSharedFallback = FALSE;
static uint32_t GreenQuicP2TxConsumerCursor = 0U;

static int
GreenQuicP2TxGetProducerSlot(
    _In_ DPDK_DATAPATH* Dpdk,
    _In_ DPDK_INTERFACE* Interface)
{{
    UNREFERENCED_PARAMETER(Dpdk);
    if (
        GreenQuicP2TxTlsSlot >= 0 &&
        (uint32_t)GreenQuicP2TxTlsSlot <
            atomic_load_explicit(&GreenQuicP2TxProducerCount, memory_order_acquire) &&
        GreenQuicP2TxProducers[GreenQuicP2TxTlsSlot].Interface == Interface) {{
        return GreenQuicP2TxTlsSlot;
    }}

    const long Tid = (long)syscall(SYS_gettid);
    while (
        atomic_flag_test_and_set_explicit(
            &GreenQuicP2TxProducerCreateLock, memory_order_acquire)) {{
        rte_pause();
    }}

    uint32_t Count =
        atomic_load_explicit(&GreenQuicP2TxProducerCount, memory_order_relaxed);
    for (uint32_t Index = 0; Index < Count; ++Index) {{
        if (
            GreenQuicP2TxProducers[Index].Tid == Tid &&
            GreenQuicP2TxProducers[Index].Interface == Interface) {{
            GreenQuicP2TxTlsSlot = (int)Index;
            atomic_flag_clear_explicit(
                &GreenQuicP2TxProducerCreateLock, memory_order_release);
            return (int)Index;
        }}
    }}

    if (Count >= GREENQUIC_P2_MAX_TX_PRODUCERS) {{
        atomic_flag_clear_explicit(
            &GreenQuicP2TxProducerCreateLock, memory_order_release);
        return -1;
    }}

    char Name[RTE_RING_NAMESIZE];
    (void)snprintf(
        Name,
        sizeof(Name),
        "P2TX_%u_%u",
        (unsigned)Interface->Port,
        (unsigned)Count);
    struct rte_ring* Ring =
        rte_ring_create(
            Name,
            {args.tx_producer_ring_size},
            rte_eth_dev_socket_id(Interface->Port),
            RING_F_SP_ENQ | RING_F_SC_DEQ);
    if (Ring == NULL) {{
        fprintf(
            stderr,
            "[P5-PERF2] producer ring creation failed: tid=%ld slot=%u rte_errno=%d\\n",
            Tid,
            (unsigned)Count,
            rte_errno);
        atomic_flag_clear_explicit(
            &GreenQuicP2TxProducerCreateLock, memory_order_release);
        return -1;
    }}

    GreenQuicP2TxProducers[Count].Tid = Tid;
    GreenQuicP2TxProducers[Count].Interface = Interface;
    GreenQuicP2TxProducers[Count].Ring = Ring;
    atomic_store_explicit(
        &GreenQuicP2TxProducerCount, Count + 1U, memory_order_release);
    GreenQuicP2TxTlsSlot = (int)Count;
    atomic_flag_clear_explicit(
        &GreenQuicP2TxProducerCreateLock, memory_order_release);

    fprintf(
        stderr,
        "[P5-PERF2] registered TX producer: tid=%ld slot=%u ring_size=%u\\n",
        Tid,
        (unsigned)Count,
        (unsigned){args.tx_producer_ring_size});
    return (int)Count;
}}

static int
GreenQuicP2TxEnqueue(
    _In_ DPDK_DATAPATH* Dpdk,
    _In_ DPDK_INTERFACE* Interface,
    _In_ struct rte_mbuf* Mbuf)
{{
    if (!GreenQuicP2TxTlsSharedFallback) {{
        const int Slot = GreenQuicP2TxGetProducerSlot(Dpdk, Interface);
        if (
            Slot >= 0 &&
            rte_ring_sp_enqueue(GreenQuicP2TxProducers[Slot].Ring, Mbuf) == 0) {{
            return 0;
        }}
        /* Keep this producer on the fallback ring after the first fallback. */
        GreenQuicP2TxTlsSharedFallback = TRUE;
    }}
    return rte_ring_mp_enqueue(Interface->TxRingBuffer, Mbuf);
}}

static uint32_t
GreenQuicP2TxBacklog(
    _In_ DPDK_INTERFACE* Interface)
{{
    uint32_t Backlog = rte_ring_count(Interface->TxRingBuffer);
    const uint32_t Count =
        atomic_load_explicit(&GreenQuicP2TxProducerCount, memory_order_acquire);
    for (uint32_t Index = 0; Index < Count; ++Index) {{
        if (GreenQuicP2TxProducers[Index].Interface == Interface) {{
            Backlog += rte_ring_count(GreenQuicP2TxProducers[Index].Ring);
        }}
    }}
    return Backlog;
}}

static uint16_t
GreenQuicP2TxDequeueBurst(
    _In_ DPDK_INTERFACE* Interface,
    _Out_writes_(MaxCount) struct rte_mbuf** Buffers,
    _In_ uint16_t MaxCount,
    _Out_ uint32_t* BacklogBefore)
{{
    if (BacklogBefore != NULL) {{
        *BacklogBefore = GreenQuicP2TxBacklog(Interface);
    }}
    uint16_t Total = 0U;
    const uint32_t Count =
        atomic_load_explicit(&GreenQuicP2TxProducerCount, memory_order_acquire);

    if (Count != 0U) {{
        const uint32_t Start = GreenQuicP2TxConsumerCursor % Count;
        for (uint32_t Step = 0; Step < Count && Total < MaxCount; ++Step) {{
            const uint32_t Index = (Start + Step) % Count;
            if (GreenQuicP2TxProducers[Index].Interface != Interface) {{
                continue;
            }}
            const uint16_t Got =
                (uint16_t)rte_ring_sc_dequeue_burst(
                    GreenQuicP2TxProducers[Index].Ring,
                    (void**)&Buffers[Total],
                    (uint16_t)(MaxCount - Total),
                    NULL);
            if (Got != 0U) {{
                Total = (uint16_t)(Total + Got);
                GreenQuicP2TxConsumerCursor = Index + 1U;
            }}
        }}
    }}

    if (Total < MaxCount) {{
        Total = (uint16_t)(
            Total +
            rte_ring_sc_dequeue_burst(
                Interface->TxRingBuffer,
                (void**)&Buffers[Total],
                (uint16_t)(MaxCount - Total),
                NULL));
    }}
    return Total;
}}
'''
    replace_once(packet_anchor, helper, "sharded TX helper insertion")

# 3) RX prefetch. Existing code already batches the whole RX burst into the raw receive API.
if args.rx_prefetch == "1":
    replace_once(
        "#include <rte_hexdump.h>\n",
        "#include <rte_hexdump.h>\n#include <rte_prefetch.h>\n",
        "rte_prefetch include",
    )
    anchor = '''    uint16_t PacketCount = 0;
    for (uint16_t Index = 0; Index < BuffersCount; ++Index) {'''
    repl = '''    uint16_t PacketCount = 0;
    for (uint16_t GreenQuicP2PrefetchIndex = 0;
         GreenQuicP2PrefetchIndex < BuffersCount;
         ++GreenQuicP2PrefetchIndex) {
        struct rte_mbuf* GreenQuicP2PrefetchMbuf =
            (struct rte_mbuf*)Buffers[GreenQuicP2PrefetchIndex];
        rte_prefetch0(GreenQuicP2PrefetchMbuf);
        rte_prefetch0(
            ((uint8_t*)GreenQuicP2PrefetchMbuf->buf_addr) +
            GreenQuicP2PrefetchMbuf->data_off);
    }
    for (uint16_t Index = 0; Index < BuffersCount; ++Index) {'''
    replace_once(anchor, repl, "RX burst prefetch")

# 4) Experimental UDP segmentation. OFF by default and activated only when all
# required PMD capabilities are advertised.
if args.udp_seg == "1":
    if "RTE_ALIGN_CEIL(sizeof(DPDK_TX_PACKET), RTE_MBUF_PRIV_ALIGN)" not in text:
        raise SystemExit("ERROR: UDP segmentation requires P5_SUPER_TX_META=mbuf")
    replace_once(
        "    DPDK_INTERFACE* Interface;\n} DPDK_TX_PACKET;",
        "    DPDK_INTERFACE* Interface;\n    uint16_t GreenQuicP2Segments;\n} DPDK_TX_PACKET;",
        "UDP segmentation logical segment metadata field",
    )
    replace_once(
        "#include <rte_hexdump.h>\n",
        "#include <rte_hexdump.h>\n#include <rte_net.h>\n",
        "rte_net include for UDP segmentation",
    )

    packet_anchor = "} DPDK_TX_PACKET;\n"
    uso_helper = f'''}} DPDK_TX_PACKET;

// GREENQUIC-P5-PERFORMANCE2-V1: experimental UDP segmentation.
static BOOLEAN GreenQuicP2UdpSegActive = FALSE;
static uint16_t GreenQuicP2UdpSegMaxActive = {args.udp_seg_max}U;

static BOOLEAN
GreenQuicP2UdpSegEligible(
    _In_ const struct rte_mbuf* First,
    _In_ const struct rte_mbuf* Candidate,
    _Out_opt_ uint16_t* PayloadLength)
{{
    if (
        First == NULL || Candidate == NULL ||
        First->nb_segs != 1U || Candidate->nb_segs != 1U ||
        First->l2_len == 0U ||
        First->l3_len != sizeof(IPV4_HEADER) ||
        Candidate->l2_len != First->l2_len ||
        Candidate->l3_len != First->l3_len ||
        First->pkt_len != Candidate->pkt_len) {{
        return FALSE;
    }}

    const uint16_t HeaderLength =
        (uint16_t)(First->l2_len + First->l3_len + sizeof(UDP_HEADER));
    if (First->pkt_len <= HeaderLength || Candidate->pkt_len <= HeaderLength) {{
        return FALSE;
    }}

    const ETHERNET_HEADER* FirstEthernet =
        rte_pktmbuf_mtod(First, const ETHERNET_HEADER*);
    const ETHERNET_HEADER* CandidateEthernet =
        rte_pktmbuf_mtod(Candidate, const ETHERNET_HEADER*);
    if (
        FirstEthernet->Type != ETHERNET_TYPE_IPV4 ||
        CandidateEthernet->Type != ETHERNET_TYPE_IPV4 ||
        memcmp(FirstEthernet->Destination, CandidateEthernet->Destination,
               sizeof(FirstEthernet->Destination)) != 0 ||
        memcmp(FirstEthernet->Source, CandidateEthernet->Source,
               sizeof(FirstEthernet->Source)) != 0) {{
        return FALSE;
    }}

    const IPV4_HEADER* FirstIp =
        (const IPV4_HEADER*)(((const uint8_t*)FirstEthernet) + First->l2_len);
    const IPV4_HEADER* CandidateIp =
        (const IPV4_HEADER*)(((const uint8_t*)CandidateEthernet) + Candidate->l2_len);
    if (
        FirstIp->Protocol != IPPROTO_UDP ||
        CandidateIp->Protocol != IPPROTO_UDP ||
        FirstIp->VersionAndHeaderLength != CandidateIp->VersionAndHeaderLength ||
        FirstIp->TypeOfServiceAndEcnField != CandidateIp->TypeOfServiceAndEcnField ||
        memcmp(FirstIp->Source, CandidateIp->Source, sizeof(FirstIp->Source)) != 0 ||
        memcmp(FirstIp->Destination, CandidateIp->Destination,
               sizeof(FirstIp->Destination)) != 0) {{
        return FALSE;
    }}

    const UDP_HEADER* FirstUdp =
        (const UDP_HEADER*)(((const uint8_t*)FirstIp) + First->l3_len);
    const UDP_HEADER* CandidateUdp =
        (const UDP_HEADER*)(((const uint8_t*)CandidateIp) + Candidate->l3_len);
    if (
        FirstUdp->SourcePort != CandidateUdp->SourcePort ||
        FirstUdp->DestinationPort != CandidateUdp->DestinationPort) {{
        return FALSE;
    }}

    if (PayloadLength != NULL) {{
        *PayloadLength = (uint16_t)(First->pkt_len - HeaderLength);
    }}
    return TRUE;
}}

static uint16_t
GreenQuicP2UdpSegCoalesce(
    _Inout_updates_(Count) struct rte_mbuf** Buffers,
    _In_ uint16_t Count,
    _Out_writes_(Count) uint16_t* LogicalPerPhysical)
{{
    for (uint16_t Index = 0U; Index < Count; ++Index) {{
        LogicalPerPhysical[Index] = 1U;
    }}
    if (!GreenQuicP2UdpSegActive || Count < 2U) {{
        return Count;
    }}

    uint16_t Read = 0U;
    uint16_t Write = 0U;
    while (Read < Count) {{
        struct rte_mbuf* First = Buffers[Read];
        DPDK_TX_PACKET* FirstMeta = (DPDK_TX_PACKET*)rte_mbuf_to_priv(First);
        FirstMeta->GreenQuicP2Segments = 1U;
        uint16_t PayloadLength = 0U;
        uint16_t Group = 1U;

        while (
            Group < GreenQuicP2UdpSegMaxActive &&
            (uint16_t)(Read + Group) < Count &&
            GreenQuicP2UdpSegEligible(
                First, Buffers[Read + Group], &PayloadLength)) {{
            ++Group;
        }}

        if (Group >= 2U && PayloadLength != 0U) {{
            const uint16_t HeaderLength =
                (uint16_t)(First->l2_len + First->l3_len + sizeof(UDP_HEADER));
            struct rte_mbuf* Tail = First;
            for (uint16_t Index = 1U; Index < Group; ++Index) {{
                struct rte_mbuf* Segment = Buffers[Read + Index];
                if (rte_pktmbuf_adj(Segment, HeaderLength) == NULL) {{
                    rte_panic("P5 performance2 UDP segmentation header adjustment failed\\n");
                }}
                Tail->next = Segment;
                Tail = Segment;
                First->nb_segs = (uint16_t)(First->nb_segs + Segment->nb_segs);
                First->pkt_len += Segment->pkt_len;
            }}

            FirstMeta->GreenQuicP2Segments = Group;
            ETHERNET_HEADER* GreenQuicP2Ethernet =
                rte_pktmbuf_mtod(First, ETHERNET_HEADER*);
            IPV4_HEADER* GreenQuicP2Ip =
                (IPV4_HEADER*)(((uint8_t*)GreenQuicP2Ethernet) + First->l2_len);
            UDP_HEADER* GreenQuicP2Udp =
                (UDP_HEADER*)(((uint8_t*)GreenQuicP2Ip) + First->l3_len);
            const uint32_t GreenQuicP2PayloadBytes =
                (uint32_t)PayloadLength * (uint32_t)Group;
            const uint32_t GreenQuicP2UdpBytes =
                (uint32_t)sizeof(UDP_HEADER) + GreenQuicP2PayloadBytes;
            const uint32_t GreenQuicP2IpBytes =
                (uint32_t)First->l3_len + GreenQuicP2UdpBytes;
            if (GreenQuicP2UdpBytes > UINT16_MAX || GreenQuicP2IpBytes > UINT16_MAX) {{
                rte_panic("P5 performance2 UDP segmentation super-packet too large\\n");
            }}
            GreenQuicP2Ip->TotalLength = rte_cpu_to_be_16((uint16_t)GreenQuicP2IpBytes);
            GreenQuicP2Ip->HeaderChecksum = 0U;
            GreenQuicP2Udp->Length = rte_cpu_to_be_16((uint16_t)GreenQuicP2UdpBytes);
            GreenQuicP2Udp->Checksum = 0U;
            First->l4_len = sizeof(UDP_HEADER);
            First->tso_segsz = PayloadLength;
            First->ol_flags |=
                RTE_MBUF_F_TX_IPV4 |
                RTE_MBUF_F_TX_IP_CKSUM |
                RTE_MBUF_F_TX_UDP_CKSUM |
                RTE_MBUF_F_TX_UDP_SEG;

            if (rte_net_intel_cksum_prepare(First) != 0) {{
                rte_panic("P5 performance2 UDP segmentation checksum preparation failed\\n");
            }}
            Buffers[Write++] = First;
            Read = (uint16_t)(Read + Group);
        }} else {{
            Buffers[Write++] = First;
            ++Read;
        }}
    }}
    return Write;
}}

static uint16_t
GreenQuicP2UdpSegLogicalCount(
    _In_reads_(PhysicalCount) const uint16_t* LogicalPerPhysical,
    _In_ uint16_t PhysicalCount)
{{
    uint32_t Logical = 0U;
    for (uint16_t Index = 0U; Index < PhysicalCount; ++Index) {{
        Logical += LogicalPerPhysical[Index];
    }}
    return Logical > UINT16_MAX ? UINT16_MAX : (uint16_t)Logical;
}}
'''
    replace_once(packet_anchor, uso_helper, "UDP segmentation helper insertion")

    roles_anchor = '''    GreenQuicConfigureRoles(
        Dpdk, &DeviceInfo, &PortConfig, &rx_rings, &tx_rings);
'''
    offload_code = roles_anchor + f'''
#if defined(RTE_ETH_TX_OFFLOAD_UDP_TSO) && defined(RTE_ETH_TX_OFFLOAD_MULTI_SEGS)
    const uint64_t GreenQuicP2UdpRequired =
        RTE_ETH_TX_OFFLOAD_UDP_TSO |
        RTE_ETH_TX_OFFLOAD_MULTI_SEGS |
        RTE_ETH_TX_OFFLOAD_IPV4_CKSUM |
        RTE_ETH_TX_OFFLOAD_UDP_CKSUM;
    if ((DeviceInfo.tx_offload_capa & GreenQuicP2UdpRequired) == GreenQuicP2UdpRequired) {{
        if (
            DeviceInfo.tx_desc_lim.nb_seg_max != 0U &&
            GreenQuicP2UdpSegMaxActive > DeviceInfo.tx_desc_lim.nb_seg_max) {{
            GreenQuicP2UdpSegMaxActive = DeviceInfo.tx_desc_lim.nb_seg_max;
        }}
        if (GreenQuicP2UdpSegMaxActive >= 2U) {{
            PortConfig.txmode.offloads |= GreenQuicP2UdpRequired;
            Dpdk->Interface.OffloadStatus.Transmit.NetworkLayerXsum = TRUE;
            Dpdk->Interface.OffloadStatus.Transmit.TransportLayerXsum = TRUE;
            GreenQuicP2UdpSegActive = TRUE;
        }}
    }}
    fprintf(
        stderr,
        "[P5-PERF2-USO] requested=1 active=%u udp_tso=%u multi_segs=%u "
        "ipv4_cksum=%u udp_cksum=%u nb_seg_max=%u max_group=%u\\n",
        GreenQuicP2UdpSegActive ? 1U : 0U,
        (DeviceInfo.tx_offload_capa & RTE_ETH_TX_OFFLOAD_UDP_TSO) != 0U ? 1U : 0U,
        (DeviceInfo.tx_offload_capa & RTE_ETH_TX_OFFLOAD_MULTI_SEGS) != 0U ? 1U : 0U,
        (DeviceInfo.tx_offload_capa & RTE_ETH_TX_OFFLOAD_IPV4_CKSUM) != 0U ? 1U : 0U,
        (DeviceInfo.tx_offload_capa & RTE_ETH_TX_OFFLOAD_UDP_CKSUM) != 0U ? 1U : 0U,
        (unsigned)DeviceInfo.tx_desc_lim.nb_seg_max,
        (unsigned)GreenQuicP2UdpSegMaxActive);
#else
    fprintf(
        stderr,
        "[P5-PERF2-USO] requested=1 active=0 reason=DPDK_headers_lack_UDP_TSO_or_MULTI_SEGS\\n");
#endif
'''
    replace_once(roles_anchor, offload_code, "UDP segmentation port offload setup")

    trace_anchor = '''    QuicTraceEvent(
        DatapathTxDequeue,'''
    replace_once(
        trace_anchor,
        '''    uint16_t GreenQuicP2LogicalPerPhysical[Dpdk->TxBurstSize];
    uint16_t GreenQuicP2TxBufferCount =
        GreenQuicP2UdpSegCoalesce(
            Buffers, BufferCount, GreenQuicP2LogicalPerPhysical);

''' + trace_anchor,
        "UDP segmentation coalesce call",
    )

    text, n = re.subn(
        r"(rte_eth_tx_burst\(Interface->Port, 0, Buffers, )BufferCount(\))",
        r"\1GreenQuicP2TxBufferCount\2",
        text,
        count=1,
    )
    if n != 1:
        raise SystemExit(f"ERROR: UDP segmentation OFF-mode TX burst anchor found {n} times")
    text, n = re.subn(
        r"(GreenQuicTrackedTxBurst\(\n\s*Interface->Port, 0, Buffers, )BufferCount(\);)",
        r"\1GreenQuicP2TxBufferCount\2",
        text,
        count=1,
    )
    if n != 1:
        raise SystemExit(f"ERROR: UDP segmentation tracked TX burst anchor found {n} times")

    tx_statement = re.compile(
        r"    const uint16_t TxCount =\n"
        r"        Dpdk->GreenQuicMode == GREENQUIC_MODE_OFF \?\n"
        r"            /\* GREENQUIC-STRICT-OFF-V1: original DPDK TX hot path\. \*/\n"
        r"            rte_eth_tx_burst\(Interface->Port, 0, Buffers, GreenQuicP2TxBufferCount\) :\n"
        r"            GreenQuicTrackedTxBurst\(\n"
        r"                Interface->Port, 0, Buffers, GreenQuicP2TxBufferCount\);"
    )
    m = tx_statement.search(text)
    if not m:
        raise SystemExit("ERROR: UDP segmentation TX statement anchor missing")
    replacement = m.group(0) + '''
    const uint16_t GreenQuicP2LogicalTxCount =
        GreenQuicP2UdpSegLogicalCount(
            GreenQuicP2LogicalPerPhysical, TxCount);
    if (
        Dpdk->GreenQuicMode != GREENQUIC_MODE_OFF &&
        GreenQuicP2LogicalTxCount > TxCount) {
        GreenQuicTransferOnTx(
            (uint16_t)(GreenQuicP2LogicalTxCount - TxCount));
    }'''
    text = text[:m.start()] + replacement + text[m.end():]

    replace_once(
        "    Dpdk->TxCounter += TxCount;",
        "    Dpdk->TxCounter += GreenQuicP2LogicalTxCount;",
        "logical TxCounter under UDP segmentation",
    )
    replace_once(
        "            Dpdk, Core, RingBefore, BufferCount, TxCount);",
        "            Dpdk, Core, RingBefore, BufferCount, GreenQuicP2LogicalTxCount);",
        "logical GreenQuicOnTxPoll under UDP segmentation",
    )
    replace_once(
        "    if (unlikely(TxCount < BufferCount)) {",
        "    if (unlikely(TxCount < GreenQuicP2TxBufferCount)) {",
        "UDP segmentation partial TX condition",
    )
    replace_once(
        "        for (uint16_t Index = TxCount; Index < BufferCount; ++Index) {",
        "        for (uint16_t Index = TxCount; Index < GreenQuicP2TxBufferCount; ++Index) {",
        "UDP segmentation partial TX free bound",
    )
    if "TxCount == BufferCount" in text:
        text = text.replace(
            "TxCount == BufferCount",
            "TxCount == GreenQuicP2TxBufferCount",
            1,
        )

if args.diag_interval_us > 0 and "GreenQuicP2DiagStartTsc" not in text:
    raise SystemExit("ERROR: diagnostics marker missing after transform")

path.write_text(text, encoding="utf-8")
print(marker)
