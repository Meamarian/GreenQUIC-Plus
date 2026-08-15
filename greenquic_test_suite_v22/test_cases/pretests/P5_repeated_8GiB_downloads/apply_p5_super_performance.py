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
p.add_argument("--drain-bursts", type=int, default=1)
p.add_argument("--drain-threshold", type=int, default=0)
p.add_argument("--mtu", type=int, default=0)
p.add_argument("--skip-off-ringcount", choices=("0", "1"), default="0")
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
if args.drain_bursts not in (1, 2, 4, 8):
    raise SystemExit("ERROR: --drain-bursts must be 1, 2, 4 or 8")
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
        const uint32_t GreenQuicSuperBacklog =
            rte_ring_count(Interface->TxRingBuffer);
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
    cap_new = r'''    printf(
        "[GreenQUIC-P5-SUPER-CAPS] max_mtu=%u tx_offload_capa=0x%llx rx_offload_capa=0x%llx mt_lockfree=%u mbuf_fast_free=%u udp_cksum=%u ipv4_cksum=%u\n",
        (unsigned)DeviceInfo.max_mtu,
        (unsigned long long)DeviceInfo.tx_offload_capa,
        (unsigned long long)DeviceInfo.rx_offload_capa,
        (DeviceInfo.tx_offload_capa & RTE_ETH_TX_OFFLOAD_MT_LOCKFREE) != 0 ? 1U : 0U,
        (DeviceInfo.tx_offload_capa & RTE_ETH_TX_OFFLOAD_MBUF_FAST_FREE) != 0 ? 1U : 0U,
        (DeviceInfo.tx_offload_capa & RTE_ETH_TX_OFFLOAD_UDP_CKSUM) != 0 ? 1U : 0U,
        (DeviceInfo.tx_offload_capa & RTE_ETH_TX_OFFLOAD_IPV4_CKSUM) != 0 ? 1U : 0U);
    Dpdk->Interface.IfIndex = DeviceInfo.if_index;'''
    replace_once(cap_anchor, cap_new, "startup capability diagnostics")

marker = (
    "GREENQUIC-P5-SUPER-PERF-V1 "
    f"cache={args.cache} rxb={args.rx_burst} txb={args.tx_burst} "
    f"ring={args.ring_size} sync={args.ring_sync} "
    f"drain={args.drain_bursts} threshold={args.drain_threshold} "
    f"mtu={args.mtu} skipoffcount={args.skip_off_ringcount} capdiag={args.cap_diag}"
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
