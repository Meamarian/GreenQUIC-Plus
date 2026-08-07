#!/usr/bin/env bash
set -Eeuo pipefail

# GreenQUIC V22: idle/EPOLL + CPU/frequency logs + goodput + ACPI power trace
#                  + client download cleanup
#
# This is one ordinary, readable shell script.
# It contains no Base64, no encoded payload, no downloaded code, and no
# temporary component scripts. Every change is visible below as plain text.
#
# Usage:
#   ./greenquic_v22_log_goodput_patch.sh
#
# Optional custom paths:
#   ./greenquic_v22_log_goodput_patch.sh /path/to/msquic /path/to/test_suite

REPO="${1:-/root/mohsen/msquic}"
SUITE="${2:-/root/mohsen/greenquic_test_suite_v22}"

for process_name in quicinterop quicinteropserver; do
    if pgrep -x "$process_name" >/dev/null 2>&1; then
        echo "ERROR: $process_name is running. Stop client/server before patching." >&2
        pgrep -ax "$process_name" >&2 || true
        exit 1
    fi
done


# ============================================================================
# 1. EPOLL RX-interrupt support and idle diagnostics
# ============================================================================

SRC="$REPO/src/platform/datapath_raw_dpdk_linux.c"
BUILD="$REPO/build-greenquic"
DPDK="$REPO/deps/dpdk-install"
MARKER='GREENQUIC-V22-IDLE-HOTFIX-RX-INTR-DIAGNOSTICS'

if [[ ! -f "$SRC" ]]; then
    echo "ERROR: active split DPDK backend not found: $SRC" >&2
    exit 1
fi
if [[ ! -d "$BUILD" ]]; then
    echo "ERROR: build directory not found: $BUILD" >&2
    exit 1
fi

RUNNING=0
for PROC in quicinterop quicinteropserver; do
    if pgrep -x "$PROC" >/dev/null 2>&1; then
        echo "ERROR: $PROC is running. Stop the client/server before patching." >&2
        pgrep -ax "$PROC" >&2 || true
        RUNNING=1
    fi
done
(( RUNNING == 0 )) || exit 1

if grep -Fq "$MARKER" "$SRC"; then
    echo "Idle hotfix already present in $SRC"
else
    BACKUP="$SRC.before_idle_hotfix_$(date +%Y%m%d_%H%M%S)"
    cp -a "$SRC" "$BACKUP"
    echo "Backup: $BACKUP"

    python3 - "$SRC" <<'PY'
from __future__ import annotations

from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "GREENQUIC-V22-IDLE-HOTFIX-RX-INTR-DIAGNOSTICS"

required = [
    "GREENQUIC-V22-SPLIT-LINUX-DPDK-PORT",
    "GREENQUIC-V20-SELECTABLE-IDLE-MODES",
    "GreenQuicTryEpollWait",
    "GreenQuicTryMonitorWait",
    "GreenQuicConfigureRoles",
]
missing = [token for token in required if token not in text]
if missing:
    raise SystemExit(
        "ERROR: unsupported source shape; missing:\n  " + "\n  ".join(missing)
    )

# The diagnostics read rte_errno directly; include its public declaration.
if "#include <rte_errno.h>" not in text:
    include_anchor = "#include <rte_power.h>\n"
    if include_anchor not in text:
        raise SystemExit("ERROR: rte_power.h include anchor not found")
    text = text.replace(
        include_anchor,
        include_anchor + "#include <rte_errno.h>\n",
        1,
    )


def function_span(source: str, name: str) -> tuple[int, int]:
    """Return a C function's full span, including nearby return/annotation lines."""
    match = re.search(rf"(?m)^[A-Za-z_][^;\n]*\n{name}\s*\(", source)
    if not match:
        # Most generated functions put the return type on the line above.
        match = re.search(rf"(?m)^{re.escape(name)}\s*\(", source)
    if not match:
        raise RuntimeError(f"function not found: {name}")

    brace = source.find("{", match.end())
    if brace < 0:
        raise RuntimeError(f"opening brace not found: {name}")

    depth = 0
    in_string = in_char = line_comment = block_comment = False
    escape = False
    i = brace
    while i < len(source):
        ch = source[i]
        nxt = source[i + 1] if i + 1 < len(source) else ""
        if line_comment:
            if ch == "\n":
                line_comment = False
            i += 1
            continue
        if block_comment:
            if ch == "*" and nxt == "/":
                block_comment = False
                i += 2
            else:
                i += 1
            continue
        if in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if in_char:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == "'":
                in_char = False
            i += 1
            continue
        if ch == "/" and nxt == "/":
            line_comment = True
            i += 2
            continue
        if ch == "/" and nxt == "*":
            block_comment = True
            i += 2
            continue
        if ch == '"':
            in_string = True
        elif ch == "'":
            in_char = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                while end < len(source) and source[end] in " \t\r\n":
                    end += 1

                line_start = source.rfind("\n", 0, match.start()) + 1
                start = line_start
                # Include generated annotations / return-type lines above.
                for _ in range(6):
                    prev_end = start - 1
                    if prev_end <= 0:
                        break
                    prev_start = source.rfind("\n", 0, prev_end) + 1
                    prev = source[prev_start:prev_end].strip()
                    if not prev:
                        break
                    if (
                        prev.startswith("_IRQL_")
                        or prev in {
                            "static", "void", "int", "size_t", "BOOLEAN",
                            "QUIC_STATUS", "CXPLAT_SEND_DATA*",
                        }
                        or prev.startswith("static ")
                    ):
                        start = prev_start
                    else:
                        break
                return start, end
        i += 1
    raise RuntimeError(f"closing brace not found: {name}")


def replace_function(source: str, name: str, replacement: str) -> str:
    start, end = function_span(source, name)
    return source[:start] + replacement.rstrip() + "\n\n" + source[end:]


# 1) Configure Rx queue interrupts before rte_eth_dev_configure(), exactly as
#    required by DPDK's interrupt mode. This is limited to EPOLL/AUTO and does
#    not change OFF/SHORT/PAUSE/MONITOR behavior.
role_start, role_end = function_span(text, "GreenQuicConfigureRoles")
role = text[role_start:role_end]
role_anchor = "    GreenQuicInstallDefaultPartitionDpdkMap(Dpdk);\n"
if role_anchor not in role:
    raise SystemExit("ERROR: role configuration anchor not found")
role_insert = r'''    // GREENQUIC-V22-IDLE-HOTFIX-RX-INTR-DIAGNOSTICS
    // DPDK requires dev_conf.intr_conf.rxq before rte_eth_dev_configure().
    // Merely calling rte_eth_dev_rx_intr_enable() later is not sufficient.
    const BOOLEAN NeedRxQueueInterrupts =
        Dpdk->GreenQuicEnableRx &&
        (Dpdk->GreenQuicIdleMode == GREENQUIC_IDLE_EPOLL ||
         Dpdk->GreenQuicIdleMode == GREENQUIC_IDLE_AUTO);
    if (NeedRxQueueInterrupts) {
        PortConfig->intr_conf.rxq = 1;
        printf(
            "GreenQUIC idle: requesting DPDK RX-queue interrupts before "
            "port configuration (mode=%s, rx_queues=%hu).\n",
            GreenQuicIdleModeToString(Dpdk->GreenQuicIdleMode),
            *RxRings);
    }

'''
role = role.replace(role_anchor, role_insert + role_anchor, 1)
text = text[:role_start] + role + text[role_end:]

# 2) Print the effective idle configuration and platform capability once.
init_support = r'''// GREENQUIC-V19-SAFE-CSTATE-IDLE
static void
GreenQuicInitCStateSupport(
    _Inout_ DPDK_DATAPATH* Dpdk
    )
{
    Dpdk->GreenQuicCStatePowerPauseSupported = FALSE;
    Dpdk->GreenQuicPowerMonitorSupported = FALSE;
#if GREENQUIC_HAVE_POWER_PAUSE_API || GREENQUIC_HAVE_POWER_MONITOR_API
    struct rte_cpu_intrinsics Intrinsics = {0};
    rte_cpu_get_intrinsics_support(&Intrinsics);
#if GREENQUIC_HAVE_POWER_PAUSE_API
    Dpdk->GreenQuicCStatePowerPauseSupported =
        Intrinsics.power_pause ? TRUE : FALSE;
#endif
#if GREENQUIC_HAVE_POWER_MONITOR_API
    Dpdk->GreenQuicPowerMonitorSupported =
        Intrinsics.power_monitor ? TRUE : FALSE;
#endif
#endif
    // Preserve the old V19 enable knob as a compatibility alias for pause mode.
    if (Dpdk->GreenQuicIdleMode == GREENQUIC_IDLE_PAUSE) {
        Dpdk->GreenQuicEnableCStateIdle = TRUE;
    }
    if (Dpdk->GreenQuicIdleMode == GREENQUIC_IDLE_PAUSE &&
        !Dpdk->GreenQuicCStatePowerPauseSupported) {
        printf(
            "GreenQUIC idle: pause requested, but rte_power_pause is not "
            "supported; fallback=%u.\n",
            (unsigned)Dpdk->GreenQuicIdleFallback);
    }
    if (Dpdk->GreenQuicIdleMode == GREENQUIC_IDLE_MONITOR &&
        !Dpdk->GreenQuicPowerMonitorSupported) {
        printf(
            "GreenQUIC idle: monitor requested, but rte_power_monitor is not "
            "supported; fallback=%u.\n",
            (unsigned)Dpdk->GreenQuicIdleFallback);
    }

    printf(
        "GreenQUIC idle config: mode=%s fallback=%u sleep=%u freq=%u "
        "work_wait_min_idle_us=%u work_wait_min_level=%u watchdog_us=%u "
        "allow_active_transfer=%u pause_supported=%u monitor_supported=%u "
        "rx_interrupt_config_requested=%u.\n",
        GreenQuicIdleModeToString(Dpdk->GreenQuicIdleMode),
        (unsigned)Dpdk->GreenQuicIdleFallback,
        Dpdk->GreenQuicEnableSleep ? 1U : 0U,
        Dpdk->GreenQuicEnableFreq ? 1U : 0U,
        Dpdk->GreenQuicWorkWaitMinIdleUs,
        Dpdk->GreenQuicWorkWaitMinLevel,
        Dpdk->GreenQuicIdleWatchdogUs,
        Dpdk->GreenQuicAllowWorkWaitDuringActiveTransfer ? 1U : 0U,
        Dpdk->GreenQuicCStatePowerPauseSupported ? 1U : 0U,
        Dpdk->GreenQuicPowerMonitorSupported ? 1U : 0U,
        Dpdk->GreenQuicEnableRx &&
            (Dpdk->GreenQuicIdleMode == GREENQUIC_IDLE_EPOLL ||
             Dpdk->GreenQuicIdleMode == GREENQUIC_IDLE_AUTO) ? 1U : 0U);
}
'''
text = replace_function(text, "GreenQuicInitCStateSupport", init_support)

# 3) Monitor mode: count an eligible attempt before PMD setup and expose the
#    exact PMD/intrinsic failure instead of silently falling back.
monitor_wait = r'''static BOOLEAN
GreenQuicTryMonitorWait(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_ DPDK_INTERFACE* Interface,
    _Inout_ GREENQUIC_LCORE_STATE* S,
    _In_ uint16_t Core,
    _In_ uint64_t IdleUs,
    _In_ BOOLEAN OwnsRx,
    _In_ BOOLEAN OwnsTx
    )
{
#if GREENQUIC_HAVE_POWER_MONITOR_API
    if (!Dpdk->GreenQuicPowerMonitorSupported || S->MonitorUnavailable || !OwnsRx ||
        !GreenQuicCanEnterWorkWait(Dpdk, Interface, S, Core, IdleUs, OwnsRx, OwnsTx)) {
        return FALSE;
    }

    ++S->MonitorAttempts;
    const uint64_t Sequence = __atomic_load_n(&S->WakeSequence, __ATOMIC_ACQUIRE);
    struct rte_power_monitor_cond Cond;
    CxPlatZeroMemory(&Cond, sizeof(Cond));
    const uint16_t QueueId = GreenQuicGetQueueId(Dpdk, Core);
    const int AddressRet =
        rte_eth_get_monitor_addr(Interface->Port, QueueId, &Cond);
    if (AddressRet != 0) {
        fprintf(
            stderr,
            "GreenQUIC monitor unavailable: lcore=%u port=%hu queue=%hu "
            "rte_eth_get_monitor_addr ret=%d (%s). Falling back.\n",
            Core,
            Interface->Port,
            QueueId,
            AddressRet,
            AddressRet < 0 ? rte_strerror(-AddressRet) : "unknown error");
        S->MonitorUnavailable = TRUE;
        return FALSE;
    }

    // Recheck after obtaining the PMD condition. If software work was published,
    // do not enter the monitor; if it arrives after entry, wakeup(Core) wakes us.
    rte_smp_rmb();
    if (__atomic_load_n(&S->WakeSequence, __ATOMIC_ACQUIRE) != Sequence ||
        !GreenQuicCanEnterWorkWait(Dpdk, Interface, S, Core, IdleUs, OwnsRx, OwnsTx)) {
        return FALSE;
    }

    const uint64_t Start = rte_get_tsc_cycles();
    const int Ret = rte_power_monitor(&Cond, GreenQuicWatchdogDeadline(Dpdk));
    const uint64_t ElapsedUs = GreenQuicTscDeltaToUs(rte_get_tsc_cycles() - Start);
    if (Ret == 0) {
        ++S->MonitorWakeups;
        if (ElapsedUs + 2U >= Dpdk->GreenQuicIdleWatchdogUs) {
            ++S->MonitorTimeouts;
        }
        return TRUE;
    }
    if (Ret == -ENOTSUP || Ret == -EINVAL) {
        fprintf(
            stderr,
            "GreenQUIC monitor disabled: lcore=%u rte_power_monitor ret=%d "
            "(%s). Falling back.\n",
            Core,
            Ret,
            rte_strerror(-Ret));
        S->MonitorUnavailable = TRUE;
    }
#else
    (void)Dpdk; (void)Interface; (void)S; (void)Core;
    (void)IdleUs; (void)OwnsRx; (void)OwnsTx;
#endif
    return FALSE;
}
'''
text = replace_function(text, "GreenQuicTryMonitorWait", monitor_wait)

# 4) Epoll setup: clean partial descriptors and print the exact Linux failure.
epoll_ensure = r'''static BOOLEAN
GreenQuicEnsureEpoll(
    _Inout_ GREENQUIC_LCORE_STATE* S,
    _In_ uint16_t Core
    )
{
#if GREENQUIC_HAVE_EPOLL_IDLE
    if (S->EpollInitialized) {
        return !S->EpollUnavailable;
    }

    S->EpollFd = epoll_create1(EPOLL_CLOEXEC);
    if (S->EpollFd < 0) {
        const int SavedErrno = errno;
        fprintf(
            stderr,
            "GreenQUIC epoll unavailable: lcore=%u epoll_create1 failed: "
            "errno=%d (%s). Falling back.\n",
            Core,
            SavedErrno,
            strerror(SavedErrno));
        S->EpollUnavailable = TRUE;
        return FALSE;
    }

    S->WakeEventFd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    if (S->WakeEventFd < 0) {
        const int SavedErrno = errno;
        fprintf(
            stderr,
            "GreenQUIC epoll unavailable: lcore=%u eventfd failed: "
            "errno=%d (%s). Falling back.\n",
            Core,
            SavedErrno,
            strerror(SavedErrno));
        close(S->EpollFd);
        S->EpollFd = -1;
        S->EpollUnavailable = TRUE;
        return FALSE;
    }

    struct epoll_event Ev;
    CxPlatZeroMemory(&Ev, sizeof(Ev));
    Ev.events = EPOLLIN;
    Ev.data.u64 = UINT64_MAX;
    if (epoll_ctl(S->EpollFd, EPOLL_CTL_ADD, S->WakeEventFd, &Ev) != 0) {
        const int SavedErrno = errno;
        fprintf(
            stderr,
            "GreenQUIC epoll unavailable: lcore=%u eventfd epoll_ctl failed: "
            "errno=%d (%s). Falling back.\n",
            Core,
            SavedErrno,
            strerror(SavedErrno));
        close(S->WakeEventFd);
        close(S->EpollFd);
        S->WakeEventFd = -1;
        S->EpollFd = -1;
        S->EpollUnavailable = TRUE;
        return FALSE;
    }

    S->EpollInitialized = TRUE;
    return TRUE;
#else
    (void)S;
    (void)Core;
    return FALSE;
#endif
}
'''
text = replace_function(text, "GreenQuicEnsureEpoll", epoll_ensure)

# 5) Epoll wait: expose get-fd/register/arm errors, count attempts before those
#    operations, and preserve the existing safe short fallback.
epoll_wait = r'''static BOOLEAN
GreenQuicTryEpollWait(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_ DPDK_INTERFACE* Interface,
    _Inout_ GREENQUIC_LCORE_STATE* S,
    _In_ uint16_t Core,
    _In_ uint64_t IdleUs,
    _In_ BOOLEAN OwnsRx,
    _In_ BOOLEAN OwnsTx
    )
{
#if GREENQUIC_HAVE_EPOLL_IDLE
    if (S->EpollUnavailable ||
        !GreenQuicCanEnterWorkWait(Dpdk, Interface, S, Core, IdleUs, OwnsRx, OwnsTx)) {
        return FALSE;
    }

    ++S->EpollAttempts;
    if (!GreenQuicEnsureEpoll(S, Core)) {
        return FALSE;
    }

    const uint64_t Sequence = __atomic_load_n(&S->WakeSequence, __ATOMIC_ACQUIRE);
    int RxFd = -1;
    const uint16_t QueueId = GreenQuicGetQueueId(Dpdk, Core);
    BOOLEAN RxInterruptArmed = FALSE;

    if (OwnsRx) {
        rte_errno = 0;
        RxFd = rte_eth_dev_rx_intr_ctl_q_get_fd(Interface->Port, QueueId);
        if (RxFd < 0) {
            const int SavedRteErrno = rte_errno;
            fprintf(
                stderr,
                "GreenQUIC epoll unavailable: lcore=%u port=%hu queue=%hu "
                "rte_eth_dev_rx_intr_ctl_q_get_fd failed, rte_errno=%d (%s). "
                "The NIC/PMD/kernel driver may not expose a per-queue eventfd. "
                "Falling back.\n",
                Core,
                Interface->Port,
                QueueId,
                SavedRteErrno,
                SavedRteErrno != 0 ? rte_strerror(SavedRteErrno) : "not reported");
            S->EpollUnavailable = TRUE;
            return FALSE;
        }

        struct epoll_event RxEv;
        CxPlatZeroMemory(&RxEv, sizeof(RxEv));
        RxEv.events = EPOLLIN;
        RxEv.data.u64 = ((uint64_t)Interface->Port << 32) | QueueId;
        if (epoll_ctl(S->EpollFd, EPOLL_CTL_ADD, RxFd, &RxEv) != 0 &&
            errno != EEXIST) {
            const int SavedErrno = errno;
            fprintf(
                stderr,
                "GreenQUIC epoll unavailable: lcore=%u port=%hu queue=%hu "
                "RX-fd epoll_ctl failed: errno=%d (%s). Falling back.\n",
                Core,
                Interface->Port,
                QueueId,
                SavedErrno,
                strerror(SavedErrno));
            S->EpollUnavailable = TRUE;
            return FALSE;
        }

        const int EnableRet =
            rte_eth_dev_rx_intr_enable(Interface->Port, QueueId);
        if (EnableRet != 0) {
            fprintf(
                stderr,
                "GreenQUIC epoll unavailable: lcore=%u port=%hu queue=%hu "
                "rte_eth_dev_rx_intr_enable ret=%d (%s). Check PMD support and "
                "the bound kernel driver (VFIO generally provides the complete "
                "per-queue interrupt path). Falling back.\n",
                Core,
                Interface->Port,
                QueueId,
                EnableRet,
                EnableRet < 0 ? rte_strerror(-EnableRet) : "unknown error");
            S->EpollUnavailable = TRUE;
            return FALSE;
        }
        RxInterruptArmed = TRUE;
    }

    rte_smp_rmb();
    if (__atomic_load_n(&S->WakeSequence, __ATOMIC_ACQUIRE) != Sequence ||
        !GreenQuicCanEnterWorkWait(Dpdk, Interface, S, Core, IdleUs, OwnsRx, OwnsTx)) {
        if (RxInterruptArmed) {
            (void)rte_eth_dev_rx_intr_disable(Interface->Port, QueueId);
        }
        return FALSE;
    }

    struct epoll_event Events[32];
    const int TimeoutMs = Dpdk->GreenQuicIdleWatchdogUs == 0U ? -1 :
        (int)((Dpdk->GreenQuicIdleWatchdogUs + 999U) / 1000U);
    const int Count = epoll_wait(
        S->EpollFd,
        Events,
        (int)Dpdk->GreenQuicEpollMaxEvents,
        TimeoutMs);
    const int WaitErrno = Count < 0 ? errno : 0;

    if (RxInterruptArmed) {
        const int DisableRet =
            rte_eth_dev_rx_intr_disable(Interface->Port, QueueId);
        if (DisableRet != 0) {
            fprintf(
                stderr,
                "GreenQUIC epoll warning: lcore=%u port=%hu queue=%hu "
                "rte_eth_dev_rx_intr_disable ret=%d (%s); disabling epoll mode "
                "for this lcore.\n",
                Core,
                Interface->Port,
                QueueId,
                DisableRet,
                DisableRet < 0 ? rte_strerror(-DisableRet) : "unknown error");
            S->EpollUnavailable = TRUE;
        }
    }

    uint64_t Drain;
    while (read(S->WakeEventFd, &Drain, sizeof(Drain)) == sizeof(Drain)) { }

    if (Count == 0) {
        ++S->EpollTimeouts;
        return TRUE;
    }
    if (Count > 0) {
        ++S->EpollWakeups;
        return TRUE;
    }
    if (WaitErrno == EINTR) {
        // A signal is a wake-up condition; repoll instead of taking another sleep.
        return TRUE;
    }

    fprintf(
        stderr,
        "GreenQUIC epoll disabled: lcore=%u epoll_wait errno=%d (%s). "
        "Falling back.\n",
        Core,
        WaitErrno,
        strerror(WaitErrno));
    S->EpollUnavailable = TRUE;
#else
    (void)Dpdk; (void)Interface; (void)S; (void)Core;
    (void)IdleUs; (void)OwnsRx; (void)OwnsTx;
#endif
    return FALSE;
}
'''
text = replace_function(text, "GreenQuicTryEpollWait", epoll_wait)

# Update the one internal call to the new GreenQuicEnsureEpoll signature if an
# old copy remains elsewhere. The replacement function already has the right call.
text = text.replace(
    "GreenQuicEnsureEpoll(S)",
    "GreenQuicEnsureEpoll(S, Core)",
)

# Pause mode already has the correct bounded semantics. Add one-time runtime
# diagnostics on a platform rejection rather than silently switching fallback.
old_pause = r'''    if (Ret == -ENOTSUP || Ret == -EINVAL) {
        S->CStateUnavailable = TRUE;
    }
'''
new_pause = r'''    if (Ret == -ENOTSUP || Ret == -EINVAL) {
        fprintf(
            stderr,
            "GreenQUIC pause disabled: lcore=%u rte_power_pause ret=%d (%s). "
            "Falling back.\n",
            Core,
            Ret,
            rte_strerror(-Ret));
        S->CStateUnavailable = TRUE;
    }
'''
if old_pause not in text:
    raise SystemExit("ERROR: pause rejection anchor not found")
text = text.replace(old_pause, new_pause, 1)

# Marker close to the active split backend header for simple verification.
header_anchor = "// GREENQUIC-V22-SPLIT-LINUX-DPDK-PORT\n"
if header_anchor not in text:
    raise SystemExit("ERROR: split backend marker not found")
text = text.replace(
    header_anchor,
    header_anchor + "// GREENQUIC-V22-IDLE-HOTFIX-RX-INTR-DIAGNOSTICS\n",
    1,
)

path.write_text(text)
print(f"Patched {path}")
PY
fi

# Static source checks before compiling.
grep -nF "$MARKER" "$SRC"
grep -nF 'PortConfig->intr_conf.rxq = 1;' "$SRC"
grep -nF 'rte_eth_dev_rx_intr_ctl_q_get_fd failed' "$SRC"
grep -nF 'GreenQUIC idle config:' "$SRC"

export PKG_CONFIG_PATH="$DPDK/lib/pkgconfig:$DPDK/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LIBRARY_PATH="$DPDK/lib:$DPDK/lib/x86_64-linux-gnu${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LD_LIBRARY_PATH="$DPDK/lib:$DPDK/lib/x86_64-linux-gnu:$DPDK/lib/dpdk/pmds-22.0${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

if ! pkg-config --exists libdpdk; then
    echo "ERROR: libdpdk is not visible through PKG_CONFIG_PATH=$PKG_CONFIG_PATH" >&2
    exit 1
fi

echo "Building with DPDK $(pkg-config --modversion libdpdk)..."
cmake --build "$BUILD" \
    --target quicinteropserver quicinterop \
    -j"$(nproc)"

echo
echo "Built binaries:"
ls -lh \
    "$BUILD/bin/Release/quicinteropserver" \
    "$BUILD/bin/Release/quicinterop"

for BIN in \
    "$BUILD/bin/Release/quicinteropserver" \
    "$BUILD/bin/Release/quicinterop"; do
    if [[ "$BIN" -ot "$SRC" ]]; then
        echo "ERROR: $BIN is older than patched source" >&2
        exit 1
    fi
done

echo
echo "PASS: GreenQUIC V22 idle hotfix applied and rebuilt."
echo "Run EPOLL with logging enabled and verify:"
echo "  idle_mode=epoll action=epoll epoll_try>0 epoll_wake>0"
echo "If epoll is unavailable, the server now prints the exact failing API."

# ============================================================================
# 2. CPU-first frequency logs and complete V22 statistics fields
# ============================================================================

SRC="$REPO/src/platform/datapath_raw_dpdk_linux.c"
BUILD="$REPO/build-greenquic"
DPDK="$REPO/deps/dpdk-install"
MARKER='GREENQUIC-V22-CPU-FREQ-LOGGING-HOTFIX'

for required in "$SRC" "$BUILD" "$DPDK"; do
    [[ -e "$required" ]] || { echo "ERROR: missing $required" >&2; exit 1; }
done

for proc in quicinterop quicinteropserver; do
    if pgrep -x "$proc" >/dev/null 2>&1; then
        echo "ERROR: $proc is running. Stop the client/server before patching." >&2
        pgrep -ax "$proc" >&2 || true
        exit 1
    fi
done

if ! grep -Fq 'GREENQUIC-V22-IDLE-HOTFIX-RX-INTR-DIAGNOSTICS' "$SRC"; then
    echo "ERROR: apply_greenquic_v22_idle_hotfix.sh must be applied first." >&2
    exit 1
fi

if grep -Fq "$MARKER" "$SRC"; then
    echo "Source logging hotfix is already present."
else
    backup="$SRC.before_cpu_freq_logging_$(date +%Y%m%d_%H%M%S)"
    cp -a "$SRC" "$backup"
    echo "Source backup: $backup"

    python3 - "$SRC" <<'PY'
from __future__ import annotations

from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "GREENQUIC-V22-CPU-FREQ-LOGGING-HOTFIX"

required = [
    "GREENQUIC-V22-IDLE-HOTFIX-RX-INTR-DIAGNOSTICS",
    "GreenQuicPowerInit",
    "GreenQuicFreqMax",
    "GreenQuicFreqUpStep",
    "GreenQuicFreqDownStep",
    "GreenQuicFreqMin",
    "GreenQuicTryCStateIdle",
    "GreenQuicMaybePrintStats",
]
missing = [token for token in required if token not in text]
if missing:
    raise SystemExit("ERROR: unsupported source shape; missing:\n  " + "\n  ".join(missing))


def function_span(source: str, name: str) -> tuple[int, int]:
    match = re.search(rf"(?m)^[A-Za-z_][^;\n]*\n{name}\s*\(", source)
    if not match:
        match = re.search(rf"(?m)^{re.escape(name)}\s*\(", source)
    if not match:
        raise RuntimeError(f"function not found: {name}")
    brace = source.find("{", match.end())
    if brace < 0:
        raise RuntimeError(f"opening brace not found: {name}")

    depth = 0
    in_string = in_char = line_comment = block_comment = False
    escape = False
    i = brace
    while i < len(source):
        ch = source[i]
        nxt = source[i + 1] if i + 1 < len(source) else ""
        if line_comment:
            if ch == "\n":
                line_comment = False
            i += 1
            continue
        if block_comment:
            if ch == "*" and nxt == "/":
                block_comment = False
                i += 2
            else:
                i += 1
            continue
        if in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if in_char:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == "'":
                in_char = False
            i += 1
            continue
        if ch == "/" and nxt == "/":
            line_comment = True
            i += 2
            continue
        if ch == "/" and nxt == "*":
            block_comment = True
            i += 2
            continue
        if ch == '"':
            in_string = True
        elif ch == "'":
            in_char = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                while end < len(source) and source[end] in " \t\r\n":
                    end += 1
                start = source.rfind("\n", 0, match.start()) + 1
                for _ in range(8):
                    prev_end = start - 1
                    if prev_end <= 0:
                        break
                    prev_start = source.rfind("\n", 0, prev_end) + 1
                    prev = source[prev_start:prev_end].strip()
                    if not prev:
                        break
                    if (
                        prev.startswith("_IRQL_")
                        or prev in {"static", "void", "int", "size_t", "BOOLEAN", "QUIC_STATUS"}
                        or prev.startswith("static ")
                    ):
                        start = prev_start
                    else:
                        break
                return start, end
        i += 1
    raise RuntimeError(f"closing brace not found: {name}")


def replace_function(source: str, name: str, replacement: str) -> str:
    start, end = function_span(source, name)
    return source[:start] + replacement.rstrip() + "\n\n" + source[end:]


# Add real requested-versus-actual pause accounting. The old cstate_last_us and
# cstate_total_us remain for backward compatibility and continue to mean the
# successful requested duration.
struct_anchor = "    uint64_t TotalCStateWaitUs;\n    uint32_t LastCStateWaitUs;\n"
struct_add = struct_anchor + """    uint64_t TotalCStateRequestedUs;\n    uint32_t LastCStateRequestedUs;\n    uint64_t TotalCStateActualUs;\n    uint32_t LastCStateActualUs;\n"""
if "LastCStateRequestedUs" not in text:
    if struct_anchor not in text:
        raise SystemExit("ERROR: C-state state-field anchor not found")
    text = text.replace(struct_anchor, struct_add, 1)

pause_anchor = """    ++S->CStateAttempts;
    const int Ret = rte_power_pause(Deadline);
"""
pause_new = """    ++S->CStateAttempts;
    S->LastCStateRequestedUs = WaitUs;
    S->TotalCStateRequestedUs += WaitUs;
    const uint64_t PauseStartTsc = rte_get_tsc_cycles();
    const int Ret = rte_power_pause(Deadline);
    const uint64_t PauseActualUs64 =
        GreenQuicTscDeltaToUs(rte_get_tsc_cycles() - PauseStartTsc);
    S->LastCStateActualUs =
        PauseActualUs64 > UINT32_MAX ? UINT32_MAX : (uint32_t)PauseActualUs64;
    S->TotalCStateActualUs += PauseActualUs64;
"""
if "PauseActualUs64" not in text:
    if pause_anchor not in text:
        raise SystemExit("ERROR: rte_power_pause accounting anchor not found")
    text = text.replace(pause_anchor, pause_new, 1)

# Frequency helpers. DPDK returns 1 when a frequency API changed the selected
# index, 0 when the request succeeded but did not change it, and a negative value
# on error. Index/KHz are sampled before and after when the active backend exposes
# rte_power_get_freq()/rte_power_freqs().
power_init_start, _ = function_span(text, "GreenQuicPowerInit")
helper_code = r'''// GREENQUIC-V22-CPU-FREQ-LOGGING-HOTFIX
#define GREENQUIC_FREQ_UNKNOWN_INDEX UINT32_MAX
#define GREENQUIC_FREQ_LIST_CAPACITY 128U

static uint32_t
GreenQuicReadFreqIndex(
    _In_ uint16_t Core
    )
{
    if (rte_power_get_freq == NULL) {
        return GREENQUIC_FREQ_UNKNOWN_INDEX;
    }
    return rte_power_get_freq(Core);
}

static uint32_t
GreenQuicReadFreqKHz(
    _In_ uint16_t Core,
    _In_ uint32_t Index
    )
{
    if (Index == GREENQUIC_FREQ_UNKNOWN_INDEX || rte_power_freqs == NULL) {
        return 0U;
    }
    uint32_t Frequencies[GREENQUIC_FREQ_LIST_CAPACITY];
    const uint32_t Count = rte_power_freqs(
        Core, Frequencies, GREENQUIC_FREQ_LIST_CAPACITY);
    return Index < Count ? Frequencies[Index] : 0U;
}

static void
GreenQuicPrintFreqEvent(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ const GREENQUIC_LCORE_STATE* S,
    _In_ uint16_t Core,
    _In_z_ const char* Api,
    _In_z_ const char* Result,
    _In_ int Ret,
    _In_ uint32_t BeforeIndex,
    _In_ uint32_t AfterIndex,
    _In_ uint64_t CooldownRemainingUs
    )
{
    if (Dpdk->GreenQuicLogLevel == 0) {
        return;
    }
    const int BeforePrintable =
        BeforeIndex == GREENQUIC_FREQ_UNKNOWN_INDEX ? -1 : (int)BeforeIndex;
    const int AfterPrintable =
        AfterIndex == GREENQUIC_FREQ_UNKNOWN_INDEX ? -1 : (int)AfterIndex;
    const uint32_t BeforeKHz = GreenQuicReadFreqKHz(Core, BeforeIndex);
    const uint32_t AfterKHz = GreenQuicReadFreqKHz(Core, AfterIndex);
    const char* ErrorText = Ret < 0 ? rte_strerror(-Ret) : "-";

    flockfile(stdout);
    printf(
        "[CPU %u] GreenQUIC FREQ policy_action=%s api=%s result=%s ret=%d "
        "before_index=%d after_index=%d before_khz=%u after_khz=%u "
        "cooldown_remaining_us=%" PRIu64 " error=%s\n\n",
        Core,
        S->LastAction != NULL ? S->LastAction : "none",
        Api,
        Result,
        Ret,
        BeforePrintable,
        AfterPrintable,
        BeforeKHz,
        AfterKHz,
        CooldownRemainingUs,
        ErrorText);
    fflush(stdout);
    funlockfile(stdout);
}

'''
if marker not in text:
    text = text[:power_init_start] + helper_code + text[power_init_start:]

power_init = r'''static void
GreenQuicPowerInit(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_ uint16_t Core
    )
{
    GREENQUIC_LCORE_STATE* S = GreenQuicGetLcoreState(Dpdk, Core);
    if (Dpdk->GreenQuicMode == GREENQUIC_MODE_OFF ||
        !Dpdk->GreenQuicEnableFreq || S->PowerInitialized) {
        return;
    }

    S->PowerInitialized = TRUE;
    const int InitRet = rte_power_init(Core);
    if (InitRet == 0) {
        S->PowerAvailable = TRUE;
        const uint32_t BeforeIndex = GreenQuicReadFreqIndex(Core);
        const int Ret = rte_power_freq_max(Core);
        const uint32_t AfterIndex = GreenQuicReadFreqIndex(Core);
        if (Ret >= 0) {
            S->FreqIsMax = TRUE;
            S->LastFreqMaxTsc = rte_get_tsc_cycles();
        } else {
            S->PowerAvailable = FALSE;
            S->FreqIsMax = FALSE;
        }
        GreenQuicPrintFreqEvent(
            Dpdk,
            S,
            Core,
            "init_then_max",
            Ret > 0 ? "changed" : (Ret == 0 ? "unchanged" : "error"),
            Ret,
            BeforeIndex,
            AfterIndex,
            0U);
    } else {
        S->PowerAvailable = FALSE;
        S->FreqIsMax = FALSE;
        if (Dpdk->GreenQuicLogLevel != 0) {
            flockfile(stderr);
            fprintf(
                stderr,
                "[CPU %u] GreenQUIC FREQ api=init result=error ret=%d "
                "error=%s scaling_disabled=1\n\n",
                Core,
                InitRet,
                InitRet < 0 ? rte_strerror(-InitRet) : "unknown");
            fflush(stderr);
            funlockfile(stderr);
        }
    }
}
'''
text = replace_function(text, "GreenQuicPowerInit", power_init)

power_cleanup = r'''static void
GreenQuicPowerCleanup(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_ uint16_t Core
    )
{
    GREENQUIC_LCORE_STATE* S = GreenQuicGetLcoreState(Dpdk, Core);

    if (S->PowerInitialized && S->PowerAvailable) {
        const uint32_t BeforeIndex = GreenQuicReadFreqIndex(Core);
        const int MaxRet = rte_power_freq_max(Core);
        const uint32_t AfterIndex = GreenQuicReadFreqIndex(Core);
        if (Dpdk->GreenQuicLogLevel >= 2) {
            GreenQuicPrintFreqEvent(
                Dpdk,
                S,
                Core,
                "cleanup_max",
                MaxRet > 0 ? "changed" : (MaxRet == 0 ? "unchanged" : "error"),
                MaxRet,
                BeforeIndex,
                AfterIndex,
                0U);
        }
        (void)rte_power_exit(Core);
    }

    S->PowerInitialized = FALSE;
    S->PowerAvailable = FALSE;
    S->FreqIsMax = FALSE;
}
'''
text = replace_function(text, "GreenQuicPowerCleanup", power_cleanup)

freq_max = r'''static void
GreenQuicFreqMax(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_ uint16_t Core
    )
{
    GREENQUIC_LCORE_STATE* S = GreenQuicGetLcoreState(Dpdk, Core);
    if (!Dpdk->GreenQuicEnableFreq) {
        if (Dpdk->GreenQuicLogLevel >= 2) {
            GreenQuicPrintFreqEvent(
                Dpdk, S, Core, "freq_max", "skipped_disabled", 0,
                GREENQUIC_FREQ_UNKNOWN_INDEX,
                GREENQUIC_FREQ_UNKNOWN_INDEX,
                0U);
        }
        return;
    }
    if (!S->PowerAvailable) {
        if (Dpdk->GreenQuicLogLevel >= 2) {
            GreenQuicPrintFreqEvent(
                Dpdk, S, Core, "freq_max", "skipped_unavailable", 0,
                GREENQUIC_FREQ_UNKNOWN_INDEX,
                GREENQUIC_FREQ_UNKNOWN_INDEX,
                0U);
        }
        return;
    }
    if (S->FreqIsMax) {
        if (Dpdk->GreenQuicLogLevel >= 2) {
            const uint32_t Index = GreenQuicReadFreqIndex(Core);
            GreenQuicPrintFreqEvent(
                Dpdk, S, Core, "freq_max", "skipped_already_max", 0,
                Index, Index, 0U);
        }
        return;
    }

    const uint32_t BeforeIndex = GreenQuicReadFreqIndex(Core);
    const int Ret = rte_power_freq_max(Core);
    const uint32_t AfterIndex = GreenQuicReadFreqIndex(Core);
    if (Ret >= 0) {
        S->FreqIsMax = TRUE;
        S->LastFreqMaxTsc = rte_get_tsc_cycles();
    } else {
        S->PowerAvailable = FALSE;
    }
    if (Ret != 0 || Dpdk->GreenQuicLogLevel >= 2) {
        GreenQuicPrintFreqEvent(
            Dpdk,
            S,
            Core,
            "freq_max",
            Ret > 0 ? "changed" : (Ret == 0 ? "unchanged" : "error"),
            Ret,
            BeforeIndex,
            AfterIndex,
            0U);
    }
}
'''
text = replace_function(text, "GreenQuicFreqMax", freq_max)

freq_up = r'''static void
GreenQuicFreqUpStep(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_ uint16_t Core
    )
{
    GREENQUIC_LCORE_STATE* S = GreenQuicGetLcoreState(Dpdk, Core);
    if (!Dpdk->GreenQuicEnableFreq || !S->PowerAvailable || S->FreqIsMax) {
        if (Dpdk->GreenQuicLogLevel >= 2) {
            const char* Result = !Dpdk->GreenQuicEnableFreq ?
                "skipped_disabled" : (!S->PowerAvailable ?
                "skipped_unavailable" : "skipped_already_max");
            const uint32_t Index = S->PowerAvailable ?
                GreenQuicReadFreqIndex(Core) : GREENQUIC_FREQ_UNKNOWN_INDEX;
            GreenQuicPrintFreqEvent(
                Dpdk, S, Core, "freq_up", Result, 0, Index, Index, 0U);
        }
        return;
    }

    const uint64_t Now = rte_get_tsc_cycles();
    if (S->LastFreqUpTsc != 0) {
        const uint64_t ElapsedUs =
            GreenQuicTscDeltaToUs(Now - S->LastFreqUpTsc);
        if (ElapsedUs < Dpdk->GreenQuicFreqUpPeriodUs) {
            if (Dpdk->GreenQuicLogLevel >= 2) {
                const uint32_t Index = GreenQuicReadFreqIndex(Core);
                GreenQuicPrintFreqEvent(
                    Dpdk,
                    S,
                    Core,
                    "freq_up",
                    "skipped_cooldown",
                    0,
                    Index,
                    Index,
                    Dpdk->GreenQuicFreqUpPeriodUs - ElapsedUs);
            }
            return;
        }
    }

    const uint32_t BeforeIndex = GreenQuicReadFreqIndex(Core);
    const int Ret = rte_power_freq_up(Core);
    const uint32_t AfterIndex = GreenQuicReadFreqIndex(Core);
    if (Ret >= 0) {
        S->LastFreqUpTsc = Now;
        S->FreqIsMax = FALSE;
    } else {
        S->PowerAvailable = FALSE;
    }
    if (Ret != 0 || Dpdk->GreenQuicLogLevel >= 2) {
        GreenQuicPrintFreqEvent(
            Dpdk,
            S,
            Core,
            "freq_up",
            Ret > 0 ? "changed" : (Ret == 0 ? "unchanged" : "error"),
            Ret,
            BeforeIndex,
            AfterIndex,
            0U);
    }
}
'''
text = replace_function(text, "GreenQuicFreqUpStep", freq_up)

freq_down = r'''static void
GreenQuicFreqDownStep(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_ uint16_t Core
    )
{
    GREENQUIC_LCORE_STATE* S = GreenQuicGetLcoreState(Dpdk, Core);
    if (!Dpdk->GreenQuicEnableFreq || !S->PowerAvailable) {
        if (Dpdk->GreenQuicLogLevel >= 2) {
            GreenQuicPrintFreqEvent(
                Dpdk,
                S,
                Core,
                "freq_down",
                !Dpdk->GreenQuicEnableFreq ? "skipped_disabled" : "skipped_unavailable",
                0,
                GREENQUIC_FREQ_UNKNOWN_INDEX,
                GREENQUIC_FREQ_UNKNOWN_INDEX,
                0U);
        }
        return;
    }

    const uint64_t Now = rte_get_tsc_cycles();
    if (S->LastFreqDownTsc != 0) {
        const uint64_t ElapsedUs =
            GreenQuicTscDeltaToUs(Now - S->LastFreqDownTsc);
        if (ElapsedUs < Dpdk->GreenQuicFreqDownPeriodUs) {
            if (Dpdk->GreenQuicLogLevel >= 2) {
                const uint32_t Index = GreenQuicReadFreqIndex(Core);
                GreenQuicPrintFreqEvent(
                    Dpdk,
                    S,
                    Core,
                    "freq_down",
                    "skipped_cooldown",
                    0,
                    Index,
                    Index,
                    Dpdk->GreenQuicFreqDownPeriodUs - ElapsedUs);
            }
            return;
        }
    }

    const uint32_t BeforeIndex = GreenQuicReadFreqIndex(Core);
    const int Ret = rte_power_freq_down(Core);
    const uint32_t AfterIndex = GreenQuicReadFreqIndex(Core);
    if (Ret >= 0) {
        S->FreqIsMax = FALSE;
        S->LastFreqDownTsc = Now;
    } else {
        S->PowerAvailable = FALSE;
    }
    if (Ret != 0 || Dpdk->GreenQuicLogLevel >= 2) {
        GreenQuicPrintFreqEvent(
            Dpdk,
            S,
            Core,
            "freq_down",
            Ret > 0 ? "changed" : (Ret == 0 ? "unchanged" : "error"),
            Ret,
            BeforeIndex,
            AfterIndex,
            0U);
    }
}
'''
text = replace_function(text, "GreenQuicFreqDownStep", freq_down)

freq_min = r'''static void
GreenQuicFreqMin(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_ uint16_t Core
    )
{
    GREENQUIC_LCORE_STATE* S = GreenQuicGetLcoreState(Dpdk, Core);
    if (!Dpdk->GreenQuicEnableFreq || !S->PowerAvailable) {
        if (Dpdk->GreenQuicLogLevel >= 2) {
            GreenQuicPrintFreqEvent(
                Dpdk,
                S,
                Core,
                "freq_min",
                !Dpdk->GreenQuicEnableFreq ? "skipped_disabled" : "skipped_unavailable",
                0,
                GREENQUIC_FREQ_UNKNOWN_INDEX,
                GREENQUIC_FREQ_UNKNOWN_INDEX,
                0U);
        }
        return;
    }

    const uint64_t Now = rte_get_tsc_cycles();
    if (S->LastFreqDownTsc != 0) {
        const uint64_t ElapsedUs =
            GreenQuicTscDeltaToUs(Now - S->LastFreqDownTsc);
        if (ElapsedUs < Dpdk->GreenQuicFreqDownPeriodUs) {
            if (Dpdk->GreenQuicLogLevel >= 2) {
                const uint32_t Index = GreenQuicReadFreqIndex(Core);
                GreenQuicPrintFreqEvent(
                    Dpdk,
                    S,
                    Core,
                    "freq_min",
                    "skipped_cooldown",
                    0,
                    Index,
                    Index,
                    Dpdk->GreenQuicFreqDownPeriodUs - ElapsedUs);
            }
            return;
        }
    }

    const uint32_t BeforeIndex = GreenQuicReadFreqIndex(Core);
    const int Ret = rte_power_freq_min(Core);
    const uint32_t AfterIndex = GreenQuicReadFreqIndex(Core);
    if (Ret >= 0) {
        S->FreqIsMax = FALSE;
        S->LastFreqDownTsc = Now;
    } else {
        S->PowerAvailable = FALSE;
    }
    if (Ret != 0 || Dpdk->GreenQuicLogLevel >= 2) {
        GreenQuicPrintFreqEvent(
            Dpdk,
            S,
            Core,
            "freq_min",
            Ret > 0 ? "changed" : (Ret == 0 ? "unchanged" : "error"),
            Ret,
            BeforeIndex,
            AfterIndex,
            0U);
    }
}
'''
text = replace_function(text, "GreenQuicFreqMin", freq_min)

stats = r'''static void
GreenQuicMaybePrintStats(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_ uint16_t Core
    )
{
    if (Dpdk->GreenQuicMode == GREENQUIC_MODE_OFF ||
        Dpdk->GreenQuicLogLevel == 0 ||
        Dpdk->GreenQuicStatsPeriodUs == 0) {
        return;
    }
    GREENQUIC_LCORE_STATE* S = GreenQuicGetLcoreState(Dpdk, Core);
    const uint64_t Now = rte_get_tsc_cycles();
    if (S->LastStatsTsc != 0 &&
        GreenQuicTscDeltaToUs(Now - S->LastStatsTsc) <
            Dpdk->GreenQuicStatsPeriodUs) {
        return;
    }
    S->LastStatsTsc = Now;

    const uint32_t FreqIndex = S->PowerAvailable ?
        GreenQuicReadFreqIndex(Core) : GREENQUIC_FREQ_UNKNOWN_INDEX;
    const int FreqIndexPrintable =
        FreqIndex == GREENQUIC_FREQ_UNKNOWN_INDEX ? -1 : (int)FreqIndex;
    const uint32_t FreqKHz = GreenQuicReadFreqKHz(Core, FreqIndex);

    flockfile(stdout);
    printf(
        "[CPU %u] GreenQUIC lcore=%u owns_rx=%u owns_tx=%u mode=%s profile=%s "
        "action=%s hardmax=%u rxhard=%u txhard=%u control=%u "
        "rxctrl=%u txctrl=%u rxphysctrl=%u txphysctrl=%u "
        "rxburstp=%u rxqueuep=%u txburstp=%u txringp=%u "
        "rxbursta=%u rxqueuea=%u txbursta=%u txringa=%u "
        "rxfloor=%u txfloor=%u rxh=0x%" PRIx64 " txh=0x%" PRIx64 " "
        "txring=%u rxq=%u rx_pkts=%" PRIu64 " tx_pkts=%" PRIu64 " "
        "rx_empty=%u tx_empty=%u rx_full=%u tx_full=%u slept_us=%" PRIu64 " "
        "cstate_attempt=%" PRIu64 " cstate_ok=%" PRIu64 " "
        "cstate_last_us=%u cstate_total_us=%" PRIu64 " "
        "cstate_req_last_us=%u cstate_req_total_us=%" PRIu64 " "
        "cstate_actual_last_us=%u cstate_actual_total_us=%" PRIu64 " "
        "idle_mode=%s monitor_try=%" PRIu64 " monitor_wake=%" PRIu64 " "
        "monitor_timeout=%" PRIu64 " epoll_try=%" PRIu64 " "
        "epoll_wake=%" PRIu64 " epoll_timeout=%" PRIu64 " "
        "wake_signal=%" PRIu64 " freq_available=%u freq_is_max=%u "
        "freq_index=%d freq_khz=%u\n\n",
        Core,
        Core,
        S->LastOwnsRx ? 1U : 0U,
        S->LastOwnsTx ? 1U : 0U,
        GreenQuicModeToString(Dpdk->GreenQuicMode),
        GreenQuicProfileToString(Dpdk->GreenQuicProfile),
        S->LastAction != NULL ? S->LastAction : "none",
        S->LastHardMax ? 1U : 0U,
        S->LastRxHardMax ? 1U : 0U,
        S->LastTxHardMax ? 1U : 0U,
        S->PressureAvg,
        S->LastRxControlPressure,
        S->LastTxControlPressure,
        S->LastRxPhysicalControl,
        S->LastTxPhysicalControl,
        S->LastRxBurstPressure,
        S->LastRxQueuePressure,
        S->LastTxBurstPressure,
        S->LastTxRingPressure,
        S->RxBurstPressureAvg,
        S->RxQueuePressureAvg,
        S->TxBurstPressureAvg,
        S->TxRingPressureAvg,
        S->LastRxQuicPressure,
        S->LastTxQuicPressure,
        S->LastRxHints,
        S->LastTxHints,
        S->LastTxRingCount,
        S->Rx.LastQueueCount,
        S->Rx.Packets,
        S->Tx.Packets,
        S->Rx.ConsecutiveEmpty,
        S->Tx.ConsecutiveEmpty,
        S->Rx.ConsecutiveFull,
        S->Tx.ConsecutiveFull,
        S->TotalSleepUs,
        S->CStateAttempts,
        S->CStateSuccesses,
        S->LastCStateWaitUs,
        S->TotalCStateWaitUs,
        S->LastCStateRequestedUs,
        S->TotalCStateRequestedUs,
        S->LastCStateActualUs,
        S->TotalCStateActualUs,
        GreenQuicIdleModeToString(Dpdk->GreenQuicIdleMode),
        S->MonitorAttempts,
        S->MonitorWakeups,
        S->MonitorTimeouts,
        S->EpollAttempts,
        S->EpollWakeups,
        S->EpollTimeouts,
        S->WakeSignals,
        S->PowerAvailable ? 1U : 0U,
        S->FreqIsMax ? 1U : 0U,
        FreqIndexPrintable,
        FreqKHz);
    fflush(stdout);
    funlockfile(stdout);
}
'''
text = replace_function(text, "GreenQuicMaybePrintStats", stats)

# Make the GreenQUIC-owned worker lines CPU-first and visually separated. EAL,
# PMD and DPDK POWER lines are external and are intentionally not rewritten.
worker_replacements = {
    '    printf("Core %u RX/TX worker running...\\n", Core);\n':
        '    printf("[CPU %u] GreenQUIC WORKER role=rx_tx state=running\\n\\n", Core);\n    fflush(stdout);\n',
    '    printf("Core %u worker running...\\n", Core);\n':
        '    printf("[CPU %u] GreenQUIC WORKER role=worker state=running\\n\\n", Core);\n    fflush(stdout);\n',
}
for old, new in worker_replacements.items():
    text = text.replace(old, new)

# Existing selectable-idle errors: put the CPU first and add a blank line. Keep
# placeholder counts unchanged.
text = text.replace(
    '"GreenQUIC: selected idle mode unsupported on lcore %u\\n"',
    '"[CPU %u] GreenQUIC IDLE result=unsupported strict_fail=1\\n\\n"')
for old, new in [
    ('"GreenQUIC monitor unavailable: lcore=%u', '"[CPU %u] GreenQUIC IDLE mode=monitor result=unavailable'),
    ('"GreenQUIC monitor disabled: lcore=%u', '"[CPU %u] GreenQUIC IDLE mode=monitor result=disabled'),
    ('"GreenQUIC pause disabled: lcore=%u', '"[CPU %u] GreenQUIC IDLE mode=pause result=disabled'),
    ('"GreenQUIC epoll unavailable: lcore=%u', '"[CPU %u] GreenQUIC IDLE mode=epoll result=unavailable'),
    ('"GreenQUIC epoll warning: lcore=%u', '"[CPU %u] GreenQUIC IDLE mode=epoll result=warning'),
    ('"GreenQUIC epoll disabled: lcore=%u', '"[CPU %u] GreenQUIC IDLE mode=epoll result=disabled'),
]:
    text = text.replace(old, new)

# Add a blank line to the endings used by the idle hotfix diagnostics.
for ending in [
    'Falling back.\\n"',
    'for this lcore.\\n"',
    'strict_fail=1\\n"',
]:
    text = text.replace(ending, ending[:-3] + '\\n\\n"')

header_anchor = "// GREENQUIC-V22-SPLIT-LINUX-DPDK-PORT\n"
if marker not in text:
    if header_anchor not in text:
        raise SystemExit("ERROR: V22 split-backend marker not found")
    text = text.replace(header_anchor, header_anchor + f"// {marker}\n", 1)

path.write_text(text)
print(f"Patched {path}")
PY
fi

# Patch only the V21/V22 log validator so a process interrupted during its final
# printf cannot create a false failure. Complete lines are still checked strictly.
VALIDATOR="$SUITE/common/bin/validate_v21_log.py"
PARSER="$SUITE/common/bin/parse_v21_stats.py"
if [[ -f "$VALIDATOR" ]]; then
    if ! grep -Fq 'GREENQUIC-V22-TRUNCATED-STATS-GUARD' "$VALIDATOR"; then
        cp -a "$VALIDATOR" "$VALIDATOR.before_logging_hotfix_$(date +%Y%m%d_%H%M%S)"
        python3 - "$VALIDATOR" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); t=p.read_text()
old="""    lines=[(n,t) for n,t in enumerate(raw,1) if t.startswith('GreenQUIC lcore=')]
    if not lines: print('ERROR: no final V21 GreenQUIC stats lines found',file=sys.stderr); return 2 if args.require_all else 0
    errors=[]; modes=set(); all_keys=set()
"""
new=r"""    # GREENQUIC-V22-TRUNCATED-STATS-GUARD
    candidates=[(n,t) for n,t in enumerate(raw,1) if t.startswith('GreenQUIC lcore=') or re.match(r'^\[CPU \d+\] GreenQUIC lcore=',t)]
    lines=[(n,t) for n,t in candidates if 'wake_signal=' in t]
    truncated=len(candidates)-len(lines)
    if not lines: print('ERROR: no complete final V21 GreenQUIC stats lines found',file=sys.stderr); return 2 if args.require_all else 0
    errors=[]; modes=set(); all_keys=set()
"""
if old not in t: raise SystemExit('ERROR: validator anchor not found')
t=t.replace(old,new,1)
old2="""    print(f"stats_lines={len(lines)}"); print('fields='+','.join(sorted(all_keys))); print('idle_modes='+','.join(sorted(modes)))
"""
new2="""    print(f"stats_lines={len(lines)}"); print(f"truncated_stats_lines_skipped={truncated}"); print('fields='+','.join(sorted(all_keys))); print('idle_modes='+','.join(sorted(modes)))
"""
if old2 not in t: raise SystemExit('ERROR: validator print anchor not found')
t=t.replace(old2,new2,1)
p.write_text(t)
PY
    fi
fi

if [[ -f "$PARSER" ]]; then
    if ! grep -Fq 'GREENQUIC-V22-TRUNCATED-STATS-GUARD' "$PARSER"; then
        cp -a "$PARSER" "$PARSER.before_logging_hotfix_$(date +%Y%m%d_%H%M%S)"
        python3 - "$PARSER" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); t=p.read_text()
old="""        if not line.startswith('GreenQUIC lcore='): continue
        row={'source_line':no}
"""
new=r"""        # GREENQUIC-V22-TRUNCATED-STATS-GUARD
        if not (line.startswith('GreenQUIC lcore=') or re.match(r'^\[CPU \d+\] GreenQUIC lcore=',line)) or 'wake_signal=' not in line: continue
        row={'source_line':no}
"""
if old not in t: raise SystemExit('ERROR: parser anchor not found')
t=t.replace(old,new,1)
p.write_text(t)
PY
    fi
fi

[[ -f "$VALIDATOR" ]] && python3 -m py_compile "$VALIDATOR"
[[ -f "$PARSER" ]] && python3 -m py_compile "$PARSER"

# Keep all other suite readers compatible with both the historical prefix and
# the new CPU-first prefix. This does not relax field validation.
for reader in \
    "$SUITE/common/bin/validate_v21_idle_evidence.py" \
    "$SUITE/common/bin/parse_v18_stats.py" \
    "$SUITE/common/bin/validate_v18_log.py"; do
    [[ -f "$reader" ]] || continue
    if grep -Fq 'GREENQUIC-V22-CPU-FIRST-STATS-PREFIX' "$reader"; then
        continue
    fi
    cp -a "$reader" "$reader.before_cpu_first_prefix_$(date +%Y%m%d_%H%M%S)"
    python3 - "$reader" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); t=p.read_text()
if p.name == 'validate_v21_idle_evidence.py':
    old="""        if not line.startswith('GreenQUIC lcore='): continue
"""
    new=r"""        # GREENQUIC-V22-CPU-FIRST-STATS-PREFIX
        if not (line.startswith('GreenQUIC lcore=') or re.match(r'^\\[CPU \\d+\\] GreenQUIC lcore=',line)): continue
"""
elif p.name == 'parse_v18_stats.py':
    old="""        if not line.startswith("GreenQUIC lcore="): continue
"""
    new=r"""        # GREENQUIC-V22-CPU-FIRST-STATS-PREFIX
        if not (line.startswith("GreenQUIC lcore=") or re.match(r"^\\[CPU \\d+\\] GreenQUIC lcore=",line)): continue
"""
elif p.name == 'validate_v18_log.py':
    old="""    lines = [(no, text) for no, text in enumerate(raw_lines, 1) if text.startswith("GreenQUIC lcore=")]
"""
    new=r"""    # GREENQUIC-V22-CPU-FIRST-STATS-PREFIX
    lines = [(no, text) for no, text in enumerate(raw_lines, 1) if text.startswith("GreenQUIC lcore=") or re.match(r"^\\[CPU \\d+\\] GreenQUIC lcore=", text)]
"""
else:
    raise SystemExit(f'ERROR: unexpected reader: {p}')
if old not in t:
    raise SystemExit(f'ERROR: prefix anchor not found in {p}')
p.write_text(t.replace(old,new,1))
PY
    python3 -m py_compile "$reader"
done

grep -nF "$MARKER" "$SRC"
grep -nF 'GreenQuicPrintFreqEvent' "$SRC" | head
grep -nF 'cstate_req_last_us=' "$SRC"
grep -nF 'cstate_actual_last_us=' "$SRC"

export PKG_CONFIG_PATH="$DPDK/lib/pkgconfig:$DPDK/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LIBRARY_PATH="$DPDK/lib:$DPDK/lib/x86_64-linux-gnu${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LD_LIBRARY_PATH="$DPDK/lib:$DPDK/lib/x86_64-linux-gnu:$DPDK/lib/dpdk/pmds-22.0${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

pkg-config --exists libdpdk || {
    echo "ERROR: libdpdk is not visible through PKG_CONFIG_PATH" >&2
    exit 1
}

echo "Building with DPDK $(pkg-config --modversion libdpdk)..."
cmake --build "$BUILD" --target quicinteropserver quicinterop -j"$(nproc)"

for bin in "$BUILD/bin/Release/quicinteropserver" "$BUILD/bin/Release/quicinterop"; do
    [[ -x "$bin" ]] || { echo "ERROR: binary missing: $bin" >&2; exit 1; }
    [[ "$bin" -nt "$SRC" ]] || { echo "ERROR: binary is older than source: $bin" >&2; exit 1; }
done

echo
echo "PASS: CPU/frequency logging and V22 stats-field hotfix applied."
echo "GQ_LOG_LEVEL=1: changed/error frequency events + periodic stats."
echo "GQ_LOG_LEVEL=2: also unchanged, cooldown and skipped frequency decisions."
echo "Human event logs and CPU-first periodic stats now end with a blank line."

# ============================================================================
# 3. Single-transfer goodput and server/client ACPI power traces
# ============================================================================

SRC="$REPO/src/platform/datapath_raw_dpdk_linux.c"
COMMON="$SUITE/common/bin"
GQ_COMMON="$COMMON/gq_common.sh"
GOODPUT="$COMMON/report_goodput.py"
POWER_TRACE="$COMMON/power_trace.py"
MARKER='GREENQUIC-V22-GOODPUT-ACPI-TRACE-HOTFIX'
PREVIOUS_MARKER='GREENQUIC-V22-CPU-FREQ-LOGGING-HOTFIX'

for required in "$SRC" "$GQ_COMMON" "$GOODPUT"; do
    [[ -f "$required" ]] || { echo "ERROR: missing $required" >&2; exit 1; }
done

for proc in quicinterop quicinteropserver; do
    if pgrep -x "$proc" >/dev/null 2>&1; then
        echo "ERROR: $proc is running. Stop the client/server before patching." >&2
        pgrep -ax "$proc" >&2 || true
        exit 1
    fi
done

if ! grep -Fq "$PREVIOUS_MARKER" "$SRC"; then
    echo "ERROR: the previous CPU/frequency logging hotfix is not present." >&2
    echo "Apply apply_greenquic_v22_cpu_freq_logging_hotfix.sh first." >&2
    exit 1
fi

stamp="$(date +%Y%m%d_%H%M%S)"

if grep -Fq "$MARKER" "$GQ_COMMON" && [[ -x "$POWER_TRACE" ]] && grep -Fq "$MARKER" "$GOODPUT"; then
    echo "Goodput/ACPI power-trace hotfix is already present. Running checks only."
else
    cp -a "$GQ_COMMON" "$GQ_COMMON.before_goodput_acpi_${stamp}"
    cp -a "$GOODPUT" "$GOODPUT.before_goodput_acpi_${stamp}"
    [[ ! -e "$POWER_TRACE" ]] || cp -a "$POWER_TRACE" "$POWER_TRACE.before_goodput_acpi_${stamp}"
    echo "Backups created with suffix .before_goodput_acpi_${stamp}"

    cat > "$POWER_TRACE" <<'PY'
#!/usr/bin/env python3
"""GreenQUIC whole-system power1 sampler and report generator.

GREENQUIC-V22-GOODPUT-ACPI-TRACE-HOTFIX

This intentionally measures the lm-sensors/sysfs ``power1`` reading. It is a
whole-system/board sensor on the user's machines, not an Intel package-RAPL
counter. Energy is estimated by trapezoidal integration of timestamped watts.
"""
from __future__ import annotations

import argparse
import csv
import html
import json
import math
import os
import re
import signal
import statistics
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

_STOP = False


def _request_stop(_signum: int, _frame: object) -> None:
    global _STOP
    _STOP = True


def _percentile(values: list[float], percentile: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * percentile
    low = math.floor(position)
    high = math.ceil(position)
    if low == high:
        return ordered[low]
    fraction = position - low
    return ordered[low] * (1.0 - fraction) + ordered[high] * fraction


def _unit_to_watts(value: float, unit: str) -> float:
    normalized = unit.replace("µ", "u").lower()
    factors = {
        "w": 1.0,
        "kw": 1_000.0,
        "mw": 1e-3,
        "uw": 1e-6,
        "nw": 1e-9,
    }
    if normalized not in factors:
        raise ValueError(f"unsupported power unit: {unit}")
    return value * factors[normalized]


def _read_from_sensors(match: str, occurrence: str) -> tuple[float, str, str]:
    completed = subprocess.run(
        ["sensors"],
        check=False,
        capture_output=True,
        text=True,
        timeout=5.0,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or f"exit status {completed.returncode}"
        raise RuntimeError(f"sensors failed: {detail}")

    matching = [line.strip() for line in completed.stdout.splitlines() if match.lower() in line.lower()]
    if not matching:
        raise RuntimeError(f"no sensors line contains {match!r}")
    line = matching[0] if occurrence == "first" else matching[-1]

    # Prefer a number after the requested label and before a power unit.
    pattern = re.compile(
        rf"{re.escape(match)}\s*:\s*([+-]?\d+(?:\.\d+)?)\s*(kW|mW|uW|µW|nW|W)\b",
        re.IGNORECASE,
    )
    found = pattern.search(line)
    if found is None:
        found = re.search(
            r"([+-]?\d+(?:\.\d+)?)\s*(kW|mW|uW|µW|nW|W)\b",
            line,
            re.IGNORECASE,
        )
    if found is None:
        raise RuntimeError(f"cannot parse watts from sensors line: {line}")
    watts = _unit_to_watts(float(found.group(1)), found.group(2))
    return watts, "lm-sensors", line


def _read_from_sysfs(match: str, occurrence: str) -> tuple[float, str, str]:
    candidates: list[Path] = []
    for name in ("power1_average", "power1_input"):
        candidates.extend(sorted(Path("/sys/class/hwmon").glob(f"hwmon*/{name}")))
    if not candidates:
        raise RuntimeError("no readable /sys/class/hwmon/hwmon*/power1_{average,input}")

    readable: list[tuple[Path, str]] = []
    for path in candidates:
        if not os.access(path, os.R_OK):
            continue
        hwmon = path.parent
        name_file = hwmon / "name"
        sensor_name = name_file.read_text(encoding="utf-8").strip() if name_file.exists() else hwmon.name
        description = f"{sensor_name}:{path.name}"
        if match.lower() in description.lower() or match.lower() == "power1":
            readable.append((path, description))
    if not readable:
        readable = [(p, str(p)) for p in candidates if os.access(p, os.R_OK)]
    if not readable:
        raise RuntimeError("power1 sysfs candidates are not readable")

    path, description = readable[0] if occurrence == "first" else readable[-1]
    raw = float(path.read_text(encoding="utf-8").strip())
    # hwmon power values are exported in microwatts.
    watts = raw / 1_000_000.0
    return watts, "hwmon-sysfs", f"{description} raw_uw={raw:g} path={path}"


def read_power(match: str, occurrence: str) -> tuple[float, str, str]:
    errors: list[str] = []
    try:
        return _read_from_sensors(match, occurrence)
    except (OSError, subprocess.SubprocessError, RuntimeError, ValueError) as exc:
        errors.append(str(exc))
    try:
        return _read_from_sysfs(match, occurrence)
    except (OSError, RuntimeError, ValueError) as exc:
        errors.append(str(exc))
    raise RuntimeError("; ".join(errors))


def _integrate_joules(samples: list[dict[str, Any]]) -> float:
    total = 0.0
    for left, right in zip(samples, samples[1:]):
        dt = float(right["elapsed_s"]) - float(left["elapsed_s"])
        if dt > 0:
            total += (float(left["power_w"]) + float(right["power_w"])) * 0.5 * dt
    return total


def _scale(values: list[float], low: float, high: float, pixels: float) -> list[float]:
    if high <= low:
        return [pixels * 0.5 for _ in values]
    return [(value - low) / (high - low) * pixels for value in values]


def write_timeseries_svg(path: Path, role: str, samples: list[dict[str, Any]]) -> None:
    width, height = 900, 420
    left, right, top, bottom = 80, 30, 45, 70
    plot_w, plot_h = width - left - right, height - top - bottom
    times = [float(row["elapsed_s"]) for row in samples]
    powers = [float(row["power_w"]) for row in samples]
    if not times or not powers:
        return
    xmin, xmax = min(times), max(times)
    ymin, ymax = min(powers), max(powers)
    padding = max(1.0, (ymax - ymin) * 0.1)
    ymin -= padding
    ymax += padding
    xs = _scale(times, xmin, xmax if xmax > xmin else xmin + 1.0, plot_w)
    ys_bottom = _scale(powers, ymin, ymax, plot_h)
    points = " ".join(f"{left+x:.2f},{top+plot_h-y:.2f}" for x, y in zip(xs, ys_bottom))
    title = html.escape(f"GreenQUIC {role} power1 over time")
    content = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        '<rect width="100%" height="100%" fill="white"/>',
        f'<text x="{width/2}" y="26" text-anchor="middle" font-family="sans-serif" font-size="18">{title}</text>',
        f'<line x1="{left}" y1="{top}" x2="{left}" y2="{top+plot_h}" stroke="black"/>',
        f'<line x1="{left}" y1="{top+plot_h}" x2="{left+plot_w}" y2="{top+plot_h}" stroke="black"/>',
        f'<polyline points="{points}" fill="none" stroke="black" stroke-width="2"/>',
        f'<text x="{width/2}" y="{height-18}" text-anchor="middle" font-family="sans-serif" font-size="14">Elapsed time [s]</text>',
        f'<text x="20" y="{height/2}" text-anchor="middle" font-family="sans-serif" font-size="14" transform="rotate(-90 20 {height/2})">Power [W]</text>',
        f'<text x="{left}" y="{top+plot_h+22}" text-anchor="middle" font-family="monospace" font-size="12">{xmin:.2f}</text>',
        f'<text x="{left+plot_w}" y="{top+plot_h+22}" text-anchor="middle" font-family="monospace" font-size="12">{xmax:.2f}</text>',
        f'<text x="{left-8}" y="{top+plot_h}" text-anchor="end" font-family="monospace" font-size="12">{ymin:.1f}</text>',
        f'<text x="{left-8}" y="{top+8}" text-anchor="end" font-family="monospace" font-size="12">{ymax:.1f}</text>',
        '</svg>',
    ]
    path.write_text("\n".join(content) + "\n", encoding="utf-8")


def write_histogram_svg(path: Path, role: str, values: list[float]) -> None:
    if not values:
        return
    width, height = 900, 420
    left, right, top, bottom = 80, 30, 45, 70
    plot_w, plot_h = width - left - right, height - top - bottom
    bins = min(12, max(1, math.ceil(math.sqrt(len(values)))))
    low, high = min(values), max(values)
    if high <= low:
        low -= 0.5
        high += 0.5
    step = (high - low) / bins
    counts = [0] * bins
    for value in values:
        index = min(bins - 1, max(0, int((value - low) / step)))
        counts[index] += 1
    max_count = max(counts) or 1
    bar_w = plot_w / bins
    title = html.escape(f"GreenQUIC {role} power1 sample histogram")
    content = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        '<rect width="100%" height="100%" fill="white"/>',
        f'<text x="{width/2}" y="26" text-anchor="middle" font-family="sans-serif" font-size="18">{title}</text>',
        f'<line x1="{left}" y1="{top}" x2="{left}" y2="{top+plot_h}" stroke="black"/>',
        f'<line x1="{left}" y1="{top+plot_h}" x2="{left+plot_w}" y2="{top+plot_h}" stroke="black"/>',
    ]
    for index, count in enumerate(counts):
        bar_h = plot_h * count / max_count
        x = left + index * bar_w + 1
        y = top + plot_h - bar_h
        content.append(
            f'<rect x="{x:.2f}" y="{y:.2f}" width="{max(1.0, bar_w-2):.2f}" height="{bar_h:.2f}" fill="none" stroke="black"/>'
        )
    content.extend([
        f'<text x="{width/2}" y="{height-18}" text-anchor="middle" font-family="sans-serif" font-size="14">Power [W]</text>',
        f'<text x="20" y="{height/2}" text-anchor="middle" font-family="sans-serif" font-size="14" transform="rotate(-90 20 {height/2})">Sample count</text>',
        f'<text x="{left}" y="{top+plot_h+22}" text-anchor="middle" font-family="monospace" font-size="12">{low:.1f}</text>',
        f'<text x="{left+plot_w}" y="{top+plot_h+22}" text-anchor="middle" font-family="monospace" font-size="12">{high:.1f}</text>',
        f'<text x="{left-8}" y="{top+plot_h}" text-anchor="end" font-family="monospace" font-size="12">0</text>',
        f'<text x="{left-8}" y="{top+8}" text-anchor="end" font-family="monospace" font-size="12">{max_count}</text>',
        '</svg>',
    ])
    path.write_text("\n".join(content) + "\n", encoding="utf-8")


def record(args: argparse.Namespace) -> int:
    global _STOP
    _STOP = False
    signal.signal(signal.SIGINT, _request_stop)
    signal.signal(signal.SIGTERM, _request_stop)

    prefix: Path = args.prefix
    prefix.parent.mkdir(parents=True, exist_ok=True)
    json_path = Path(str(prefix) + ".json")
    csv_path = Path(str(prefix) + ".csv")
    list_path = Path(str(prefix) + "_python_lists.txt")
    time_svg = Path(str(prefix) + "_timeseries.svg")
    hist_svg = Path(str(prefix) + "_histogram.svg")

    start_wall_ns = time.time_ns()
    start_mono_ns = time.monotonic_ns()
    interval_s = args.interval_ms / 1000.0
    samples: list[dict[str, Any]] = []
    problems: list[str] = []
    source = "unavailable"
    source_detail = ""
    next_sample_ns = start_mono_ns

    while not _STOP:
        now_ns = time.monotonic_ns()
        if args.duration_s is not None and (now_ns - start_mono_ns) / 1e9 >= args.duration_s:
            break
        if now_ns < next_sample_ns:
            time.sleep(min(0.05, (next_sample_ns - now_ns) / 1e9))
            continue
        wall_ns = time.time_ns()
        mono_ns = time.monotonic_ns()
        try:
            watts, current_source, detail = read_power(args.sensor_match, args.sensor_occurrence)
            source = current_source
            source_detail = detail
            samples.append({
                "sample_index": len(samples),
                "wall_ns": wall_ns,
                "monotonic_ns": mono_ns,
                "elapsed_s": (mono_ns - start_mono_ns) / 1e9,
                "power_w": watts,
                "source_line": detail,
            })
        except RuntimeError as exc:
            message = str(exc)
            if not problems or problems[-1] != message:
                problems.append(message)
        next_sample_ns += int(interval_s * 1e9)
        if next_sample_ns <= mono_ns:
            next_sample_ns = mono_ns + int(interval_s * 1e9)

    # Take a final timestamped sample at shutdown so trapezoidal integration
    # covers the tail between the last periodic sample and process completion.
    final_wall_ns = time.time_ns()
    final_mono_ns = time.monotonic_ns()
    if not samples or (final_mono_ns - int(samples[-1]["monotonic_ns"])) >= 1_000_000:
        try:
            watts, current_source, detail = read_power(args.sensor_match, args.sensor_occurrence)
            source = current_source
            source_detail = detail
            samples.append({
                "sample_index": len(samples),
                "wall_ns": final_wall_ns,
                "monotonic_ns": final_mono_ns,
                "elapsed_s": (final_mono_ns - start_mono_ns) / 1e9,
                "power_w": watts,
                "source_line": detail,
            })
        except RuntimeError as exc:
            message = str(exc)
            if not problems or problems[-1] != message:
                problems.append(message)

    end_wall_ns = time.time_ns()
    end_mono_ns = time.monotonic_ns()
    powers = [float(row["power_w"]) for row in samples]
    times = [float(row["elapsed_s"]) for row in samples]
    energy_j = _integrate_joules(samples)
    covered_s = (times[-1] - times[0]) if len(times) >= 2 else 0.0
    average_tw = (energy_j / covered_s) if covered_s > 0 else (powers[0] if len(powers) == 1 else None)

    output: dict[str, Any] = {
        "label": args.label,
        "role": args.role,
        "sensor_kind": "whole-system power1 (ACPI/lm-sensors or hwmon)",
        "source": source,
        "source_detail_last": source_detail,
        "sensor_match": args.sensor_match,
        "sensor_occurrence": args.sensor_occurrence,
        "start_wall_ns": start_wall_ns,
        "end_wall_ns": end_wall_ns,
        "elapsed_s": (end_mono_ns - start_mono_ns) / 1e9,
        "sample_interval_ms_requested": args.interval_ms,
        "sample_count": len(samples),
        "time_s_series": times,
        "power_w_series": powers,
        "samples": samples,
        "estimated_energy_j_trapezoidal": energy_j if len(samples) >= 2 else None,
        "integration_covered_s": covered_s,
        "average_power_w_time_weighted": average_tw,
        "power_w_min": min(powers) if powers else None,
        "power_w_max": max(powers) if powers else None,
        "power_w_mean_samples": statistics.fmean(powers) if powers else None,
        "power_w_median": statistics.median(powers) if powers else None,
        "power_w_p95": _percentile(powers, 0.95),
        "artifacts": {
            "json": str(json_path),
            "csv": str(csv_path),
            "python_lists": str(list_path),
            "time_series_svg": str(time_svg) if samples else None,
            "histogram_svg": str(hist_svg) if samples else None,
        },
        "problems": problems,
        "measurement_note": (
            "The samples are the machine power1 sensor, normally whole-server/board power. "
            "They are not CPU package RAPL. Energy is an approximation from timestamped samples."
        ),
    }

    json_path.write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")
    with csv_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=["sample_index", "elapsed_s", "wall_ns", "power_w", "source_line"])
        writer.writeheader()
        for row in samples:
            writer.writerow({key: row.get(key) for key in writer.fieldnames})
    list_path.write_text(
        "time_s = " + repr(times) + "\n" +
        "power_w = " + repr(powers) + "\n",
        encoding="utf-8",
    )
    if samples:
        write_timeseries_svg(time_svg, args.role, samples)
        write_histogram_svg(hist_svg, args.role, powers)

    if not samples:
        return 4
    return 0


def summary(args: argparse.Namespace) -> int:
    data = json.loads(args.input.read_text(encoding="utf-8"))
    print("\n=== GreenQUIC whole-system power1 trace ===")
    print(f"role={data.get('role')} label={data.get('label')}")
    print(f"source={data.get('source')} samples={data.get('sample_count')} requested_interval_ms={data.get('sample_interval_ms_requested')}")
    print(f"time_s={data.get('time_s_series')}")
    print(f"power_w={data.get('power_w_series')}")
    energy = data.get("estimated_energy_j_trapezoidal")
    average = data.get("average_power_w_time_weighted")
    if energy is not None and average is not None:
        print(f"estimated_whole_system_energy={float(energy):.3f} J average_power={float(average):.3f} W")
    else:
        print("estimated_whole_system_energy=unavailable (need at least two valid samples)")
    print(
        "power_summary="
        f"min={data.get('power_w_min')} W mean={data.get('power_w_mean_samples')} W "
        f"median={data.get('power_w_median')} W p95={data.get('power_w_p95')} W max={data.get('power_w_max')} W"
    )
    artifacts = data.get("artifacts", {})
    print(f"time_series={artifacts.get('time_series_svg')}")
    print(f"histogram={artifacts.get('histogram_svg')}")
    print(f"json={artifacts.get('json')}")
    print("note=power1 is whole-system/board power, not package RAPL")
    print()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    rec = sub.add_parser("record")
    rec.add_argument("--role", choices=("server", "client"), required=True)
    rec.add_argument("--label", default="")
    rec.add_argument("--prefix", type=Path, required=True)
    rec.add_argument("--interval-ms", type=int, default=1000)
    rec.add_argument("--sensor-match", default="power1")
    rec.add_argument("--sensor-occurrence", choices=("first", "last"), default="last")
    rec.add_argument("--duration-s", type=float)

    show = sub.add_parser("summary")
    show.add_argument("--input", type=Path, required=True)

    args = parser.parse_args()
    if args.command == "record":
        if args.interval_ms < 50:
            parser.error("--interval-ms must be at least 50")
        return record(args)
    return summary(args)


if __name__ == "__main__":
    raise SystemExit(main())
PY
    chmod +x "$POWER_TRACE"

    cat > "$GOODPUT" <<'PY'
#!/usr/bin/env python3
"""Accurate payload-goodput report for GreenQUIC client downloads.

GREENQUIC-V22-GOODPUT-ACPI-TRACE-HOTFIX

The primary formula is payload bits divided by the measured client download
interval. The script preserves the old CLI and derives the matching client log
from the energy JSON timestamp.
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


def goodput(payload_bytes: int, duration_s: float) -> dict[str, float]:
    if payload_bytes <= 0:
        raise ValueError("payload bytes must be positive")
    if duration_s <= 0:
        raise ValueError("duration must be positive")
    bits = payload_bytes * 8
    return {
        "duration_s": duration_s,
        "goodput_bps": bits / duration_s,
        "goodput_mbps_decimal": bits / duration_s / 1e6,
        "goodput_gbps_decimal": bits / duration_s / 1e9,
        "goodput_gib_per_s": payload_bytes / duration_s / (1024 ** 3),
    }


def derive_client_log(energy: Path, mode: str) -> Path | None:
    match = re.fullmatch(rf"client_energy_{re.escape(mode)}_(.+)\.json", energy.name)
    test_dir = energy.parent.parent
    logs = test_dir / "logs"
    if match:
        exact = logs / f"client_{mode}_{match.group(1)}.log"
        if exact.is_file():
            return exact
    candidates = sorted(logs.glob(f"client_{mode}_*.log"), key=lambda path: path.stat().st_mtime_ns, reverse=True)
    return candidates[0] if candidates else None


def parse_client_log(path: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8", errors="replace")
    transmission_us = [int(value) for value in re.findall(r"(?mi)^\s*transmission time \[us\]:\s*(\d+)\s*$", text)]
    total_execution_s = [float(value) for value in re.findall(r"(?mi)^\s*Total execution time:\s*([0-9]+(?:\.[0-9]+)?)s\s*$", text)]
    completions = [
        {"file": name.strip(), "duration_ms": int(milliseconds)}
        for name, milliseconds in re.findall(r"(?m)^\s*(.+?):\s*Completed download!\s*\((\d+)\s*ms\)\s*$", text)
    ]
    return {
        "transmission_time_us_values": transmission_us,
        "total_execution_s_values": total_execution_s,
        "completions": completions,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Calculate payload goodput from the exact GreenQUIC client download log.")
    parser.add_argument("--energy", type=Path, required=True, help="Backward-compatible process/RAPL interval JSON")
    parser.add_argument("--client-log", type=Path, help="Exact client log; normally derived from --energy")
    parser.add_argument("--bytes", type=int, required=True)
    parser.add_argument("--mode", required=True)
    parser.add_argument("--test-id", required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    energy_data = json.loads(args.energy.read_text(encoding="utf-8"))
    client_log = args.client_log or derive_client_log(args.energy, args.mode)
    parsed: dict[str, Any] = {"transmission_time_us_values": [], "total_execution_s_values": [], "completions": []}
    if client_log is not None and client_log.is_file():
        parsed = parse_client_log(client_log)

    primary_source: str
    primary_scope: str
    primary_duration_s: float
    transmission_values = parsed["transmission_time_us_values"]
    completions = parsed["completions"]

    if transmission_values:
        primary_duration_s = transmission_values[-1] / 1_000_000.0
        primary_source = "client log: transmission time [us]"
        primary_scope = "client framework download/transmission interval (microsecond timer)"
    elif len(completions) == 1:
        primary_duration_s = completions[0]["duration_ms"] / 1000.0
        primary_source = "client log: Completed download! (ms)"
        primary_scope = "MsQuic application download-completion interval (millisecond timer)"
    else:
        primary_duration_s = float(energy_data.get("elapsed_s") or 0.0)
        primary_source = "fallback: client process/RAPL interval"
        primary_scope = "DPDK/MsQuic startup + handshake + transfer + shutdown; not preferred for paper-comparable goodput"

    primary = goodput(args.bytes, primary_duration_s)
    completion_result = None
    if len(completions) == 1:
        completion_result = goodput(args.bytes, completions[0]["duration_ms"] / 1000.0)
    process_result = None
    process_elapsed = float(energy_data.get("elapsed_s") or 0.0)
    if process_elapsed > 0:
        process_result = goodput(args.bytes, process_elapsed)

    matching_power = None
    power_match = re.fullmatch(rf"client_energy_{re.escape(args.mode)}_(.+)\.json", args.energy.name)
    if power_match:
        power_path = args.energy.with_name(f"client_power_{args.mode}_{power_match.group(1)}.json")
        if power_path.is_file():
            matching_power = json.loads(power_path.read_text(encoding="utf-8"))

    result: dict[str, Any] = {
        "test_id": args.test_id,
        "mode": args.mode,
        "definition": "payload goodput = (successfully downloaded payload bytes * 8) / measured download duration",
        "payload_bytes": args.bytes,
        "payload_gib": args.bytes / (1024 ** 3),
        "units": {
            "Gbit_per_s": "decimal, 1 Gbit/s = 1,000,000,000 bit/s",
            "GiB_per_s": "binary, 1 GiB = 1,073,741,824 bytes",
        },
        "primary": {
            "timing_source": primary_source,
            "timing_scope": primary_scope,
            **primary,
        },
        "paper_method_note": (
            "The paper evaluates goodput from file downloads. Its PDF does not print an algebraic equation; "
            "this report uses payload bits divided by the measured download duration and exposes every timing scope."
        ),
        "client_log": str(client_log) if client_log else None,
        "raw_client_timers": parsed,
        "msquic_completion_crosscheck": completion_result,
        "client_process_interval_crosscheck": process_result,
        "energy_source": str(args.energy),
        "rapl_available": bool(energy_data.get("rapl_available")),
        "total_package_j": energy_data.get("total_package_j") if energy_data.get("rapl_available") else None,
        "average_package_w": energy_data.get("average_package_w") if energy_data.get("rapl_available") else None,
        "whole_system_power1": matching_power,
    }

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")

    print("\n=== GreenQUIC client payload goodput ===")
    print("formula=(payload_bytes * 8) / download_duration_seconds")
    print(f"test={args.test_id} mode={args.mode}")
    print(f"payload={args.bytes} bytes ({result['payload_gib']:.3f} GiB)")
    print(f"primary_timing={primary_source}")
    print(f"duration={primary['duration_s']:.6f} s")
    print(f"goodput={primary['goodput_gbps_decimal']:.6f} Gbit/s ({primary['goodput_mbps_decimal']:.3f} Mbit/s)")
    if completion_result is not None:
        print(
            "msquic_completion_crosscheck="
            f"{completion_result['goodput_gbps_decimal']:.6f} Gbit/s "
            f"from {completion_result['duration_s']:.6f} s"
        )
    if process_result is not None:
        print(
            "whole_client_process_crosscheck="
            f"{process_result['goodput_gbps_decimal']:.6f} Gbit/s "
            f"from {process_result['duration_s']:.6f} s"
        )
    print("note=payload bytes only; Ethernet/IP/UDP/QUIC headers and retransmitted bytes are excluded")
    if matching_power is not None:
        print(
            "client_whole_system_power1="
            f"energy={matching_power.get('estimated_energy_j_trapezoidal')} J "
            f"average={matching_power.get('average_power_w_time_weighted')} W "
            f"samples={matching_power.get('sample_count')}"
        )
    print(f"client_log={client_log}")
    print(f"result={args.out}")
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
    chmod +x "$GOODPUT"

    python3 - "$GQ_COMMON" <<'PY'
from __future__ import annotations

from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
marker = "GREENQUIC-V22-GOODPUT-ACPI-TRACE-HOTFIX"
if marker in text:
    raise SystemExit(0)

old_energy_finish = '''energy_finish() {
    local start="$1"
    local out="$2"
    local label="$3"
    local -a args=(finish --start "$start" --out "$out" --label "$label")
    [[ "${GQ_REQUIRE_RAPL:-1}" == 1 ]] && args+=(--require-package)
    python3 "$GQ_COMMON_DIR/bin/energy_meter.py" "${args[@]}"
}
'''
new_energy_finish = '''energy_finish() {
    local start="$1"
    local out="$2"
    local label="$3"
    local -a args=(finish --start "$start" --out "$out" --label "$label")
    [[ "${GQ_REQUIRE_RAPL:-1}" == 1 ]] && args+=(--require-package)
    local captured rc=0 rapl_available=0
    captured="$(mktemp)"
    python3 "$GQ_COMMON_DIR/bin/energy_meter.py" "${args[@]}" >"$captured" || rc=$?
    if [[ -s "$out" ]]; then
        rapl_available="$(python3 - "$out" <<'PY_RAPL'
import json, sys
try:
    print(1 if json.load(open(sys.argv[1], encoding='utf-8')).get('rapl_available') else 0)
except Exception:
    print(0)
PY_RAPL
)"
    fi
    if [[ "$rapl_available" == 1 || "${GQ_REQUIRE_RAPL:-1}" == 1 ]]; then
        cat "$captured"
    else
        warn "Package RAPL is unavailable. The separate power1 time series is the primary whole-system power result."
    fi
    rm -f "$captured"
    return "$rc"
}

# GREENQUIC-V22-GOODPUT-ACPI-TRACE-HOTFIX
power_trace_start() {
    local role="$1" prefix="$2" label="$3"
    GQ_POWER_TRACE_PID=""
    [[ "${GQ_ENABLE_ACPI_POWER_TRACE:-1}" == 1 ]] || return 0
    local interval="${GQ_POWER_SAMPLE_INTERVAL_MS:-1000}"
    local match="${GQ_POWER_SENSOR_MATCH:-power1}"
    local occurrence="${GQ_POWER_SENSOR_OCCURRENCE:-last}"
    python3 "$GQ_COMMON_DIR/bin/power_trace.py" record \\
        --role "$role" --label "$label" --prefix "$prefix" \\
        --interval-ms "$interval" --sensor-match "$match" --sensor-occurrence "$occurrence" \\
        >"${prefix}_sampler.log" 2>&1 &
    GQ_POWER_TRACE_PID=$!
    sleep 0.10
    if ! kill -0 "$GQ_POWER_TRACE_PID" 2>/dev/null; then
        local rc=0
        wait "$GQ_POWER_TRACE_PID" || rc=$?
        GQ_POWER_TRACE_PID=""
        if [[ "${GQ_REQUIRE_ACPI_POWER_TRACE:-0}" == 1 ]]; then
            cat "${prefix}_sampler.log" >&2 || true
            die "The required power1 sampler failed during startup (status $rc)."
        fi
        warn "power1 sampler is unavailable; see ${prefix}_sampler.log"
        return 0
    fi
    log "Started ${role} whole-system power1 trace pid=$GQ_POWER_TRACE_PID interval=${interval}ms prefix=$prefix"
}

power_trace_stop() {
    local pid="$1" prefix="$2"
    [[ "${GQ_ENABLE_ACPI_POWER_TRACE:-1}" == 1 ]] || return 0
    local rc=0
    if [[ -n "$pid" ]]; then
        if kill -0 "$pid" 2>/dev/null; then kill -INT "$pid" 2>/dev/null || true; fi
        wait "$pid" || rc=$?
    fi
    if [[ -s "${prefix}.json" ]]; then
        python3 "$GQ_COMMON_DIR/bin/power_trace.py" summary --input "${prefix}.json"
    else
        [[ -s "${prefix}_sampler.log" ]] && cat "${prefix}_sampler.log" >&2 || true
        if [[ "${GQ_REQUIRE_ACPI_POWER_TRACE:-0}" == 1 ]]; then
            return "${rc:-4}"
        fi
        warn "No valid power1 trace was produced for $prefix"
        return 0
    fi
    if [[ "$rc" != 0 && "${GQ_REQUIRE_ACPI_POWER_TRACE:-0}" == 1 ]]; then return "$rc"; fi
    return 0
}
'''
if old_energy_finish not in text:
    raise SystemExit("ERROR: unsupported gq_common.sh: energy_finish block was not found")
text = text.replace(old_energy_finish, new_energy_finish, 1)

old = '''    local logf="$TEST_DIR/logs/server_${mode}_${stamp}.log"
    local estart="$runtime/energy_start_${stamp}.json" eout="$TEST_DIR/results/server_energy_${mode}_${stamp}.json"
'''
new = '''    local logf="$TEST_DIR/logs/server_${mode}_${stamp}.log"
    local estart="$runtime/energy_start_${stamp}.json" eout="$TEST_DIR/results/server_energy_${mode}_${stamp}.json"
    local power_prefix="$TEST_DIR/results/server_power_${mode}_${stamp}"
'''
if old not in text:
    raise SystemExit("ERROR: unsupported gq_common.sh: server result variables anchor not found")
text = text.replace(old, new, 1)

old = '''    energy_start "$estart"
    GQ_SERVER_ESTART="$estart"
'''
new = '''    power_trace_start server "$power_prefix" "$TEST_ID server $mode UNSYNCHRONIZED_LISTENER_LIFETIME"
    GQ_SERVER_POWER_PID="${GQ_POWER_TRACE_PID:-}"
    GQ_SERVER_POWER_PREFIX="$power_prefix"
    energy_start "$estart"
    GQ_SERVER_ESTART="$estart"
'''
if old not in text:
    raise SystemExit("ERROR: unsupported gq_common.sh: server energy_start anchor not found")
text = text.replace(old, new, 1)

old = '''        local check_rc=0 energy_rc=0
        validate_runtime_log server "$GQ_SERVER_LOGF" "$GQ_SERVER_MODE" "$GQ_SERVER_STAMP" || check_rc=$?
        energy_finish "$GQ_SERVER_ESTART" "$GQ_SERVER_EOUT" "$GQ_SERVER_LABEL" || energy_rc=$?
        [[ "$rc" == 0 && "$check_rc" != 0 ]] && rc="$check_rc"
        [[ "$rc" == 0 && "$energy_rc" != 0 ]] && rc="$energy_rc"
'''
new = '''        local check_rc=0 energy_rc=0 power_rc=0
        power_trace_stop "${GQ_SERVER_POWER_PID:-}" "$GQ_SERVER_POWER_PREFIX" || power_rc=$?
        validate_runtime_log server "$GQ_SERVER_LOGF" "$GQ_SERVER_MODE" "$GQ_SERVER_STAMP" || check_rc=$?
        energy_finish "$GQ_SERVER_ESTART" "$GQ_SERVER_EOUT" "$GQ_SERVER_LABEL" || energy_rc=$?
        [[ "$rc" == 0 && "$power_rc" != 0 ]] && rc="$power_rc"
        [[ "$rc" == 0 && "$check_rc" != 0 ]] && rc="$check_rc"
        [[ "$rc" == 0 && "$energy_rc" != 0 ]] && rc="$energy_rc"
'''
if old not in text:
    raise SystemExit("ERROR: unsupported gq_common.sh: server finish anchor not found")
text = text.replace(old, new, 1)

old = '''    local logf="$TEST_DIR/logs/client_${mode}_${stamp}.log"
    local estart="$runtime/energy_start_${stamp}.json" eout="$TEST_DIR/results/client_energy_${mode}_${stamp}.json"
'''
new = '''    local logf="$TEST_DIR/logs/client_${mode}_${stamp}.log"
    local estart="$runtime/energy_start_${stamp}.json" eout="$TEST_DIR/results/client_energy_${mode}_${stamp}.json"
    local power_prefix="$TEST_DIR/results/client_power_${mode}_${stamp}"
'''
if old not in text:
    raise SystemExit("ERROR: unsupported gq_common.sh: client result variables anchor not found")
text = text.replace(old, new, 1)

old = '''    energy_start "$estart"
    local rc=0 energy_rc=0
'''
new = '''    power_trace_start client "$power_prefix" "$TEST_ID client $mode"
    local power_pid="${GQ_POWER_TRACE_PID:-}"
    energy_start "$estart"
    local rc=0 energy_rc=0 power_rc=0
'''
if old not in text:
    raise SystemExit("ERROR: unsupported gq_common.sh: client energy_start anchor not found")
text = text.replace(old, new, 1)

old = '''    ) 2>&1 | tee "$logf" || rc=${PIPESTATUS[0]}
    energy_finish "$estart" "$eout" "$TEST_ID client $mode" || energy_rc=$?
    [[ "$rc" == 0 ]] || return "$rc"
    [[ "$energy_rc" == 0 ]] || return "$energy_rc"
'''
new = '''    ) 2>&1 | tee "$logf" || rc=${PIPESTATUS[0]}
    power_trace_stop "$power_pid" "$power_prefix" || power_rc=$?
    energy_finish "$estart" "$eout" "$TEST_ID client $mode" || energy_rc=$?
    [[ "$rc" == 0 ]] || return "$rc"
    [[ "$power_rc" == 0 ]] || return "$power_rc"
    [[ "$energy_rc" == 0 ]] || return "$energy_rc"
'''
if old not in text:
    raise SystemExit("ERROR: unsupported gq_common.sh: client finish anchor not found")
text = text.replace(old, new, 1)

path.write_text(text, encoding="utf-8")
PY
fi

python3 -m py_compile "$POWER_TRACE" "$GOODPUT" "$COMMON/energy_meter.py"
bash -n "$GQ_COMMON"

grep -Fq "$MARKER" "$GQ_COMMON" || { echo "ERROR: gq_common marker missing" >&2; exit 1; }
grep -Fq "$MARKER" "$GOODPUT" || { echo "ERROR: report_goodput marker missing" >&2; exit 1; }

# Deterministic goodput self-test using the exact timing shape shown by the user.
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/test/results" "$test_dir/test/logs"
cat > "$test_dir/test/results/client_energy_basic_20260731_130000_000000000.json" <<'JSON'
{"elapsed_s": 13.418718956, "rapl_available": false, "total_package_j": 0.0, "average_package_w": null}
JSON
cat > "$test_dir/test/logs/client_basic_20260731_130000_000000000.log" <<'LOG'
file_10G.bin: Completed download! (12482 ms)
Total execution time: 12.496s
transmission time [us]: 12495528
LOG
python3 "$GOODPUT" \
    --energy "$test_dir/test/results/client_energy_basic_20260731_130000_000000000.json" \
    --bytes 10737418240 --mode basic --test-id P2 \
    --out "$test_dir/goodput.json" >/dev/null
python3 - "$test_dir/goodput.json" <<'PY'
import json, math, sys
row=json.load(open(sys.argv[1], encoding='utf-8'))
expected=10737418240*8/12.495528/1e9
actual=row['primary']['goodput_gbps_decimal']
if not math.isclose(actual, expected, rel_tol=0, abs_tol=1e-12):
    raise SystemExit(f'goodput self-test failed: {actual} != {expected}')
assert row['primary']['timing_source'] == 'client log: transmission time [us]'
PY

# Power sampler self-test with a fake sensors executable.
mkdir -p "$test_dir/fakebin"
cat > "$test_dir/fakebin/sensors" <<'SH'
#!/usr/bin/env bash
printf 'acpitz-acpi-0\npower1:      152.00 W  (interval = 1.00 s)\n'
SH
chmod +x "$test_dir/fakebin/sensors"
PATH="$test_dir/fakebin:$PATH" python3 "$POWER_TRACE" record \
    --role client --label selftest --prefix "$test_dir/power" --interval-ms 100 --duration-s 0.36 >/dev/null
python3 - "$test_dir/power.json" <<'PY'
import json, sys
row=json.load(open(sys.argv[1], encoding='utf-8'))
assert row['sample_count'] >= 3, row
assert row['power_w_series'] and all(abs(v-152.0) < 1e-9 for v in row['power_w_series'])
assert row['estimated_energy_j_trapezoidal'] is not None
for key in ('time_series_svg','histogram_svg','python_lists'):
    assert row['artifacts'][key], key
PY

cat <<EOF

GreenQUIC V22 goodput + ACPI/lm-sensors power-trace hotfix applied successfully.

Preserved previous source patch:
  $PREVIOUS_MARKER

Added suite-only marker:
  $MARKER

No MsQuic source was changed and no rebuild is required.

New runtime environment controls:
  GQ_ENABLE_ACPI_POWER_TRACE=1       enable power1 trace (default 1)
  GQ_REQUIRE_ACPI_POWER_TRACE=0      fail test when no sample is available (default 0)
  GQ_POWER_SAMPLE_INTERVAL_MS=1000   sample interval in milliseconds
  GQ_POWER_SENSOR_MATCH=power1       lm-sensors line selector
  GQ_POWER_SENSOR_OCCURRENCE=last    first or last matching sensors line

Each run now creates separate role-specific artifacts in the test results directory:
  client_power_<mode>_<stamp>.json/.csv/_python_lists.txt/_timeseries.svg/_histogram.svg
  server_power_<mode>_<stamp>.json/.csv/_python_lists.txt/_timeseries.svg/_histogram.svg

The client goodput report now uses:
  payload_goodput = payload_bytes * 8 / client_download_duration_seconds
and prints both the microsecond framework timer and the MsQuic completion timer when available.
EOF

# ============================================================================
# 4. Client download manifest and automatic payload cleanup
# ============================================================================

GQ_COMMON="$SUITE/common/bin/gq_common.sh"
GOODPUT="$SUITE/common/bin/report_goodput.py"
MARKER='GREENQUIC-V22-DOWNLOAD-CLEANUP-HOTFIX'
PREVIOUS_MARKER='GREENQUIC-V22-GOODPUT-ACPI-TRACE-HOTFIX'

[[ -f "$GQ_COMMON" ]] || { echo "ERROR: missing $GQ_COMMON" >&2; exit 1; }
[[ -f "$GOODPUT" ]] || { echo "ERROR: missing $GOODPUT" >&2; exit 1; }
if ! grep -Fq "$PREVIOUS_MARKER" "$GQ_COMMON"; then
    echo "ERROR: the goodput/ACPI patch must be applied first." >&2
    exit 1
fi

P0="$SUITE/test_cases/pretests/P0_smoke_1MiB/run_client.sh"
P1="$SUITE/test_cases/pretests/P1_goodput_off_10GiB/run_client.sh"
P2="$SUITE/test_cases/pretests/P2_goodput_basic_10GiB/run_client.sh"
for f in "$P0" "$P1" "$P2"; do
    [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 1; }
done

if grep -Fq "$MARKER" "$GQ_COMMON"; then
    echo "Download cleanup hotfix is already present."
else
    stamp="$(date +%Y%m%d_%H%M%S)"
    cp -a "$GQ_COMMON" "$GQ_COMMON.before_download_cleanup_${stamp}"
    cp -a "$P0" "$P0.before_download_cleanup_${stamp}"
    cp -a "$P1" "$P1.before_download_cleanup_${stamp}"
    cp -a "$P2" "$P2.before_download_cleanup_${stamp}"
    echo "Backups created with suffix .before_download_cleanup_${stamp}"

    python3 - "$GQ_COMMON" "$P0" "$P1" "$P2" <<'PY'
from __future__ import annotations

from pathlib import Path
import sys

common_path, p0_path, p1_path, p2_path = map(Path, sys.argv[1:])
text = common_path.read_text(encoding="utf-8")
marker = "GREENQUIC-V22-DOWNLOAD-CLEANUP-HOTFIX"

if marker not in text:
    anchor = "\nrun_client() {\n"
    if anchor not in text:
        raise SystemExit("ERROR: run_client() anchor not found in gq_common.sh")

    helpers = r'''
# GREENQUIC-V22-DOWNLOAD-CLEANUP-HOTFIX
write_client_download_manifest() {
    local start_wall_ns="$1" out="$2"
    python3 - "$EFFECTIVE_DOWNLOAD_DIR" "$start_wall_ns" "$out" "$TEST_ID" "$WORKLOAD_KIND" <<'PY_MANIFEST'
from __future__ import annotations
import json
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
start_ns = int(sys.argv[2])
out = Path(sys.argv[3])
test_id = sys.argv[4]
workload = sys.argv[5]
rows = []
if root.is_dir():
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        st = path.stat()
        # Only files created or modified by this client run are owned by it.
        if st.st_mtime_ns < start_ns:
            continue
        rows.append({
            "path": str(path),
            "relative_path": str(path.relative_to(root)),
            "size_bytes": st.st_size,
            "mtime_ns": st.st_mtime_ns,
        })
data = {
    "schema": "greenquic-client-download-manifest-v1",
    "test_id": test_id,
    "workload_kind": workload,
    "download_root": str(root),
    "start_wall_ns": start_ns,
    "file_count": len(rows),
    "total_bytes": sum(row["size_bytes"] for row in rows),
    "files": rows,
}
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
print(
    f"[GreenQUIC-Test] Download manifest: files={data['file_count']} "
    f"total_bytes={data['total_bytes']} path={out}"
)
PY_MANIFEST
}

cleanup_client_downloads() {
    local manifest="$1"
    [[ "${GQ_CLEANUP_DOWNLOADED_FILES:-1}" == 1 ]] || {
        log "Preserving client payload files because GQ_CLEANUP_DOWNLOADED_FILES=${GQ_CLEANUP_DOWNLOADED_FILES:-0}."
        return 0
    }
    python3 - "$manifest" <<'PY_CLEANUP'
from __future__ import annotations
import json
from pathlib import Path
import sys

manifest = Path(sys.argv[1])
data = json.loads(manifest.read_text(encoding="utf-8"))
root = Path(data["download_root"]).resolve()
removed = 0
removed_bytes = 0
for row in data.get("files", []):
    path = Path(row["path"]).resolve()
    try:
        path.relative_to(root)
    except ValueError:
        raise SystemExit(f"refusing to delete path outside download root: {path}")
    if path.is_file():
        removed_bytes += path.stat().st_size
        path.unlink()
        removed += 1
# Remove empty subdirectories, but preserve the configured download root itself.
if root.is_dir():
    for directory in sorted((p for p in root.rglob("*") if p.is_dir()), reverse=True):
        try:
            directory.rmdir()
        except OSError:
            pass
print(
    f"[GreenQUIC-Test] Removed {removed} downloaded payload file(s), "
    f"{removed_bytes} byte(s), from {root}."
)
PY_CLEANUP
}
'''
    text = text.replace(anchor, "\n" + helpers.strip("\n") + anchor, 1)

    old = '''    local logf="$TEST_DIR/logs/client_${mode}_${stamp}.log"
    local estart="$runtime/energy_start_${stamp}.json" eout="$TEST_DIR/results/client_energy_${mode}_${stamp}.json"
    local power_prefix="$TEST_DIR/results/client_power_${mode}_${stamp}"
'''
    new = '''    local logf="$TEST_DIR/logs/client_${mode}_${stamp}.log"
    local estart="$runtime/energy_start_${stamp}.json" eout="$TEST_DIR/results/client_energy_${mode}_${stamp}.json"
    local power_prefix="$TEST_DIR/results/client_power_${mode}_${stamp}"
    local download_manifest="$TEST_DIR/results/client_download_manifest_${mode}_${stamp}.json"
    local download_start_wall_ns
    download_start_wall_ns="$(date +%s%N)"
'''
    if old not in text:
        raise SystemExit("ERROR: client result-variable anchor not found")
    text = text.replace(old, new, 1)

    old = '''    local rc=0 energy_rc=0 power_rc=0
    (
'''
    new = '''    local rc=0 energy_rc=0 power_rc=0 manifest_rc=0 cleanup_rc=0
    (
'''
    if old not in text:
        raise SystemExit("ERROR: client return-code anchor not found")
    text = text.replace(old, new, 1)

    old = '''    power_trace_stop "$power_pid" "$power_prefix" || power_rc=$?
    energy_finish "$estart" "$eout" "$TEST_ID client $mode" || energy_rc=$?
    [[ "$rc" == 0 ]] || return "$rc"
    [[ "$power_rc" == 0 ]] || return "$power_rc"
    [[ "$energy_rc" == 0 ]] || return "$energy_rc"
    validate_stock_client_completions "$logf"
    validate_runtime_log client "$logf" "$mode" "$stamp"
'''
    new = '''    power_trace_stop "$power_pid" "$power_prefix" || power_rc=$?
    energy_finish "$estart" "$eout" "$TEST_ID client $mode" || energy_rc=$?
    write_client_download_manifest "$download_start_wall_ns" "$download_manifest" || manifest_rc=$?

    # Validate before deleting payloads. Logs, JSON, CSV and SVG reports are preserved.
    if [[ "$rc" == 0 && "$power_rc" == 0 && "$energy_rc" == 0 && "$manifest_rc" == 0 ]]; then
        validate_stock_client_completions "$logf" || rc=$?
    fi
    if [[ "$rc" == 0 && "$power_rc" == 0 && "$energy_rc" == 0 && "$manifest_rc" == 0 ]]; then
        validate_runtime_log client "$logf" "$mode" "$stamp" || rc=$?
    fi
    cleanup_client_downloads "$download_manifest" || cleanup_rc=$?

    [[ "$rc" == 0 ]] || return "$rc"
    [[ "$power_rc" == 0 ]] || return "$power_rc"
    [[ "$energy_rc" == 0 ]] || return "$energy_rc"
    [[ "$manifest_rc" == 0 ]] || return "$manifest_rc"
    [[ "$cleanup_rc" == 0 ]] || return "$cleanup_rc"
'''
    if old not in text:
        raise SystemExit("ERROR: client finish block not found")
    text = text.replace(old, new, 1)
    common_path.write_text(text, encoding="utf-8")

# P0 needs the downloaded file for its size and SHA validation, so it disables
# common cleanup for that command and removes the file itself through an EXIT trap.
p0 = p0_path.read_text(encoding="utf-8")
if marker not in p0:
    p0 = p0.replace(
        'TARGET="$HERE/results/downloads/file_1M.bin"\nrm -f "$TARGET"\n',
        'TARGET="$HERE/results/downloads/file_1M.bin"\n'
        '# GREENQUIC-V22-DOWNLOAD-CLEANUP-HOTFIX\n'
        'cleanup_download() { rm -f -- "$TARGET"; }\n'
        'trap cleanup_download EXIT\n'
        'rm -f -- "$TARGET"\n',
        1,
    )
    old = '"$HERE/../../../common/bin/run_role.sh" client "$HERE" off 0\n'
    new = 'GQ_CLEANUP_DOWNLOADED_FILES=0 "$HERE/../../../common/bin/run_role.sh" client "$HERE" off 0\n'
    if old not in p0:
        raise SystemExit("ERROR: P0 run_role anchor not found")
    p0 = p0.replace(old, new, 1)
    p0_path.write_text(p0, encoding="utf-8")


def patch_goodput_wrapper(path: Path, mode: str) -> None:
    body = path.read_text(encoding="utf-8")
    if marker in body:
        return
    run_line = f'"$HERE/../../../common/bin/run_role.sh" client "$HERE" "{mode}" 0\n'
    if run_line not in body:
        raise SystemExit(f"ERROR: run_role anchor not found in {path}")
    body = body.replace(run_line, run_line + f'''# {marker}
manifest="$(find "$HERE/results" -maxdepth 1 -type f -name 'client_download_manifest_{mode}_*.json' -printf '%T@ %p\\n' | sort -nr | head -n1 | cut -d' ' -f2-)"
[[ -n "$manifest" && -f "$manifest" ]] || {{ echo 'ERROR: latest client download manifest not found' >&2; exit 2; }}
actual_bytes="$(python3 - "$manifest" <<'PY_BYTES'
import json, sys
row = json.load(open(sys.argv[1], encoding='utf-8'))
print(int(row.get('total_bytes', 0)))
PY_BYTES
)"
[[ "$actual_bytes" -gt 0 ]] || {{ echo "ERROR: no downloaded payload bytes were recorded in $manifest" >&2; exit 2; }}
[[ "$actual_bytes" == "$PAYLOAD_BYTES" ]] || {{ echo "ERROR: expected $PAYLOAD_BYTES downloaded bytes, got $actual_bytes" >&2; exit 2; }}
''', 1)
    body = body.replace('--energy "$energy" --bytes "$PAYLOAD_BYTES"', '--energy "$energy" --bytes "$actual_bytes"', 1)
    path.write_text(body, encoding="utf-8")

patch_goodput_wrapper(p1_path, "off")
patch_goodput_wrapper(p2_path, "basic")
PY
fi

bash -n "$GQ_COMMON" "$P0" "$P1" "$P2"
grep -Fq "$MARKER" "$GQ_COMMON" || { echo "ERROR: common cleanup marker missing" >&2; exit 1; }
grep -Fq "$MARKER" "$P0" || { echo "ERROR: P0 cleanup marker missing" >&2; exit 1; }
grep -Fq "$MARKER" "$P1" || { echo "ERROR: P1 cleanup marker missing" >&2; exit 1; }
grep -Fq "$MARKER" "$P2" || { echo "ERROR: P2 cleanup marker missing" >&2; exit 1; }

cat <<'EOF'

GreenQUIC V22 client-download cleanup hotfix applied successfully.

Default behavior:
  GQ_CLEANUP_DOWNLOADED_FILES=1

Each client run now:
  1. records the exact files and byte counts written during that run;
  2. writes client_download_manifest_<mode>_<stamp>.json;
  3. validates logs;
  4. deletes only the downloaded payload files from that run.

Goodput for P1/P2 uses the actual downloaded byte count from the manifest.
The patch reports one goodput value per execution; it does not perform 50 repetitions.

The server's canonical source payload is preserved because it is one reusable file,
not an accumulating download. Whichever machine runs the client cleans its local downloads.
EOF


echo
echo "PASS: GreenQUIC V22 log/goodput/power/cleanup patch completed."
echo "MsQuic repository: $REPO"
echo "Test suite:        $SUITE"
