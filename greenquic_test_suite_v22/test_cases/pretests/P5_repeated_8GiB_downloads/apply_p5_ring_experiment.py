#!/usr/bin/env python3
"""Apply exactly one TX-ring experiment on top of the cache128 baseline.

Every profile is isolated: the caller must first restore the cache128 datapath,
then invoke this transformer once.  No GreenQUIC/GreenQUIC+ policy is changed.
"""

from pathlib import Path
import re
import sys

PROFILES = {
    "hts_generic": "GREENQUIC-P5-RING-HTS-GENERIC-V1",
    "mp_classic": "GREENQUIC-P5-RING-MP-CLASSIC-V1",
    "rts_generic": "GREENQUIC-P5-RING-RTS-GENERIC-V1",
    "deq_generic": "GREENQUIC-P5-RING-DEQ-GENERIC-V1",
    "ring1024": "GREENQUIC-P5-RING-SIZE1024-V1",
    "ring2048": "GREENQUIC-P5-RING-SIZE2048-V1",
    "ring8192": "GREENQUIC-P5-RING-SIZE8192-V1",
    "txburst16": "GREENQUIC-P5-RING-TXBURST16-V1",
    "txburst64": "GREENQUIC-P5-RING-TXBURST64-V1",
    "txburst128": "GREENQUIC-P5-RING-TXBURST128-V1",
}

if len(sys.argv) != 3:
    raise SystemExit(
        "usage: apply_p5_ring_experiment.py "
        "{hts_generic|mp_classic|rts_generic|deq_generic|ring1024|ring2048|ring8192|txburst16|txburst64|txburst128} "
        "datapath_raw_dpdk_linux.c"
    )

profile = sys.argv[1].strip().lower()
path = Path(sys.argv[2])
if profile not in PROFILES:
    raise SystemExit(f"ERROR: unknown ring profile {profile!r}")

text = path.read_text(encoding="utf-8")
marker = PROFILES[profile]

for other in PROFILES.values():
    if other in text:
        raise SystemExit(
            f"ERROR: ring experiment source already contains {other}; "
            "restore cache128 before applying another ring profile"
        )


def once(old: str, new: str, label: str) -> None:
    global text
    n = text.count(old)
    if n != 1:
        raise SystemExit(f"ERROR: {label}: expected one anchor, found {n}")
    text = text.replace(old, new, 1)


def replace_macro(name: str, value: int) -> None:
    global text
    pattern = rf"(?m)^#define\s+{re.escape(name)}\s+.*$"
    matches = re.findall(pattern, text)
    if len(matches) != 1:
        raise SystemExit(f"ERROR: expected exactly one {name}, found {len(matches)}")
    text = re.sub(pattern, f"#define {name:<28} {value}", text, count=1)


create_old = '''    Dpdk->Interface.TxRingBuffer =
            rte_ring_create(
                    "TxRing", Dpdk->TxRingSize, rte_eth_dev_socket_id(Port),
                    RING_F_MP_HTS_ENQ | RING_F_SC_DEQ);'''

enqueue_old = "rte_ring_mp_enqueue(Interface->TxRingBuffer, Packet->Mbuf)"
dequeue_old = "rte_ring_sc_dequeue_burst(\n            Interface->TxRingBuffer,"

if profile == "hts_generic":
    # Keep the existing MP-HTS creation flag, but use the generic enqueue API
    # that dispatches according to the ring's configured producer sync type.
    once(
        enqueue_old,
        "rte_ring_enqueue(Interface->TxRingBuffer, Packet->Mbuf)",
        "HTS generic enqueue",
    )

elif profile == "mp_classic":
    # Remove the HTS producer flag.  Keep the explicit MP enqueue call.
    create_new = '''    Dpdk->Interface.TxRingBuffer =
            rte_ring_create(
                    "TxRing", Dpdk->TxRingSize, rte_eth_dev_socket_id(Port),
                    RING_F_SC_DEQ);'''
    once(create_old, create_new, "classic MP ring creation")

elif profile == "rts_generic":
    # RTS must be selected at ring creation and reached through the generic API.
    create_new = '''    Dpdk->Interface.TxRingBuffer =
            rte_ring_create(
                    "TxRing", Dpdk->TxRingSize, rte_eth_dev_socket_id(Port),
                    RING_F_MP_RTS_ENQ | RING_F_SC_DEQ);'''
    once(create_old, create_new, "RTS ring creation")
    once(
        enqueue_old,
        "rte_ring_enqueue(Interface->TxRingBuffer, Packet->Mbuf)",
        "RTS generic enqueue",
    )

elif profile == "deq_generic":
    # Consumer remains single-consumer via RING_F_SC_DEQ, but use the generic
    # dequeue API so the configured consumer synchronization is honored.
    once(
        dequeue_old,
        "rte_ring_dequeue_burst(\n            Interface->TxRingBuffer,",
        "generic dequeue",
    )

elif profile == "ring1024":
    replace_macro("DEFAULT_TX_RING_SIZE", 1024)

elif profile == "ring2048":
    replace_macro("DEFAULT_TX_RING_SIZE", 2048)

elif profile == "ring8192":
    replace_macro("DEFAULT_TX_RING_SIZE", 8192)

elif profile == "txburst16":
    replace_macro("DEFAULT_TX_BURST_SIZE", 16)

elif profile == "txburst64":
    replace_macro("DEFAULT_TX_BURST_SIZE", 64)

elif profile == "txburst128":
    replace_macro("DEFAULT_TX_BURST_SIZE", 128)

# A used marker makes binary contamination checks reliable even if the source
# change itself is optimized/inlined.
anchor = "#include <rte_hexdump.h>\n"
ident = re.sub(r"[^A-Za-z0-9]", "_", profile)
once(
    anchor,
    anchor
    + f'\nstatic const char GreenQuicP5Ring_{ident}[] __attribute__((used)) = '
      f'"{marker}";\n',
    "ring profile marker",
)

if marker not in text:
    raise SystemExit(f"ERROR: generated source missing marker {marker}")

path.write_text(text, encoding="utf-8")
print(f"P5 ring experiment applied: profile={profile} marker={marker}")
