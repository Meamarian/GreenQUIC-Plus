#!/usr/bin/env python3
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
marker = "GREENQUIC-V22-FINAL-IDLE-COUNTERS-V1"
if marker in text:
    raise SystemExit(0)

def once(old, new, label):
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"ERROR: {label}: expected 1 old block, found {count}")
    text = text.replace(old, new, 1)

once(
    "static void GreenQuicIdleCleanupLcore(_Inout_ GREENQUIC_LCORE_STATE* S);",
    """static void GreenQuicIdleCleanupLcore(
    _In_ const DPDK_DATAPATH* Dpdk,
    _Inout_ GREENQUIC_LCORE_STATE* S,
    _In_ uint16_t Core);""",
    "cleanup declaration",
)
once(
    """GreenQuicIdleCleanupLcore(
    _Inout_ GREENQUIC_LCORE_STATE* S
    )
{""",
    """GreenQuicIdleCleanupLcore(
    _In_ const DPDK_DATAPATH* Dpdk,
    _Inout_ GREENQUIC_LCORE_STATE* S,
    _In_ uint16_t Core
    )
{
    /* GREENQUIC-V22-FINAL-IDLE-COUNTERS-V1: P5 isolated build. */
    printf(
        "[CPU %u] GreenQUIC FINAL idle_mode=%s "
        "monitor_try=%" PRIu64 " monitor_wake=%" PRIu64
        " monitor_timeout=%" PRIu64 " "
        "epoll_try=%" PRIu64 " epoll_wake=%" PRIu64
        " epoll_timeout=%" PRIu64 " wake_signal=%" PRIu64 "\\n",
        Core,
        GreenQuicIdleModeToString(Dpdk->GreenQuicIdleMode),
        S->MonitorAttempts,
        S->MonitorWakeups,
        S->MonitorTimeouts,
        S->EpollAttempts,
        S->EpollWakeups,
        S->EpollTimeouts,
        S->WakeSignals);
    fflush(stdout);""",
    "cleanup definition",
)
old_call = "GreenQuicIdleCleanupLcore(GreenQuicGetLcoreState(Dpdk, Core));"
count = text.count(old_call)
if count < 1:
    raise SystemExit("ERROR: no GreenQuicIdleCleanupLcore call sites found")
text = text.replace(
    old_call,
    "GreenQuicIdleCleanupLcore(\n            Dpdk, GreenQuicGetLcoreState(Dpdk, Core), Core);",
)
path.write_text(text, encoding="utf-8")
print(f"P5 datapath fix applied to {path}; call_sites={count}")
