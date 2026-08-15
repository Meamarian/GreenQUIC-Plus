#!/usr/bin/env python3
"""Add exactly one immediate retry for a partial DPDK TX burst.

This is an isolated feature experiment. It changes no GreenQUIC/GreenQUIC+
policy, no checksum behavior, no lock behavior, no counters, and no runtime
configuration. The caller is expected to apply the chosen static baseline first.
"""

from pathlib import Path
import sys

MARKER = "GREENQUIC-P5-TX-RETRY1-V1"

if len(sys.argv) != 2:
    raise SystemExit("usage: apply_p5_tx_retry_once.py datapath_raw_dpdk_linux.c")

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

if MARKER in text:
    raise SystemExit(f"ERROR: {MARKER} already present")

marker_anchor = "#include <rte_hexdump.h>\n"
if text.count(marker_anchor) != 1:
    raise SystemExit(
        f"ERROR: TX retry marker anchor expected once, found {text.count(marker_anchor)}"
    )
text = text.replace(
    marker_anchor,
    marker_anchor
    + '\nstatic const char GreenQuicP5TxRetry1Marker[] __attribute__((used)) = '
      '"GREENQUIC-P5-TX-RETRY1-V1";\n',
    1,
)

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

    /* GREENQUIC-P5-TX-RETRY1-V1: exactly one retry of an unsent TX tail. */
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

count = text.count(old)
if count != 1:
    raise SystemExit(f"ERROR: TX burst anchor expected once, found {count}")

text = text.replace(old, new, 1)
path.write_text(text, encoding="utf-8")

print(
    "P5 isolated feature: tx_retry_once=1; "
    "checksum=unchanged counters=off forced_lockfree=off runtime_hooks=none"
)
