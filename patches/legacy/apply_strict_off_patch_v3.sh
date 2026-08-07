#!/usr/bin/env bash
set -euo pipefail

# Strict OFF-mode runtime bypass for GreenQUIC.
#
# Usage:
#   bash apply_strict_off_patch_v3.sh /root/mohsen
#   bash apply_strict_off_patch_v3.sh /root/greenquic_snapshot
#   bash apply_strict_off_patch_v3.sh /root/mohsen --no-build

ROOT="${1:-}"
NO_BUILD="${2:-}"

if [[ -z "$ROOT" || ! -d "$ROOT" ]]; then
    echo "Usage: $0 /path/to/GreenQUIC [--no-build]" >&2
    exit 2
fi
if [[ -n "$NO_BUILD" && "$NO_BUILD" != "--no-build" ]]; then
    echo "Unknown option: $NO_BUILD" >&2
    exit 2
fi

ROOT="$(cd "$ROOT" && pwd)"
MSQUIC="$ROOT/msquic"
DPDK_FILE="$MSQUIC/src/platform/datapath_raw_dpdk_linux.c"
PLUS_C="$MSQUIC/src/platform/greenquic_plus.c"
PLUS_H="$MSQUIC/src/inc/greenquic_plus.h"
COMMON_SH="$ROOT/greenquic_test_suite_v22/common/bin/gq_common.sh"
BOOTSTRAP="$ROOT/bootstrap_greenquic.sh"
ENV_FILE="$ROOT/greenquic-env.sh"
BUILD="$MSQUIC/build-greenquic"

for file in "$DPDK_FILE" "$PLUS_C" "$PLUS_H" "$COMMON_SH" "$BOOTSTRAP" "$ENV_FILE"; do
    [[ -f "$file" ]] || {
        echo "ERROR: required file is missing: $file" >&2
        exit 1
    }
done

if pgrep -af 'quicinterop(server)?|secnetperf' >/dev/null 2>&1; then
    echo "ERROR: stop all quicinterop/quicinteropserver/secnetperf processes before patching." >&2
    pgrep -af 'quicinterop(server)?|secnetperf' >&2 || true
    exit 1
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="$ROOT/.greenquic-strict-off-backup-$STAMP"
mkdir -p "$BACKUP/msquic/src/platform" "$BACKUP/msquic/src/inc" \
         "$BACKUP/greenquic_test_suite_v22/common/bin"
cp -a "$DPDK_FILE" "$BACKUP/msquic/src/platform/"
cp -a "$PLUS_C" "$BACKUP/msquic/src/platform/"
cp -a "$PLUS_H" "$BACKUP/msquic/src/inc/"
cp -a "$COMMON_SH" "$BACKUP/greenquic_test_suite_v22/common/bin/"
cp -a "$BOOTSTRAP" "$BACKUP/"
cp -a "$ENV_FILE" "$BACKUP/"

echo "Backup created: $BACKUP"

PATCH_COMPLETE=0
restore_on_exit() {
    local rc=$?
    if [[ "$PATCH_COMPLETE" != 1 ]]; then
        echo >&2
        echo "Patch did not complete; restoring source files from: $BACKUP" >&2
        cp -a "$BACKUP"/. "$ROOT"/
        echo "Source restoration completed." >&2
    fi
    exit "$rc"
}
trap restore_on_exit EXIT

python3 - "$ROOT" <<'PY'
from __future__ import annotations

from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
plus_h = root / "msquic/src/inc/greenquic_plus.h"
plus_c = root / "msquic/src/platform/greenquic_plus.c"
dpdk = root / "msquic/src/platform/datapath_raw_dpdk_linux.c"
common = root / "greenquic_test_suite_v22/common/bin/gq_common.sh"

MARK = "GREENQUIC-STRICT-OFF-V1"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        print(f"OK already patched: {label}")
        return text
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            f"ERROR: {label}: expected exactly one old block, found {count}"
        )
    print(f"PATCH: {label}")
    return text.replace(old, new, 1)


def replace_all_exact(
    text: str,
    old: str,
    new: str,
    label: str,
    expected: int,
) -> str:
    if new in text and old not in text:
        print(f"OK already patched: {label}")
        return text
    count = text.count(old)
    if count != expected:
        raise SystemExit(
            f"ERROR: {label}: expected {expected} old blocks, found {count}"
        )
    print(f"PATCH: {label} ({count} occurrences)")
    return text.replace(old, new)


def insert_function_guard(
    text: str,
    function: str,
    return_statement: str,
) -> str:
    marker = f"/* {MARK}: no hint work outside PLUS mode. */"
    pattern = re.compile(
        rf"((?:void|uint16_t|uint64_t)\n{re.escape(function)}\s*\([^)]*\)\n\{{\n)",
        re.DOTALL,
    )
    match = pattern.search(text)
    if not match:
        raise SystemExit(f"ERROR: cannot find function {function}")
    nearby = text[match.end():match.end() + 260]
    if nearby.lstrip().startswith(marker):
        print(f"OK already guarded: {function}")
        return text
    guard = (
        f"    {marker}\n"
        f"    if (!CxPlatGreenQuicPlusRuntimeEnabled()) {{\n"
        f"        {return_statement}\n"
        f"    }}\n"
    )
    print(f"PATCH: guard {function}")
    return text[:match.end()] + guard + text[match.end():]


# ---------------------------------------------------------------------------
# Public runtime gate for every GreenQUIC+ hook.
# ---------------------------------------------------------------------------
text = read(plus_h)
old = "void CxPlatGreenQuicPlusSetThreadLcore(uint16_t Lcore);\n"
new = f"""/* {MARK}: process-wide runtime gate; enabled only in PLUS mode. */
void CxPlatGreenQuicPlusSetRuntimeEnabled(int Enabled);
int CxPlatGreenQuicPlusRuntimeEnabled(void);

{old}"""
text = replace_once(text, old, new, "declare PLUS runtime gate")
write(plus_h, text)

text = read(plus_c)
thread_block = """#if defined(_MSC_VER)
__declspec(thread) static uint16_t ThreadLcore = GQPLUS_LCORE_UNKNOWN;
#else
static _Thread_local uint16_t ThreadLcore = GQPLUS_LCORE_UNKNOWN;
#endif
"""
gate_block = thread_block + f"""
/* {MARK}: OFF and BASIC do not execute hint bookkeeping. */
static atomic_int GreenQuicPlusRuntimeGate = ATOMIC_VAR_INIT(0);

void
CxPlatGreenQuicPlusSetRuntimeEnabled(int Enabled)
{{
    atomic_store_explicit(
        &GreenQuicPlusRuntimeGate,
        Enabled != 0 ? 1 : 0,
        memory_order_release);
    if (Enabled == 0) {{
        ThreadLcore = GQPLUS_LCORE_UNKNOWN;
    }}
}}

int
CxPlatGreenQuicPlusRuntimeEnabled(void)
{{
    return atomic_load_explicit(
        &GreenQuicPlusRuntimeGate,
        memory_order_acquire) != 0;
}}
"""
text = replace_once(text, thread_block, gate_block, "implement PLUS runtime gate")

void_guards = [
    "CxPlatGreenQuicPlusSetPartitionDpdkLcore",
    "CxPlatGreenQuicPlusSetHints",
    "CxPlatGreenQuicPlusClearHints",
    "CxPlatGreenQuicPlusBeginTransfer",
    "CxPlatGreenQuicPlusEndTransfer",
    "CxPlatGreenQuicPlusBeginRecovery",
    "CxPlatGreenQuicPlusEndRecovery",
    "CxPlatGreenQuicPlusBeginRecoveryForPartition",
    "CxPlatGreenQuicPlusEndRecoveryForPartition",
    "CxPlatGreenQuicPlusPulseHints",
    "CxPlatGreenQuicPlusPulseHintsForLcore",
    "CxPlatGreenQuicPlusPulseHintsForPartition",
]
for name in void_guards:
    text = insert_function_guard(text, name, "return;")

text = insert_function_guard(
    text,
    "CxPlatGreenQuicPlusSetThreadLcore",
    "ThreadLcore = GQPLUS_LCORE_UNKNOWN; return;",
)
text = insert_function_guard(
    text,
    "CxPlatGreenQuicPlusGetPartitionDpdkLcore",
    "return GQPLUS_LCORE_UNKNOWN;",
)
for name in (
    "CxPlatGreenQuicPlusGetHints",
    "CxPlatGreenQuicPlusGetTxHints",
    "CxPlatGreenQuicPlusGetHintsForLcore",
):
    text = insert_function_guard(text, name, "return 0;")
write(plus_c, text)

# ---------------------------------------------------------------------------
# Strict OFF bypass inside the Linux DPDK datapath.
# ---------------------------------------------------------------------------
text = read(dpdk)

old = """        }
    } else if (strcmp(Key, "GreenQuicProfile") == 0) {
"""
new = f"""        }}
        /* {MARK}: hint hooks are live only in PLUS mode. */
        CxPlatGreenQuicPlusSetRuntimeEnabled(
            Dpdk->GreenQuicMode == GREENQUIC_MODE_PLUS ? 1 : 0);
    }} else if (strcmp(Key, "GreenQuicProfile") == 0) {{
"""
text = replace_once(text, old, new, "connect parsed mode to PLUS runtime gate")

pattern = re.compile(
    r"(static void\nGreenQuicParsePartitionDpdkMap\s*\([^)]*\)\n\{\n)",
    re.DOTALL,
)
m = pattern.search(text)
if not m:
    raise SystemExit("ERROR: GreenQuicParsePartitionDpdkMap not found")
parse_guard = f"""    /* {MARK} */
    if (Dpdk->GreenQuicMode != GREENQUIC_MODE_PLUS) {{
        return;
    }}
"""
if MARK not in text[m.end():m.end()+180]:
    text = text[:m.end()] + parse_guard + text[m.end():]
    print("PATCH: skip partition-map parsing outside PLUS")
else:
    print("OK already patched: partition-map parsing")

old = """    if (!Dpdk->GreenQuicEnableMultiCore || Dpdk->GreenQuicPartitionDpdkMapConfigured) {
        return;
    }
"""
new = f"""    if (Dpdk->GreenQuicMode != GREENQUIC_MODE_PLUS ||
        !Dpdk->GreenQuicEnableMultiCore ||
        Dpdk->GreenQuicPartitionDpdkMapConfigured) {{
        return;
    }}
"""
text = replace_once(text, old, new, "skip default partition mapping outside PLUS")

old = """    FILE *File = fopen("dpdk.ini", "r");
    if (File == NULL) {
        GreenQuicReadPowerConfig(Dpdk);
        GreenQuicInitCStateSupport(Dpdk);
        return;
    }
"""
new = f"""    FILE *File = fopen("dpdk.ini", "r");
    if (File == NULL) {{
        /* {MARK}: default mode is OFF; do not initialize GreenQUIC. */
        CxPlatGreenQuicPlusSetRuntimeEnabled(0);
        return;
    }}
"""
text = replace_once(text, old, new, "skip power/idle initialization without config")

old = """    fclose(File);
    GreenQuicReadPowerConfig(Dpdk);
    GreenQuicInitCStateSupport(Dpdk);
}
"""
new = f"""    fclose(File);
    if (Dpdk->GreenQuicMode != GREENQUIC_MODE_OFF) {{
        GreenQuicReadPowerConfig(Dpdk);
        GreenQuicInitCStateSupport(Dpdk);
    }} else {{
        /* {MARK}: OFF ignores powermng.ini completely. */
        CxPlatGreenQuicPlusSetRuntimeEnabled(0);
    }}
}}
"""
text = replace_once(text, old, new, "skip power/idle initialization in OFF")

old = """    const BOOLEAN NeedRxQueueInterrupts =
        Dpdk->GreenQuicEnableRx &&
"""
new = f"""    const BOOLEAN NeedRxQueueInterrupts =
        /* {MARK}: OFF keeps the original polling NIC configuration. */
        Dpdk->GreenQuicMode != GREENQUIC_MODE_OFF &&
        Dpdk->GreenQuicEnableRx &&
"""
text = replace_once(text, old, new, "disable RX interrupt configuration in OFF")

pattern = re.compile(
    r"(static void\nGreenQuicSignalLcoreWork\s*\([^)]*\)\n\{\n)",
    re.DOTALL,
)
m = pattern.search(text)
if not m:
    raise SystemExit("ERROR: GreenQuicSignalLcoreWork not found")
signal_guard = f"""    /* {MARK} */
    if (Dpdk->GreenQuicMode == GREENQUIC_MODE_OFF) {{
        return;
    }}
"""
if MARK not in text[m.end():m.end()+180]:
    text = text[:m.end()] + signal_guard + text[m.end():]
    print("PATCH: disable wake signalling in OFF")
else:
    print("OK already patched: wake signalling")

old = """    const uint16_t BuffersCount =
        GreenQuicTrackedRxBurst(
            Interface->Port,
            QueueId,
            (struct rte_mbuf**)Buffers,
            Dpdk->RxBurstSize);
    GreenQuicOnRxPoll(Dpdk, Core, BuffersCount, RxQueueCountBefore);
"""
new = f"""    uint16_t BuffersCount;
    if (Dpdk->GreenQuicMode == GREENQUIC_MODE_OFF) {{
        /* {MARK}: original DPDK RX hot path. */
        BuffersCount = rte_eth_rx_burst(
            Interface->Port,
            QueueId,
            (struct rte_mbuf**)Buffers,
            Dpdk->RxBurstSize);
    }} else {{
        BuffersCount = GreenQuicTrackedRxBurst(
            Interface->Port,
            QueueId,
            (struct rte_mbuf**)Buffers,
            Dpdk->RxBurstSize);
        GreenQuicOnRxPoll(
            Dpdk, Core, BuffersCount, RxQueueCountBefore);
    }}
"""
text = replace_once(text, old, new, "use direct RX burst in OFF")

old = """        GreenQuicOnTxPoll(Dpdk, Core, 0, 0, 0);
        return;
"""
new = f"""        if (Dpdk->GreenQuicMode != GREENQUIC_MODE_OFF) {{
            GreenQuicOnTxPoll(Dpdk, Core, 0, 0, 0);
        }}
        return;
"""
text = replace_once(text, old, new, "skip non-owner TX hook in OFF")

old = """    if (unlikely(BufferCount == 0)) {
        GreenQuicOnTxPoll(Dpdk, Core, RingBefore, 0, 0);
        return;
    }
"""
new = f"""    if (unlikely(BufferCount == 0)) {{
        if (Dpdk->GreenQuicMode != GREENQUIC_MODE_OFF) {{
            GreenQuicOnTxPoll(Dpdk, Core, RingBefore, 0, 0);
        }}
        return;
    }}
"""
text = replace_once(text, old, new, "skip empty TX hook in OFF")

old = """    const uint16_t TxCount =
        GreenQuicTrackedTxBurst(Interface->Port, 0, Buffers, BufferCount);
"""
new = f"""    const uint16_t TxCount =
        Dpdk->GreenQuicMode == GREENQUIC_MODE_OFF ?
            /* {MARK}: original DPDK TX hot path. */
            rte_eth_tx_burst(Interface->Port, 0, Buffers, BufferCount) :
            GreenQuicTrackedTxBurst(
                Interface->Port, 0, Buffers, BufferCount);
"""
text = replace_once(text, old, new, "use direct TX burst in OFF")

old = """    Dpdk->TxCounter += TxCount;
    GreenQuicOnTxPoll(Dpdk, Core, RingBefore, BufferCount, TxCount);
"""
new = f"""    Dpdk->TxCounter += TxCount;
    if (Dpdk->GreenQuicMode != GREENQUIC_MODE_OFF) {{
        GreenQuicOnTxPoll(
            Dpdk, Core, RingBefore, BufferCount, TxCount);
    }}
"""
text = replace_once(text, old, new, "skip successful TX hook in OFF")

old = """        const uint16_t TxCount = GreenQuicTrackedTxBurst(Interface->Port, 0, &Buffer, 1);
"""
new = f"""        const uint16_t TxCount =
            Dpdk->GreenQuicMode == GREENQUIC_MODE_OFF ?
                /* {MARK}: original ARP TX path. */
                rte_eth_tx_burst(Interface->Port, 0, &Buffer, 1) :
                GreenQuicTrackedTxBurst(Interface->Port, 0, &Buffer, 1);
"""
text = replace_once(text, old, new, "use direct ARP TX burst in OFF")

old = """    GreenQuicPowerInit(Dpdk, Core);
    CxPlatGreenQuicPlusSetThreadLcore(Core);
"""
new = f"""    if (Dpdk->GreenQuicMode != GREENQUIC_MODE_OFF) {{
        /* {MARK} */
        GreenQuicPowerInit(Dpdk, Core);
        CxPlatGreenQuicPlusSetThreadLcore(Core);
    }}
"""
text = replace_all_exact(
    text, old, new, "skip GreenQUIC worker initialization in OFF", 4
)

old = """            GreenQuicApplyPolicy(Dpdk, Interface, Core);
"""
new = f"""            if (Dpdk->GreenQuicMode != GREENQUIC_MODE_OFF) {{
                /* {MARK} */
                GreenQuicApplyPolicy(Dpdk, Interface, Core);
            }}
"""
text = replace_all_exact(
    text, old, new, "remove policy call from OFF worker loops", 4
)

old = """    CxPlatGreenQuicPlusClearThreadLcore();
    GreenQuicPowerCleanup(Dpdk, Core);
    GreenQuicIdleCleanupLcore(GreenQuicGetLcoreState(Dpdk, Core));
"""
new = f"""    if (Dpdk->GreenQuicMode != GREENQUIC_MODE_OFF) {{
        /* {MARK} */
        CxPlatGreenQuicPlusClearThreadLcore();
        GreenQuicPowerCleanup(Dpdk, Core);
        GreenQuicIdleCleanupLcore(GreenQuicGetLcoreState(Dpdk, Core));
    }}
"""
text = replace_all_exact(
    text, old, new, "skip GreenQUIC worker cleanup in OFF", 4
)

for old, new, label in [
    (
        '    printf("Core %u RX worker running...\\n", Core);\n',
        f"""    if (Dpdk->GreenQuicMode != GREENQUIC_MODE_OFF) {{
        printf("Core %u RX worker running...\\n", Core);
    }}
""",
        "suppress RX GreenQUIC worker banner in OFF",
    ),
    (
        '    printf("Core %u TX worker running...\\n", Core);\n',
        f"""    if (Dpdk->GreenQuicMode != GREENQUIC_MODE_OFF) {{
        printf("Core %u TX worker running...\\n", Core);
    }}
""",
        "suppress TX GreenQUIC worker banner in OFF",
    ),
]:
    text = replace_once(text, old, new, label)

old = """    printf("[CPU %u] GreenQUIC WORKER role=rx_tx state=running\\n\\n", Core);
    fflush(stdout);
"""
new = f"""    if (Dpdk->GreenQuicMode != GREENQUIC_MODE_OFF) {{
        printf("[CPU %u] GreenQUIC WORKER role=rx_tx state=running\\n\\n", Core);
        fflush(stdout);
    }}
"""
text = replace_once(text, old, new, "suppress RX/TX GreenQUIC worker banner in OFF")

old = """    printf(
        "Core %u GreenQUIC worker running: rx=%u tx=%u rxq=%hu\\n",
        Core,
        GreenQuicLcoreOwnsRx(Dpdk, Core) ? 1U : 0U,
        GreenQuicLcoreOwnsTx(Dpdk, Core) ? 1U : 0U,
        GreenQuicGetQueueId(Dpdk, Core));
"""
new = f"""    if (Dpdk->GreenQuicMode != GREENQUIC_MODE_OFF) {{
        printf(
            "Core %u GreenQUIC worker running: rx=%u tx=%u rxq=%hu\\n",
            Core,
            GreenQuicLcoreOwnsRx(Dpdk, Core) ? 1U : 0U,
            GreenQuicLcoreOwnsTx(Dpdk, Core) ? 1U : 0U,
            GreenQuicGetQueueId(Dpdk, Core));
    }}
"""
text = replace_once(text, old, new, "suppress multicore GreenQUIC worker banner in OFF")

old = """    GreenQuicSignalTxWork(Dpdk);
    Dpdk->TxEnqueueCounter++; // increase in any case, even if packet was dropped
"""
new = f"""    if (Dpdk->GreenQuicMode != GREENQUIC_MODE_OFF) {{
        /* {MARK} */
        GreenQuicSignalTxWork(Dpdk);
    }}
    Dpdk->TxEnqueueCounter++; // increase in any case, even if packet was dropped
"""
text = replace_once(text, old, new, "remove TX wake call from OFF enqueue path")

text = text.replace(
    '"DPDK: GreenQuicTrackedTxBurst() failed to send all packets"',
    '"DPDK TX burst failed to send all packets"',
)

write(dpdk, text)

# ---------------------------------------------------------------------------
# Test suite: OFF does not request in-process transfer instrumentation and its
# powermng.ini explicitly records that GreenQUIC policy is disabled.
# ---------------------------------------------------------------------------
text = read(common)

old = """    local idle_mode="$EFFECTIVE_IDLE_MODE"
    local idle_fallback="$EFFECTIVE_IDLE_FALLBACK"
    local enable_cstate_idle="${ENABLE_CSTATE_IDLE:-0}"
    [[ "$idle_mode" == pause ]] && enable_cstate_idle=1
"""
new = f"""    local idle_mode="$EFFECTIVE_IDLE_MODE"
    local idle_fallback="$EFFECTIVE_IDLE_FALLBACK"
    local enable_cstate_idle="${{ENABLE_CSTATE_IDLE:-0}}"
    local effective_enable_freq="$ENABLE_FREQ"
    local effective_enable_sleep="$ENABLE_SLEEP"
    [[ "$idle_mode" == pause ]] && enable_cstate_idle=1
    if [[ "$mode" == off ]]; then
        # {MARK}: OFF config records no GreenQUIC power/idle policy.
        idle_mode=off
        idle_fallback=off
        enable_cstate_idle=0
        effective_enable_freq=0
        effective_enable_sleep=0
    fi
"""
text = replace_once(text, old, new, "materialize no-policy OFF powermng.ini")

text = replace_once(
    text,
    "GreenQuicEnableFreq=$ENABLE_FREQ\nGreenQuicEnableSleep=$ENABLE_SLEEP\n",
    "GreenQuicEnableFreq=$effective_enable_freq\nGreenQuicEnableSleep=$effective_enable_sleep\n",
    "write effective OFF frequency/sleep flags",
)

server_old = """    GQ_TRANSFER_WINDOW_FILE="$transfer_window"
    GQ_TRANSFER_ROLE=server
    export GQ_TRANSFER_WINDOW_FILE GQ_TRANSFER_ROLE
"""
server_new = f"""    if [[ "$mode" == off ]]; then
        # {MARK}: no per-burst clock/atomic instrumentation in strict OFF.
        unset GQ_TRANSFER_WINDOW_FILE GQ_TRANSFER_ROLE || true
    else
        GQ_TRANSFER_WINDOW_FILE="$transfer_window"
        GQ_TRANSFER_ROLE=server
        export GQ_TRANSFER_WINDOW_FILE GQ_TRANSFER_ROLE
    fi
"""
text = replace_once(text, server_old, server_new, "disable server transfer-window instrumentation in OFF")

client_old = """    GQ_TRANSFER_WINDOW_FILE="$transfer_window"
    GQ_TRANSFER_ROLE=client
    export GQ_TRANSFER_WINDOW_FILE GQ_TRANSFER_ROLE
"""
client_new = f"""    if [[ "$mode" == off ]]; then
        # {MARK}: no per-burst clock/atomic instrumentation in strict OFF.
        unset GQ_TRANSFER_WINDOW_FILE GQ_TRANSFER_ROLE || true
    else
        GQ_TRANSFER_WINDOW_FILE="$transfer_window"
        GQ_TRANSFER_ROLE=client
        export GQ_TRANSFER_WINDOW_FILE GQ_TRANSFER_ROLE
    fi
"""
text = replace_once(text, client_old, client_new, "disable client transfer-window instrumentation in OFF")

needle = """validate_runtime_log() {
    local role="$1" logf="$2" mode="$3" stamp="$4"
"""
replacement = needle + f"""    if [[ "$mode" == off ]]; then
        if grep -Eq \\
            'GreenQUIC lcore=|policy_action=(freq_max_control|freq_max_hard|freq_up|freq_down|freq_min|sleep|pause|monitor|epoll|keep_pause|short_idle_pause|txring_protect_up)' \\
            "$logf" 2>/dev/null; then
            printf '\\n[GreenQUIC-Test:ERROR] %s\\n' \\
                "Strict OFF validation failed: GreenQUIC policy activity appeared in $logf" >&2
            return 2
        fi
    fi
"""
text = replace_once(text, needle, replacement, "validate strict OFF policy bypass")

write(common, text)

print("\nAll strict-OFF source patches applied successfully.")
PY

# Permanently fix the DPDK static-library discovery used by bootstrap and
# greenquic-env.sh. Static DPDK installs contain individual librte_*.a files;
# they do not necessarily contain an aggregate libdpdk.a file.
python3 - "$ROOT" <<'PY_BUILD_ENV'
from pathlib import Path
import sys

root = Path(sys.argv[1])
bootstrap = root / "bootstrap_greenquic.sh"
env_file = root / "greenquic-env.sh"
mark = "GREENQUIC-DPDK-STATIC-LIBDIR-V1"


def patch_block(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text(encoding="utf-8")
    if mark in text:
        print(f"OK already patched: {label}")
        return
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            f"ERROR: {label}: expected exactly one build environment block, found {count}"
        )
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"PATCH: {label}")


old_bootstrap = r'''DPDK_LIB_DIR="$(find "$DPDK_INSTALL" -type f \( -name 'libdpdk.a' -o -name 'libdpdk.so' -o -name 'libdpdk.so.*' \) -printf '%h\n' | head -n 1)"
[[ -n "$DPDK_LIB_DIR" ]] || DPDK_LIB_DIR="$DPDK_INSTALL/lib"

export PKG_CONFIG_PATH="$DPDK_PC_DIR${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="$DPDK_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LIBRARY_PATH="$DPDK_LIB_DIR${LIBRARY_PATH:+:$LIBRARY_PATH}"
export CMAKE_PREFIX_PATH="$DPDK_INSTALL${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export PATH="$DPDK_INSTALL/bin:$DPDK_SRC/usertools:$PATH"
'''
new_bootstrap = r'''# GREENQUIC-DPDK-STATIC-LIBDIR-V1
# A static DPDK install is a directory of librte_*.a archives and may not
# contain an aggregate libdpdk.a archive.
DPDK_LIB_DIR="$(find "$DPDK_INSTALL" -type f -name 'librte_eal.a' -printf '%h\n' | head -n 1)"
if [[ -z "$DPDK_LIB_DIR" ]]; then
    DPDK_LIB_DIR="$(find "$DPDK_INSTALL" -type f \( -name 'libdpdk.a' -o -name 'libdpdk.so' -o -name 'libdpdk.so.*' \) -printf '%h\n' | head -n 1)"
fi
[[ -n "$DPDK_LIB_DIR" ]] || DPDK_LIB_DIR="$DPDK_INSTALL/lib"
[[ -f "$DPDK_LIB_DIR/librte_eal.a" ]] || {
    echo "ERROR: static DPDK libraries were not found under $DPDK_INSTALL" >&2
    exit 1
}

export PKG_CONFIG_PATH="$DPDK_PC_DIR${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="$DPDK_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LIBRARY_PATH="$DPDK_LIB_DIR${LIBRARY_PATH:+:$LIBRARY_PATH}"
export CMAKE_PREFIX_PATH="$DPDK_INSTALL${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export CMAKE_LIBRARY_PATH="$DPDK_LIB_DIR${CMAKE_LIBRARY_PATH:+:$CMAKE_LIBRARY_PATH}"
export PATH="$DPDK_INSTALL/bin:$DPDK_SRC/usertools:$PATH"
'''
patch_block(
    bootstrap,
    old_bootstrap,
    new_bootstrap,
    "bootstrap static DPDK library directory",
)

old_template = r'''_DPDK_LIB_DIR="$(find "$DPDK_INSTALL" -type f \( -name 'libdpdk.a' -o -name 'libdpdk.so' -o -name 'libdpdk.so.*' \) -printf '%h\n' 2>/dev/null | head -n 1)"
if [[ -n "$_DPDK_LIB_DIR" ]]; then
    export LD_LIBRARY_PATH="$_DPDK_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export LIBRARY_PATH="$_DPDK_LIB_DIR${LIBRARY_PATH:+:$LIBRARY_PATH}"
fi

export CMAKE_PREFIX_PATH="$DPDK_INSTALL${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
'''
new_template = r'''# GREENQUIC-DPDK-STATIC-LIBDIR-V1
_DPDK_LIB_DIR="$(find "$DPDK_INSTALL" -type f -name 'librte_eal.a' -printf '%h\n' 2>/dev/null | head -n 1)"
if [[ -z "$_DPDK_LIB_DIR" ]]; then
    _DPDK_LIB_DIR="$(find "$DPDK_INSTALL" -type f \( -name 'libdpdk.a' -o -name 'libdpdk.so' -o -name 'libdpdk.so.*' \) -printf '%h\n' 2>/dev/null | head -n 1)"
fi
if [[ -n "$_DPDK_LIB_DIR" ]]; then
    export LD_LIBRARY_PATH="$_DPDK_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export LIBRARY_PATH="$_DPDK_LIB_DIR${LIBRARY_PATH:+:$LIBRARY_PATH}"
    export CMAKE_LIBRARY_PATH="$_DPDK_LIB_DIR${CMAKE_LIBRARY_PATH:+:$CMAKE_LIBRARY_PATH}"
fi

export CMAKE_PREFIX_PATH="$DPDK_INSTALL${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
'''
patch_block(
    bootstrap,
    old_template,
    new_template,
    "generated greenquic-env.sh static DPDK library directory",
)
patch_block(
    env_file,
    old_template,
    new_template,
    "current greenquic-env.sh static DPDK library directory",
)
PY_BUILD_ENV

bash -n "$COMMON_SH" "$BOOTSTRAP" "$ENV_FILE"

if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$ROOT" diff --check
    echo
    echo "Changed files:"
    git -C "$ROOT" diff --stat -- \
        msquic/src/inc/greenquic_plus.h \
        msquic/src/platform/greenquic_plus.c \
        msquic/src/platform/datapath_raw_dpdk_linux.c \
        greenquic_test_suite_v22/common/bin/gq_common.sh
fi

if [[ "$NO_BUILD" != "--no-build" ]]; then
    [[ -f "$BUILD/CMakeCache.txt" ]] || {
        echo "ERROR: $BUILD is not configured. Run bootstrap_greenquic.sh first, or rerun this patch with --no-build." >&2
        exit 1
    }

    DPDK_INSTALL="$MSQUIC/deps/dpdk-install"
    DPDK_PC="$(find "$DPDK_INSTALL" -type f -name libdpdk.pc -print -quit)"
    [[ -n "$DPDK_PC" ]] || {
        echo "ERROR: libdpdk.pc not found under $DPDK_INSTALL" >&2
        exit 1
    }
    DPDK_PC_DIR="$(dirname "$DPDK_PC")"
    DPDK_LIB_DIR="$(find "$DPDK_INSTALL" -type f -name 'librte_eal.a' -printf '%h\n' | head -n 1)"
    [[ -n "$DPDK_LIB_DIR" ]] || {
        echo "ERROR: librte_eal.a not found under $DPDK_INSTALL" >&2
        exit 1
    }

    export PKG_CONFIG_PATH="$DPDK_PC_DIR${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    export LD_LIBRARY_PATH="$DPDK_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export LIBRARY_PATH="$DPDK_LIB_DIR${LIBRARY_PATH:+:$LIBRARY_PATH}"
    export CMAKE_PREFIX_PATH="$DPDK_INSTALL${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
    export CMAKE_LIBRARY_PATH="$DPDK_LIB_DIR${CMAKE_LIBRARY_PATH:+:$CMAKE_LIBRARY_PATH}"

    pkg-config --exists libdpdk || {
        echo "ERROR: pkg-config cannot resolve the local DPDK installation" >&2
        exit 1
    }
    [[ -f "$DPDK_LIB_DIR/librte_power.a" ]] || {
        echo "ERROR: DPDK static libraries are incomplete in $DPDK_LIB_DIR" >&2
        exit 1
    }

    echo
    echo "DPDK pkg-config: $DPDK_PC_DIR"
    echo "DPDK static libs: $DPDK_LIB_DIR"
    echo "Reconfiguring MsQuic with the local DPDK library directory..."

    cmake -S "$MSQUIC" -B "$BUILD" -G Ninja \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DCMAKE_PREFIX_PATH="$DPDK_INSTALL" \
        -DCMAKE_LIBRARY_PATH="$DPDK_LIB_DIR" \
        -DQUIC_TLS=openssl \
        -DQUIC_USE_SYSTEM_LIBCRYPTO=OFF \
        -DQUIC_LINUX_DPDK_ENABLED=ON \
        -DQUIC_LINUX_XDP_ENABLED=OFF \
        -DQUIC_BUILD_SHARED=OFF \
        -DQUIC_BUILD_TOOLS=ON \
        -DQUIC_BUILD_PERF=ON \
        -DQUIC_BUILD_TEST=OFF \
        -DQUIC_ENABLE_LOGGING=OFF

    echo "Rebuilding MsQuic targets..."
    cmake --build "$BUILD" \
        --target secnetperf quicinteropserver quicinterop \
        --parallel "$(nproc)"

    for binary in secnetperf quicinteropserver quicinterop; do
        [[ -x "$BUILD/bin/Release/$binary" ]] || {
            echo "ERROR: rebuilt binary is missing: $BUILD/bin/Release/$binary" >&2
            exit 1
        }
        echo "OK: $BUILD/bin/Release/$binary"
    done
fi

PATCH_COMPLETE=1
trap - EXIT

echo
echo "Strict OFF patch complete for: $ROOT"
echo "Backup: $BACKUP"
echo
echo "Verification markers:"
grep -n "GREENQUIC-STRICT-OFF-V1" \
    "$PLUS_H" "$PLUS_C" "$DPDK_FILE" "$COMMON_SH" | sed -n '1,40p'

echo
echo "Run OFF with a fresh process on both endpoints:"
echo "  GQ_LOG_LEVEL=0 GQ_MODE_OVERRIDE=off ./run_server.sh"
echo "  GQ_LOG_LEVEL=0 GQ_MODE_OVERRIDE=off ./run_client.sh"
echo
echo "Strict OFF intentionally disables the in-process DPDK transfer-window"
echo "instrumentation. OFF goodput remains available from the client/MsQuic timer,"
echo "but the first-RX-to-last-TX active-window section is unavailable for OFF."
