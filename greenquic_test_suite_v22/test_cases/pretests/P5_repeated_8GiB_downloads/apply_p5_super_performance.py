#!/usr/bin/env python3
from __future__ import annotations
import argparse
from pathlib import Path
import re

p = argparse.ArgumentParser()
p.add_argument("datapath")
p.add_argument("--cache", type=int, default=128)
p.add_argument("--rx-burst", type=int, default=32)
p.add_argument("--tx-burst", type=int, default=16)
p.add_argument("--ring-size", type=int, default=4096)
p.add_argument("--ring-sync", choices=("legacy", "mp", "hts", "rts"), default="legacy")
p.add_argument("--drain-bursts", type=int, default=4)
p.add_argument("--drain-threshold", type=int, default=0)
p.add_argument("--mtu", type=int, default=0)
p.add_argument("--skip-off-ringcount", choices=("0", "1"), default="0")
p.add_argument("--debug-counters", choices=("0", "1"), default="1")
p.add_argument("--transfer-window", choices=("0", "1"), default="1")
p.add_argument("--trace-ringcount", choices=("0", "1"), default="1")
p.add_argument("--tx-meta", choices=("pool", "mbuf"), default="mbuf")
p.add_argument("--rx-meta", choices=("pool", "mbuf"), default="mbuf")
p.add_argument(
    "--tx-lock-mode",
    choices=("legacy", "capability", "single_owner"),
    default="single_owner",
)
p.add_argument("--cap-diag", choices=("0", "1"), default="1")
args = p.parse_args()

if args.cache not in (128, 256, 512):
    raise SystemExit("ERROR: --cache must be 128, 256 or 512")
if args.rx_burst not in (16, 32, 64, 128):
    raise SystemExit("ERROR: --rx-burst must be 16, 32, 64 or 128")
if args.tx_burst not in (16, 32, 64, 128):
    raise SystemExit("ERROR: --tx-burst must be 16, 32, 64 or 128")
if args.ring_size not in (1024, 2048, 4096, 8192):
    raise SystemExit("ERROR: --ring-size must be 1024, 2048, 4096 or 8192")
if not 1 <= args.drain_bursts <= 8:
    raise SystemExit("ERROR: --drain-bursts must be in [1, 8]")
if args.drain_threshold < 0 or args.drain_threshold > args.ring_size:
    raise SystemExit("ERROR: --drain-threshold must be between 0 and ring-size")
if args.drain_bursts == 1 and args.drain_threshold != 0:
    raise SystemExit("ERROR: --drain-threshold requires --drain-bursts > 1")
if args.mtu not in (0, 1500):
    raise SystemExit("ERROR: --mtu currently supports 0 or 1500 only")

path = Path(args.datapath)
text = path.read_text(encoding="utf-8")

bad_markers = (
    "GREENQUIC-P5-SUPER-PERF-V1",
    "GREENQUIC-P5-SUPER-PERF-V2",
    "GREENQUIC-P5-STATIC-PERF-V2",
    "GREENQUIC-P5-RING-",
    "GREENQUIC-P5-ISO-",
    "GREENQUIC-P5-MAX-GOODPUT-V1",
)
for marker in bad_markers:
    if marker in text:
        raise SystemExit(
            f"ERROR: source already contains performance marker {marker}; "
            "restore the disposable datapath before applying super performance"
        )


def replace_once(old: str, new: str, label: str) -> None:
    global text
    n = text.count(old)
    if n != 1:
        raise SystemExit(f"ERROR: {label}: expected exactly one anchor, found {n}")
    text = text.replace(old, new, 1)


def replace_macro(name: str, value: int) -> None:
    global text
    pattern = rf"(?m)^#define\s+{re.escape(name)}\s+.*$"
    matches = re.findall(pattern, text)
    if len(matches) != 1:
        raise SystemExit(f"ERROR: expected exactly one {name}, found {len(matches)}")
    text = re.sub(pattern, f"#define {name:<28} {value}", text, count=1)


replace_macro("DEFAULT_MBUF_CACHE_SIZE", args.cache)
replace_macro("DEFAULT_RX_BURST_SIZE", args.rx_burst)
replace_macro("DEFAULT_TX_BURST_SIZE", args.tx_burst)
replace_macro("DEFAULT_TX_RING_SIZE", args.ring_size)

create_old = '''    Dpdk->Interface.TxRingBuffer =
            rte_ring_create(
                    "TxRing", Dpdk->TxRingSize, rte_eth_dev_socket_id(Port),
                    RING_F_MP_HTS_ENQ | RING_F_SC_DEQ);'''
enqueue_old = "rte_ring_mp_enqueue(Interface->TxRingBuffer, Packet->Mbuf)"

if args.ring_sync == "mp":
    create_new = '''    Dpdk->Interface.TxRingBuffer =
            rte_ring_create(
                    "TxRing", Dpdk->TxRingSize, rte_eth_dev_socket_id(Port),
                    RING_F_SC_DEQ);'''
    replace_once(create_old, create_new, "classic MP ring creation")
elif args.ring_sync == "hts":
    replace_once(
        enqueue_old,
        "rte_ring_enqueue(Interface->TxRingBuffer, Packet->Mbuf)",
        "HTS generic enqueue",
    )
elif args.ring_sync == "rts":
    create_new = '''    Dpdk->Interface.TxRingBuffer =
            rte_ring_create(
                    "TxRing", Dpdk->TxRingSize, rte_eth_dev_socket_id(Port),
                    RING_F_MP_RTS_ENQ | RING_F_SC_DEQ);'''
    replace_once(create_old, create_new, "RTS ring creation")
    replace_once(
        enqueue_old,
        "rte_ring_enqueue(Interface->TxRingBuffer, Packet->Mbuf)",
        "RTS generic enqueue",
    )

if args.mtu == 1500:
    replace_once(
        "    PortConfig.rxmode.mtu = DeviceInfo.max_mtu;",
        "    PortConfig.rxmode.mtu = 1500;",
        "P5/P7 MTU alignment",
    )

if args.tx_lock_mode != "legacy":
    fast_free_old = '''    if (DeviceInfo.tx_offload_capa & RTE_ETH_TX_OFFLOAD_MBUF_FAST_FREE) {
        printf("Mbuf fast free offload activated\\n");
        PortConfig.txmode.offloads |= RTE_ETH_TX_OFFLOAD_MBUF_FAST_FREE;
        Dpdk->Interface.OffloadStatus.Transmit.Lockfree = TRUE;
    }'''
    fast_free_new = '''    if (DeviceInfo.tx_offload_capa & RTE_ETH_TX_OFFLOAD_MBUF_FAST_FREE) {
        printf("Mbuf fast free offload activated\\n");
        PortConfig.txmode.offloads |= RTE_ETH_TX_OFFLOAD_MBUF_FAST_FREE;
        /* MBUF_FAST_FREE does not imply RTE_ETH_TX_OFFLOAD_MT_LOCKFREE. */
    }'''
    replace_once(fast_free_old, fast_free_new, "MBUF_FAST_FREE/MT_LOCKFREE bookkeeping")

if args.tx_lock_mode == "single_owner":
    replace_once(
        '''    if (!Dpdk->Interface.OffloadStatus.Transmit.Lockfree) {
        CxPlatLockAcquire(&Interface->TxLock);
    }''',
        '''    /* GREENQUIC-P5-SUPER: the configured DPDK TX owner is the only
     * data-path caller of rte_eth_tx_burst, so no per-burst lock is needed. */''',
        "single-owner TX lock acquire elision",
    )
    replace_once(
        '''    if (!Dpdk->Interface.OffloadStatus.Transmit.Lockfree) {
        CxPlatLockRelease(&Interface->TxLock);
    }''',
        '''    /* GREENQUIC-P5-SUPER: matching single-owner TX lock release elided. */''',
        "single-owner TX lock release elision",
    )

if args.debug_counters == "0":
    replace_once(
        "    Dpdk->RxCounter += BuffersCount;",
        "    /* GREENQUIC-P5-SUPER: debugging RxCounter disabled. */",
        "RX debugging counter",
    )
    replace_once(
        "    Dpdk->TxEnqueueCounter++; // increase in any case, even if packet was dropped",
        "    /* GREENQUIC-P5-SUPER: debugging TxEnqueueCounter disabled. */",
        "TX enqueue debugging counter",
    )
    replace_once(
        "    Dpdk->TxCounter += TxCount;",
        "    /* GREENQUIC-P5-SUPER: debugging TxCounter disabled. */",
        "TX debugging counter",
    )

if args.transfer_window == "0":
    rx_track_old = '''        BuffersCount = GreenQuicTrackedRxBurst(
            Interface->Port,
            QueueId,
            (struct rte_mbuf**)Buffers,
            Dpdk->RxBurstSize);'''
    rx_track_new = '''        BuffersCount = rte_eth_rx_burst(
            Interface->Port,
            QueueId,
            (struct rte_mbuf**)Buffers,
            Dpdk->RxBurstSize);'''
    replace_once(rx_track_old, rx_track_new, "RX transfer-window hot path")

    tx_track_old = '''            GreenQuicTrackedTxBurst(
                Interface->Port, 0, Buffers, BufferCount);'''
    tx_track_new = '''            rte_eth_tx_burst(
                Interface->Port, 0, Buffers, BufferCount);'''
    replace_once(tx_track_old, tx_track_new, "TX transfer-window hot path")
    replace_once(
        "__attribute__((destructor))\nstatic void\nGreenQuicTransferWindowWrite(void)",
        "__attribute__((unused))\nstatic void\nGreenQuicTransferWindowWrite(void)",
        "transfer-window destructor disable",
    )

if args.trace_ringcount == "0":
    replace_once(
        '''                "[data] TX packet (%u bytes) enqueued in ring (now %u entries).",
                Packet->Mbuf->data_len,
                rte_ring_count(Interface->TxRingBuffer));''',
        '''                "[data] TX packet (%u bytes) enqueued in ring (ring count disabled=%u).",
                Packet->Mbuf->data_len,
                0U);''',
        "TX enqueue trace ring count",
    )
    replace_once(
        '''        "[data] %u packets dequeued from TX ring (now %u entries).",
        BufferCount,
        rte_ring_count(Interface->TxRingBuffer));''',
        '''        "[data] %u packets dequeued from TX ring (ring count disabled=%u).",
        BufferCount,
        0U);''',
        "TX dequeue trace ring count",
    )

if args.tx_meta == "mbuf":
    replace_once(
        '"MBUF_POOL_TX", Dpdk->TxMbufPoolSize, Dpdk->MbufCacheSize, 0,',
        '"MBUF_POOL_TX", Dpdk->TxMbufPoolSize, Dpdk->MbufCacheSize,\n                    RTE_ALIGN_CEIL(sizeof(DPDK_TX_PACKET), RTE_MBUF_PRIV_ALIGN),',
        "TX mbuf private metadata size",
    )
    tx_alloc_old = '''    DPDK_DATAPATH* Dpdk = (DPDK_DATAPATH*)Socket->RawDatapath;
    DPDK_TX_PACKET* Packet = CxPlatPoolAlloc(&Dpdk->AdditionalInfoPool);
    QUIC_ADDRESS_FAMILY Family = QuicAddrGetFamily(&Config->Route->RemoteAddress);
    DPDK_INTERFACE* Interface = (DPDK_INTERFACE*)Config->Route->Queue;

    if (likely(Packet)) {
        Packet->Interface = Interface;
        Packet->Mbuf = rte_pktmbuf_alloc(Interface->TxMemoryPool);
        if (likely(Packet->Mbuf)) {
            HEADER_BACKFILL HeaderFill = CxPlatDpRawCalculateHeaderBackFill(Family, Socket->UseTcp);
            Packet->Dpdk = Dpdk;
            Packet->Buffer.Length = Config->MaxPacketSize;
            Packet->Mbuf->data_off = 0;
            Packet->Buffer.Buffer = ((uint8_t*)Packet->Mbuf->buf_addr) + HeaderFill.AllLayer;
            Packet->Mbuf->l2_len = HeaderFill.LinkLayer;
            Packet->Mbuf->l3_len = HeaderFill.NetworkLayer;
            Packet->DatapathType = Config->Route->DatapathType = CXPLAT_DATAPATH_TYPE_RAW;
        } else {
            CxPlatPoolFree(&Dpdk->AdditionalInfoPool, Packet);
            Packet = NULL;
            QuicTraceEvent(
                    LibraryError,
                    "[ lib] ERROR, %s.",
                    "Failed to allocate mbuf in TxMemoryPool");
        }
    }
    return (CXPLAT_SEND_DATA*)Packet;'''
    tx_alloc_new = '''    DPDK_DATAPATH* Dpdk = (DPDK_DATAPATH*)Socket->RawDatapath;
    QUIC_ADDRESS_FAMILY Family = QuicAddrGetFamily(&Config->Route->RemoteAddress);
    DPDK_INTERFACE* Interface = (DPDK_INTERFACE*)Config->Route->Queue;
    struct rte_mbuf* Mbuf = rte_pktmbuf_alloc(Interface->TxMemoryPool);
    DPDK_TX_PACKET* Packet = NULL;

    if (likely(Mbuf)) {
        Packet = (DPDK_TX_PACKET*)rte_mbuf_to_priv(Mbuf);
        CxPlatZeroMemory(Packet, sizeof(*Packet));
        Packet->Interface = Interface;
        Packet->Mbuf = Mbuf;
        HEADER_BACKFILL HeaderFill = CxPlatDpRawCalculateHeaderBackFill(Family, Socket->UseTcp);
        Packet->Dpdk = Dpdk;
        Packet->Buffer.Length = Config->MaxPacketSize;
        Packet->Mbuf->data_off = 0;
        Packet->Buffer.Buffer = ((uint8_t*)Packet->Mbuf->buf_addr) + HeaderFill.AllLayer;
        Packet->Mbuf->l2_len = HeaderFill.LinkLayer;
        Packet->Mbuf->l3_len = HeaderFill.NetworkLayer;
        Packet->DatapathType = Config->Route->DatapathType = CXPLAT_DATAPATH_TYPE_RAW;
    } else {
        QuicTraceEvent(
                LibraryError,
                "[ lib] ERROR, %s.",
                "Failed to allocate mbuf in TxMemoryPool");
    }
    return (CXPLAT_SEND_DATA*)Packet;'''
    replace_once(tx_alloc_old, tx_alloc_new, "TX metadata-in-mbuf allocation")
    replace_once(
        '''    rte_pktmbuf_free(Packet->Mbuf);
    CxPlatPoolFree(&Packet->Dpdk->AdditionalInfoPool, SendData);''',
        '''    rte_pktmbuf_free(Packet->Mbuf);
    /* TX metadata is private storage owned by Packet->Mbuf. */''',
        "TX metadata-in-mbuf free",
    )
    replace_once(
        '''    CxPlatPoolFree(&Dpdk->AdditionalInfoPool, Packet);
}


static
void
CxPlatDpdkTx(''',
        '''    /* TX metadata is private storage owned by the enqueued mbuf. */
}


static
void
CxPlatDpdkTx(''',
        "TX metadata-in-mbuf enqueue lifetime",
    )

if args.rx_meta == "mbuf":
    replace_once(
        '"MBUF_POOL_RX", Dpdk->RxMbufPoolSize, Dpdk->MbufCacheSize, 0,',
        '"MBUF_POOL_RX", Dpdk->RxMbufPoolSize, Dpdk->MbufCacheSize,\n                    RTE_ALIGN_CEIL(sizeof(DPDK_RX_PACKET), RTE_MBUF_PRIV_ALIGN),',
        "RX mbuf private metadata size",
    )
    rx_alloc_old = '''            uint32_t RetryCount = 0;
            do {
                NewPacket = CxPlatPoolAlloc(&Dpdk->AdditionalInfoPool);
            } while (NewPacket == NULL && ++RetryCount < 10);
            if (NewPacket == NULL) {
                QuicTraceEvent(
                    AllocFailure,
                    "Allocation of '%s' failed. (%llu bytes)",
                    "DPDK_RX_PACKET",
                    0);
                rte_pktmbuf_free(Buffer);
                continue;
            }

            CxPlatCopyMemory(NewPacket, &Packet, sizeof(DPDK_RX_PACKET));
            NewPacket->RecvData.Allocated = TRUE;
            NewPacket->Mbuf = Buffer;
            NewPacket->OwnerPool = &Dpdk->AdditionalInfoPool;'''
    rx_alloc_new = '''            NewPacket = (DPDK_RX_PACKET*)rte_mbuf_to_priv(Buffer);
            CxPlatCopyMemory(NewPacket, &Packet, sizeof(DPDK_RX_PACKET));
            NewPacket->RecvData.Allocated = TRUE;
            NewPacket->Mbuf = Buffer;
            NewPacket->OwnerPool = NULL;'''
    replace_once(rx_alloc_old, rx_alloc_new, "RX metadata-in-mbuf allocation")
    replace_once(
        '''        rte_pktmbuf_free(Packet->Mbuf);
        CxPlatPoolFree(Packet->OwnerPool, (void*)Packet);''',
        '''        rte_pktmbuf_free(Packet->Mbuf);
        /* RX metadata is private storage owned by Packet->Mbuf. */''',
        "RX metadata-in-mbuf free",
    )

ring_before_original = "    const uint32_t RingBefore = rte_ring_count(Interface->TxRingBuffer);"
ring_before_active = ring_before_original
if args.skip_off_ringcount == "1":
    ring_before_active = '''    const uint32_t RingBefore =
        Dpdk->GreenQuicMode == GREENQUIC_MODE_OFF ?
            0U : rte_ring_count(Interface->TxRingBuffer);'''
    replace_once(
        ring_before_original,
        ring_before_active,
        "OFF unnecessary ring-count removal",
    )

if args.drain_bursts > 1:
    drain_prefix = f'''    uint16_t GreenQuicSuperDrainBudget = {args.drain_bursts};
GreenQuicSuperDrainAgain: ;
{ring_before_active}'''
    replace_once(ring_before_active, drain_prefix, "bounded TX drain loop entry")

    tail_old = '''    if (unlikely(TxCount < BufferCount)) {
        for (uint16_t Index = TxCount; Index < BufferCount; ++Index) {
            rte_pktmbuf_free(Buffers[Index]);
        }
        QuicTraceEvent(
            LibraryError,
            "[ lib] ERROR, %s.",
            "DPDK TX burst failed to send all packets");
    }
}'''
    threshold = args.drain_threshold
    tail_new = f'''    if (unlikely(TxCount < BufferCount)) {{
        for (uint16_t Index = TxCount; Index < BufferCount; ++Index) {{
            rte_pktmbuf_free(Buffers[Index]);
        }}
        QuicTraceEvent(
            LibraryError,
            "[ lib] ERROR, %s.",
            "DPDK TX burst failed to send all packets");
    }}
    if (GreenQuicSuperDrainBudget > 1 && TxCount == BufferCount) {{
        const uint32_t GreenQuicSuperBacklog = rte_ring_count(Interface->TxRingBuffer);
        if (
            GreenQuicSuperBacklog > 0 &&
            ({threshold}U == 0U || GreenQuicSuperBacklog >= {threshold}U)) {{
            --GreenQuicSuperDrainBudget;
            goto GreenQuicSuperDrainAgain;
        }}
    }}
}}'''
    replace_once(tail_old, tail_new, "bounded TX drain loop exit")

if args.cap_diag == "1":
    cap_anchor = "    Dpdk->Interface.IfIndex = DeviceInfo.if_index;"
    cap_new = f'''#ifdef RTE_ETH_TX_OFFLOAD_MULTI_SEGS
    const unsigned GreenQuicCapMultiSegs =
        (DeviceInfo.tx_offload_capa & RTE_ETH_TX_OFFLOAD_MULTI_SEGS) != 0 ? 1U : 0U;
#else
    const unsigned GreenQuicCapMultiSegs = 0U;
#endif
#ifdef RTE_ETH_TX_OFFLOAD_UDP_TSO
    const unsigned GreenQuicCapUdpTso =
        (DeviceInfo.tx_offload_capa & RTE_ETH_TX_OFFLOAD_UDP_TSO) != 0 ? 1U : 0U;
#else
    const unsigned GreenQuicCapUdpTso = 0U;
#endif
    printf(
        "[GreenQUIC-P5-SUPER-CAPS] max_mtu=%u tx_offload_capa=0x%llx rx_offload_capa=0x%llx mt_lockfree=%u mbuf_fast_free=%u udp_cksum=%u ipv4_cksum=%u multi_segs=%u udp_tso=%u max_rxq=%u max_txq=%u tx_lock_mode={args.tx_lock_mode}\\n",
        (unsigned)DeviceInfo.max_mtu,
        (unsigned long long)DeviceInfo.tx_offload_capa,
        (unsigned long long)DeviceInfo.rx_offload_capa,
        (DeviceInfo.tx_offload_capa & RTE_ETH_TX_OFFLOAD_MT_LOCKFREE) != 0 ? 1U : 0U,
        (DeviceInfo.tx_offload_capa & RTE_ETH_TX_OFFLOAD_MBUF_FAST_FREE) != 0 ? 1U : 0U,
        (DeviceInfo.tx_offload_capa & RTE_ETH_TX_OFFLOAD_UDP_CKSUM) != 0 ? 1U : 0U,
        (DeviceInfo.tx_offload_capa & RTE_ETH_TX_OFFLOAD_IPV4_CKSUM) != 0 ? 1U : 0U,
        GreenQuicCapMultiSegs,
        GreenQuicCapUdpTso,
        (unsigned)DeviceInfo.max_rx_queues,
        (unsigned)DeviceInfo.max_tx_queues);
    Dpdk->Interface.IfIndex = DeviceInfo.if_index;'''
    replace_once(cap_anchor, cap_new, "startup capability diagnostics")

marker = (
    "GREENQUIC-P5-SUPER-PERF-V2 "
    f"cache={args.cache} rxb={args.rx_burst} txb={args.tx_burst} "
    f"ring={args.ring_size} sync={args.ring_sync} "
    f"drain={args.drain_bursts} threshold={args.drain_threshold} "
    f"mtu={args.mtu} skipoffcount={args.skip_off_ringcount} "
    f"debugcounters={args.debug_counters} transferwindow={args.transfer_window} "
    f"traceringcount={args.trace_ringcount} txmeta={args.tx_meta} rxmeta={args.rx_meta} "
    f"txlock={args.tx_lock_mode} capdiag={args.cap_diag}"
)
include_anchor = "#include <rte_hexdump.h>\n"
replace_once(
    include_anchor,
    include_anchor
    + '\nstatic const char GreenQuicP5SuperPerfMarker[] __attribute__((used)) =\n'
      f'    "{marker}";\n',
    "super performance marker",
)

path.write_text(text, encoding="utf-8")
print(marker)
