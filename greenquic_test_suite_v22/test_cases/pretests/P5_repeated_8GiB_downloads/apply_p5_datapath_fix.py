#!/usr/bin/env python3
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

IDLE_MARKER = "GREENQUIC-V22-FINAL-IDLE-COUNTERS-V1"
PACKET_MARKER = "GREENQUIC-P5-DATAPATH-PACKET-TOTALS-V1"
EPOLL_FD_MARKER = "GREENQUIC-P5-EPOLL-FD-INIT-FIX-V1"
DVFS_RECORD_MARKER = "GREENQUIC-DVFS-RECORD-LOG0-V1"


def once(old, new, label):
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"ERROR: {label}: expected 1 old block, found {count}")
    text = text.replace(old, new, 1)


if IDLE_MARKER not in text:
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
else:
    count = text.count("GreenQuicIdleCleanupLcore(")

# P5 EPOLL hotfix. The Linux datapath initializes EpollFd/WakeEventFd to -1,
# but a later CxPlatZeroMemory() clears the whole per-lcore state and changes
# them back to 0. An early TX wake can then write to fd 0 and permanently set
# EpollUnavailable before the first real EPOLL attempt. Keep this P5-local:
# restore the fd sentinels after the zeroing and never signal an eventfd until
# GreenQuicEnsureEpoll() has actually initialized it.
if EPOLL_FD_MARKER not in text:
    once(
        """    CxPlatZeroMemory(Dpdk->GreenQuicLcore, sizeof(Dpdk->GreenQuicLcore));
}""",
        """    CxPlatZeroMemory(Dpdk->GreenQuicLcore, sizeof(Dpdk->GreenQuicLcore));
    /* GREENQUIC-P5-EPOLL-FD-INIT-FIX-V1
     * CxPlatZeroMemory above resets the fd sentinels to 0. Restore -1 after
     * zeroing so an uninitialized lcore can never treat stdin as its eventfd.
     */
    for (uint32_t IdleCore = 0; IdleCore < RTE_MAX_LCORE; ++IdleCore) {
        Dpdk->GreenQuicLcore[IdleCore].EpollFd = -1;
        Dpdk->GreenQuicLcore[IdleCore].WakeEventFd = -1;
    }
}""",
        "P5 EPOLL fd sentinel initialization",
    )
    once(
        """    if (S->WakeEventFd >= 0) {
        const uint64_t One = 1U;""",
        """    if (S->EpollInitialized && S->WakeEventFd >= 0) {
        const uint64_t One = 1U;""",
        "P5 EPOLL wake-event guard",
    )

# Recording must remain independent from verbose GreenQUIC logging. The report
# finalizer phase-attributes successful DVFS changes from timestamped FREQ
# records. With GQ_LOG_LEVEL=0, retain only those sparse successful-change
# records when ENABLE_RECORD=1; all unchanged/error/debug FREQ output stays off.
if DVFS_RECORD_MARKER not in text:
    once(
        """    if (Dpdk->GreenQuicLogLevel == 0) {
        return;
    }
    const int BeforePrintable =""",
        """    /* GREENQUIC-DVFS-RECORD-LOG0-V1
     * ENABLE_RECORD is normalized by the P5/P6 harness to literal 0/1.
     * A successful DVFS change is sparse (typically tens per run), so keeping
     * only these lines provides exact MONOTONIC phase evidence without turning
     * verbose GreenQUIC logging back on.
     */
    if (Dpdk->GreenQuicLogLevel == 0) {
        const char* RecordEnabled = getenv("ENABLE_RECORD");
        if (RecordEnabled == NULL ||
            strcmp(RecordEnabled, "1") != 0 ||
            strcmp(Result, "changed") != 0) {
            return;
        }
    }
    const int BeforePrintable =""",
        "log-off DVFS measurement events",
    )

# P5-only process-end packet totals. RxCounter/TxCounter already exist and are
# updated by the datapath for every mode, including strict OFF. This adds only
# one teardown print and does not add any new RX/TX hot-path work.
if PACKET_MARKER not in text:
    once(
        """    rte_eal_mp_wait_lcore();

    char stats_path[1048];""",
        """    rte_eal_mp_wait_lcore();

    /* GREENQUIC-P5-DATAPATH-PACKET-TOTALS-V1
     * Existing datapath totals, emitted once after all workers stop.
     * This intentionally works for OFF/BASIC/PLUS without adding hot-path
     * instrumentation or changing strict-OFF packet processing.
     */
    printf(
        "[CPU %u] GreenQUIC PACKETS source=datapath_totals "
        "rx_pkts=%" PRIu64 " tx_pkts=%" PRIu64 "\\n",
        Dpdk->Cpu,
        Dpdk->RxCounter,
        Dpdk->TxCounter);
    fflush(stdout);

    char stats_path[1048];""",
        "P5 process-end datapath packet totals",
    )

# Guard against accidentally turning the C escape sequence "\\n" into a real
# line break inside a generated string literal.
required_c_strings = (
    r'" epoll_timeout=%" PRIu64 " wake_signal=%" PRIu64 "\n",',
    r'"rx_pkts=%" PRIu64 " tx_pkts=%" PRIu64 "\n",',
)
for expected in required_c_strings:
    if expected not in text:
        raise SystemExit(
            "ERROR: generated C telemetry string lost its escaped newline: "
            + expected
        )

path.write_text(text, encoding="utf-8")
print(
    f"P5 datapath fixes applied to {path}; "
    f"idle_marker={IDLE_MARKER in text} "
    f"packet_marker={PACKET_MARKER in text} "
    f"epoll_fd_marker={EPOLL_FD_MARKER in text} "
    f"dvfs_record_marker={DVFS_RECORD_MARKER in text}"
)
