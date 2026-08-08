#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: apply_p6_impairment.py PATH_TO_datapath_raw_dpdk.c")

path = Path(sys.argv[1])
src = path.read_text(encoding="utf-8")
marker = "GREENQUIC-P6-DETERMINISTIC-LOSS-V1"
if marker in src:
    print(f"{marker}: already applied")
    raise SystemExit(0)

# Insert after all GreenQUIC/DPDK types are defined, immediately before the TX
# poll implementation. This avoids forward-type ordering problems.
anchor = "static void\nGreenQuicOnTxPoll(\n"
insert = r'''
// GREENQUIC-P6-DETERMINISTIC-LOSS-V1
// P6-only deterministic server-download TX loss injector. This is intentionally
// outside the GreenQUIC policy: OFF/BASIC/PLUS all see the same impaired path.
// It runs after MsQuic has handed the datagram to the raw datapath, so a dropped
// mbuf is perceived by QUIC as real network loss and naturally exercises CUBIC
// recovery and the existing CUBIC_CWND_BLOCKED / CUBIC_RECOVERY hints.
//
// Environment variables:
//   GQ_P6_DROP_EVERY_N      0 disables; otherwise drop every Nth eligible mbuf.
//   GQ_P6_DROP_START_AFTER  do not drop the first N eligible mbufs (handshake guard).
// Defaults are disabled; the P6 run command enables them explicitly.
static BOOLEAN GreenQuicP6LossInitialized = FALSE;
static uint64_t GreenQuicP6DropEveryN = 0;
static uint64_t GreenQuicP6DropStartAfter = 10000;
static uint64_t GreenQuicP6TxEligible = 0;
static uint64_t GreenQuicP6TxDropped = 0;

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
    printf("GreenQUIC P6 impairment: marker=%s drop_every_n=%" PRIu64 " start_after=%" PRIu64 "\n",
        "GREENQUIC-P6-DETERMINISTIC-LOSS-V1",
        GreenQuicP6DropEveryN,
        GreenQuicP6DropStartAfter);
}

static BOOLEAN
GreenQuicP6ShouldDropTx(
    _In_ DPDK_DATAPATH* Dpdk
    )
{
    GreenQuicP6InitLoss();
    if (GreenQuicP6DropEveryN == 0 ||
        Dpdk->GreenQuicProfile != GREENQUIC_PROFILE_SERVER_DOWNLOAD) {
        return FALSE;
    }
    const uint64_t Index = ++GreenQuicP6TxEligible;
    if (Index <= GreenQuicP6DropStartAfter) {
        return FALSE;
    }
    return ((Index - GreenQuicP6DropStartAfter) % GreenQuicP6DropEveryN) == 0;
}

'''

if src.count(anchor) != 1:
    raise SystemExit(f"ERROR: expected one TX poll definition anchor, found {src.count(anchor)}")
src = src.replace(anchor, insert + anchor, 1)

old = '''    const uint16_t TxCount = rte_eth_tx_burst(Interface->Port, 0, Buffers, BufferCount);\n    GreenQuicOnTxPoll(Dpdk, Core, RingBefore, BufferCount, TxCount);\n    if (unlikely(TxCount < BufferCount)) {\n        for (uint16_t buf = TxCount; buf < BufferCount; buf++) {\n            rte_pktmbuf_free(Buffers[buf]);\n        }\n'''
new = '''    // GREENQUIC-P6-DETERMINISTIC-LOSS-V1: compact the burst after\n    // deterministic P6-only drops. MsQuic has already committed these packets\n    // to congestion control, therefore CUBIC observes genuine loss/recovery.\n    uint16_t P6SendCount = 0;\n    for (uint16_t buf = 0; buf < BufferCount; ++buf) {\n        if (GreenQuicP6ShouldDropTx(Dpdk)) {\n            rte_pktmbuf_free(Buffers[buf]);\n            ++GreenQuicP6TxDropped;\n            if (GreenQuicP6TxDropped <= 5 || (GreenQuicP6TxDropped % 100) == 0) {\n                printf("GreenQUIC P6 drop: eligible=%" PRIu64 " dropped=%" PRIu64 "\\n",\n                    GreenQuicP6TxEligible, GreenQuicP6TxDropped);\n            }\n        } else {\n            Buffers[P6SendCount++] = Buffers[buf];\n        }\n    }\n\n    const uint16_t TxCount = P6SendCount == 0 ? 0 :\n        rte_eth_tx_burst(Interface->Port, 0, Buffers, P6SendCount);\n    GreenQuicOnTxPoll(Dpdk, Core, RingBefore, BufferCount, TxCount);\n    if (unlikely(TxCount < P6SendCount)) {\n        for (uint16_t buf = TxCount; buf < P6SendCount; buf++) {\n            rte_pktmbuf_free(Buffers[buf]);\n        }\n'''

if src.count(old) != 1:
    raise SystemExit(f"ERROR: expected one rte_eth_tx_burst block, found {src.count(old)}")
src = src.replace(old, new, 1)
path.write_text(src, encoding="utf-8")
print(f"Applied {marker} to {path}")
