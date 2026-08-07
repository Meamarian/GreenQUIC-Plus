#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${1:-/root/mohsen/msquic}"
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
