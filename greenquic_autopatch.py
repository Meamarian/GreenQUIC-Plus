#!/usr/bin/env python3
"""
greenquic_full_autopatch_v20_selectable_idle_modes.py

Full local GreenQUIC / GreenQUIC+ autopatcher with poll-count idle detection, conservative staged sleep, selectable runtime idle mechanisms (short, pause, monitor, epoll, auto), independent hint expiry, direction-separated RX/TX pressure paths, explicit RX-only/TX-only/RX+TX lcore roles, and checked single-core and optional multi-core paths.

What it does:
  1. asks for a Git URL or uses an existing repo
  2. clones locally under ./ and checks out a selected branch/tag/commit
  3. creates a new branch
  4. verifies the files expected by the GreenQUIC guide
  5. writes full GreenQUIC+ files
  6. patches the DPDK datapath with the GreenQUIC power-management algorithm
  7. patches ACK/CUBIC/app hooks for GreenQUIC+
  8. patches Linux-safe/Windows-safe DPDK EAL driver loading
  9. patches CMake for local or system DPDK
 10. optionally builds a local DPDK under ./deps without touching system libraries
 11. optionally builds MsQuic locally
 12. writes powermng.ini with every power-policy threshold, alpha, floor, DVFS timing and sleep level
 13. prints test commands and configuration examples, with logging disabled by default

Safety:
  - no sudo
  - no cmake --install
  - no writing into /usr/lib or Linux system libraries
  - creates .greenquic.bak backups before editing existing files
  - build happens inside the repository build directory

Important:
  This is a real full-code patcher, not only a skeleton. It still depends on the exact
  MsQuic branch and DPDK version. If an anchor does not match your branch, the script
  stops and tells you which file/anchor failed instead of guessing.

  V18 keeps the complete older implementation in this file. The final override
  gives RX burst, RX queue, TX burst and TX ring separate physical EWMAs. QUIC
  hints are short-lived configurable floors applied after those physical EWMAs,
  so semantic states do not contaminate physical history. RX and TX meet only at
  the final per-lcore action. RX-only, TX-only and RX+TX roles are supported, and
  BASIC-mode hint gate: ACK/CUBIC/application hints are forced to zero before
  both DVFS and idle decisions unless GreenQuicMode=plus.

  all power-policy values are loaded from powermng.ini. Older generated logic is
  retained in comments or #if 0 blocks instead of being deleted.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Iterable, List, Optional

RECOMMENDED_DPDK_CHECKOUT = "v21.11.9"  # DPDK 21.11 LTS final patch release; matches this branch's -21 ABI clue.
FALLBACK_DPDK_CHECKOUT = "v21.11"


# =============================================================================
# Logging and command helpers
# =============================================================================

def log(msg: str) -> None:
    print(f"\n[GreenQUIC] {msg}", flush=True)


def warn(msg: str) -> None:
    print(f"\n[GreenQUIC:WARN] {msg}", flush=True)


def die(msg: str, code: int = 1) -> None:
    print(f"\n[GreenQUIC:ERROR] {msg}", file=sys.stderr, flush=True)
    sys.exit(code)


def run(cmd: List[str], cwd: Optional[Path] = None, check: bool = True) -> subprocess.CompletedProcess:
    where = f" cwd={cwd}" if cwd else ""
    print(f"[cmd]{where}: {' '.join(cmd)}", flush=True)
    p = subprocess.run(cmd, cwd=str(cwd) if cwd else None, text=True)
    if check and p.returncode != 0:
        die(f"Command failed: {' '.join(cmd)}")
    return p


def capture(cmd: List[str], cwd: Optional[Path] = None, check: bool = True) -> str:
    p = subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and p.returncode != 0:
        if p.stdout:
            print(p.stdout)
        if p.stderr:
            print(p.stderr, file=sys.stderr)
        die(f"Command failed: {' '.join(cmd)}")
    return p.stdout.strip()


def ask(prompt: str, default: Optional[str] = None) -> str:
    suffix = f" [{default}]" if default is not None else ""
    ans = input(f"{prompt}{suffix}: ").strip()
    return ans if ans else (default or "")


def ask_yes(prompt: str, default: bool = False) -> bool:
    suffix = "Y/n" if default else "y/N"
    ans = input(f"{prompt} [{suffix}]: ").strip().lower()
    if not ans:
        return default
    return ans in ("y", "yes")


# =============================================================================
# File helpers
# =============================================================================

def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def backup(path: Path) -> None:
    bak = path.with_name(path.name + ".greenquic.bak")
    if not bak.exists():
        shutil.copy2(path, bak)
        log(f"Backup created: {bak}")


def ensure_file(path: Path) -> None:
    if not path.exists():
        die(f"Expected file not found: {path}")


def ensure_contains(path: Path, needles: Iterable[str]) -> None:
    text = read_text(path)
    missing = [n for n in needles if n not in text]
    if missing:
        die(f"{path} is missing expected anchor(s):\n" + "\n".join(missing))


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise RuntimeError(f"Anchor not found for {label}:\n{old[:500]}")
    return text.replace(old, new, 1)


def insert_after(text: str, anchor: str, insertion: str, label: str) -> str:
    if insertion.strip() and insertion.strip() in text:
        return text
    idx = text.find(anchor)
    if idx < 0:
        raise RuntimeError(f"Anchor not found for {label}:\n{anchor[:500]}")
    idx += len(anchor)
    return text[:idx] + insertion + text[idx:]


def insert_before(text: str, anchor: str, insertion: str, label: str) -> str:
    if insertion.strip() and insertion.strip() in text:
        return text
    idx = text.find(anchor)
    if idx < 0:
        raise RuntimeError(f"Anchor not found for {label}:\n{anchor[:500]}")
    return text[:idx] + insertion + text[idx:]


def write_new_or_replace(path: Path, text: str) -> None:
    if path.exists():
        backup(path)
    write_text(path, text)
    log(f"Wrote {path}")


# =============================================================================
# Full GreenQUIC code blocks
# =============================================================================

GREENQUIC_PLUS_H = r'''/*++

    GreenQUIC Plus public hint API.

    This header only defines names and prototypes.
    It does not store state and it does not decide CPU power policy.

    Threading model:
      - PulseHints is safe for short timing hints from different MsQuic worker threads.
      - BeginTransfer/EndTransfer use reference counters, so parallel transfers do not
        clear a transfer hint while another transfer is still active.

--*/

#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Short timing hints. These are set with PulseHints and expire automatically.
#define GQPLUS_HINT_ACK_PENDING             (1ull << 0)
#define GQPLUS_HINT_CUBIC_CWND_BLOCKED     (1ull << 1)
#define GQPLUS_HINT_CUBIC_RECOVERY         (1ull << 2)
#define GQPLUS_HINT_CUBIC_RAMPING          (1ull << 3)

// Long transfer hints. Use BeginTransfer/EndTransfer for these in application code.
#define GQPLUS_HINT_SERVER_FILE_TX_ACTIVE  (1ull << 16)
#define GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE  (1ull << 17)

void
CxPlatGreenQuicPlusSetHints(
    uint64_t Hints
    );

void
CxPlatGreenQuicPlusClearHints(
    uint64_t Hints
    );

void
CxPlatGreenQuicPlusBeginTransfer(
    uint64_t Hints
    );

void
CxPlatGreenQuicPlusEndTransfer(
    uint64_t Hints
    );

void
CxPlatGreenQuicPlusPulseHints(
    uint64_t Hints
    );

uint64_t
CxPlatGreenQuicPlusGetHints(
    void
    );

#ifdef __cplusplus
}
#endif
'''

GREENQUIC_PLUS_C = r'''/*++

    GreenQUIC Plus hint storage.

    Logic:
      - PersistentHints contains long-lived active states.
      - TransientHints contains short timing states, e.g., ACK pending.
      - Transfer hints are reference-counted so parallel transfers from different
        MsQuic/app threads do not incorrectly clear each other.
      - CxPlatGreenQuicPlusGetHints returns persistent and non-expired transient hints.

    No DPDK power policy is implemented here.

--*/

#define _POSIX_C_SOURCE 200809L

#include "greenquic_plus.h"

#include <stdatomic.h>
#include <stdint.h>
#include <time.h>

#define GQPLUS_TRANSIENT_TTL_NS (2ull * 1000ull * 1000ull) // 2 ms
#define GQPLUS_TRANSFER_HINTS (GQPLUS_HINT_SERVER_FILE_TX_ACTIVE | GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE)

static atomic_uint_fast64_t PersistentHints;
static atomic_uint_fast64_t TransientHints;
static atomic_uint_fast64_t TransientUntilNs;
static atomic_uint_fast32_t ServerFileTxActiveCount;
static atomic_uint_fast32_t ClientFileRxActiveCount;

static uint64_t
CxPlatGreenQuicPlusNowNs(
    void
    )
{
    struct timespec Ts;
#if defined(CLOCK_MONOTONIC_RAW)
    clock_gettime(CLOCK_MONOTONIC_RAW, &Ts);
#else
    clock_gettime(CLOCK_MONOTONIC, &Ts);
#endif
    return ((uint64_t)Ts.tv_sec * 1000000000ull) + (uint64_t)Ts.tv_nsec;
}

static void
CxPlatGreenQuicPlusIncrementHintCount(
    atomic_uint_fast32_t* Counter,
    uint64_t Hint
    )
{
    const uint_fast32_t Old = atomic_fetch_add_explicit(Counter, 1, memory_order_relaxed);
    if (Old == 0) {
        atomic_fetch_or_explicit(&PersistentHints, Hint, memory_order_release);
    }
}

static void
CxPlatGreenQuicPlusDecrementHintCount(
    atomic_uint_fast32_t* Counter,
    uint64_t Hint
    )
{
    uint_fast32_t Old = atomic_load_explicit(Counter, memory_order_relaxed);
    while (Old != 0) {
        if (atomic_compare_exchange_weak_explicit(
                Counter,
                &Old,
                Old - 1,
                memory_order_acq_rel,
                memory_order_relaxed)) {
            if (Old == 1) {
                atomic_fetch_and_explicit(&PersistentHints, ~Hint, memory_order_release);
            }
            return;
        }
    }
}

void
CxPlatGreenQuicPlusBeginTransfer(
    uint64_t Hints
    )
{
    if ((Hints & GQPLUS_HINT_SERVER_FILE_TX_ACTIVE) != 0) {
        CxPlatGreenQuicPlusIncrementHintCount(&ServerFileTxActiveCount, GQPLUS_HINT_SERVER_FILE_TX_ACTIVE);
    }
    if ((Hints & GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE) != 0) {
        CxPlatGreenQuicPlusIncrementHintCount(&ClientFileRxActiveCount, GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE);
    }
}

void
CxPlatGreenQuicPlusEndTransfer(
    uint64_t Hints
    )
{
    if ((Hints & GQPLUS_HINT_SERVER_FILE_TX_ACTIVE) != 0) {
        CxPlatGreenQuicPlusDecrementHintCount(&ServerFileTxActiveCount, GQPLUS_HINT_SERVER_FILE_TX_ACTIVE);
    }
    if ((Hints & GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE) != 0) {
        CxPlatGreenQuicPlusDecrementHintCount(&ClientFileRxActiveCount, GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE);
    }
}

void
CxPlatGreenQuicPlusSetHints(
    uint64_t Hints
    )
{
    // Kept for non-transfer persistent hints and backward compatibility.
    // Application file-transfer code should use BeginTransfer instead.
    atomic_fetch_or_explicit(&PersistentHints, Hints & ~GQPLUS_TRANSFER_HINTS, memory_order_relaxed);
    CxPlatGreenQuicPlusBeginTransfer(Hints & GQPLUS_TRANSFER_HINTS);
}

void
CxPlatGreenQuicPlusClearHints(
    uint64_t Hints
    )
{
    // Kept for non-transfer persistent hints and backward compatibility.
    // Application file-transfer code should use EndTransfer instead.
    atomic_fetch_and_explicit(&PersistentHints, ~(Hints & ~GQPLUS_TRANSFER_HINTS), memory_order_relaxed);
    CxPlatGreenQuicPlusEndTransfer(Hints & GQPLUS_TRANSFER_HINTS);
}

void
CxPlatGreenQuicPlusPulseHints(
    uint64_t Hints
    )
{
    const uint64_t Now = CxPlatGreenQuicPlusNowNs();
    atomic_fetch_or_explicit(&TransientHints, Hints, memory_order_relaxed);
    atomic_store_explicit(&TransientUntilNs, Now + GQPLUS_TRANSIENT_TTL_NS, memory_order_relaxed);
}

uint64_t
CxPlatGreenQuicPlusGetHints(
    void
    )
{
    const uint64_t Now = CxPlatGreenQuicPlusNowNs();
    const uint64_t Persistent = atomic_load_explicit(&PersistentHints, memory_order_acquire);
    const uint64_t Until = atomic_load_explicit(&TransientUntilNs, memory_order_relaxed);

    uint64_t Transient = 0;
    if (Now <= Until) {
        Transient = atomic_load_explicit(&TransientHints, memory_order_relaxed);
    } else {
        atomic_store_explicit(&TransientHints, 0, memory_order_relaxed);
    }

    return Persistent | Transient;
}
'''

DPDK_TYPES = r'''
// GREENQUIC-BEGIN: mode, profile and runtime state

#define DEFAULT_GREENQUIC_MODE                   GREENQUIC_MODE_OFF
#define DEFAULT_GREENQUIC_PROFILE                GREENQUIC_PROFILE_SYMMETRIC
#define DEFAULT_GREENQUIC_FREQ_PERIOD_US         100000U
#define DEFAULT_GREENQUIC_FREQ_UP_PERIOD_US      1000U
#define DEFAULT_GREENQUIC_FREQ_DOWN_PERIOD_US    5000U
#define DEFAULT_GREENQUIC_FREQ_MIN_IDLE_US       20000U
#define DEFAULT_GREENQUIC_RX_EMPTY_POLLS         50000U
#define DEFAULT_GREENQUIC_TX_EMPTY_POLLS         50000U
#define DEFAULT_GREENQUIC_RX_QUEUE_HIGH          64U
#define DEFAULT_GREENQUIC_RX_QUEUE_SAMPLE_PERIOD 64U
#define DEFAULT_GREENQUIC_TX_RING_HIGH           64U
#define DEFAULT_GREENQUIC_PRESSURE_MAX           900U
#define DEFAULT_GREENQUIC_PRESSURE_UP            600U
#define DEFAULT_GREENQUIC_PRESSURE_KEEP          200U
#define DEFAULT_GREENQUIC_FULL_BURST_MAX_COUNT   8U
#define DEFAULT_GREENQUIC_EWMA_RISE_SHIFT        1U
#define DEFAULT_GREENQUIC_EWMA_FALL_SHIFT        3U
#define DEFAULT_GREENQUIC_ACK_SLEEP_US           2U
#define DEFAULT_GREENQUIC_DATA_SLEEP_US          0U
#define DEFAULT_GREENQUIC_MAX_SLEEP_US           5U
#define DEFAULT_GREENQUIC_STATS_PERIOD_US        0U
#define DEFAULT_GREENQUIC_LOG_LEVEL              0U
#define DEFAULT_GREENQUIC_ENABLE_FREQ            TRUE
#define DEFAULT_GREENQUIC_ENABLE_SLEEP           FALSE
#define DEFAULT_GREENQUIC_NO_SLEEP_TX_RING       TRUE

#define GREENQUIC_PRESSURE_SCALE                 1000U

typedef enum GREENQUIC_MODE {
    GREENQUIC_MODE_OFF = 0,
    GREENQUIC_MODE_BASIC = 1,
    GREENQUIC_MODE_PLUS = 2
} GREENQUIC_MODE;

typedef enum GREENQUIC_PROFILE {
    GREENQUIC_PROFILE_SYMMETRIC = 0,
    GREENQUIC_PROFILE_SERVER_DOWNLOAD = 1,
    GREENQUIC_PROFILE_CLIENT_DOWNLOAD = 2,
    GREENQUIC_PROFILE_SERVER_UPLOAD = 3,
    GREENQUIC_PROFILE_CLIENT_UPLOAD = 4
} GREENQUIC_PROFILE;

typedef enum GREENQUIC_DIR {
    GREENQUIC_DIR_RX = 0,
    GREENQUIC_DIR_TX = 1
} GREENQUIC_DIR;

typedef struct GREENQUIC_DIR_STATE {
    uint64_t Polls;
    uint64_t EmptyPolls;
    uint64_t FullBursts;
    uint64_t Packets;
    uint64_t LastActiveTsc;
    uint32_t ConsecutiveEmpty;
    uint32_t ConsecutiveFull;
    uint32_t LastQueueCount;      // RX descriptor count when available, otherwise last burst count; TX ring count
    uint32_t LastBurstCount;      // RX/TX burst size from the last poll
    uint32_t QueueSampleCountdown; // RX queue count is sampled, not read every poll
} GREENQUIC_DIR_STATE;

typedef struct GREENQUIC_LCORE_STATE {
    GREENQUIC_DIR_STATE Rx;
    GREENQUIC_DIR_STATE Tx;
    uint64_t LastFreqMaxTsc;
    uint64_t LastFreqUpTsc;
    uint64_t LastFreqDownTsc;
    uint64_t LastStatsTsc;
    uint64_t TotalSleepUs;
    uint32_t PressureAvg;
    uint32_t LastRawPressure;
    uint32_t LastRxPressure;
    uint32_t LastTxPressure;
    uint32_t LastPlusPressure;
    uint32_t LastTxRingCount;
    uint64_t LastHints;
    BOOLEAN LastHardMax;
    const char* LastAction;
    BOOLEAN PowerInitialized;
    BOOLEAN PowerAvailable;
    BOOLEAN FreqIsMax;
} GREENQUIC_LCORE_STATE;

// GREENQUIC-END
'''

DPDK_DATAPATH_FIELDS = r'''

    // GREENQUIC-BEGIN: runtime configuration and per-lcore policy state
    GREENQUIC_MODE GreenQuicMode;
    GREENQUIC_PROFILE GreenQuicProfile;
    uint32_t GreenQuicFreqPeriodUs;       // backward-compatible fallback, also used as default down period
    uint32_t GreenQuicFreqUpPeriodUs;     // fast step-up throttle
    uint32_t GreenQuicFreqDownPeriodUs;   // slow step-down throttle
    uint32_t GreenQuicFreqMinIdleUs;      // long idle before forcing min frequency
    uint32_t GreenQuicRxEmptyPollThreshold;
    uint32_t GreenQuicTxEmptyPollThreshold;
    uint32_t GreenQuicRxQueueHigh;
    uint32_t GreenQuicRxQueueSamplePeriod;
    uint32_t GreenQuicTxRingHigh;
    uint32_t GreenQuicPressureMaxThreshold;
    uint32_t GreenQuicPressureUpThreshold;
    uint32_t GreenQuicPressureKeepThreshold;
    uint32_t GreenQuicFullBurstMaxCount;
    uint32_t GreenQuicEwmaRiseShift;
    uint32_t GreenQuicEwmaFallShift;
    uint32_t GreenQuicAckPathMaxSleepUs;
    uint32_t GreenQuicDataPathMaxSleepUs;
    uint32_t GreenQuicMaxSleepUs;
    uint32_t GreenQuicStatsPeriodUs;
    uint32_t GreenQuicLogLevel;      // 0=off, 1=summary, 2=verbose
    char GreenQuicDpdkLcores[64];    // optional EAL -l string, e.g., "8" or "8,9"; no multi-queue magic
    BOOLEAN GreenQuicEnableFreq;
    BOOLEAN GreenQuicEnableSleep;
    BOOLEAN GreenQuicNoSleepIfTxRingNotEmpty;
    GREENQUIC_LCORE_STATE GreenQuicLcore[RTE_MAX_LCORE];
    // GREENQUIC-END
'''

DPDK_PROTOTYPES = r'''
// GREENQUIC-BEGIN: helper prototypes
static void GreenQuicSetDefaults(_Inout_ DPDK_DATAPATH* Dpdk);
static const char* GreenQuicModeToString(_In_ GREENQUIC_MODE Mode);
static const char* GreenQuicProfileToString(_In_ GREENQUIC_PROFILE Profile);
static uint64_t GreenQuicTscDeltaToUs(_In_ uint64_t DeltaTsc);
static uint32_t GreenQuicMinU32(_In_ uint32_t A, _In_ uint32_t B);
static uint32_t GreenQuicMaxU32(_In_ uint32_t A, _In_ uint32_t B);
static uint32_t GreenQuicPressureFromRatio(_In_ uint64_t Value, _In_ uint64_t High);
static uint32_t GreenQuicUpdateEwma(_In_ uint32_t Avg, _In_ uint32_t Raw, _In_ uint32_t RiseShift, _In_ uint32_t FallShift);
static BOOLEAN GreenQuicIsDataPath(_In_ const DPDK_DATAPATH* Dpdk, _In_ GREENQUIC_DIR Dir);
static GREENQUIC_LCORE_STATE* GreenQuicGetLcoreState(_Inout_ DPDK_DATAPATH* Dpdk, _In_ uint16_t Core);
static void GreenQuicPowerInit(_Inout_ DPDK_DATAPATH* Dpdk, _In_ uint16_t Core);
static void GreenQuicPowerCleanup(_Inout_ DPDK_DATAPATH* Dpdk, _In_ uint16_t Core);
static void GreenQuicFreqMax(_Inout_ DPDK_DATAPATH* Dpdk, _In_ uint16_t Core);
static void GreenQuicFreqUpStep(_Inout_ DPDK_DATAPATH* Dpdk, _In_ uint16_t Core);
static void GreenQuicFreqDownStep(_Inout_ DPDK_DATAPATH* Dpdk, _In_ uint16_t Core);
static void GreenQuicFreqMin(_Inout_ DPDK_DATAPATH* Dpdk, _In_ uint16_t Core);
static void GreenQuicSleepUs(_Inout_ DPDK_DATAPATH* Dpdk, _In_ uint16_t Core, _In_ uint32_t SleepUs);
static uint32_t GreenQuicGetSleepBudgetUs(_In_ const DPDK_DATAPATH* Dpdk);
static void GreenQuicOnRxPoll(_Inout_ DPDK_DATAPATH* Dpdk, _In_ uint16_t Core, _In_ uint16_t BuffersCount, _In_ int RxQueueCountBefore);
static void GreenQuicOnTxPoll(_Inout_ DPDK_DATAPATH* Dpdk, _In_ uint16_t Core, _In_ uint32_t RingBefore, _In_ uint16_t BufferCount, _In_ uint16_t TxCount);
static BOOLEAN GreenQuicPlusHasActiveTransferHint(_In_ const DPDK_DATAPATH* Dpdk, _In_ uint64_t Hints);
static uint32_t GreenQuicPlusPressure(_In_ const DPDK_DATAPATH* Dpdk, _In_ uint64_t Hints, _In_ uint32_t RxPressure, _In_ uint32_t TxPressure, _Out_ BOOLEAN* HardMax);
static uint32_t GreenQuicComputeRawPressure(_In_ const DPDK_DATAPATH* Dpdk, _In_ GREENQUIC_LCORE_STATE* S, _In_ uint32_t TxRingCount, _Out_ BOOLEAN* HardMax);
static void GreenQuicApplyPolicy(_Inout_ DPDK_DATAPATH* Dpdk, _In_ DPDK_INTERFACE* Interface, _In_ uint16_t Core);
static void GreenQuicMaybePrintStats(_Inout_ DPDK_DATAPATH* Dpdk, _In_ uint16_t Core);
// GREENQUIC-END
'''

DPDK_HELPERS = r'''
// GREENQUIC-BEGIN: helper implementations

static void
GreenQuicSetDefaults(
    _Inout_ DPDK_DATAPATH* Dpdk
    )
{
    Dpdk->GreenQuicMode = DEFAULT_GREENQUIC_MODE;
    Dpdk->GreenQuicProfile = DEFAULT_GREENQUIC_PROFILE;
    Dpdk->GreenQuicFreqPeriodUs = DEFAULT_GREENQUIC_FREQ_PERIOD_US;
    Dpdk->GreenQuicFreqUpPeriodUs = DEFAULT_GREENQUIC_FREQ_UP_PERIOD_US;
    Dpdk->GreenQuicFreqDownPeriodUs = DEFAULT_GREENQUIC_FREQ_DOWN_PERIOD_US;
    Dpdk->GreenQuicFreqMinIdleUs = DEFAULT_GREENQUIC_FREQ_MIN_IDLE_US;
    Dpdk->GreenQuicRxEmptyPollThreshold = DEFAULT_GREENQUIC_RX_EMPTY_POLLS;
    Dpdk->GreenQuicTxEmptyPollThreshold = DEFAULT_GREENQUIC_TX_EMPTY_POLLS;
    Dpdk->GreenQuicRxQueueHigh = DEFAULT_GREENQUIC_RX_QUEUE_HIGH;
    Dpdk->GreenQuicRxQueueSamplePeriod = DEFAULT_GREENQUIC_RX_QUEUE_SAMPLE_PERIOD;
    Dpdk->GreenQuicTxRingHigh = DEFAULT_GREENQUIC_TX_RING_HIGH;
    Dpdk->GreenQuicPressureMaxThreshold = DEFAULT_GREENQUIC_PRESSURE_MAX;
    Dpdk->GreenQuicPressureUpThreshold = DEFAULT_GREENQUIC_PRESSURE_UP;
    Dpdk->GreenQuicPressureKeepThreshold = DEFAULT_GREENQUIC_PRESSURE_KEEP;
    Dpdk->GreenQuicFullBurstMaxCount = DEFAULT_GREENQUIC_FULL_BURST_MAX_COUNT;
    Dpdk->GreenQuicEwmaRiseShift = DEFAULT_GREENQUIC_EWMA_RISE_SHIFT;
    Dpdk->GreenQuicEwmaFallShift = DEFAULT_GREENQUIC_EWMA_FALL_SHIFT;
    Dpdk->GreenQuicAckPathMaxSleepUs = DEFAULT_GREENQUIC_ACK_SLEEP_US;
    Dpdk->GreenQuicDataPathMaxSleepUs = DEFAULT_GREENQUIC_DATA_SLEEP_US;
    Dpdk->GreenQuicMaxSleepUs = DEFAULT_GREENQUIC_MAX_SLEEP_US;
    Dpdk->GreenQuicStatsPeriodUs = DEFAULT_GREENQUIC_STATS_PERIOD_US;
    Dpdk->GreenQuicLogLevel = DEFAULT_GREENQUIC_LOG_LEVEL;
    Dpdk->GreenQuicDpdkLcores[0] = '\0';
    Dpdk->GreenQuicEnableFreq = DEFAULT_GREENQUIC_ENABLE_FREQ;
    Dpdk->GreenQuicEnableSleep = DEFAULT_GREENQUIC_ENABLE_SLEEP;
    Dpdk->GreenQuicNoSleepIfTxRingNotEmpty = DEFAULT_GREENQUIC_NO_SLEEP_TX_RING;
    CxPlatZeroMemory(Dpdk->GreenQuicLcore, sizeof(Dpdk->GreenQuicLcore));
}

static const char*
GreenQuicModeToString(
    _In_ GREENQUIC_MODE Mode
    )
{
    switch (Mode) {
    case GREENQUIC_MODE_OFF: return "off";
    case GREENQUIC_MODE_BASIC: return "basic";
    case GREENQUIC_MODE_PLUS: return "plus";
    default: return "unknown";
    }
}

static const char*
GreenQuicProfileToString(
    _In_ GREENQUIC_PROFILE Profile
    )
{
    switch (Profile) {
    case GREENQUIC_PROFILE_SYMMETRIC: return "symmetric";
    case GREENQUIC_PROFILE_SERVER_DOWNLOAD: return "server_download";
    case GREENQUIC_PROFILE_CLIENT_DOWNLOAD: return "client_download";
    case GREENQUIC_PROFILE_SERVER_UPLOAD: return "server_upload";
    case GREENQUIC_PROFILE_CLIENT_UPLOAD: return "client_upload";
    default: return "unknown";
    }
}

static uint64_t
GreenQuicTscDeltaToUs(
    _In_ uint64_t DeltaTsc
    )
{
    const uint64_t Hz = rte_get_tsc_hz();
    if (Hz == 0) {
        return 0;
    }
    return (DeltaTsc * 1000000ull) / Hz;
}

static uint32_t
GreenQuicMinU32(
    _In_ uint32_t A,
    _In_ uint32_t B
    )
{
    return A < B ? A : B;
}

static uint32_t
GreenQuicMaxU32(
    _In_ uint32_t A,
    _In_ uint32_t B
    )
{
    return A > B ? A : B;
}

static uint32_t
GreenQuicPressureFromRatio(
    _In_ uint64_t Value,
    _In_ uint64_t High
    )
{
    if (Value == 0 || High == 0) {
        return 0;
    }
    const uint64_t Score = (Value * GREENQUIC_PRESSURE_SCALE) / High;
    return Score > GREENQUIC_PRESSURE_SCALE ? GREENQUIC_PRESSURE_SCALE : (uint32_t)Score;
}

static uint32_t
GreenQuicUpdateEwma(
    _In_ uint32_t Avg,
    _In_ uint32_t Raw,
    _In_ uint32_t RiseShift,
    _In_ uint32_t FallShift
    )
{
    if (Raw > GREENQUIC_PRESSURE_SCALE) {
        Raw = GREENQUIC_PRESSURE_SCALE;
    }
    if (Avg > GREENQUIC_PRESSURE_SCALE) {
        Avg = GREENQUIC_PRESSURE_SCALE;
    }

    if (Raw > Avg) {
        const uint32_t Delta = Raw - Avg;
        uint32_t Step = RiseShift >= 31 ? Delta : (Delta >> RiseShift);
        if (Step == 0 && Delta != 0) {
            Step = 1;
        }
        return GreenQuicMinU32(GREENQUIC_PRESSURE_SCALE, Avg + Step);
    }

    const uint32_t Delta = Avg - Raw;
    uint32_t Step = FallShift >= 31 ? 0 : (Delta >> FallShift);
    if (Step == 0 && Delta != 0) {
        Step = 1;
    }
    return Avg > Step ? Avg - Step : 0;
}

static BOOLEAN
GreenQuicIsDataPath(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ GREENQUIC_DIR Dir
    )
{
    if (Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_SYMMETRIC) {
        return TRUE;
    }

    if (Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_SERVER_DOWNLOAD) {
        return Dir == GREENQUIC_DIR_TX;
    }

    if (Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_CLIENT_DOWNLOAD) {
        return Dir == GREENQUIC_DIR_RX;
    }

    if (Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_SERVER_UPLOAD) {
        return Dir == GREENQUIC_DIR_RX;
    }

    if (Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_CLIENT_UPLOAD) {
        return Dir == GREENQUIC_DIR_TX;
    }

    return TRUE;
}

static GREENQUIC_LCORE_STATE*
GreenQuicGetLcoreState(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_ uint16_t Core
    )
{
    if (Core < RTE_MAX_LCORE) {
        return &Dpdk->GreenQuicLcore[Core];
    }
    return &Dpdk->GreenQuicLcore[0];
}

static void
GreenQuicPowerInit(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_ uint16_t Core
    )
{
    GREENQUIC_LCORE_STATE* S = GreenQuicGetLcoreState(Dpdk, Core);
    if (Dpdk->GreenQuicMode == GREENQUIC_MODE_OFF || !Dpdk->GreenQuicEnableFreq || S->PowerInitialized) {
        return;
    }

    S->PowerInitialized = TRUE;
    if (rte_power_init(Core) == 0) {
        S->PowerAvailable = TRUE;
        const int Ret = rte_power_freq_max(Core);
        if (Ret >= 0) {
            S->FreqIsMax = TRUE;
            S->LastFreqMaxTsc = rte_get_tsc_cycles();
        }
    } else {
        S->PowerAvailable = FALSE;
        S->FreqIsMax = FALSE;
        printf("GreenQUIC: rte_power_init failed on lcore %u; frequency scaling disabled on this lcore.\n", Core);
    }
}

static void
GreenQuicPowerCleanup(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_ uint16_t Core
    )
{
    GREENQUIC_LCORE_STATE* S = GreenQuicGetLcoreState(Dpdk, Core);

    if (S->PowerInitialized && S->PowerAvailable) {
        rte_power_freq_max(Core);
        rte_power_exit(Core);
    }

    S->PowerInitialized = FALSE;
    S->PowerAvailable = FALSE;
    S->FreqIsMax = FALSE;
}

static void
GreenQuicFreqMax(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_ uint16_t Core
    )
{
    if (!Dpdk->GreenQuicEnableFreq) {
        return;
    }

    GREENQUIC_LCORE_STATE* S = GreenQuicGetLcoreState(Dpdk, Core);
    if (!S->PowerAvailable || S->FreqIsMax) {
        return;
    }

    // Hard max is intentionally immediate: backlog, full bursts, recovery, or strong QUIC hints.
    const int Ret = rte_power_freq_max(Core);
    if (Ret >= 0) {
        S->FreqIsMax = TRUE;
        S->LastFreqMaxTsc = rte_get_tsc_cycles();
    } else {
        S->PowerAvailable = FALSE;
    }
}

static void
GreenQuicFreqUpStep(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_ uint16_t Core
    )
{
    if (!Dpdk->GreenQuicEnableFreq) {
        return;
    }

    GREENQUIC_LCORE_STATE* S = GreenQuicGetLcoreState(Dpdk, Core);
    if (!S->PowerAvailable || S->FreqIsMax) {
        return;
    }

    const uint64_t Now = rte_get_tsc_cycles();
    if (S->LastFreqUpTsc != 0 &&
        GreenQuicTscDeltaToUs(Now - S->LastFreqUpTsc) < Dpdk->GreenQuicFreqUpPeriodUs) {
        return;
    }

    const int Ret = rte_power_freq_up(Core);
    if (Ret >= 0) {
        S->LastFreqUpTsc = Now;
        S->FreqIsMax = FALSE;
    } else {
        S->PowerAvailable = FALSE;
    }
}

static void
GreenQuicFreqDownStep(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_ uint16_t Core
    )
{
    if (!Dpdk->GreenQuicEnableFreq) {
        return;
    }

    GREENQUIC_LCORE_STATE* S = GreenQuicGetLcoreState(Dpdk, Core);
    if (!S->PowerAvailable) {
        return;
    }

    const uint64_t Now = rte_get_tsc_cycles();
    if (S->LastFreqDownTsc != 0 &&
        GreenQuicTscDeltaToUs(Now - S->LastFreqDownTsc) < Dpdk->GreenQuicFreqDownPeriodUs) {
        return;
    }

    const int Ret = rte_power_freq_down(Core);
    if (Ret >= 0) {
        S->FreqIsMax = FALSE;
        S->LastFreqDownTsc = Now;
    } else {
        S->PowerAvailable = FALSE;
    }
}

static void
GreenQuicFreqMin(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_ uint16_t Core
    )
{
    if (!Dpdk->GreenQuicEnableFreq) {
        return;
    }

    GREENQUIC_LCORE_STATE* S = GreenQuicGetLcoreState(Dpdk, Core);
    if (!S->PowerAvailable) {
        return;
    }

    const uint64_t Now = rte_get_tsc_cycles();
    if (S->LastFreqDownTsc != 0 &&
        GreenQuicTscDeltaToUs(Now - S->LastFreqDownTsc) < Dpdk->GreenQuicFreqDownPeriodUs) {
        return;
    }

    const int Ret = rte_power_freq_min(Core);
    if (Ret >= 0) {
        S->FreqIsMax = FALSE;
        S->LastFreqDownTsc = Now;
    } else {
        S->PowerAvailable = FALSE;
    }
}

static void
GreenQuicSleepUs(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_ uint16_t Core,
    _In_ uint32_t SleepUs
    )
{
    if (!Dpdk->GreenQuicEnableSleep || SleepUs == 0) {
        return;
    }

    if (SleepUs > Dpdk->GreenQuicMaxSleepUs) {
        SleepUs = Dpdk->GreenQuicMaxSleepUs;
    }

    rte_delay_us_sleep(SleepUs);
    GreenQuicGetLcoreState(Dpdk, Core)->TotalSleepUs += SleepUs;
}

static uint32_t
GreenQuicGetSleepBudgetUs(
    _In_ const DPDK_DATAPATH* Dpdk
    )
{
    if (GreenQuicIsDataPath(Dpdk, GREENQUIC_DIR_RX) || GreenQuicIsDataPath(Dpdk, GREENQUIC_DIR_TX)) {
        return Dpdk->GreenQuicDataPathMaxSleepUs;
    }
    return Dpdk->GreenQuicAckPathMaxSleepUs;
}

static void
GreenQuicOnRxPoll(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_ uint16_t Core,
    _In_ uint16_t BuffersCount,
    _In_ int RxQueueCountBefore
    )
{
    if (Dpdk->GreenQuicMode == GREENQUIC_MODE_OFF) {
        return;
    }

    GREENQUIC_DIR_STATE* Rx = &GreenQuicGetLcoreState(Dpdk, Core)->Rx;
    Rx->Polls++;
    Rx->LastBurstCount = BuffersCount;
    Rx->LastQueueCount = RxQueueCountBefore > 0 ? (uint32_t)RxQueueCountBefore : BuffersCount;

    if (BuffersCount == 0) {
        Rx->EmptyPolls++;
        Rx->ConsecutiveEmpty++;
        Rx->ConsecutiveFull = 0;
        return;
    }

    Rx->Packets += BuffersCount;
    if (BuffersCount == RX_BURST_SIZE) {
        Rx->FullBursts++;
        Rx->ConsecutiveFull++;
    } else {
        Rx->ConsecutiveFull = 0;
    }
    Rx->ConsecutiveEmpty = 0;
    Rx->LastActiveTsc = rte_get_tsc_cycles();
}

static void
GreenQuicOnTxPoll(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_ uint16_t Core,
    _In_ uint32_t RingBefore,
    _In_ uint16_t BufferCount,
    _In_ uint16_t TxCount
    )
{
    if (Dpdk->GreenQuicMode == GREENQUIC_MODE_OFF) {
        return;
    }

    GREENQUIC_DIR_STATE* Tx = &GreenQuicGetLcoreState(Dpdk, Core)->Tx;
    Tx->Polls++;
    Tx->LastQueueCount = RingBefore;
    Tx->LastBurstCount = BufferCount;

    if (RingBefore == 0 && BufferCount == 0 && TxCount == 0) {
        Tx->EmptyPolls++;
        Tx->ConsecutiveEmpty++;
        Tx->ConsecutiveFull = 0;
        return;
    }

    Tx->Packets += TxCount;
    if (BufferCount == TX_BURST_SIZE) {
        Tx->FullBursts++;
        Tx->ConsecutiveFull++;
    } else {
        Tx->ConsecutiveFull = 0;
    }
    Tx->ConsecutiveEmpty = 0;
    Tx->LastActiveTsc = rte_get_tsc_cycles();
}

static BOOLEAN
GreenQuicPlusHasActiveTransferHint(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ uint64_t Hints
    )
{
    if (Dpdk->GreenQuicMode != GREENQUIC_MODE_PLUS || Hints == 0) {
        return FALSE;
    }

    if ((Hints & GQPLUS_HINT_SERVER_FILE_TX_ACTIVE) != 0 &&
        (Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_SERVER_DOWNLOAD ||
         Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_SYMMETRIC)) {
        return TRUE;
    }

    if ((Hints & GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE) != 0 &&
        (Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_CLIENT_DOWNLOAD ||
         Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_SYMMETRIC)) {
        return TRUE;
    }

    return FALSE;
}

static uint32_t
GreenQuicPlusPressure(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ uint64_t Hints,
    _In_ uint32_t RxPressure,
    _In_ uint32_t TxPressure,
    _Out_ BOOLEAN* HardMax
    )
{
    uint32_t AckPressure = 0;
    uint32_t CubicPressure = 0;
    uint32_t AppPressure = 0;

    *HardMax = FALSE;

    if (Dpdk->GreenQuicMode != GREENQUIC_MODE_PLUS || Hints == 0) {
        return 0;
    }

    // ACKs are timing-sensitive, but for energy saving they should not force max by themselves.
    // They become hard-max only when the real receive side is already under high pressure.
    if ((Hints & GQPLUS_HINT_ACK_PENDING) != 0) {
        AckPressure =
            Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_CLIENT_DOWNLOAD ? 700U : 550U;
        if (Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_CLIENT_DOWNLOAD &&
            RxPressure >= Dpdk->GreenQuicPressureMaxThreshold) {
            *HardMax = TRUE;
        }
    }

    if ((Hints & GQPLUS_HINT_CUBIC_RECOVERY) != 0) {
        // Loss recovery is urgent: keep this as a direct max-frequency event.
        CubicPressure = 1000U;
        *HardMax = TRUE;
    } else if ((Hints & GQPLUS_HINT_CUBIC_RAMPING) != 0) {
        // A boolean ramping hint means the congestion window grew, but not how strongly.
        // Treat it as step-up pressure, not hard max, so long 8GB transfers can still save energy.
        CubicPressure = 650U;
    } else if ((Hints & GQPLUS_HINT_CUBIC_CWND_BLOCKED) != 0) {
        CubicPressure = 700U;
    }

    // File-transfer hints identify the active direction. They must not create a constant
    // pressure floor. Otherwise PLUS mode stays too hot for the whole 8GB download.
    if ((Hints & GQPLUS_HINT_SERVER_FILE_TX_ACTIVE) != 0 &&
        (Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_SERVER_DOWNLOAD ||
         Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_SYMMETRIC)) {
        AppPressure = GreenQuicMaxU32(AppPressure, TxPressure);
        if (TxPressure >= Dpdk->GreenQuicPressureMaxThreshold) {
            *HardMax = TRUE;
        }
    }

    if ((Hints & GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE) != 0 &&
        (Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_CLIENT_DOWNLOAD ||
         Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_SYMMETRIC)) {
        AppPressure = GreenQuicMaxU32(AppPressure, RxPressure);
        if (RxPressure >= Dpdk->GreenQuicPressureMaxThreshold) {
            *HardMax = TRUE;
        }
    }

    return GreenQuicMaxU32(AppPressure, GreenQuicMaxU32(AckPressure, CubicPressure));
}

static uint32_t
GreenQuicComputeRawPressure(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ GREENQUIC_LCORE_STATE* S,
    _In_ uint32_t TxRingCount,
    _Out_ BOOLEAN* HardMax
    )
{
    const uint32_t RxBurstPressure = GreenQuicPressureFromRatio(S->Rx.LastBurstCount, RX_BURST_SIZE);
    const uint32_t RxQueuePressure = GreenQuicPressureFromRatio(S->Rx.LastQueueCount, Dpdk->GreenQuicRxQueueHigh);
    uint32_t RxPressure = GreenQuicMaxU32(RxBurstPressure, RxQueuePressure);

    const uint32_t TxBurstPressure = GreenQuicPressureFromRatio(S->Tx.LastBurstCount, TX_BURST_SIZE);
    uint32_t TxPressure = GreenQuicPressureFromRatio(TxRingCount, Dpdk->GreenQuicTxRingHigh);
    TxPressure = GreenQuicMaxU32(TxPressure, GreenQuicPressureFromRatio(S->Tx.LastQueueCount, Dpdk->GreenQuicTxRingHigh));
    TxPressure = GreenQuicMaxU32(TxPressure, TxBurstPressure);

    *HardMax = FALSE;

    // Repeated full bursts mean pressure, but not necessarily hard max by themselves.
    // Hard max is reserved for repeated full bursts combined with queue/backlog pressure.
    if (S->Rx.ConsecutiveFull >= Dpdk->GreenQuicFullBurstMaxCount) {
        RxPressure = GreenQuicMaxU32(RxPressure, Dpdk->GreenQuicPressureUpThreshold);
    }
    if (S->Tx.ConsecutiveFull >= Dpdk->GreenQuicFullBurstMaxCount) {
        TxPressure = GreenQuicMaxU32(TxPressure, Dpdk->GreenQuicPressureUpThreshold);
    }

    if ((S->Rx.ConsecutiveFull >= Dpdk->GreenQuicFullBurstMaxCount &&
         RxQueuePressure >= Dpdk->GreenQuicPressureMaxThreshold) ||
        (S->Tx.ConsecutiveFull >= Dpdk->GreenQuicFullBurstMaxCount &&
         TxPressure >= Dpdk->GreenQuicPressureMaxThreshold) ||
        RxQueuePressure >= Dpdk->GreenQuicPressureMaxThreshold ||
        TxPressure >= Dpdk->GreenQuicPressureMaxThreshold) {
        *HardMax = TRUE;
    }

    const uint64_t Hints = CxPlatGreenQuicPlusGetHints();
    BOOLEAN PlusHardMax = FALSE;
    const uint32_t PlusPressure = GreenQuicPlusPressure(Dpdk, Hints, RxPressure, TxPressure, &PlusHardMax);
    if (PlusHardMax) {
        *HardMax = TRUE;
    }

    S->LastRxPressure = RxPressure;
    S->LastTxPressure = TxPressure;
    S->LastPlusPressure = PlusPressure;
    S->LastTxRingCount = TxRingCount;
    S->LastHints = Hints;
    S->LastHardMax = *HardMax;

    uint32_t Weighted;
    switch (Dpdk->GreenQuicProfile) {
    case GREENQUIC_PROFILE_SERVER_DOWNLOAD:
        Weighted = (50U * TxPressure + 25U * PlusPressure + 15U * RxPressure) / 90U;
        break;
    case GREENQUIC_PROFILE_CLIENT_DOWNLOAD:
        Weighted = (50U * RxPressure + 25U * PlusPressure + 15U * TxPressure) / 90U;
        break;
    default:
        Weighted = (35U * RxPressure + 35U * TxPressure + 30U * PlusPressure) / 100U;
        break;
    }

    Weighted = GreenQuicMaxU32(Weighted, RxPressure);
    Weighted = GreenQuicMaxU32(Weighted, TxPressure);
    Weighted = GreenQuicMaxU32(Weighted, PlusPressure);
    return GreenQuicMinU32(Weighted, GREENQUIC_PRESSURE_SCALE);
}

static void
GreenQuicApplyPolicy(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_ DPDK_INTERFACE* Interface,
    _In_ uint16_t Core
    )
{
    if (Dpdk->GreenQuicMode == GREENQUIC_MODE_OFF) {
        return;
    }

    GreenQuicMaybePrintStats(Dpdk, Core);

    const uint32_t TxRingCount = rte_ring_count(Interface->TxRingBuffer);
    GREENQUIC_LCORE_STATE* S = GreenQuicGetLcoreState(Dpdk, Core);

    BOOLEAN HardMax = FALSE;
    const uint32_t RawPressure = GreenQuicComputeRawPressure(Dpdk, S, TxRingCount, &HardMax);
    S->LastRawPressure = RawPressure;

    if (HardMax) {
        // Do not pin the moving average to 1000. Hard-max is an immediate action,
        // but the average should decay normally after the burst/backlog disappears.
        S->PressureAvg = GreenQuicUpdateEwma(
            S->PressureAvg,
            RawPressure,
            Dpdk->GreenQuicEwmaRiseShift,
            Dpdk->GreenQuicEwmaFallShift);
        S->LastAction = "freq_max_hard";
        GreenQuicFreqMax(Dpdk, Core);
        return;
    }

    S->PressureAvg = GreenQuicUpdateEwma(
        S->PressureAvg,
        RawPressure,
        Dpdk->GreenQuicEwmaRiseShift,
        Dpdk->GreenQuicEwmaFallShift);

    if (S->PressureAvg >= Dpdk->GreenQuicPressureMaxThreshold) {
        S->LastAction = "freq_max_avg";
        GreenQuicFreqMax(Dpdk, Core);
        return;
    }

    if (S->PressureAvg >= Dpdk->GreenQuicPressureUpThreshold) {
        S->LastAction = "freq_up";
        GreenQuicFreqUpStep(Dpdk, Core);
        return;
    }

    if (S->PressureAvg >= Dpdk->GreenQuicPressureKeepThreshold) {
        S->LastAction = "keep_pause";
        rte_pause();
        return;
    }

    if (S->Rx.ConsecutiveEmpty < Dpdk->GreenQuicRxEmptyPollThreshold ||
        S->Tx.ConsecutiveEmpty < Dpdk->GreenQuicTxEmptyPollThreshold) {
        S->LastAction = "short_idle_pause";
        rte_pause();
        return;
    }

    if (Dpdk->GreenQuicNoSleepIfTxRingNotEmpty && TxRingCount > 0) {
        S->LastAction = "txring_protect_up";
        GreenQuicFreqUpStep(Dpdk, Core);
        return;
    }

    const uint64_t LastActive = S->Rx.LastActiveTsc > S->Tx.LastActiveTsc ? S->Rx.LastActiveTsc : S->Tx.LastActiveTsc;
    const uint64_t Now = rte_get_tsc_cycles();
    const uint64_t IdleUs = LastActive == 0 ? UINT64_MAX : GreenQuicTscDeltaToUs(Now - LastActive);

    if (IdleUs >= Dpdk->GreenQuicFreqMinIdleUs) {
        S->LastAction = "freq_min";
        GreenQuicFreqMin(Dpdk, Core);
    } else {
        S->LastAction = "freq_down";
        GreenQuicFreqDownStep(Dpdk, Core);
    }

    const uint64_t Hints = CxPlatGreenQuicPlusGetHints();
    if (GreenQuicPlusHasActiveTransferHint(Dpdk, Hints)) {
        // During a known file transfer, allow DVFS step-down but avoid adding sleep latency.
        S->LastAction = "transfer_no_sleep";
        return;
    }

    const uint32_t SleepBudgetUs = GreenQuicGetSleepBudgetUs(Dpdk);
    if (SleepBudgetUs != 0) {
        S->LastAction = "sleep";
        GreenQuicSleepUs(Dpdk, Core, SleepBudgetUs);
    }
}

static void
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
        GreenQuicTscDeltaToUs(Now - S->LastStatsTsc) < Dpdk->GreenQuicStatsPeriodUs) {
        return;
    }

    S->LastStatsTsc = Now;
    printf("GreenQUIC lcore=%u mode=%s profile=%s action=%s power=%u hardmax=%u raw=%u avg=%u "
           "rxp=%u txp=%u plusp=%u hints=0x%" PRIx64 " txring=%u rxq=%u "
           "rx_pkts=%" PRIu64 " tx_pkts=%" PRIu64 " rx_empty=%u tx_empty=%u "
           "rx_full=%u tx_full=%u slept_us=%" PRIu64 "\n",
           Core,
           GreenQuicModeToString(Dpdk->GreenQuicMode),
           GreenQuicProfileToString(Dpdk->GreenQuicProfile),
           S->LastAction != NULL ? S->LastAction : "none",
           S->PowerAvailable ? 1U : 0U,
           S->LastHardMax ? 1U : 0U,
           S->LastRawPressure,
           S->PressureAvg,
           S->LastRxPressure,
           S->LastTxPressure,
           S->LastPlusPressure,
           S->LastHints,
           S->LastTxRingCount,
           S->Rx.LastQueueCount,
           S->Rx.Packets,
           S->Tx.Packets,
           S->Rx.ConsecutiveEmpty,
           S->Tx.ConsecutiveEmpty,
           S->Rx.ConsecutiveFull,
           S->Tx.ConsecutiveFull,
           S->TotalSleepUs);
}

// GREENQUIC-END
'''

DPDK_CONFIG_PARSE = r'''        if (strcmp(Line, "DeviceName") == 0) {
             strcpy(Dpdk->Interface.DeviceName, Value);
        } else if (strcmp(Line, "GreenQuicDpdkLcore") == 0) {
            Dpdk->Cpu = (uint16_t)atoi(Value);
            snprintf(Dpdk->GreenQuicDpdkLcores, sizeof(Dpdk->GreenQuicDpdkLcores), "%hu", Dpdk->Cpu);
        } else if (strcmp(Line, "GreenQuicDpdkLcores") == 0) {
            snprintf(Dpdk->GreenQuicDpdkLcores, sizeof(Dpdk->GreenQuicDpdkLcores), "%s", Value);
        } else if (strcmp(Line, "GreenQuicMode") == 0) {
            if (strcasecmp(Value, "off") == 0 || strcmp(Value, "0") == 0) {
                Dpdk->GreenQuicMode = GREENQUIC_MODE_OFF;
            } else if (strcasecmp(Value, "basic") == 0 || strcasecmp(Value, "greenquic") == 0 || strcmp(Value, "1") == 0) {
                Dpdk->GreenQuicMode = GREENQUIC_MODE_BASIC;
            } else if (strcasecmp(Value, "plus") == 0 || strcasecmp(Value, "greenquic+") == 0 || strcmp(Value, "2") == 0) {
                Dpdk->GreenQuicMode = GREENQUIC_MODE_PLUS;
            }
        } else if (strcmp(Line, "GreenQuicProfile") == 0) {
            if (strcasecmp(Value, "server_download") == 0) {
                Dpdk->GreenQuicProfile = GREENQUIC_PROFILE_SERVER_DOWNLOAD;
            } else if (strcasecmp(Value, "client_download") == 0) {
                Dpdk->GreenQuicProfile = GREENQUIC_PROFILE_CLIENT_DOWNLOAD;
            } else if (strcasecmp(Value, "server_upload") == 0) {
                Dpdk->GreenQuicProfile = GREENQUIC_PROFILE_SERVER_UPLOAD;
            } else if (strcasecmp(Value, "client_upload") == 0) {
                Dpdk->GreenQuicProfile = GREENQUIC_PROFILE_CLIENT_UPLOAD;
            } else {
                Dpdk->GreenQuicProfile = GREENQUIC_PROFILE_SYMMETRIC;
            }
        } else if (strcmp(Line, "GreenQuicRxEmptyPollThreshold") == 0) {
            Dpdk->GreenQuicRxEmptyPollThreshold = (uint32_t)atoi(Value);
        } else if (strcmp(Line, "GreenQuicTxEmptyPollThreshold") == 0) {
            Dpdk->GreenQuicTxEmptyPollThreshold = (uint32_t)atoi(Value);
        } else if (strcmp(Line, "GreenQuicRxQueueHigh") == 0) {
            Dpdk->GreenQuicRxQueueHigh = (uint32_t)atoi(Value);
        } else if (strcmp(Line, "GreenQuicRxQueueSamplePeriod") == 0) {
            Dpdk->GreenQuicRxQueueSamplePeriod = (uint32_t)atoi(Value);
            if (Dpdk->GreenQuicRxQueueSamplePeriod == 0) {
                Dpdk->GreenQuicRxQueueSamplePeriod = 1;
            }
        } else if (strcmp(Line, "GreenQuicTxRingHigh") == 0) {
            Dpdk->GreenQuicTxRingHigh = (uint32_t)atoi(Value);
        } else if (strcmp(Line, "GreenQuicPressureMaxThreshold") == 0) {
            Dpdk->GreenQuicPressureMaxThreshold = (uint32_t)atoi(Value);
        } else if (strcmp(Line, "GreenQuicPressureUpThreshold") == 0) {
            Dpdk->GreenQuicPressureUpThreshold = (uint32_t)atoi(Value);
        } else if (strcmp(Line, "GreenQuicPressureKeepThreshold") == 0) {
            Dpdk->GreenQuicPressureKeepThreshold = (uint32_t)atoi(Value);
        } else if (strcmp(Line, "GreenQuicFullBurstMaxCount") == 0) {
            Dpdk->GreenQuicFullBurstMaxCount = (uint32_t)atoi(Value);
        } else if (strcmp(Line, "GreenQuicEwmaRiseShift") == 0) {
            Dpdk->GreenQuicEwmaRiseShift = (uint32_t)atoi(Value);
        } else if (strcmp(Line, "GreenQuicEwmaFallShift") == 0) {
            Dpdk->GreenQuicEwmaFallShift = (uint32_t)atoi(Value);
        } else if (strcmp(Line, "GreenQuicAckPathMaxSleepUs") == 0) {
            Dpdk->GreenQuicAckPathMaxSleepUs = (uint32_t)atoi(Value);
        } else if (strcmp(Line, "GreenQuicDataPathMaxSleepUs") == 0) {
            Dpdk->GreenQuicDataPathMaxSleepUs = (uint32_t)atoi(Value);
        } else if (strcmp(Line, "GreenQuicMaxSleepUs") == 0) {
            Dpdk->GreenQuicMaxSleepUs = (uint32_t)atoi(Value);
        } else if (strcmp(Line, "GreenQuicFreqPeriodUs") == 0) {
            Dpdk->GreenQuicFreqPeriodUs = (uint32_t)atoi(Value);
            Dpdk->GreenQuicFreqDownPeriodUs = Dpdk->GreenQuicFreqPeriodUs;
        } else if (strcmp(Line, "GreenQuicFreqUpPeriodUs") == 0) {
            Dpdk->GreenQuicFreqUpPeriodUs = (uint32_t)atoi(Value);
        } else if (strcmp(Line, "GreenQuicFreqDownPeriodUs") == 0) {
            Dpdk->GreenQuicFreqDownPeriodUs = (uint32_t)atoi(Value);
        } else if (strcmp(Line, "GreenQuicFreqMinIdleUs") == 0) {
            Dpdk->GreenQuicFreqMinIdleUs = (uint32_t)atoi(Value);
        } else if (strcmp(Line, "GreenQuicStatsPeriodUs") == 0) {
            Dpdk->GreenQuicStatsPeriodUs = (uint32_t)atoi(Value);
        } else if (strcmp(Line, "GreenQuicLogLevel") == 0) {
            Dpdk->GreenQuicLogLevel = (uint32_t)atoi(Value);
            if (Dpdk->GreenQuicLogLevel > 2) {
                Dpdk->GreenQuicLogLevel = 2;
            }
            if (Dpdk->GreenQuicLogLevel != 0 && Dpdk->GreenQuicStatsPeriodUs == 0) {
                Dpdk->GreenQuicStatsPeriodUs = 1000000U;
            }
        } else if (strcmp(Line, "GreenQuicEnableLogging") == 0) {
            Dpdk->GreenQuicLogLevel = atoi(Value) != 0 ? 1U : 0U;
            if (Dpdk->GreenQuicLogLevel != 0 && Dpdk->GreenQuicStatsPeriodUs == 0) {
                Dpdk->GreenQuicStatsPeriodUs = 1000000U;
            }
        } else if (strcmp(Line, "GreenQuicEnableFreq") == 0) {
            Dpdk->GreenQuicEnableFreq = atoi(Value) != 0 ? TRUE : FALSE;
        } else if (strcmp(Line, "GreenQuicEnableSleep") == 0) {
            Dpdk->GreenQuicEnableSleep = atoi(Value) != 0 ? TRUE : FALSE;
        } else if (strcmp(Line, "GreenQuicNoSleepIfTxRingNotEmpty") == 0) {
            Dpdk->GreenQuicNoSleepIfTxRingNotEmpty = atoi(Value) != 0 ? TRUE : FALSE;
        }
'''

DPDK_INI_EXAMPLE = r'''# GreenQUIC example configuration for dpdk.ini
# Put this file in the directory where you run the MsQuic DPDK tool.

DeviceName=<your-dpdk-device-name>

# off: original behavior
# basic: DPDK-only GreenQUIC
# plus: GreenQUIC + QUIC/app hints
GreenQuicMode=basic

# For an 8GB server-to-client download:
# server side: server_download
# client side: client_download
GreenQuicProfile=server_download

# Empty-poll / queue thresholds. RX queue pressure uses rte_eth_rx_queue_count() when the PMD supports it.
GreenQuicRxEmptyPollThreshold=50000
GreenQuicTxEmptyPollThreshold=50000
GreenQuicRxQueueHigh=64
GreenQuicRxQueueSamplePeriod=64
GreenQuicTxRingHigh=64

# Proportional pressure policy, 0..1000
# v9 defaults are quiet and measurement-friendly:
# - logging is off unless GreenQuicEnableLogging=1 or GreenQuicLogLevel>0
# - app transfer hints are reference-counted for parallel transfers
# - per-lcore GreenQUIC state is kept, but original MsQuic-DPDK queue mapping is still queue 0
# >= max  -> jump directly to rte_power_freq_max()
# >= up   -> one DPDK step up with rte_power_freq_up()
# >= keep -> hold current / pause
GreenQuicPressureMaxThreshold=900
GreenQuicPressureUpThreshold=600
GreenQuicPressureKeepThreshold=200
GreenQuicFullBurstMaxCount=8

# Moving average: fast rise, controlled fall.
# Rise shift 1 means half of the difference upward.
# Fall shift 3 means one-eighth of the difference downward; this is less sticky for energy saving.
GreenQuicEwmaRiseShift=1
GreenQuicEwmaFallShift=3

# Frequency timing.
GreenQuicFreqUpPeriodUs=1000
GreenQuicFreqDownPeriodUs=5000
GreenQuicFreqMinIdleUs=20000
GreenQuicFreqPeriodUs=100000

GreenQuicAckPathMaxSleepUs=2
GreenQuicDataPathMaxSleepUs=0
GreenQuicMaxSleepUs=5
# Logging is off by default. Enable only when debugging/measuring decisions.
GreenQuicEnableLogging=0
GreenQuicLogLevel=0
GreenQuicStatsPeriodUs=0
# Example debug settings:
# GreenQuicEnableLogging=1
# GreenQuicLogLevel=1
# GreenQuicStatsPeriodUs=1000000
GreenQuicEnableFreq=1
GreenQuicEnableSleep=0
GreenQuicNoSleepIfTxRingNotEmpty=1

# Linux optional driver/plugin path at runtime:
#   export GREENQUIC_DPDK_DRIVER_PATH=/path/to/dpdk/drivers

   If you already have a private DPDK folder, you can ask the script to search it:

   ./greenquic_full_autopatch_v13_partition_mapped_multicore.py --dpdk-mode local --dpdk-search-root ./mohsen/dpdk21
# On Windows, the original rte_*-21.dll PMD list is kept under #ifdef _WIN32.
'''


# =============================================================================
# Git and repo setup
# =============================================================================

EXPECTED_FILES = [
    "CMakeLists.txt",
    "src/platform/CMakeLists.txt",
    "src/platform/datapath_raw_dpdk.c",
    "src/core/precomp.h",
    "src/core/ack_tracker.c",
    "src/core/cubic.c",
    "src/tools/interopserver/InteropServer.h",
    "src/tools/interopserver/InteropServer.cpp",
    "src/tools/interop/interop.cpp",
]


def looks_like_msquic_tree(repo: Path) -> bool:
    return all((repo / rel).exists() for rel in EXPECTED_FILES[:3])


def is_git_repo(repo: Path) -> bool:
    return (repo / ".git").exists()


def clone_or_use_repo(args: argparse.Namespace) -> Path:
    if args.repo_dir:
        repo = Path(args.repo_dir).resolve()
        if repo.exists() and is_git_repo(repo):
            log(f"Using existing git repo: {repo}")
            return repo
        if repo.exists() and looks_like_msquic_tree(repo):
            warn(f"Using existing non-git MsQuic source tree: {repo}")
            warn("Checkout, branch creation, and submodule update will be skipped. Use a real git clone for normal development.")
            return repo
        if repo.exists():
            die(f"{repo} exists but is neither a git repo nor a recognizable MsQuic source tree.")

    git_url = args.git_url or ask("Git URL to clone")
    if not git_url:
        die("Git URL is required unless --repo-dir points to an existing repo/source tree.")

    default_name = git_url.rstrip("/").split("/")[-1].replace(".git", "") or "msquic"
    repo_dir = Path(args.repo_dir or ask("Local directory under ./", default_name)).resolve()

    if repo_dir.exists() and is_git_repo(repo_dir):
        log(f"Using existing repo: {repo_dir}")
    elif repo_dir.exists() and looks_like_msquic_tree(repo_dir):
        warn(f"Using existing non-git MsQuic source tree: {repo_dir}")
        warn("Checkout, branch creation, and submodule update will be skipped.")
    elif repo_dir.exists():
        die(f"{repo_dir} exists but is neither a git repo nor a recognizable MsQuic source tree. Choose another directory.")
    else:
        log(f"Cloning {git_url} into {repo_dir}")
        run(["git", "clone", git_url, str(repo_dir)])

    return repo_dir


def choose_checkout(repo: Path, args: argparse.Namespace) -> str:
    log("Fetching branches and tags.")
    run(["git", "fetch", "--all", "--tags", "--prune"], cwd=repo)

    branches = capture(["git", "branch", "-r", "--format=%(refname:short)"], cwd=repo, check=False).splitlines()
    tags = capture(["git", "tag", "--sort=-creatordate"], cwd=repo, check=False).splitlines()

    print("\nRemote branches:")
    for i, b in enumerate(branches[:40], 1):
        print(f"  b{i:02d}: {b}")
    print("\nTags:")
    for i, t in enumerate(tags[:40], 1):
        print(f"  t{i:02d}: {t}")

    return args.checkout or ask("Checkout point", "origin/main")


def prepare_branch(repo: Path, args: argparse.Namespace) -> None:
    if not is_git_repo(repo):
        warn("Non-git source tree: skipping checkout, submodule update, and branch creation.")
        return

    checkout = choose_checkout(repo, args)
    log(f"Checking out {checkout}")
    run(["git", "checkout", checkout], cwd=repo)

    log("Updating submodules locally inside the repo.")
    run(["git", "submodule", "update", "--init", "--recursive"], cwd=repo)

    branch = args.branch or ask("New branch name", "greenquic-full")
    log(f"Creating/resetting branch {branch}")
    run(["git", "checkout", "-B", branch], cwd=repo)


def check_expected_files(repo: Path) -> None:
    log("Checking expected files.")
    missing = [p for p in EXPECTED_FILES if not (repo / p).exists()]
    if missing:
        die("Missing expected files:\n" + "\n".join(missing))
    log("All expected files exist.")


# =============================================================================
# Patching
# =============================================================================

def patch_greenquic_plus_files(repo: Path) -> None:
    log("Writing full GreenQUIC+ header and implementation.")
    write_new_or_replace(repo / "src/inc/greenquic_plus.h", GREENQUIC_PLUS_H)
    write_new_or_replace(repo / "src/platform/greenquic_plus.c", GREENQUIC_PLUS_C)
    write_new_or_replace(repo / "dpdk.greenquic.example.ini", DPDK_INI_EXAMPLE)


def patch_datapath(repo: Path) -> None:
    path = repo / "src/platform/datapath_raw_dpdk.c"
    log(f"Patching {path}")
    ensure_file(path)
    backup(path)
    text = read_text(path)

    if "// GREENQUIC-BEGIN: mode, profile and runtime state" in text and "// GREENQUIC-BEGIN: helper implementations" in text:
        log("datapath_raw_dpdk.c already has the GreenQUIC base patch; skipping base datapath patch.")
        return

    ensure_contains(path, [
        '#include "datapath_raw.h"',
        '#include <rte_mbuf_core.h>',
        '#define TX_RING_SIZE 1024',
        'DPDK_INTERFACE Interface; // TODO: support multiple NIC interfaces.',
        'static int CxPlatDpdkWorkerThread(_In_ void* Context);',
        'Dpdk->Cpu = (uint16_t)(CxPlatProcCount() - 1);',
        'if (strcmp(Line, "DeviceName") == 0) {',
        'CxPlatDpdkTx(',
        'CxPlatDpdkWorkerThread(',
    ])

    text = insert_after(text, '#include "datapath_raw.h"\n', '#include "greenquic_plus.h"\n', "datapath include greenquic_plus.h")
    text = insert_after(text, '#include <rte_mbuf_core.h>\n', '#include <rte_cycles.h>\n#include <rte_pause.h>\n#include <rte_power.h>\n#include <inttypes.h>\n#include <stdlib.h>\n#ifndef _WIN32\n#include <strings.h>\n#else\n#define strcasecmp _stricmp\n#endif\n', "datapath DPDK/system includes")
    text = insert_after(text, '#define TX_RING_SIZE 1024\n', DPDK_TYPES, "GreenQUIC types/defaults")
    text = insert_after(text, '    DPDK_INTERFACE Interface; // TODO: support multiple NIC interfaces.\n', DPDK_DATAPATH_FIELDS, "GreenQUIC DPDK_DATAPATH fields")
    text = insert_after(text, 'static int CxPlatDpdkWorkerThread(_In_ void* Context);\n', DPDK_PROTOTYPES, "GreenQUIC prototypes")
    text = insert_before(text, '_IRQL_requires_max_(PASSIVE_LEVEL)\nvoid\nCxPlatDpdkReadConfig(', DPDK_HELPERS + "\n", "GreenQUIC helper implementations")

    text = insert_after(text, '    Dpdk->Cpu = (uint16_t)(CxPlatProcCount() - 1);\n', '    GreenQuicSetDefaults(Dpdk);\n', "GreenQUIC defaults before config")


    old_eal = '''    const char* argv[] = {
        "msquic",
        "-n", "4",
        "-l", DpdpCpuStr,
        "-d", "rte_mempool_ring-21.dll",
        "-d", "rte_bus_pci-21.dll",
        "-d", "rte_common_mlx5-21.dll",
        "-d", "rte_net_mlx5-21.dll"
    };
'''
    new_eal = r'''    // GREENQUIC-BEGIN: Linux-safe and Windows-safe DPDK EAL args
    const char* argv[20];
    int argc = 0;
    argv[argc++] = "msquic";
    argv[argc++] = "-n";
    argv[argc++] = "4";
    argv[argc++] = "-l";
    argv[argc++] = DpdpCpuStr;
#ifdef _WIN32
    // Keep the original MsQuic Windows DPDK PMD DLL loading path.
    argv[argc++] = "-d";
    argv[argc++] = "rte_mempool_ring-21.dll";
    argv[argc++] = "-d";
    argv[argc++] = "rte_bus_pci-21.dll";
    argv[argc++] = "-d";
    argv[argc++] = "rte_common_mlx5-21.dll";
    argv[argc++] = "-d";
    argv[argc++] = "rte_net_mlx5-21.dll";
#else
    // On Linux, do not load Windows .dll PMDs. Linked/static PMDs from libdpdk are used.
    // If your Linux DPDK build uses plugin PMDs, set this env var to the driver .so or driver directory.
    const char* GreenQuicDpdkDriverPath = getenv("GREENQUIC_DPDK_DRIVER_PATH");
    if (GreenQuicDpdkDriverPath != NULL && GreenQuicDpdkDriverPath[0] != '\0') {
        argv[argc++] = "-d";
        argv[argc++] = GreenQuicDpdkDriverPath;
    }
#endif
    // GREENQUIC-END
'''
    if "GREENQUIC-BEGIN: Linux-safe and Windows-safe DPDK EAL args" not in text:
        text = replace_once(text, old_eal, new_eal, "Linux/Windows DPDK EAL driver args")
    text = text.replace('    char DpdpCpuStr[16];\n    sprintf(DpdpCpuStr, "%hu", Dpdk->Cpu);\n',
        '    char DpdpCpuStr[64];\n'
        '    if (Dpdk->GreenQuicDpdkLcores[0] != \'\\0\') {\n'
        '        snprintf(DpdpCpuStr, sizeof(DpdpCpuStr), "%s", Dpdk->GreenQuicDpdkLcores);\n'
        '    } else {\n'
        '        snprintf(DpdpCpuStr, sizeof(DpdpCpuStr), "%hu", Dpdk->Cpu);\n'
        '    }\n'
        "    if (strchr(DpdpCpuStr, ',') != NULL || strchr(DpdpCpuStr, '-') != NULL) {\n"
        '        printf("GreenQUIC warning: multiple DPDK lcores requested with -l %s. "\n'
        '               "GreenQUIC per-lcore state is ready, but the original MsQuic DPDK path still uses RX/TX queue 0. "\n'
        '               "Add real queue mapping before treating this as true multi-core scaling.\\n", DpdpCpuStr);\n'
        '    }\n', 1)

    text = text.replace('rte_eal_init(ARRAYSIZE(argv), (char**)argv)', 'rte_eal_init(argc, (char**)argv)')

    old_cfg = '''        if (strcmp(Line, "DeviceName") == 0) {
             strcpy(Dpdk->Interface.DeviceName, Value);
        }
'''
    if "strcasecmp(Value, \"greenquic\")" not in text:
        text = replace_once(text, old_cfg, DPDK_CONFIG_PARSE, "GreenQUIC config parser")

    old_rx = '''    const uint16_t BuffersCount =
        rte_eth_rx_burst(Interface->Port, 0, (struct rte_mbuf**)Buffers, RX_BURST_SIZE);
    if (unlikely(BuffersCount == 0)) {
        return;
    }
'''
    new_rx = '''    int RxQueueCountBefore = -1;
    if (Dpdk->GreenQuicMode != GREENQUIC_MODE_OFF) {
        GREENQUIC_LCORE_STATE* GreenQuicState = GreenQuicGetLcoreState(Dpdk, Core);
        if (GreenQuicState->Rx.QueueSampleCountdown == 0) {
            RxQueueCountBefore = rte_eth_rx_queue_count(Interface->Port, 0);
            GreenQuicState->Rx.QueueSampleCountdown = Dpdk->GreenQuicRxQueueSamplePeriod;
        }
        GreenQuicState->Rx.QueueSampleCountdown--;
    }
    const uint16_t BuffersCount =
        rte_eth_rx_burst(Interface->Port, 0, (struct rte_mbuf**)Buffers, RX_BURST_SIZE);
    GreenQuicOnRxPoll(Dpdk, Core, BuffersCount, RxQueueCountBefore);
    if (unlikely(BuffersCount == 0)) {
        return;
    }
'''
    if "GreenQuicOnRxPoll(Dpdk, Core, BuffersCount, RxQueueCountBefore);" not in text:
        text = replace_once(text, old_rx, new_rx, "RX observation hook with sampled rte_eth_rx_queue_count pressure")

    old_tx_sig = '''CxPlatDpdkTx(
    _In_ DPDK_DATAPATH* Dpdk,
    _In_ DPDK_INTERFACE* Interface
    )
'''
    new_tx_sig = '''CxPlatDpdkTx(
    _In_ DPDK_DATAPATH* Dpdk,
    _In_ const uint16_t Core,
    _In_ DPDK_INTERFACE* Interface
    )
'''
    if "_In_ const uint16_t Core,\n    _In_ DPDK_INTERFACE* Interface\n    )\n{\n    struct rte_mbuf* Buffers[TX_BURST_SIZE];" not in text:
        text = replace_once(text, old_tx_sig, new_tx_sig, "CxPlatDpdkTx signature")

    old_tx_body = '''    struct rte_mbuf* Buffers[TX_BURST_SIZE];
    const uint16_t BufferCount =
        (uint16_t)rte_ring_sc_dequeue_burst(
            Interface->TxRingBuffer, (void**)Buffers, TX_BURST_SIZE, NULL);
    if (unlikely(BufferCount == 0)) {
        return;
    }

    const uint16_t TxCount = rte_eth_tx_burst(Interface->Port, 0, Buffers, BufferCount);
'''
    new_tx_body = '''    struct rte_mbuf* Buffers[TX_BURST_SIZE];
    const uint32_t RingBefore = rte_ring_count(Interface->TxRingBuffer);
    const uint16_t BufferCount =
        (uint16_t)rte_ring_sc_dequeue_burst(
            Interface->TxRingBuffer, (void**)Buffers, TX_BURST_SIZE, NULL);
    if (unlikely(BufferCount == 0)) {
        GreenQuicOnTxPoll(Dpdk, Core, RingBefore, BufferCount, 0);
        return;
    }

    const uint16_t TxCount = rte_eth_tx_burst(Interface->Port, 0, Buffers, BufferCount);
    GreenQuicOnTxPoll(Dpdk, Core, RingBefore, BufferCount, TxCount);
'''
    if "const uint32_t RingBefore = rte_ring_count" not in text:
        text = replace_once(text, old_tx_body, new_tx_body, "TX observation hook")

    text = insert_after(text, '    printf("Core %u worker running...\\n", Core);\n', '    GreenQuicPowerInit(Dpdk, Core);\n', "worker power init")

    old_loop = '''            CxPlatDpdkRx(Dpdk, Core, Interface);
            CxPlatDpdkTx(Dpdk, Interface);
'''
    new_loop = '''            CxPlatDpdkRx(Dpdk, Core, Interface);
            CxPlatDpdkTx(Dpdk, Core, Interface);
            GreenQuicApplyPolicy(Dpdk, Interface, Core);
'''
    if "GreenQuicApplyPolicy(Dpdk, Interface, Core);" not in text:
        text = replace_once(text, old_loop, new_loop, "worker policy call")

    old_tail = '''    }

    return 0;
}
'''
    new_tail = '''    }

    GreenQuicPowerCleanup(Dpdk, Core);
    return 0;
}
'''
    if "GreenQuicPowerCleanup(Dpdk, Core);" not in text:
        text = replace_once(text, old_tail, new_tail, "worker power cleanup")

    write_text(path, text)
    log("Finished datapath_raw_dpdk.c patch.")


def patch_precomp(repo: Path) -> None:
    path = repo / "src/core/precomp.h"
    log(f"Patching {path}")
    ensure_file(path)
    backup(path)
    text = read_text(path)
    if '#include "greenquic_plus.h"' not in text:
        if '#include "quic_trace.h"\n' in text:
            text = insert_after(text, '#include "quic_trace.h"\n', '#include "greenquic_plus.h"\n', "precomp greenquic include")
        else:
            text = insert_after(text, '#include "platform.h"\n', '#include "greenquic_plus.h"\n', "precomp greenquic include fallback")
    write_text(path, text)


def patch_ack_tracker(repo: Path) -> None:
    path = repo / "src/core/ack_tracker.c"
    log(f"Patching {path}")
    ensure_file(path)
    backup(path)
    text = read_text(path)
    if "GQPLUS_HINT_ACK_PENDING" not in text:
        text = text.replace(
            '        QuicSendSetSendFlag(&Connection->Send, QUIC_CONN_SEND_FLAG_ACK);\n',
            '        QuicSendSetSendFlag(&Connection->Send, QUIC_CONN_SEND_FLAG_ACK);\n        CxPlatGreenQuicPlusPulseHints(GQPLUS_HINT_ACK_PENDING);\n',
            1)
        text = text.replace(
            '        QuicSendStartDelayedAckTimer(&Connection->Send);\n',
            '        QuicSendStartDelayedAckTimer(&Connection->Send);\n        CxPlatGreenQuicPlusPulseHints(GQPLUS_HINT_ACK_PENDING);\n',
            1)
        if text.count('GQPLUS_HINT_ACK_PENDING') < 2:
            raise RuntimeError("Failed to insert both ACK hooks in ack_tracker.c")
    write_text(path, text)


def patch_cubic(repo: Path) -> None:
    path = repo / "src/core/cubic.c"
    log(f"Patching {path}")
    ensure_file(path)
    backup(path)
    text = read_text(path)
    if "GQPLUS_HINT_CUBIC_CWND_BLOCKED" not in text:
        text = insert_after(text, '        SendAllowance = 0;\n', '        CxPlatGreenQuicPlusPulseHints(GQPLUS_HINT_CUBIC_CWND_BLOCKED);\n', "CUBIC cwnd blocked hook")
    if "GQPLUS_HINT_CUBIC_RECOVERY" not in text:
        text = insert_after(text, '    Cubic->IsInRecovery = TRUE;\n', '    CxPlatGreenQuicPlusPulseHints(GQPLUS_HINT_CUBIC_RECOVERY);\n', "CUBIC recovery hook")
    if "OldCongestionWindow" not in text:
        if '    uint32_t BytesAcked = AckEvent->NumRetransmittableBytes;\n' in text:
            text = insert_after(text, '    uint32_t BytesAcked = AckEvent->NumRetransmittableBytes;\n', '    const uint32_t OldCongestionWindow = Cubic->CongestionWindow;\n', "CUBIC old cwnd capture")
        elif '    uint32_t BytesAcked = NumRetransmittableBytes;\n' in text:
            text = insert_after(text, '    uint32_t BytesAcked = NumRetransmittableBytes;\n', '    const uint32_t OldCongestionWindow = Cubic->CongestionWindow;\n', "CUBIC old cwnd capture fallback")
        else:
            raise RuntimeError("Could not find BytesAcked anchor in cubic.c")
        text = insert_before(text, 'Exit:\n', '    if (Cubic->CongestionWindow > OldCongestionWindow) {\n        CxPlatGreenQuicPlusPulseHints(GQPLUS_HINT_CUBIC_RAMPING);\n    }\n\n', "CUBIC ramping hook")
    write_text(path, text)


def patch_server_header(repo: Path) -> None:
    path = repo / "src/tools/interopserver/InteropServer.h"
    log(f"Patching {path}")
    ensure_file(path)
    backup(path)
    text = read_text(path)
    if "GreenQuicServerTxHintActive" not in text:
        text = insert_after(
            text,
            '    bool WriteHttp11Header;\n',
            '    bool GreenQuicServerTxHintActive;\n',
            "server transfer hint guard member")
    write_text(path, text)


def patch_server_tool(repo: Path) -> None:
    path = repo / "src/tools/interopserver/InteropServer.cpp"
    log(f"Patching {path}")
    ensure_file(path)
    backup(path)
    text = read_text(path)
    if '#include "greenquic_plus.h"' not in text:
        if '#include "InteropServer.h"\n' in text:
            text = insert_after(text, '#include "InteropServer.h"\n', '#include "greenquic_plus.h"\n', "server include")
        elif '#include "msquic.h"\n' in text:
            text = insert_after(text, '#include "msquic.h"\n', '#include "greenquic_plus.h"\n', "server include fallback msquic")
        else:
            raise RuntimeError("Could not find include anchor in InteropServer.cpp")

    if "GreenQuicServerTxHintActive(false)" not in text:
        text = replace_once(
            text,
            '    Shutdown(false), WriteHttp11Header(false)\n',
            '    Shutdown(false), WriteHttp11Header(false), GreenQuicServerTxHintActive(false)\n',
            "server transfer hint guard constructor init")

    if "GreenQuicServerTxHintActive) {" not in text.split("HttpRequest::~HttpRequest", 1)[1].split("void", 1)[0]:
        text = insert_after(
            text,
            'HttpRequest::~HttpRequest()\n{\n',
            '    if (GreenQuicServerTxHintActive) {\n        CxPlatGreenQuicPlusEndTransfer(GQPLUS_HINT_SERVER_FILE_TX_ACTIVE);\n        GreenQuicServerTxHintActive = false;\n    }\n',
            "server destructor transfer hint cleanup")

    if "if (!GreenQuicServerTxHintActive)" not in text:
        senddata_anchor = '    Buffer.Reset();\n\n    if (File) {\n'
        if senddata_anchor not in text:
            raise RuntimeError("Could not find SendData if(File) anchor in InteropServer.cpp")
        text = text.replace(
            senddata_anchor,
            '    Buffer.Reset();\n\n    if (File) {\n        if (!GreenQuicServerTxHintActive) {\n            CxPlatGreenQuicPlusBeginTransfer(GQPLUS_HINT_SERVER_FILE_TX_ACTIVE);\n            GreenQuicServerTxHintActive = true;\n        }\n',
            1)

    if "GreenQuicServerTxHintActive = false;" not in text.split("QUIC_STREAM_EVENT_PEER_SEND_ABORTED", 1)[1].split("break;", 1)[0]:
        text = text.replace(
            '        pThis->Abort(HttpRequestPeerAbort);\n',
            '        if (pThis->GreenQuicServerTxHintActive) {\n            CxPlatGreenQuicPlusEndTransfer(GQPLUS_HINT_SERVER_FILE_TX_ACTIVE);\n            pThis->GreenQuicServerTxHintActive = false;\n        }\n        pThis->Abort(HttpRequestPeerAbort);\n',
            1)

    if "GreenQuicServerTxHintActive = false;" not in text.split("QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE", 1)[1].split("delete pThis;", 1)[0]:
        text = text.replace(
            '        delete pThis;\n',
            '        if (pThis->GreenQuicServerTxHintActive) {\n            CxPlatGreenQuicPlusEndTransfer(GQPLUS_HINT_SERVER_FILE_TX_ACTIVE);\n            pThis->GreenQuicServerTxHintActive = false;\n        }\n        delete pThis;\n',
            1)
    write_text(path, text)


def patch_client_tool(repo: Path) -> None:
    path = repo / "src/tools/interop/interop.cpp"
    log(f"Patching {path}")
    ensure_file(path)
    backup(path)
    text = read_text(path)
    if '#include "greenquic_plus.h"' not in text:
        if '#include "interop.h"\n' in text:
            text = insert_after(text, '#include "interop.h"\n', '#include "greenquic_plus.h"\n', "client include")
        elif '#include "msquic.h"\n' in text:
            text = insert_after(text, '#include "msquic.h"\n', '#include "greenquic_plus.h"\n', "client include fallback msquic")
        else:
            raise RuntimeError("Could not find include anchor in interop.cpp")

    if "GreenQuicClientRxHintActive" not in text:
        text = insert_after(
            text,
            '    int64_t LastReceiveDuration;\n',
            '    bool GreenQuicClientRxHintActive;\n',
            "client transfer hint guard member")
        text = replace_once(
            text,
            '        LastReceiveTime(0),\n        LastReceiveDuration(0),\n        ReceivedResponse(false),\n',
            '        LastReceiveTime(0),\n        LastReceiveDuration(0),\n        GreenQuicClientRxHintActive(false),\n        ReceivedResponse(false),\n',
            "client transfer hint guard constructor init")
        text = insert_after(
            text,
            '    ~InteropStream() {\n',
            '        if (GreenQuicClientRxHintActive) {\n            CxPlatGreenQuicPlusEndTransfer(GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE);\n            GreenQuicClientRxHintActive = false;\n        }\n',
            "client destructor transfer hint cleanup")

    if "if (!pThis->GreenQuicClientRxHintActive)" not in text:
        text = insert_after(
            text,
            '                    pThis->File = fopen(fullPath.c_str(), "wb");\n',
            '                    if (pThis->File != nullptr && !pThis->GreenQuicClientRxHintActive) {\n                        CxPlatGreenQuicPlusBeginTransfer(GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE);\n                        pThis->GreenQuicClientRxHintActive = true;\n                    }\n',
            "client guarded transfer start")

    if "GreenQuicClientRxHintActive = false;" not in text.split("QUIC_STREAM_EVENT_PEER_SEND_ABORTED", 1)[1].split("CxPlatEventSet", 1)[0]:
        text = text.replace(
            '                printf("%s: Peer aborted send! (%llu ms)\\n",\n',
            '                if (pThis->GreenQuicClientRxHintActive) {\n                    CxPlatGreenQuicPlusEndTransfer(GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE);\n                    pThis->GreenQuicClientRxHintActive = false;\n                }\n                printf("%s: Peer aborted send! (%llu ms)\\n",\n',
            1)

    if "GreenQuicClientRxHintActive = false;" not in text.split("QUIC_STREAM_EVENT_PEER_SEND_SHUTDOWN", 1)[1].split("fclose(pThis->File);", 1)[0]:
        text = text.replace(
            '                fflush(pThis->File);\n                fclose(pThis->File);\n',
            '                fflush(pThis->File);\n                if (pThis->GreenQuicClientRxHintActive) {\n                    CxPlatGreenQuicPlusEndTransfer(GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE);\n                    pThis->GreenQuicClientRxHintActive = false;\n                }\n                fclose(pThis->File);\n',
            1)

    if "GreenQuicClientRxHintActive = false;" not in text.split("QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE", 1)[1].split("fclose(pThis->File); // Didn't get closed properly.", 1)[0]:
        text = text.replace(
            "                fclose(pThis->File); // Didn't get closed properly.\n",
            "                if (pThis->GreenQuicClientRxHintActive) {\n                    CxPlatGreenQuicPlusEndTransfer(GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE);\n                    pThis->GreenQuicClientRxHintActive = false;\n                }\n                fclose(pThis->File); // Didn't get closed properly.\n",
            1)
    write_text(path, text)


def patch_cmake(repo: Path) -> None:
    root = repo / "CMakeLists.txt"
    plat = repo / "src/platform/CMakeLists.txt"

    log(f"Patching {root}")
    ensure_file(root)
    backup(root)
    text = read_text(root)
    if "QUIC_LINUX_DPDK_ENABLED" not in text:
        text = insert_after(text, 'option(QUIC_LINUX_XDP_ENABLED "Enables XDP support" OFF)\n', 'option(QUIC_LINUX_DPDK_ENABLED "Enables DPDK support" OFF)\n\nif (QUIC_LINUX_DPDK_ENABLED)\n    find_package(PkgConfig REQUIRED)\n    pkg_check_modules(LIBDPDK REQUIRED IMPORTED_TARGET libdpdk)\nendif()\n', "root DPDK CMake option")
    write_text(root, text)

    log(f"Patching {plat}")
    ensure_file(plat)
    backup(plat)
    text = read_text(plat)

    old_sources = '''        if (QUIC_LINUX_XDP_ENABLED)
            set(SOURCES ${SOURCES} datapath_xplat.c datapath_raw.c datapath_raw_linux.c datapath_raw_socket.c datapath_raw_socket_linux.c datapath_raw_xdp_linux.c)
        else()
            set(SOURCES ${SOURCES} datapath_xplat.c datapath_raw_dummy.c)
        endif()
'''
    new_sources = '''        if (QUIC_LINUX_DPDK_ENABLED)
            set(SOURCES ${SOURCES} datapath_xplat.c datapath_raw.c datapath_raw_dpdk.c greenquic_plus.c)
        elseif (QUIC_LINUX_XDP_ENABLED)
            set(SOURCES ${SOURCES} datapath_xplat.c datapath_raw.c datapath_raw_linux.c datapath_raw_socket.c datapath_raw_socket_linux.c datapath_raw_xdp_linux.c)
        else()
            set(SOURCES ${SOURCES} datapath_xplat.c datapath_raw_dummy.c)
        endif()
'''
    if "datapath_raw_dpdk.c" not in text and "datapath_raw_dpdk_linux.c" not in text:
        text = replace_once(text, old_sources, new_sources, "platform DPDK sources")

    if "elseif(QUIC_LINUX_DPDK_ENABLED)" not in text:
        text = text.replace('elseif(QUIC_LINUX_XDP_ENABLED)\n', 'elseif(QUIC_LINUX_DPDK_ENABLED)\n    target_link_libraries(msquic_platform PUBLIC PkgConfig::LIBDPDK)\nelseif(QUIC_LINUX_XDP_ENABLED)\n', 1)
        if "elseif(QUIC_LINUX_DPDK_ENABLED)" not in text:
            raise RuntimeError("Could not insert DPDK link block into src/platform/CMakeLists.txt")

    write_text(plat, text)


MULTICORE_GREENQUIC_PLUS_H = '/*++\n\n    GreenQUIC Plus public hint API.\n\n    Default API remains process-safe and v10-compatible.\n    The optional --enable-multi-core patch adds lcore-local hint APIs so\n    DPDK datapath threads can categorize ACK/CUBIC transient hints by lcore.\n\n--*/\n\n#pragma once\n\n#include <stdint.h>\n\n#ifdef __cplusplus\nextern "C" {\n#endif\n\n#define GQPLUS_LCORE_UNKNOWN              ((uint16_t)0xffffu)\n\n#define GQPLUS_HINT_ACK_PENDING             (1ull << 0)\n#define GQPLUS_HINT_CUBIC_CWND_BLOCKED     (1ull << 1)\n#define GQPLUS_HINT_CUBIC_RECOVERY         (1ull << 2)\n#define GQPLUS_HINT_CUBIC_RAMPING          (1ull << 3)\n\n#define GQPLUS_HINT_SERVER_FILE_TX_ACTIVE  (1ull << 16)\n#define GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE  (1ull << 17)\n\nvoid CxPlatGreenQuicPlusSetThreadLcore(uint16_t Lcore);\nvoid CxPlatGreenQuicPlusClearThreadLcore(void);\nvoid CxPlatGreenQuicPlusSetHints(uint64_t Hints);\nvoid CxPlatGreenQuicPlusClearHints(uint64_t Hints);\nvoid CxPlatGreenQuicPlusBeginTransfer(uint64_t Hints);\nvoid CxPlatGreenQuicPlusEndTransfer(uint64_t Hints);\nvoid CxPlatGreenQuicPlusPulseHints(uint64_t Hints);\nvoid CxPlatGreenQuicPlusPulseHintsForLcore(uint16_t Lcore, uint64_t Hints);\nuint64_t CxPlatGreenQuicPlusGetHints(void);\nuint64_t CxPlatGreenQuicPlusGetHintsForLcore(uint16_t Lcore, int IncludeUnknownGlobalHints);\n\n#ifdef __cplusplus\n}\n#endif\n'

MULTICORE_GREENQUIC_PLUS_C = '/*++\n\n    GreenQUIC Plus hint storage with optional lcore-local transient hints.\n\n    Transfer hints are global and reference-counted because app/tool callbacks do\n    not reliably know the RSS/lcore owner of a request yet. ACK/CUBIC transient\n    hints become lcore-local when emitted from a DPDK lcore that called\n    CxPlatGreenQuicPlusSetThreadLcore(Core). Hints emitted from normal MsQuic\n    worker threads without a lcore context go to an unknown/global transient\n    bucket; the datapath admits those only for lcores with local activity.\n\n--*/\n\n#define _POSIX_C_SOURCE 200809L\n\n#include "greenquic_plus.h"\n\n#include <stdatomic.h>\n#include <stdint.h>\n#include <time.h>\n\n#define GQPLUS_TRANSIENT_TTL_NS (2ull * 1000ull * 1000ull)\n#define GQPLUS_TRANSFER_HINTS (GQPLUS_HINT_SERVER_FILE_TX_ACTIVE | GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE)\n#define GQPLUS_MAX_LCORES 512u\n\n#if defined(_MSC_VER)\n__declspec(thread) static uint16_t ThreadLcore = GQPLUS_LCORE_UNKNOWN;\n#else\nstatic _Thread_local uint16_t ThreadLcore = GQPLUS_LCORE_UNKNOWN;\n#endif\n\nstatic atomic_uint_fast64_t PersistentHints;\nstatic atomic_uint_fast64_t UnknownTransientHints;\nstatic atomic_uint_fast64_t UnknownTransientUntilNs;\nstatic atomic_uint_fast64_t LcoreTransientHints[GQPLUS_MAX_LCORES];\nstatic atomic_uint_fast64_t LcoreTransientUntilNs[GQPLUS_MAX_LCORES];\nstatic atomic_uint_fast32_t ServerFileTxActiveCount;\nstatic atomic_uint_fast32_t ClientFileRxActiveCount;\n\nstatic uint64_t CxPlatGreenQuicPlusNowNs(void)\n{\n    struct timespec Ts;\n#if defined(CLOCK_MONOTONIC_RAW)\n    clock_gettime(CLOCK_MONOTONIC_RAW, &Ts);\n#else\n    clock_gettime(CLOCK_MONOTONIC, &Ts);\n#endif\n    return ((uint64_t)Ts.tv_sec * 1000000000ull) + (uint64_t)Ts.tv_nsec;\n}\n\nstatic int CxPlatGreenQuicPlusValidLcore(uint16_t Lcore)\n{\n    return Lcore != GQPLUS_LCORE_UNKNOWN && Lcore < GQPLUS_MAX_LCORES;\n}\n\nvoid CxPlatGreenQuicPlusSetThreadLcore(uint16_t Lcore)\n{\n    ThreadLcore = Lcore;\n}\n\nvoid CxPlatGreenQuicPlusClearThreadLcore(void)\n{\n    ThreadLcore = GQPLUS_LCORE_UNKNOWN;\n}\n\nstatic void CxPlatGreenQuicPlusIncrementHintCount(atomic_uint_fast32_t* Counter, uint64_t Hint)\n{\n    const uint_fast32_t Old = atomic_fetch_add_explicit(Counter, 1, memory_order_relaxed);\n    if (Old == 0) {\n        atomic_fetch_or_explicit(&PersistentHints, Hint, memory_order_release);\n    }\n}\n\nstatic void CxPlatGreenQuicPlusDecrementHintCount(atomic_uint_fast32_t* Counter, uint64_t Hint)\n{\n    uint_fast32_t Old = atomic_load_explicit(Counter, memory_order_relaxed);\n    while (Old != 0) {\n        if (atomic_compare_exchange_weak_explicit(Counter, &Old, Old - 1, memory_order_acq_rel, memory_order_relaxed)) {\n            if (Old == 1) {\n                atomic_fetch_and_explicit(&PersistentHints, ~Hint, memory_order_release);\n            }\n            return;\n        }\n    }\n}\n\nvoid CxPlatGreenQuicPlusBeginTransfer(uint64_t Hints)\n{\n    if ((Hints & GQPLUS_HINT_SERVER_FILE_TX_ACTIVE) != 0) {\n        CxPlatGreenQuicPlusIncrementHintCount(&ServerFileTxActiveCount, GQPLUS_HINT_SERVER_FILE_TX_ACTIVE);\n    }\n    if ((Hints & GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE) != 0) {\n        CxPlatGreenQuicPlusIncrementHintCount(&ClientFileRxActiveCount, GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE);\n    }\n}\n\nvoid CxPlatGreenQuicPlusEndTransfer(uint64_t Hints)\n{\n    if ((Hints & GQPLUS_HINT_SERVER_FILE_TX_ACTIVE) != 0) {\n        CxPlatGreenQuicPlusDecrementHintCount(&ServerFileTxActiveCount, GQPLUS_HINT_SERVER_FILE_TX_ACTIVE);\n    }\n    if ((Hints & GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE) != 0) {\n        CxPlatGreenQuicPlusDecrementHintCount(&ClientFileRxActiveCount, GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE);\n    }\n}\n\nvoid CxPlatGreenQuicPlusSetHints(uint64_t Hints)\n{\n    atomic_fetch_or_explicit(&PersistentHints, Hints & ~GQPLUS_TRANSFER_HINTS, memory_order_relaxed);\n    CxPlatGreenQuicPlusBeginTransfer(Hints & GQPLUS_TRANSFER_HINTS);\n}\n\nvoid CxPlatGreenQuicPlusClearHints(uint64_t Hints)\n{\n    atomic_fetch_and_explicit(&PersistentHints, ~(Hints & ~GQPLUS_TRANSFER_HINTS), memory_order_relaxed);\n    CxPlatGreenQuicPlusEndTransfer(Hints & GQPLUS_TRANSFER_HINTS);\n}\n\nvoid CxPlatGreenQuicPlusPulseHintsForLcore(uint16_t Lcore, uint64_t Hints)\n{\n    const uint64_t Now = CxPlatGreenQuicPlusNowNs();\n    if (CxPlatGreenQuicPlusValidLcore(Lcore)) {\n        atomic_fetch_or_explicit(&LcoreTransientHints[Lcore], Hints, memory_order_relaxed);\n        atomic_store_explicit(&LcoreTransientUntilNs[Lcore], Now + GQPLUS_TRANSIENT_TTL_NS, memory_order_relaxed);\n    } else {\n        atomic_fetch_or_explicit(&UnknownTransientHints, Hints, memory_order_relaxed);\n        atomic_store_explicit(&UnknownTransientUntilNs, Now + GQPLUS_TRANSIENT_TTL_NS, memory_order_relaxed);\n    }\n}\n\nvoid CxPlatGreenQuicPlusPulseHints(uint64_t Hints)\n{\n    CxPlatGreenQuicPlusPulseHintsForLcore(ThreadLcore, Hints);\n}\n\nstatic uint64_t CxPlatGreenQuicPlusGetUnknownTransient(uint64_t Now)\n{\n    const uint64_t Until = atomic_load_explicit(&UnknownTransientUntilNs, memory_order_relaxed);\n    if (Now <= Until) {\n        return atomic_load_explicit(&UnknownTransientHints, memory_order_relaxed);\n    }\n    atomic_store_explicit(&UnknownTransientHints, 0, memory_order_relaxed);\n    return 0;\n}\n\nstatic uint64_t CxPlatGreenQuicPlusGetLcoreTransient(uint16_t Lcore, uint64_t Now)\n{\n    if (!CxPlatGreenQuicPlusValidLcore(Lcore)) {\n        return 0;\n    }\n    const uint64_t Until = atomic_load_explicit(&LcoreTransientUntilNs[Lcore], memory_order_relaxed);\n    if (Now <= Until) {\n        return atomic_load_explicit(&LcoreTransientHints[Lcore], memory_order_relaxed);\n    }\n    atomic_store_explicit(&LcoreTransientHints[Lcore], 0, memory_order_relaxed);\n    return 0;\n}\n\nuint64_t CxPlatGreenQuicPlusGetHints(void)\n{\n    const uint64_t Now = CxPlatGreenQuicPlusNowNs();\n    const uint64_t Persistent = atomic_load_explicit(&PersistentHints, memory_order_acquire);\n    return Persistent | CxPlatGreenQuicPlusGetUnknownTransient(Now);\n}\n\nuint64_t CxPlatGreenQuicPlusGetHintsForLcore(uint16_t Lcore, int IncludeUnknownGlobalHints)\n{\n    const uint64_t Now = CxPlatGreenQuicPlusNowNs();\n    uint64_t Hints = CxPlatGreenQuicPlusGetLcoreTransient(Lcore, Now);\n    if (IncludeUnknownGlobalHints) {\n        Hints |= atomic_load_explicit(&PersistentHints, memory_order_acquire);\n        Hints |= CxPlatGreenQuicPlusGetUnknownTransient(Now);\n    }\n    return Hints;\n}\n'

def patch_multicore_plus_hint_api(repo: Path) -> None:
    """Only used by --enable-multi-core. Replaces global-only hint storage with local+unknown buckets."""
    write_new_or_replace(repo / "src/inc/greenquic_plus.h", MULTICORE_GREENQUIC_PLUS_H)
    write_new_or_replace(repo / "src/platform/greenquic_plus.c", MULTICORE_GREENQUIC_PLUS_C)
    log("Patched GreenQUIC+ with lcore-local transient hints for optional multi-core mode.")

def patch_multicore_support_v12(repo: Path) -> None:
    """Patch optional multi-core DPDK support on top of the v10 datapath. Kept for v13 layering."""
    patch_multicore_plus_hint_api(repo)
    path = repo / "src/platform/datapath_raw_dpdk.c"
    log(f"Patching optional multi-core DPDK support in {path}")
    ensure_file(path)
    backup(path)
    text = read_text(path)

    rss_aliases = '''
#ifndef RTE_ETH_MQ_RX_RSS
#define RTE_ETH_MQ_RX_RSS ETH_MQ_RX_RSS
#endif
#ifndef RTE_ETH_RSS_IP
#define RTE_ETH_RSS_IP ETH_RSS_IP
#endif
#ifndef RTE_ETH_RSS_UDP
#define RTE_ETH_RSS_UDP ETH_RSS_UDP
#endif
'''
    if "GREENQUIC-BEGIN: DPDK RSS compatibility aliases" not in text:
        text = insert_after(
            text,
            '#include <stdlib.h>\n',
            '// GREENQUIC-BEGIN: DPDK RSS compatibility aliases\n' + rss_aliases + '// GREENQUIC-END\n',
            "DPDK RSS compatibility aliases")

    if "BOOLEAN GreenQuicEnableMultiCore;" not in text:
        text = insert_after(
            text,
            '    char GreenQuicDpdkLcores[64];    // optional EAL -l string, e.g., "8" or "8,9"; no multi-queue magic\n',
            '    BOOLEAN GreenQuicEnableMultiCore; // runtime opt-in: GreenQuicEnableMultiCore=1 enables multi-queue/RSS mapping\n'
            '    uint16_t GreenQuicQueueCount;     // actual RX/TX queue count used by optional multi-core path\n'
            '    uint32_t GreenQuicHintLocalityWindowUs; // gate global PLUS hints to lcores with recent local datapath activity\n',
            "multi-core fields")

    if "Dpdk->GreenQuicEnableMultiCore = FALSE;" not in text:
        text = insert_after(
            text,
            "    Dpdk->GreenQuicDpdkLcores[0] = '\\0';\n",
            '    Dpdk->GreenQuicEnableMultiCore = FALSE;\n'
            '    Dpdk->GreenQuicQueueCount = 1;\n'
            '    Dpdk->GreenQuicHintLocalityWindowUs = 2000;\n',
            "multi-core defaults")

    if "GreenQuicGetQueueId(" not in text.split("// GREENQUIC-BEGIN: helper prototypes",1)[1].split("// GREENQUIC-END",1)[0]:
        text = insert_after(
            text,
            'static GREENQUIC_LCORE_STATE* GreenQuicGetLcoreState(_Inout_ DPDK_DATAPATH* Dpdk, _In_ uint16_t Core);\n',
            'static uint16_t GreenQuicGetQueueId(_In_ const DPDK_DATAPATH* Dpdk, _In_ uint16_t Core);\n'
            'static BOOLEAN GreenQuicHasLocalRecentActivity(_In_ const DPDK_DATAPATH* Dpdk, _In_ const GREENQUIC_LCORE_STATE* S);\n',
            "multi-core helper prototypes")

    helper_impl = '''
static uint16_t
GreenQuicGetQueueId(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ uint16_t Core
    )
{
    if (!Dpdk->GreenQuicEnableMultiCore || Dpdk->GreenQuicQueueCount <= 1) {
        return 0;
    }

    const int LcoreIndex = rte_lcore_index(Core);
    if (LcoreIndex < 0) {
        return 0;
    }

    return (uint16_t)((uint16_t)LcoreIndex % Dpdk->GreenQuicQueueCount);
}

static BOOLEAN
GreenQuicHasLocalRecentActivity(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ const GREENQUIC_LCORE_STATE* S
    )
{
    if (!Dpdk->GreenQuicEnableMultiCore) {
        return TRUE;
    }

    if (S->Rx.LastBurstCount != 0 || S->Tx.LastBurstCount != 0 ||
        S->Rx.LastQueueCount != 0 || S->Tx.LastQueueCount != 0 ||
        S->LastTxRingCount != 0) {
        return TRUE;
    }

    const uint64_t Now = rte_get_tsc_cycles();
    if (S->Rx.LastActiveTsc != 0 &&
        GreenQuicTscDeltaToUs(Now - S->Rx.LastActiveTsc) <= Dpdk->GreenQuicHintLocalityWindowUs) {
        return TRUE;
    }

    if (S->Tx.LastActiveTsc != 0 &&
        GreenQuicTscDeltaToUs(Now - S->Tx.LastActiveTsc) <= Dpdk->GreenQuicHintLocalityWindowUs) {
        return TRUE;
    }

    return FALSE;
}

static uint64_t
GreenQuicGetHintsForCore(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ const GREENQUIC_LCORE_STATE* S,
    _In_ uint16_t Core
    )
{
    if (!Dpdk->GreenQuicEnableMultiCore) {
        return CxPlatGreenQuicPlusGetHints();
    }

    return CxPlatGreenQuicPlusGetHintsForLcore(
        Core,
        GreenQuicHasLocalRecentActivity(Dpdk, S) ? 1 : 0);
}

'''
    if "GreenQuicHasLocalRecentActivity" not in text.split("// GREENQUIC-BEGIN: helper implementations",1)[1].split("GreenQuicPowerInit",1)[0]:
        marker = '''static void
GreenQuicPowerInit(
'''
        text = insert_before(text, marker, helper_impl, "multi-core helper implementations")

    proto_block = text.split("// GREENQUIC-BEGIN: helper prototypes", 1)[1].split("// GREENQUIC-END", 1)[0]
    if "GreenQuicGetHintsForCore" not in proto_block:
        text = insert_after(
            text,
            'static BOOLEAN GreenQuicHasLocalRecentActivity(_In_ const DPDK_DATAPATH* Dpdk, _In_ const GREENQUIC_LCORE_STATE* S);\n',
            'static uint64_t GreenQuicGetHintsForCore(_In_ const DPDK_DATAPATH* Dpdk, _In_ const GREENQUIC_LCORE_STATE* S, _In_ uint16_t Core);\n',
            "multi-core per-lcore hint getter prototype")

    if 'strcmp(Line, "GreenQuicEnableMultiCore")' not in text:
        text = insert_before(
            text,
            '        } else if (strcmp(Line, "GreenQuicEnableFreq") == 0) {\n',
            '        } else if (strcmp(Line, "GreenQuicEnableMultiCore") == 0) {\n'
            '            Dpdk->GreenQuicEnableMultiCore = atoi(Value) != 0 ? TRUE : FALSE;\n'
            '        } else if (strcmp(Line, "GreenQuicHintLocalityWindowUs") == 0) {\n'
            '            Dpdk->GreenQuicHintLocalityWindowUs = (uint32_t)atoi(Value);\n'
            '            if (Dpdk->GreenQuicHintLocalityWindowUs == 0) {\n'
            '                Dpdk->GreenQuicHintLocalityWindowUs = 1;\n'
            '            }\n',
            "multi-core config parser")

    old_warning = '''    if (strchr(DpdpCpuStr, ',') != NULL || strchr(DpdpCpuStr, '-') != NULL) {
        printf("GreenQUIC warning: multiple DPDK lcores requested with -l %s. "
               "GreenQUIC per-lcore state is ready, but the original MsQuic DPDK path still uses RX/TX queue 0. "
               "Add real queue mapping before treating this as true multi-core scaling.\\n", DpdpCpuStr);
    }
'''
    new_warning = '''    if (strchr(DpdpCpuStr, ',') != NULL || strchr(DpdpCpuStr, '-') != NULL) {
        if (Dpdk->GreenQuicEnableMultiCore) {
            printf("GreenQUIC multi-core requested with -l %s; RSS/queue mapping will be enabled after port discovery.\\n", DpdpCpuStr);
        } else {
            printf("GreenQUIC warning: multiple DPDK lcores requested with -l %s, but GreenQuicEnableMultiCore=0. "
                   "Only v10-style behavior is active. Set GreenQuicEnableMultiCore=1 after patching with --enable-multi-core.\\n", DpdpCpuStr);
        }
    }
'''
    if old_warning in text:
        text = text.replace(old_warning, new_warning, 1)

    text = text.replace('    const uint16_t rx_rings = 1, tx_rings = 1;\n', '    uint16_t rx_rings = 1, tx_rings = 1;\n', 1)

    multicore_setup = '''

    // GREENQUIC-BEGIN: optional multi-core queue/RSS setup
    if (Dpdk->GreenQuicEnableMultiCore) {
        const unsigned int EnabledLcores = rte_lcore_count();
        if (EnabledLcores <= 1) {
            printf("GreenQUIC multi-core requested but EAL has only %u lcore; using one queue.\\n", EnabledLcores);
        } else {
            uint16_t DesiredQueues = EnabledLcores > UINT16_MAX ? UINT16_MAX : (uint16_t)EnabledLcores;
            if (DeviceInfo.max_rx_queues != 0 && DesiredQueues > DeviceInfo.max_rx_queues) {
                DesiredQueues = DeviceInfo.max_rx_queues;
            }
            if (DeviceInfo.max_tx_queues != 0 && DesiredQueues > DeviceInfo.max_tx_queues) {
                DesiredQueues = DeviceInfo.max_tx_queues;
            }
            if (DesiredQueues == 0) {
                DesiredQueues = 1;
            }

            rx_rings = DesiredQueues;
            tx_rings = DesiredQueues;
            Dpdk->GreenQuicQueueCount = DesiredQueues;

            if (Dpdk->GreenQuicQueueCount > 1) {
                PortConfig.rxmode.mq_mode = RTE_ETH_MQ_RX_RSS;
                uint64_t RssHf = RTE_ETH_RSS_IP | RTE_ETH_RSS_UDP;
                if (DeviceInfo.flow_type_rss_offloads != 0) {
                    const uint64_t Supported = RssHf & DeviceInfo.flow_type_rss_offloads;
                    RssHf = Supported != 0 ? Supported : DeviceInfo.flow_type_rss_offloads;
                }
                PortConfig.rx_adv_conf.rss_conf.rss_hf = RssHf;
                printf("GreenQUIC multi-core enabled: lcores=%u rxq=%hu txq=%hu rss_hf=0x%" PRIx64 "\\n",
                       EnabledLcores, rx_rings, tx_rings, RssHf);
            }
        }
    }
    // GREENQUIC-END
'''
    if "GREENQUIC-BEGIN: optional multi-core queue/RSS setup" not in text:
        text = insert_after(text, '    Dpdk->Interface.IfIndex = DeviceInfo.if_index;\n', multicore_setup, "multi-core queue/RSS setup")

    old_ring_flags = '''            "TxRing", TX_RING_SIZE, rte_eth_dev_socket_id(Port),
            RING_F_MP_HTS_ENQ | RING_F_SC_DEQ);'''
    new_ring_flags = '''            "TxRing", TX_RING_SIZE, rte_eth_dev_socket_id(Port),
            Dpdk->GreenQuicEnableMultiCore ? 0 : (RING_F_MP_HTS_ENQ | RING_F_SC_DEQ));'''
    if old_ring_flags in text:
        text = text.replace(old_ring_flags, new_ring_flags, 1)

    if "const uint16_t QueueId = GreenQuicGetQueueId(Dpdk, Core);" not in text.split("CxPlatDpdkRx",1)[1].split("CxPlatDpRawRxFree",1)[0]:
        text = insert_after(text, '    void* Buffers[RX_BURST_SIZE];\n', '    const uint16_t QueueId = GreenQuicGetQueueId(Dpdk, Core);\n', "RX queue-id mapping")
    text = text.replace('RxQueueCountBefore = rte_eth_rx_queue_count(Interface->Port, 0);', 'RxQueueCountBefore = rte_eth_rx_queue_count(Interface->Port, QueueId);')
    text = text.replace('rte_eth_rx_burst(Interface->Port, 0, (struct rte_mbuf**)Buffers, RX_BURST_SIZE);', 'rte_eth_rx_burst(Interface->Port, QueueId, (struct rte_mbuf**)Buffers, RX_BURST_SIZE);')

    tx_body = text.split("static\nvoid\nCxPlatDpdkTx(", 1)[1].split("static\nint\nCxPlatDpdkWorkerThread", 1)[0]
    if "const uint16_t QueueId = GreenQuicGetQueueId(Dpdk, Core);" not in tx_body:
        text = text.replace(
            '    struct rte_mbuf* Buffers[TX_BURST_SIZE];\n    const uint32_t RingBefore = rte_ring_count(Interface->TxRingBuffer);',
            '    struct rte_mbuf* Buffers[TX_BURST_SIZE];\n    const uint16_t QueueId = GreenQuicGetQueueId(Dpdk, Core);\n    const uint32_t RingBefore = rte_ring_count(Interface->TxRingBuffer);',
            1)
    old_deq = '''    const uint16_t BufferCount =
        (uint16_t)rte_ring_sc_dequeue_burst(
            Interface->TxRingBuffer, (void**)Buffers, TX_BURST_SIZE, NULL);'''
    new_deq = '''    const uint16_t BufferCount = Dpdk->GreenQuicEnableMultiCore ?
        (uint16_t)rte_ring_mc_dequeue_burst(
            Interface->TxRingBuffer, (void**)Buffers, TX_BURST_SIZE, NULL) :
        (uint16_t)rte_ring_sc_dequeue_burst(
            Interface->TxRingBuffer, (void**)Buffers, TX_BURST_SIZE, NULL);'''
    if old_deq in text:
        text = text.replace(old_deq, new_deq, 1)
    text = text.replace('rte_eth_tx_burst(Interface->Port, 0, Buffers, BufferCount);', 'rte_eth_tx_burst(Interface->Port, QueueId, Buffers, BufferCount);')

    old_hints = '''    const uint64_t Hints = CxPlatGreenQuicPlusGetHints();
    BOOLEAN PlusHardMax = FALSE;
    const uint32_t PlusPressure = GreenQuicPlusPressure(Dpdk, Hints, RxPressure, TxPressure, &PlusHardMax);'''
    new_hints = '''    const uint64_t Hints = GreenQuicGetHintsForCore(Dpdk, S, Core);
    BOOLEAN PlusHardMax = FALSE;
    const uint32_t PlusPressure = GreenQuicPlusPressure(Dpdk, Hints, RxPressure, TxPressure, &PlusHardMax);'''
    if old_hints in text:
        text = text.replace(old_hints, new_hints, 1)

    text = text.replace(
        'static uint32_t GreenQuicComputeRawPressure(_In_ const DPDK_DATAPATH* Dpdk, _In_ GREENQUIC_LCORE_STATE* S, _In_ uint32_t TxRingCount, _Out_ BOOLEAN* HardMax);',
        'static uint32_t GreenQuicComputeRawPressure(_In_ const DPDK_DATAPATH* Dpdk, _In_ GREENQUIC_LCORE_STATE* S, _In_ uint16_t Core, _In_ uint32_t TxRingCount, _Out_ BOOLEAN* HardMax);')
    text = text.replace(
        '''GreenQuicComputeRawPressure(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ GREENQUIC_LCORE_STATE* S,
    _In_ uint32_t TxRingCount,
    _Out_ BOOLEAN* HardMax
    )''',
        '''GreenQuicComputeRawPressure(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ GREENQUIC_LCORE_STATE* S,
    _In_ uint16_t Core,
    _In_ uint32_t TxRingCount,
    _Out_ BOOLEAN* HardMax
    )''')
    text = text.replace(
        'GreenQuicComputeRawPressure(Dpdk, S, TxRingCount, &HardMax)',
        'GreenQuicComputeRawPressure(Dpdk, S, Core, TxRingCount, &HardMax)')

    old_transfer_hints = '''    const uint64_t Hints = CxPlatGreenQuicPlusGetHints();
    if (GreenQuicPlusHasActiveTransferHint(Dpdk, Hints)) {'''
    new_transfer_hints = '''    const uint64_t Hints = GreenQuicGetHintsForCore(Dpdk, S, Core);
    if (GreenQuicPlusHasActiveTransferHint(Dpdk, Hints)) {'''
    if old_transfer_hints in text:
        text = text.replace(old_transfer_hints, new_transfer_hints, 1)

    if 'CxPlatGreenQuicPlusSetThreadLcore(Core);' not in text:
        text = insert_after(
            text,
            '    GreenQuicPowerInit(Dpdk, Core);\n',
            '    CxPlatGreenQuicPlusSetThreadLcore(Core);\n',
            'thread-local lcore hint context')
    if 'CxPlatGreenQuicPlusClearThreadLcore();' not in text:
        text = insert_before(
            text,
            '    GreenQuicPowerCleanup(Dpdk, Core);\n',
            '    CxPlatGreenQuicPlusClearThreadLcore();\n',
            'thread-local lcore hint cleanup')

    write_text(path, text)

    ini = repo / "dpdk.greenquic.example.ini"
    if ini.exists():
        itext = read_text(ini)
        if "GreenQuicEnableMultiCore" not in itext:
            itext += '''

# Optional multi-core path. This section only works if the autopatcher was run with --enable-multi-core.
# Keep this OFF for first sequential tests. Enable only when you want multiple DPDK lcores/queues.
# Use separate QUIC connections for parallel requests if you want RSS to distribute work across queues.
# Multiple HTTP/3 streams inside one QUIC connection usually stay one UDP 5-tuple and may map to one queue.
# GreenQuicDpdkLcores=8,9,10,11
# GreenQuicEnableMultiCore=1
# GreenQuicHintLocalityWindowUs=2000
'''
            write_text(ini, itext)

    log("Optional multi-core DPDK support patched. Runtime default remains GreenQuicEnableMultiCore=0.")

def apply_all_patches(repo: Path, basic_only: bool, enable_multi_core: bool = False) -> None:
    patch_greenquic_plus_files(repo)
    patch_datapath(repo)
    if basic_only:
        warn("BASIC-only selected: GreenQUIC+ files are created and compiled, but ACK/CUBIC/tool hooks are skipped. Run mode=basic.")
    else:
        patch_precomp(repo)
        patch_ack_tracker(repo)
        patch_cubic(repo)
        patch_server_header(repo)
        patch_server_tool(repo)
        patch_client_tool(repo)
    patch_cmake(repo)
    if enable_multi_core:
        patch_multicore_support(repo, basic_only)
    else:
        log("Optional multi-core patch not requested; keeping v10 single-queue datapath behavior.")
    post_compile_safety_fixes(repo, enable_multi_core)
    log("All patches applied.")



# =============================================================================
# V16 compile-safety fixes for current MsQuic raw datapath API
# =============================================================================

def _replace_if_present(text: str, old: str, new: str) -> str:
    return text.replace(old, new) if old in text else text


def post_compile_safety_fixes(repo: Path, enable_multi_core: bool) -> None:
    # Fixes found by compiling patched sources against current MsQuic headers.
    # These do not change the old policy logic; they adapt the rudimentary DPDK
    # datapath to the current CXPLAT_DATAPATH_RAW API and make GreenQUIC+ link
    # whenever ACK/CUBIC hooks are compiled.
    dp = repo / "src/platform/datapath_raw_dpdk.c"
    if dp.exists():
        t = read_text(dp)

        alias_anchor = "// GREENQUIC-END\n#ifndef _WIN32"
        alias_block = """// GREENQUIC-END

// GREENQUIC-BEGIN: DPDK mbuf/offload compatibility aliases
#ifndef DEV_TX_OFFLOAD_IPV4_CKSUM
#define DEV_TX_OFFLOAD_IPV4_CKSUM RTE_ETH_TX_OFFLOAD_IPV4_CKSUM
#endif
#ifndef DEV_TX_OFFLOAD_UDP_CKSUM
#define DEV_TX_OFFLOAD_UDP_CKSUM RTE_ETH_TX_OFFLOAD_UDP_CKSUM
#endif
#ifndef DEV_RX_OFFLOAD_IPV4_CKSUM
#define DEV_RX_OFFLOAD_IPV4_CKSUM RTE_ETH_RX_OFFLOAD_IPV4_CKSUM
#endif
#ifndef DEV_RX_OFFLOAD_UDP_CKSUM
#define DEV_RX_OFFLOAD_UDP_CKSUM RTE_ETH_RX_OFFLOAD_UDP_CKSUM
#endif
#ifndef PKT_RX_IP_CKSUM_BAD
#define PKT_RX_IP_CKSUM_BAD RTE_MBUF_F_RX_IP_CKSUM_BAD
#endif
#ifndef PKT_RX_L4_CKSUM_BAD
#define PKT_RX_L4_CKSUM_BAD RTE_MBUF_F_RX_L4_CKSUM_BAD
#endif
#ifndef PKT_TX_IPV4
#define PKT_TX_IPV4 RTE_MBUF_F_TX_IPV4
#endif
#ifndef PKT_TX_IP_CKSUM
#define PKT_TX_IP_CKSUM RTE_MBUF_F_TX_IP_CKSUM
#endif
#ifndef PKT_TX_UDP_CKSUM
#define PKT_TX_UDP_CKSUM RTE_MBUF_F_TX_UDP_CKSUM
#endif
#ifndef likely
#define likely(x) __builtin_expect(!!(x), 1)
#endif
#ifndef unlikely
#define unlikely(x) __builtin_expect(!!(x), 0)
#endif
// GREENQUIC-END
#ifndef _WIN32"""
        if "DPDK mbuf/offload compatibility aliases" not in t:
            if alias_anchor in t:
                t = t.replace(alias_anchor, alias_block)
            else:
                # Single-core/non-multi-core path may not have the optional RSS alias anchor.
                # Insert the compatibility aliases after the last DPDK include so both
                # --enable-multi-core and default paths compile against old/new DPDK names.
                include_anchor = "#include <rte_power.h>\n"
                if include_anchor in t:
                    alias_block_for_includes = alias_block.split("// GREENQUIC-END\n#ifndef _WIN32", 1)[0]
                    if alias_block_for_includes.startswith("// GREENQUIC-END\n\n"):
                        alias_block_for_includes = alias_block_for_includes[len("// GREENQUIC-END\n\n"):]
                    t = t.replace(include_anchor, include_anchor + "\n" + alias_block_for_includes + "\n", 1)
                else:
                    raise RuntimeError("Could not find DPDK include anchor for compatibility aliases")

        t = _replace_if_present(t, "    CXPLAT_DATAPATH;\n\n    BOOLEAN Running;", "    CXPLAT_DATAPATH_RAW;\n\n    BOOLEAN Running;")
        if "uint16_t Cpu; // GREENQUIC" not in t:
            t = t.replace("    DPDK_INTERFACE Interface; // TODO: support multiple NIC interfaces.\n", "    DPDK_INTERFACE Interface; // TODO: support multiple NIC interfaces.\n    uint16_t Cpu; // GREENQUIC: DPDK EAL primary lcore when GreenQuicDpdkLcores is not set.\n")

        t = t.replace("_In_opt_ CXPLAT_DATAPATH_CONFIG* Config", "_In_opt_ const QUIC_EXECUTION_CONFIG* Config")
        t = t.replace("if (Config != NULL && Config->DataPathProcList != NULL) {\n        Dpdk->Cpu = Config->DataPathProcList[0];\n    }", "if (Config != NULL && Config->ProcessorCount != 0) {\n        Dpdk->Cpu = Config->ProcessorList[0];\n    }")

        t = t.replace("CxPlatDpRawInitialize(\n    _Inout_ CXPLAT_DATAPATH* Datapath,", "CxPlatDpRawInitialize(\n    _Inout_ CXPLAT_DATAPATH_RAW* Datapath,")
        t = t.replace("CxPlatDpRawUninitialize(\n    _In_ CXPLAT_DATAPATH* Datapath", "CxPlatDpRawUninitialize(\n    _In_ CXPLAT_DATAPATH_RAW* Datapath")
        t = t.replace("CxPlatDpRawUpdateConfig(\n    _In_ CXPLAT_DATAPATH* Datapath,", "CxPlatDpRawUpdateConfig(\n    _In_ CXPLAT_DATAPATH_RAW* Datapath,")
        t = t.replace("CxPlatDpRawPlumbRulesOnSocket(\n    _In_ CXPLAT_SOCKET* Socket,", "CxPlatDpRawPlumbRulesOnSocket(\n    _In_ CXPLAT_SOCKET_RAW* Socket,")
        t = t.replace("CxPlatDpRawTxAlloc(\n    _In_ CXPLAT_DATAPATH* Datapath,", "CxPlatDpRawTxAlloc(\n    _In_ CXPLAT_SOCKET_RAW* Socket,")

        t = t.replace("CXPLAT_THREAD_CONFIG Config = {\n        0, 0, \"DpdkMain\", CxPlatDpdkMainThread, Dpdk\n    };", "CXPLAT_THREAD_CONFIG ThreadConfig = {\n        0, 0, \"DpdkMain\", CxPlatDpdkMainThread, Dpdk\n    };")
        t = t.replace("CxPlatThreadCreate(&Config, &Dpdk->DpdkThread)", "CxPlatThreadCreate(&ThreadConfig, &Dpdk->DpdkThread)")

        t = t.replace("CxPlatDpRawRxEthernet((CXPLAT_DATAPATH*)Dpdk,", "CxPlatDpRawRxEthernet((CXPLAT_DATAPATH_RAW*)Dpdk,")
        t = t.replace("Route->Queue = Interface;", "Route->Queue = (CXPLAT_INTERFACE*)Interface;")

        t = t.replace("DPDK_DATAPATH* Dpdk = (DPDK_DATAPATH*)Datapath;\n    DPDK_TX_PACKET* Packet = CxPlatPoolAlloc(&Dpdk->AdditionalInfoPool);", "DPDK_DATAPATH* Dpdk = (DPDK_DATAPATH*)Socket->RawDatapath;\n    DPDK_TX_PACKET* Packet = CxPlatPoolAlloc(&Dpdk->AdditionalInfoPool);")
        t = t.replace("HEADER_BACKFILL HeaderFill = CxPlatDpRawCalculateHeaderBackFill(Family);", "HEADER_BACKFILL HeaderFill = CxPlatDpRawCalculateHeaderBackFill(Family, Socket->UseTcp);")
        t = t.replace("CXPLAT_CXPLAT_CONTAINING_RECORD(", "CXPLAT_CONTAINING_RECORD(")
        if "CONTAINING_RECORD(" in t:
            import re
            t = re.sub(r"(?<!CXPLAT_)CONTAINING_RECORD\(", "CXPLAT_CONTAINING_RECORD(", t)

        old_mib = """    //
    // Retrieve ifindex of the interface to which DPDK is binding.
    //
    MIB_IF_TABLE2* IfTable;
    Status = GetIfTable2(&IfTable);
    if (QUIC_FAILED(Status)) {
        QuicTraceEvent(
            LibraryErrorStatus,
            \"[ lib] ERROR, %u, %s.\",
            Status,
            \"GetIfTable2\");
        goto Error;
    }

    for (uint32_t i = 0; i < IfTable->NumEntries; i++) {
        MIB_IF_ROW2* IfRow = (MIB_IF_ROW2*)&IfTable->Table[i];
        if (!IfRow->InterfaceAndOperStatusFlags.FilterInterface &&
            !IfRow->InterfaceAndOperStatusFlags.NotMediaConnected &&
            !IfRow->InterfaceAndOperStatusFlags.Paused &&
            IfRow->OperStatus == IfOperStatusUp &&
            IfRow->MediaType == NdisMedium802_3 &&
            IfRow->PhysicalAddressLength == 6 &&
            memcmp(IfRow->PhysicalAddress, addr.addr_bytes, IfRow->PhysicalAddressLength) == 0) {
            Dpdk->Interface.IfIndex = IfRow->InterfaceIndex;
            break;
        }
    }
"""
        new_mib = """    //
    // Linux DPDK path: use the DPDK MAC address directly. The if_index, when
    // available from the PMD, was copied from rte_eth_dev_info.if_index above.
    //
    CxPlatCopyMemory(Dpdk->Interface.PhysicalAddress, addr.addr_bytes, sizeof(Dpdk->Interface.PhysicalAddress));
"""
        t = _replace_if_present(t, old_mib, new_mib)

        write_text(dp, t)
        log("V16 compile-safety fixes applied to datapath_raw_dpdk.c for current CXPLAT_DATAPATH_RAW API.")

    gp = repo / "src/platform/greenquic_plus.c"
    if gp.exists():
        g = read_text(gp)
        old_get = """uint64_t CxPlatGreenQuicPlusGetHints(void)
{
    const uint64_t Now = CxPlatGreenQuicPlusNowNs();
    const uint64_t Persistent = atomic_load_explicit(&PersistentHints, memory_order_acquire);
    return Persistent | CxPlatGreenQuicPlusGetUnknownTransient(Now);
}
"""
        new_get = """uint64_t CxPlatGreenQuicPlusGetHints(void)
{
    const uint64_t Now = CxPlatGreenQuicPlusNowNs();
    uint64_t Hints = atomic_load_explicit(&PersistentHints, memory_order_acquire) |
        CxPlatGreenQuicPlusGetUnknownTransient(Now);
    for (uint16_t Lcore = 0; Lcore < GQPLUS_MAX_LCORES; ++Lcore) {
        Hints |= CxPlatGreenQuicPlusGetLcoreTransient(Lcore, Now);
    }
    return Hints;
}
"""
        if old_get in g:
            g = g.replace(old_get, new_get)
            write_text(gp, g)
            log("V16 fixed GreenQUIC+ fallback GetHints to include lcore-local transient hints.")

    cm = repo / "src/platform/CMakeLists.txt"
    if cm.exists():
        c = read_text(cm)
        c = c.replace("set(SOURCES crypt.c hashtable.c pcp.c platform_worker.c toeplitz.c)",
                      "set(SOURCES crypt.c hashtable.c pcp.c platform_worker.c toeplitz.c greenquic_plus.c)")
        c = c.replace("datapath_xplat.c datapath_raw.c datapath_raw_dpdk.c greenquic_plus.c", "datapath_xplat.c datapath_raw.c datapath_raw_dpdk.c")
        write_text(cm, c)
        log("V16 CMake fix: greenquic_plus.c is compiled once, outside the DPDK-only source branch.")


# =============================================================================
# V13 optional multi-core: partition mapped QUIC hints
# =============================================================================

MULTICORE_PARTITION_GREENQUIC_PLUS_H = r'''/*++

    GreenQUIC Plus public hint API.

    Default API remains process-safe and v10-compatible.
    The optional --enable-multi-core patch adds partition-to-DPDK-lcore mapping.

    Goal:
      Every ACK/CUBIC QUIC hint should target a concrete DPDK datapath lcore
      when the QUIC connection's MsQuic worker partition is known.

--*/

#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GQPLUS_LCORE_UNKNOWN              ((uint16_t)0xffffu)
#define GQPLUS_PARTITION_UNKNOWN          ((uint16_t)0xffffu)

#define GQPLUS_HINT_ACK_PENDING             (1ull << 0)
#define GQPLUS_HINT_CUBIC_CWND_BLOCKED     (1ull << 1)
#define GQPLUS_HINT_CUBIC_RECOVERY         (1ull << 2)
#define GQPLUS_HINT_CUBIC_RAMPING          (1ull << 3)

#define GQPLUS_HINT_SERVER_FILE_TX_ACTIVE  (1ull << 16)
#define GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE  (1ull << 17)

void CxPlatGreenQuicPlusSetThreadLcore(uint16_t Lcore);
void CxPlatGreenQuicPlusClearThreadLcore(void);

void CxPlatGreenQuicPlusSetPartitionDpdkLcore(uint16_t Partition, uint16_t Lcore);
uint16_t CxPlatGreenQuicPlusGetPartitionDpdkLcore(uint16_t Partition);

void CxPlatGreenQuicPlusSetHints(uint64_t Hints);
void CxPlatGreenQuicPlusClearHints(uint64_t Hints);
void CxPlatGreenQuicPlusBeginTransfer(uint64_t Hints);
void CxPlatGreenQuicPlusEndTransfer(uint64_t Hints);

void CxPlatGreenQuicPlusPulseHints(uint64_t Hints);
void CxPlatGreenQuicPlusPulseHintsForLcore(uint16_t Lcore, uint64_t Hints);
void CxPlatGreenQuicPlusPulseHintsForPartition(uint16_t Partition, uint64_t Hints);

uint64_t CxPlatGreenQuicPlusGetHints(void);
uint64_t CxPlatGreenQuicPlusGetHintsForLcore(uint16_t Lcore, int IncludeUnknownGlobalHints);

#ifdef __cplusplus
}
#endif
'''

MULTICORE_PARTITION_GREENQUIC_PLUS_C = r'''/*++

    GreenQUIC Plus hint storage with partition-to-DPDK-lcore mapping.

    Design:
      - ACK/CUBIC transient hints should target a DPDK lcore.
      - MsQuic core hooks call PulseHintsForPartition(Connection->Worker->PartitionIndex, Hint).
      - The datapath reads GreenQuicPartitionDpdkMap from dpdk.ini and installs:
            MsQuic worker partition -> DPDK lcore
      - If a partition has no mapping, the code falls back to thread-local lcore
        if available; otherwise it enters an unknown bucket admitted only for
        locally active lcores. With a correct map, ACK/CUBIC should not be unknown.
      - Transfer hints remain global reference-counted because tool/app callbacks
        do not reliably know the RSS queue/lcore owner of a request. They still
        influence only active DPDK lcores because pressure combines them with local RX/TX.

--*/

#define _POSIX_C_SOURCE 200809L

#include "greenquic_plus.h"

#include <stdatomic.h>
#include <stdint.h>
#include <time.h>

#define GQPLUS_TRANSIENT_TTL_NS (2ull * 1000ull * 1000ull)
#define GQPLUS_TRANSFER_HINTS (GQPLUS_HINT_SERVER_FILE_TX_ACTIVE | GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE)
#define GQPLUS_MAX_LCORES 512u
#define GQPLUS_MAX_PARTITIONS 512u

#if defined(_MSC_VER)
__declspec(thread) static uint16_t ThreadLcore = GQPLUS_LCORE_UNKNOWN;
#else
static _Thread_local uint16_t ThreadLcore = GQPLUS_LCORE_UNKNOWN;
#endif

static atomic_uint_fast64_t PersistentHints;
static atomic_uint_fast64_t UnknownTransientHints;
static atomic_uint_fast64_t UnknownTransientUntilNs;
static atomic_uint_fast64_t LcoreTransientHints[GQPLUS_MAX_LCORES];
static atomic_uint_fast64_t LcoreTransientUntilNs[GQPLUS_MAX_LCORES];
static atomic_uint_fast32_t ServerFileTxActiveCount;
static atomic_uint_fast32_t ClientFileRxActiveCount;

// Stores lcore + 1. Zero means unmapped, so real lcore 0 is representable.
static atomic_uint_fast32_t PartitionDpdkLcorePlusOne[GQPLUS_MAX_PARTITIONS];

static uint64_t CxPlatGreenQuicPlusNowNs(void)
{
    struct timespec Ts;
#if defined(CLOCK_MONOTONIC_RAW)
    clock_gettime(CLOCK_MONOTONIC_RAW, &Ts);
#else
    clock_gettime(CLOCK_MONOTONIC, &Ts);
#endif
    return ((uint64_t)Ts.tv_sec * 1000000000ull) + (uint64_t)Ts.tv_nsec;
}

static int CxPlatGreenQuicPlusValidLcore(uint16_t Lcore)
{
    return Lcore != GQPLUS_LCORE_UNKNOWN && Lcore < GQPLUS_MAX_LCORES;
}

static int CxPlatGreenQuicPlusValidPartition(uint16_t Partition)
{
    return Partition != GQPLUS_PARTITION_UNKNOWN && Partition < GQPLUS_MAX_PARTITIONS;
}

void CxPlatGreenQuicPlusSetThreadLcore(uint16_t Lcore)
{
    ThreadLcore = Lcore;
}

void CxPlatGreenQuicPlusClearThreadLcore(void)
{
    ThreadLcore = GQPLUS_LCORE_UNKNOWN;
}

void CxPlatGreenQuicPlusSetPartitionDpdkLcore(uint16_t Partition, uint16_t Lcore)
{
    if (!CxPlatGreenQuicPlusValidPartition(Partition)) {
        return;
    }

    if (CxPlatGreenQuicPlusValidLcore(Lcore)) {
        atomic_store_explicit(
            &PartitionDpdkLcorePlusOne[Partition],
            (uint_fast32_t)Lcore + 1u,
            memory_order_release);
    } else {
        atomic_store_explicit(&PartitionDpdkLcorePlusOne[Partition], 0u, memory_order_release);
    }
}

uint16_t CxPlatGreenQuicPlusGetPartitionDpdkLcore(uint16_t Partition)
{
    if (!CxPlatGreenQuicPlusValidPartition(Partition)) {
        return GQPLUS_LCORE_UNKNOWN;
    }

    const uint_fast32_t Stored = atomic_load_explicit(&PartitionDpdkLcorePlusOne[Partition], memory_order_acquire);
    if (Stored == 0) {
        return GQPLUS_LCORE_UNKNOWN;
    }

    return (uint16_t)(Stored - 1u);
}

static void CxPlatGreenQuicPlusIncrementHintCount(atomic_uint_fast32_t* Counter, uint64_t Hint)
{
    const uint_fast32_t Old = atomic_fetch_add_explicit(Counter, 1, memory_order_relaxed);
    if (Old == 0) {
        atomic_fetch_or_explicit(&PersistentHints, Hint, memory_order_release);
    }
}

static void CxPlatGreenQuicPlusDecrementHintCount(atomic_uint_fast32_t* Counter, uint64_t Hint)
{
    uint_fast32_t Old = atomic_load_explicit(Counter, memory_order_relaxed);
    while (Old != 0) {
        if (atomic_compare_exchange_weak_explicit(Counter, &Old, Old - 1, memory_order_acq_rel, memory_order_relaxed)) {
            if (Old == 1) {
                atomic_fetch_and_explicit(&PersistentHints, ~Hint, memory_order_release);
            }
            return;
        }
    }
}

void CxPlatGreenQuicPlusBeginTransfer(uint64_t Hints)
{
    if ((Hints & GQPLUS_HINT_SERVER_FILE_TX_ACTIVE) != 0) {
        CxPlatGreenQuicPlusIncrementHintCount(&ServerFileTxActiveCount, GQPLUS_HINT_SERVER_FILE_TX_ACTIVE);
    }
    if ((Hints & GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE) != 0) {
        CxPlatGreenQuicPlusIncrementHintCount(&ClientFileRxActiveCount, GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE);
    }
}

void CxPlatGreenQuicPlusEndTransfer(uint64_t Hints)
{
    if ((Hints & GQPLUS_HINT_SERVER_FILE_TX_ACTIVE) != 0) {
        CxPlatGreenQuicPlusDecrementHintCount(&ServerFileTxActiveCount, GQPLUS_HINT_SERVER_FILE_TX_ACTIVE);
    }
    if ((Hints & GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE) != 0) {
        CxPlatGreenQuicPlusDecrementHintCount(&ClientFileRxActiveCount, GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE);
    }
}

void CxPlatGreenQuicPlusSetHints(uint64_t Hints)
{
    atomic_fetch_or_explicit(&PersistentHints, Hints & ~GQPLUS_TRANSFER_HINTS, memory_order_relaxed);
    CxPlatGreenQuicPlusBeginTransfer(Hints & GQPLUS_TRANSFER_HINTS);
}

void CxPlatGreenQuicPlusClearHints(uint64_t Hints)
{
    atomic_fetch_and_explicit(&PersistentHints, ~(Hints & ~GQPLUS_TRANSFER_HINTS), memory_order_relaxed);
    CxPlatGreenQuicPlusEndTransfer(Hints & GQPLUS_TRANSFER_HINTS);
}

void CxPlatGreenQuicPlusPulseHintsForLcore(uint16_t Lcore, uint64_t Hints)
{
    const uint64_t Now = CxPlatGreenQuicPlusNowNs();
    if (CxPlatGreenQuicPlusValidLcore(Lcore)) {
        atomic_fetch_or_explicit(&LcoreTransientHints[Lcore], Hints, memory_order_relaxed);
        atomic_store_explicit(&LcoreTransientUntilNs[Lcore], Now + GQPLUS_TRANSIENT_TTL_NS, memory_order_relaxed);
    } else {
        atomic_fetch_or_explicit(&UnknownTransientHints, Hints, memory_order_relaxed);
        atomic_store_explicit(&UnknownTransientUntilNs, Now + GQPLUS_TRANSIENT_TTL_NS, memory_order_relaxed);
    }
}

void CxPlatGreenQuicPlusPulseHintsForPartition(uint16_t Partition, uint64_t Hints)
{
    const uint16_t Lcore = CxPlatGreenQuicPlusGetPartitionDpdkLcore(Partition);
    if (CxPlatGreenQuicPlusValidLcore(Lcore)) {
        CxPlatGreenQuicPlusPulseHintsForLcore(Lcore, Hints);
        return;
    }

    // Fallback: if the caller is a DPDK datapath thread, still target that lcore.
    // This should not be used for ACK/CUBIC when GreenQuicPartitionDpdkMap is set.
    CxPlatGreenQuicPlusPulseHintsForLcore(ThreadLcore, Hints);
}

void CxPlatGreenQuicPlusPulseHints(uint64_t Hints)
{
    // v10-compatible fallback API. Multi-core ACK/CUBIC hooks use ForPartition instead.
    CxPlatGreenQuicPlusPulseHintsForLcore(ThreadLcore, Hints);
}

static uint64_t CxPlatGreenQuicPlusGetUnknownTransient(uint64_t Now)
{
    const uint64_t Until = atomic_load_explicit(&UnknownTransientUntilNs, memory_order_relaxed);
    if (Now <= Until) {
        return atomic_load_explicit(&UnknownTransientHints, memory_order_relaxed);
    }
    atomic_store_explicit(&UnknownTransientHints, 0, memory_order_relaxed);
    return 0;
}

static uint64_t CxPlatGreenQuicPlusGetLcoreTransient(uint16_t Lcore, uint64_t Now)
{
    if (!CxPlatGreenQuicPlusValidLcore(Lcore)) {
        return 0;
    }
    const uint64_t Until = atomic_load_explicit(&LcoreTransientUntilNs[Lcore], memory_order_relaxed);
    if (Now <= Until) {
        return atomic_load_explicit(&LcoreTransientHints[Lcore], memory_order_relaxed);
    }
    atomic_store_explicit(&LcoreTransientHints[Lcore], 0, memory_order_relaxed);
    return 0;
}

uint64_t CxPlatGreenQuicPlusGetHints(void)
{
    const uint64_t Now = CxPlatGreenQuicPlusNowNs();
    const uint64_t Persistent = atomic_load_explicit(&PersistentHints, memory_order_acquire);
    return Persistent | CxPlatGreenQuicPlusGetUnknownTransient(Now);
}

uint64_t CxPlatGreenQuicPlusGetHintsForLcore(uint16_t Lcore, int IncludeUnknownGlobalHints)
{
    const uint64_t Now = CxPlatGreenQuicPlusNowNs();
    uint64_t Hints = CxPlatGreenQuicPlusGetLcoreTransient(Lcore, Now);

    // Transfer hints are global reference-counted. They do not by themselves force
    // a core to max; GreenQUIC policy combines them with local RX/TX pressure.
    Hints |= atomic_load_explicit(&PersistentHints, memory_order_acquire);

    if (IncludeUnknownGlobalHints) {
        Hints |= CxPlatGreenQuicPlusGetUnknownTransient(Now);
    }
    return Hints;
}
'''


def patch_multicore_plus_hint_api(repo: Path) -> None:
    '''V13: partition-to-DPDK-lcore mapped hint storage for optional multi-core mode.'''
    write_new_or_replace(repo / "src/inc/greenquic_plus.h", MULTICORE_PARTITION_GREENQUIC_PLUS_H)
    write_new_or_replace(repo / "src/platform/greenquic_plus.c", MULTICORE_PARTITION_GREENQUIC_PLUS_C)
    log("Patched GreenQUIC+ with partition-to-DPDK-lcore mapped ACK/CUBIC hints for optional multi-core mode.")


def patch_multicore_partition_hooks(repo: Path) -> None:
    '''Retarget ACK/CUBIC hooks from process/thread-local hints to MsQuic partition mapped DPDK lcores.'''
    ack = repo / "src/core/ack_tracker.c"
    ensure_file(ack)
    backup(ack)
    text = read_text(ack)
    text = text.replace(
        'CxPlatGreenQuicPlusPulseHints(GQPLUS_HINT_ACK_PENDING);',
        'CxPlatGreenQuicPlusPulseHintsForPartition(\n            Connection->Worker != NULL ? Connection->Worker->PartitionIndex : GQPLUS_PARTITION_UNKNOWN,\n            GQPLUS_HINT_ACK_PENDING);')
    write_text(ack, text)

    cubic = repo / "src/core/cubic.c"
    ensure_file(cubic)
    backup(cubic)
    text = read_text(cubic)
    text = text.replace(
        'CxPlatGreenQuicPlusPulseHints(GQPLUS_HINT_CUBIC_CWND_BLOCKED);',
        'CxPlatGreenQuicPlusPulseHintsForPartition(\n            Connection->Worker != NULL ? Connection->Worker->PartitionIndex : GQPLUS_PARTITION_UNKNOWN,\n            GQPLUS_HINT_CUBIC_CWND_BLOCKED);')
    text = text.replace(
        'CxPlatGreenQuicPlusPulseHints(GQPLUS_HINT_CUBIC_RECOVERY);',
        'CxPlatGreenQuicPlusPulseHintsForPartition(\n        Connection->Worker != NULL ? Connection->Worker->PartitionIndex : GQPLUS_PARTITION_UNKNOWN,\n        GQPLUS_HINT_CUBIC_RECOVERY);')
    text = text.replace(
        'CxPlatGreenQuicPlusPulseHints(GQPLUS_HINT_CUBIC_RAMPING);',
        'CxPlatGreenQuicPlusPulseHintsForPartition(\n            Connection->Worker != NULL ? Connection->Worker->PartitionIndex : GQPLUS_PARTITION_UNKNOWN,\n            GQPLUS_HINT_CUBIC_RAMPING);')
    write_text(cubic, text)
    log("Retargeted ACK/CUBIC hints to MsQuic partition -> DPDK lcore mapping.")


GREENQUIC_TOOL_EXEC_CONFIG_HELPER = r'''
// GREENQUIC-BEGIN: tool-level MsQuic execution CPU config
static bool
GreenQuicReadConfigValue(
    const char* Key,
    char* Value,
    size_t ValueSize
    )
{
    const char* ConfigPath = getenv("GREENQUIC_CONFIG");
    if (ConfigPath == nullptr || ConfigPath[0] == '\0') {
        ConfigPath = "dpdk.ini";
    }

    FILE* File = fopen(ConfigPath, "r");
    if (File == nullptr) {
        return false;
    }

    char Line[512];
    const size_t KeyLen = strlen(Key);
    while (fgets(Line, sizeof(Line), File) != nullptr) {
        char* P = Line;
        while (*P == ' ' || *P == '\t') {
            ++P;
        }
        if (*P == '#' || *P == ';' || *P == '\0' || *P == '\n') {
            continue;
        }
        if (strncmp(P, Key, KeyLen) != 0) {
            continue;
        }
        P += KeyLen;
        while (*P == ' ' || *P == '\t') {
            ++P;
        }
        if (*P != '=') {
            continue;
        }
        ++P;
        while (*P == ' ' || *P == '\t') {
            ++P;
        }
        char* End = P + strlen(P);
        while (End > P && (End[-1] == '\n' || End[-1] == '\r' || End[-1] == ' ' || End[-1] == '\t')) {
            --End;
        }
        *End = '\0';
        strncpy(Value, P, ValueSize - 1);
        Value[ValueSize - 1] = '\0';
        fclose(File);
        return true;
    }

    fclose(File);
    return false;
}

static QUIC_EXECUTION_PROFILE
GreenQuicGetQuicExecutionProfile()
{
    char Value[64];
    if (!GreenQuicReadConfigValue("GreenQuicQuicProfile", Value, sizeof(Value))) {
        return QUIC_EXECUTION_PROFILE_TYPE_MAX_THROUGHPUT;
    }
    if (strcmp(Value, "low_latency") == 0 || strcmp(Value, "low-latency") == 0) {
        return QUIC_EXECUTION_PROFILE_LOW_LATENCY;
    }
    if (strcmp(Value, "scavenger") == 0) {
        return QUIC_EXECUTION_PROFILE_TYPE_SCAVENGER;
    }
    if (strcmp(Value, "real_time") == 0 || strcmp(Value, "real-time") == 0) {
        return QUIC_EXECUTION_PROFILE_TYPE_REAL_TIME;
    }
    return QUIC_EXECUTION_PROFILE_TYPE_MAX_THROUGHPUT;
}

static QUIC_STATUS
GreenQuicSetMsQuicExecutionConfig()
{
    char CpuText[512];
    if (!GreenQuicReadConfigValue("GreenQuicQuicWorkerCpus", CpuText, sizeof(CpuText)) || CpuText[0] == '\0') {
        return QUIC_STATUS_SUCCESS;
    }

    uint16_t Cpus[256];
    uint32_t CpuCount = 0;
    const char* P = CpuText;
    while (*P != '\0' && CpuCount < ARRAYSIZE(Cpus)) {
        while (*P == ' ' || *P == '\t' || *P == ',') {
            ++P;
        }
        if (*P == '\0') {
            break;
        }
        char* End = nullptr;
        unsigned long Cpu = strtoul(P, &End, 10);
        if (End == P || Cpu > UINT16_MAX) {
            printf("GreenQUIC: invalid GreenQuicQuicWorkerCpus=%s\n", CpuText);
            return QUIC_STATUS_INVALID_PARAMETER;
        }
        Cpus[CpuCount++] = (uint16_t)Cpu;
        P = End;
    }

    if (CpuCount == 0) {
        return QUIC_STATUS_SUCCESS;
    }

    const uint32_t ConfigSize = QUIC_EXECUTION_CONFIG_MIN_SIZE + CpuCount * sizeof(uint16_t);
    QUIC_EXECUTION_CONFIG* ExecConfig = (QUIC_EXECUTION_CONFIG*)calloc(1, ConfigSize);
    if (ExecConfig == nullptr) {
        return QUIC_STATUS_OUT_OF_MEMORY;
    }

    char AffinitizeText[32];
    const bool Affinitize =
        GreenQuicReadConfigValue("GreenQuicQuicAffinitize", AffinitizeText, sizeof(AffinitizeText)) &&
        atoi(AffinitizeText) != 0;

    ExecConfig->Flags = QUIC_EXECUTION_CONFIG_FLAG_NONE;
#ifdef QUIC_API_ENABLE_PREVIEW_FEATURES
    if (Affinitize) {
        ExecConfig->Flags |= QUIC_EXECUTION_CONFIG_FLAG_AFFINITIZE;
    }
#else
    if (Affinitize) {
        printf("GreenQUIC: GreenQuicQuicAffinitize requested, but QUIC_API_ENABLE_PREVIEW_FEATURES is not enabled; using ProcessorList without AFFINITIZE.\n");
    }
#endif
    ExecConfig->PollingIdleTimeoutUs = 0;
    ExecConfig->ProcessorCount = CpuCount;
    for (uint32_t i = 0; i < CpuCount; ++i) {
        ExecConfig->ProcessorList[i] = Cpus[i];
    }

    QUIC_STATUS Status =
        MsQuic->SetParam(
            nullptr,
            QUIC_PARAM_GLOBAL_EXECUTION_CONFIG,
            ConfigSize,
            ExecConfig);
    free(ExecConfig);

    if (QUIC_FAILED(Status)) {
        printf("GreenQUIC: failed to set MsQuic execution config, 0x%x\n", Status);
    } else {
        printf("GreenQUIC: MsQuic worker CPU list from dpdk.ini = %s\n", CpuText);
    }
    return Status;
}
// GREENQUIC-END
'''


def patch_multicore_tool_execution_config(repo: Path) -> None:
    '''Patch interop tools to read QUIC worker CPU config from dpdk.ini using public MsQuic API.'''
    tool_files = [
        (repo / "src/tools/interopserver/InteropServer.cpp", '"interopserver"'),
        (repo / "src/tools/interop/interop.cpp", '"quicinterop"'),
    ]
    for path, name_literal in tool_files:
        if not path.exists():
            continue
        backup(path)
        text = read_text(path)
        if "GREENQUIC-BEGIN: tool-level MsQuic execution CPU config" not in text:
            if '#include <stdlib.h>' not in text and '#include "greenquic_plus.h"\n' in text:
                text = insert_after(
                    text,
                    '#include "greenquic_plus.h"\n',
                    '#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n',
                    "tool execution config C library includes")
            if 'const QUIC_API_TABLE* MsQuic;\n' in text:
                text = insert_after(text, 'const QUIC_API_TABLE* MsQuic;\n', GREENQUIC_TOOL_EXEC_CONFIG_HELPER, "tool execution config helper")
            elif 'const QUIC_API_TABLE* MsQuic = nullptr;\n' in text:
                text = insert_after(text, 'const QUIC_API_TABLE* MsQuic = nullptr;\n', GREENQUIC_TOOL_EXEC_CONFIG_HELPER, "tool execution config helper")
            else:
                text = insert_after(text, '#include "greenquic_plus.h"\n', GREENQUIC_TOOL_EXEC_CONFIG_HELPER, "tool execution config helper fallback")
        text = text.replace(
            f'const QUIC_REGISTRATION_CONFIG RegConfig = {{ {name_literal}, QUIC_EXECUTION_PROFILE_LOW_LATENCY }};',
            f'const QUIC_REGISTRATION_CONFIG RegConfig = {{ {name_literal}, GreenQuicGetQuicExecutionProfile() }};')
        text = text.replace(
            f'const QUIC_REGISTRATION_CONFIG RegConfig = {{ {name_literal}, QUIC_EXECUTION_PROFILE_TYPE_MAX_THROUGHPUT }};',
            f'const QUIC_REGISTRATION_CONFIG RegConfig = {{ {name_literal}, GreenQuicGetQuicExecutionProfile() }};')
        if 'EXIT_ON_FAILURE(GreenQuicSetMsQuicExecutionConfig())' not in text and 'Status = GreenQuicSetMsQuicExecutionConfig()' not in text:
            if 'EXIT_ON_FAILURE(MsQuicOpen2(&MsQuic));\n' in text:
                text = insert_after(
                    text,
                    'EXIT_ON_FAILURE(MsQuicOpen2(&MsQuic));\n',
                    '    EXIT_ON_FAILURE(GreenQuicSetMsQuicExecutionConfig());\n',
                    "server execution config call")
            elif 'if (QUIC_FAILED(Status = MsQuicOpen2(&MsQuic))) {\n        printf("MsQuicOpen2 failed, 0x%x!\\n", Status);\n        goto Error;\n    }\n' in text:
                text = insert_after(
                    text,
                    'if (QUIC_FAILED(Status = MsQuicOpen2(&MsQuic))) {\n        printf("MsQuicOpen2 failed, 0x%x!\\n", Status);\n        goto Error;\n    }\n',
                    '\n    if (QUIC_FAILED(Status = GreenQuicSetMsQuicExecutionConfig())) {\n        goto Error;\n    }\n',
                    "client execution config call")
        write_text(path, text)
    log("Patched interop tools to read GreenQuicQuicWorkerCpus/GreenQuicQuicProfile from dpdk.ini.")


def patch_multicore_partition_map_datapath(repo: Path) -> None:
    '''Add dpdk.ini partition->DPDK-lcore mapping and default modulo mapping.'''
    path = repo / "src/platform/datapath_raw_dpdk.c"
    ensure_file(path)
    backup(path)
    text = read_text(path)

    if "GreenQuicPartitionDpdkMapConfigured" not in text:
        text = insert_after(
            text,
            '    uint32_t GreenQuicHintLocalityWindowUs; // gate global PLUS hints to lcores with recent local datapath activity\n',
            '    BOOLEAN GreenQuicPartitionDpdkMapConfigured; // TRUE if GreenQuicPartitionDpdkMap was parsed from dpdk.ini\n',
            "partition map configured field")

    if "Dpdk->GreenQuicPartitionDpdkMapConfigured = FALSE;" not in text:
        text = insert_after(
            text,
            '    Dpdk->GreenQuicHintLocalityWindowUs = 2000;\n',
            '    Dpdk->GreenQuicPartitionDpdkMapConfigured = FALSE;\n',
            "partition map default")

    proto_block = text.split("// GREENQUIC-BEGIN: helper prototypes", 1)[1].split("// GREENQUIC-END", 1)[0]
    if "GreenQuicParsePartitionDpdkMap" not in proto_block:
        text = insert_after(
            text,
            'static uint64_t GreenQuicGetHintsForCore(_In_ const DPDK_DATAPATH* Dpdk, _In_ const GREENQUIC_LCORE_STATE* S, _In_ uint16_t Core);\n',
            'static void GreenQuicParsePartitionDpdkMap(_Inout_ DPDK_DATAPATH* Dpdk, _In_z_ const char* Value);\n'
            'static void GreenQuicInstallDefaultPartitionDpdkMap(_Inout_ DPDK_DATAPATH* Dpdk);\n',
            "partition map prototypes")

    helper_impl = r'''
static void
GreenQuicParsePartitionDpdkMap(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_z_ const char* Value
    )
{
    const char* P = Value;
    uint32_t Count = 0;
    while (*P != '\0') {
        while (*P == ' ' || *P == '\t' || *P == ',') {
            ++P;
        }
        if (*P == '\0') {
            break;
        }

        char* End = NULL;
        unsigned long Partition = strtoul(P, &End, 10);
        if (End == P || *End != ':' || Partition > UINT16_MAX) {
            printf("GreenQUIC: invalid GreenQuicPartitionDpdkMap near '%s'\n", P);
            break;
        }
        P = End + 1;
        unsigned long Lcore = strtoul(P, &End, 10);
        if (End == P || Lcore > UINT16_MAX) {
            printf("GreenQUIC: invalid DPDK lcore in GreenQuicPartitionDpdkMap near '%s'\n", P);
            break;
        }

        CxPlatGreenQuicPlusSetPartitionDpdkLcore((uint16_t)Partition, (uint16_t)Lcore);
        Count++;
        P = End;
    }

    if (Count != 0) {
        Dpdk->GreenQuicPartitionDpdkMapConfigured = TRUE;
        printf("GreenQUIC: installed %u explicit MsQuic partition -> DPDK lcore mapping entries.\n", Count);
    }
}

static void
GreenQuicInstallDefaultPartitionDpdkMap(
    _Inout_ DPDK_DATAPATH* Dpdk
    )
{
    if (!Dpdk->GreenQuicEnableMultiCore || Dpdk->GreenQuicPartitionDpdkMapConfigured) {
        return;
    }

    uint16_t Lcores[256];
    uint32_t LcoreCount = 0;
    unsigned int Lcore;
    RTE_LCORE_FOREACH(Lcore) {
        if (LcoreCount < ARRAYSIZE(Lcores) && Lcore <= UINT16_MAX) {
            Lcores[LcoreCount++] = (uint16_t)Lcore;
        }
    }

    if (LcoreCount == 0) {
        return;
    }

    for (uint16_t Partition = 0; Partition < 256; ++Partition) {
        CxPlatGreenQuicPlusSetPartitionDpdkLcore(Partition, Lcores[Partition % LcoreCount]);
    }
    printf("GreenQUIC: installed default partition -> DPDK lcore map for 256 partitions over %u DPDK lcores. Use GreenQuicPartitionDpdkMap to override.\n", LcoreCount);
}

'''
    if "GreenQuicParsePartitionDpdkMap" not in text.split("// GREENQUIC-BEGIN: helper implementations",1)[1].split("GreenQuicPowerInit",1)[0]:
        text = insert_before(text, 'static void\nGreenQuicPowerInit(\n', helper_impl, "partition map helper implementations")

    if 'strcmp(Line, "GreenQuicPartitionDpdkMap")' not in text:
        text = insert_before(
            text,
            '        } else if (strcmp(Line, "GreenQuicEnableFreq") == 0) {\n',
            '        } else if (strcmp(Line, "GreenQuicPartitionDpdkMap") == 0) {\n'
            '            GreenQuicParsePartitionDpdkMap(Dpdk, Value);\n',
            "partition map config parser")

    if "GreenQuicInstallDefaultPartitionDpdkMap(Dpdk);" not in text:
        text = text.replace(
            '    // GREENQUIC-END\n\n    if (DeviceInfo.tx_offload_capa',
            '    // GREENQUIC-END\n    GreenQuicInstallDefaultPartitionDpdkMap(Dpdk);\n\n    if (DeviceInfo.tx_offload_capa',
            1)

    write_text(path, text)


def patch_multicore_support(repo: Path, basic_only: bool = False) -> None:
    '''V13 optional multi-core path. Single-core/default sections remain unchanged.'''
    patch_multicore_support_v12(repo)
    patch_multicore_partition_map_datapath(repo)
    if basic_only:
        warn("BASIC-only + --enable-multi-core: datapath multi-core mapping is patched, but ACK/CUBIC/tool PLUS hooks are intentionally skipped.")
    else:
        patch_multicore_partition_hooks(repo)
        patch_multicore_tool_execution_config(repo)

    ini = repo / "dpdk.greenquic.example.ini"
    if ini.exists():
        itext = read_text(ini)
        if "GreenQuicPartitionDpdkMap" not in itext:
            itext += r'''

# V13 optional multi-core partition mapping.
# These keys only matter if the autopatcher was run with --enable-multi-core.
# DPDK packet lcores/queues:
# GreenQuicEnableMultiCore=1
# GreenQuicDpdkLcores=8,9
# MsQuic protocol worker CPUs, set by the tool before RegistrationOpen:
# GreenQuicQuicWorkerCpus=16,17,18,19
# GreenQuicQuicAffinitize=1
# GreenQuicQuicProfile=max_throughput
# Map MsQuic worker partitions to DPDK datapath lcores. Many-to-one is allowed.
# Example: partitions 0 and 1 target DPDK lcore 8; partitions 2 and 3 target DPDK lcore 9.
# GreenQuicPartitionDpdkMap=0:8,1:8,2:9,3:9
'''
            write_text(ini, itext)
    log("V13 multi-core partition-mapped hint support patched. ACK/CUBIC now target mapped DPDK lcores.")


# =============================================================================
# Local DPDK preparation
# =============================================================================

def _prepend_env_path(name: str, value: Path) -> None:
    value_str = str(value)
    old = os.environ.get(name, "")
    if old:
        if value_str not in old.split(os.pathsep):
            os.environ[name] = value_str + os.pathsep + old
    else:
        os.environ[name] = value_str


def _dpdk_pkgconfig_candidates(prefix: Path) -> List[Path]:
    return [
        prefix / "lib" / "x86_64-linux-gnu" / "pkgconfig",
        prefix / "lib64" / "pkgconfig",
        prefix / "lib" / "pkgconfig",
        prefix / "share" / "pkgconfig",
    ]


def _dpdk_lib_candidates(prefix: Path) -> List[Path]:
    return [
        prefix / "lib" / "x86_64-linux-gnu",
        prefix / "lib64",
        prefix / "lib",
    ]


def _find_local_libdpdk_pc(prefix: Path) -> Optional[Path]:
    for pc_dir in _dpdk_pkgconfig_candidates(prefix):
        pc = pc_dir / "libdpdk.pc"
        if pc.exists():
            return pc
    return None


def _find_libdpdk_pc_recursive(root: Path) -> Optional[Path]:
    """Find libdpdk.pc somewhere below an arbitrary DPDK folder.

    This helps when the user points at a folder such as ./mohsen/dpdk21 that
    may contain an install prefix, a build tree, or nested local install.
    Prefer pkgconfig directories over random matches.
    """
    if not root.exists():
        return None
    matches = sorted(root.rglob("libdpdk.pc"), key=lambda x: ("pkgconfig" not in str(x.parent), len(str(x))))
    return matches[0] if matches else None


def _find_dpdk_lib_dirs_recursive(root: Path) -> List[Path]:
    """Find directories containing libdpdk or rte libraries below a root."""
    if not root.exists():
        return []
    dirs = set()
    patterns = ("libdpdk.so*", "libdpdk.a", "librte_eal.so*", "librte_eal.a")
    for pattern in patterns:
        for f in root.rglob(pattern):
            if f.is_file():
                dirs.add(f.parent.resolve())
    return sorted(dirs, key=lambda x: len(str(x)))


def _find_dpdk_driver_dirs_recursive(root: Path) -> List[Path]:
    """Find likely Linux DPDK PMD/plugin directories below a root.

    DPDK installed with shared drivers commonly stores PMDs under paths like
    lib/dpdk/pmds-<version>. Some builds place PMD .so files next to libdpdk.
    We return candidate directories; runtime still depends on how DPDK was built.
    """
    if not root.exists():
        return []
    dirs = set()
    for d in root.rglob("pmds-*"):
        if d.is_dir():
            dirs.add(d.resolve())
    for pattern in ("librte_net_*.so*", "librte_bus_*.so*", "librte_mempool_*.so*"):
        for f in root.rglob(pattern):
            if f.is_file():
                dirs.add(f.parent.resolve())
    return sorted(dirs, key=lambda x: len(str(x)))


def _activate_dpdk_from_arbitrary_root(root: Path) -> bool:
    """Activate DPDK from any folder by recursively finding libdpdk.pc/libs/drivers."""
    root = root.resolve()
    pc = _find_libdpdk_pc_recursive(root)
    found_pc = False
    if pc:
        _prepend_env_path("PKG_CONFIG_PATH", pc.parent)
        found_pc = True
        log(f"Found libdpdk.pc under: {pc.parent}")
    else:
        warn(f"No libdpdk.pc found below {root}")

    for lib in _find_dpdk_lib_dirs_recursive(root):
        _prepend_env_path("LD_LIBRARY_PATH", lib)
        _prepend_env_path("LIBRARY_PATH", lib)
        log(f"Added DPDK library path: {lib}")

    driver_dirs = _find_dpdk_driver_dirs_recursive(root)
    if driver_dirs:
        # Do not overwrite a user-provided runtime driver path. For multiple dirs, DPDK accepts a directory
        # or a driver .so through -d; the patched code reads GREENQUIC_DPDK_DRIVER_PATH at runtime.
        os.environ.setdefault("GREENQUIC_DPDK_DRIVER_PATH", str(driver_dirs[0]))
        log(f"Found likely DPDK PMD/plugin directory: {driver_dirs[0]}")
        if len(driver_dirs) > 1:
            log("Additional PMD/plugin candidates: " + ", ".join(str(x) for x in driver_dirs[1:4]))
    else:
        warn(f"No Linux PMD/plugin .so directory found below {root}; this may be fine for static-linked DPDK.")

    return found_pc


def _activate_local_dpdk_env(prefix: Path) -> bool:
    found_pc = False
    for pc in _dpdk_pkgconfig_candidates(prefix):
        if (pc / "libdpdk.pc").exists():
            found_pc = True
            _prepend_env_path("PKG_CONFIG_PATH", pc)
    for lib in _dpdk_lib_candidates(prefix):
        if lib.exists():
            _prepend_env_path("LD_LIBRARY_PATH", lib)
            _prepend_env_path("LIBRARY_PATH", lib)
    return found_pc


def _pkg_config_libdpdk_version() -> Optional[str]:
    if shutil.which("pkg-config") is None:
        return None
    p = subprocess.run(["pkg-config", "--modversion", "libdpdk"], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode == 0:
        return p.stdout.strip()
    return None


def prepare_dpdk(repo: Path, args: argparse.Namespace) -> None:
    if args.dpdk_mode == "windows":
        warn("DPDK mode is windows: script keeps Windows PMD .dll code under #ifdef _WIN32. Local Linux DPDK build is skipped.")
        return

    if args.dpdk_mode == "system":
        version = _pkg_config_libdpdk_version()
        if not version:
            die("--dpdk-mode system selected, but pkg-config cannot find libdpdk. Use --dpdk-mode local or set PKG_CONFIG_PATH.")
        log(f"Using system/existing DPDK from pkg-config: libdpdk {version}")
        return

    # Optional arbitrary folder search, e.g. --dpdk-search-root ./mohsen/dpdk21.
    # This does not build or install anything; it only discovers libdpdk.pc, libs, and possible PMD dirs.
    if args.dpdk_search_root:
        search_root = Path(args.dpdk_search_root).resolve()
        log(f"Searching arbitrary DPDK folder: {search_root}")
        search_pc_found = _activate_dpdk_from_arbitrary_root(search_root)
        version = _pkg_config_libdpdk_version() if search_pc_found else None
        if version and not args.force_dpdk_build:
            log(f"Using DPDK discovered under {search_root}: libdpdk {version}")
            return
        if args.no_dpdk_build:
            die(f"Could not activate libdpdk from {search_root}, and --no-dpdk-build was used.")
        warn("DPDK folder search did not produce an active libdpdk.pc; falling back to local DPDK build.")

    dpdk_src = Path(args.dpdk_dir or (repo / "deps" / "dpdk")).resolve()
    dpdk_prefix = Path(args.dpdk_install_dir or (repo / "deps" / "dpdk-install")).resolve()
    local_pc_found = _activate_local_dpdk_env(dpdk_prefix)

    # If --dpdk-install-dir points at an arbitrary folder, also search it recursively.
    if not local_pc_found and args.dpdk_install_dir:
        log(f"Standard pkgconfig paths failed; recursively searching DPDK install folder: {dpdk_prefix}")
        local_pc_found = _activate_dpdk_from_arbitrary_root(dpdk_prefix)

    version = _pkg_config_libdpdk_version() if local_pc_found else None
    if version and not args.force_dpdk_build:
        log(f"Using local DPDK from {dpdk_prefix}: libdpdk {version}")
        return

    if not local_pc_found:
        log(f"No local libdpdk.pc found under {dpdk_prefix}; a local DPDK build will be prepared.")

    if args.no_dpdk_build:
        die(f"Local DPDK not found under {dpdk_prefix}, and --no-dpdk-build was used.")

    for tool in ("git", "meson", "ninja", "pkg-config"):
        if shutil.which(tool) is None:
            die(f"Required tool for local DPDK build missing from PATH: {tool}")

    dpdk_src.parent.mkdir(parents=True, exist_ok=True)
    if not (dpdk_src / ".git").exists():
        log(f"Cloning DPDK into local repo folder: {dpdk_src}")
        run(["git", "clone", args.dpdk_git_url, str(dpdk_src)])
    else:
        log(f"Using existing local DPDK source folder: {dpdk_src}")
        run(["git", "fetch", "--all", "--tags", "--prune"], cwd=dpdk_src, check=False)

    log(f"Checking out DPDK {args.dpdk_checkout}")
    run(["git", "checkout", args.dpdk_checkout], cwd=dpdk_src)

    build_dir = dpdk_src / "build-greenquic"
    if args.force_dpdk_build and build_dir.exists():
        shutil.rmtree(build_dir)

    if not build_dir.exists():
        log(f"Configuring DPDK locally. Prefix: {dpdk_prefix}")
        run(["meson", "setup", str(build_dir), f"--prefix={dpdk_prefix}", "--libdir=lib"], cwd=dpdk_src)
    else:
        log(f"Reusing DPDK build directory: {build_dir}")

    log("Building DPDK locally. No sudo and no system install.")
    run(["ninja", "-C", str(build_dir), "-j", str(args.jobs or os.cpu_count() or 4)], cwd=dpdk_src)
    log("Installing DPDK into local prefix only.")
    run(["ninja", "-C", str(build_dir), "install"], cwd=dpdk_src)

    local_pc_found = _activate_local_dpdk_env(dpdk_prefix)
    version = _pkg_config_libdpdk_version() if local_pc_found else None
    if not version:
        die(f"DPDK local install finished, but pkg-config still cannot find local libdpdk under {dpdk_prefix}.")
    log(f"Local DPDK is active for this build: libdpdk {version}")

# =============================================================================
# Build and test guidance
# =============================================================================

def build_repo(repo: Path, args: argparse.Namespace) -> None:
    build_dir = Path(args.build_dir or ask("Build directory", "build-greenquic"))
    if not build_dir.is_absolute():
        build_dir = repo / build_dir

    build_type = args.build_type or ask("CMAKE_BUILD_TYPE", "Release")
    tls = args.tls or ask("QUIC_TLS", "openssl")
    jobs = str(args.jobs or os.cpu_count() or 4)

    log("Configuring local build. No install, no sudo, no system library overwrite.")
    run([
        "cmake", "-S", ".", "-B", str(build_dir),
        f"-DCMAKE_BUILD_TYPE={build_type}",
        f"-DQUIC_TLS={tls}",
        "-DQUIC_BUILD_SHARED=OFF",
        "-DQUIC_BUILD_TOOLS=ON",
        "-DQUIC_BUILD_TEST=OFF",
        "-DQUIC_BUILD_PERF=OFF",
        "-DQUIC_LINUX_DPDK_ENABLED=ON",
    ], cwd=repo)

    log("Building locally.")
    run(["cmake", "--build", str(build_dir), "-j", jobs], cwd=repo)


def print_test_guide(repo: Path) -> None:
    print("\n" + "=" * 90)
    print("GREENQUIC TEST GUIDE")
    print("=" * 90)
    print(f"Repo: {repo}")
    print(r'''
0. If you used local DPDK, keep these in the shell before running tools:

   export PKG_CONFIG_PATH="./deps/dpdk-install/lib/pkgconfig:./deps/dpdk-install/lib/x86_64-linux-gnu/pkgconfig:$PKG_CONFIG_PATH"
   export LD_LIBRARY_PATH="./deps/dpdk-install/lib:./deps/dpdk-install/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH"

   Optional Linux plugin PMD path:

   export GREENQUIC_DPDK_DRIVER_PATH=/path/to/dpdk/drivers

   If you already have a private DPDK folder, you can ask the script to search it:

   ./greenquic_full_autopatch_v13_partition_mapped_multicore.py --dpdk-mode local --dpdk-search-root ./mohsen/dpdk21

1. Find built tools:

   find ./ -type f \( -name interopserver -o -name interop -o -name msquicsecnetperf \)

2. Ask exact options for your MsQuic version:

   <path-to-interopserver> --help
   <path-to-interop> --help

3. Create an 8GB file for download testing:

   mkdir -p ./greenquic_www
   fallocate -l 8G ./greenquic_www/8g.bin

4. Use dpdk.greenquic.example.ini as a starting point:

   cp dpdk.greenquic.example.ini dpdk.ini

   On server side:
      GreenQuicMode=basic      # first test
      GreenQuicProfile=server_download
      # optional: GreenQuicDpdkLcore=8
      # optional debug: GreenQuicEnableLogging=1

   On client side:
      GreenQuicMode=basic      # first test
      GreenQuicProfile=client_download
      # optional: GreenQuicDpdkLcore=12
      # optional debug: GreenQuicEnableLogging=1

   After BASIC works, try:
      GreenQuicMode=plus

5. Compare modes:

   GreenQuicMode=off
   GreenQuicMode=basic
   GreenQuicMode=plus

   Measure:
      throughput
      CPU frequency
      package power / RAPL power
      GreenQUIC printed stats only if logging is enabled

6. Multi-core note:

   Default behavior is still v10-compatible: one RX/TX queue unless you used --enable-multi-core.

   If you DID run the autopatcher with --enable-multi-core, then runtime can use:
      GreenQuicDpdkLcores=8,9,10,11
      GreenQuicEnableMultiCore=1

   That optional path assigns one RX queue to each resolved RX owner and keeps one
   dedicated TX consumer/queue to avoid cross-lcore TX reordering. Set
   GreenQuicTxOwnerAlsoRx=0 to make the TX owner TX-only; the other lcores are RX-only.
   It is meant for parallel requests using separate QUIC connections/flows so RSS can distribute them.
   Multiple streams inside one QUIC connection may still map to one RX queue because the NIC sees one UDP 5-tuple.

7. Important safety:

   This script does not install anything into Linux system paths.
   It builds inside the repo build directory.
   Default --dpdk-mode local builds/uses DPDK under ./deps only.
   Use --dpdk-mode system only when you intentionally want an existing pkg-config libdpdk.
''')
    print("=" * 90)


# =============================================================================
# Main
# =============================================================================

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Full GreenQUIC / GreenQUIC+ local autopatcher v18 (poll-count idle, independent hint TTLs, QUIC-safe single/multi paths)")
    p.add_argument("--git-url", default=None)
    p.add_argument("--repo-dir", default=None, help="Existing repo dir or clone target")
    p.add_argument("--checkout", default=None, help="Branch/tag/commit, e.g. origin/main")
    p.add_argument("--branch", default=None, help="New branch for edits")
    p.add_argument("--basic-only", action="store_true", help="Do not patch ACK/CUBIC/tool hooks; run BASIC mode only")
    p.add_argument("--yes", action="store_true", help="Do not ask before applying patches")
    p.add_argument("--no-build", action="store_true")
    p.add_argument("--build-dir", default=None)
    p.add_argument("--build-type", default=None)
    p.add_argument("--tls", default=None)
    p.add_argument("--jobs", type=int, default=None)
    p.add_argument("--dpdk-mode", choices=["local", "system", "windows"], default="local",
                   help="local: build/use ./deps/dpdk-install by default; system: use existing pkg-config libdpdk; windows: keep Windows PMD DLL path and skip local Linux DPDK build")
    p.add_argument("--dpdk-dir", default=None, help="Local DPDK source folder. Default: <repo>/deps/dpdk")
    p.add_argument("--dpdk-install-dir", default=None, help="Local DPDK install prefix. Default: <repo>/deps/dpdk-install. If given and libdpdk.pc is not in standard paths, v13 recursively searches below it.")
    p.add_argument("--dpdk-search-root", default=None, help="Arbitrary existing DPDK folder to search recursively for libdpdk.pc, libdpdk/librte libraries, and Linux PMD/plugin driver directories; e.g. ./mohsen/dpdk21")
    p.add_argument("--dpdk-git-url", default="https://github.com/DPDK/dpdk.git", help="DPDK git URL. Default: official DPDK repo")
    p.add_argument("--dpdk-checkout", default=RECOMMENDED_DPDK_CHECKOUT, help=f"DPDK tag/branch to build locally. Recommended: {RECOMMENDED_DPDK_CHECKOUT} (DPDK 21.11 LTS final). Fallback: {FALLBACK_DPDK_CHECKOUT}. 22.11 may also work, but test NIC/PMD compatibility.")
    p.add_argument("--force-dpdk-build", action="store_true", help="Delete/rebuild the local DPDK build directory")
    p.add_argument("--no-dpdk-build", action="store_true", help="Do not build DPDK; fail if local libdpdk is not found")
    p.add_argument("--enable-example-logging", action="store_true", help="Print dpdk.ini examples with GreenQuic logging enabled; generated code still defaults logging off")
    p.add_argument("--enable-multi-core", action="store_true", help="Patch optional multi-core DPDK: one RX queue per RX owner, one dedicated TX consumer/queue, optional TX-only owner, and partition-to-RX-lcore ACK/CUBIC hints. Runtime still requires GreenQuicEnableMultiCore=1.")
    return p.parse_args()


# =============================================================================
# V18 SAFE-ENERGY OVERRIDES
# =============================================================================
#
# This block intentionally appears after the complete v17 implementation.
# Python resolves these globals/functions at call time, so the definitions below
# replace only the behavior that needs correction. The complete old code remains
# above for comparison, as requested.
#
# V18 principles:
#   - consecutive empty POLLS remain poll-count based
#   - non-empty TX ring and real RX/TX pressure always win
#   - ACK-ready, recovery and ramping prevent sleep
#   - delayed ACK timer start is NOT treated as ACK-ready
#   - persistent transfer hints do not globally veto sleep
#   - transient hints have independent expiry
#   - multi-core uses one RSS RX queue per RX owner plus one dedicated TX consumer by default
#   - GreenQuicTxOwnerAlsoRx=0 makes the TX owner TX-only
#

GREENQUIC_PLUS_H = r'''/*++

    GreenQUIC Plus public hint API, v18.

    Threading model:
      - PulseHints is safe for short timing hints.
      - BeginTransfer/EndTransfer are reference-counted.
      - BeginRecovery/EndRecovery are reference-counted across connections.

--*/

#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GQPLUS_HINT_ACK_PENDING             (1ull << 0)
#define GQPLUS_HINT_CUBIC_CWND_BLOCKED     (1ull << 1)
#define GQPLUS_HINT_CUBIC_RECOVERY         (1ull << 2)
#define GQPLUS_HINT_CUBIC_RAMPING          (1ull << 3)
#define GQPLUS_HINT_SERVER_FILE_TX_ACTIVE  (1ull << 16)
#define GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE  (1ull << 17)

void CxPlatGreenQuicPlusSetHints(uint64_t Hints);
void CxPlatGreenQuicPlusClearHints(uint64_t Hints);
void CxPlatGreenQuicPlusBeginTransfer(uint64_t Hints);
void CxPlatGreenQuicPlusEndTransfer(uint64_t Hints);
void CxPlatGreenQuicPlusBeginRecovery(void);
void CxPlatGreenQuicPlusEndRecovery(void);
void CxPlatGreenQuicPlusPulseHints(uint64_t Hints);
uint64_t CxPlatGreenQuicPlusGetHints(void);

#ifdef __cplusplus
}
#endif
'''

GREENQUIC_PLUS_C = r'''/*++

    GreenQUIC Plus hint storage, v18 single-core/default path.

    Active implementation:
      - application transfer hints are reference-counted
      - CUBIC recovery is reference-counted across concurrent connections
      - ACK, blocked, recovery fallback and ramping expire independently

    The old v17 shared-expiration implementation is retained in #if 0.

--*/

#define _POSIX_C_SOURCE 200809L

#include "greenquic_plus.h"

#include <stdatomic.h>
#include <stdint.h>
#include <time.h>

#define GQPLUS_ACK_TTL_NS          (500ull * 1000ull)
#define GQPLUS_CWND_BLOCKED_TTL_NS (1000ull * 1000ull)
#define GQPLUS_RECOVERY_PULSE_NS   (2000ull * 1000ull)
#define GQPLUS_RAMPING_TTL_NS      (2000ull * 1000ull)
#define GQPLUS_OTHER_TTL_NS        (2000ull * 1000ull)
#define GQPLUS_TRANSFER_HINTS \
    (GQPLUS_HINT_SERVER_FILE_TX_ACTIVE | GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE)
#define GQPLUS_KNOWN_TRANSIENT_HINTS \
    (GQPLUS_HINT_ACK_PENDING | GQPLUS_HINT_CUBIC_CWND_BLOCKED | \
     GQPLUS_HINT_CUBIC_RECOVERY | GQPLUS_HINT_CUBIC_RAMPING)

static atomic_uint_fast64_t PersistentHints;
static atomic_uint_fast64_t AckPendingUntilNs;
static atomic_uint_fast64_t CwndBlockedUntilNs;
static atomic_uint_fast64_t RecoveryPulseUntilNs;
static atomic_uint_fast64_t CubicRampingUntilNs;
static atomic_uint_fast64_t OtherTransientHints;
static atomic_uint_fast64_t OtherTransientUntilNs;
static atomic_uint_fast32_t ServerFileTxActiveCount;
static atomic_uint_fast32_t ClientFileRxActiveCount;
static atomic_uint_fast32_t CubicRecoveryActiveCount;

static uint64_t
CxPlatGreenQuicPlusNowNs(void)
{
    struct timespec Ts;
#if defined(CLOCK_MONOTONIC_RAW)
    clock_gettime(CLOCK_MONOTONIC_RAW, &Ts);
#else
    clock_gettime(CLOCK_MONOTONIC, &Ts);
#endif
    return ((uint64_t)Ts.tv_sec * 1000000000ull) + (uint64_t)Ts.tv_nsec;
}

static void
CxPlatGreenQuicPlusExtendUntil(
    atomic_uint_fast64_t* Until,
    uint64_t Candidate
    )
{
    uint_fast64_t Old = atomic_load_explicit(Until, memory_order_relaxed);
    while (Old < Candidate &&
           !atomic_compare_exchange_weak_explicit(
               Until,
               &Old,
               Candidate,
               memory_order_release,
               memory_order_relaxed)) {
    }
}

static void
CxPlatGreenQuicPlusIncrementHintCount(
    atomic_uint_fast32_t* Counter,
    uint64_t Hint
    )
{
    const uint_fast32_t Old =
        atomic_fetch_add_explicit(Counter, 1, memory_order_relaxed);
    if (Old == 0) {
        atomic_fetch_or_explicit(&PersistentHints, Hint, memory_order_release);
    }
}

static void
CxPlatGreenQuicPlusDecrementHintCount(
    atomic_uint_fast32_t* Counter,
    uint64_t Hint
    )
{
    uint_fast32_t Old = atomic_load_explicit(Counter, memory_order_relaxed);
    while (Old != 0) {
        if (atomic_compare_exchange_weak_explicit(
                Counter,
                &Old,
                Old - 1,
                memory_order_acq_rel,
                memory_order_relaxed)) {
            if (Old == 1) {
                atomic_fetch_and_explicit(&PersistentHints, ~Hint, memory_order_release);
            }
            return;
        }
    }
}

void
CxPlatGreenQuicPlusBeginTransfer(uint64_t Hints)
{
    if ((Hints & GQPLUS_HINT_SERVER_FILE_TX_ACTIVE) != 0) {
        CxPlatGreenQuicPlusIncrementHintCount(
            &ServerFileTxActiveCount,
            GQPLUS_HINT_SERVER_FILE_TX_ACTIVE);
    }
    if ((Hints & GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE) != 0) {
        CxPlatGreenQuicPlusIncrementHintCount(
            &ClientFileRxActiveCount,
            GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE);
    }
}

void
CxPlatGreenQuicPlusEndTransfer(uint64_t Hints)
{
    if ((Hints & GQPLUS_HINT_SERVER_FILE_TX_ACTIVE) != 0) {
        CxPlatGreenQuicPlusDecrementHintCount(
            &ServerFileTxActiveCount,
            GQPLUS_HINT_SERVER_FILE_TX_ACTIVE);
    }
    if ((Hints & GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE) != 0) {
        CxPlatGreenQuicPlusDecrementHintCount(
            &ClientFileRxActiveCount,
            GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE);
    }
}

void
CxPlatGreenQuicPlusBeginRecovery(void)
{
    CxPlatGreenQuicPlusIncrementHintCount(
        &CubicRecoveryActiveCount,
        GQPLUS_HINT_CUBIC_RECOVERY);
}

void
CxPlatGreenQuicPlusEndRecovery(void)
{
    CxPlatGreenQuicPlusDecrementHintCount(
        &CubicRecoveryActiveCount,
        GQPLUS_HINT_CUBIC_RECOVERY);
}

void
CxPlatGreenQuicPlusSetHints(uint64_t Hints)
{
    const uint64_t PlainPersistent =
        Hints & ~(GQPLUS_TRANSFER_HINTS | GQPLUS_HINT_CUBIC_RECOVERY);
    atomic_fetch_or_explicit(&PersistentHints, PlainPersistent, memory_order_relaxed);
    CxPlatGreenQuicPlusBeginTransfer(Hints & GQPLUS_TRANSFER_HINTS);
    if ((Hints & GQPLUS_HINT_CUBIC_RECOVERY) != 0) {
        CxPlatGreenQuicPlusBeginRecovery();
    }
}

void
CxPlatGreenQuicPlusClearHints(uint64_t Hints)
{
    const uint64_t PlainPersistent =
        Hints & ~(GQPLUS_TRANSFER_HINTS | GQPLUS_HINT_CUBIC_RECOVERY);
    atomic_fetch_and_explicit(&PersistentHints, ~PlainPersistent, memory_order_relaxed);
    CxPlatGreenQuicPlusEndTransfer(Hints & GQPLUS_TRANSFER_HINTS);
    if ((Hints & GQPLUS_HINT_CUBIC_RECOVERY) != 0) {
        CxPlatGreenQuicPlusEndRecovery();
    }
}

void
CxPlatGreenQuicPlusPulseHints(uint64_t Hints)
{
    const uint64_t Now = CxPlatGreenQuicPlusNowNs();

    if ((Hints & GQPLUS_HINT_ACK_PENDING) != 0) {
        CxPlatGreenQuicPlusExtendUntil(
            &AckPendingUntilNs,
            Now + GQPLUS_ACK_TTL_NS);
    }
    if ((Hints & GQPLUS_HINT_CUBIC_CWND_BLOCKED) != 0) {
        CxPlatGreenQuicPlusExtendUntil(
            &CwndBlockedUntilNs,
            Now + GQPLUS_CWND_BLOCKED_TTL_NS);
    }
    if ((Hints & GQPLUS_HINT_CUBIC_RECOVERY) != 0) {
        // Backward-compatible fallback. New CUBIC hooks use Begin/EndRecovery.
        CxPlatGreenQuicPlusExtendUntil(
            &RecoveryPulseUntilNs,
            Now + GQPLUS_RECOVERY_PULSE_NS);
    }
    if ((Hints & GQPLUS_HINT_CUBIC_RAMPING) != 0) {
        CxPlatGreenQuicPlusExtendUntil(
            &CubicRampingUntilNs,
            Now + GQPLUS_RAMPING_TTL_NS);
    }

    const uint64_t Other = Hints & ~GQPLUS_KNOWN_TRANSIENT_HINTS;
    if (Other != 0) {
        atomic_fetch_or_explicit(&OtherTransientHints, Other, memory_order_relaxed);
        CxPlatGreenQuicPlusExtendUntil(
            &OtherTransientUntilNs,
            Now + GQPLUS_OTHER_TTL_NS);
    }
}

uint64_t
CxPlatGreenQuicPlusGetHints(void)
{
    const uint64_t Now = CxPlatGreenQuicPlusNowNs();
    uint64_t Hints = atomic_load_explicit(&PersistentHints, memory_order_acquire);

    if (Now <= atomic_load_explicit(&AckPendingUntilNs, memory_order_acquire)) {
        Hints |= GQPLUS_HINT_ACK_PENDING;
    }
    if (Now <= atomic_load_explicit(&CwndBlockedUntilNs, memory_order_acquire)) {
        Hints |= GQPLUS_HINT_CUBIC_CWND_BLOCKED;
    }
    if (Now <= atomic_load_explicit(&RecoveryPulseUntilNs, memory_order_acquire)) {
        Hints |= GQPLUS_HINT_CUBIC_RECOVERY;
    }
    if (Now <= atomic_load_explicit(&CubicRampingUntilNs, memory_order_acquire)) {
        Hints |= GQPLUS_HINT_CUBIC_RAMPING;
    }
    if (Now <= atomic_load_explicit(&OtherTransientUntilNs, memory_order_acquire)) {
        Hints |= atomic_load_explicit(&OtherTransientHints, memory_order_relaxed);
    } else {
        atomic_store_explicit(&OtherTransientHints, 0, memory_order_relaxed);
    }

    return Hints;
}

#if 0
/*
 * GREENQUIC-OLD-V17: one shared transient bitmask and expiration.
 * A later pulse extended unrelated older hint bits.
 */
#define GQPLUS_TRANSIENT_TTL_NS (2ull * 1000ull * 1000ull)
static atomic_uint_fast64_t TransientHints;
static atomic_uint_fast64_t TransientUntilNs;

void CxPlatGreenQuicPlusPulseHints_V17(uint64_t Hints)
{
    const uint64_t Now = CxPlatGreenQuicPlusNowNs();
    atomic_fetch_or_explicit(&TransientHints, Hints, memory_order_relaxed);
    atomic_store_explicit(
        &TransientUntilNs,
        Now + GQPLUS_TRANSIENT_TTL_NS,
        memory_order_relaxed);
}
#endif
'''

# Keep the original strings above and derive corrected v18 datapath strings here.
DPDK_TYPES = DPDK_TYPES.replace(
    '#define DEFAULT_GREENQUIC_FREQ_UP_PERIOD_US      1000U',
    '/* GREENQUIC-OLD-V17: DEFAULT_GREENQUIC_FREQ_UP_PERIOD_US was 1000U. */\n'
    '#define DEFAULT_GREENQUIC_FREQ_UP_PERIOD_US      500U')
DPDK_TYPES = DPDK_TYPES.replace(
    '#define DEFAULT_GREENQUIC_PRESSURE_KEEP          200U',
    '/* GREENQUIC-OLD-V17: DEFAULT_GREENQUIC_PRESSURE_KEEP was 200U. */\n'
    '#define DEFAULT_GREENQUIC_PRESSURE_KEEP          250U')
DPDK_TYPES = DPDK_TYPES.replace(
    '#define DEFAULT_GREENQUIC_EWMA_FALL_SHIFT        3U',
    '/* GREENQUIC-OLD-V17: DEFAULT_GREENQUIC_EWMA_FALL_SHIFT was 3U. */\n'
    '#define DEFAULT_GREENQUIC_EWMA_FALL_SHIFT        2U')
DPDK_TYPES = DPDK_TYPES.replace(
    '#define DEFAULT_GREENQUIC_ACK_SLEEP_US           2U',
    '/* GREENQUIC-OLD-V17: DEFAULT_GREENQUIC_ACK_SLEEP_US was 2U. */\n'
    '#define DEFAULT_GREENQUIC_ACK_SLEEP_US           1U')
DPDK_TYPES = DPDK_TYPES.replace(
    '#define DEFAULT_GREENQUIC_DATA_SLEEP_US          0U',
    '/* GREENQUIC-OLD-V17: DEFAULT_GREENQUIC_DATA_SLEEP_US was 0U. */\n'
    '#define DEFAULT_GREENQUIC_DATA_SLEEP_US          2U')
DPDK_TYPES = DPDK_TYPES.replace(
    '#define DEFAULT_GREENQUIC_MAX_SLEEP_US           5U',
    '/* GREENQUIC-OLD-V17: DEFAULT_GREENQUIC_MAX_SLEEP_US was 5U. */\n'
    '#define DEFAULT_GREENQUIC_MAX_SLEEP_US           2U')
DPDK_TYPES = DPDK_TYPES.replace(
    '#define DEFAULT_GREENQUIC_ENABLE_SLEEP           FALSE',
    '/* GREENQUIC-OLD-V17: DEFAULT_GREENQUIC_ENABLE_SLEEP was FALSE. */\n'
    '#define DEFAULT_GREENQUIC_ENABLE_SLEEP           TRUE')

DPDK_PROTOTYPES = DPDK_PROTOTYPES.replace(
    'static uint32_t GreenQuicGetSleepBudgetUs(_In_ const DPDK_DATAPATH* Dpdk);',
    'static uint32_t GreenQuicGetSleepBudgetUs(_In_ const DPDK_DATAPATH* Dpdk, _In_ const GREENQUIC_LCORE_STATE* S, _In_ uint32_t TxRingCount, _In_ uint64_t Hints);')

_V17_SLEEP_HELPER = r'''static uint32_t
GreenQuicGetSleepBudgetUs(
    _In_ const DPDK_DATAPATH* Dpdk
    )
{
    if (GreenQuicIsDataPath(Dpdk, GREENQUIC_DIR_RX) || GreenQuicIsDataPath(Dpdk, GREENQUIC_DIR_TX)) {
        return Dpdk->GreenQuicDataPathMaxSleepUs;
    }
    return Dpdk->GreenQuicAckPathMaxSleepUs;
}
'''

_V18_SLEEP_HELPER = r'''#if 0
/* GREENQUIC-OLD-V17: profile-only selection was effectively always data-path. */
static uint32_t
GreenQuicGetSleepBudgetUs_V17(
    _In_ const DPDK_DATAPATH* Dpdk
    )
{
    if (GreenQuicIsDataPath(Dpdk, GREENQUIC_DIR_RX) || GreenQuicIsDataPath(Dpdk, GREENQUIC_DIR_TX)) {
        return Dpdk->GreenQuicDataPathMaxSleepUs;
    }
    return Dpdk->GreenQuicAckPathMaxSleepUs;
}
#endif

static uint32_t
GreenQuicGetSleepBudgetUs(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ const GREENQUIC_LCORE_STATE* S,
    _In_ uint32_t TxRingCount,
    _In_ uint64_t Hints
    )
{
    if (!Dpdk->GreenQuicEnableSleep || Dpdk->GreenQuicMaxSleepUs == 0) {
        return 0;
    }

    if (TxRingCount != 0 ||
        S->Rx.LastBurstCount != 0 ||
        S->Tx.LastBurstCount != 0 ||
        S->PressureAvg >= Dpdk->GreenQuicPressureKeepThreshold) {
        return 0;
    }

    if ((Hints &
        (GQPLUS_HINT_ACK_PENDING |
         GQPLUS_HINT_CUBIC_RECOVERY |
         GQPLUS_HINT_CUBIC_RAMPING)) != 0) {
        return 0;
    }

    const uint32_t RxThreshold =
        Dpdk->GreenQuicRxEmptyPollThreshold == 0 ? 1 :
        Dpdk->GreenQuicRxEmptyPollThreshold;
    const uint32_t TxThreshold =
        Dpdk->GreenQuicTxEmptyPollThreshold == 0 ? 1 :
        Dpdk->GreenQuicTxEmptyPollThreshold;
    const uint32_t RxLevel = S->Rx.ConsecutiveEmpty / RxThreshold;
    const uint32_t TxLevel = S->Tx.ConsecutiveEmpty / TxThreshold;
    const uint32_t EmptyLevel = GreenQuicMinU32(RxLevel, TxLevel);

    // A persistent file transfer may sleep only after a deeper real empty-poll gap.
    if (GreenQuicPlusHasActiveTransferHint(Dpdk, Hints) && EmptyLevel < 4U) {
        return 0;
    }

    if (EmptyLevel >= 8U) {
        return Dpdk->GreenQuicMaxSleepUs;
    }
    if (EmptyLevel >= 4U) {
        return GreenQuicMinU32(
            Dpdk->GreenQuicDataPathMaxSleepUs,
            Dpdk->GreenQuicMaxSleepUs);
    }
    if (EmptyLevel >= 2U) {
        return GreenQuicMinU32(
            Dpdk->GreenQuicAckPathMaxSleepUs,
            Dpdk->GreenQuicMaxSleepUs);
    }
    return 0;
}
'''

if _V17_SLEEP_HELPER not in DPDK_HELPERS:
    raise RuntimeError('V18 override could not find v17 sleep helper')
DPDK_HELPERS = DPDK_HELPERS.replace(_V17_SLEEP_HELPER, _V18_SLEEP_HELPER, 1)

# Preserve the complete old PLUS pressure function in #if 0 and activate v18.
_v17_plus_start = DPDK_HELPERS.index('static uint32_t\nGreenQuicPlusPressure(')
_v17_plus_end = DPDK_HELPERS.index('\nstatic uint32_t\nGreenQuicComputeRawPressure(', _v17_plus_start)
_V17_PLUS_PRESSURE = DPDK_HELPERS[_v17_plus_start:_v17_plus_end]
_V18_PLUS_PRESSURE = r'''#if 0
/* GREENQUIC-OLD-V17: old PLUS pressure policy retained verbatim below. */
''' + _V17_PLUS_PRESSURE + r'''#endif

static uint32_t
GreenQuicPlusPressure(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ uint64_t Hints,
    _In_ uint32_t RxPressure,
    _In_ uint32_t TxPressure,
    _Out_ BOOLEAN* HardMax
    )
{
    uint32_t AckPressure = 0;
    uint32_t CubicPressure = 0;
    uint32_t AppPressure = 0;

    *HardMax = FALSE;

    if (Dpdk->GreenQuicMode != GREENQUIC_MODE_PLUS || Hints == 0) {
        return 0;
    }

    if ((Hints & GQPLUS_HINT_ACK_PENDING) != 0) {
        AckPressure =
            Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_CLIENT_DOWNLOAD ?
                600U : 550U;
        if (Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_CLIENT_DOWNLOAD &&
            RxPressure >= Dpdk->GreenQuicPressureMaxThreshold) {
            *HardMax = TRUE;
        }
    }

    if ((Hints & GQPLUS_HINT_CUBIC_RECOVERY) != 0) {
        CubicPressure = 750U;
        if (GreenQuicMaxU32(RxPressure, TxPressure) >=
                Dpdk->GreenQuicPressureUpThreshold) {
            *HardMax = TRUE;
        }
    } else if ((Hints & GQPLUS_HINT_CUBIC_RAMPING) != 0) {
        CubicPressure = 600U;
    } else if ((Hints & GQPLUS_HINT_CUBIC_CWND_BLOCKED) != 0) {
        // Network-limited state: keep/pause, not blind maximum frequency.
        CubicPressure = 350U;
    }

    if ((Hints & GQPLUS_HINT_SERVER_FILE_TX_ACTIVE) != 0 &&
        (Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_SERVER_DOWNLOAD ||
         Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_SYMMETRIC)) {
        AppPressure = GreenQuicMaxU32(AppPressure, TxPressure);
        if (TxPressure >= Dpdk->GreenQuicPressureMaxThreshold) {
            *HardMax = TRUE;
        }
    }

    if ((Hints & GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE) != 0 &&
        (Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_CLIENT_DOWNLOAD ||
         Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_SYMMETRIC)) {
        AppPressure = GreenQuicMaxU32(AppPressure, RxPressure);
        if (RxPressure >= Dpdk->GreenQuicPressureMaxThreshold) {
            *HardMax = TRUE;
        }
    }

    return GreenQuicMaxU32(
        AppPressure,
        GreenQuicMaxU32(AckPressure, CubicPressure));
}
'''
DPDK_HELPERS = (
    DPDK_HELPERS[:_v17_plus_start] +
    _V18_PLUS_PRESSURE +
    DPDK_HELPERS[_v17_plus_end:])

_V17_WEIGHTING = r'''    uint32_t Weighted;
    switch (Dpdk->GreenQuicProfile) {
    case GREENQUIC_PROFILE_SERVER_DOWNLOAD:
        Weighted = (50U * TxPressure + 25U * PlusPressure + 15U * RxPressure) / 90U;
        break;
    case GREENQUIC_PROFILE_CLIENT_DOWNLOAD:
        Weighted = (50U * RxPressure + 25U * PlusPressure + 15U * TxPressure) / 90U;
        break;
    default:
        Weighted = (35U * RxPressure + 35U * TxPressure + 30U * PlusPressure) / 100U;
        break;
    }

    Weighted = GreenQuicMaxU32(Weighted, RxPressure);
    Weighted = GreenQuicMaxU32(Weighted, TxPressure);
    Weighted = GreenQuicMaxU32(Weighted, PlusPressure);
    return GreenQuicMinU32(Weighted, GREENQUIC_PRESSURE_SCALE);
'''

_V18_WEIGHTING = r'''#if 0
    /* GREENQUIC-OLD-V17: these max operations neutralized profile weighting. */
    uint32_t WeightedV17;
    switch (Dpdk->GreenQuicProfile) {
    case GREENQUIC_PROFILE_SERVER_DOWNLOAD:
        WeightedV17 = (50U * TxPressure + 25U * PlusPressure + 15U * RxPressure) / 90U;
        break;
    case GREENQUIC_PROFILE_CLIENT_DOWNLOAD:
        WeightedV17 = (50U * RxPressure + 25U * PlusPressure + 15U * TxPressure) / 90U;
        break;
    default:
        WeightedV17 = (35U * RxPressure + 35U * TxPressure + 30U * PlusPressure) / 100U;
        break;
    }
    WeightedV17 = GreenQuicMaxU32(WeightedV17, RxPressure);
    WeightedV17 = GreenQuicMaxU32(WeightedV17, TxPressure);
    WeightedV17 = GreenQuicMaxU32(WeightedV17, PlusPressure);
#endif

    uint32_t PrimaryPressure;
    uint32_t SecondaryPressure;
    uint32_t Weighted;
    switch (Dpdk->GreenQuicProfile) {
    case GREENQUIC_PROFILE_SERVER_DOWNLOAD:
        PrimaryPressure = TxPressure;
        SecondaryPressure = RxPressure;
        Weighted =
            (60U * PrimaryPressure +
             20U * SecondaryPressure +
             20U * PlusPressure) / 100U;
        break;
    case GREENQUIC_PROFILE_CLIENT_DOWNLOAD:
        PrimaryPressure = RxPressure;
        SecondaryPressure = TxPressure;
        Weighted =
            (60U * PrimaryPressure +
             20U * SecondaryPressure +
             20U * PlusPressure) / 100U;
        break;
    default:
        PrimaryPressure = GreenQuicMaxU32(RxPressure, TxPressure);
        SecondaryPressure = GreenQuicMinU32(RxPressure, TxPressure);
        Weighted =
            (50U * PrimaryPressure +
             30U * SecondaryPressure +
             20U * PlusPressure) / 100U;
        break;
    }

    // Never hide real pressure in the primary data direction.
    Weighted = GreenQuicMaxU32(Weighted, PrimaryPressure);

    // Urgent QUIC events may set a temporary floor; CWND-blocked alone may not.
    if ((Hints &
        (GQPLUS_HINT_ACK_PENDING |
         GQPLUS_HINT_CUBIC_RECOVERY |
         GQPLUS_HINT_CUBIC_RAMPING)) != 0) {
        Weighted = GreenQuicMaxU32(Weighted, PlusPressure);
    }

    return GreenQuicMinU32(Weighted, GREENQUIC_PRESSURE_SCALE);
'''
if _V17_WEIGHTING not in DPDK_HELPERS:
    raise RuntimeError('V18 override could not find v17 weighting')
DPDK_HELPERS = DPDK_HELPERS.replace(_V17_WEIGHTING, _V18_WEIGHTING, 1)

_V17_TRANSFER_VETO = r'''    const uint64_t Hints = CxPlatGreenQuicPlusGetHints();
    if (GreenQuicPlusHasActiveTransferHint(Dpdk, Hints)) {
        // During a known file transfer, allow DVFS step-down but avoid adding sleep latency.
        S->LastAction = "transfer_no_sleep";
        return;
    }

    const uint32_t SleepBudgetUs = GreenQuicGetSleepBudgetUs(Dpdk);
'''

_V18_TRANSFER_SLEEP = r'''    const uint64_t Hints = S->LastHints;
#if 0
    /* GREENQUIC-OLD-V17: persistent transfer hints blocked all sleep.
    if (GreenQuicPlusHasActiveTransferHint(Dpdk, Hints)) {
        S->LastAction = "transfer_no_sleep";
        return;
    }
    */
#endif

    const uint32_t SleepBudgetUs =
        GreenQuicGetSleepBudgetUs(Dpdk, S, TxRingCount, Hints);
'''
if _V17_TRANSFER_VETO not in DPDK_HELPERS:
    raise RuntimeError('V18 override could not find v17 transfer veto')
DPDK_HELPERS = DPDK_HELPERS.replace(
    _V17_TRANSFER_VETO,
    _V18_TRANSFER_SLEEP,
    1)

DPDK_INI_EXAMPLE = DPDK_INI_EXAMPLE.replace(
    'GreenQuicPressureKeepThreshold=200',
    '# GREENQUIC-OLD-V17: GreenQuicPressureKeepThreshold=200\n'
    'GreenQuicPressureKeepThreshold=250')
DPDK_INI_EXAMPLE = DPDK_INI_EXAMPLE.replace(
    'GreenQuicEwmaFallShift=3',
    '# GREENQUIC-OLD-V17: GreenQuicEwmaFallShift=3\n'
    'GreenQuicEwmaFallShift=2')
DPDK_INI_EXAMPLE = DPDK_INI_EXAMPLE.replace(
    'GreenQuicFreqUpPeriodUs=1000',
    '# GREENQUIC-OLD-V17: GreenQuicFreqUpPeriodUs=1000\n'
    'GreenQuicFreqUpPeriodUs=500')
DPDK_INI_EXAMPLE = DPDK_INI_EXAMPLE.replace(
    'GreenQuicAckPathMaxSleepUs=2\n'
    'GreenQuicDataPathMaxSleepUs=0\n'
    'GreenQuicMaxSleepUs=5',
    'GreenQuicAckPathMaxSleepUs=1\n'
    '# GREENQUIC-OLD-V17: GreenQuicDataPathMaxSleepUs=0\n'
    'GreenQuicDataPathMaxSleepUs=2\n'
    '# GREENQUIC-OLD-V17: GreenQuicMaxSleepUs=5\n'
    'GreenQuicMaxSleepUs=2')
DPDK_INI_EXAMPLE = DPDK_INI_EXAMPLE.replace(
    'GreenQuicEnableSleep=0',
    '# GREENQUIC-OLD-V17: GreenQuicEnableSleep=0\n'
    'GreenQuicEnableSleep=1')


def patch_ack_tracker(repo: Path) -> None:
    path = repo / 'src/core/ack_tracker.c'
    log(f'Patching {path}')
    ensure_file(path)
    backup(path)
    text = read_text(path)
    if 'GREENQUIC-V18: ACK is actually ready to send' not in text:
        text = text.replace(
            '        QuicSendSetSendFlag(&Connection->Send, QUIC_CONN_SEND_FLAG_ACK);\n',
            '        QuicSendSetSendFlag(&Connection->Send, QUIC_CONN_SEND_FLAG_ACK);\n'
            '        // GREENQUIC-V18: ACK is actually ready to send.\n'
            '        CxPlatGreenQuicPlusPulseHints(GQPLUS_HINT_ACK_PENDING);\n',
            1)
        text = text.replace(
            '        QuicSendStartDelayedAckTimer(&Connection->Send);\n',
            '        QuicSendStartDelayedAckTimer(&Connection->Send);\n'
            '        /* GREENQUIC-OLD-V17: disabled. Timer start is not ACK-ready.\n'
            '         * CxPlatGreenQuicPlusPulseHints(GQPLUS_HINT_ACK_PENDING);\n'
            '         */\n',
            1)
        if 'GREENQUIC-V18: ACK is actually ready to send' not in text:
            raise RuntimeError('Failed to insert immediate ACK-ready hook')
    write_text(path, text)


def patch_cubic(repo: Path) -> None:
    path = repo / 'src/core/cubic.c'
    log(f'Patching {path}')
    ensure_file(path)
    backup(path)
    text = read_text(path)

    if 'GREENQUIC-V18: CWND blocked' not in text:
        text = insert_after(
            text,
            '        SendAllowance = 0;\n',
            '        // GREENQUIC-V18: CWND blocked is a low-pressure short hint.\n'
            '        CxPlatGreenQuicPlusPulseHints(GQPLUS_HINT_CUBIC_CWND_BLOCKED);\n',
            'CUBIC blocked hook')

    if 'GREENQUIC-V18: recovery begins' not in text:
        text = text.replace(
            '    Cubic->IsInRecovery = TRUE;\n',
            '    if (!Cubic->IsInRecovery) {\n'
            '        // GREENQUIC-V18: recovery begins; ref-counted across connections.\n'
            '        CxPlatGreenQuicPlusBeginRecovery();\n'
            '    }\n'
            '    Cubic->IsInRecovery = TRUE;\n'
            '    /* GREENQUIC-OLD-V17: disabled fixed 2-ms recovery pulse.\n'
            '     * CxPlatGreenQuicPlusPulseHints(GQPLUS_HINT_CUBIC_RECOVERY);\n'
            '     */\n',
            1)

    if 'GREENQUIC-V18: recovery ends' not in text:
        # Preserve indentation at every original recovery-clear site.
        # The original v17 assignment remains as the final line after the new hook.
        clear_pattern = re.compile(
            r'(?m)^([ \t]*)Cubic->IsInRecovery = FALSE;$')
        clear_matches = list(clear_pattern.finditer(text))
        if len(clear_matches) < 3:
            raise RuntimeError(
                f'Expected at least 3 recovery-clear anchors, found {len(clear_matches)}')

        def replace_recovery_clear(match: re.Match[str]) -> str:
            indent = match.group(1)
            return (
                f'{indent}if (Cubic->IsInRecovery) {{\n'
                f'{indent}    // GREENQUIC-V18: recovery ends.\n'
                f'{indent}    CxPlatGreenQuicPlusEndRecovery();\n'
                f'{indent}}}\n'
                f'{indent}Cubic->IsInRecovery = FALSE;')

        text = clear_pattern.sub(replace_recovery_clear, text)

    if 'OldCongestionWindow' not in text:
        if '    uint32_t BytesAcked = AckEvent->NumRetransmittableBytes;\n' in text:
            text = insert_after(
                text,
                '    uint32_t BytesAcked = AckEvent->NumRetransmittableBytes;\n',
                '    const uint32_t OldCongestionWindow = Cubic->CongestionWindow;\n',
                'CUBIC old CWND')
        elif '    uint32_t BytesAcked = NumRetransmittableBytes;\n' in text:
            text = insert_after(
                text,
                '    uint32_t BytesAcked = NumRetransmittableBytes;\n',
                '    const uint32_t OldCongestionWindow = Cubic->CongestionWindow;\n',
                'CUBIC old CWND fallback')
        else:
            raise RuntimeError('Could not find BytesAcked anchor')
        text = insert_before(
            text,
            'Exit:\n',
            '    if (Cubic->CongestionWindow > OldCongestionWindow) {\n'
            '        CxPlatGreenQuicPlusPulseHints(GQPLUS_HINT_CUBIC_RAMPING);\n'
            '    }\n\n',
            'CUBIC ramping hook')

    write_text(path, text)

# -----------------------------------------------------------------------------
# V18 optional multi-core hint storage.
# The old MULTICORE_* strings and functions remain above, but these definitions
# are the active ones when --enable-multi-core is requested.
# -----------------------------------------------------------------------------

MULTICORE_PARTITION_GREENQUIC_PLUS_H = r'''/*++

    GreenQUIC Plus public hint API, v18 optional multi-core path.

    QUIC core events target a DPDK lcore through:
        MsQuic partition -> configured DPDK lcore.

    Recovery is reference-counted per mapped lcore.

--*/

#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GQPLUS_LCORE_UNKNOWN              ((uint16_t)0xffffu)
#define GQPLUS_PARTITION_UNKNOWN          ((uint16_t)0xffffu)

#define GQPLUS_HINT_ACK_PENDING             (1ull << 0)
#define GQPLUS_HINT_CUBIC_CWND_BLOCKED     (1ull << 1)
#define GQPLUS_HINT_CUBIC_RECOVERY         (1ull << 2)
#define GQPLUS_HINT_CUBIC_RAMPING          (1ull << 3)
#define GQPLUS_HINT_SERVER_FILE_TX_ACTIVE  (1ull << 16)
#define GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE  (1ull << 17)

void CxPlatGreenQuicPlusSetThreadLcore(uint16_t Lcore);
void CxPlatGreenQuicPlusClearThreadLcore(void);
void CxPlatGreenQuicPlusSetPartitionDpdkLcore(uint16_t Partition, uint16_t Lcore);
uint16_t CxPlatGreenQuicPlusGetPartitionDpdkLcore(uint16_t Partition);

void CxPlatGreenQuicPlusSetHints(uint64_t Hints);
void CxPlatGreenQuicPlusClearHints(uint64_t Hints);
void CxPlatGreenQuicPlusBeginTransfer(uint64_t Hints);
void CxPlatGreenQuicPlusEndTransfer(uint64_t Hints);
void CxPlatGreenQuicPlusBeginRecovery(void);
void CxPlatGreenQuicPlusEndRecovery(void);
void CxPlatGreenQuicPlusBeginRecoveryForPartition(uint16_t Partition);
void CxPlatGreenQuicPlusEndRecoveryForPartition(uint16_t Partition);

void CxPlatGreenQuicPlusPulseHints(uint64_t Hints);
void CxPlatGreenQuicPlusPulseHintsForLcore(uint16_t Lcore, uint64_t Hints);
void CxPlatGreenQuicPlusPulseHintsForPartition(uint16_t Partition, uint64_t Hints);

uint64_t CxPlatGreenQuicPlusGetHints(void);
uint64_t CxPlatGreenQuicPlusGetHintsForLcore(uint16_t Lcore, int IncludeUnknownGlobalHints);

#ifdef __cplusplus
}
#endif
'''

MULTICORE_PARTITION_GREENQUIC_PLUS_C = r'''/*++

    GreenQUIC Plus hint storage, v18 optional multi-core path.

    - transient expiry is independent per hint and per lcore
    - recovery is reference-counted per mapped lcore
    - transfer hints stay global reference-counted context
    - partition-to-lcore mapping is explicit or modulo default

    The v17 shared-expiry approach is retained in #if 0.

--*/

#define _POSIX_C_SOURCE 200809L

#include "greenquic_plus.h"

#include <stdatomic.h>
#include <stdint.h>
#include <time.h>

#define GQPLUS_ACK_TTL_NS          (500ull * 1000ull)
#define GQPLUS_CWND_BLOCKED_TTL_NS (1000ull * 1000ull)
#define GQPLUS_RECOVERY_PULSE_NS   (2000ull * 1000ull)
#define GQPLUS_RAMPING_TTL_NS      (2000ull * 1000ull)
#define GQPLUS_OTHER_TTL_NS        (2000ull * 1000ull)
#define GQPLUS_TRANSFER_HINTS \
    (GQPLUS_HINT_SERVER_FILE_TX_ACTIVE | GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE)
#define GQPLUS_KNOWN_TRANSIENT_HINTS \
    (GQPLUS_HINT_ACK_PENDING | GQPLUS_HINT_CUBIC_CWND_BLOCKED | \
     GQPLUS_HINT_CUBIC_RECOVERY | GQPLUS_HINT_CUBIC_RAMPING)
#define GQPLUS_MAX_LCORES 512u
#define GQPLUS_MAX_PARTITIONS 512u

#if defined(_MSC_VER)
__declspec(thread) static uint16_t ThreadLcore = GQPLUS_LCORE_UNKNOWN;
#else
static _Thread_local uint16_t ThreadLcore = GQPLUS_LCORE_UNKNOWN;
#endif

static atomic_uint_fast64_t GlobalPersistentHints;
static atomic_uint_fast64_t UnknownPersistentHints;
static atomic_uint_fast64_t LcorePersistentHints[GQPLUS_MAX_LCORES];

static atomic_uint_fast64_t UnknownAckUntilNs;
static atomic_uint_fast64_t UnknownBlockedUntilNs;
static atomic_uint_fast64_t UnknownRecoveryPulseUntilNs;
static atomic_uint_fast64_t UnknownRampingUntilNs;
static atomic_uint_fast64_t UnknownOtherHints;
static atomic_uint_fast64_t UnknownOtherUntilNs;

static atomic_uint_fast64_t LcoreAckUntilNs[GQPLUS_MAX_LCORES];
static atomic_uint_fast64_t LcoreBlockedUntilNs[GQPLUS_MAX_LCORES];
static atomic_uint_fast64_t LcoreRecoveryPulseUntilNs[GQPLUS_MAX_LCORES];
static atomic_uint_fast64_t LcoreRampingUntilNs[GQPLUS_MAX_LCORES];
static atomic_uint_fast64_t LcoreOtherHints[GQPLUS_MAX_LCORES];
static atomic_uint_fast64_t LcoreOtherUntilNs[GQPLUS_MAX_LCORES];

static atomic_uint_fast32_t ServerFileTxActiveCount;
static atomic_uint_fast32_t ClientFileRxActiveCount;
static atomic_uint_fast32_t UnknownRecoveryActiveCount;
static atomic_uint_fast32_t LcoreRecoveryActiveCount[GQPLUS_MAX_LCORES];

// Stores lcore + 1. Zero means unmapped; actual lcore 0 remains representable.
static atomic_uint_fast32_t PartitionDpdkLcorePlusOne[GQPLUS_MAX_PARTITIONS];

static uint64_t
CxPlatGreenQuicPlusNowNs(void)
{
    struct timespec Ts;
#if defined(CLOCK_MONOTONIC_RAW)
    clock_gettime(CLOCK_MONOTONIC_RAW, &Ts);
#else
    clock_gettime(CLOCK_MONOTONIC, &Ts);
#endif
    return ((uint64_t)Ts.tv_sec * 1000000000ull) + (uint64_t)Ts.tv_nsec;
}

static int
CxPlatGreenQuicPlusValidLcore(uint16_t Lcore)
{
    return Lcore != GQPLUS_LCORE_UNKNOWN && Lcore < GQPLUS_MAX_LCORES;
}

static int
CxPlatGreenQuicPlusValidPartition(uint16_t Partition)
{
    return Partition != GQPLUS_PARTITION_UNKNOWN &&
        Partition < GQPLUS_MAX_PARTITIONS;
}

static void
CxPlatGreenQuicPlusExtendUntil(
    atomic_uint_fast64_t* Until,
    uint64_t Candidate
    )
{
    uint_fast64_t Old = atomic_load_explicit(Until, memory_order_relaxed);
    while (Old < Candidate &&
           !atomic_compare_exchange_weak_explicit(
               Until,
               &Old,
               Candidate,
               memory_order_release,
               memory_order_relaxed)) {
    }
}

void
CxPlatGreenQuicPlusSetThreadLcore(uint16_t Lcore)
{
    ThreadLcore = Lcore;
}

void
CxPlatGreenQuicPlusClearThreadLcore(void)
{
    ThreadLcore = GQPLUS_LCORE_UNKNOWN;
}

void
CxPlatGreenQuicPlusSetPartitionDpdkLcore(
    uint16_t Partition,
    uint16_t Lcore
    )
{
    if (!CxPlatGreenQuicPlusValidPartition(Partition)) {
        return;
    }

    atomic_store_explicit(
        &PartitionDpdkLcorePlusOne[Partition],
        CxPlatGreenQuicPlusValidLcore(Lcore) ?
            (uint_fast32_t)Lcore + 1u : 0u,
        memory_order_release);
}

uint16_t
CxPlatGreenQuicPlusGetPartitionDpdkLcore(uint16_t Partition)
{
    if (!CxPlatGreenQuicPlusValidPartition(Partition)) {
        return GQPLUS_LCORE_UNKNOWN;
    }

    const uint_fast32_t Stored = atomic_load_explicit(
        &PartitionDpdkLcorePlusOne[Partition],
        memory_order_acquire);
    return Stored == 0 ?
        GQPLUS_LCORE_UNKNOWN : (uint16_t)(Stored - 1u);
}

static void
CxPlatGreenQuicPlusIncrementGlobal(
    atomic_uint_fast32_t* Counter,
    uint64_t Hint
    )
{
    const uint_fast32_t Old =
        atomic_fetch_add_explicit(Counter, 1, memory_order_relaxed);
    if (Old == 0) {
        atomic_fetch_or_explicit(
            &GlobalPersistentHints,
            Hint,
            memory_order_release);
    }
}

static void
CxPlatGreenQuicPlusDecrementGlobal(
    atomic_uint_fast32_t* Counter,
    uint64_t Hint
    )
{
    uint_fast32_t Old = atomic_load_explicit(Counter, memory_order_relaxed);
    while (Old != 0) {
        if (atomic_compare_exchange_weak_explicit(
                Counter,
                &Old,
                Old - 1,
                memory_order_acq_rel,
                memory_order_relaxed)) {
            if (Old == 1) {
                atomic_fetch_and_explicit(
                    &GlobalPersistentHints,
                    ~Hint,
                    memory_order_release);
            }
            return;
        }
    }
}

static void
CxPlatGreenQuicPlusBeginRecoveryForLcore(uint16_t Lcore)
{
    if (CxPlatGreenQuicPlusValidLcore(Lcore)) {
        const uint_fast32_t Old = atomic_fetch_add_explicit(
            &LcoreRecoveryActiveCount[Lcore],
            1,
            memory_order_relaxed);
        if (Old == 0) {
            atomic_fetch_or_explicit(
                &LcorePersistentHints[Lcore],
                GQPLUS_HINT_CUBIC_RECOVERY,
                memory_order_release);
        }
    } else {
        const uint_fast32_t Old = atomic_fetch_add_explicit(
            &UnknownRecoveryActiveCount,
            1,
            memory_order_relaxed);
        if (Old == 0) {
            atomic_fetch_or_explicit(
                &UnknownPersistentHints,
                GQPLUS_HINT_CUBIC_RECOVERY,
                memory_order_release);
        }
    }
}

static void
CxPlatGreenQuicPlusEndRecoveryForLcore(uint16_t Lcore)
{
    atomic_uint_fast32_t* Counter =
        CxPlatGreenQuicPlusValidLcore(Lcore) ?
            &LcoreRecoveryActiveCount[Lcore] :
            &UnknownRecoveryActiveCount;
    atomic_uint_fast64_t* Persistent =
        CxPlatGreenQuicPlusValidLcore(Lcore) ?
            &LcorePersistentHints[Lcore] :
            &UnknownPersistentHints;

    uint_fast32_t Old = atomic_load_explicit(Counter, memory_order_relaxed);
    while (Old != 0) {
        if (atomic_compare_exchange_weak_explicit(
                Counter,
                &Old,
                Old - 1,
                memory_order_acq_rel,
                memory_order_relaxed)) {
            if (Old == 1) {
                atomic_fetch_and_explicit(
                    Persistent,
                    ~GQPLUS_HINT_CUBIC_RECOVERY,
                    memory_order_release);
            }
            return;
        }
    }
}

void
CxPlatGreenQuicPlusBeginTransfer(uint64_t Hints)
{
    if ((Hints & GQPLUS_HINT_SERVER_FILE_TX_ACTIVE) != 0) {
        CxPlatGreenQuicPlusIncrementGlobal(
            &ServerFileTxActiveCount,
            GQPLUS_HINT_SERVER_FILE_TX_ACTIVE);
    }
    if ((Hints & GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE) != 0) {
        CxPlatGreenQuicPlusIncrementGlobal(
            &ClientFileRxActiveCount,
            GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE);
    }
}

void
CxPlatGreenQuicPlusEndTransfer(uint64_t Hints)
{
    if ((Hints & GQPLUS_HINT_SERVER_FILE_TX_ACTIVE) != 0) {
        CxPlatGreenQuicPlusDecrementGlobal(
            &ServerFileTxActiveCount,
            GQPLUS_HINT_SERVER_FILE_TX_ACTIVE);
    }
    if ((Hints & GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE) != 0) {
        CxPlatGreenQuicPlusDecrementGlobal(
            &ClientFileRxActiveCount,
            GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE);
    }
}

void
CxPlatGreenQuicPlusBeginRecoveryForPartition(uint16_t Partition)
{
    uint16_t Lcore =
        CxPlatGreenQuicPlusGetPartitionDpdkLcore(Partition);
    if (!CxPlatGreenQuicPlusValidLcore(Lcore)) {
        Lcore = ThreadLcore;
    }
    CxPlatGreenQuicPlusBeginRecoveryForLcore(Lcore);
}

void
CxPlatGreenQuicPlusEndRecoveryForPartition(uint16_t Partition)
{
    uint16_t Lcore =
        CxPlatGreenQuicPlusGetPartitionDpdkLcore(Partition);
    if (!CxPlatGreenQuicPlusValidLcore(Lcore)) {
        Lcore = ThreadLcore;
    }
    CxPlatGreenQuicPlusEndRecoveryForLcore(Lcore);
}

void
CxPlatGreenQuicPlusBeginRecovery(void)
{
    CxPlatGreenQuicPlusBeginRecoveryForLcore(ThreadLcore);
}

void
CxPlatGreenQuicPlusEndRecovery(void)
{
    CxPlatGreenQuicPlusEndRecoveryForLcore(ThreadLcore);
}

void
CxPlatGreenQuicPlusSetHints(uint64_t Hints)
{
    const uint64_t Plain =
        Hints & ~(GQPLUS_TRANSFER_HINTS | GQPLUS_HINT_CUBIC_RECOVERY);
    atomic_fetch_or_explicit(
        &GlobalPersistentHints,
        Plain,
        memory_order_relaxed);
    CxPlatGreenQuicPlusBeginTransfer(Hints & GQPLUS_TRANSFER_HINTS);
    if ((Hints & GQPLUS_HINT_CUBIC_RECOVERY) != 0) {
        CxPlatGreenQuicPlusBeginRecovery();
    }
}

void
CxPlatGreenQuicPlusClearHints(uint64_t Hints)
{
    const uint64_t Plain =
        Hints & ~(GQPLUS_TRANSFER_HINTS | GQPLUS_HINT_CUBIC_RECOVERY);
    atomic_fetch_and_explicit(
        &GlobalPersistentHints,
        ~Plain,
        memory_order_relaxed);
    CxPlatGreenQuicPlusEndTransfer(Hints & GQPLUS_TRANSFER_HINTS);
    if ((Hints & GQPLUS_HINT_CUBIC_RECOVERY) != 0) {
        CxPlatGreenQuicPlusEndRecovery();
    }
}

static void
CxPlatGreenQuicPlusPulseToBucket(
    uint16_t Lcore,
    uint64_t Hints,
    uint64_t Now
    )
{
    atomic_uint_fast64_t* AckUntil;
    atomic_uint_fast64_t* BlockedUntil;
    atomic_uint_fast64_t* RecoveryUntil;
    atomic_uint_fast64_t* RampingUntil;
    atomic_uint_fast64_t* OtherHints;
    atomic_uint_fast64_t* OtherUntil;

    if (CxPlatGreenQuicPlusValidLcore(Lcore)) {
        AckUntil = &LcoreAckUntilNs[Lcore];
        BlockedUntil = &LcoreBlockedUntilNs[Lcore];
        RecoveryUntil = &LcoreRecoveryPulseUntilNs[Lcore];
        RampingUntil = &LcoreRampingUntilNs[Lcore];
        OtherHints = &LcoreOtherHints[Lcore];
        OtherUntil = &LcoreOtherUntilNs[Lcore];
    } else {
        AckUntil = &UnknownAckUntilNs;
        BlockedUntil = &UnknownBlockedUntilNs;
        RecoveryUntil = &UnknownRecoveryPulseUntilNs;
        RampingUntil = &UnknownRampingUntilNs;
        OtherHints = &UnknownOtherHints;
        OtherUntil = &UnknownOtherUntilNs;
    }

    if ((Hints & GQPLUS_HINT_ACK_PENDING) != 0) {
        CxPlatGreenQuicPlusExtendUntil(
            AckUntil,
            Now + GQPLUS_ACK_TTL_NS);
    }
    if ((Hints & GQPLUS_HINT_CUBIC_CWND_BLOCKED) != 0) {
        CxPlatGreenQuicPlusExtendUntil(
            BlockedUntil,
            Now + GQPLUS_CWND_BLOCKED_TTL_NS);
    }
    if ((Hints & GQPLUS_HINT_CUBIC_RECOVERY) != 0) {
        CxPlatGreenQuicPlusExtendUntil(
            RecoveryUntil,
            Now + GQPLUS_RECOVERY_PULSE_NS);
    }
    if ((Hints & GQPLUS_HINT_CUBIC_RAMPING) != 0) {
        CxPlatGreenQuicPlusExtendUntil(
            RampingUntil,
            Now + GQPLUS_RAMPING_TTL_NS);
    }

    const uint64_t Other = Hints & ~GQPLUS_KNOWN_TRANSIENT_HINTS;
    if (Other != 0) {
        atomic_fetch_or_explicit(
            OtherHints,
            Other,
            memory_order_relaxed);
        CxPlatGreenQuicPlusExtendUntil(
            OtherUntil,
            Now + GQPLUS_OTHER_TTL_NS);
    }
}

void
CxPlatGreenQuicPlusPulseHintsForLcore(
    uint16_t Lcore,
    uint64_t Hints
    )
{
    CxPlatGreenQuicPlusPulseToBucket(
        Lcore,
        Hints,
        CxPlatGreenQuicPlusNowNs());
}

void
CxPlatGreenQuicPlusPulseHintsForPartition(
    uint16_t Partition,
    uint64_t Hints
    )
{
    uint16_t Lcore =
        CxPlatGreenQuicPlusGetPartitionDpdkLcore(Partition);
    if (!CxPlatGreenQuicPlusValidLcore(Lcore)) {
        Lcore = ThreadLcore;
    }
    CxPlatGreenQuicPlusPulseHintsForLcore(Lcore, Hints);
}

void
CxPlatGreenQuicPlusPulseHints(uint64_t Hints)
{
    CxPlatGreenQuicPlusPulseHintsForLcore(ThreadLcore, Hints);
}

static uint64_t
CxPlatGreenQuicPlusReadTransientBucket(
    uint16_t Lcore,
    uint64_t Now
    )
{
    atomic_uint_fast64_t* AckUntil;
    atomic_uint_fast64_t* BlockedUntil;
    atomic_uint_fast64_t* RecoveryUntil;
    atomic_uint_fast64_t* RampingUntil;
    atomic_uint_fast64_t* OtherHints;
    atomic_uint_fast64_t* OtherUntil;

    if (CxPlatGreenQuicPlusValidLcore(Lcore)) {
        AckUntil = &LcoreAckUntilNs[Lcore];
        BlockedUntil = &LcoreBlockedUntilNs[Lcore];
        RecoveryUntil = &LcoreRecoveryPulseUntilNs[Lcore];
        RampingUntil = &LcoreRampingUntilNs[Lcore];
        OtherHints = &LcoreOtherHints[Lcore];
        OtherUntil = &LcoreOtherUntilNs[Lcore];
    } else {
        AckUntil = &UnknownAckUntilNs;
        BlockedUntil = &UnknownBlockedUntilNs;
        RecoveryUntil = &UnknownRecoveryPulseUntilNs;
        RampingUntil = &UnknownRampingUntilNs;
        OtherHints = &UnknownOtherHints;
        OtherUntil = &UnknownOtherUntilNs;
    }

    uint64_t Hints = 0;
    if (Now <= atomic_load_explicit(AckUntil, memory_order_acquire)) {
        Hints |= GQPLUS_HINT_ACK_PENDING;
    }
    if (Now <= atomic_load_explicit(BlockedUntil, memory_order_acquire)) {
        Hints |= GQPLUS_HINT_CUBIC_CWND_BLOCKED;
    }
    if (Now <= atomic_load_explicit(RecoveryUntil, memory_order_acquire)) {
        Hints |= GQPLUS_HINT_CUBIC_RECOVERY;
    }
    if (Now <= atomic_load_explicit(RampingUntil, memory_order_acquire)) {
        Hints |= GQPLUS_HINT_CUBIC_RAMPING;
    }
    if (Now <= atomic_load_explicit(OtherUntil, memory_order_acquire)) {
        Hints |= atomic_load_explicit(OtherHints, memory_order_relaxed);
    } else {
        atomic_store_explicit(OtherHints, 0, memory_order_relaxed);
    }
    return Hints;
}

uint64_t
CxPlatGreenQuicPlusGetHintsForLcore(
    uint16_t Lcore,
    int IncludeUnknownGlobalHints
    )
{
    const uint64_t Now = CxPlatGreenQuicPlusNowNs();
    uint64_t Hints = 0;

    if (CxPlatGreenQuicPlusValidLcore(Lcore)) {
        Hints |= atomic_load_explicit(
            &LcorePersistentHints[Lcore],
            memory_order_acquire);
        Hints |= CxPlatGreenQuicPlusReadTransientBucket(Lcore, Now);
    }

    // Transfer hints are global context; local datapath pressure decides action.
    Hints |= atomic_load_explicit(
        &GlobalPersistentHints,
        memory_order_acquire);

    if (IncludeUnknownGlobalHints) {
        Hints |= atomic_load_explicit(
            &UnknownPersistentHints,
            memory_order_acquire);
        Hints |= CxPlatGreenQuicPlusReadTransientBucket(
            GQPLUS_LCORE_UNKNOWN,
            Now);
    }
    return Hints;
}

uint64_t
CxPlatGreenQuicPlusGetHints(void)
{
    const uint64_t Now = CxPlatGreenQuicPlusNowNs();
    uint64_t Hints =
        atomic_load_explicit(
            &GlobalPersistentHints,
            memory_order_acquire) |
        atomic_load_explicit(
            &UnknownPersistentHints,
            memory_order_acquire) |
        CxPlatGreenQuicPlusReadTransientBucket(
            GQPLUS_LCORE_UNKNOWN,
            Now);

    for (uint16_t Lcore = 0; Lcore < GQPLUS_MAX_LCORES; ++Lcore) {
        Hints |= atomic_load_explicit(
            &LcorePersistentHints[Lcore],
            memory_order_acquire);
        Hints |= CxPlatGreenQuicPlusReadTransientBucket(Lcore, Now);
    }
    return Hints;
}

#if 0
/*
 * GREENQUIC-OLD-V17:
 * static atomic_uint_fast64_t LcoreTransientHints[GQPLUS_MAX_LCORES];
 * static atomic_uint_fast64_t LcoreTransientUntilNs[GQPLUS_MAX_LCORES];
 * One pulse extended every old transient bit in that lcore bucket.
 */
#endif
'''


# -----------------------------------------------------------------------------
# V18 DIRECTIONAL RX/TX HINT-API CORRECTION
# -----------------------------------------------------------------------------
# Keep the complete implementations above. These final string overrides add an
# efficient TX-side aggregate getter. The TX owner receives ACK-ready,
# congestion-window-growth, and recovery information emitted by any partition.
# RX lcores continue to use their partition-mapped local hint buckets.

if 'CxPlatGreenQuicPlusGetTxHints' not in GREENQUIC_PLUS_H:
    GREENQUIC_PLUS_H = GREENQUIC_PLUS_H.replace(
        'uint64_t CxPlatGreenQuicPlusGetHints(void);\n',
        'uint64_t CxPlatGreenQuicPlusGetHints(void);\n'
        'uint64_t CxPlatGreenQuicPlusGetTxHints(void);\n',
        1)

_SINGLE_TX_GETTER_MARKER = r'''
#if 0
/*
 * GREENQUIC-OLD-V17: one shared transient bitmask and expiration.
'''
_SINGLE_TX_GETTER = r'''
uint64_t
CxPlatGreenQuicPlusGetTxHints(void)
{
    // In the single-lcore path the same lcore owns RX and TX.
    return CxPlatGreenQuicPlusGetHints();
}
'''
if 'CxPlatGreenQuicPlusGetTxHints(void)' not in GREENQUIC_PLUS_C:
    if _SINGLE_TX_GETTER_MARKER not in GREENQUIC_PLUS_C:
        raise RuntimeError('Directional override could not find single-core TX getter marker')
    GREENQUIC_PLUS_C = GREENQUIC_PLUS_C.replace(
        _SINGLE_TX_GETTER_MARKER,
        '\n' + _SINGLE_TX_GETTER + _SINGLE_TX_GETTER_MARKER,
        1)

if 'CxPlatGreenQuicPlusGetTxHints' not in MULTICORE_PARTITION_GREENQUIC_PLUS_H:
    MULTICORE_PARTITION_GREENQUIC_PLUS_H = MULTICORE_PARTITION_GREENQUIC_PLUS_H.replace(
        'uint64_t CxPlatGreenQuicPlusGetHints(void);\n'
        'uint64_t CxPlatGreenQuicPlusGetHintsForLcore(uint16_t Lcore, int IncludeUnknownGlobalHints);\n',
        'uint64_t CxPlatGreenQuicPlusGetHints(void);\n'
        'uint64_t CxPlatGreenQuicPlusGetTxHints(void);\n'
        'uint64_t CxPlatGreenQuicPlusGetHintsForLcore(uint16_t Lcore, int IncludeUnknownGlobalHints);\n',
        1)

if 'GlobalTxAckUntilNs' not in MULTICORE_PARTITION_GREENQUIC_PLUS_C:
    MULTICORE_PARTITION_GREENQUIC_PLUS_C = MULTICORE_PARTITION_GREENQUIC_PLUS_C.replace(
        'static atomic_uint_fast64_t LcoreOtherUntilNs[GQPLUS_MAX_LCORES];\n\n'
        'static atomic_uint_fast32_t ServerFileTxActiveCount;\n',
        'static atomic_uint_fast64_t LcoreOtherUntilNs[GQPLUS_MAX_LCORES];\n\n'
        '// GREENQUIC-V18-DIRECTIONAL-RXTX: global mirrors read only by the TX owner.\n'
        'static atomic_uint_fast64_t GlobalTxAckUntilNs;\n'
        'static atomic_uint_fast64_t GlobalTxRecoveryPulseUntilNs;\n'
        'static atomic_uint_fast64_t GlobalTxRampingUntilNs;\n'
        'static atomic_uint_fast32_t GlobalTxRecoveryActiveCount;\n\n'
        'static atomic_uint_fast32_t ServerFileTxActiveCount;\n', 1)

    MULTICORE_PARTITION_GREENQUIC_PLUS_C = MULTICORE_PARTITION_GREENQUIC_PLUS_C.replace(
        'static void\nCxPlatGreenQuicPlusBeginRecoveryForLcore(uint16_t Lcore)\n{\n',
        'static void\nCxPlatGreenQuicPlusBeginRecoveryForLcore(uint16_t Lcore)\n{\n'
        '    atomic_fetch_add_explicit(\n'
        '        &GlobalTxRecoveryActiveCount,\n'
        '        1,\n'
        '        memory_order_relaxed);\n', 1)

    _OLD_END_RECOVERY = r'''static void
CxPlatGreenQuicPlusEndRecoveryForLcore(uint16_t Lcore)
{
    atomic_uint_fast32_t* Counter =
        CxPlatGreenQuicPlusValidLcore(Lcore) ?
            &LcoreRecoveryActiveCount[Lcore] :
            &UnknownRecoveryActiveCount;
    atomic_uint_fast64_t* Persistent =
        CxPlatGreenQuicPlusValidLcore(Lcore) ?
            &LcorePersistentHints[Lcore] :
            &UnknownPersistentHints;

    uint_fast32_t Old = atomic_load_explicit(Counter, memory_order_relaxed);
    while (Old != 0) {
        if (atomic_compare_exchange_weak_explicit(
                Counter,
                &Old,
                Old - 1,
                memory_order_acq_rel,
                memory_order_relaxed)) {
            if (Old == 1) {
                atomic_fetch_and_explicit(
                    Persistent,
                    ~GQPLUS_HINT_CUBIC_RECOVERY,
                    memory_order_release);
            }
            return;
        }
    }
}
'''
    _NEW_END_RECOVERY = r'''static void
CxPlatGreenQuicPlusEndRecoveryForLcore(uint16_t Lcore)
{
    atomic_uint_fast32_t* Counter =
        CxPlatGreenQuicPlusValidLcore(Lcore) ?
            &LcoreRecoveryActiveCount[Lcore] :
            &UnknownRecoveryActiveCount;
    atomic_uint_fast64_t* Persistent =
        CxPlatGreenQuicPlusValidLcore(Lcore) ?
            &LcorePersistentHints[Lcore] :
            &UnknownPersistentHints;

    uint_fast32_t Old = atomic_load_explicit(Counter, memory_order_relaxed);
    while (Old != 0) {
        if (atomic_compare_exchange_weak_explicit(
                Counter,
                &Old,
                Old - 1,
                memory_order_acq_rel,
                memory_order_relaxed)) {
            if (Old == 1) {
                atomic_fetch_and_explicit(
                    Persistent,
                    ~GQPLUS_HINT_CUBIC_RECOVERY,
                    memory_order_release);
            }

            uint_fast32_t GlobalOld = atomic_load_explicit(
                &GlobalTxRecoveryActiveCount,
                memory_order_relaxed);
            while (GlobalOld != 0 &&
                   !atomic_compare_exchange_weak_explicit(
                       &GlobalTxRecoveryActiveCount,
                       &GlobalOld,
                       GlobalOld - 1,
                       memory_order_acq_rel,
                       memory_order_relaxed)) {
            }
            return;
        }
    }
}
'''
    if _OLD_END_RECOVERY not in MULTICORE_PARTITION_GREENQUIC_PLUS_C:
        raise RuntimeError('Directional override could not find multi-core recovery end helper')
    MULTICORE_PARTITION_GREENQUIC_PLUS_C = MULTICORE_PARTITION_GREENQUIC_PLUS_C.replace(
        _OLD_END_RECOVERY, _NEW_END_RECOVERY, 1)

    MULTICORE_PARTITION_GREENQUIC_PLUS_C = MULTICORE_PARTITION_GREENQUIC_PLUS_C.replace(
        'static void\n'
        'CxPlatGreenQuicPlusPulseToBucket(\n'
        '    uint16_t Lcore,\n'
        '    uint64_t Hints,\n'
        '    uint64_t Now\n'
        '    )\n'
        '{\n',
        'static void\n'
        'CxPlatGreenQuicPlusPulseToBucket(\n'
        '    uint16_t Lcore,\n'
        '    uint64_t Hints,\n'
        '    uint64_t Now\n'
        '    )\n'
        '{\n'
        '    // Mirror only TX-relevant transient information for the TX owner.\n'
        '    if ((Hints & GQPLUS_HINT_ACK_PENDING) != 0) {\n'
        '        CxPlatGreenQuicPlusExtendUntil(\n'
        '            &GlobalTxAckUntilNs,\n'
        '            Now + GQPLUS_ACK_TTL_NS);\n'
        '    }\n'
        '    if ((Hints & GQPLUS_HINT_CUBIC_RECOVERY) != 0) {\n'
        '        CxPlatGreenQuicPlusExtendUntil(\n'
        '            &GlobalTxRecoveryPulseUntilNs,\n'
        '            Now + GQPLUS_RECOVERY_PULSE_NS);\n'
        '    }\n'
        '    if ((Hints & GQPLUS_HINT_CUBIC_RAMPING) != 0) {\n'
        '        CxPlatGreenQuicPlusExtendUntil(\n'
        '            &GlobalTxRampingUntilNs,\n'
        '            Now + GQPLUS_RAMPING_TTL_NS);\n'
        '    }\n\n', 1)

    _MULTI_GET_MARKER = r'''uint64_t
CxPlatGreenQuicPlusGetHints(void)
{
'''
    _MULTI_TX_GETTER = r'''uint64_t
CxPlatGreenQuicPlusGetTxHints(void)
{
    const uint64_t Now = CxPlatGreenQuicPlusNowNs();
    uint64_t Hints = atomic_load_explicit(
        &GlobalPersistentHints,
        memory_order_acquire);

    if (Now <= atomic_load_explicit(
            &GlobalTxAckUntilNs,
            memory_order_acquire)) {
        Hints |= GQPLUS_HINT_ACK_PENDING;
    }
    if (atomic_load_explicit(
            &GlobalTxRecoveryActiveCount,
            memory_order_acquire) != 0 ||
        Now <= atomic_load_explicit(
            &GlobalTxRecoveryPulseUntilNs,
            memory_order_acquire)) {
        Hints |= GQPLUS_HINT_CUBIC_RECOVERY;
    }
    if (Now <= atomic_load_explicit(
            &GlobalTxRampingUntilNs,
            memory_order_acquire)) {
        Hints |= GQPLUS_HINT_CUBIC_RAMPING;
    }
    return Hints;
}

'''
    if _MULTI_GET_MARKER not in MULTICORE_PARTITION_GREENQUIC_PLUS_C:
        raise RuntimeError('Directional override could not find multi-core getter marker')
    MULTICORE_PARTITION_GREENQUIC_PLUS_C = MULTICORE_PARTITION_GREENQUIC_PLUS_C.replace(
        _MULTI_GET_MARKER, _MULTI_TX_GETTER + _MULTI_GET_MARKER, 1)


def patch_multicore_plus_hint_api(repo: Path) -> None:
    '''V18 partition-to-DPDK-lcore mapped hint storage.'''
    write_new_or_replace(
        repo / 'src/inc/greenquic_plus.h',
        MULTICORE_PARTITION_GREENQUIC_PLUS_H)
    write_new_or_replace(
        repo / 'src/platform/greenquic_plus.c',
        MULTICORE_PARTITION_GREENQUIC_PLUS_C)
    log('V18 partition-mapped per-hint storage written.')


def patch_multicore_partition_hooks(repo: Path) -> None:
    '''V18 partition-targeted hooks with indentation preserved.'''

    def partition_expression(indent: str, comma: bool) -> str:
        suffix = ',' if comma else ''
        return (
            f'{indent}Connection->Worker != NULL ?\n'
            f'{indent}    Connection->Worker->PartitionIndex :\n'
            f'{indent}    GQPLUS_PARTITION_UNKNOWN{suffix}')

    def replace_pulse(
        text: str,
        old_hint: str,
        new_function: str,
    ) -> str:
        pattern = re.compile(
            rf'(?m)^([ \t]*)CxPlatGreenQuicPlusPulseHints\({re.escape(old_hint)}\);$')

        def repl(match: re.Match[str]) -> str:
            indent = match.group(1)
            return (
                f'{indent}{new_function}(\n'
                f'{partition_expression(indent + "    ", True)}\n'
                f'{indent}    {old_hint});')

        return pattern.sub(repl, text)

    def replace_recovery_call(
        text: str,
        old_function: str,
        new_function: str,
    ) -> str:
        pattern = re.compile(
            rf'(?m)^([ \t]*){re.escape(old_function)}\(\);$')

        def repl(match: re.Match[str]) -> str:
            indent = match.group(1)
            return (
                f'{indent}{new_function}(\n'
                f'{partition_expression(indent + "    ", False)});')

        return pattern.sub(repl, text)

    ack = repo / 'src/core/ack_tracker.c'
    if ack.exists():
        backup(ack)
        text = read_text(ack)
        text = replace_pulse(
            text,
            'GQPLUS_HINT_ACK_PENDING',
            'CxPlatGreenQuicPlusPulseHintsForPartition')
        write_text(ack, text)

    cubic = repo / 'src/core/cubic.c'
    if cubic.exists():
        backup(cubic)
        text = read_text(cubic)
        text = replace_pulse(
            text,
            'GQPLUS_HINT_CUBIC_CWND_BLOCKED',
            'CxPlatGreenQuicPlusPulseHintsForPartition')
        text = replace_pulse(
            text,
            'GQPLUS_HINT_CUBIC_RAMPING',
            'CxPlatGreenQuicPlusPulseHintsForPartition')
        text = replace_recovery_call(
            text,
            'CxPlatGreenQuicPlusBeginRecovery',
            'CxPlatGreenQuicPlusBeginRecoveryForPartition')
        text = replace_recovery_call(
            text,
            'CxPlatGreenQuicPlusEndRecovery',
            'CxPlatGreenQuicPlusEndRecoveryForPartition')
        write_text(cubic, text)

    log('V18 ACK/CUBIC hooks mapped by MsQuic partition.')


# Keep a reference to the complete v17 multi-core patch, then correct only the
# generated multi-core TX behavior and fields.
_patch_multicore_support_v17 = patch_multicore_support_v12


def patch_multicore_support_v12(repo: Path) -> None:
    '''V18 wrapper: reuse all v17 RX/RSS mapping, then enforce one TX consumer.'''
    _patch_multicore_support_v17(repo)

    path = repo / 'src/platform/datapath_raw_dpdk.c'
    ensure_file(path)
    backup(path)
    text = read_text(path)

    # Add dedicated TX-owner fields after the v17 multi-core queue count.
    if 'GreenQuicTxOwnerLcore' not in text:
        text = text.replace(
            '    uint16_t GreenQuicQueueCount;     // actual RX/TX queue count used by optional multi-core path\n',
            '    uint16_t GreenQuicQueueCount;     // actual RX queue count used by optional multi-core path\n'
            '    uint16_t GreenQuicTxOwnerLcore;  // dedicated shared-ring TX consumer\n'
            '    BOOLEAN GreenQuicTxOwnerConfigured;\n',
            1)

        text = text.replace(
            '    Dpdk->GreenQuicQueueCount = 1;\n',
            '    Dpdk->GreenQuicQueueCount = 1;\n'
            '    Dpdk->GreenQuicTxOwnerLcore = UINT16_MAX;\n'
            '    Dpdk->GreenQuicTxOwnerConfigured = FALSE;\n',
            1)

        text = text.replace(
            '        } else if (strcmp(Line, "GreenQuicHintLocalityWindowUs") == 0) {\n',
            '        } else if (strcmp(Line, "GreenQuicTxOwnerLcore") == 0) {\n'
            '            Dpdk->GreenQuicTxOwnerLcore = (uint16_t)atoi(Value);\n'
            '            Dpdk->GreenQuicTxOwnerConfigured = TRUE;\n'
            '        } else if (strcmp(Line, "GreenQuicHintLocalityWindowUs") == 0) {\n',
            1)

    old_queue_setup = r'''            rx_rings = DesiredQueues;
            tx_rings = DesiredQueues;
            Dpdk->GreenQuicQueueCount = DesiredQueues;

            if (Dpdk->GreenQuicQueueCount > 1) {
                PortConfig.rxmode.mq_mode = RTE_ETH_MQ_RX_RSS;
                uint64_t RssHf = RTE_ETH_RSS_IP | RTE_ETH_RSS_UDP;
                if (DeviceInfo.flow_type_rss_offloads != 0) {
                    const uint64_t Supported = RssHf & DeviceInfo.flow_type_rss_offloads;
                    RssHf = Supported != 0 ? Supported : DeviceInfo.flow_type_rss_offloads;
                }
                PortConfig.rx_adv_conf.rss_conf.rss_hf = RssHf;
                printf("GreenQUIC multi-core enabled: lcores=%u rxq=%hu txq=%hu rss_hf=0x%" PRIx64 "\n",
                       EnabledLcores, rx_rings, tx_rings, RssHf);
            }
'''
    new_queue_setup = r'''            rx_rings = DesiredQueues;
            // GREENQUIC-OLD-V17: tx_rings = DesiredQueues;
            // Multiple consumers of one shared ring could reorder QUIC packets.
            tx_rings = 1;
            Dpdk->GreenQuicQueueCount = DesiredQueues;

            if (!Dpdk->GreenQuicTxOwnerConfigured ||
                !rte_lcore_is_enabled(Dpdk->GreenQuicTxOwnerLcore)) {
                Dpdk->GreenQuicTxOwnerLcore =
                    (uint16_t)rte_get_main_lcore();
                Dpdk->GreenQuicTxOwnerConfigured = FALSE;
            }

            if (Dpdk->GreenQuicQueueCount > 1) {
                PortConfig.rxmode.mq_mode = RTE_ETH_MQ_RX_RSS;
                uint64_t RssHf = RTE_ETH_RSS_IP | RTE_ETH_RSS_UDP;
                if (DeviceInfo.flow_type_rss_offloads != 0) {
                    const uint64_t Supported =
                        RssHf & DeviceInfo.flow_type_rss_offloads;
                    RssHf = Supported != 0 ?
                        Supported : DeviceInfo.flow_type_rss_offloads;
                }
                PortConfig.rx_adv_conf.rss_conf.rss_hf = RssHf;
                printf(
                    "GreenQUIC multi-core enabled: lcores=%u rxq=%hu "
                    "txq=1 tx_owner=%hu rss_hf=0x%" PRIx64 "\n",
                    EnabledLcores,
                    rx_rings,
                    Dpdk->GreenQuicTxOwnerLcore,
                    RssHf);
            }
'''
    if old_queue_setup not in text:
        raise RuntimeError('V18 could not find v17 multi-core queue setup')
    text = text.replace(old_queue_setup, new_queue_setup, 1)

    text = text.replace(
        '            Dpdk->GreenQuicEnableMultiCore ? 0 : '
        '(RING_F_MP_HTS_ENQ | RING_F_SC_DEQ));',
        '            /* GREENQUIC-OLD-V17 used MC dequeue in multi-core. */\n'
        '            RING_F_MP_HTS_ENQ | RING_F_SC_DEQ);',
        1)

    # Replace v17 multi-consumer TX body with one dedicated consumer on TX queue 0.
    old_tx_prefix = r'''    struct rte_mbuf* Buffers[TX_BURST_SIZE];
    const uint16_t QueueId = GreenQuicGetQueueId(Dpdk, Core);
    const uint32_t RingBefore = rte_ring_count(Interface->TxRingBuffer);
    const uint16_t BufferCount = Dpdk->GreenQuicEnableMultiCore ?
        (uint16_t)rte_ring_mc_dequeue_burst(
            Interface->TxRingBuffer, (void**)Buffers, TX_BURST_SIZE, NULL) :
        (uint16_t)rte_ring_sc_dequeue_burst(
            Interface->TxRingBuffer, (void**)Buffers, TX_BURST_SIZE, NULL);
'''
    new_tx_prefix = r'''    struct rte_mbuf* Buffers[TX_BURST_SIZE];
    // GREENQUIC-V18: one TX consumer protects ordering and TX power attribution.
    if (Dpdk->GreenQuicEnableMultiCore &&
        Core != Dpdk->GreenQuicTxOwnerLcore) {
        GreenQuicOnTxPoll(Dpdk, Core, 0, 0, 0);
        return;
    }

    const uint32_t RingBefore = rte_ring_count(Interface->TxRingBuffer);
#if 0
    /* GREENQUIC-OLD-V17: multiple lcores raced on one shared TX ring. */
    const uint16_t BufferCountV17 = Dpdk->GreenQuicEnableMultiCore ?
        (uint16_t)rte_ring_mc_dequeue_burst(
            Interface->TxRingBuffer, (void**)Buffers, TX_BURST_SIZE, NULL) :
        (uint16_t)rte_ring_sc_dequeue_burst(
            Interface->TxRingBuffer, (void**)Buffers, TX_BURST_SIZE, NULL);
#endif
    const uint16_t BufferCount =
        (uint16_t)rte_ring_sc_dequeue_burst(
            Interface->TxRingBuffer, (void**)Buffers, TX_BURST_SIZE, NULL);
'''
    if old_tx_prefix not in text:
        raise RuntimeError('V18 could not find v17 multi-consumer TX body')
    text = text.replace(old_tx_prefix, new_tx_prefix, 1)

    text = text.replace(
        'rte_eth_tx_burst(Interface->Port, QueueId, Buffers, BufferCount);',
        'rte_eth_tx_burst(Interface->Port, 0, Buffers, BufferCount);',
        1)

    # Non-owner RX lcores must not react to the owner-only shared TX backlog.
    text = text.replace(
        '    const uint32_t TxRingCount = rte_ring_count(Interface->TxRingBuffer);\n',
        '    const uint32_t TxRingCount =\n'
        '        (!Dpdk->GreenQuicEnableMultiCore ||\n'
        '         Core == Dpdk->GreenQuicTxOwnerLcore) ?\n'
        '            rte_ring_count(Interface->TxRingBuffer) : 0;\n',
        1)

    write_text(path, text)

    ini = repo / 'dpdk.greenquic.example.ini'
    if ini.exists():
        ini_text = read_text(ini)
        if 'GreenQuicTxOwnerLcore' not in ini_text:
            ini_text += r'''

# V18 QUIC-safe multi-core TX policy:
# Multiple RX queues use RSS, but one lcore consumes the shared TX ring.
# Default is the EAL main lcore. Override only with an enabled DPDK lcore.
# GreenQuicTxOwnerLcore=8
'''
            write_text(ini, ini_text)

    log('V18 multi-core RX/RSS plus dedicated TX-owner policy patched.')


# -----------------------------------------------------------------------------
# V18 DIRECTIONAL RX/TX DATAPATH CORRECTION
# -----------------------------------------------------------------------------

def patch_directional_pressure_policy(
    repo: Path,
    enable_multi_core: bool
    ) -> None:
    # Keep physical RX/TX load, QUIC-side RX/TX information, raw pressure, and
    # EWMA pressure independent until the final CPU action for each DPDK lcore.
    # Legacy final PressureAvg/LastRawPressure remain as compatibility mirrors.
    path = repo / 'src/platform/datapath_raw_dpdk.c'
    ensure_file(path)
    text = read_text(path)

    if 'GREENQUIC-V18-DIRECTIONAL-RXTX' in text:
        log('Directional RX/TX pressure policy is already present.')
        return

    old_state = r'''    uint32_t PressureAvg;
    uint32_t LastRawPressure;
    uint32_t LastRxPressure;
    uint32_t LastTxPressure;
    uint32_t LastPlusPressure;
    uint32_t LastTxRingCount;
    uint64_t LastHints;
    BOOLEAN LastHardMax;
'''
    new_state = r'''    // GREENQUIC-V18-DIRECTIONAL-RXTX: independent directional state.
    uint32_t PressureAvg;        // final action average = max(relevant RX/TX averages)
    uint32_t RxPressureAvg;
    uint32_t TxPressureAvg;
    uint32_t LastRawPressure;    // compatibility mirror = max(last RX/TX raw)
    uint32_t LastRxRawPressure;
    uint32_t LastTxRawPressure;
    uint32_t LastRxPressure;     // physical RX pressure
    uint32_t LastTxPressure;     // physical TX pressure; zero on non-owner
    uint32_t LastRxQuicPressure;
    uint32_t LastTxQuicPressure;
    uint32_t LastPlusPressure;   // compatibility mirror = max(RX/TX QUIC)
    uint32_t LastTxRingCount;
    uint64_t LastHints;          // compatibility mirror = RX hints | TX hints
    uint64_t LastRxHints;
    uint64_t LastTxHints;
    BOOLEAN LastHardMax;
    BOOLEAN LastRxHardMax;
    BOOLEAN LastTxHardMax;
'''
    if old_state not in text:
        raise RuntimeError('Directional policy could not find lcore state fields')
    text = text.replace(old_state, new_state, 1)

    old_sleep_proto = (
        'static uint32_t GreenQuicGetSleepBudgetUs(_In_ const DPDK_DATAPATH* Dpdk, '
        '_In_ const GREENQUIC_LCORE_STATE* S, _In_ uint32_t TxRingCount, '
        '_In_ uint64_t Hints);')
    new_sleep_proto = (
        'static uint32_t GreenQuicGetSleepBudgetUs(_In_ const DPDK_DATAPATH* Dpdk, '
        '_In_ const GREENQUIC_LCORE_STATE* S, _In_ uint32_t TxRingCount, '
        '_In_ uint64_t RxHints, _In_ uint64_t TxHints, _In_ BOOLEAN OwnsTx);')
    if old_sleep_proto not in text:
        raise RuntimeError('Directional policy could not find sleep prototype')
    text = text.replace(old_sleep_proto, new_sleep_proto, 1)

    old_plus_proto = (
        'static uint32_t GreenQuicPlusPressure(_In_ const DPDK_DATAPATH* Dpdk, '
        '_In_ uint64_t Hints, _In_ uint32_t RxPressure, _In_ uint32_t TxPressure, '
        '_Out_ BOOLEAN* HardMax);')
    new_plus_protos = (
        'static BOOLEAN GreenQuicLcoreOwnsTx(_In_ const DPDK_DATAPATH* Dpdk, _In_ uint16_t Core);\n'
        'static void GreenQuicGetDirectionalHintsForCore(_In_ const DPDK_DATAPATH* Dpdk, '
        '_In_ const GREENQUIC_LCORE_STATE* S, _In_ uint16_t Core, '
        '_Out_ uint64_t* RxHints, _Out_ uint64_t* TxHints);\n'
        'static void GreenQuicPlusDirectionalPressure(_In_ const DPDK_DATAPATH* Dpdk, '
        '_In_ uint64_t RxHints, _In_ uint64_t TxHints, '
        '_In_ uint32_t RxPressure, _In_ uint32_t TxPressure, _In_ BOOLEAN OwnsTx, '
        '_Out_ uint32_t* RxQuicPressure, _Out_ uint32_t* TxQuicPressure, '
        '_Out_ BOOLEAN* RxHardMax, _Out_ BOOLEAN* TxHardMax);')
    if old_plus_proto not in text:
        raise RuntimeError('Directional policy could not find PLUS prototype')
    text = text.replace(old_plus_proto, new_plus_protos, 1)

    compute_proto_pattern = re.compile(
        r'static uint32_t GreenQuicComputeRawPressure\(_In_ const DPDK_DATAPATH\* Dpdk, '
        r'_In_ GREENQUIC_LCORE_STATE\* S, (?:_In_ uint16_t Core, )?'
        r'_In_ uint32_t TxRingCount, _Out_ BOOLEAN\* HardMax\);')
    text, count = compute_proto_pattern.subn(
        'static uint32_t GreenQuicComputeRawPressure(_In_ const DPDK_DATAPATH* Dpdk, '
        '_In_ GREENQUIC_LCORE_STATE* S, _In_ uint16_t Core, '
        '_In_ uint32_t TxRingCount, _Out_ BOOLEAN* HardMax);', text, count=1)
    if count != 1:
        raise RuntimeError('Directional policy could not normalize compute prototype')

    helper_start = text.index('// GREENQUIC-BEGIN: helper implementations')
    sleep_start = text.index('static uint32_t\nGreenQuicGetSleepBudgetUs(', helper_start)
    sleep_end = text.index('\nstatic void\nGreenQuicOnRxPoll(', sleep_start)
    new_sleep = r'''static uint32_t
GreenQuicGetSleepBudgetUs(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ const GREENQUIC_LCORE_STATE* S,
    _In_ uint32_t TxRingCount,
    _In_ uint64_t RxHints,
    _In_ uint64_t TxHints,
    _In_ BOOLEAN OwnsTx
    )
{
    if (!Dpdk->GreenQuicEnableSleep || Dpdk->GreenQuicMaxSleepUs == 0) {
        return 0;
    }

    if ((OwnsTx && TxRingCount != 0) ||
        S->Rx.LastBurstCount != 0 ||
        (OwnsTx && S->Tx.LastBurstCount != 0) ||
        S->PressureAvg >= Dpdk->GreenQuicPressureKeepThreshold) {
        return 0;
    }

    if ((RxHints & GQPLUS_HINT_CUBIC_RECOVERY) != 0 ||
        (OwnsTx &&
         (TxHints &
          (GQPLUS_HINT_ACK_PENDING |
           GQPLUS_HINT_CUBIC_RECOVERY |
           GQPLUS_HINT_CUBIC_RAMPING)) != 0)) {
        return 0;
    }

    const uint32_t RxThreshold =
        Dpdk->GreenQuicRxEmptyPollThreshold == 0 ? 1 :
        Dpdk->GreenQuicRxEmptyPollThreshold;
    const uint32_t RxLevel = S->Rx.ConsecutiveEmpty / RxThreshold;

    uint32_t EmptyLevel = RxLevel;
    if (OwnsTx) {
        const uint32_t TxThreshold =
            Dpdk->GreenQuicTxEmptyPollThreshold == 0 ? 1 :
            Dpdk->GreenQuicTxEmptyPollThreshold;
        const uint32_t TxLevel = S->Tx.ConsecutiveEmpty / TxThreshold;
        EmptyLevel = GreenQuicMinU32(RxLevel, TxLevel);
    }

    const BOOLEAN ActiveRxTransfer =
        (RxHints & GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE) != 0 &&
        (Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_CLIENT_DOWNLOAD ||
         Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_SYMMETRIC);
    const BOOLEAN ActiveTxTransfer =
        OwnsTx &&
        (TxHints & GQPLUS_HINT_SERVER_FILE_TX_ACTIVE) != 0 &&
        (Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_SERVER_DOWNLOAD ||
         Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_SYMMETRIC);

    if ((ActiveRxTransfer || ActiveTxTransfer) && EmptyLevel < 4U) {
        return 0;
    }

    if (EmptyLevel >= 8U) {
        return Dpdk->GreenQuicMaxSleepUs;
    }
    if (EmptyLevel >= 4U) {
        return GreenQuicMinU32(
            Dpdk->GreenQuicDataPathMaxSleepUs,
            Dpdk->GreenQuicMaxSleepUs);
    }
    if (EmptyLevel >= 2U) {
        return GreenQuicMinU32(
            Dpdk->GreenQuicAckPathMaxSleepUs,
            Dpdk->GreenQuicMaxSleepUs);
    }
    return 0;
}
'''
    text = text[:sleep_start] + new_sleep + text[sleep_end:]

    plus_start = text.rfind('static uint32_t\nGreenQuicPlusPressure(')
    if plus_start < 0:
        raise RuntimeError('Directional policy could not find active PLUS function')
    plus_end = text.index('\nstatic void\nGreenQuicApplyPolicy(', plus_start)

    if enable_multi_core:
        owns_tx_body = (
            '    return !Dpdk->GreenQuicEnableMultiCore ||\n'
            '        Core == Dpdk->GreenQuicTxOwnerLcore;\n')
        directional_hints_body = (
            '    const uint64_t LocalHints = GreenQuicGetHintsForCore(Dpdk, S, Core);\n'
            '    *RxHints = LocalHints;\n'
            '    *TxHints = GreenQuicLcoreOwnsTx(Dpdk, Core) ?\n'
            '        (LocalHints | CxPlatGreenQuicPlusGetTxHints()) : 0;\n')
    else:
        owns_tx_body = (
            '    (void)Dpdk;\n'
            '    (void)Core;\n'
            '    return TRUE;\n')
        directional_hints_body = (
            '    (void)Dpdk;\n'
            '    (void)S;\n'
            '    (void)Core;\n'
            '    const uint64_t Hints = CxPlatGreenQuicPlusGetHints();\n'
            '    *RxHints = Hints;\n'
            '    *TxHints = Hints;\n')

    directional_block = r'''static BOOLEAN
GreenQuicLcoreOwnsTx(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ uint16_t Core
    )
{
''' + owns_tx_body + r'''}

static void
GreenQuicGetDirectionalHintsForCore(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ const GREENQUIC_LCORE_STATE* S,
    _In_ uint16_t Core,
    _Out_ uint64_t* RxHints,
    _Out_ uint64_t* TxHints
    )
{
''' + directional_hints_body + r'''}

static void
GreenQuicPlusDirectionalPressure(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ uint64_t RxHints,
    _In_ uint64_t TxHints,
    _In_ uint32_t RxPressure,
    _In_ uint32_t TxPressure,
    _In_ BOOLEAN OwnsTx,
    _Out_ uint32_t* RxQuicPressure,
    _Out_ uint32_t* TxQuicPressure,
    _Out_ BOOLEAN* RxHardMax,
    _Out_ BOOLEAN* TxHardMax
    )
{
    *RxQuicPressure = 0;
    *TxQuicPressure = 0;
    *RxHardMax = FALSE;
    *TxHardMax = FALSE;

    if (Dpdk->GreenQuicMode != GREENQUIC_MODE_PLUS) {
        return;
    }

    if (OwnsTx && (TxHints & GQPLUS_HINT_ACK_PENDING) != 0) {
        *TxQuicPressure = GreenQuicMaxU32(
            *TxQuicPressure,
            Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_CLIENT_DOWNLOAD ?
                600U : 550U);
    }

    if ((RxHints & GQPLUS_HINT_ACK_PENDING) != 0 &&
        Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_CLIENT_DOWNLOAD &&
        RxPressure >= Dpdk->GreenQuicPressureMaxThreshold) {
        *RxHardMax = TRUE;
    }

    if ((RxHints & GQPLUS_HINT_CUBIC_RECOVERY) != 0) {
        *RxQuicPressure = GreenQuicMaxU32(*RxQuicPressure, 750U);
        if (RxPressure >= Dpdk->GreenQuicPressureUpThreshold) {
            *RxHardMax = TRUE;
        }
    }
    if (OwnsTx && (TxHints & GQPLUS_HINT_CUBIC_RECOVERY) != 0) {
        *TxQuicPressure = GreenQuicMaxU32(*TxQuicPressure, 750U);
        if (TxPressure >= Dpdk->GreenQuicPressureUpThreshold) {
            *TxHardMax = TRUE;
        }
    }

    if (OwnsTx && (TxHints & GQPLUS_HINT_CUBIC_RAMPING) != 0) {
        *TxQuicPressure = GreenQuicMaxU32(*TxQuicPressure, 600U);
    }

    if ((RxHints & GQPLUS_HINT_CUBIC_CWND_BLOCKED) != 0) {
        const uint32_t BlockedRxPressure = (20U * 350U) / 100U;
        *RxQuicPressure = GreenQuicMaxU32(
            *RxQuicPressure,
            BlockedRxPressure);
    }

    if (OwnsTx &&
        (TxHints & GQPLUS_HINT_SERVER_FILE_TX_ACTIVE) != 0 &&
        (Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_SERVER_DOWNLOAD ||
         Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_SYMMETRIC)) {
        *TxQuicPressure = GreenQuicMaxU32(*TxQuicPressure, TxPressure);
    }

    if ((RxHints & GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE) != 0 &&
        (Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_CLIENT_DOWNLOAD ||
         Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_SYMMETRIC)) {
        *RxQuicPressure = GreenQuicMaxU32(*RxQuicPressure, RxPressure);
    }
}

static uint32_t
GreenQuicComputeRawPressure(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ GREENQUIC_LCORE_STATE* S,
    _In_ uint16_t Core,
    _In_ uint32_t TxRingCount,
    _Out_ BOOLEAN* HardMax
    )
{
    const BOOLEAN OwnsTx = GreenQuicLcoreOwnsTx(Dpdk, Core);

    const uint32_t RxBurstPressure = GreenQuicPressureFromRatio(
        S->Rx.LastBurstCount,
        RX_BURST_SIZE);
    const uint32_t RxQueuePressure = GreenQuicPressureFromRatio(
        S->Rx.LastQueueCount,
        Dpdk->GreenQuicRxQueueHigh);
    uint32_t RxPressure = GreenQuicMaxU32(RxBurstPressure, RxQueuePressure);

    uint32_t TxPressure = 0;
    if (OwnsTx) {
        const uint32_t TxBurstPressure = GreenQuicPressureFromRatio(
            S->Tx.LastBurstCount,
            TX_BURST_SIZE);
        TxPressure = GreenQuicPressureFromRatio(
            TxRingCount,
            Dpdk->GreenQuicTxRingHigh);
        TxPressure = GreenQuicMaxU32(
            TxPressure,
            GreenQuicPressureFromRatio(
                S->Tx.LastQueueCount,
                Dpdk->GreenQuicTxRingHigh));
        TxPressure = GreenQuicMaxU32(TxPressure, TxBurstPressure);
    }

    if (S->Rx.ConsecutiveFull >= Dpdk->GreenQuicFullBurstMaxCount) {
        RxPressure = GreenQuicMaxU32(
            RxPressure,
            Dpdk->GreenQuicPressureUpThreshold);
    }
    if (OwnsTx &&
        S->Tx.ConsecutiveFull >= Dpdk->GreenQuicFullBurstMaxCount) {
        TxPressure = GreenQuicMaxU32(
            TxPressure,
            Dpdk->GreenQuicPressureUpThreshold);
    }

    BOOLEAN RxHardMax =
        RxQueuePressure >= Dpdk->GreenQuicPressureMaxThreshold;
    BOOLEAN TxHardMax =
        OwnsTx && TxPressure >= Dpdk->GreenQuicPressureMaxThreshold;

    uint64_t RxHints = 0;
    uint64_t TxHints = 0;
    GreenQuicGetDirectionalHintsForCore(
        Dpdk, S, Core, &RxHints, &TxHints);

    uint32_t RxQuicPressure = 0;
    uint32_t TxQuicPressure = 0;
    BOOLEAN RxQuicHardMax = FALSE;
    BOOLEAN TxQuicHardMax = FALSE;
    GreenQuicPlusDirectionalPressure(
        Dpdk,
        RxHints,
        TxHints,
        RxPressure,
        TxPressure,
        OwnsTx,
        &RxQuicPressure,
        &TxQuicPressure,
        &RxQuicHardMax,
        &TxQuicHardMax);

    RxHardMax = RxHardMax || RxQuicHardMax;
    TxHardMax = TxHardMax || TxQuicHardMax;

    const uint32_t RxRawPressure = GreenQuicMaxU32(
        RxPressure,
        RxQuicPressure);
    const uint32_t TxRawPressure = OwnsTx ?
        GreenQuicMaxU32(TxPressure, TxQuicPressure) : 0;
    const uint32_t RawPressure = GreenQuicMaxU32(
        RxRawPressure,
        TxRawPressure);

    S->LastRxPressure = RxPressure;
    S->LastTxPressure = TxPressure;
    S->LastRxQuicPressure = RxQuicPressure;
    S->LastTxQuicPressure = TxQuicPressure;
    S->LastPlusPressure = GreenQuicMaxU32(
        RxQuicPressure,
        TxQuicPressure);
    S->LastRxRawPressure = RxRawPressure;
    S->LastTxRawPressure = TxRawPressure;
    S->LastRawPressure = RawPressure;
    S->LastTxRingCount = TxRingCount;
    S->LastRxHints = RxHints;
    S->LastTxHints = TxHints;
    S->LastHints = RxHints | TxHints;
    S->LastRxHardMax = RxHardMax;
    S->LastTxHardMax = TxHardMax;
    S->LastHardMax = RxHardMax || TxHardMax;

    *HardMax = S->LastHardMax;
    return GreenQuicMinU32(RawPressure, GREENQUIC_PRESSURE_SCALE);
}
'''
    text = text[:plus_start] + directional_block + text[plus_end:]

    apply_start = text.index('static void\nGreenQuicApplyPolicy(', plus_start)
    apply_end = text.index('\nstatic void\nGreenQuicMaybePrintStats(', apply_start)
    new_apply = r'''static void
GreenQuicApplyPolicy(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_ DPDK_INTERFACE* Interface,
    _In_ uint16_t Core
    )
{
    if (Dpdk->GreenQuicMode == GREENQUIC_MODE_OFF) {
        return;
    }

    GreenQuicMaybePrintStats(Dpdk, Core);

    const BOOLEAN OwnsTx = GreenQuicLcoreOwnsTx(Dpdk, Core);
    const uint32_t TxRingCount = OwnsTx ?
        rte_ring_count(Interface->TxRingBuffer) : 0;
    GREENQUIC_LCORE_STATE* S = GreenQuicGetLcoreState(Dpdk, Core);

    BOOLEAN HardMax = FALSE;
    const uint32_t RawPressure = GreenQuicComputeRawPressure(
        Dpdk, S, Core, TxRingCount, &HardMax);
    S->LastRawPressure = RawPressure;

    S->RxPressureAvg = GreenQuicUpdateEwma(
        S->RxPressureAvg,
        S->LastRxRawPressure,
        Dpdk->GreenQuicEwmaRiseShift,
        Dpdk->GreenQuicEwmaFallShift);

    if (OwnsTx) {
        S->TxPressureAvg = GreenQuicUpdateEwma(
            S->TxPressureAvg,
            S->LastTxRawPressure,
            Dpdk->GreenQuicEwmaRiseShift,
            Dpdk->GreenQuicEwmaFallShift);
    } else {
        S->TxPressureAvg = 0;
    }

    S->PressureAvg = GreenQuicMaxU32(
        S->RxPressureAvg,
        S->TxPressureAvg);

    if (HardMax) {
        S->LastAction = "freq_max_hard";
        GreenQuicFreqMax(Dpdk, Core);
        return;
    }
    if (S->PressureAvg >= Dpdk->GreenQuicPressureMaxThreshold) {
        S->LastAction = "freq_max_avg";
        GreenQuicFreqMax(Dpdk, Core);
        return;
    }
    if (S->PressureAvg >= Dpdk->GreenQuicPressureUpThreshold) {
        S->LastAction = "freq_up";
        GreenQuicFreqUpStep(Dpdk, Core);
        return;
    }
    if (S->PressureAvg >= Dpdk->GreenQuicPressureKeepThreshold) {
        S->LastAction = "keep_pause";
        rte_pause();
        return;
    }

    const BOOLEAN RxEmptyEnough =
        S->Rx.ConsecutiveEmpty >= Dpdk->GreenQuicRxEmptyPollThreshold;
    const BOOLEAN TxEmptyEnough =
        !OwnsTx ||
        S->Tx.ConsecutiveEmpty >= Dpdk->GreenQuicTxEmptyPollThreshold;
    if (!RxEmptyEnough || !TxEmptyEnough) {
        S->LastAction = "short_idle_pause";
        rte_pause();
        return;
    }

    if (OwnsTx &&
        Dpdk->GreenQuicNoSleepIfTxRingNotEmpty &&
        TxRingCount > 0) {
        S->LastAction = "txring_protect_up";
        GreenQuicFreqUpStep(Dpdk, Core);
        return;
    }

    uint64_t LastActive = S->Rx.LastActiveTsc;
    if (OwnsTx && S->Tx.LastActiveTsc > LastActive) {
        LastActive = S->Tx.LastActiveTsc;
    }
    const uint64_t Now = rte_get_tsc_cycles();
    const uint64_t IdleUs = LastActive == 0 ?
        UINT64_MAX : GreenQuicTscDeltaToUs(Now - LastActive);

    if (IdleUs >= Dpdk->GreenQuicFreqMinIdleUs) {
        S->LastAction = "freq_min";
        GreenQuicFreqMin(Dpdk, Core);
    } else {
        S->LastAction = "freq_down";
        GreenQuicFreqDownStep(Dpdk, Core);
    }

    const uint32_t SleepBudgetUs = GreenQuicGetSleepBudgetUs(
        Dpdk,
        S,
        TxRingCount,
        S->LastRxHints,
        S->LastTxHints,
        OwnsTx);
    if (SleepBudgetUs != 0) {
        S->LastAction = "sleep";
        GreenQuicSleepUs(Dpdk, Core, SleepBudgetUs);
    }
}
'''
    text = text[:apply_start] + new_apply + text[apply_end:]

    stats_start = text.index('static void\nGreenQuicMaybePrintStats(', apply_start)
    stats_end = text.index('\n// GREENQUIC-END', stats_start)
    new_stats = r'''static void
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
    printf(
        "GreenQUIC lcore=%u mode=%s profile=%s action=%s power=%u "
        "hardmax=%u rxhard=%u txhard=%u raw=%u avg=%u "
        "rxraw=%u txraw=%u rxavg=%u txavg=%u "
        "rxp=%u txp=%u rxqp=%u txqp=%u plusp=%u "
        "rxh=0x%" PRIx64 " txh=0x%" PRIx64 " txring=%u rxq=%u "
        "rx_pkts=%" PRIu64 " tx_pkts=%" PRIu64 " "
        "rx_empty=%u tx_empty=%u rx_full=%u tx_full=%u "
        "slept_us=%" PRIu64 "\n",
        Core,
        GreenQuicModeToString(Dpdk->GreenQuicMode),
        GreenQuicProfileToString(Dpdk->GreenQuicProfile),
        S->LastAction != NULL ? S->LastAction : "none",
        S->PowerAvailable ? 1U : 0U,
        S->LastHardMax ? 1U : 0U,
        S->LastRxHardMax ? 1U : 0U,
        S->LastTxHardMax ? 1U : 0U,
        S->LastRawPressure,
        S->PressureAvg,
        S->LastRxRawPressure,
        S->LastTxRawPressure,
        S->RxPressureAvg,
        S->TxPressureAvg,
        S->LastRxPressure,
        S->LastTxPressure,
        S->LastRxQuicPressure,
        S->LastTxQuicPressure,
        S->LastPlusPressure,
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
        S->TotalSleepUs);
}
'''
    text = text[:stats_start] + new_stats + text[stats_end:]

    write_text(path, text)
    log(
        'V18 directional RX/TX policy patched: separate physical pressure, '
        'QUIC pressure, raw pressure and EWMA per direction.')

# -----------------------------------------------------------------------------
# V18 FINAL ROLE-COMPLETE RX/TX OVERRIDE
# -----------------------------------------------------------------------------

def patch_role_complete_directional_policy(
    repo: Path,
    enable_multi_core: bool
    ) -> None:
    """Final V18 correction for explicit RX-only, TX-only and RX+TX lcores.

    This runs after patch_directional_pressure_policy. It keeps the complete
    existing code and replaces only the generated active C policy blocks.
    RX and TX physical pressure, QUIC pressure, raw pressure, EWMA, empty state,
    and sleep gating stay independent until the one final CPU action.
    """
    path = repo / 'src/platform/datapath_raw_dpdk.c'
    ensure_file(path)
    text = read_text(path)

    if 'GREENQUIC-V18-ROLE-COMPLETE' in text:
        log('Role-complete directional policy is already present.')
        return

    # Generic direction switches are available in both patch modes. Defaults
    # preserve the normal one-lcore RX+TX behavior.
    field_anchor = '    BOOLEAN GreenQuicEnableFreq;\n'
    if field_anchor not in text:
        raise RuntimeError('Role-complete patch could not find frequency field')
    text = text.replace(
        field_anchor,
        '    // GREENQUIC-V18-ROLE-COMPLETE: explicit direction ownership.\n'
        '    BOOLEAN GreenQuicEnableRx;\n'
        '    BOOLEAN GreenQuicEnableTx;\n' + field_anchor,
        1)

    default_anchor = '    Dpdk->GreenQuicEnableFreq = DEFAULT_GREENQUIC_ENABLE_FREQ;\n'
    if default_anchor not in text:
        raise RuntimeError('Role-complete patch could not find frequency default')
    text = text.replace(
        default_anchor,
        '    Dpdk->GreenQuicEnableRx = TRUE;\n'
        '    Dpdk->GreenQuicEnableTx = TRUE;\n' + default_anchor,
        1)

    parser_anchor = '        } else if (strcmp(Line, "GreenQuicEnableFreq") == 0) {\n'
    if parser_anchor not in text:
        raise RuntimeError('Role-complete patch could not find parser anchor')
    text = text.replace(
        parser_anchor,
        '        } else if (strcmp(Line, "GreenQuicEnableRx") == 0) {\n'
        '            Dpdk->GreenQuicEnableRx = atoi(Value) != 0 ? TRUE : FALSE;\n'
        '        } else if (strcmp(Line, "GreenQuicEnableTx") == 0) {\n'
        '            Dpdk->GreenQuicEnableTx = atoi(Value) != 0 ? TRUE : FALSE;\n' + parser_anchor,
        1)

    if enable_multi_core:
        role_field_anchor = (
            '    uint16_t GreenQuicTxOwnerLcore;  // dedicated shared-ring TX consumer\n'
            '    BOOLEAN GreenQuicTxOwnerConfigured;\n')
        if role_field_anchor not in text:
            raise RuntimeError('Role-complete patch could not find TX-owner fields')
        text = text.replace(
            role_field_anchor,
            role_field_anchor +
            '    BOOLEAN GreenQuicTxOwnerAlsoRx; // 0 makes TX owner TX-only\n'
            '    uint16_t GreenQuicRxQueueByLcore[RTE_MAX_LCORE];\n'
            '    uint16_t GreenQuicRxOwnerCount;\n',
            1)

        role_default_anchor = (
            '    Dpdk->GreenQuicTxOwnerLcore = UINT16_MAX;\n'
            '    Dpdk->GreenQuicTxOwnerConfigured = FALSE;\n')
        if role_default_anchor not in text:
            raise RuntimeError('Role-complete patch could not find TX-owner defaults')
        text = text.replace(
            role_default_anchor,
            role_default_anchor +
            '    Dpdk->GreenQuicTxOwnerAlsoRx = TRUE;\n'
            '    Dpdk->GreenQuicRxOwnerCount = 0;\n'
            '    for (uint32_t RoleIndex = 0; RoleIndex < RTE_MAX_LCORE; ++RoleIndex) {\n'
            '        Dpdk->GreenQuicRxQueueByLcore[RoleIndex] = UINT16_MAX;\n'
            '    }\n',
            1)

        role_parser_anchor = (
            '        } else if (strcmp(Line, "GreenQuicTxOwnerLcore") == 0) {\n'
            '            Dpdk->GreenQuicTxOwnerLcore = (uint16_t)atoi(Value);\n'
            '            Dpdk->GreenQuicTxOwnerConfigured = TRUE;\n')
        if role_parser_anchor not in text:
            raise RuntimeError('Role-complete patch could not find TX-owner parser')
        text = text.replace(
            role_parser_anchor,
            role_parser_anchor +
            '        } else if (strcmp(Line, "GreenQuicTxOwnerAlsoRx") == 0) {\n'
            '            Dpdk->GreenQuicTxOwnerAlsoRx = atoi(Value) != 0 ? TRUE : FALSE;\n',
            1)

        queue_start = text.index('static uint16_t\nGreenQuicGetQueueId(')
        queue_end = text.index('\nstatic BOOLEAN\nGreenQuicHasLocalRecentActivity(', queue_start)
        queue_helper = r'''static uint16_t
GreenQuicGetQueueId(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ uint16_t Core
    )
{
    if (Core < RTE_MAX_LCORE &&
        Dpdk->GreenQuicRxQueueByLcore[Core] != UINT16_MAX) {
        return Dpdk->GreenQuicRxQueueByLcore[Core];
    }
    return 0;
}
'''
        text = text[:queue_start] + queue_helper + text[queue_end:]

        setup_start = text.index(
            '    // GREENQUIC-BEGIN: optional multi-core queue/RSS setup\n')
        setup_end_marker = (
            '    // GREENQUIC-END\n'
            '    GreenQuicInstallDefaultPartitionDpdkMap(Dpdk);')
        setup_end = text.index(setup_end_marker, setup_start) + len('    // GREENQUIC-END\n')
        role_setup = r'''    // GREENQUIC-BEGIN: optional multi-core queue/RSS setup
    // GREENQUIC-V18-ROLE-COMPLETE: resolve ownership before workers start.
    for (uint32_t RoleIndex = 0; RoleIndex < RTE_MAX_LCORE; ++RoleIndex) {
        Dpdk->GreenQuicRxQueueByLcore[RoleIndex] = UINT16_MAX;
    }
    Dpdk->GreenQuicRxOwnerCount = 0;

    if (Dpdk->GreenQuicEnableTx) {
        if (!Dpdk->GreenQuicTxOwnerConfigured ||
            !rte_lcore_is_enabled(Dpdk->GreenQuicTxOwnerLcore)) {
            Dpdk->GreenQuicTxOwnerLcore =
                (uint16_t)rte_get_main_lcore();
            Dpdk->GreenQuicTxOwnerConfigured = FALSE;
        }
    } else {
        Dpdk->GreenQuicTxOwnerLcore = UINT16_MAX;
    }

    if (Dpdk->GreenQuicEnableMultiCore) {
        const unsigned int EnabledLcores = rte_lcore_count();
        const uint16_t MaxRxQueues = DeviceInfo.max_rx_queues == 0 ?
            1 : DeviceInfo.max_rx_queues;
        uint16_t NextRxQueue = 0;
        unsigned int RoleLcore;

        RTE_LCORE_FOREACH(RoleLcore) {
            const BOOLEAN RequestedRx =
                Dpdk->GreenQuicEnableRx &&
                (!Dpdk->GreenQuicEnableTx ||
                 RoleLcore != Dpdk->GreenQuicTxOwnerLcore ||
                 Dpdk->GreenQuicTxOwnerAlsoRx);

            if (RequestedRx && NextRxQueue < MaxRxQueues &&
                RoleLcore < RTE_MAX_LCORE) {
                Dpdk->GreenQuicRxQueueByLcore[RoleLcore] = NextRxQueue++;
            } else if (RequestedRx && NextRxQueue >= MaxRxQueues) {
                printf(
                    "GreenQUIC: lcore %u requested RX but the NIC supports "
                    "only %hu RX queues; this lcore receives no RX role.\n",
                    RoleLcore,
                    MaxRxQueues);
            }
        }

        Dpdk->GreenQuicRxOwnerCount = NextRxQueue;
        Dpdk->GreenQuicQueueCount = NextRxQueue;
        // Keep one configured but unpolled RX queue if RX is disabled. Some
        // PMDs reject a zero-RX-queue configuration.
        rx_rings = NextRxQueue == 0 ? 1 : NextRxQueue;
        tx_rings = 1;

        if (NextRxQueue > 1) {
            PortConfig.rxmode.mq_mode = RTE_ETH_MQ_RX_RSS;
            uint64_t RssHf = RTE_ETH_RSS_IP | RTE_ETH_RSS_UDP;
            if (DeviceInfo.flow_type_rss_offloads != 0) {
                const uint64_t Supported =
                    RssHf & DeviceInfo.flow_type_rss_offloads;
                RssHf = Supported != 0 ?
                    Supported : DeviceInfo.flow_type_rss_offloads;
            }
            PortConfig.rx_adv_conf.rss_conf.rss_hf = RssHf;
        }

        printf(
            "GreenQUIC roles: lcores=%u rx_owners=%hu rxq=%hu "
            "tx_enabled=%u txq=1 tx_owner=%hu tx_owner_also_rx=%u\n",
            EnabledLcores,
            Dpdk->GreenQuicRxOwnerCount,
            rx_rings,
            Dpdk->GreenQuicEnableTx ? 1U : 0U,
            Dpdk->GreenQuicTxOwnerLcore,
            Dpdk->GreenQuicTxOwnerAlsoRx ? 1U : 0U);
    } else {
        const uint16_t MainLcore = (uint16_t)rte_get_main_lcore();
        Dpdk->GreenQuicQueueCount = Dpdk->GreenQuicEnableRx ? 1 : 0;
        Dpdk->GreenQuicRxOwnerCount = Dpdk->GreenQuicEnableRx ? 1 : 0;
        if (Dpdk->GreenQuicEnableRx && MainLcore < RTE_MAX_LCORE) {
            Dpdk->GreenQuicRxQueueByLcore[MainLcore] = 0;
        }
        rx_rings = 1;
        tx_rings = 1;
    }
    // GREENQUIC-END
'''
        text = text[:setup_start] + role_setup + text[setup_end:]

        old_default_map = r'''    uint16_t Lcores[256];
    uint32_t LcoreCount = 0;
    unsigned int Lcore;
    RTE_LCORE_FOREACH(Lcore) {
        if (LcoreCount < ARRAYSIZE(Lcores) && Lcore <= UINT16_MAX) {
            Lcores[LcoreCount++] = (uint16_t)Lcore;
        }
    }
'''
        new_default_map = r'''    uint16_t Lcores[256];
    uint32_t LcoreCount = 0;
    unsigned int Lcore;
    RTE_LCORE_FOREACH(Lcore) {
        if (LcoreCount < ARRAYSIZE(Lcores) &&
            Lcore <= UINT16_MAX &&
            GreenQuicLcoreOwnsRx(Dpdk, (uint16_t)Lcore)) {
            Lcores[LcoreCount++] = (uint16_t)Lcore;
        }
    }
'''
        if old_default_map not in text:
            raise RuntimeError('Role-complete patch could not find default partition map')
        text = text.replace(old_default_map, new_default_map, 1)

    # Add OwnsRx to prototypes and upgrade existing role-aware prototypes.
    owns_tx_proto = (
        'static BOOLEAN GreenQuicLcoreOwnsTx(_In_ const DPDK_DATAPATH* Dpdk, '
        '_In_ uint16_t Core);')
    if owns_tx_proto not in text:
        raise RuntimeError('Role-complete patch could not find OwnsTx prototype')
    text = text.replace(
        owns_tx_proto,
        'static BOOLEAN GreenQuicLcoreOwnsRx(_In_ const DPDK_DATAPATH* Dpdk, '
        '_In_ uint16_t Core);\n' + owns_tx_proto,
        1)

    old_sleep_proto = (
        'static uint32_t GreenQuicGetSleepBudgetUs(_In_ const DPDK_DATAPATH* Dpdk, '
        '_In_ const GREENQUIC_LCORE_STATE* S, _In_ uint32_t TxRingCount, '
        '_In_ uint64_t RxHints, _In_ uint64_t TxHints, _In_ BOOLEAN OwnsTx);')
    new_sleep_proto = (
        'static uint32_t GreenQuicGetSleepBudgetUs(_In_ const DPDK_DATAPATH* Dpdk, '
        '_In_ const GREENQUIC_LCORE_STATE* S, _In_ uint32_t TxRingCount, '
        '_In_ uint64_t RxHints, _In_ uint64_t TxHints, '
        '_In_ BOOLEAN OwnsRx, _In_ BOOLEAN OwnsTx);')
    if old_sleep_proto not in text:
        raise RuntimeError('Role-complete patch could not find directional sleep prototype')
    text = text.replace(old_sleep_proto, new_sleep_proto, 1)

    old_plus_proto = (
        'static void GreenQuicPlusDirectionalPressure(_In_ const DPDK_DATAPATH* Dpdk, '
        '_In_ uint64_t RxHints, _In_ uint64_t TxHints, '
        '_In_ uint32_t RxPressure, _In_ uint32_t TxPressure, _In_ BOOLEAN OwnsTx, '
        '_Out_ uint32_t* RxQuicPressure, _Out_ uint32_t* TxQuicPressure, '
        '_Out_ BOOLEAN* RxHardMax, _Out_ BOOLEAN* TxHardMax);')
    new_plus_proto = (
        'static void GreenQuicPlusDirectionalPressure(_In_ const DPDK_DATAPATH* Dpdk, '
        '_In_ uint64_t RxHints, _In_ uint64_t TxHints, '
        '_In_ uint32_t RxPressure, _In_ uint32_t TxPressure, '
        '_In_ BOOLEAN OwnsRx, _In_ BOOLEAN OwnsTx, '
        '_Out_ uint32_t* RxQuicPressure, _Out_ uint32_t* TxQuicPressure, '
        '_Out_ BOOLEAN* RxHardMax, _Out_ BOOLEAN* TxHardMax);')
    if old_plus_proto not in text:
        raise RuntimeError('Role-complete patch could not find directional PLUS prototype')
    text = text.replace(old_plus_proto, new_plus_proto, 1)

    # Lcore state records roles for exact logs.
    state_anchor = '    BOOLEAN LastTxHardMax;\n'
    if state_anchor not in text:
        raise RuntimeError('Role-complete patch could not find directional state anchor')
    text = text.replace(
        state_anchor,
        state_anchor +
        '    BOOLEAN LastOwnsRx;\n'
        '    BOOLEAN LastOwnsTx;\n',
        1)

    helper_impl_start = text.index('// GREENQUIC-BEGIN: helper implementations')
    sleep_start = text.index('static uint32_t\nGreenQuicGetSleepBudgetUs(', helper_impl_start)
    sleep_end = text.index('\nstatic void\nGreenQuicOnRxPoll(', sleep_start)
    sleep_code = r'''static uint32_t
GreenQuicGetSleepBudgetUs(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ const GREENQUIC_LCORE_STATE* S,
    _In_ uint32_t TxRingCount,
    _In_ uint64_t RxHints,
    _In_ uint64_t TxHints,
    _In_ BOOLEAN OwnsRx,
    _In_ BOOLEAN OwnsTx
    )
{
    if (!Dpdk->GreenQuicEnableSleep || Dpdk->GreenQuicMaxSleepUs == 0) {
        return 0;
    }

    if ((OwnsTx && TxRingCount != 0) ||
        (OwnsRx && S->Rx.LastBurstCount != 0) ||
        (OwnsTx && S->Tx.LastBurstCount != 0) ||
        S->PressureAvg >= Dpdk->GreenQuicPressureKeepThreshold) {
        return 0;
    }

    if ((OwnsRx &&
         (RxHints & GQPLUS_HINT_CUBIC_RECOVERY) != 0) ||
        (OwnsTx &&
         (TxHints &
          (GQPLUS_HINT_ACK_PENDING |
           GQPLUS_HINT_CUBIC_RECOVERY |
           GQPLUS_HINT_CUBIC_RAMPING)) != 0)) {
        return 0;
    }

    uint32_t EmptyLevel = 8U;
    if (OwnsRx) {
        const uint32_t RxThreshold =
            Dpdk->GreenQuicRxEmptyPollThreshold == 0 ? 1 :
            Dpdk->GreenQuicRxEmptyPollThreshold;
        EmptyLevel = S->Rx.ConsecutiveEmpty / RxThreshold;
    }
    if (OwnsTx) {
        const uint32_t TxThreshold =
            Dpdk->GreenQuicTxEmptyPollThreshold == 0 ? 1 :
            Dpdk->GreenQuicTxEmptyPollThreshold;
        const uint32_t TxLevel = S->Tx.ConsecutiveEmpty / TxThreshold;
        EmptyLevel = OwnsRx ? GreenQuicMinU32(EmptyLevel, TxLevel) : TxLevel;
    }

    const BOOLEAN ActiveRxTransfer =
        OwnsRx &&
        (RxHints & GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE) != 0 &&
        (Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_CLIENT_DOWNLOAD ||
         Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_SYMMETRIC);
    const BOOLEAN ActiveTxTransfer =
        OwnsTx &&
        (TxHints & GQPLUS_HINT_SERVER_FILE_TX_ACTIVE) != 0 &&
        (Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_SERVER_DOWNLOAD ||
         Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_SYMMETRIC);

    if ((ActiveRxTransfer || ActiveTxTransfer) && EmptyLevel < 4U) {
        return 0;
    }

    if (EmptyLevel >= 8U) {
        return Dpdk->GreenQuicMaxSleepUs;
    }
    if (EmptyLevel >= 4U) {
        return GreenQuicMinU32(
            Dpdk->GreenQuicDataPathMaxSleepUs,
            Dpdk->GreenQuicMaxSleepUs);
    }
    if (EmptyLevel >= 2U) {
        return GreenQuicMinU32(
            Dpdk->GreenQuicAckPathMaxSleepUs,
            Dpdk->GreenQuicMaxSleepUs);
    }
    return 0;
}
'''
    text = text[:sleep_start] + sleep_code + text[sleep_end:]

    role_start = text.index('static BOOLEAN\nGreenQuicLcoreOwnsTx(')
    hint_start = text.index('\nstatic void\nGreenQuicGetDirectionalHintsForCore(', role_start)

    if enable_multi_core:
        role_code = r'''static BOOLEAN
GreenQuicLcoreOwnsRx(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ uint16_t Core
    )
{
    return Dpdk->GreenQuicEnableRx &&
        Core < RTE_MAX_LCORE &&
        Dpdk->GreenQuicRxQueueByLcore[Core] != UINT16_MAX;
}

static BOOLEAN
GreenQuicLcoreOwnsTx(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ uint16_t Core
    )
{
    return Dpdk->GreenQuicEnableTx &&
        Core == Dpdk->GreenQuicTxOwnerLcore;
}
'''
    else:
        role_code = r'''static BOOLEAN
GreenQuicLcoreOwnsRx(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ uint16_t Core
    )
{
    (void)Core;
    return Dpdk->GreenQuicEnableRx;
}

static BOOLEAN
GreenQuicLcoreOwnsTx(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ uint16_t Core
    )
{
    (void)Core;
    return Dpdk->GreenQuicEnableTx;
}
'''
    text = text[:role_start] + role_code + text[hint_start:]

    hints_start = text.index('static void\nGreenQuicGetDirectionalHintsForCore(')
    plus_start = text.index('\nstatic void\nGreenQuicPlusDirectionalPressure(', hints_start)
    if enable_multi_core:
        hints_code = r'''static void
GreenQuicGetDirectionalHintsForCore(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ const GREENQUIC_LCORE_STATE* S,
    _In_ uint16_t Core,
    _Out_ uint64_t* RxHints,
    _Out_ uint64_t* TxHints
    )
{
    /*
     * BASIC is strictly physical-only. QUIC/application hints must not affect
     * either DVFS or any idle/sleep gate unless PLUS mode is selected.
     */
    if (Dpdk->GreenQuicMode != GREENQUIC_MODE_PLUS) {
        *RxHints = 0;
        *TxHints = 0;
        return;
    }

    const BOOLEAN OwnsRx = GreenQuicLcoreOwnsRx(Dpdk, Core);
    const BOOLEAN OwnsTx = GreenQuicLcoreOwnsTx(Dpdk, Core);
    const uint64_t LocalHints = GreenQuicGetHintsForCore(Dpdk, S, Core);
    *RxHints = OwnsRx ? LocalHints : 0;
    *TxHints = OwnsTx ?
        (LocalHints | CxPlatGreenQuicPlusGetTxHints()) : 0;
}
'''
    else:
        hints_code = r'''static void
GreenQuicGetDirectionalHintsForCore(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ const GREENQUIC_LCORE_STATE* S,
    _In_ uint16_t Core,
    _Out_ uint64_t* RxHints,
    _Out_ uint64_t* TxHints
    )
{
    (void)S;
    /* Keep BASIC completely physical-only for both DVFS and idle decisions. */
    if (Dpdk->GreenQuicMode != GREENQUIC_MODE_PLUS) {
        *RxHints = 0;
        *TxHints = 0;
        return;
    }

    const uint64_t Hints = CxPlatGreenQuicPlusGetHints();
    *RxHints = GreenQuicLcoreOwnsRx(Dpdk, Core) ? Hints : 0;
    *TxHints = GreenQuicLcoreOwnsTx(Dpdk, Core) ? Hints : 0;
}
'''
    text = text[:hints_start] + hints_code + text[plus_start:]

    plus_start = text.index('static void\nGreenQuicPlusDirectionalPressure(')
    compute_start = text.index('\nstatic uint32_t\nGreenQuicComputeRawPressure(', plus_start)
    plus_code = r'''static void
GreenQuicPlusDirectionalPressure(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ uint64_t RxHints,
    _In_ uint64_t TxHints,
    _In_ uint32_t RxPressure,
    _In_ uint32_t TxPressure,
    _In_ BOOLEAN OwnsRx,
    _In_ BOOLEAN OwnsTx,
    _Out_ uint32_t* RxQuicPressure,
    _Out_ uint32_t* TxQuicPressure,
    _Out_ BOOLEAN* RxHardMax,
    _Out_ BOOLEAN* TxHardMax
    )
{
    *RxQuicPressure = 0;
    *TxQuicPressure = 0;
    *RxHardMax = FALSE;
    *TxHardMax = FALSE;

    if (Dpdk->GreenQuicMode != GREENQUIC_MODE_PLUS) {
        return;
    }

    // ACK generation is TX-side work.
    if (OwnsTx && (TxHints & GQPLUS_HINT_ACK_PENDING) != 0) {
        *TxQuicPressure = GreenQuicMaxU32(
            *TxQuicPressure,
            Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_CLIENT_DOWNLOAD ?
                600U : 550U);
        if (OwnsRx &&
            RxPressure >= Dpdk->GreenQuicPressureMaxThreshold) {
            *RxHardMax = TRUE;
        }
    }

    // Recovery remains separate: local RX recovery protects RX; the TX-owner
    // aggregate protects retransmission creation/transmission on TX.
    if (OwnsRx && (RxHints & GQPLUS_HINT_CUBIC_RECOVERY) != 0) {
        *RxQuicPressure = GreenQuicMaxU32(*RxQuicPressure, 750U);
        if (RxPressure >= Dpdk->GreenQuicPressureUpThreshold) {
            *RxHardMax = TRUE;
        }
    }
    if (OwnsTx && (TxHints & GQPLUS_HINT_CUBIC_RECOVERY) != 0) {
        *TxQuicPressure = GreenQuicMaxU32(*TxQuicPressure, 750U);
        if (TxPressure >= Dpdk->GreenQuicPressureUpThreshold) {
            *TxHardMax = TRUE;
        }
    }

    // Congestion-window growth authorizes additional outgoing packets: TX.
    if (OwnsTx && (TxHints & GQPLUS_HINT_CUBIC_RAMPING) != 0) {
        *TxQuicPressure = GreenQuicMaxU32(*TxQuicPressure, 600U);
    }

    // Zero send allowance means waiting for incoming ACKs: RX readiness.
    if (OwnsRx && (RxHints & GQPLUS_HINT_CUBIC_CWND_BLOCKED) != 0) {
        const uint32_t BlockedRxPressure = (20U * 350U) / 100U;
        *RxQuicPressure = GreenQuicMaxU32(
            *RxQuicPressure,
            BlockedRxPressure);
    }

    if (OwnsTx &&
        (TxHints & GQPLUS_HINT_SERVER_FILE_TX_ACTIVE) != 0 &&
        (Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_SERVER_DOWNLOAD ||
         Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_SYMMETRIC)) {
        *TxQuicPressure = GreenQuicMaxU32(*TxQuicPressure, TxPressure);
    }

    if (OwnsRx &&
        (RxHints & GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE) != 0 &&
        (Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_CLIENT_DOWNLOAD ||
         Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_SYMMETRIC)) {
        *RxQuicPressure = GreenQuicMaxU32(*RxQuicPressure, RxPressure);
    }
}
'''
    text = text[:plus_start] + plus_code + text[compute_start:]

    compute_start = text.index('static uint32_t\nGreenQuicComputeRawPressure(')
    apply_start = text.index('\nstatic void\nGreenQuicApplyPolicy(', compute_start)
    compute_code = r'''static uint32_t
GreenQuicComputeRawPressure(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ GREENQUIC_LCORE_STATE* S,
    _In_ uint16_t Core,
    _In_ uint32_t TxRingCount,
    _Out_ BOOLEAN* HardMax
    )
{
    const BOOLEAN OwnsRx = GreenQuicLcoreOwnsRx(Dpdk, Core);
    const BOOLEAN OwnsTx = GreenQuicLcoreOwnsTx(Dpdk, Core);

    uint32_t RxPressure = 0;
    uint32_t RxQueuePressure = 0;
    if (OwnsRx) {
        const uint32_t RxBurstPressure = GreenQuicPressureFromRatio(
            S->Rx.LastBurstCount,
            RX_BURST_SIZE);
        RxQueuePressure = GreenQuicPressureFromRatio(
            S->Rx.LastQueueCount,
            Dpdk->GreenQuicRxQueueHigh);
        RxPressure = GreenQuicMaxU32(RxBurstPressure, RxQueuePressure);
        if (S->Rx.ConsecutiveFull >= Dpdk->GreenQuicFullBurstMaxCount) {
            RxPressure = GreenQuicMaxU32(
                RxPressure,
                Dpdk->GreenQuicPressureUpThreshold);
        }
    }

    uint32_t TxPressure = 0;
    if (OwnsTx) {
        const uint32_t TxBurstPressure = GreenQuicPressureFromRatio(
            S->Tx.LastBurstCount,
            TX_BURST_SIZE);
        TxPressure = GreenQuicPressureFromRatio(
            TxRingCount,
            Dpdk->GreenQuicTxRingHigh);
        TxPressure = GreenQuicMaxU32(
            TxPressure,
            GreenQuicPressureFromRatio(
                S->Tx.LastQueueCount,
                Dpdk->GreenQuicTxRingHigh));
        TxPressure = GreenQuicMaxU32(TxPressure, TxBurstPressure);
        if (S->Tx.ConsecutiveFull >= Dpdk->GreenQuicFullBurstMaxCount) {
            TxPressure = GreenQuicMaxU32(
                TxPressure,
                Dpdk->GreenQuicPressureUpThreshold);
        }
    }

    BOOLEAN RxHardMax =
        OwnsRx &&
        RxQueuePressure >= Dpdk->GreenQuicPressureMaxThreshold;
    BOOLEAN TxHardMax =
        OwnsTx &&
        TxPressure >= Dpdk->GreenQuicPressureMaxThreshold;

    uint64_t RxHints = 0;
    uint64_t TxHints = 0;
    GreenQuicGetDirectionalHintsForCore(
        Dpdk, S, Core, &RxHints, &TxHints);

    uint32_t RxQuicPressure = 0;
    uint32_t TxQuicPressure = 0;
    BOOLEAN RxQuicHardMax = FALSE;
    BOOLEAN TxQuicHardMax = FALSE;
    GreenQuicPlusDirectionalPressure(
        Dpdk,
        RxHints,
        TxHints,
        RxPressure,
        TxPressure,
        OwnsRx,
        OwnsTx,
        &RxQuicPressure,
        &TxQuicPressure,
        &RxQuicHardMax,
        &TxQuicHardMax);

    RxHardMax = RxHardMax || RxQuicHardMax;
    TxHardMax = TxHardMax || TxQuicHardMax;

    const uint32_t RxRawPressure = OwnsRx ?
        GreenQuicMaxU32(RxPressure, RxQuicPressure) : 0;
    const uint32_t TxRawPressure = OwnsTx ?
        GreenQuicMaxU32(TxPressure, TxQuicPressure) : 0;
    const uint32_t RawPressure = GreenQuicMaxU32(
        RxRawPressure,
        TxRawPressure);

    S->LastOwnsRx = OwnsRx;
    S->LastOwnsTx = OwnsTx;
    S->LastRxPressure = RxPressure;
    S->LastTxPressure = TxPressure;
    S->LastRxQuicPressure = RxQuicPressure;
    S->LastTxQuicPressure = TxQuicPressure;
    S->LastPlusPressure = GreenQuicMaxU32(
        RxQuicPressure,
        TxQuicPressure);
    S->LastRxRawPressure = RxRawPressure;
    S->LastTxRawPressure = TxRawPressure;
    S->LastRawPressure = RawPressure;
    S->LastTxRingCount = OwnsTx ? TxRingCount : 0;
    S->LastRxHints = OwnsRx ? RxHints : 0;
    S->LastTxHints = OwnsTx ? TxHints : 0;
    S->LastHints = S->LastRxHints | S->LastTxHints;
    S->LastRxHardMax = RxHardMax;
    S->LastTxHardMax = TxHardMax;
    S->LastHardMax = RxHardMax || TxHardMax;

    *HardMax = S->LastHardMax;
    return GreenQuicMinU32(RawPressure, GREENQUIC_PRESSURE_SCALE);
}
'''
    text = text[:compute_start] + compute_code + text[apply_start:]

    apply_start = text.index('static void\nGreenQuicApplyPolicy(')
    stats_start = text.index('\nstatic void\nGreenQuicMaybePrintStats(', apply_start)
    apply_code = r'''static void
GreenQuicApplyPolicy(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_ DPDK_INTERFACE* Interface,
    _In_ uint16_t Core
    )
{
    if (Dpdk->GreenQuicMode == GREENQUIC_MODE_OFF) {
        return;
    }

    GreenQuicMaybePrintStats(Dpdk, Core);

    const BOOLEAN OwnsRx = GreenQuicLcoreOwnsRx(Dpdk, Core);
    const BOOLEAN OwnsTx = GreenQuicLcoreOwnsTx(Dpdk, Core);
    const uint32_t TxRingCount = OwnsTx ?
        rte_ring_count(Interface->TxRingBuffer) : 0;
    GREENQUIC_LCORE_STATE* S = GreenQuicGetLcoreState(Dpdk, Core);

    BOOLEAN HardMax = FALSE;
    const uint32_t RawPressure = GreenQuicComputeRawPressure(
        Dpdk, S, Core, TxRingCount, &HardMax);
    S->LastRawPressure = RawPressure;

    if (OwnsRx) {
        S->RxPressureAvg = GreenQuicUpdateEwma(
            S->RxPressureAvg,
            S->LastRxRawPressure,
            Dpdk->GreenQuicEwmaRiseShift,
            Dpdk->GreenQuicEwmaFallShift);
    } else {
        S->RxPressureAvg = 0;
    }

    if (OwnsTx) {
        S->TxPressureAvg = GreenQuicUpdateEwma(
            S->TxPressureAvg,
            S->LastTxRawPressure,
            Dpdk->GreenQuicEwmaRiseShift,
            Dpdk->GreenQuicEwmaFallShift);
    } else {
        S->TxPressureAvg = 0;
    }

    // The only combination is the final CPU action. A physical lcore has one
    // frequency and one sleep state, so the busiest owned direction wins.
    S->PressureAvg = GreenQuicMaxU32(
        OwnsRx ? S->RxPressureAvg : 0,
        OwnsTx ? S->TxPressureAvg : 0);

    if (HardMax) {
        S->LastAction = "freq_max_hard";
        GreenQuicFreqMax(Dpdk, Core);
        return;
    }
    if (S->PressureAvg >= Dpdk->GreenQuicPressureMaxThreshold) {
        S->LastAction = "freq_max_avg";
        GreenQuicFreqMax(Dpdk, Core);
        return;
    }
    if (S->PressureAvg >= Dpdk->GreenQuicPressureUpThreshold) {
        S->LastAction = "freq_up";
        GreenQuicFreqUpStep(Dpdk, Core);
        return;
    }
    if (S->PressureAvg >= Dpdk->GreenQuicPressureKeepThreshold) {
        S->LastAction = "keep_pause";
        rte_pause();
        return;
    }

    const BOOLEAN RxEmptyEnough =
        !OwnsRx ||
        S->Rx.ConsecutiveEmpty >= Dpdk->GreenQuicRxEmptyPollThreshold;
    const BOOLEAN TxEmptyEnough =
        !OwnsTx ||
        S->Tx.ConsecutiveEmpty >= Dpdk->GreenQuicTxEmptyPollThreshold;
    if (!RxEmptyEnough || !TxEmptyEnough) {
        S->LastAction = "short_idle_pause";
        rte_pause();
        return;
    }

    if (OwnsTx &&
        Dpdk->GreenQuicNoSleepIfTxRingNotEmpty &&
        TxRingCount > 0) {
        S->LastAction = "txring_protect_up";
        GreenQuicFreqUpStep(Dpdk, Core);
        return;
    }

    uint64_t LastActive = 0;
    if (OwnsRx) {
        LastActive = S->Rx.LastActiveTsc;
    }
    if (OwnsTx && S->Tx.LastActiveTsc > LastActive) {
        LastActive = S->Tx.LastActiveTsc;
    }
    const uint64_t Now = rte_get_tsc_cycles();
    const uint64_t IdleUs = LastActive == 0 ?
        UINT64_MAX : GreenQuicTscDeltaToUs(Now - LastActive);

    if (IdleUs >= Dpdk->GreenQuicFreqMinIdleUs) {
        S->LastAction = "freq_min";
        GreenQuicFreqMin(Dpdk, Core);
    } else {
        S->LastAction = "freq_down";
        GreenQuicFreqDownStep(Dpdk, Core);
    }

    const uint32_t SleepBudgetUs = GreenQuicGetSleepBudgetUs(
        Dpdk,
        S,
        TxRingCount,
        S->LastRxHints,
        S->LastTxHints,
        OwnsRx,
        OwnsTx);
    if (SleepBudgetUs != 0) {
        S->LastAction = "sleep";
        GreenQuicSleepUs(Dpdk, Core, SleepBudgetUs);
    }
}
'''
    text = text[:apply_start] + apply_code + text[stats_start:]

    stats_start = text.index('static void\nGreenQuicMaybePrintStats(')
    stats_end = text.index('\n// GREENQUIC-END', stats_start)
    stats_code = r'''static void
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
    printf(
        "GreenQUIC lcore=%u owns_rx=%u owns_tx=%u mode=%s profile=%s "
        "action=%s power=%u hardmax=%u rxhard=%u txhard=%u raw=%u avg=%u "
        "rxraw=%u txraw=%u rxavg=%u txavg=%u "
        "rxp=%u txp=%u rxqp=%u txqp=%u plusp=%u "
        "rxh=0x%" PRIx64 " txh=0x%" PRIx64 " txring=%u rxq=%u "
        "rx_pkts=%" PRIu64 " tx_pkts=%" PRIu64 " "
        "rx_empty=%u tx_empty=%u rx_full=%u tx_full=%u "
        "slept_us=%" PRIu64 "\n",
        Core,
        S->LastOwnsRx ? 1U : 0U,
        S->LastOwnsTx ? 1U : 0U,
        GreenQuicModeToString(Dpdk->GreenQuicMode),
        GreenQuicProfileToString(Dpdk->GreenQuicProfile),
        S->LastAction != NULL ? S->LastAction : "none",
        S->PowerAvailable ? 1U : 0U,
        S->LastHardMax ? 1U : 0U,
        S->LastRxHardMax ? 1U : 0U,
        S->LastTxHardMax ? 1U : 0U,
        S->LastRawPressure,
        S->PressureAvg,
        S->LastRxRawPressure,
        S->LastTxRawPressure,
        S->RxPressureAvg,
        S->TxPressureAvg,
        S->LastRxPressure,
        S->LastTxPressure,
        S->LastRxQuicPressure,
        S->LastTxQuicPressure,
        S->LastPlusPressure,
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
        S->TotalSleepUs);
}
'''
    text = text[:stats_start] + stats_code + text[stats_end:]

    old_worker = r'''            CxPlatDpdkRx(Dpdk, Core, Interface);
            CxPlatDpdkTx(Dpdk, Core, Interface);
            GreenQuicApplyPolicy(Dpdk, Interface, Core);
'''
    new_worker = r'''            const BOOLEAN OwnsRx = GreenQuicLcoreOwnsRx(Dpdk, Core);
            const BOOLEAN OwnsTx = GreenQuicLcoreOwnsTx(Dpdk, Core);
            if (OwnsRx) {
                CxPlatDpdkRx(Dpdk, Core, Interface);
            }
            if (OwnsTx) {
                CxPlatDpdkTx(Dpdk, Core, Interface);
            }
            GreenQuicApplyPolicy(Dpdk, Interface, Core);
            if (!OwnsRx && !OwnsTx) {
                rte_pause();
            }
'''
    if old_worker not in text:
        raise RuntimeError('Role-complete patch could not find worker operations')
    text = text.replace(old_worker, new_worker, 1)

    write_text(path, text)

    ini = repo / 'dpdk.greenquic.example.ini'
    if ini.exists():
        ini_text = read_text(ini)
        if 'GreenQuicEnableRx=1' not in ini_text:
            ini_text += r'''

# V18 role-complete directional ownership.
# Defaults: RX and TX are enabled. In non-multicore mode the single lcore owns
# both directions, but the two pressure paths remain independent.
GreenQuicEnableRx=1
GreenQuicEnableTx=1

# Multi-core only. Set 0 to make GreenQuicTxOwnerLcore a TX-only lcore.
# Every other enabled DPDK lcore receives an RX-only role, subject to the NIC's
# maximum RX queue count.
GreenQuicTxOwnerAlsoRx=1
'''
            write_text(ini, ini_text)

    log(
        'V18 final role-complete correction patched: RX-only, TX-only and RX+TX '
        'lcores use independent directional pressure and idle state.')


# =============================================================================
# V18 FINAL SEPARATED-SIGNAL EWMA + powermng.ini OVERRIDE
# =============================================================================

POWER_MNG_INI_V18 = r'''# GreenQUIC V18 power-management configuration
#
# Runtime loading order:
#   1. Built-in safe defaults
#   2. dpdk.ini (mode, profile, lcores, roles, plus legacy power keys)
#   3. this powermng.ini file, which overrides all power-policy values
#
# Override the path with:
#   export GREENQUIC_POWER_CONFIG=/absolute/path/to/powermng.ini
#
# Pressure values use a 0..GreenQuicPressureScale range. 1000 is recommended.
# A pressure value is NOT a frequency percentage. It selects a policy region.

# -----------------------------------------------------------------------------
# Master switches
# -----------------------------------------------------------------------------
GreenQuicEnableFreq=1
GreenQuicEnableSleep=1
GreenQuicNoSleepIfTxRingNotEmpty=1
GreenQuicTxRingProtectUp=1

# -----------------------------------------------------------------------------
# Pressure scale and final CPU-action thresholds
# -----------------------------------------------------------------------------
GreenQuicPressureScale=1000
# >= 900: request maximum frequency immediately from the averaged/control path.
GreenQuicPressureMaxThreshold=900
# 600..899: request one DPDK frequency step upward, rate-limited below.
GreenQuicPressureUpThreshold=600
# 250..599: keep the current frequency and continue polling.
# <250: begin empty-poll and idle-duration checks.
GreenQuicPressureKeepThreshold=250

# -----------------------------------------------------------------------------
# Physical signal normalization
# -----------------------------------------------------------------------------
# RX queue count 64 maps to full pressure (1000 by default).
GreenQuicRxQueueHigh=64
# rte_eth_rx_queue_count() is sampled once per this many RX polls.
GreenQuicRxQueueSamplePeriod=64
# TX software-ring count 64 maps to full pressure.
GreenQuicTxRingHigh=64

# -----------------------------------------------------------------------------
# Separate physical-signal EWMAs
# -----------------------------------------------------------------------------
# Alpha is written in permille: 500 = 0.5 = 1/2, 250 = 0.25 = 1/4.
#
# Bursts are instantaneous, so they rise and fall quickly.
GreenQuicRxBurstRiseAlphaPermille=500
GreenQuicRxBurstFallAlphaPermille=500
GreenQuicTxBurstRiseAlphaPermille=500
GreenQuicTxBurstFallAlphaPermille=500
#
# Queue/ring backlog is stronger evidence of insufficient service capacity.
# Rise alpha 1000 reacts immediately; fall alpha 250 remembers real backlog
# through short gaps without keeping burst history artificially sticky.
GreenQuicRxQueueRiseAlphaPermille=1000
GreenQuicRxQueueFallAlphaPermille=250
GreenQuicTxRingRiseAlphaPermille=1000
GreenQuicTxRingFallAlphaPermille=250

# Optional legacy aliases. If used, each shift is converted to alpha=1/(2^shift)
# and applied to all four physical signals. Explicit per-signal alpha keys later
# in this file override the alias.
# GreenQuicEwmaRiseShift=1
# GreenQuicEwmaFallShift=2

# -----------------------------------------------------------------------------
# Full-burst persistence
# -----------------------------------------------------------------------------
GreenQuicFullBurstMaxCount=8
# Default 0 disables an extra floor because a current full burst already maps
# to full pressure. Set a value such as 600 only for controlled experiments.
GreenQuicFullBurstFloor=0

# -----------------------------------------------------------------------------
# QUIC semantic floors (PLUS mode only)
# -----------------------------------------------------------------------------
# These are direct, short-lived floors applied AFTER physical EWMAs.
# They are not fed into a long EWMA, so they disappear when the hint expires.

# Client-download ACKs are throughput-critical: reach the frequency-up boundary.
GreenQuicAckClientFloor=600
# Other ACKs stay active and avoid sleep, but remain below the up boundary.
GreenQuicAckOtherFloor=550
# Optional ACK+heavy-RX immediate maximum threshold.
GreenQuicAckRxHardMaxThreshold=900
GreenQuicEnableAckRxHardMax=1
GreenQuicAckBlocksSleep=1

# CUBIC growth predicts future TX work. Without physical work, stay ready at 550.
# With real TX pressure >=250, use 600 and permit one upward step.
GreenQuicCwndGrowthNoWorkFloor=550
GreenQuicCwndGrowthWorkFloor=600
GreenQuicCwndGrowthPhysicalThreshold=250
GreenQuicCwndGrowthBlocksSleep=1

# Recovery is stronger than normal up pressure but below max pressure.
GreenQuicRecoveryFloor=750
# Recovery + substantial current physical work forces immediate max frequency.
GreenQuicRecoveryHardMaxPhysicalThreshold=600
GreenQuicEnableRecoveryHardMax=1
GreenQuicRecoveryBlocksSleep=1

# A blocked sender is waiting for feedback, not doing local work. Default 0 means
# no numerical frequency floor. It can optionally guard shallow sleep below.
GreenQuicBlockedRxFloor=0
# 0 disables the blocked-state sleep guard. 2 would forbid sleep until idle level 2.
GreenQuicBlockedSleepGuardLevel=0

# Active file-transfer hints do not create frequency pressure. Real burst/queue/
# ring signals control frequency. The hint only requires deeper idle before sleep.
GreenQuicActiveTransferSleepMinLevel=4

# -----------------------------------------------------------------------------
# Physical and semantic hard-maximum controls
# -----------------------------------------------------------------------------
GreenQuicEnablePhysicalHardMax=1

# -----------------------------------------------------------------------------
# Empty confirmation and DVFS timing
# -----------------------------------------------------------------------------
GreenQuicRxEmptyPollThreshold=50000
GreenQuicTxEmptyPollThreshold=50000
# At most one upward step every 500 us.
GreenQuicFreqUpPeriodUs=500
# At most one downward/minimum request every 5 ms.
GreenQuicFreqDownPeriodUs=5000
# After 20 ms since the latest owned-direction activity, request min frequency.
GreenQuicFreqMinIdleUs=20000
# Backward-compatible alias used by old configurations.
GreenQuicFreqPeriodUs=100000

# -----------------------------------------------------------------------------
# Sleep depth and duration
# -----------------------------------------------------------------------------
# EmptyLevel = consecutive_empty_polls / direction_empty_threshold.
GreenQuicSleepShortMinLevel=2
GreenQuicSleepDataMinLevel=4
GreenQuicSleepDeepMinLevel=8
# Requested sleeps; actual wake-up latency must be measured on the target CPU.
GreenQuicAckPathMaxSleepUs=1
GreenQuicDataPathMaxSleepUs=2
GreenQuicMaxSleepUs=2

# -----------------------------------------------------------------------------
# Decision logging
# -----------------------------------------------------------------------------
GreenQuicLogLevel=0
GreenQuicStatsPeriodUs=0
'''


def patch_separated_signal_ewma_and_powermng(
    repo: Path,
    enable_multi_core: bool
    ) -> None:
    """Final V18 override: separate physical EWMAs and external power tuning.

    The previous complete V18 code remains in this full autopatcher. This final
    patch only replaces the active generated policy functions and adds fields,
    parsing and comments. RX burst, RX queue, TX burst and TX ring keep separate
    histories. QUIC hints are direct short-lived floors after those EWMAs.
    """
    path = repo / 'src/platform/datapath_raw_dpdk.c'
    text = read_text(path)
    marker = '// GREENQUIC-V18-SEPARATE-SIGNALS-POWERMNG'
    if marker in text:
        log('V18 separated-signal EWMA/powermng.ini patch already present; skipping.')
        return

    log('Applying V18 separated physical EWMAs and powermng.ini power policy.')

    # ------------------------------------------------------------------
    # Add state for each signal. Existing directional fields are retained
    # for compatibility and logging; they now mirror final control values.
    # ------------------------------------------------------------------
    state_anchor = '    BOOLEAN LastOwnsTx;\n'
    if state_anchor not in text:
        raise RuntimeError('Separated-signal patch could not find lcore-state anchor')
    state_fields = r'''    // GREENQUIC-V18-SEPARATE-SIGNALS-POWERMNG
    // Physical measurements keep independent memory because a one-poll burst
    // and persistent queue/ring backlog have different time behavior.
    uint32_t RxBurstPressureAvg;
    uint32_t RxQueuePressureAvg;
    uint32_t TxBurstPressureAvg;
    uint32_t TxRingPressureAvg;
    uint32_t LastRxBurstPressure;
    uint32_t LastRxQueuePressure;
    uint32_t LastTxBurstPressure;
    uint32_t LastTxRingPressure;
    uint32_t LastRxPhysicalControl;
    uint32_t LastTxPhysicalControl;
    uint32_t LastRxControlPressure;
    uint32_t LastTxControlPressure;
'''
    text = text.replace(state_anchor, state_anchor + state_fields, 1)

    # ------------------------------------------------------------------
    # Add all tunable values to the datapath configuration. The old shared
    # EWMA shifts remain in the struct for backward compatibility.
    # ------------------------------------------------------------------
    cfg_anchor = '    uint32_t GreenQuicEwmaFallShift;\n'
    if cfg_anchor not in text:
        raise RuntimeError('Separated-signal patch could not find config-field anchor')
    cfg_fields = r'''    // GREENQUIC-V18-SEPARATE-SIGNALS-POWERMNG: all algorithm knobs.
    uint32_t GreenQuicPressureScale;
    uint32_t GreenQuicRxBurstRiseAlphaPermille;
    uint32_t GreenQuicRxBurstFallAlphaPermille;
    uint32_t GreenQuicRxQueueRiseAlphaPermille;
    uint32_t GreenQuicRxQueueFallAlphaPermille;
    uint32_t GreenQuicTxBurstRiseAlphaPermille;
    uint32_t GreenQuicTxBurstFallAlphaPermille;
    uint32_t GreenQuicTxRingRiseAlphaPermille;
    uint32_t GreenQuicTxRingFallAlphaPermille;
    uint32_t GreenQuicFullBurstFloor;
    uint32_t GreenQuicAckClientFloor;
    uint32_t GreenQuicAckOtherFloor;
    uint32_t GreenQuicAckRxHardMaxThreshold;
    uint32_t GreenQuicCwndGrowthNoWorkFloor;
    uint32_t GreenQuicCwndGrowthWorkFloor;
    uint32_t GreenQuicCwndGrowthPhysicalThreshold;
    uint32_t GreenQuicRecoveryFloor;
    uint32_t GreenQuicRecoveryHardMaxPhysicalThreshold;
    uint32_t GreenQuicBlockedRxFloor;
    uint32_t GreenQuicBlockedSleepGuardLevel;
    uint32_t GreenQuicActiveTransferSleepMinLevel;
    uint32_t GreenQuicSleepShortMinLevel;
    uint32_t GreenQuicSleepDataMinLevel;
    uint32_t GreenQuicSleepDeepMinLevel;
    BOOLEAN GreenQuicEnablePhysicalHardMax;
    BOOLEAN GreenQuicEnableRecoveryHardMax;
    BOOLEAN GreenQuicEnableAckRxHardMax;
    BOOLEAN GreenQuicAckBlocksSleep;
    BOOLEAN GreenQuicRecoveryBlocksSleep;
    BOOLEAN GreenQuicCwndGrowthBlocksSleep;
    BOOLEAN GreenQuicTxRingProtectUp;
'''
    text = text.replace(cfg_anchor, cfg_anchor + cfg_fields, 1)

    # Defaults are intentionally explicit. Alpha permille is easier to tune than
    # bit shifts: 500=1/2, 250=1/4, 1000=immediate.
    defaults_anchor = '    Dpdk->GreenQuicEwmaFallShift = DEFAULT_GREENQUIC_EWMA_FALL_SHIFT;\n'
    if defaults_anchor not in text:
        raise RuntimeError('Separated-signal patch could not find defaults anchor')
    defaults_code = r'''    // GREENQUIC-V18-SEPARATE-SIGNALS-POWERMNG defaults.
    Dpdk->GreenQuicPressureScale = 1000U;
    Dpdk->GreenQuicRxBurstRiseAlphaPermille = 500U;
    Dpdk->GreenQuicRxBurstFallAlphaPermille = 500U;
    Dpdk->GreenQuicRxQueueRiseAlphaPermille = 1000U;
    Dpdk->GreenQuicRxQueueFallAlphaPermille = 250U;
    Dpdk->GreenQuicTxBurstRiseAlphaPermille = 500U;
    Dpdk->GreenQuicTxBurstFallAlphaPermille = 500U;
    Dpdk->GreenQuicTxRingRiseAlphaPermille = 1000U;
    Dpdk->GreenQuicTxRingFallAlphaPermille = 250U;
    Dpdk->GreenQuicFullBurstFloor = 0U;
    Dpdk->GreenQuicAckClientFloor = 600U;
    Dpdk->GreenQuicAckOtherFloor = 550U;
    Dpdk->GreenQuicAckRxHardMaxThreshold = 900U;
    Dpdk->GreenQuicCwndGrowthNoWorkFloor = 550U;
    Dpdk->GreenQuicCwndGrowthWorkFloor = 600U;
    Dpdk->GreenQuicCwndGrowthPhysicalThreshold = 250U;
    Dpdk->GreenQuicRecoveryFloor = 750U;
    Dpdk->GreenQuicRecoveryHardMaxPhysicalThreshold = 600U;
    Dpdk->GreenQuicBlockedRxFloor = 0U;
    Dpdk->GreenQuicBlockedSleepGuardLevel = 0U;
    Dpdk->GreenQuicActiveTransferSleepMinLevel = 4U;
    Dpdk->GreenQuicSleepShortMinLevel = 2U;
    Dpdk->GreenQuicSleepDataMinLevel = 4U;
    Dpdk->GreenQuicSleepDeepMinLevel = 8U;
    Dpdk->GreenQuicEnablePhysicalHardMax = TRUE;
    Dpdk->GreenQuicEnableRecoveryHardMax = TRUE;
    Dpdk->GreenQuicEnableAckRxHardMax = TRUE;
    Dpdk->GreenQuicAckBlocksSleep = TRUE;
    Dpdk->GreenQuicRecoveryBlocksSleep = TRUE;
    Dpdk->GreenQuicCwndGrowthBlocksSleep = TRUE;
    Dpdk->GreenQuicTxRingProtectUp = TRUE;
'''
    text = text.replace(defaults_anchor, defaults_anchor + defaults_code, 1)

    # Add helper prototypes. Old helpers remain untouched for old code retained
    # under #if 0 and for compatibility.
    proto_anchor = 'static uint32_t GreenQuicUpdateEwma(_In_ uint32_t Avg, _In_ uint32_t Raw, _In_ uint32_t RiseShift, _In_ uint32_t FallShift);\n'
    if proto_anchor not in text:
        raise RuntimeError('Separated-signal patch could not find helper prototype anchor')
    proto_code = r'''static uint32_t GreenQuicPressureFromRatioConfigured(_In_ const DPDK_DATAPATH* Dpdk, _In_ uint64_t Value, _In_ uint64_t High);
static uint32_t GreenQuicUpdateEwmaAlpha(_In_ const DPDK_DATAPATH* Dpdk, _In_ uint32_t Avg, _In_ uint32_t Raw, _In_ uint32_t RiseAlphaPermille, _In_ uint32_t FallAlphaPermille);
static uint32_t GreenQuicAlphaPermilleFromShift(_In_ uint32_t Shift);
static BOOLEAN GreenQuicApplyPowerConfigValue(_Inout_ DPDK_DATAPATH* Dpdk, _In_ const char* Key, _In_ const char* Value);
static void GreenQuicReadPowerConfig(_Inout_ DPDK_DATAPATH* Dpdk);
'''
    text = text.replace(proto_anchor, proto_anchor + proto_code, 1)

    old_plus_proto = (
        'static void GreenQuicPlusDirectionalPressure(_In_ const DPDK_DATAPATH* Dpdk, '
        '_In_ uint64_t RxHints, _In_ uint64_t TxHints, _In_ uint32_t RxPressure, '
        '_In_ uint32_t TxPressure, _In_ BOOLEAN OwnsRx, _In_ BOOLEAN OwnsTx, '
        '_Out_ uint32_t* RxQuicPressure, _Out_ uint32_t* TxQuicPressure, '
        '_Out_ BOOLEAN* RxHardMax, _Out_ BOOLEAN* TxHardMax);')
    new_plus_proto = (
        'static void GreenQuicPlusDirectionalPressure(_In_ const DPDK_DATAPATH* Dpdk, '
        '_In_ uint64_t RxHints, _In_ uint64_t TxHints, '
        '_In_ uint32_t RxPhysicalRaw, _In_ uint32_t TxPhysicalRaw, '
        '_In_ uint32_t RxPhysicalControl, _In_ uint32_t TxPhysicalControl, '
        '_In_ BOOLEAN OwnsRx, _In_ BOOLEAN OwnsTx, '
        '_Out_ uint32_t* RxQuicFloor, _Out_ uint32_t* TxQuicFloor, '
        '_Out_ BOOLEAN* RxHardMax, _Out_ BOOLEAN* TxHardMax);')
    if old_plus_proto not in text:
        raise RuntimeError('Separated-signal patch could not find QUIC-floor prototype')
    text = text.replace(old_plus_proto, new_plus_proto, 1)

    # Add configured-scale normalization, arbitrary-alpha EWMA and separate file
    # parsing immediately before the active sleep helper.
    helper_start = text.index('// GREENQUIC-BEGIN: helper implementations')
    sleep_start = text.index('static uint32_t\nGreenQuicGetSleepBudgetUs(', helper_start)
    helper_code = r'''// GREENQUIC-V18-SEPARATE-SIGNALS-POWERMNG
static uint32_t
GreenQuicPressureFromRatioConfigured(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ uint64_t Value,
    _In_ uint64_t High
    )
{
    if (Value == 0 || High == 0 || Dpdk->GreenQuicPressureScale == 0) {
        return 0;
    }
    const uint64_t Score =
        (Value * (uint64_t)Dpdk->GreenQuicPressureScale) / High;
    return Score > Dpdk->GreenQuicPressureScale ?
        Dpdk->GreenQuicPressureScale : (uint32_t)Score;
}

static uint32_t
GreenQuicAlphaPermilleFromShift(
    _In_ uint32_t Shift
    )
{
    if (Shift == 0) {
        return 1000U;
    }
    if (Shift >= 31U) {
        return 0U;
    }
    const uint32_t Denominator = 1U << Shift;
    const uint32_t Alpha = 1000U / Denominator;
    return Alpha == 0 ? 1U : Alpha;
}

static uint32_t
GreenQuicUpdateEwmaAlpha(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ uint32_t Avg,
    _In_ uint32_t Raw,
    _In_ uint32_t RiseAlphaPermille,
    _In_ uint32_t FallAlphaPermille
    )
{
    const uint32_t Scale =
        Dpdk->GreenQuicPressureScale == 0 ? 1000U :
        Dpdk->GreenQuicPressureScale;
    Avg = GreenQuicMinU32(Avg, Scale);
    Raw = GreenQuicMinU32(Raw, Scale);
    if (Raw == Avg) {
        return Avg;
    }

    const BOOLEAN Rising = Raw > Avg;
    uint32_t Alpha = Rising ? RiseAlphaPermille : FallAlphaPermille;
    Alpha = GreenQuicMinU32(Alpha, 1000U);
    if (Alpha == 0) {
        // Alpha zero is an intentional freeze for controlled experiments.
        return Avg;
    }

    const uint32_t Delta = Rising ? Raw - Avg : Avg - Raw;
    uint32_t Step = (uint32_t)(((uint64_t)Delta * Alpha) / 1000U);
    if (Step == 0) {
        // Prevent integer rounding from permanently stopping a nonzero alpha.
        Step = 1U;
    }
    if (Rising) {
        return GreenQuicMinU32(Scale, Avg + Step);
    }
    return Avg > Step ? Avg - Step : 0U;
}

static BOOLEAN
GreenQuicApplyPowerConfigValue(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_ const char* Key,
    _In_ const char* Value
    )
{
#define GQ_U32(Name, Field) \
    if (strcmp(Key, Name) == 0) { \
        Dpdk->Field = (uint32_t)strtoul(Value, NULL, 10); \
        return TRUE; \
    }
#define GQ_BOOL(Name, Field) \
    if (strcmp(Key, Name) == 0) { \
        Dpdk->Field = atoi(Value) != 0 ? TRUE : FALSE; \
        return TRUE; \
    }

    GQ_U32("GreenQuicPressureScale", GreenQuicPressureScale)
    GQ_U32("GreenQuicPressureMaxThreshold", GreenQuicPressureMaxThreshold)
    GQ_U32("GreenQuicPressureUpThreshold", GreenQuicPressureUpThreshold)
    GQ_U32("GreenQuicPressureKeepThreshold", GreenQuicPressureKeepThreshold)
    GQ_U32("GreenQuicRxQueueHigh", GreenQuicRxQueueHigh)
    GQ_U32("GreenQuicRxQueueSamplePeriod", GreenQuicRxQueueSamplePeriod)
    GQ_U32("GreenQuicTxRingHigh", GreenQuicTxRingHigh)
    GQ_U32("GreenQuicRxEmptyPollThreshold", GreenQuicRxEmptyPollThreshold)
    GQ_U32("GreenQuicTxEmptyPollThreshold", GreenQuicTxEmptyPollThreshold)
    GQ_U32("GreenQuicFullBurstMaxCount", GreenQuicFullBurstMaxCount)
    GQ_U32("GreenQuicFullBurstFloor", GreenQuicFullBurstFloor)

    GQ_U32("GreenQuicRxBurstRiseAlphaPermille", GreenQuicRxBurstRiseAlphaPermille)
    GQ_U32("GreenQuicRxBurstFallAlphaPermille", GreenQuicRxBurstFallAlphaPermille)
    GQ_U32("GreenQuicRxQueueRiseAlphaPermille", GreenQuicRxQueueRiseAlphaPermille)
    GQ_U32("GreenQuicRxQueueFallAlphaPermille", GreenQuicRxQueueFallAlphaPermille)
    GQ_U32("GreenQuicTxBurstRiseAlphaPermille", GreenQuicTxBurstRiseAlphaPermille)
    GQ_U32("GreenQuicTxBurstFallAlphaPermille", GreenQuicTxBurstFallAlphaPermille)
    GQ_U32("GreenQuicTxRingRiseAlphaPermille", GreenQuicTxRingRiseAlphaPermille)
    GQ_U32("GreenQuicTxRingFallAlphaPermille", GreenQuicTxRingFallAlphaPermille)

    GQ_U32("GreenQuicAckClientFloor", GreenQuicAckClientFloor)
    GQ_U32("GreenQuicAckOtherFloor", GreenQuicAckOtherFloor)
    GQ_U32("GreenQuicAckRxHardMaxThreshold", GreenQuicAckRxHardMaxThreshold)
    GQ_U32("GreenQuicCwndGrowthNoWorkFloor", GreenQuicCwndGrowthNoWorkFloor)
    GQ_U32("GreenQuicCwndGrowthWorkFloor", GreenQuicCwndGrowthWorkFloor)
    GQ_U32("GreenQuicCwndGrowthPhysicalThreshold", GreenQuicCwndGrowthPhysicalThreshold)
    GQ_U32("GreenQuicRecoveryFloor", GreenQuicRecoveryFloor)
    GQ_U32("GreenQuicRecoveryHardMaxPhysicalThreshold", GreenQuicRecoveryHardMaxPhysicalThreshold)
    GQ_U32("GreenQuicBlockedRxFloor", GreenQuicBlockedRxFloor)
    GQ_U32("GreenQuicBlockedSleepGuardLevel", GreenQuicBlockedSleepGuardLevel)
    GQ_U32("GreenQuicActiveTransferSleepMinLevel", GreenQuicActiveTransferSleepMinLevel)

    GQ_U32("GreenQuicFreqPeriodUs", GreenQuicFreqPeriodUs)
    GQ_U32("GreenQuicFreqUpPeriodUs", GreenQuicFreqUpPeriodUs)
    GQ_U32("GreenQuicFreqDownPeriodUs", GreenQuicFreqDownPeriodUs)
    GQ_U32("GreenQuicFreqMinIdleUs", GreenQuicFreqMinIdleUs)
    GQ_U32("GreenQuicAckPathMaxSleepUs", GreenQuicAckPathMaxSleepUs)
    GQ_U32("GreenQuicDataPathMaxSleepUs", GreenQuicDataPathMaxSleepUs)
    GQ_U32("GreenQuicMaxSleepUs", GreenQuicMaxSleepUs)
    GQ_U32("GreenQuicSleepShortMinLevel", GreenQuicSleepShortMinLevel)
    GQ_U32("GreenQuicSleepDataMinLevel", GreenQuicSleepDataMinLevel)
    GQ_U32("GreenQuicSleepDeepMinLevel", GreenQuicSleepDeepMinLevel)
    GQ_U32("GreenQuicStatsPeriodUs", GreenQuicStatsPeriodUs)
    GQ_U32("GreenQuicLogLevel", GreenQuicLogLevel)

    GQ_BOOL("GreenQuicEnableFreq", GreenQuicEnableFreq)
    GQ_BOOL("GreenQuicEnableSleep", GreenQuicEnableSleep)
    GQ_BOOL("GreenQuicNoSleepIfTxRingNotEmpty", GreenQuicNoSleepIfTxRingNotEmpty)
    GQ_BOOL("GreenQuicTxRingProtectUp", GreenQuicTxRingProtectUp)
    GQ_BOOL("GreenQuicEnablePhysicalHardMax", GreenQuicEnablePhysicalHardMax)
    GQ_BOOL("GreenQuicEnableRecoveryHardMax", GreenQuicEnableRecoveryHardMax)
    GQ_BOOL("GreenQuicEnableAckRxHardMax", GreenQuicEnableAckRxHardMax)
    GQ_BOOL("GreenQuicAckBlocksSleep", GreenQuicAckBlocksSleep)
    GQ_BOOL("GreenQuicRecoveryBlocksSleep", GreenQuicRecoveryBlocksSleep)
    GQ_BOOL("GreenQuicCwndGrowthBlocksSleep", GreenQuicCwndGrowthBlocksSleep)

    // Backward-compatible shared shift aliases. They intentionally affect all
    // physical signals; later per-signal alpha keys can override them.
    if (strcmp(Key, "GreenQuicEwmaRiseShift") == 0) {
        const uint32_t Alpha = GreenQuicAlphaPermilleFromShift(
            (uint32_t)strtoul(Value, NULL, 10));
        Dpdk->GreenQuicRxBurstRiseAlphaPermille = Alpha;
        Dpdk->GreenQuicRxQueueRiseAlphaPermille = Alpha;
        Dpdk->GreenQuicTxBurstRiseAlphaPermille = Alpha;
        Dpdk->GreenQuicTxRingRiseAlphaPermille = Alpha;
        return TRUE;
    }
    if (strcmp(Key, "GreenQuicEwmaFallShift") == 0) {
        const uint32_t Alpha = GreenQuicAlphaPermilleFromShift(
            (uint32_t)strtoul(Value, NULL, 10));
        Dpdk->GreenQuicRxBurstFallAlphaPermille = Alpha;
        Dpdk->GreenQuicRxQueueFallAlphaPermille = Alpha;
        Dpdk->GreenQuicTxBurstFallAlphaPermille = Alpha;
        Dpdk->GreenQuicTxRingFallAlphaPermille = Alpha;
        return TRUE;
    }

#undef GQ_U32
#undef GQ_BOOL
    return FALSE;
}

static void
GreenQuicReadPowerConfig(
    _Inout_ DPDK_DATAPATH* Dpdk
    )
{
    const char* ConfigPath = getenv("GREENQUIC_POWER_CONFIG");
    if (ConfigPath == NULL || ConfigPath[0] == '\0') {
        ConfigPath = "powermng.ini";
    }

    FILE* File = fopen(ConfigPath, "r");
    if (File == NULL) {
        // Missing file is safe: built-in defaults and optional legacy dpdk.ini
        // values remain active.
        return;
    }

    char Buffer[512];
    while (fgets(Buffer, sizeof(Buffer), File) != NULL) {
        char* Line = Buffer;
        while (*Line == ' ' || *Line == '\t') {
            ++Line;
        }
        if (*Line == '\0' || *Line == '\n' || *Line == '\r' ||
            *Line == '#' || *Line == ';') {
            continue;
        }

        char* Equal = strchr(Line, '=');
        if (Equal == NULL) {
            continue;
        }
        *Equal = '\0';
        char* Value = Equal + 1;

        char* KeyEnd = Equal;
        while (KeyEnd > Line && (KeyEnd[-1] == ' ' || KeyEnd[-1] == '\t')) {
            *--KeyEnd = '\0';
        }
        while (*Value == ' ' || *Value == '\t') {
            ++Value;
        }
        char* ValueEnd = Value + strlen(Value);
        while (ValueEnd > Value &&
               (ValueEnd[-1] == '\n' || ValueEnd[-1] == '\r' ||
                ValueEnd[-1] == ' ' || ValueEnd[-1] == '\t')) {
            *--ValueEnd = '\0';
        }

        (void)GreenQuicApplyPowerConfigValue(Dpdk, Line, Value);
    }
    fclose(File);

    // Sanitize only structural invariants. User-selected policy values remain
    // otherwise untouched and are visible in logs.
    if (Dpdk->GreenQuicPressureScale == 0) {
        Dpdk->GreenQuicPressureScale = 1000U;
    }
#define GQ_CLAMP_PRESSURE(Field) \
    Dpdk->Field = GreenQuicMinU32(Dpdk->Field, Dpdk->GreenQuicPressureScale)
#define GQ_CLAMP_ALPHA(Field) \
    Dpdk->Field = GreenQuicMinU32(Dpdk->Field, 1000U)
    GQ_CLAMP_PRESSURE(GreenQuicPressureKeepThreshold);
    GQ_CLAMP_PRESSURE(GreenQuicPressureUpThreshold);
    GQ_CLAMP_PRESSURE(GreenQuicPressureMaxThreshold);
    GQ_CLAMP_PRESSURE(GreenQuicFullBurstFloor);
    GQ_CLAMP_PRESSURE(GreenQuicAckClientFloor);
    GQ_CLAMP_PRESSURE(GreenQuicAckOtherFloor);
    GQ_CLAMP_PRESSURE(GreenQuicAckRxHardMaxThreshold);
    GQ_CLAMP_PRESSURE(GreenQuicCwndGrowthNoWorkFloor);
    GQ_CLAMP_PRESSURE(GreenQuicCwndGrowthWorkFloor);
    GQ_CLAMP_PRESSURE(GreenQuicCwndGrowthPhysicalThreshold);
    GQ_CLAMP_PRESSURE(GreenQuicRecoveryFloor);
    GQ_CLAMP_PRESSURE(GreenQuicRecoveryHardMaxPhysicalThreshold);
    GQ_CLAMP_PRESSURE(GreenQuicBlockedRxFloor);
    GQ_CLAMP_ALPHA(GreenQuicRxBurstRiseAlphaPermille);
    GQ_CLAMP_ALPHA(GreenQuicRxBurstFallAlphaPermille);
    GQ_CLAMP_ALPHA(GreenQuicRxQueueRiseAlphaPermille);
    GQ_CLAMP_ALPHA(GreenQuicRxQueueFallAlphaPermille);
    GQ_CLAMP_ALPHA(GreenQuicTxBurstRiseAlphaPermille);
    GQ_CLAMP_ALPHA(GreenQuicTxBurstFallAlphaPermille);
    GQ_CLAMP_ALPHA(GreenQuicTxRingRiseAlphaPermille);
    GQ_CLAMP_ALPHA(GreenQuicTxRingFallAlphaPermille);
#undef GQ_CLAMP_PRESSURE
#undef GQ_CLAMP_ALPHA

    if (Dpdk->GreenQuicRxQueueHigh == 0) {
        Dpdk->GreenQuicRxQueueHigh = 1U;
    }
    if (Dpdk->GreenQuicTxRingHigh == 0) {
        Dpdk->GreenQuicTxRingHigh = 1U;
    }
    if (Dpdk->GreenQuicRxQueueSamplePeriod == 0) {
        Dpdk->GreenQuicRxQueueSamplePeriod = 1U;
    }
    if (Dpdk->GreenQuicPressureUpThreshold <
        Dpdk->GreenQuicPressureKeepThreshold) {
        Dpdk->GreenQuicPressureUpThreshold =
            Dpdk->GreenQuicPressureKeepThreshold;
    }
    if (Dpdk->GreenQuicPressureMaxThreshold <
        Dpdk->GreenQuicPressureUpThreshold) {
        Dpdk->GreenQuicPressureMaxThreshold =
            Dpdk->GreenQuicPressureUpThreshold;
    }
    if (Dpdk->GreenQuicSleepDataMinLevel <
        Dpdk->GreenQuicSleepShortMinLevel) {
        Dpdk->GreenQuicSleepDataMinLevel =
            Dpdk->GreenQuicSleepShortMinLevel;
    }
    if (Dpdk->GreenQuicSleepDeepMinLevel <
        Dpdk->GreenQuicSleepDataMinLevel) {
        Dpdk->GreenQuicSleepDeepMinLevel =
            Dpdk->GreenQuicSleepDataMinLevel;
    }
    if (Dpdk->GreenQuicLogLevel > 2U) {
        Dpdk->GreenQuicLogLevel = 2U;
    }
}

'''
    text = text[:sleep_start] + helper_code + text[sleep_start:]

    # Replace the active sleep policy. All levels and blockers are tunable.
    helper_start = text.index('// GREENQUIC-BEGIN: helper implementations')
    sleep_start = text.index('static uint32_t\nGreenQuicGetSleepBudgetUs(', helper_start)
    sleep_end = text.index('\nstatic void\nGreenQuicOnRxPoll(', sleep_start)
    sleep_code = r'''static uint32_t
GreenQuicGetSleepBudgetUs(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ const GREENQUIC_LCORE_STATE* S,
    _In_ uint32_t TxRingCount,
    _In_ uint64_t RxHints,
    _In_ uint64_t TxHints,
    _In_ BOOLEAN OwnsRx,
    _In_ BOOLEAN OwnsTx
    )
{
    if (!Dpdk->GreenQuicEnableSleep || Dpdk->GreenQuicMaxSleepUs == 0) {
        return 0;
    }

    // Never sleep over real work. PressureKeepThreshold is the exact boundary
    // between active polling and idle consideration.
    if ((OwnsTx && TxRingCount != 0) ||
        (OwnsRx && S->Rx.LastBurstCount != 0) ||
        (OwnsTx && S->Tx.LastBurstCount != 0) ||
        S->PressureAvg >= Dpdk->GreenQuicPressureKeepThreshold) {
        return 0;
    }

    if ((OwnsRx && Dpdk->GreenQuicRecoveryBlocksSleep &&
         (RxHints & GQPLUS_HINT_CUBIC_RECOVERY) != 0) ||
        (OwnsTx && Dpdk->GreenQuicAckBlocksSleep &&
         (TxHints & GQPLUS_HINT_ACK_PENDING) != 0) ||
        (OwnsTx && Dpdk->GreenQuicRecoveryBlocksSleep &&
         (TxHints & GQPLUS_HINT_CUBIC_RECOVERY) != 0) ||
        (OwnsTx && Dpdk->GreenQuicCwndGrowthBlocksSleep &&
         (TxHints & GQPLUS_HINT_CUBIC_RAMPING) != 0)) {
        return 0;
    }

    uint32_t EmptyLevel = Dpdk->GreenQuicSleepDeepMinLevel;
    if (OwnsRx) {
        const uint32_t Threshold =
            Dpdk->GreenQuicRxEmptyPollThreshold == 0 ? 1U :
            Dpdk->GreenQuicRxEmptyPollThreshold;
        EmptyLevel = S->Rx.ConsecutiveEmpty / Threshold;
    }
    if (OwnsTx) {
        const uint32_t Threshold =
            Dpdk->GreenQuicTxEmptyPollThreshold == 0 ? 1U :
            Dpdk->GreenQuicTxEmptyPollThreshold;
        const uint32_t TxLevel = S->Tx.ConsecutiveEmpty / Threshold;
        EmptyLevel = OwnsRx ? GreenQuicMinU32(EmptyLevel, TxLevel) : TxLevel;
    }

    // A blocked sender has no default frequency floor. This optional guard can
    // still prevent the shallowest sleeps while waiting for ACK feedback.
    if (OwnsRx && Dpdk->GreenQuicBlockedSleepGuardLevel != 0 &&
        (RxHints & GQPLUS_HINT_CUBIC_CWND_BLOCKED) != 0 &&
        EmptyLevel < Dpdk->GreenQuicBlockedSleepGuardLevel) {
        return 0;
    }

    const BOOLEAN ActiveRxTransfer =
        OwnsRx &&
        (RxHints & GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE) != 0 &&
        (Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_CLIENT_DOWNLOAD ||
         Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_SYMMETRIC);
    const BOOLEAN ActiveTxTransfer =
        OwnsTx &&
        (TxHints & GQPLUS_HINT_SERVER_FILE_TX_ACTIVE) != 0 &&
        (Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_SERVER_DOWNLOAD ||
         Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_SYMMETRIC);
    if ((ActiveRxTransfer || ActiveTxTransfer) &&
        EmptyLevel < Dpdk->GreenQuicActiveTransferSleepMinLevel) {
        return 0;
    }

    if (EmptyLevel >= Dpdk->GreenQuicSleepDeepMinLevel) {
        return Dpdk->GreenQuicMaxSleepUs;
    }
    if (EmptyLevel >= Dpdk->GreenQuicSleepDataMinLevel) {
        return GreenQuicMinU32(
            Dpdk->GreenQuicDataPathMaxSleepUs,
            Dpdk->GreenQuicMaxSleepUs);
    }
    if (EmptyLevel >= Dpdk->GreenQuicSleepShortMinLevel) {
        return GreenQuicMinU32(
            Dpdk->GreenQuicAckPathMaxSleepUs,
            Dpdk->GreenQuicMaxSleepUs);
    }
    return 0;
}
'''
    text = text[:sleep_start] + sleep_code + text[sleep_end:]

    # QUIC hints become direct floors after physical EWMAs, not EWMA inputs.
    plus_start = text.index('static void\nGreenQuicPlusDirectionalPressure(')
    compute_start = text.index('\nstatic uint32_t\nGreenQuicComputeRawPressure(', plus_start)
    plus_code = r'''static void
GreenQuicPlusDirectionalPressure(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ uint64_t RxHints,
    _In_ uint64_t TxHints,
    _In_ uint32_t RxPhysicalRaw,
    _In_ uint32_t TxPhysicalRaw,
    _In_ uint32_t RxPhysicalControl,
    _In_ uint32_t TxPhysicalControl,
    _In_ BOOLEAN OwnsRx,
    _In_ BOOLEAN OwnsTx,
    _Out_ uint32_t* RxQuicFloor,
    _Out_ uint32_t* TxQuicFloor,
    _Out_ BOOLEAN* RxHardMax,
    _Out_ BOOLEAN* TxHardMax
    )
{
    *RxQuicFloor = 0;
    *TxQuicFloor = 0;
    *RxHardMax = FALSE;
    *TxHardMax = FALSE;
    if (Dpdk->GreenQuicMode != GREENQUIC_MODE_PLUS) {
        return;
    }

    // ACK floor: 600 for a downloading client reaches the up boundary; 550 in
    // other profiles keeps polling active but normally avoids an up step.
    if (OwnsTx && (TxHints & GQPLUS_HINT_ACK_PENDING) != 0) {
        const uint32_t AckFloor =
            Dpdk->GreenQuicProfile == GREENQUIC_PROFILE_CLIENT_DOWNLOAD ?
                Dpdk->GreenQuicAckClientFloor :
                Dpdk->GreenQuicAckOtherFloor;
        *TxQuicFloor = GreenQuicMaxU32(*TxQuicFloor, AckFloor);
        if (Dpdk->GreenQuicEnableAckRxHardMax && OwnsRx &&
            RxPhysicalRaw >= Dpdk->GreenQuicAckRxHardMaxThreshold) {
            *RxHardMax = TRUE;
        }
    }

    // Recovery is stronger than ordinary up pressure. It becomes immediate max
    // only when real current physical work also crosses its tunable threshold.
    if (OwnsRx && (RxHints & GQPLUS_HINT_CUBIC_RECOVERY) != 0) {
        *RxQuicFloor = GreenQuicMaxU32(
            *RxQuicFloor, Dpdk->GreenQuicRecoveryFloor);
        if (Dpdk->GreenQuicEnableRecoveryHardMax &&
            RxPhysicalRaw >=
                Dpdk->GreenQuicRecoveryHardMaxPhysicalThreshold) {
            *RxHardMax = TRUE;
        }
    }
    if (OwnsTx && (TxHints & GQPLUS_HINT_CUBIC_RECOVERY) != 0) {
        *TxQuicFloor = GreenQuicMaxU32(
            *TxQuicFloor, Dpdk->GreenQuicRecoveryFloor);
        if (Dpdk->GreenQuicEnableRecoveryHardMax &&
            TxPhysicalRaw >=
                Dpdk->GreenQuicRecoveryHardMaxPhysicalThreshold) {
            *TxHardMax = TRUE;
        }
    }

    // Cwnd growth is predictive. Use the lower floor with no physical TX work;
    // upgrade to the up-boundary floor only when current/recent TX work exists.
    if (OwnsTx && (TxHints & GQPLUS_HINT_CUBIC_RAMPING) != 0) {
        const uint32_t PhysicalEvidence = GreenQuicMaxU32(
            TxPhysicalRaw, TxPhysicalControl);
        const uint32_t GrowthFloor =
            PhysicalEvidence >= Dpdk->GreenQuicCwndGrowthPhysicalThreshold ?
                Dpdk->GreenQuicCwndGrowthWorkFloor :
                Dpdk->GreenQuicCwndGrowthNoWorkFloor;
        *TxQuicFloor = GreenQuicMaxU32(*TxQuicFloor, GrowthFloor);
    }

    // A blocked sender is waiting, not performing local work. Default floor is
    // zero; the value remains tunable for controlled experiments.
    if (OwnsRx && (RxHints & GQPLUS_HINT_CUBIC_CWND_BLOCKED) != 0) {
        *RxQuicFloor = GreenQuicMaxU32(
            *RxQuicFloor, Dpdk->GreenQuicBlockedRxFloor);
    }

    // Active file-transfer hints deliberately add no frequency floor. Real
    // burst/backlog EWMAs control frequency; transfer state only deepens sleep.
    (void)RxPhysicalControl;
}
'''
    text = text[:plus_start] + plus_code + text[compute_start:]

    # Measurement stage: normalize raw physical signals only. No moving average
    # is applied here and no QUIC floor is mixed into physical history.
    compute_start = text.index('static uint32_t\nGreenQuicComputeRawPressure(')
    apply_start = text.index('\nstatic void\nGreenQuicApplyPolicy(', compute_start)
    compute_code = r'''static uint32_t
GreenQuicComputeRawPressure(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ GREENQUIC_LCORE_STATE* S,
    _In_ uint16_t Core,
    _In_ uint32_t TxRingCount,
    _Out_ BOOLEAN* HardMax
    )
{
    const BOOLEAN OwnsRx = GreenQuicLcoreOwnsRx(Dpdk, Core);
    const BOOLEAN OwnsTx = GreenQuicLcoreOwnsTx(Dpdk, Core);

    S->LastRxBurstPressure = OwnsRx ?
        GreenQuicPressureFromRatioConfigured(
            Dpdk, S->Rx.LastBurstCount, RX_BURST_SIZE) : 0U;
    S->LastRxQueuePressure = OwnsRx ?
        GreenQuicPressureFromRatioConfigured(
            Dpdk, S->Rx.LastQueueCount, Dpdk->GreenQuicRxQueueHigh) : 0U;
    S->LastTxBurstPressure = OwnsTx ?
        GreenQuicPressureFromRatioConfigured(
            Dpdk, S->Tx.LastBurstCount, TX_BURST_SIZE) : 0U;

    const uint32_t TxRingNowPressure = OwnsTx ?
        GreenQuicPressureFromRatioConfigured(
            Dpdk, TxRingCount, Dpdk->GreenQuicTxRingHigh) : 0U;
    const uint32_t TxRingLastPressure = OwnsTx ?
        GreenQuicPressureFromRatioConfigured(
            Dpdk, S->Tx.LastQueueCount, Dpdk->GreenQuicTxRingHigh) : 0U;
    S->LastTxRingPressure = GreenQuicMaxU32(
        TxRingNowPressure, TxRingLastPressure);

    // These compatibility fields are raw physical maxima, not EWMAs.
    S->LastRxPressure = GreenQuicMaxU32(
        S->LastRxBurstPressure, S->LastRxQueuePressure);
    S->LastTxPressure = GreenQuicMaxU32(
        S->LastTxBurstPressure, S->LastTxRingPressure);

    BOOLEAN RxHardMax =
        Dpdk->GreenQuicEnablePhysicalHardMax && OwnsRx &&
        S->LastRxQueuePressure >= Dpdk->GreenQuicPressureMaxThreshold;
    BOOLEAN TxHardMax =
        Dpdk->GreenQuicEnablePhysicalHardMax && OwnsTx &&
        S->LastTxPressure >= Dpdk->GreenQuicPressureMaxThreshold;

    uint64_t RxHints = 0;
    uint64_t TxHints = 0;
    GreenQuicGetDirectionalHintsForCore(
        Dpdk, S, Core, &RxHints, &TxHints);
    S->LastRxHints = OwnsRx ? RxHints : 0U;
    S->LastTxHints = OwnsTx ? TxHints : 0U;
    S->LastHints = S->LastRxHints | S->LastTxHints;
    S->LastTxRingCount = OwnsTx ? TxRingCount : 0U;
    S->LastOwnsRx = OwnsRx;
    S->LastOwnsTx = OwnsTx;
    S->LastRxHardMax = RxHardMax;
    S->LastTxHardMax = TxHardMax;
    S->LastHardMax = RxHardMax || TxHardMax;
    *HardMax = S->LastHardMax;

    return GreenQuicMaxU32(S->LastRxPressure, S->LastTxPressure);
}
'''
    text = text[:compute_start] + compute_code + text[apply_start:]

    # Control stage: update one EWMA per physical signal, combine by signal
    # nature, then apply direct QUIC floors and finally choose one lcore action.
    apply_start = text.index('static void\nGreenQuicApplyPolicy(')
    stats_start = text.index('\nstatic void\nGreenQuicMaybePrintStats(', apply_start)
    apply_code = r'''static void
GreenQuicApplyPolicy(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_ DPDK_INTERFACE* Interface,
    _In_ uint16_t Core
    )
{
    if (Dpdk->GreenQuicMode == GREENQUIC_MODE_OFF) {
        return;
    }

    GreenQuicMaybePrintStats(Dpdk, Core);
    const BOOLEAN OwnsRx = GreenQuicLcoreOwnsRx(Dpdk, Core);
    const BOOLEAN OwnsTx = GreenQuicLcoreOwnsTx(Dpdk, Core);
    const uint32_t TxRingCount = OwnsTx ?
        rte_ring_count(Interface->TxRingBuffer) : 0U;
    GREENQUIC_LCORE_STATE* S = GreenQuicGetLcoreState(Dpdk, Core);

    BOOLEAN HardMax = FALSE;
    (void)GreenQuicComputeRawPressure(
        Dpdk, S, Core, TxRingCount, &HardMax);

    // BURST EWMAs: fast rise and fast fall. Bursts are instantaneous samples and
    // should not keep frequency elevated through a genuine inter-chunk gap.
    if (OwnsRx) {
        S->RxBurstPressureAvg = GreenQuicUpdateEwmaAlpha(
            Dpdk,
            S->RxBurstPressureAvg,
            S->LastRxBurstPressure,
            Dpdk->GreenQuicRxBurstRiseAlphaPermille,
            Dpdk->GreenQuicRxBurstFallAlphaPermille);
        // QUEUE EWMA: immediate/fast rise and slower fall. Persistent backlog is
        // stronger evidence that service capacity is insufficient.
        S->RxQueuePressureAvg = GreenQuicUpdateEwmaAlpha(
            Dpdk,
            S->RxQueuePressureAvg,
            S->LastRxQueuePressure,
            Dpdk->GreenQuicRxQueueRiseAlphaPermille,
            Dpdk->GreenQuicRxQueueFallAlphaPermille);
    } else {
        S->RxBurstPressureAvg = 0U;
        S->RxQueuePressureAvg = 0U;
    }

    if (OwnsTx) {
        S->TxBurstPressureAvg = GreenQuicUpdateEwmaAlpha(
            Dpdk,
            S->TxBurstPressureAvg,
            S->LastTxBurstPressure,
            Dpdk->GreenQuicTxBurstRiseAlphaPermille,
            Dpdk->GreenQuicTxBurstFallAlphaPermille);
        S->TxRingPressureAvg = GreenQuicUpdateEwmaAlpha(
            Dpdk,
            S->TxRingPressureAvg,
            S->LastTxRingPressure,
            Dpdk->GreenQuicTxRingRiseAlphaPermille,
            Dpdk->GreenQuicTxRingFallAlphaPermille);
    } else {
        S->TxBurstPressureAvg = 0U;
        S->TxRingPressureAvg = 0U;
    }

    uint32_t RxPhysicalControl = OwnsRx ? GreenQuicMaxU32(
        S->RxBurstPressureAvg, S->RxQueuePressureAvg) : 0U;
    uint32_t TxPhysicalControl = OwnsTx ? GreenQuicMaxU32(
        S->TxBurstPressureAvg, S->TxRingPressureAvg) : 0U;

    // Optional experimental full-burst floor. Default zero disables it because
    // repeated full bursts are already represented by the burst EWMA.
    if (OwnsRx && Dpdk->GreenQuicFullBurstFloor != 0 &&
        S->Rx.ConsecutiveFull >= Dpdk->GreenQuicFullBurstMaxCount) {
        RxPhysicalControl = GreenQuicMaxU32(
            RxPhysicalControl, Dpdk->GreenQuicFullBurstFloor);
    }
    if (OwnsTx && Dpdk->GreenQuicFullBurstFloor != 0 &&
        S->Tx.ConsecutiveFull >= Dpdk->GreenQuicFullBurstMaxCount) {
        TxPhysicalControl = GreenQuicMaxU32(
            TxPhysicalControl, Dpdk->GreenQuicFullBurstFloor);
    }
    S->LastRxPhysicalControl = RxPhysicalControl;
    S->LastTxPhysicalControl = TxPhysicalControl;

    uint32_t RxQuicFloor = 0U;
    uint32_t TxQuicFloor = 0U;
    BOOLEAN RxQuicHardMax = FALSE;
    BOOLEAN TxQuicHardMax = FALSE;
    GreenQuicPlusDirectionalPressure(
        Dpdk,
        S->LastRxHints,
        S->LastTxHints,
        S->LastRxPressure,
        S->LastTxPressure,
        RxPhysicalControl,
        TxPhysicalControl,
        OwnsRx,
        OwnsTx,
        &RxQuicFloor,
        &TxQuicFloor,
        &RxQuicHardMax,
        &TxQuicHardMax);

    S->LastRxQuicPressure = OwnsRx ? RxQuicFloor : 0U;
    S->LastTxQuicPressure = OwnsTx ? TxQuicFloor : 0U;
    S->LastPlusPressure = GreenQuicMaxU32(
        S->LastRxQuicPressure, S->LastTxQuicPressure);
    S->LastRxControlPressure = OwnsRx ? GreenQuicMaxU32(
        RxPhysicalControl, RxQuicFloor) : 0U;
    S->LastTxControlPressure = OwnsTx ? GreenQuicMaxU32(
        TxPhysicalControl, TxQuicFloor) : 0U;

    // Legacy names retained: these are now direct directional control pressures,
    // not another EWMA. No semantic hint is allowed to contaminate physical EWMA.
    S->RxPressureAvg = S->LastRxControlPressure;
    S->TxPressureAvg = S->LastTxControlPressure;
    S->LastRxRawPressure = S->LastRxControlPressure;
    S->LastTxRawPressure = S->LastTxControlPressure;
    S->LastRawPressure = GreenQuicMaxU32(
        S->LastRxControlPressure, S->LastTxControlPressure);
    S->PressureAvg = GreenQuicMaxU32(
        OwnsRx ? S->LastRxControlPressure : 0U,
        OwnsTx ? S->LastTxControlPressure : 0U);

    S->LastRxHardMax = S->LastRxHardMax || RxQuicHardMax;
    S->LastTxHardMax = S->LastTxHardMax || TxQuicHardMax;
    S->LastHardMax = S->LastRxHardMax || S->LastTxHardMax;
    HardMax = S->LastHardMax;

    if (HardMax) {
        S->LastAction = "freq_max_hard";
        GreenQuicFreqMax(Dpdk, Core);
        return;
    }
    if (S->PressureAvg >= Dpdk->GreenQuicPressureMaxThreshold) {
        S->LastAction = "freq_max_control";
        GreenQuicFreqMax(Dpdk, Core);
        return;
    }
    if (S->PressureAvg >= Dpdk->GreenQuicPressureUpThreshold) {
        S->LastAction = "freq_up";
        GreenQuicFreqUpStep(Dpdk, Core);
        return;
    }
    if (S->PressureAvg >= Dpdk->GreenQuicPressureKeepThreshold) {
        S->LastAction = "keep_pause";
        rte_pause();
        return;
    }

    const BOOLEAN RxEmptyEnough =
        !OwnsRx ||
        S->Rx.ConsecutiveEmpty >= Dpdk->GreenQuicRxEmptyPollThreshold;
    const BOOLEAN TxEmptyEnough =
        !OwnsTx ||
        S->Tx.ConsecutiveEmpty >= Dpdk->GreenQuicTxEmptyPollThreshold;
    if (!RxEmptyEnough || !TxEmptyEnough) {
        S->LastAction = "short_idle_pause";
        rte_pause();
        return;
    }

    if (OwnsTx && Dpdk->GreenQuicTxRingProtectUp &&
        Dpdk->GreenQuicNoSleepIfTxRingNotEmpty && TxRingCount > 0) {
        S->LastAction = "txring_protect_up";
        GreenQuicFreqUpStep(Dpdk, Core);
        return;
    }

    uint64_t LastActive = 0U;
    if (OwnsRx) {
        LastActive = S->Rx.LastActiveTsc;
    }
    if (OwnsTx && S->Tx.LastActiveTsc > LastActive) {
        LastActive = S->Tx.LastActiveTsc;
    }
    const uint64_t Now = rte_get_tsc_cycles();
    const uint64_t IdleUs = LastActive == 0 ? UINT64_MAX :
        GreenQuicTscDeltaToUs(Now - LastActive);

    if (IdleUs >= Dpdk->GreenQuicFreqMinIdleUs) {
        S->LastAction = "freq_min";
        GreenQuicFreqMin(Dpdk, Core);
    } else {
        S->LastAction = "freq_down";
        GreenQuicFreqDownStep(Dpdk, Core);
    }

    const uint32_t SleepBudgetUs = GreenQuicGetSleepBudgetUs(
        Dpdk,
        S,
        TxRingCount,
        S->LastRxHints,
        S->LastTxHints,
        OwnsRx,
        OwnsTx);
    if (SleepBudgetUs != 0) {
        S->LastAction = "sleep";
        GreenQuicSleepUs(Dpdk, Core, SleepBudgetUs);
    }
}
'''
    text = text[:apply_start] + apply_code + text[stats_start:]

    # Expanded stats make every combination visible during experiments.
    stats_start = text.index('static void\nGreenQuicMaybePrintStats(')
    stats_end = text.index('\n// GREENQUIC-END', stats_start)
    stats_code = r'''static void
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
    printf(
        "GreenQUIC lcore=%u owns_rx=%u owns_tx=%u mode=%s profile=%s "
        "action=%s hardmax=%u rxhard=%u txhard=%u control=%u "
        "rxctrl=%u txctrl=%u rxphysctrl=%u txphysctrl=%u "
        "rxburstp=%u rxqueuep=%u txburstp=%u txringp=%u "
        "rxbursta=%u rxqueuea=%u txbursta=%u txringa=%u "
        "rxfloor=%u txfloor=%u rxh=0x%" PRIx64 " txh=0x%" PRIx64 " "
        "txring=%u rxq=%u rx_pkts=%" PRIu64 " tx_pkts=%" PRIu64 " "
        "rx_empty=%u tx_empty=%u rx_full=%u tx_full=%u slept_us=%" PRIu64 "\n",
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
        S->TotalSleepUs);
}
'''
    text = text[:stats_start] + stats_code + text[stats_end:]

    # Let the legacy dpdk.ini parser set the old shared shift and also translate
    # it into all new alphas for backward compatibility.
    config_start = text.index('void\nCxPlatDpdkReadConfig(')
    config_end = text.index('\n_IRQL_requires_max_(PASSIVE_LEVEL)\nsize_t\nCxPlatDpRawGetDatapathSize(', config_start)
    config_text = text[config_start:config_end]
    old_rise = '            Dpdk->GreenQuicEwmaRiseShift = (uint32_t)atoi(Value);\n'
    new_rise = old_rise + r'''            {
                const uint32_t Alpha = GreenQuicAlphaPermilleFromShift(
                    Dpdk->GreenQuicEwmaRiseShift);
                Dpdk->GreenQuicRxBurstRiseAlphaPermille = Alpha;
                Dpdk->GreenQuicRxQueueRiseAlphaPermille = Alpha;
                Dpdk->GreenQuicTxBurstRiseAlphaPermille = Alpha;
                Dpdk->GreenQuicTxRingRiseAlphaPermille = Alpha;
            }
'''
    old_fall = '            Dpdk->GreenQuicEwmaFallShift = (uint32_t)atoi(Value);\n'
    new_fall = old_fall + r'''            {
                const uint32_t Alpha = GreenQuicAlphaPermilleFromShift(
                    Dpdk->GreenQuicEwmaFallShift);
                Dpdk->GreenQuicRxBurstFallAlphaPermille = Alpha;
                Dpdk->GreenQuicRxQueueFallAlphaPermille = Alpha;
                Dpdk->GreenQuicTxBurstFallAlphaPermille = Alpha;
                Dpdk->GreenQuicTxRingFallAlphaPermille = Alpha;
            }
'''
    if old_rise in config_text:
        config_text = config_text.replace(old_rise, new_rise, 1)
    if old_fall in config_text:
        config_text = config_text.replace(old_fall, new_fall, 1)

    # powermng.ini is always read last and therefore overrides legacy dpdk.ini.
    null_block = '''    if (File == NULL) {
        return;
    }
'''
    if null_block not in config_text:
        raise RuntimeError('Separated-signal patch could not find dpdk.ini NULL block')
    config_text = config_text.replace(
        null_block,
        '''    if (File == NULL) {
        GreenQuicReadPowerConfig(Dpdk);
        return;
    }
''',
        1)
    close_pos = config_text.rfind('    fclose(File);\n')
    if close_pos < 0:
        raise RuntimeError('Separated-signal patch could not find dpdk.ini fclose')
    close_end = close_pos + len('    fclose(File);\n')
    config_text = (
        config_text[:close_end] +
        '    GreenQuicReadPowerConfig(Dpdk);\n' +
        config_text[close_end:])
    text = text[:config_start] + config_text + text[config_end:]

    write_text(path, text)

    # Keep dpdk.ini for mode/profile/topology and put every power knob here.
    write_new_or_replace(repo / 'powermng.example.ini', POWER_MNG_INI_V18)
    power_ini = repo / 'powermng.ini'
    if not power_ini.exists():
        write_text(power_ini, POWER_MNG_INI_V18)
    else:
        log('Preserving existing powermng.ini; powermng.example.ini was refreshed.')

    dpdk_example = repo / 'dpdk.greenquic.example.ini'
    if dpdk_example.exists():
        ini_text = read_text(dpdk_example)
        note = r'''

# V18 separated power configuration:
# All pressure thresholds, physical EWMAs, QUIC floors, DVFS timing and sleep
# values are loaded from ./powermng.ini after this file. Override its location:
#   export GREENQUIC_POWER_CONFIG=/absolute/path/to/powermng.ini
# Values left here remain backward-compatible defaults but powermng.ini wins.
'''
        if 'V18 separated power configuration' not in ini_text:
            ini_text += note
            write_text(dpdk_example, ini_text)

    log(
        'V18 separated-signal policy patched: RX burst/queue and TX burst/ring '
        'have independent EWMAs; QUIC hints are direct configurable floors; '
        'powermng.ini contains all power-policy knobs.')


# =============================================================================
# V19 safe speculative C-state opportunity
# =============================================================================
#
# This section extends the complete V18 autopatcher without deleting or replacing
# any of the V18 RX/TX pressure, EWMA, QUIC-floor, role, build, or tool logic.
#
# Important semantics:
#   * The application never requests a named hardware C-state such as C3/C6.
#   * When explicitly enabled, it uses DPDK rte_power_pause() for a bounded TSC
#     interval after strict idle checks. Linux CPUIdle / the processor decides the
#     actual state based on target residency, exit latency, BIOS and kernel policy.
#   * The feature is OFF by default. This is intentional: a bounded pause cannot
#     be woken by rte_power_monitor_wakeup(), and a TX producer may enqueue work
#     after the final check. Users must validate latency before enabling it.
#   * Existing 1-2 us software sleeps remain unchanged and are the fallback.
#
# The defaults below are conservative. The optional 300 us tier is long enough to
# provide a meaningful C-state opportunity on some systems, but TX owners are
# capped at 50 us by default because new QUIC output can be enqueued asynchronously.
POWER_MNG_INI_V19_CSTATE = POWER_MNG_INI_V18 + r'''

# =============================================================================
# V19 optional C-state opportunity (safe, bounded, disabled by default)
# =============================================================================
# This does NOT select C1/C3/C6 directly. When supported, rte_power_pause() stops
# busy execution until a bounded TSC deadline; CPUIdle/hardware chooses the state.
# Keep disabled until throughput, ACK latency, recovery and TTFB are validated.
GreenQuicEnableCStateIdle=0

# Require sustained inactivity before attempting the optimized wait. This is in
# addition to pressure, empty-poll, TX-ring and QUIC-hint checks.
GreenQuicCStateMinIdleUs=20000

# EmptyLevel = min(owned_direction_consecutive_empty / direction_threshold).
# The first tier requests a short optimized wait; the second permits the longer
# C-state opportunity. These are confidence levels, not hardware C-state numbers.
GreenQuicCStateMinLevel=16
GreenQuicCStateDeepMinLevel=64

# Bounded wait durations. Start with 25-50 us in latency-sensitive experiments.
# A 300 us tier is provided for long confirmed idle only.
GreenQuicCStateWaitUs=50
GreenQuicCStateDeepWaitUs=300
GreenQuicCStateMaxWaitUs=300

# TX producers run on other MsQuic workers. rte_power_pause() has no explicit
# software wake API, so cap TX-owner waits much more tightly by default.
GreenQuicCStateTxOwnerMaxWaitUs=50

# Active transfer hints indicate that another chunk may arrive soon. Default 0
# forbids the C-state wait during an active transfer; existing 1-2 us sleeps may
# still be used according to the V18 policy.
GreenQuicCStateAllowDuringActiveTransfer=0
'''


def patch_safe_cstate_idle(repo: Path) -> None:
    '''Add an opt-in, bounded C-state opportunity without disturbing V18.

    Safety model:
      1. Existing V18 pressure, ownership and QUIC blockers remain authoritative.
      2. The feature is disabled by default.
      3. Runtime support for rte_power_pause() is checked before use.
      4. RX/TX work and semantic blockers are checked again immediately before
         the optimized wait.
      5. TX-owner waits are separately capped because software TX work can arrive
         asynchronously and rte_power_pause() cannot be explicitly woken.
      6. Unsupported platforms transparently retain the original V18 short-sleep
         path; there is no illegal-instruction risk.
    '''
    path = repo / 'src/platform/datapath_raw_dpdk.c'
    text = read_text(path)
    marker = '// GREENQUIC-V19-SAFE-CSTATE-IDLE'
    if marker in text:
        log('V19 safe C-state patch already present; skipping.')
        return

    log('Applying V19 opt-in bounded C-state opportunity (disabled by default).')

    # Optional include guards keep older DPDK trees buildable. The runtime check
    # remains mandatory even when the headers and symbols are available.
    include_anchor = '#include <rte_power.h>\n'
    if include_anchor not in text:
        raise RuntimeError('V19 could not find rte_power.h include anchor')
    include_code = r'''#include <rte_power.h>
// GREENQUIC-V19-SAFE-CSTATE-IDLE
// rte_power_pause() is optional and architecture-dependent. Do not assume that
// presence of the header means the current CPU/kernel supports the instruction.
#if defined(__has_include)
#if __has_include(<rte_power_intrinsics.h>) && __has_include(<rte_cpuflags.h>)
#include <rte_power_intrinsics.h>
#include <rte_cpuflags.h>
#define GREENQUIC_HAVE_POWER_PAUSE_API 1
#endif
#endif
#ifndef GREENQUIC_HAVE_POWER_PAUSE_API
#define GREENQUIC_HAVE_POWER_PAUSE_API 0
#endif
'''
    text = text.replace(include_anchor, include_code, 1)

    # Per-lcore counters are diagnostics only. Existing V18 state is retained.
    state_anchor = '    uint64_t TotalSleepUs;\n'
    if state_anchor not in text:
        raise RuntimeError('V19 could not find TotalSleepUs state anchor')
    state_code = r'''    uint64_t TotalSleepUs;
    // GREENQUIC-V19-SAFE-CSTATE-IDLE: optimized-wait diagnostics.
    uint64_t CStateAttempts;
    uint64_t CStateSuccesses;
    uint64_t TotalCStateWaitUs;
    uint32_t LastCStateWaitUs;
    BOOLEAN CStateUnavailable;
'''
    text = text.replace(state_anchor, state_code, 1)

    # Global runtime configuration and one-time capability result.
    cfg_anchor = '    BOOLEAN GreenQuicTxRingProtectUp;\n'
    if cfg_anchor not in text:
        raise RuntimeError('V19 could not find V18 config anchor')
    cfg_code = r'''    BOOLEAN GreenQuicTxRingProtectUp;
    // GREENQUIC-V19-SAFE-CSTATE-IDLE. This is an optional bounded wait, not a
    // direct C-state selector. It is deliberately disabled by default.
    BOOLEAN GreenQuicEnableCStateIdle;
    BOOLEAN GreenQuicCStateAllowDuringActiveTransfer;
    BOOLEAN GreenQuicCStatePowerPauseSupported;
    uint32_t GreenQuicCStateMinIdleUs;
    uint32_t GreenQuicCStateMinLevel;
    uint32_t GreenQuicCStateDeepMinLevel;
    uint32_t GreenQuicCStateWaitUs;
    uint32_t GreenQuicCStateDeepWaitUs;
    uint32_t GreenQuicCStateMaxWaitUs;
    uint32_t GreenQuicCStateTxOwnerMaxWaitUs;
'''
    text = text.replace(cfg_anchor, cfg_code, 1)

    defaults_anchor = '    Dpdk->GreenQuicTxRingProtectUp = TRUE;\n'
    if defaults_anchor not in text:
        raise RuntimeError('V19 could not find defaults anchor')
    defaults_code = r'''    Dpdk->GreenQuicTxRingProtectUp = TRUE;
    // GREENQUIC-V19-SAFE-CSTATE-IDLE defaults. OFF is the safe default because
    // rte_power_pause() is deadline-wakeable, not software-wakeable.
    Dpdk->GreenQuicEnableCStateIdle = FALSE;
    Dpdk->GreenQuicCStateAllowDuringActiveTransfer = FALSE;
    Dpdk->GreenQuicCStatePowerPauseSupported = FALSE;
    Dpdk->GreenQuicCStateMinIdleUs = 20000U;
    Dpdk->GreenQuicCStateMinLevel = 16U;
    Dpdk->GreenQuicCStateDeepMinLevel = 64U;
    Dpdk->GreenQuicCStateWaitUs = 50U;
    Dpdk->GreenQuicCStateDeepWaitUs = 300U;
    Dpdk->GreenQuicCStateMaxWaitUs = 300U;
    Dpdk->GreenQuicCStateTxOwnerMaxWaitUs = 50U;
'''
    text = text.replace(defaults_anchor, defaults_code, 1)

    # Prototypes are inserted next to the active V18 sleep helpers.
    proto_anchor = 'static uint32_t GreenQuicGetSleepBudgetUs(_In_ const DPDK_DATAPATH* Dpdk, _In_ const GREENQUIC_LCORE_STATE* S, _In_ uint32_t TxRingCount, _In_ uint64_t RxHints, _In_ uint64_t TxHints, _In_ BOOLEAN OwnsRx, _In_ BOOLEAN OwnsTx);\n'
    if proto_anchor not in text:
        raise RuntimeError('V19 could not find sleep prototype anchor')
    proto_code = proto_anchor + r'''static void GreenQuicInitCStateSupport(_Inout_ DPDK_DATAPATH* Dpdk);
static uint32_t GreenQuicGetEmptyLevel(_In_ const DPDK_DATAPATH* Dpdk, _In_ const GREENQUIC_LCORE_STATE* S, _In_ BOOLEAN OwnsRx, _In_ BOOLEAN OwnsTx);
static BOOLEAN GreenQuicCStateHintsBlock(_In_ const DPDK_DATAPATH* Dpdk, _In_ uint64_t RxHints, _In_ uint64_t TxHints, _In_ BOOLEAN OwnsRx, _In_ BOOLEAN OwnsTx);
static BOOLEAN GreenQuicTryCStateIdle(_Inout_ DPDK_DATAPATH* Dpdk, _In_ DPDK_INTERFACE* Interface, _Inout_ GREENQUIC_LCORE_STATE* S, _In_ uint16_t Core, _In_ uint64_t IdleUs, _In_ BOOLEAN OwnsRx, _In_ BOOLEAN OwnsTx);
'''
    text = text.replace(proto_anchor, proto_code, 1)

    # Add parser entries before the V18 parser undefines its helper macros.
    parser_anchor = '#undef GQ_U32\n#undef GQ_BOOL\n'
    if parser_anchor not in text:
        raise RuntimeError('V19 could not find power parser macro anchor')
    parser_code = r'''    // GREENQUIC-V19-SAFE-CSTATE-IDLE runtime values.
    GQ_BOOL("GreenQuicEnableCStateIdle", GreenQuicEnableCStateIdle)
    GQ_BOOL("GreenQuicCStateAllowDuringActiveTransfer", GreenQuicCStateAllowDuringActiveTransfer)
    GQ_U32("GreenQuicCStateMinIdleUs", GreenQuicCStateMinIdleUs)
    GQ_U32("GreenQuicCStateMinLevel", GreenQuicCStateMinLevel)
    GQ_U32("GreenQuicCStateDeepMinLevel", GreenQuicCStateDeepMinLevel)
    GQ_U32("GreenQuicCStateWaitUs", GreenQuicCStateWaitUs)
    GQ_U32("GreenQuicCStateDeepWaitUs", GreenQuicCStateDeepWaitUs)
    GQ_U32("GreenQuicCStateMaxWaitUs", GreenQuicCStateMaxWaitUs)
    GQ_U32("GreenQuicCStateTxOwnerMaxWaitUs", GreenQuicCStateTxOwnerMaxWaitUs)

#undef GQ_U32
#undef GQ_BOOL
'''
    text = text.replace(parser_anchor, parser_code, 1)

    # Structural sanitation prevents accidental unbounded waits or inverted tiers.
    sanitize_anchor = '''    if (Dpdk->GreenQuicLogLevel > 2U) {
        Dpdk->GreenQuicLogLevel = 2U;
    }
}
'''
    if sanitize_anchor not in text:
        raise RuntimeError('V19 could not find power-config sanitation anchor')
    sanitize_code = r'''    if (Dpdk->GreenQuicLogLevel > 2U) {
        Dpdk->GreenQuicLogLevel = 2U;
    }

    // GREENQUIC-V19-SAFE-CSTATE-IDLE sanitation. Zero max disables the path.
    if (Dpdk->GreenQuicCStateMinLevel == 0U) {
        Dpdk->GreenQuicCStateMinLevel = 1U;
    }
    if (Dpdk->GreenQuicCStateDeepMinLevel <
        Dpdk->GreenQuicCStateMinLevel) {
        Dpdk->GreenQuicCStateDeepMinLevel =
            Dpdk->GreenQuicCStateMinLevel;
    }
    if (Dpdk->GreenQuicCStateWaitUs >
        Dpdk->GreenQuicCStateMaxWaitUs) {
        Dpdk->GreenQuicCStateWaitUs =
            Dpdk->GreenQuicCStateMaxWaitUs;
    }
    if (Dpdk->GreenQuicCStateDeepWaitUs >
        Dpdk->GreenQuicCStateMaxWaitUs) {
        Dpdk->GreenQuicCStateDeepWaitUs =
            Dpdk->GreenQuicCStateMaxWaitUs;
    }
    if (Dpdk->GreenQuicCStateTxOwnerMaxWaitUs >
        Dpdk->GreenQuicCStateMaxWaitUs) {
        Dpdk->GreenQuicCStateTxOwnerMaxWaitUs =
            Dpdk->GreenQuicCStateMaxWaitUs;
    }
}
'''
    text = text.replace(sanitize_anchor, sanitize_code, 1)

    # Capability detection is run after the final power configuration is loaded.
    # The function is harmless when the feature is disabled.
    call = '        GreenQuicReadPowerConfig(Dpdk);\n'
    if text.count(call) < 1:
        raise RuntimeError('V19 could not find missing-dpdk.ini power-config call')
    text = text.replace(
        call,
        call + '        GreenQuicInitCStateSupport(Dpdk);\n',
        1)
    call2 = '    GreenQuicReadPowerConfig(Dpdk);\n'
    # Replace the later normal-file path but not the already-indented call above.
    normal_index = text.rfind(call2)
    if normal_index < 0:
        raise RuntimeError('V19 could not find normal power-config call')
    text = (
        text[:normal_index] + call2 +
        '    GreenQuicInitCStateSupport(Dpdk);\n' +
        text[normal_index + len(call2):])

    # Place helper implementations immediately before RX polling helpers. The
    # existing V18 short-sleep function and budget are not removed.
    helper_anchor = '\nstatic void\nGreenQuicOnRxPoll('
    helper_pos = text.index(helper_anchor)
    helper_code = r'''

// GREENQUIC-V19-SAFE-CSTATE-IDLE
static void
GreenQuicInitCStateSupport(
    _Inout_ DPDK_DATAPATH* Dpdk
    )
{
    Dpdk->GreenQuicCStatePowerPauseSupported = FALSE;
#if GREENQUIC_HAVE_POWER_PAUSE_API
    if (Dpdk->GreenQuicEnableCStateIdle) {
        struct rte_cpu_intrinsics Intrinsics = {0};
        rte_cpu_get_intrinsics_support(&Intrinsics);
        Dpdk->GreenQuicCStatePowerPauseSupported =
            Intrinsics.power_pause ? TRUE : FALSE;
        if (!Dpdk->GreenQuicCStatePowerPauseSupported) {
            printf(
                "GreenQUIC: C-state idle requested but rte_power_pause is not "
                "supported; retaining V18 short-sleep path.\n");
        }
    }
#else
    if (Dpdk->GreenQuicEnableCStateIdle) {
        printf(
            "GreenQUIC: C-state idle requested but this DPDK build has no "
            "power-intrinsics API; retaining V18 short-sleep path.\n");
    }
#endif
}

static uint32_t
GreenQuicGetEmptyLevel(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ const GREENQUIC_LCORE_STATE* S,
    _In_ BOOLEAN OwnsRx,
    _In_ BOOLEAN OwnsTx
    )
{
    uint32_t EmptyLevel = UINT32_MAX;
    if (OwnsRx) {
        const uint32_t Threshold =
            Dpdk->GreenQuicRxEmptyPollThreshold == 0U ? 1U :
            Dpdk->GreenQuicRxEmptyPollThreshold;
        EmptyLevel = S->Rx.ConsecutiveEmpty / Threshold;
    }
    if (OwnsTx) {
        const uint32_t Threshold =
            Dpdk->GreenQuicTxEmptyPollThreshold == 0U ? 1U :
            Dpdk->GreenQuicTxEmptyPollThreshold;
        const uint32_t TxLevel = S->Tx.ConsecutiveEmpty / Threshold;
        EmptyLevel = OwnsRx ? GreenQuicMinU32(EmptyLevel, TxLevel) : TxLevel;
    }
    return EmptyLevel == UINT32_MAX ? 0U : EmptyLevel;
}

static BOOLEAN
GreenQuicCStateHintsBlock(
    _In_ const DPDK_DATAPATH* Dpdk,
    _In_ uint64_t RxHints,
    _In_ uint64_t TxHints,
    _In_ BOOLEAN OwnsRx,
    _In_ BOOLEAN OwnsTx
    )
{
    if ((OwnsRx && Dpdk->GreenQuicRecoveryBlocksSleep &&
         (RxHints & GQPLUS_HINT_CUBIC_RECOVERY) != 0U) ||
        (OwnsTx && Dpdk->GreenQuicAckBlocksSleep &&
         (TxHints & GQPLUS_HINT_ACK_PENDING) != 0U) ||
        (OwnsTx && Dpdk->GreenQuicRecoveryBlocksSleep &&
         (TxHints & GQPLUS_HINT_CUBIC_RECOVERY) != 0U) ||
        (OwnsTx && Dpdk->GreenQuicCwndGrowthBlocksSleep &&
         (TxHints & GQPLUS_HINT_CUBIC_RAMPING) != 0U)) {
        return TRUE;
    }

    const BOOLEAN ActiveRxTransfer =
        OwnsRx &&
        (RxHints & GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE) != 0U;
    const BOOLEAN ActiveTxTransfer =
        OwnsTx &&
        (TxHints & GQPLUS_HINT_SERVER_FILE_TX_ACTIVE) != 0U;
    return !Dpdk->GreenQuicCStateAllowDuringActiveTransfer &&
        (ActiveRxTransfer || ActiveTxTransfer);
}

static BOOLEAN
GreenQuicTryCStateIdle(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_ DPDK_INTERFACE* Interface,
    _Inout_ GREENQUIC_LCORE_STATE* S,
    _In_ uint16_t Core,
    _In_ uint64_t IdleUs,
    _In_ BOOLEAN OwnsRx,
    _In_ BOOLEAN OwnsTx
    )
{
    if (!Dpdk->GreenQuicEnableSleep ||
        !Dpdk->GreenQuicEnableCStateIdle ||
        !Dpdk->GreenQuicCStatePowerPauseSupported ||
        S->CStateUnavailable ||
        Dpdk->GreenQuicCStateMaxWaitUs == 0U ||
        IdleUs < Dpdk->GreenQuicCStateMinIdleUs ||
        S->PressureAvg >= Dpdk->GreenQuicPressureKeepThreshold) {
        return FALSE;
    }

    // First safety snapshot. Never wait over observed RX/TX work.
    if ((OwnsRx &&
         (S->Rx.LastBurstCount != 0U || S->Rx.LastQueueCount != 0U)) ||
        (OwnsTx &&
         (S->Tx.LastBurstCount != 0U ||
          rte_ring_count(Interface->TxRingBuffer) != 0U))) {
        return FALSE;
    }

    uint64_t RxHints = 0U;
    uint64_t TxHints = 0U;
    GreenQuicGetDirectionalHintsForCore(
        Dpdk, S, Core, &RxHints, &TxHints);
    if (GreenQuicCStateHintsBlock(
            Dpdk, RxHints, TxHints, OwnsRx, OwnsTx)) {
        return FALSE;
    }

    const uint32_t EmptyLevel =
        GreenQuicGetEmptyLevel(Dpdk, S, OwnsRx, OwnsTx);
    if (EmptyLevel < Dpdk->GreenQuicCStateMinLevel) {
        return FALSE;
    }

    uint32_t WaitUs =
        EmptyLevel >= Dpdk->GreenQuicCStateDeepMinLevel ?
            Dpdk->GreenQuicCStateDeepWaitUs :
            Dpdk->GreenQuicCStateWaitUs;
    WaitUs = GreenQuicMinU32(WaitUs, Dpdk->GreenQuicCStateMaxWaitUs);
    if (OwnsTx) {
        // A TX producer may enqueue after this check and rte_power_pause() has no
        // explicit wake API. Bound the maximum added TX latency independently.
        WaitUs = GreenQuicMinU32(
            WaitUs, Dpdk->GreenQuicCStateTxOwnerMaxWaitUs);
    }
    if (WaitUs == 0U) {
        return FALSE;
    }

    // Final race-reduction check immediately before entering the optimized wait.
    // This cannot eliminate arrivals after the check, which is why every wait is
    // bounded and the feature remains opt-in.
    rte_smp_rmb();
    if ((OwnsTx && rte_ring_count(Interface->TxRingBuffer) != 0U) ||
        (OwnsRx &&
         (S->Rx.LastBurstCount != 0U || S->Rx.LastQueueCount != 0U)) ||
        (OwnsTx && S->Tx.LastBurstCount != 0U)) {
        return FALSE;
    }
    uint64_t FinalRxHints = 0U;
    uint64_t FinalTxHints = 0U;
    GreenQuicGetDirectionalHintsForCore(
        Dpdk, S, Core, &FinalRxHints, &FinalTxHints);
    if (GreenQuicCStateHintsBlock(
            Dpdk, FinalRxHints, FinalTxHints, OwnsRx, OwnsTx)) {
        return FALSE;
    }

#if GREENQUIC_HAVE_POWER_PAUSE_API
    const uint64_t Hz = rte_get_tsc_hz();
    const uint64_t Delta =
        ((uint64_t)WaitUs * Hz + 999999U) / 1000000U;
    const uint64_t Deadline = rte_get_tsc_cycles() +
        (Delta == 0U ? 1U : Delta);
    ++S->CStateAttempts;
    const int Ret = rte_power_pause(Deadline);
    if (Ret == 0) {
        ++S->CStateSuccesses;
        S->LastCStateWaitUs = WaitUs;
        S->TotalCStateWaitUs += WaitUs;
        return TRUE;
    }

    // ENOTSUP can occur even after the runtime feature check because kernel or
    // architecture policy may reject the operation. Disable the optional path
    // only for this lcore; never disable V18 frequency or short software sleeps.
    if (Ret == -ENOTSUP || Ret == -EINVAL) {
        S->CStateUnavailable = TRUE;
    }
#else
    (void)Interface;
    (void)Core;
#endif
    return FALSE;
}
'''
    text = text[:helper_pos] + helper_code + text[helper_pos:]

    # Insert the optional wait after the normal V18 frequency action and before
    # the existing short-sleep budget. A successful optimized wait returns to the
    # worker loop immediately; otherwise the unchanged V18 sleep path executes.
    apply_anchor = '''    const uint32_t SleepBudgetUs = GreenQuicGetSleepBudgetUs(
        Dpdk,
        S,
        TxRingCount,
        S->LastRxHints,
        S->LastTxHints,
        OwnsRx,
        OwnsTx);
'''
    if apply_anchor not in text:
        raise RuntimeError('V19 could not find final V18 sleep call')
    apply_code = r'''    if (GreenQuicTryCStateIdle(
            Dpdk, Interface, S, Core, IdleUs, OwnsRx, OwnsTx)) {
        S->LastAction = "cstate_pause";
        return;
    }

''' + apply_anchor
    text = text.replace(apply_anchor, apply_code, 1)

    # Extend diagnostics without changing existing field names or parsers.
    stats_old = '"rx_empty=%u tx_empty=%u rx_full=%u tx_full=%u slept_us=%" PRIu64 "\\n",\n'
    stats_new = '"rx_empty=%u tx_empty=%u rx_full=%u tx_full=%u slept_us=%" PRIu64 " "\n        "cstate_attempt=%" PRIu64 " cstate_ok=%" PRIu64 " "\n        "cstate_last_us=%u cstate_total_us=%" PRIu64 "\\n",\n'
    if stats_old not in text:
        raise RuntimeError('V19 could not find stats format anchor')
    text = text.replace(stats_old, stats_new, 1)
    args_old = '        S->Tx.ConsecutiveFull,\n        S->TotalSleepUs);\n'
    args_new = r'''        S->Tx.ConsecutiveFull,
        S->TotalSleepUs,
        S->CStateAttempts,
        S->CStateSuccesses,
        S->LastCStateWaitUs,
        S->TotalCStateWaitUs);
'''
    if args_old not in text:
        raise RuntimeError('V19 could not find stats argument anchor')
    text = text.replace(args_old, args_new, 1)

    write_text(path, text)

    # Refresh the example with the complete V18 policy plus V19 options. Preserve
    # an existing user powermng.ini exactly, matching V18 behavior.
    write_new_or_replace(repo / 'powermng.example.ini', POWER_MNG_INI_V19_CSTATE)
    power_ini = repo / 'powermng.ini'
    if not power_ini.exists():
        write_text(power_ini, POWER_MNG_INI_V19_CSTATE)
    elif read_text(power_ini) == POWER_MNG_INI_V18:
        # The immediately preceding V18 stage created an untouched default file;
        # it is safe to extend that generated default with the V19 options.
        write_text(power_ini, POWER_MNG_INI_V19_CSTATE)
    else:
        log('Preserving customized powermng.ini; V19 options are in powermng.example.ini.')

    log('V19 safe C-state opportunity added; runtime default remains disabled.')


# =============================================================================
# V20 selectable idle mechanisms: short | pause | monitor | epoll | auto
# =============================================================================
#
# This stage deliberately keeps the full V18/V19 implementation and adds a
# runtime dispatcher. It does not delete the previous short-sleep or pause code.
#
# Wake semantics:
#   short   -> timeout (rte_delay_us_sleep)
#   pause   -> TSC deadline (rte_power_pause)
#   monitor -> RX descriptor write OR explicit rte_power_monitor_wakeup() after
#              TX work is published; watchdog only prevents indefinite hangs
#   epoll   -> NIC RX interrupt OR Linux eventfd written after TX work is
#              published; watchdog only prevents indefinite hangs
#   auto    -> monitor, then epoll, then short. It never silently chooses pause.
#
# QUIC safety:
#   * Existing V18 pressure, queue/ring, ACK, recovery, cwnd-growth and active-
#     transfer checks remain authoritative.
#   * Work is published before a wake notification.
#   * A monotonically increasing per-lcore sequence closes the race where work
#     appears just before monitor/epoll entry.
#   * monitor/epoll are disabled by default; the default remains short.
#   * unsupported APIs fall back according to GreenQuicIdleFallback.

POWER_MNG_INI_V20_IDLE = POWER_MNG_INI_V19_CSTATE + r'''

# =============================================================================
# V20 runtime-selectable idle mechanism
# =============================================================================
# off | short | pause | monitor | epoll | auto
# Default short preserves the proven V18 behavior.
GreenQuicIdleMode=short

# short | off | fail
# Used when monitor/epoll/pause is selected but unavailable at runtime.
GreenQuicIdleFallback=short

# Required sustained idle before monitor or epoll can block for work.
GreenQuicWorkWaitMinIdleUs=20000
GreenQuicWorkWaitMinLevel=16

# Safety watchdog, not the normal wake condition. Normal monitor/epoll wake-up
# comes from RX work or from a software producer publishing TX work.
GreenQuicIdleWatchdogUs=1000000

# Conservative semantic protection. Keep 0 until long-gap tests prove that an
# active transfer can tolerate work-triggered sleeping between chunks.
GreenQuicAllowWorkWaitDuringActiveTransfer=0

# epoll timeout is derived from the watchdog; 1000 ms matches 1,000,000 us.
GreenQuicEpollMaxEvents=8
'''


def patch_selectable_idle_modes(repo: Path) -> None:
    '''Add runtime-selectable short/pause/monitor/epoll/auto idle modes.

    The generated code remains one binary. Selection happens in powermng.ini:
        GreenQuicIdleMode=monitor
    or by environment override before process start:
        GREENQUIC_IDLE_MODE=epoll

    monitor mode uses rte_eth_get_monitor_addr() for RX wake and
    rte_power_monitor_wakeup() after successful TX-ring publication. epoll mode
    combines NIC RX interrupts with a per-lcore Linux eventfd. Both retain a
    watchdog as a failure-safety bound, not as the intended wake source.
    '''
    path = repo / 'src/platform/datapath_raw_dpdk.c'
    text = read_text(path)
    marker = '// GREENQUIC-V20-SELECTABLE-IDLE-MODES'
    if marker in text:
        log('V20 selectable idle modes already present; skipping.')
        return
    if '// GREENQUIC-V19-SAFE-CSTATE-IDLE' not in text:
        raise RuntimeError('V20 requires the complete V19-generated datapath')

    log('Applying V20 selectable idle modes: short, pause, monitor, epoll, auto.')

    # DPDK 21.11 marks monitor and per-queue interrupt-fd APIs experimental.
    exp_anchor = '#define _CRT_SECURE_NO_WARNINGS 1 // TODO - Remove\n'
    if exp_anchor not in text:
        raise RuntimeError('V20 could not find source preamble anchor')
    text = text.replace(exp_anchor, exp_anchor + '#define ALLOW_EXPERIMENTAL_API 1\n', 1)

    # Linux eventfd/epoll are guarded. Monitor/pause APIs retain runtime checks.
    inc_anchor = '#define GREENQUIC_HAVE_POWER_PAUSE_API 1\n'
    if inc_anchor not in text:
        raise RuntimeError('V20 could not find V19 power intrinsic include anchor')
    inc_repl = inc_anchor + r'''#define GREENQUIC_HAVE_POWER_MONITOR_API 1
'''
    text = text.replace(inc_anchor, inc_repl, 1)
    guard_anchor = '#ifndef GREENQUIC_HAVE_POWER_PAUSE_API\n#define GREENQUIC_HAVE_POWER_PAUSE_API 0\n#endif\n'
    if guard_anchor not in text:
        raise RuntimeError('V20 could not find V19 include guard anchor')
    guard_repl = guard_anchor + r'''#ifndef GREENQUIC_HAVE_POWER_MONITOR_API
#define GREENQUIC_HAVE_POWER_MONITOR_API 0
#endif

// GREENQUIC-V20-SELECTABLE-IDLE-MODES
#if defined(__linux__)
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <unistd.h>
#include <errno.h>
#define GREENQUIC_HAVE_EPOLL_IDLE 1
#else
#define GREENQUIC_HAVE_EPOLL_IDLE 0
#endif
'''
    text = text.replace(guard_anchor, guard_repl, 1)

    enum_anchor = '''typedef enum GREENQUIC_PROFILE {
'''
    enum_code = r'''typedef enum GREENQUIC_IDLE_MODE {
    GREENQUIC_IDLE_OFF = 0,
    GREENQUIC_IDLE_SHORT = 1,
    GREENQUIC_IDLE_PAUSE = 2,
    GREENQUIC_IDLE_MONITOR = 3,
    GREENQUIC_IDLE_EPOLL = 4,
    GREENQUIC_IDLE_AUTO = 5
} GREENQUIC_IDLE_MODE;

typedef enum GREENQUIC_IDLE_FALLBACK {
    GREENQUIC_IDLE_FALLBACK_SHORT = 0,
    GREENQUIC_IDLE_FALLBACK_OFF = 1,
    GREENQUIC_IDLE_FALLBACK_FAIL = 2
} GREENQUIC_IDLE_FALLBACK;

'''
    if enum_anchor not in text:
        raise RuntimeError('V20 could not find enum anchor')
    text = text.replace(enum_anchor, enum_code + enum_anchor, 1)

    # Per-lcore state. eventfd/epoll descriptors are initialized lazily on owner.
    state_anchor = '    BOOLEAN CStateUnavailable;\n'
    state_code = r'''    BOOLEAN CStateUnavailable;
    // GREENQUIC-V20-SELECTABLE-IDLE-MODES
    volatile uint64_t WakeSequence;
    uint64_t MonitorAttempts;
    uint64_t MonitorWakeups;
    uint64_t MonitorTimeouts;
    uint64_t EpollAttempts;
    uint64_t EpollWakeups;
    uint64_t EpollTimeouts;
    uint64_t WakeSignals;
    int EpollFd;
    int WakeEventFd;
    BOOLEAN EpollInitialized;
    BOOLEAN MonitorUnavailable;
    BOOLEAN EpollUnavailable;
'''
    if state_anchor not in text:
        raise RuntimeError('V20 could not find lcore state anchor')
    text = text.replace(state_anchor, state_code, 1)

    cfg_anchor = '    uint32_t GreenQuicCStateTxOwnerMaxWaitUs;\n'
    cfg_code = r'''    uint32_t GreenQuicCStateTxOwnerMaxWaitUs;
    // GREENQUIC-V20-SELECTABLE-IDLE-MODES
    GREENQUIC_IDLE_MODE GreenQuicIdleMode;
    GREENQUIC_IDLE_FALLBACK GreenQuicIdleFallback;
    uint32_t GreenQuicWorkWaitMinIdleUs;
    uint32_t GreenQuicWorkWaitMinLevel;
    uint32_t GreenQuicIdleWatchdogUs;
    uint32_t GreenQuicEpollMaxEvents;
    BOOLEAN GreenQuicAllowWorkWaitDuringActiveTransfer;
    BOOLEAN GreenQuicPowerMonitorSupported;
'''
    if cfg_anchor not in text:
        raise RuntimeError('V20 could not find config anchor')
    text = text.replace(cfg_anchor, cfg_code, 1)

    defaults_anchor = '    Dpdk->GreenQuicCStateTxOwnerMaxWaitUs = 50U;\n'
    defaults_code = r'''    Dpdk->GreenQuicCStateTxOwnerMaxWaitUs = 50U;
    // GREENQUIC-V20-SELECTABLE-IDLE-MODES. "short" is intentionally the
    // compatibility default. Work-triggered modes must be explicitly selected.
    Dpdk->GreenQuicIdleMode = GREENQUIC_IDLE_SHORT;
    Dpdk->GreenQuicIdleFallback = GREENQUIC_IDLE_FALLBACK_SHORT;
    Dpdk->GreenQuicWorkWaitMinIdleUs = 20000U;
    Dpdk->GreenQuicWorkWaitMinLevel = 16U;
    Dpdk->GreenQuicIdleWatchdogUs = 1000000U;
    Dpdk->GreenQuicEpollMaxEvents = 8U;
    Dpdk->GreenQuicAllowWorkWaitDuringActiveTransfer = FALSE;
    Dpdk->GreenQuicPowerMonitorSupported = FALSE;
    for (uint32_t IdleCore = 0; IdleCore < RTE_MAX_LCORE; ++IdleCore) {
        Dpdk->GreenQuicLcore[IdleCore].EpollFd = -1;
        Dpdk->GreenQuicLcore[IdleCore].WakeEventFd = -1;
    }
'''
    if defaults_anchor not in text:
        raise RuntimeError('V20 could not find defaults anchor')
    text = text.replace(defaults_anchor, defaults_code, 1)

    proto_anchor = 'static BOOLEAN GreenQuicTryCStateIdle(_Inout_ DPDK_DATAPATH* Dpdk, _In_ DPDK_INTERFACE* Interface, _Inout_ GREENQUIC_LCORE_STATE* S, _In_ uint16_t Core, _In_ uint64_t IdleUs, _In_ BOOLEAN OwnsRx, _In_ BOOLEAN OwnsTx);\n'
    proto_code = proto_anchor + r'''static const char* GreenQuicIdleModeToString(_In_ GREENQUIC_IDLE_MODE Mode);
static GREENQUIC_IDLE_MODE GreenQuicParseIdleMode(_In_z_ const char* Value, _In_ GREENQUIC_IDLE_MODE DefaultMode);
static GREENQUIC_IDLE_FALLBACK GreenQuicParseIdleFallback(_In_z_ const char* Value, _In_ GREENQUIC_IDLE_FALLBACK DefaultMode);
static BOOLEAN GreenQuicCanEnterWorkWait(_In_ DPDK_DATAPATH* Dpdk, _In_ DPDK_INTERFACE* Interface, _In_ GREENQUIC_LCORE_STATE* S, _In_ uint16_t Core, _In_ uint64_t IdleUs, _In_ BOOLEAN OwnsRx, _In_ BOOLEAN OwnsTx);
static void GreenQuicSignalLcoreWork(_Inout_ DPDK_DATAPATH* Dpdk, _In_ uint16_t Core);
static void GreenQuicSignalTxWork(_Inout_ DPDK_DATAPATH* Dpdk);
static BOOLEAN GreenQuicTryMonitorWait(_Inout_ DPDK_DATAPATH* Dpdk, _In_ DPDK_INTERFACE* Interface, _Inout_ GREENQUIC_LCORE_STATE* S, _In_ uint16_t Core, _In_ uint64_t IdleUs, _In_ BOOLEAN OwnsRx, _In_ BOOLEAN OwnsTx);
static BOOLEAN GreenQuicTryEpollWait(_Inout_ DPDK_DATAPATH* Dpdk, _In_ DPDK_INTERFACE* Interface, _Inout_ GREENQUIC_LCORE_STATE* S, _In_ uint16_t Core, _In_ uint64_t IdleUs, _In_ BOOLEAN OwnsRx, _In_ BOOLEAN OwnsTx);
static BOOLEAN GreenQuicTrySelectedIdle(_Inout_ DPDK_DATAPATH* Dpdk, _In_ DPDK_INTERFACE* Interface, _Inout_ GREENQUIC_LCORE_STATE* S, _In_ uint16_t Core, _In_ uint64_t IdleUs, _In_ BOOLEAN OwnsRx, _In_ BOOLEAN OwnsTx);
static void GreenQuicIdleCleanupLcore(_Inout_ GREENQUIC_LCORE_STATE* S);
'''
    if proto_anchor not in text:
        raise RuntimeError('V20 could not find prototype anchor')
    text = text.replace(proto_anchor, proto_code, 1)

    # Parse strings directly in the existing key/value chain.
    parser_anchor = '    // GREENQUIC-V19-SAFE-CSTATE-IDLE runtime values.\n'
    parser_code = r'''    // GREENQUIC-V20-SELECTABLE-IDLE-MODES string values.
    if (strcmp(Key, "GreenQuicIdleMode") == 0) {
        Dpdk->GreenQuicIdleMode = GreenQuicParseIdleMode(Value, Dpdk->GreenQuicIdleMode);
        return TRUE;
    }
    if (strcmp(Key, "GreenQuicIdleFallback") == 0) {
        Dpdk->GreenQuicIdleFallback = GreenQuicParseIdleFallback(Value, Dpdk->GreenQuicIdleFallback);
        return TRUE;
    }
    GQ_U32("GreenQuicWorkWaitMinIdleUs", GreenQuicWorkWaitMinIdleUs)
    GQ_U32("GreenQuicWorkWaitMinLevel", GreenQuicWorkWaitMinLevel)
    GQ_U32("GreenQuicIdleWatchdogUs", GreenQuicIdleWatchdogUs)
    GQ_U32("GreenQuicEpollMaxEvents", GreenQuicEpollMaxEvents)
    GQ_BOOL("GreenQuicAllowWorkWaitDuringActiveTransfer", GreenQuicAllowWorkWaitDuringActiveTransfer)

'''
    if parser_anchor not in text:
        raise RuntimeError('V20 could not find parser anchor')
    text = text.replace(parser_anchor, parser_code + parser_anchor, 1)

    sanitize_anchor = '    // GREENQUIC-V19-SAFE-CSTATE-IDLE sanitation. Zero max disables the path.\n'
    sanitize_code = r'''    // GREENQUIC-V20-SELECTABLE-IDLE-MODES sanitation and environment override.
    if (Dpdk->GreenQuicWorkWaitMinLevel == 0U) {
        Dpdk->GreenQuicWorkWaitMinLevel = 1U;
    }
    if (Dpdk->GreenQuicEpollMaxEvents == 0U) {
        Dpdk->GreenQuicEpollMaxEvents = 1U;
    } else if (Dpdk->GreenQuicEpollMaxEvents > 32U) {
        Dpdk->GreenQuicEpollMaxEvents = 32U;
    }
    const char* IdleModeEnv = getenv("GREENQUIC_IDLE_MODE");
    if (IdleModeEnv != NULL && IdleModeEnv[0] != '\\0') {
        Dpdk->GreenQuicIdleMode = GreenQuicParseIdleMode(IdleModeEnv, Dpdk->GreenQuicIdleMode);
    }

'''
    if sanitize_anchor not in text:
        raise RuntimeError('V20 could not find sanitation anchor')
    text = text.replace(sanitize_anchor, sanitize_code + sanitize_anchor, 1)

    # Replace V19 capability initialization so pause and monitor are checked
    # after the runtime idle mode has been parsed.
    cap_start = text.index('// GREENQUIC-V19-SAFE-CSTATE-IDLE\nstatic void\nGreenQuicInitCStateSupport')
    cap_end = text.index('\nstatic uint32_t\nGreenQuicGetEmptyLevel', cap_start)
    cap_code = r'''// GREENQUIC-V19-SAFE-CSTATE-IDLE
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
    if (Dpdk->GreenQuicIdleMode == GREENQUIC_IDLE_MONITOR &&
        !Dpdk->GreenQuicPowerMonitorSupported) {
        printf("GreenQUIC: monitor mode requested but power_monitor is unsupported; fallback=%u.\n",
            (unsigned)Dpdk->GreenQuicIdleFallback);
    }
}
'''
    text = text[:cap_start] + cap_code + text[cap_end:]

    # Helpers are inserted before the V19 marker implementation.
    helper_pos = text.index('// GREENQUIC-V19-SAFE-CSTATE-IDLE\nstatic void\nGreenQuicInitCStateSupport')
    helpers = r'''// GREENQUIC-V20-SELECTABLE-IDLE-MODES
static const char*
GreenQuicIdleModeToString(
    _In_ GREENQUIC_IDLE_MODE Mode
    )
{
    switch (Mode) {
    case GREENQUIC_IDLE_OFF: return "off";
    case GREENQUIC_IDLE_SHORT: return "short";
    case GREENQUIC_IDLE_PAUSE: return "pause";
    case GREENQUIC_IDLE_MONITOR: return "monitor";
    case GREENQUIC_IDLE_EPOLL: return "epoll";
    case GREENQUIC_IDLE_AUTO: return "auto";
    default: return "unknown";
    }
}

static GREENQUIC_IDLE_MODE
GreenQuicParseIdleMode(
    _In_z_ const char* Value,
    _In_ GREENQUIC_IDLE_MODE DefaultMode
    )
{
    if (strcasecmp(Value, "off") == 0) return GREENQUIC_IDLE_OFF;
    if (strcasecmp(Value, "short") == 0) return GREENQUIC_IDLE_SHORT;
    if (strcasecmp(Value, "pause") == 0) return GREENQUIC_IDLE_PAUSE;
    if (strcasecmp(Value, "monitor") == 0) return GREENQUIC_IDLE_MONITOR;
    if (strcasecmp(Value, "epoll") == 0) return GREENQUIC_IDLE_EPOLL;
    if (strcasecmp(Value, "auto") == 0) return GREENQUIC_IDLE_AUTO;
    fprintf(stderr, "GreenQUIC: invalid GreenQuicIdleMode=%s; keeping %s\\n",
        Value, GreenQuicIdleModeToString(DefaultMode));
    return DefaultMode;
}

static GREENQUIC_IDLE_FALLBACK
GreenQuicParseIdleFallback(
    _In_z_ const char* Value,
    _In_ GREENQUIC_IDLE_FALLBACK DefaultMode
    )
{
    if (strcasecmp(Value, "short") == 0) return GREENQUIC_IDLE_FALLBACK_SHORT;
    if (strcasecmp(Value, "off") == 0) return GREENQUIC_IDLE_FALLBACK_OFF;
    if (strcasecmp(Value, "fail") == 0) return GREENQUIC_IDLE_FALLBACK_FAIL;
    return DefaultMode;
}

static BOOLEAN
GreenQuicCanEnterWorkWait(
    _In_ DPDK_DATAPATH* Dpdk,
    _In_ DPDK_INTERFACE* Interface,
    _In_ GREENQUIC_LCORE_STATE* S,
    _In_ uint16_t Core,
    _In_ uint64_t IdleUs,
    _In_ BOOLEAN OwnsRx,
    _In_ BOOLEAN OwnsTx
    )
{
    if (!Dpdk->GreenQuicEnableSleep ||
        IdleUs < Dpdk->GreenQuicWorkWaitMinIdleUs ||
        S->PressureAvg >= Dpdk->GreenQuicPressureKeepThreshold ||
        GreenQuicGetEmptyLevel(Dpdk, S, OwnsRx, OwnsTx) <
            Dpdk->GreenQuicWorkWaitMinLevel) {
        return FALSE;
    }
    if ((OwnsRx &&
         (S->Rx.LastBurstCount != 0U || S->Rx.LastQueueCount != 0U)) ||
        (OwnsTx &&
         (S->Tx.LastBurstCount != 0U ||
          rte_ring_count(Interface->TxRingBuffer) != 0U))) {
        return FALSE;
    }
    uint64_t RxHints = 0U, TxHints = 0U;
    GreenQuicGetDirectionalHintsForCore(Dpdk, S, Core, &RxHints, &TxHints);
    if (GreenQuicCStateHintsBlock(Dpdk, RxHints, TxHints, OwnsRx, OwnsTx)) {
        return FALSE;
    }
    if (!Dpdk->GreenQuicAllowWorkWaitDuringActiveTransfer &&
        (((OwnsRx && (RxHints & GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE) != 0U)) ||
         ((OwnsTx && (TxHints & GQPLUS_HINT_SERVER_FILE_TX_ACTIVE) != 0U)))) {
        return FALSE;
    }
    return TRUE;
}

static void
GreenQuicSignalLcoreWork(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_ uint16_t Core
    )
{
    if (Core >= RTE_MAX_LCORE) return;
    GREENQUIC_LCORE_STATE* S = &Dpdk->GreenQuicLcore[Core];
    __atomic_add_fetch(&S->WakeSequence, 1U, __ATOMIC_RELEASE);
    ++S->WakeSignals;
#if GREENQUIC_HAVE_POWER_MONITOR_API
    (void)rte_power_monitor_wakeup(Core);
#endif
#if GREENQUIC_HAVE_EPOLL_IDLE
    if (S->WakeEventFd >= 0) {
        const uint64_t One = 1U;
        const ssize_t Written = write(S->WakeEventFd, &One, sizeof(One));
        if (Written < 0 && errno != EAGAIN) {
            S->EpollUnavailable = TRUE;
        }
    }
#endif
}

static void
GreenQuicSignalTxWork(
    _Inout_ DPDK_DATAPATH* Dpdk
    )
{
    const uint16_t Target =
        Dpdk->GreenQuicEnableMultiCore && Dpdk->GreenQuicTxOwnerConfigured ?
            Dpdk->GreenQuicTxOwnerLcore : Dpdk->Cpu;
    GreenQuicSignalLcoreWork(Dpdk, Target);
}

static uint64_t
GreenQuicWatchdogDeadline(
    _In_ const DPDK_DATAPATH* Dpdk
    )
{
    const uint64_t Hz = rte_get_tsc_hz();
    const uint64_t Delta =
        ((uint64_t)Dpdk->GreenQuicIdleWatchdogUs * Hz + 999999U) / 1000000U;
    return rte_get_tsc_cycles() + (Delta == 0U ? 1U : Delta);
}

static BOOLEAN
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
    const uint64_t Sequence = __atomic_load_n(&S->WakeSequence, __ATOMIC_ACQUIRE);
    struct rte_power_monitor_cond Cond;
    CxPlatZeroMemory(&Cond, sizeof(Cond));
    const uint16_t QueueId = GreenQuicGetQueueId(Dpdk, Core);
    if (rte_eth_get_monitor_addr(Interface->Port, QueueId, &Cond) != 0) {
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
    ++S->MonitorAttempts;
    const uint64_t Start = rte_get_tsc_cycles();
    const int Ret = rte_power_monitor(&Cond, GreenQuicWatchdogDeadline(Dpdk));
    const uint64_t ElapsedUs = GreenQuicTscDeltaToUs(rte_get_tsc_cycles() - Start);
    if (Ret == 0) {
        ++S->MonitorWakeups;
        if (ElapsedUs + 2U >= Dpdk->GreenQuicIdleWatchdogUs) ++S->MonitorTimeouts;
        return TRUE;
    }
    if (Ret == -ENOTSUP || Ret == -EINVAL) S->MonitorUnavailable = TRUE;
#else
    (void)Dpdk; (void)Interface; (void)S; (void)Core;
    (void)IdleUs; (void)OwnsRx; (void)OwnsTx;
#endif
    return FALSE;
}

static BOOLEAN
GreenQuicEnsureEpoll(
    _Inout_ GREENQUIC_LCORE_STATE* S
    )
{
#if GREENQUIC_HAVE_EPOLL_IDLE
    if (S->EpollInitialized) return !S->EpollUnavailable;
    S->EpollFd = epoll_create1(EPOLL_CLOEXEC);
    S->WakeEventFd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    if (S->EpollFd < 0 || S->WakeEventFd < 0) {
        S->EpollUnavailable = TRUE;
        return FALSE;
    }
    struct epoll_event Ev;
    CxPlatZeroMemory(&Ev, sizeof(Ev));
    Ev.events = EPOLLIN;
    Ev.data.u64 = UINT64_MAX;
    if (epoll_ctl(S->EpollFd, EPOLL_CTL_ADD, S->WakeEventFd, &Ev) != 0) {
        S->EpollUnavailable = TRUE;
        return FALSE;
    }
    S->EpollInitialized = TRUE;
    return TRUE;
#else
    (void)S;
    return FALSE;
#endif
}

static BOOLEAN
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
        !GreenQuicEnsureEpoll(S) ||
        !GreenQuicCanEnterWorkWait(Dpdk, Interface, S, Core, IdleUs, OwnsRx, OwnsTx)) {
        return FALSE;
    }
    const uint64_t Sequence = __atomic_load_n(&S->WakeSequence, __ATOMIC_ACQUIRE);
    int RxFd = -1;
    const uint16_t QueueId = GreenQuicGetQueueId(Dpdk, Core);
    if (OwnsRx) {
        RxFd = rte_eth_dev_rx_intr_ctl_q_get_fd(Interface->Port, QueueId);
        if (RxFd < 0) {
            S->EpollUnavailable = TRUE;
            return FALSE;
        }
        struct epoll_event RxEv;
        CxPlatZeroMemory(&RxEv, sizeof(RxEv));
        RxEv.events = EPOLLIN;
        RxEv.data.u64 = ((uint64_t)Interface->Port << 32) | QueueId;
        if (epoll_ctl(S->EpollFd, EPOLL_CTL_ADD, RxFd, &RxEv) != 0 && errno != EEXIST) {
            S->EpollUnavailable = TRUE;
            return FALSE;
        }
        if (rte_eth_dev_rx_intr_enable(Interface->Port, QueueId) != 0) {
            S->EpollUnavailable = TRUE;
            return FALSE;
        }
    }
    rte_smp_rmb();
    if (__atomic_load_n(&S->WakeSequence, __ATOMIC_ACQUIRE) != Sequence ||
        !GreenQuicCanEnterWorkWait(Dpdk, Interface, S, Core, IdleUs, OwnsRx, OwnsTx)) {
        if (OwnsRx) (void)rte_eth_dev_rx_intr_disable(Interface->Port, QueueId);
        return FALSE;
    }
    struct epoll_event Events[32];
    const int TimeoutMs = Dpdk->GreenQuicIdleWatchdogUs == 0U ? -1 :
        (int)((Dpdk->GreenQuicIdleWatchdogUs + 999U) / 1000U);
    ++S->EpollAttempts;
    const int Count = epoll_wait(S->EpollFd, Events,
        (int)Dpdk->GreenQuicEpollMaxEvents, TimeoutMs);
    if (OwnsRx) (void)rte_eth_dev_rx_intr_disable(Interface->Port, QueueId);
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
    if (errno != EINTR) S->EpollUnavailable = TRUE;
#else
    (void)Dpdk; (void)Interface; (void)S; (void)Core;
    (void)IdleUs; (void)OwnsRx; (void)OwnsTx;
#endif
    return FALSE;
}

static BOOLEAN
GreenQuicIdleFallbackAction(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_ DPDK_INTERFACE* Interface,
    _Inout_ GREENQUIC_LCORE_STATE* S,
    _In_ uint16_t Core,
    _In_ uint64_t IdleUs,
    _In_ BOOLEAN OwnsRx,
    _In_ BOOLEAN OwnsTx
    )
{
    if (Dpdk->GreenQuicIdleFallback == GREENQUIC_IDLE_FALLBACK_SHORT) {
        return FALSE; // unchanged V18 short-sleep code executes after dispatcher
    }
    if (Dpdk->GreenQuicIdleFallback == GREENQUIC_IDLE_FALLBACK_FAIL) {
        fprintf(stderr, "GreenQUIC: selected idle mode unsupported on lcore %u\\n", Core);
        Dpdk->Running = FALSE;
    }
    (void)Interface; (void)S; (void)IdleUs; (void)OwnsRx; (void)OwnsTx;
    return TRUE; // OFF/fail: suppress the later short-sleep fallback
}

static BOOLEAN
GreenQuicTrySelectedIdle(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_ DPDK_INTERFACE* Interface,
    _Inout_ GREENQUIC_LCORE_STATE* S,
    _In_ uint16_t Core,
    _In_ uint64_t IdleUs,
    _In_ BOOLEAN OwnsRx,
    _In_ BOOLEAN OwnsTx
    )
{
    switch (Dpdk->GreenQuicIdleMode) {
    case GREENQUIC_IDLE_OFF:
        return TRUE; // suppress short sleep; DVFS remains active
    case GREENQUIC_IDLE_SHORT:
        return FALSE; // execute unchanged V18 short-sleep code
    case GREENQUIC_IDLE_PAUSE:
        if (GreenQuicTryCStateIdle(Dpdk, Interface, S, Core, IdleUs, OwnsRx, OwnsTx)) {
            S->LastAction = "pause";
            return TRUE;
        }
        return GreenQuicIdleFallbackAction(Dpdk, Interface, S, Core, IdleUs, OwnsRx, OwnsTx);
    case GREENQUIC_IDLE_MONITOR:
        if (GreenQuicTryMonitorWait(Dpdk, Interface, S, Core, IdleUs, OwnsRx, OwnsTx)) {
            S->LastAction = "monitor";
            return TRUE;
        }
        return GreenQuicIdleFallbackAction(Dpdk, Interface, S, Core, IdleUs, OwnsRx, OwnsTx);
    case GREENQUIC_IDLE_EPOLL:
        if (GreenQuicTryEpollWait(Dpdk, Interface, S, Core, IdleUs, OwnsRx, OwnsTx)) {
            S->LastAction = "epoll";
            return TRUE;
        }
        return GreenQuicIdleFallbackAction(Dpdk, Interface, S, Core, IdleUs, OwnsRx, OwnsTx);
    case GREENQUIC_IDLE_AUTO:
        if (GreenQuicTryMonitorWait(Dpdk, Interface, S, Core, IdleUs, OwnsRx, OwnsTx)) {
            S->LastAction = "monitor";
            return TRUE;
        }
        if (GreenQuicTryEpollWait(Dpdk, Interface, S, Core, IdleUs, OwnsRx, OwnsTx)) {
            S->LastAction = "epoll";
            return TRUE;
        }
        return FALSE; // auto's final fallback is the unchanged short sleep
    default:
        return FALSE;
    }
}

static void
GreenQuicIdleCleanupLcore(
    _Inout_ GREENQUIC_LCORE_STATE* S
    )
{
#if GREENQUIC_HAVE_EPOLL_IDLE
    if (S->WakeEventFd >= 0) close(S->WakeEventFd);
    if (S->EpollFd >= 0) close(S->EpollFd);
#endif
    S->WakeEventFd = -1;
    S->EpollFd = -1;
    S->EpollInitialized = FALSE;
}

'''
    text = text[:helper_pos] + helpers + text[helper_pos:]

    # Replace unconditional V19 pause attempt with the runtime dispatcher.
    old_apply = r'''    if (GreenQuicTryCStateIdle(
            Dpdk, Interface, S, Core, IdleUs, OwnsRx, OwnsTx)) {
        S->LastAction = "cstate_pause";
        return;
    }

'''
    new_apply = r'''    if (GreenQuicTrySelectedIdle(
            Dpdk, Interface, S, Core, IdleUs, OwnsRx, OwnsTx)) {
        return;
    }

'''
    if old_apply not in text:
        raise RuntimeError('V20 could not find V19 policy call')
    text = text.replace(old_apply, new_apply, 1)

    # Signal only after successful publication to the shared TX ring.
    tx_old = '''    if (unlikely(rte_ring_mp_enqueue(Interface->TxRingBuffer, Packet->Mbuf) != 0)) {
        rte_pktmbuf_free(Packet->Mbuf);
        QuicTraceEvent(
            LibraryError,
            "[ lib] ERROR, %s.",
            "No room in DPDK TX ring buffer");
    }

    CxPlatPoolFree(&Dpdk->AdditionalInfoPool, Packet);
'''
    tx_new = '''    if (unlikely(rte_ring_mp_enqueue(Interface->TxRingBuffer, Packet->Mbuf) != 0)) {
        rte_pktmbuf_free(Packet->Mbuf);
        QuicTraceEvent(
            LibraryError,
            "[ lib] ERROR, %s.",
            "No room in DPDK TX ring buffer");
    } else {
        // Publish first, then wake. Release ordering in GreenQuicSignalTxWork()
        // guarantees the sleeping consumer observes the ring item after wake-up.
        GreenQuicSignalTxWork(Dpdk);
    }

    CxPlatPoolFree(&Dpdk->AdditionalInfoPool, Packet);
'''
    if tx_old not in text:
        raise RuntimeError('V20 could not find TX enqueue anchor')
    text = text.replace(tx_old, tx_new, 1)

    # Wake all DPDK workers during shutdown before waiting for lcores to exit.
    shutdown_anchor = '''    DPDK_DATAPATH* Dpdk = (DPDK_DATAPATH*)Datapath;
    Dpdk->Running = FALSE;
'''
    shutdown_code = r'''    DPDK_DATAPATH* Dpdk = (DPDK_DATAPATH*)Datapath;
    Dpdk->Running = FALSE;
    // GREENQUIC-V20: unblock monitor/epoll workers during shutdown.
    unsigned int ShutdownCore;
    RTE_LCORE_FOREACH_WORKER(ShutdownCore) {
        GreenQuicSignalLcoreWork(Dpdk, (uint16_t)ShutdownCore);
    }
    GreenQuicSignalLcoreWork(Dpdk, Dpdk->Cpu);
'''
    if shutdown_anchor not in text:
        raise RuntimeError('V20 could not find shutdown anchor')
    text = text.replace(shutdown_anchor, shutdown_code, 1)

    cleanup_anchor = '    GreenQuicPowerCleanup(Dpdk, Core);\n    return 0;\n'
    cleanup_code = '''    GreenQuicPowerCleanup(Dpdk, Core);
    GreenQuicIdleCleanupLcore(GreenQuicGetLcoreState(Dpdk, Core));
    return 0;
'''
    if cleanup_anchor not in text:
        raise RuntimeError('V20 could not find worker cleanup anchor')
    text = text.replace(cleanup_anchor, cleanup_code, 1)

    # Extend summary diagnostics. Keep all V19 names intact.
    fmt_old = '        "cstate_last_us=%u cstate_total_us=%" PRIu64 "\\n",\n'
    fmt_new = '        "cstate_last_us=%u cstate_total_us=%" PRIu64 " "\n        "idle_mode=%s monitor_try=%" PRIu64 " monitor_wake=%" PRIu64 " monitor_timeout=%" PRIu64 " "\n        "epoll_try=%" PRIu64 " epoll_wake=%" PRIu64 " epoll_timeout=%" PRIu64 " wake_signal=%" PRIu64 "\\n",\n'
    if fmt_old not in text:
        raise RuntimeError('V20 could not find V19 stats format')
    text = text.replace(fmt_old, fmt_new, 1)
    args_old = '''        S->LastCStateWaitUs,
        S->TotalCStateWaitUs);
'''
    args_new = '''        S->LastCStateWaitUs,
        S->TotalCStateWaitUs,
        GreenQuicIdleModeToString(Dpdk->GreenQuicIdleMode),
        S->MonitorAttempts,
        S->MonitorWakeups,
        S->MonitorTimeouts,
        S->EpollAttempts,
        S->EpollWakeups,
        S->EpollTimeouts,
        S->WakeSignals);
'''
    if args_old not in text:
        raise RuntimeError('V20 could not find V19 stats args')
    text = text.replace(args_old, args_new, 1)

    write_text(path, text)
    write_new_or_replace(repo / 'powermng.example.ini', POWER_MNG_INI_V20_IDLE)
    power_ini = repo / 'powermng.ini'
    if not power_ini.exists() or read_text(power_ini) == POWER_MNG_INI_V19_CSTATE:
        write_text(power_ini, POWER_MNG_INI_V20_IDLE)
    else:
        log('Preserving customized powermng.ini; V20 modes are in powermng.example.ini.')
    log('V20 selectable idle modes added; default remains short.')

def _detect_existing_greenquic_mode(repo: Path) -> str:
    header = repo / 'src/inc/greenquic_plus.h'
    datapath = repo / 'src/platform/datapath_raw_dpdk.c'
    h = read_text(header) if header.exists() else ''
    d = read_text(datapath) if datapath.exists() else ''
    if ('CxPlatGreenQuicPlusPulseHintsForPartition' in h or
        'GreenQuicPartitionDpdkMapConfigured' in d):
        return 'multi'
    if 'GREENQUIC-BEGIN: mode, profile and runtime state' in d:
        return 'single'
    return 'none'


def _validate_v18_generated_tree(
    repo: Path,
    enable_multi_core: bool,
    basic_only: bool
    ) -> None:
    dp = read_text(repo / 'src/platform/datapath_raw_dpdk.c')
    gp = read_text(repo / 'src/platform/greenquic_plus.c')

    required = [
        'GQPLUS_ACK_TTL_NS',
        'GREENQUIC-OLD-V17',
        'GREENQUIC-V18-DIRECTIONAL-RXTX',
        'GREENQUIC-V18-ROLE-COMPLETE',
        'GreenQuicLcoreOwnsRx',
        'GreenQuicEnableRx',
        'GreenQuicEnableTx',
        'GreenQuicGetSleepBudgetUs(',
        'GreenQuicDataPathMaxSleepUs',
        'GreenQuicPlusDirectionalPressure',
        'RxPressureAvg',
        'TxPressureAvg',
        'LastRxQuicPressure',
        'LastTxQuicPressure',
        'CxPlatGreenQuicPlusGetTxHints',
        'GREENQUIC-V18-SEPARATE-SIGNALS-POWERMNG',
        'RxBurstPressureAvg',
        'RxQueuePressureAvg',
        'TxBurstPressureAvg',
        'TxRingPressureAvg',
        'GreenQuicReadPowerConfig',
        'GreenQuicAckClientFloor',
        'GREENQUIC-V19-SAFE-CSTATE-IDLE',
        'GreenQuicTryCStateIdle',
        'GreenQuicEnableCStateIdle',
        'GreenQuicCStateTxOwnerMaxWaitUs',
        'rte_power_pause',
        'GREENQUIC-V20-SELECTABLE-IDLE-MODES',
        'GreenQuicTrySelectedIdle',
        'rte_power_monitor',
        'rte_eth_get_monitor_addr',
        'rte_eth_dev_rx_intr_enable',
        'GreenQuicSignalTxWork',
    ]
    if not basic_only:
        ack = read_text(repo / 'src/core/ack_tracker.c')
        cubic = read_text(repo / 'src/core/cubic.c')
        required += [
            'GREENQUIC-V18: ACK is actually ready to send',
            'GREENQUIC-V18: recovery begins',
            'CxPlatGreenQuicPlusBeginRecovery',
        ]
        combined = dp + gp + ack + cubic
    else:
        combined = dp + gp

    missing = [item for item in required if item not in combined]
    if missing:
        die(f'V18 generated-tree validation failed; missing: {missing}')

    if enable_multi_core:
        multi_required = [
            'GreenQuicTxOwnerLcore',
            'GREENQUIC-V18: one TX consumer',
            'rte_ring_mc_dequeue_burst',  # old code retained in #if 0
            'rte_ring_sc_dequeue_burst',
            'CxPlatGreenQuicPlusPulseHintsForPartition',
            'GlobalTxRecoveryActiveCount',
            'GlobalTxAckUntilNs',
            'GreenQuicTxOwnerAlsoRx',
            'GreenQuicRxQueueByLcore',
        ]
        missing = [item for item in multi_required if item not in combined]
        if missing:
            die(f'V18 multi-core validation failed; missing: {missing}')
    else:
        if 'GreenQuicEnableMultiCore' in dp:
            die('V18 single-core validation found unexpected multi-core fields.')

    log(
        'V18 generated-tree validation passed for ' +
        ('multi-core' if enable_multi_core else 'single-core') +
        (' BASIC-only path.' if basic_only else ' PLUS-capable path.'))


# Keep the full v17 apply function above for reference; this one is active.
def apply_all_patches(
    repo: Path,
    basic_only: bool,
    enable_multi_core: bool = False
    ) -> None:
    existing = _detect_existing_greenquic_mode(repo)
    requested = 'multi' if enable_multi_core else 'single'
    if existing != 'none' and existing != requested:
        die(
            f'Existing GreenQUIC patch mode is {existing}, but this run requests '
            f'{requested}. Restore .greenquic.bak files or use a clean tree. '
            'V18 refuses to mix incompatible single/multi APIs.')

    patch_greenquic_plus_files(repo)
    patch_datapath(repo)
    if basic_only:
        warn(
            'BASIC-only selected: hint files are compiled, but ACK/CUBIC/tool '
            'hooks are skipped. Run GreenQuicMode=basic.')
    else:
        patch_precomp(repo)
        patch_ack_tracker(repo)
        patch_cubic(repo)
        patch_server_header(repo)
        patch_server_tool(repo)
        patch_client_tool(repo)

    patch_cmake(repo)
    if enable_multi_core:
        patch_multicore_support(repo, basic_only)
    else:
        log(
            'Optional multi-core patch not requested; keeping one RX queue and '
            'one TX queue/consumer.')

    post_compile_safety_fixes(repo, enable_multi_core)
    patch_directional_pressure_policy(repo, enable_multi_core)
    patch_role_complete_directional_policy(repo, enable_multi_core)
    patch_separated_signal_ewma_and_powermng(repo, enable_multi_core)
    patch_safe_cstate_idle(repo)
    patch_selectable_idle_modes(repo)
    _validate_v18_generated_tree(repo, enable_multi_core, basic_only)
    log('All V20 patches applied (complete V18/V19 + selectable idle modes).')

def main() -> None:
    args = parse_args()

    for tool in ("git", "cmake"):
        if shutil.which(tool) is None:
            die(f"Required tool missing from PATH: {tool}")

    print(f"""
GreenQUIC full autopatcher v20 - selectable short/pause/monitor/epoll/auto idle

This creates the full GreenQUIC + GreenQUIC+ code path:
  - BASIC mode: DPDK RX/TX observation + RX queue pressure + proportional pressure + EWMA + step-up/step-down/max DVFS
  - PLUS mode: BASIC mode + ACK/CUBIC/app hints with ref-counted app transfer hints
  - logging is off by default; enable with GreenQuicEnableLogging=1 or GreenQuicLogLevel=1
  - guarded ref-counted transfer hints, so repeated SendData callbacks do not leak active counters
  - per-lcore GreenQUIC state for future multi-lcore DPDK changes
  - separate RX burst/queue and TX burst/ring EWMAs; QUIC hints are direct configurable floors; RX/TX meet only at the final per-lcore action
  - all power thresholds, alpha values, floors, DVFS timings and sleep levels are tunable in powermng.ini
  - runtime GreenQuicIdleMode: off, short, pause, monitor, epoll, auto; default short
  - monitor wakes on RX descriptor work or explicit software wake after TX publication
  - epoll wakes on NIC RX interrupt or per-lcore eventfd; watchdog is safety-only
  - explicit RX-only, TX-only and RX+TX lcore roles; unowned directions are ignored
  - optional --enable-multi-core patch: one RX queue per RX owner + optional TX-only owner + partition-to-RX-lcore hint attribution + efficient TX-owner hint aggregation
  - power init/cleanup per DPDK worker lcore
  - local CMake build only, no sudo, no system install
  - default DPDK mode is local: ./deps/dpdk + ./deps/dpdk-install
  - can recursively search an existing DPDK folder with --dpdk-search-root ./mohsen/dpdk21
  - recommended local DPDK checkout: {RECOMMENDED_DPDK_CHECKOUT}
""")

    repo = clone_or_use_repo(args)
    prepare_branch(repo, args)
    check_expected_files(repo)

    if not args.yes:
        print("\nThe script will now edit files and create .greenquic.bak backups.")
        if not ask_yes("Apply full GreenQUIC patches now?", default=False):
            die("Stopped before patching.")

    apply_all_patches(repo, basic_only=args.basic_only, enable_multi_core=args.enable_multi_core)

    if not args.no_build:
        prepare_dpdk(repo, args)
        if args.yes or ask_yes("Run local CMake build now?", default=True):
            build_repo(repo, args)
        else:
            warn("Build skipped.")

    print_test_guide(repo)


# =============================================================================
# V21 OPTIONAL EXACT CONNECTION-TO-DPDK-LCORE TRACKING
# =============================================================================
#
# This block is intentionally appended after the complete V20 implementation.
# Nothing above is removed or shortened. When --trackconnection is absent, the
# V20 generated tree and behavior remain unchanged.
#
# --trackconnection adds exact receive provenance:
#   actual DPDK RX lcore/queue -> received datagram -> MsQuic connection
#
# ACK/CUBIC hints are then routed through the learned connection location. The
# existing partition map remains only a fallback before any packet has been
# attributed. TX-relevant hints still reach the configured TX owner through the
# existing V18/V20 aggregate TX-hint path.
#
# Application file-transfer hints are also made directional:
#   SERVER_FILE_TX_ACTIVE -> configured DPDK TX owner
#   CLIENT_FILE_RX_ACTIVE -> connection's learned DPDK RX lcore
#
# The tracking table is keyed by the actual HQUIC/QUIC_CONNECTION pointer. Core
# packet processing updates it before ACK/congestion-control processing, and
# QuicConnFree removes the entry. Transfer begin returns its selected lcore so
# the matching end always decrements the same bucket even after migration.
# =============================================================================

_GQ_TRACK_MARKER = "GREENQUIC-V21-TRACKCONNECTION"


def _gq_find_c_function_span(text: str, function_name: str) -> tuple[int, int]:
    """Return [start, end) of a C function definition, including its closing brace."""
    search_from = 0
    name_pattern = re.compile(rf'(?m)^[ \t]*{re.escape(function_name)}[ \t]*\(')
    while True:
        match = name_pattern.search(text, search_from)
        if match is None:
            raise RuntimeError(f"Could not find C function definition: {function_name}")
        open_paren = text.find('(', match.start())
        open_brace = text.find('{', open_paren)
        semicolon = text.find(';', open_paren)
        if open_brace != -1 and (semicolon == -1 or open_brace < semicolon):
            break
        search_from = match.end()

    depth = 0
    i = open_brace
    state = 'code'
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ''
        if state == 'code':
            if ch == '/' and nxt == '/':
                state = 'line_comment'
                i += 2
                continue
            if ch == '/' and nxt == '*':
                state = 'block_comment'
                i += 2
                continue
            if ch == '"':
                state = 'string'
                i += 1
                continue
            if ch == "'":
                state = 'char'
                i += 1
                continue
            if ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0:
                    line_start = text.rfind('\n', 0, match.start()) + 1
                    return line_start, i + 1
            i += 1
            continue
        if state == 'line_comment':
            if ch == '\n':
                state = 'code'
            i += 1
            continue
        if state == 'block_comment':
            if ch == '*' and nxt == '/':
                state = 'code'
                i += 2
            else:
                i += 1
            continue
        if state in ('string', 'char'):
            if ch == '\\':
                i += 2
                continue
            if (state == 'string' and ch == '"') or (state == 'char' and ch == "'"):
                state = 'code'
            i += 1
            continue
    raise RuntimeError(f"Unterminated C function definition: {function_name}")


def _gq_find_call_end(text: str, call_start: int) -> int:
    """Return end offset just after the semicolon for a function call."""
    open_paren = text.find('(', call_start)
    if open_paren == -1:
        raise RuntimeError('Call has no opening parenthesis')
    depth = 0
    i = open_paren
    state = 'code'
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ''
        if state == 'code':
            if ch == '/' and nxt == '/':
                state = 'line_comment'; i += 2; continue
            if ch == '/' and nxt == '*':
                state = 'block_comment'; i += 2; continue
            if ch == '"':
                state = 'string'; i += 1; continue
            if ch == "'":
                state = 'char'; i += 1; continue
            if ch == '(':
                depth += 1
            elif ch == ')':
                depth -= 1
                if depth == 0:
                    j = i + 1
                    while j < len(text) and text[j] in ' \t\r\n':
                        j += 1
                    if j >= len(text) or text[j] != ';':
                        raise RuntimeError('Matched call is not followed by a semicolon')
                    return j + 1
            i += 1
            continue
        if state == 'line_comment':
            if ch == '\n': state = 'code'
            i += 1
            continue
        if state == 'block_comment':
            if ch == '*' and nxt == '/': state = 'code'; i += 2
            else: i += 1
            continue
        if state in ('string', 'char'):
            if ch == '\\': i += 2; continue
            if (state == 'string' and ch == '"') or (state == 'char' and ch == "'"):
                state = 'code'
            i += 1
            continue
    raise RuntimeError('Unterminated function call')


def _gq_replace_partition_calls_with_connection_tracking(
    text: str,
    function_name: str,
    replacement_name: str,
    required_tokens: list[str],
    path_name: str,
    ) -> tuple[str, dict[str, int]]:
    """Replace active partition-routed calls while preserving their partition argument."""
    counts = {token: 0 for token in required_tokens}
    pattern = re.compile(rf'(?m)^(?P<indent>[ \t]*){re.escape(function_name)}[ \t]*\(')
    matches = list(pattern.finditer(text))
    replacements: list[tuple[int, int, str]] = []
    for match in matches:
        end = _gq_find_call_end(text, match.start())
        call = text[match.start():end]
        token = next((item for item in required_tokens if item in call), None)
        if token is None:
            continue
        indent = match.group('indent')
        open_paren = call.find('(')
        close_paren = call.rfind(')')
        args = call[open_paren + 1:close_paren]
        if function_name == 'CxPlatGreenQuicPlusPulseHintsForPartition':
            split_at = args.rfind(',')
            if split_at == -1:
                raise RuntimeError(f'{path_name}: could not split partition/hint arguments')
            partition_expr = args[:split_at].strip()
            hint_expr = args[split_at + 1:].strip()
            new_call = (
                f'{indent}{replacement_name}(\n'
                f'{indent}    (const void*)Connection,\n'
                f'{indent}    {partition_expr},\n'
                f'{indent}    {hint_expr});')
        else:
            partition_expr = args.strip()
            new_call = (
                f'{indent}{replacement_name}(\n'
                f'{indent}    (const void*)Connection,\n'
                f'{indent}    {partition_expr});')
        replacements.append((match.start(), end, new_call))
        counts[token] += 1

    for start, end, replacement in reversed(replacements):
        text = text[:start] + replacement + text[end:]
    return text, counts


def _gq_patch_recv_provenance_header(repo: Path) -> None:
    path = repo / 'src/inc/quic_datapath.h'
    ensure_file(path)
    backup(path)
    text = read_text(path)
    if _GQ_TRACK_MARKER in text:
        return

    define_anchor = '#define CXPLAT_MAX_BATCH_SIZE'
    define_block = (
        '// GREENQUIC-BEGIN: V21 exact DPDK RX provenance\n'
        '#define CXPLAT_GREENQUIC_RX_PROVENANCE_MAGIC 0x47515258u\n'
        '#define CXPLAT_GREENQUIC_RX_LCORE_UNKNOWN ((uint16_t)0xffffu)\n'
        '#define CXPLAT_GREENQUIC_RX_QUEUE_UNKNOWN ((uint16_t)0xffffu)\n'
        '// GREENQUIC-END: V21 exact DPDK RX provenance\n\n')
    if define_anchor in text:
        line_start = text.rfind('\n', 0, text.index(define_anchor)) + 1
        text = text[:line_start] + define_block + text[line_start:]
    else:
        include_anchor = '#include'
        first_type = text.find('typedef struct CXPLAT_RECV_DATA')
        if first_type == -1:
            raise RuntimeError(f'{path}: could not find CXPLAT_RECV_DATA')
        text = text[:first_type] + define_block + text[first_type:]

    field_pattern = re.compile(r'(?m)^(?P<i>[ \t]*)uint16_t PartitionIndex;[ \t]*$')
    match = field_pattern.search(text)
    if match is None:
        raise RuntimeError(f'{path}: could not find PartitionIndex field')
    indent = match.group('i')
    field_block = (
        match.group(0) + '\n\n'
        f'{indent}// {_GQ_TRACK_MARKER}: populated only by the DPDK raw datapath.\n'
        f'{indent}uint32_t GreenQuicRxProvenanceMagic;\n'
        f'{indent}uint16_t GreenQuicRxLcore;\n'
        f'{indent}uint16_t GreenQuicRxQueue;')
    text = text[:match.start()] + field_block + text[match.end():]
    write_text(path, text)


def _gq_patch_dpdk_recv_stamp_and_tx_owner(repo: Path) -> None:
    path = repo / 'src/platform/datapath_raw_dpdk.c'
    ensure_file(path)
    backup(path)
    text = read_text(path)

    if 'GREENQUIC-V21: stamp actual RX lcore and queue' not in text:
        start, end = _gq_find_c_function_span(text, 'CxPlatDpdkRx')
        function = text[start:end]
        if 'const uint16_t QueueId = GreenQuicGetQueueId(Dpdk, Core);' not in function:
            raise RuntimeError(
                f'{path}: --trackconnection requires the V20 multi-core QueueId in CxPlatDpdkRx')
        packet_ptr_match = re.search(
            r'(?m)^[ \t]*DPDK_RX_PACKET[ \t]*\*[ \t]*(?P<var>[A-Za-z_][A-Za-z0-9_]*)[ \t]*;',
            function)
        if packet_ptr_match is not None:
            var = packet_ptr_match.group('var')
            allocated_pattern = re.compile(
                rf'(?m)^(?P<i>[ \t]*){re.escape(var)}->Allocated[ \t]*=[ \t]*TRUE;[ \t]*$')
            allocated_match = allocated_pattern.search(function)
        else:
            allocated_match = None

        if allocated_match is not None:
            indent = allocated_match.group('i')
            stamp = (
                allocated_match.group(0) + '\n'
                f'{indent}// GREENQUIC-V21: stamp the final copied RX packet.\n'
                f'{indent}{var}->GreenQuicRxProvenanceMagic = CXPLAT_GREENQUIC_RX_PROVENANCE_MAGIC;\n'
                f'{indent}{var}->GreenQuicRxLcore = Core;\n'
                f'{indent}{var}->GreenQuicRxQueue = QueueId;')
            function = (
                function[:allocated_match.start()] + stamp +
                function[allocated_match.end():])
        else:
            # Conservative fallback for a branch that directly submits a stack packet.
            packet_match = re.search(
                r'(?m)^[ \t]*DPDK_RX_PACKET[ \t]+(?P<var>[A-Za-z_][A-Za-z0-9_]*)[ \t]*;',
                function)
            if packet_match is None:
                raise RuntimeError(f'{path}: could not find a DPDK_RX_PACKET variable')
            var = packet_match.group('var')
            route_pattern = re.compile(
                rf'(?m)^(?P<i>[ \t]*){re.escape(var)}\.Route->Queue[ \t]*=[^;]+;[ \t]*$')
            route_match = route_pattern.search(function)
            if route_match is None:
                raise RuntimeError(f'{path}: could not find final RX packet stamp anchor')
            indent = route_match.group('i')
            stamp = (
                route_match.group(0) + '\n'
                f'{indent}// GREENQUIC-V21: stamp actual RX lcore and queue.\n'
                f'{indent}{var}.GreenQuicRxProvenanceMagic = CXPLAT_GREENQUIC_RX_PROVENANCE_MAGIC;\n'
                f'{indent}{var}.GreenQuicRxLcore = Core;\n'
                f'{indent}{var}.GreenQuicRxQueue = QueueId;')
            function = function[:route_match.start()] + stamp + function[route_match.end():]
        text = text[:start] + function + text[end:]

    if 'GREENQUIC-V21: publish the configured TX owner' not in text:
        anchor = '    CxPlatGreenQuicPlusSetThreadLcore(Core);\n'
        if anchor not in text:
            raise RuntimeError(f'{path}: could not find SetThreadLcore worker anchor')
        text = text.replace(
            anchor,
            anchor +
            '    // GREENQUIC-V21: publish the configured TX owner for directional transfer hints.\n'
            '    if (GreenQuicLcoreOwnsTx(Dpdk, Core)) {\n'
            '        CxPlatGreenQuicPlusSetTxOwnerLcore(Core);\n'
            '    }\n',
            1)

    if 'GREENQUIC-V21: clear the TX owner' not in text:
        anchor = '    CxPlatGreenQuicPlusClearThreadLcore();\n'
        if anchor not in text:
            raise RuntimeError(f'{path}: could not find ClearThreadLcore worker anchor')
        text = text.replace(
            anchor,
            '    // GREENQUIC-V21: clear the TX owner only from its owning worker.\n'
            '    if (GreenQuicLcoreOwnsTx(Dpdk, Core)) {\n'
            '        CxPlatGreenQuicPlusClearTxOwnerLcore(Core);\n'
            '    }\n' + anchor,
            1)

    write_text(path, text)


def _gq_patch_tracking_hint_api(repo: Path) -> None:
    header = repo / 'src/inc/greenquic_plus.h'
    source = repo / 'src/platform/greenquic_plus.c'
    ensure_file(header)
    ensure_file(source)
    backup(header)
    backup(source)

    h = read_text(header)
    if 'CxPlatGreenQuicPlusTrackConnection' not in h:
        declaration_anchor = 'void CxPlatGreenQuicPlusPulseHintsForPartition(uint16_t Partition, uint64_t Hints);\n'
        if declaration_anchor not in h:
            raise RuntimeError(f'{header}: could not find multi-core pulse API anchor')
        declarations = r'''

// GREENQUIC-BEGIN: V21 exact connection-to-DPDK-lcore tracking.
void CxPlatGreenQuicPlusTrackConnection(
    const void* ConnectionHandle,
    uint16_t RxLcore,
    uint16_t RxQueue);
void CxPlatGreenQuicPlusUntrackConnection(const void* ConnectionHandle);
uint16_t CxPlatGreenQuicPlusGetConnectionRxLcore(const void* ConnectionHandle);
uint16_t CxPlatGreenQuicPlusGetConnectionRxQueue(const void* ConnectionHandle);
void CxPlatGreenQuicPlusPulseHintsForConnection(
    const void* ConnectionHandle,
    uint16_t FallbackPartition,
    uint64_t Hints);
void CxPlatGreenQuicPlusBeginRecoveryForLcore(uint16_t Lcore);
void CxPlatGreenQuicPlusEndRecoveryForLcore(uint16_t Lcore);
void CxPlatGreenQuicPlusBeginRecoveryForConnection(
    const void* ConnectionHandle,
    uint16_t FallbackPartition);
void CxPlatGreenQuicPlusEndRecoveryForConnection(
    const void* ConnectionHandle,
    uint16_t FallbackPartition);
void CxPlatGreenQuicPlusBeginTransferForLcore(uint16_t Lcore, uint64_t Hints);
void CxPlatGreenQuicPlusEndTransferForLcore(uint16_t Lcore, uint64_t Hints);
uint16_t CxPlatGreenQuicPlusBeginTransferForConnection(
    const void* ConnectionHandle,
    uint64_t Hints);
void CxPlatGreenQuicPlusSetTxOwnerLcore(uint16_t Lcore);
void CxPlatGreenQuicPlusClearTxOwnerLcore(uint16_t Lcore);
uint16_t CxPlatGreenQuicPlusGetTxOwnerLcore(void);
// GREENQUIC-END: V21 exact connection-to-DPDK-lcore tracking.
'''
        h = h.replace(declaration_anchor, declaration_anchor + declarations, 1)
    write_text(header, h)

    c = read_text(source)
    if 'GQPLUS_CONNECTION_TRACK_SLOTS' not in c:
        declaration_anchor = 'static atomic_uint_fast32_t PartitionDpdkLcorePlusOne[GQPLUS_MAX_PARTITIONS];\n'
        if declaration_anchor not in c:
            raise RuntimeError(f'{source}: could not find partition map declaration')
        declarations = r'''

// GREENQUIC-BEGIN: V21 exact connection tracking table.
#define GQPLUS_CONNECTION_TRACK_SLOTS 8192u
#define GQPLUS_CONNECTION_TRACK_TOMBSTONE ((uintptr_t)1u)

typedef struct GQPLUS_CONNECTION_TRACK_ENTRY {
    atomic_uintptr_t Key;
    atomic_uint_fast32_t RxLcorePlusOne;
    atomic_uint_fast32_t RxQueuePlusOne;
    atomic_uint_fast32_t RecoveryLcorePlusOne;
    atomic_uint_fast64_t LastRxNs;
} GQPLUS_CONNECTION_TRACK_ENTRY;

static GQPLUS_CONNECTION_TRACK_ENTRY
    ConnectionTrack[GQPLUS_CONNECTION_TRACK_SLOTS];
static atomic_uint_fast32_t TxOwnerLcorePlusOne;
static atomic_uint_fast32_t LcoreServerFileTxActiveCount[GQPLUS_MAX_LCORES];
static atomic_uint_fast32_t LcoreClientFileRxActiveCount[GQPLUS_MAX_LCORES];
// GREENQUIC-END: V21 exact connection tracking table.
'''
        c = c.replace(declaration_anchor, declaration_anchor + declarations, 1)

    # The V20 functions are static. Export them for exact connection routing.
    c = c.replace(
        'static void\nCxPlatGreenQuicPlusBeginRecoveryForLcore(uint16_t Lcore)\n',
        'void\nCxPlatGreenQuicPlusBeginRecoveryForLcore(uint16_t Lcore)\n',
        1)
    c = c.replace(
        'static void\nCxPlatGreenQuicPlusEndRecoveryForLcore(uint16_t Lcore)\n',
        'void\nCxPlatGreenQuicPlusEndRecoveryForLcore(uint16_t Lcore)\n',
        1)

    if 'CxPlatGreenQuicPlusFindConnectionEntry' not in c:
        _, valid_partition_end = _gq_find_c_function_span(c, 'CxPlatGreenQuicPlusValidPartition')
        table_helpers = r'''

// GREENQUIC-BEGIN: V21 lock-free connection lookup helpers.
static uint32_t
CxPlatGreenQuicPlusHashConnectionKey(uintptr_t Key)
{
    Key >>= 3;
    Key ^= Key >> 17;
    Key ^= Key >> 9;
    return (uint32_t)Key & (GQPLUS_CONNECTION_TRACK_SLOTS - 1u);
}

static GQPLUS_CONNECTION_TRACK_ENTRY*
CxPlatGreenQuicPlusFindConnectionEntry(
    const void* ConnectionHandle,
    int Create
    )
{
    const uintptr_t Key = (uintptr_t)ConnectionHandle;
    if (Key <= GQPLUS_CONNECTION_TRACK_TOMBSTONE) {
        return NULL;
    }

    for (uint32_t Attempt = 0; Attempt < 4u; ++Attempt) {
        GQPLUS_CONNECTION_TRACK_ENTRY* FirstTombstone = NULL;
        const uint32_t Start = CxPlatGreenQuicPlusHashConnectionKey(Key);

        for (uint32_t Probe = 0; Probe < GQPLUS_CONNECTION_TRACK_SLOTS; ++Probe) {
            GQPLUS_CONNECTION_TRACK_ENTRY* Entry =
                &ConnectionTrack[(Start + Probe) &
                    (GQPLUS_CONNECTION_TRACK_SLOTS - 1u)];
            const uintptr_t Existing = atomic_load_explicit(
                &Entry->Key,
                memory_order_acquire);

            if (Existing == Key) {
                return Entry;
            }
            if (Existing == GQPLUS_CONNECTION_TRACK_TOMBSTONE) {
                if (FirstTombstone == NULL) {
                    FirstTombstone = Entry;
                }
                continue;
            }
            if (Existing == 0u) {
                if (!Create) {
                    return NULL;
                }
                GQPLUS_CONNECTION_TRACK_ENTRY* Target =
                    FirstTombstone != NULL ? FirstTombstone : Entry;
                uintptr_t Expected =
                    FirstTombstone != NULL ?
                        GQPLUS_CONNECTION_TRACK_TOMBSTONE : 0u;
                if (atomic_compare_exchange_strong_explicit(
                        &Target->Key,
                        &Expected,
                        Key,
                        memory_order_acq_rel,
                        memory_order_acquire)) {
                    atomic_store_explicit(
                        &Target->RxLcorePlusOne, 0u, memory_order_relaxed);
                    atomic_store_explicit(
                        &Target->RxQueuePlusOne, 0u, memory_order_relaxed);
                    atomic_store_explicit(
                        &Target->RecoveryLcorePlusOne, 0u, memory_order_relaxed);
                    atomic_store_explicit(
                        &Target->LastRxNs, 0u, memory_order_relaxed);
                    return Target;
                }
                break; // A racing insertion changed the slot; retry the table.
            }
        }

        // A table can contain no never-used zero slot after many sequential
        // connections even though every old entry is now a tombstone. Reuse a
        // tombstone after the full probe instead of permanently disabling
        // tracking once all slots have been touched at least once.
        if (Create && FirstTombstone != NULL) {
            uintptr_t Expected = GQPLUS_CONNECTION_TRACK_TOMBSTONE;
            if (atomic_compare_exchange_strong_explicit(
                    &FirstTombstone->Key,
                    &Expected,
                    Key,
                    memory_order_acq_rel,
                    memory_order_acquire)) {
                atomic_store_explicit(
                    &FirstTombstone->RxLcorePlusOne,
                    0u,
                    memory_order_relaxed);
                atomic_store_explicit(
                    &FirstTombstone->RxQueuePlusOne,
                    0u,
                    memory_order_relaxed);
                atomic_store_explicit(
                    &FirstTombstone->RecoveryLcorePlusOne,
                    0u,
                    memory_order_relaxed);
                atomic_store_explicit(
                    &FirstTombstone->LastRxNs,
                    0u,
                    memory_order_relaxed);
                return FirstTombstone;
            }
        }
    }
    return NULL;
}

static uint16_t
CxPlatGreenQuicPlusStoredMinusOne(atomic_uint_fast32_t* Value)
{
    const uint_fast32_t Stored = atomic_load_explicit(
        Value,
        memory_order_acquire);
    return Stored == 0u ?
        GQPLUS_LCORE_UNKNOWN : (uint16_t)(Stored - 1u);
}

void
CxPlatGreenQuicPlusTrackConnection(
    const void* ConnectionHandle,
    uint16_t RxLcore,
    uint16_t RxQueue
    )
{
    if (!CxPlatGreenQuicPlusValidLcore(RxLcore)) {
        return;
    }
    GQPLUS_CONNECTION_TRACK_ENTRY* Entry =
        CxPlatGreenQuicPlusFindConnectionEntry(ConnectionHandle, 1);
    if (Entry == NULL) {
        return;
    }

    atomic_store_explicit(
        &Entry->RxQueuePlusOne,
        RxQueue == GQPLUS_LCORE_UNKNOWN ? 0u : (uint_fast32_t)RxQueue + 1u,
        memory_order_relaxed);
    atomic_store_explicit(
        &Entry->LastRxNs,
        CxPlatGreenQuicPlusNowNs(),
        memory_order_relaxed);
    atomic_store_explicit(
        &Entry->RxLcorePlusOne,
        (uint_fast32_t)RxLcore + 1u,
        memory_order_release);
}

uint16_t
CxPlatGreenQuicPlusGetConnectionRxLcore(const void* ConnectionHandle)
{
    GQPLUS_CONNECTION_TRACK_ENTRY* Entry =
        CxPlatGreenQuicPlusFindConnectionEntry(ConnectionHandle, 0);
    return Entry == NULL ? GQPLUS_LCORE_UNKNOWN :
        CxPlatGreenQuicPlusStoredMinusOne(&Entry->RxLcorePlusOne);
}

uint16_t
CxPlatGreenQuicPlusGetConnectionRxQueue(const void* ConnectionHandle)
{
    GQPLUS_CONNECTION_TRACK_ENTRY* Entry =
        CxPlatGreenQuicPlusFindConnectionEntry(ConnectionHandle, 0);
    return Entry == NULL ? GQPLUS_LCORE_UNKNOWN :
        CxPlatGreenQuicPlusStoredMinusOne(&Entry->RxQueuePlusOne);
}

void
CxPlatGreenQuicPlusSetTxOwnerLcore(uint16_t Lcore)
{
    if (CxPlatGreenQuicPlusValidLcore(Lcore)) {
        atomic_store_explicit(
            &TxOwnerLcorePlusOne,
            (uint_fast32_t)Lcore + 1u,
            memory_order_release);
    }
}

void
CxPlatGreenQuicPlusClearTxOwnerLcore(uint16_t Lcore)
{
    uint_fast32_t Expected = (uint_fast32_t)Lcore + 1u;
    (void)atomic_compare_exchange_strong_explicit(
        &TxOwnerLcorePlusOne,
        &Expected,
        0u,
        memory_order_acq_rel,
        memory_order_acquire);
}

uint16_t
CxPlatGreenQuicPlusGetTxOwnerLcore(void)
{
    return CxPlatGreenQuicPlusStoredMinusOne(&TxOwnerLcorePlusOne);
}
// GREENQUIC-END: V21 lock-free connection lookup helpers.
'''
        c = c[:valid_partition_end] + table_helpers + c[valid_partition_end:]

    if 'CxPlatGreenQuicPlusPulseHintsForConnection' not in c:
        _, recovery_end = _gq_find_c_function_span(c, 'CxPlatGreenQuicPlusEndRecoveryForLcore')
        routing_impl = r'''

// GREENQUIC-BEGIN: V21 exact connection-routed hints and transfers.
static void
CxPlatGreenQuicPlusIncrementLcoreTransfer(
    uint16_t Lcore,
    atomic_uint_fast32_t* Counter,
    uint64_t Hint
    )
{
    const uint_fast32_t Old = atomic_fetch_add_explicit(
        Counter,
        1u,
        memory_order_relaxed);
    if (Old == 0u) {
        atomic_fetch_or_explicit(
            &LcorePersistentHints[Lcore],
            Hint,
            memory_order_release);
    }
}

static void
CxPlatGreenQuicPlusDecrementLcoreTransfer(
    uint16_t Lcore,
    atomic_uint_fast32_t* Counter,
    uint64_t Hint
    )
{
    uint_fast32_t Old = atomic_load_explicit(Counter, memory_order_relaxed);
    while (Old != 0u) {
        if (atomic_compare_exchange_weak_explicit(
                Counter,
                &Old,
                Old - 1u,
                memory_order_acq_rel,
                memory_order_relaxed)) {
            if (Old == 1u) {
                atomic_fetch_and_explicit(
                    &LcorePersistentHints[Lcore],
                    ~Hint,
                    memory_order_release);
            }
            return;
        }
    }
}

void
CxPlatGreenQuicPlusBeginTransferForLcore(
    uint16_t Lcore,
    uint64_t Hints
    )
{
    if (!CxPlatGreenQuicPlusValidLcore(Lcore)) {
        CxPlatGreenQuicPlusBeginTransfer(Hints);
        return;
    }
    if ((Hints & GQPLUS_HINT_SERVER_FILE_TX_ACTIVE) != 0u) {
        CxPlatGreenQuicPlusIncrementLcoreTransfer(
            Lcore,
            &LcoreServerFileTxActiveCount[Lcore],
            GQPLUS_HINT_SERVER_FILE_TX_ACTIVE);
    }
    if ((Hints & GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE) != 0u) {
        CxPlatGreenQuicPlusIncrementLcoreTransfer(
            Lcore,
            &LcoreClientFileRxActiveCount[Lcore],
            GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE);
    }
}

void
CxPlatGreenQuicPlusEndTransferForLcore(
    uint16_t Lcore,
    uint64_t Hints
    )
{
    if (!CxPlatGreenQuicPlusValidLcore(Lcore)) {
        CxPlatGreenQuicPlusEndTransfer(Hints);
        return;
    }
    if ((Hints & GQPLUS_HINT_SERVER_FILE_TX_ACTIVE) != 0u) {
        CxPlatGreenQuicPlusDecrementLcoreTransfer(
            Lcore,
            &LcoreServerFileTxActiveCount[Lcore],
            GQPLUS_HINT_SERVER_FILE_TX_ACTIVE);
    }
    if ((Hints & GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE) != 0u) {
        CxPlatGreenQuicPlusDecrementLcoreTransfer(
            Lcore,
            &LcoreClientFileRxActiveCount[Lcore],
            GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE);
    }
}

uint16_t
CxPlatGreenQuicPlusBeginTransferForConnection(
    const void* ConnectionHandle,
    uint64_t Hints
    )
{
    uint16_t Lcore = GQPLUS_LCORE_UNKNOWN;
    if ((Hints & GQPLUS_HINT_SERVER_FILE_TX_ACTIVE) != 0u) {
        Lcore = CxPlatGreenQuicPlusGetTxOwnerLcore();
    }
    if (!CxPlatGreenQuicPlusValidLcore(Lcore)) {
        Lcore = CxPlatGreenQuicPlusGetConnectionRxLcore(ConnectionHandle);
    }
    CxPlatGreenQuicPlusBeginTransferForLcore(Lcore, Hints);
    return Lcore;
}

void
CxPlatGreenQuicPlusPulseHintsForConnection(
    const void* ConnectionHandle,
    uint16_t FallbackPartition,
    uint64_t Hints
    )
{
    uint16_t Lcore =
        CxPlatGreenQuicPlusGetConnectionRxLcore(ConnectionHandle);
    if (!CxPlatGreenQuicPlusValidLcore(Lcore)) {
        Lcore = CxPlatGreenQuicPlusGetPartitionDpdkLcore(FallbackPartition);
    }
    CxPlatGreenQuicPlusPulseHintsForLcore(Lcore, Hints);
}

void
CxPlatGreenQuicPlusBeginRecoveryForConnection(
    const void* ConnectionHandle,
    uint16_t FallbackPartition
    )
{
    uint16_t Lcore =
        CxPlatGreenQuicPlusGetConnectionRxLcore(ConnectionHandle);
    if (!CxPlatGreenQuicPlusValidLcore(Lcore)) {
        Lcore = CxPlatGreenQuicPlusGetPartitionDpdkLcore(FallbackPartition);
    }

    GQPLUS_CONNECTION_TRACK_ENTRY* Entry =
        CxPlatGreenQuicPlusFindConnectionEntry(ConnectionHandle, 1);
    if (Entry != NULL) {
        atomic_store_explicit(
            &Entry->RecoveryLcorePlusOne,
            CxPlatGreenQuicPlusValidLcore(Lcore) ?
                (uint_fast32_t)Lcore + 1u : 0u,
            memory_order_release);
    }
    CxPlatGreenQuicPlusBeginRecoveryForLcore(Lcore);
}

void
CxPlatGreenQuicPlusEndRecoveryForConnection(
    const void* ConnectionHandle,
    uint16_t FallbackPartition
    )
{
    uint16_t Lcore = GQPLUS_LCORE_UNKNOWN;
    GQPLUS_CONNECTION_TRACK_ENTRY* Entry =
        CxPlatGreenQuicPlusFindConnectionEntry(ConnectionHandle, 0);
    if (Entry != NULL) {
        const uint_fast32_t Stored = atomic_exchange_explicit(
            &Entry->RecoveryLcorePlusOne,
            0u,
            memory_order_acq_rel);
        if (Stored != 0u) {
            Lcore = (uint16_t)(Stored - 1u);
        }
    }
    if (!CxPlatGreenQuicPlusValidLcore(Lcore)) {
        Lcore = CxPlatGreenQuicPlusGetPartitionDpdkLcore(FallbackPartition);
    }
    CxPlatGreenQuicPlusEndRecoveryForLcore(Lcore);
}

void
CxPlatGreenQuicPlusUntrackConnection(const void* ConnectionHandle)
{
    GQPLUS_CONNECTION_TRACK_ENTRY* Entry =
        CxPlatGreenQuicPlusFindConnectionEntry(ConnectionHandle, 0);
    if (Entry == NULL) {
        return;
    }

    const uint_fast32_t RecoveryStored = atomic_exchange_explicit(
        &Entry->RecoveryLcorePlusOne,
        0u,
        memory_order_acq_rel);
    if (RecoveryStored != 0u) {
        CxPlatGreenQuicPlusEndRecoveryForLcore(
            (uint16_t)(RecoveryStored - 1u));
    }

    atomic_store_explicit(&Entry->RxLcorePlusOne, 0u, memory_order_relaxed);
    atomic_store_explicit(&Entry->RxQueuePlusOne, 0u, memory_order_relaxed);
    atomic_store_explicit(&Entry->LastRxNs, 0u, memory_order_relaxed);
    atomic_store_explicit(
        &Entry->Key,
        GQPLUS_CONNECTION_TRACK_TOMBSTONE,
        memory_order_release);
}
// GREENQUIC-END: V21 exact connection-routed hints and transfers.
'''
        c = c[:recovery_end] + routing_impl + c[recovery_end:]

    write_text(source, c)


def _gq_patch_core_connection_tracking(repo: Path) -> None:
    path = repo / 'src/core/connection.c'
    ensure_file(path)
    backup(path)
    text = read_text(path)

    if 'GREENQUIC-V21: bind the actual DPDK RX lcore' not in text:
        start, end = _gq_find_c_function_span(text, 'QuicConnRecvDatagrams')
        function = text[start:end]
        route_match = re.search(
            r'(?m)^(?P<i>[ \t]*)(?P<call>(?:CxPlatUpdateRoute|QuicCopyRouteInfo)\('             r'&DatagramPath->Route,[ \t]*Packet->Route\);)[ \t]*$',
            function)
        if route_match is None:
            raise RuntimeError(
                f'{path}: could not find route update after QuicConnGetPathForPacket')
        indent = route_match.group('i')
        tracking = (
            f'{indent}// GREENQUIC-V21: bind the actual DPDK RX lcore/queue to this connection.\n'
            f'{indent}if (Packet->GreenQuicRxProvenanceMagic ==\n'
            f'{indent}        CXPLAT_GREENQUIC_RX_PROVENANCE_MAGIC &&\n'
            f'{indent}    Packet->GreenQuicRxLcore !=\n'
            f'{indent}        CXPLAT_GREENQUIC_RX_LCORE_UNKNOWN) {{\n'
            f'{indent}    CxPlatGreenQuicPlusTrackConnection(\n'
            f'{indent}        (const void*)Connection,\n'
            f'{indent}        Packet->GreenQuicRxLcore,\n'
            f'{indent}        Packet->GreenQuicRxQueue);\n'
            f'{indent}}}\n')
        original_route = route_match.group(0)
        function = (
            function[:route_match.start()] + tracking + original_route +
            function[route_match.end():])
        text = text[:start] + function + text[end:]

    if 'GREENQUIC-V21: remove exact connection tracking' not in text:
        start, end = _gq_find_c_function_span(text, 'QuicConnFree')
        function = text[start:end]
        free_matches = list(re.finditer(
            r'(?ms)^(?P<i>[ \t]*)CxPlatPoolFree\([^;]*Connection[^;]*\);[ \t]*$',
            function))
        if not free_matches:
            raise RuntimeError(f'{path}: could not find final connection pool free')
        free_match = free_matches[-1]
        indent = free_match.group('i')
        cleanup = (
            f'{indent}// GREENQUIC-V21: remove exact connection tracking after core cleanup.\n'
            f'{indent}CxPlatGreenQuicPlusUntrackConnection((const void*)Connection);\n')
        function = (
            function[:free_match.start()] + cleanup + function[free_match.start():])
        text = text[:start] + function + text[end:]

    write_text(path, text)


def _gq_patch_core_hint_hooks(repo: Path) -> None:
    ack = repo / 'src/core/ack_tracker.c'
    cubic = repo / 'src/core/cubic.c'
    ensure_file(ack)
    ensure_file(cubic)
    backup(ack)
    backup(cubic)

    ack_text = read_text(ack)
    ack_text, ack_counts = _gq_replace_partition_calls_with_connection_tracking(
        ack_text,
        'CxPlatGreenQuicPlusPulseHintsForPartition',
        'CxPlatGreenQuicPlusPulseHintsForConnection',
        ['GQPLUS_HINT_ACK_PENDING'],
        str(ack))
    if ack_counts['GQPLUS_HINT_ACK_PENDING'] < 1 and not re.search(
            r'(?s)CxPlatGreenQuicPlusPulseHintsForConnection\s*\([^;]*'
            r'GQPLUS_HINT_ACK_PENDING[^;]*\);',
            ack_text):
        raise RuntimeError(
            f'{ack}: neither an old partition-routed ACK hook nor an already '
            'patched connection-routed ACK hook was found')
    write_text(ack, ack_text)

    cubic_text = read_text(cubic)
    cubic_text, blocked_counts = _gq_replace_partition_calls_with_connection_tracking(
        cubic_text,
        'CxPlatGreenQuicPlusPulseHintsForPartition',
        'CxPlatGreenQuicPlusPulseHintsForConnection',
        ['GQPLUS_HINT_CUBIC_CWND_BLOCKED', 'GQPLUS_HINT_CUBIC_RAMPING'],
        str(cubic))
    if blocked_counts['GQPLUS_HINT_CUBIC_CWND_BLOCKED'] < 1 and not re.search(
            r'(?s)CxPlatGreenQuicPlusPulseHintsForConnection\s*\([^;]*'
            r'GQPLUS_HINT_CUBIC_CWND_BLOCKED[^;]*\);',
            cubic_text):
        raise RuntimeError(
            f'{cubic}: neither an old nor an already patched cwnd-blocked hook was found')
    if blocked_counts['GQPLUS_HINT_CUBIC_RAMPING'] < 1 and not re.search(
            r'(?s)CxPlatGreenQuicPlusPulseHintsForConnection\s*\([^;]*'
            r'GQPLUS_HINT_CUBIC_RAMPING[^;]*\);',
            cubic_text):
        raise RuntimeError(
            f'{cubic}: neither an old nor an already patched cwnd-ramping hook was found')

    cubic_text, begin_counts = _gq_replace_partition_calls_with_connection_tracking(
        cubic_text,
        'CxPlatGreenQuicPlusBeginRecoveryForPartition',
        'CxPlatGreenQuicPlusBeginRecoveryForConnection',
        ['Connection->Worker', 'GQPLUS_PARTITION_UNKNOWN'],
        str(cubic))
    if sum(begin_counts.values()) < 1 and not re.search(
            r'(?s)CxPlatGreenQuicPlusBeginRecoveryForConnection\s*\(',
            cubic_text):
        raise RuntimeError(
            f'{cubic}: neither an old nor an already patched recovery begin hook was found')

    cubic_text, end_counts = _gq_replace_partition_calls_with_connection_tracking(
        cubic_text,
        'CxPlatGreenQuicPlusEndRecoveryForPartition',
        'CxPlatGreenQuicPlusEndRecoveryForConnection',
        ['Connection->Worker', 'GQPLUS_PARTITION_UNKNOWN'],
        str(cubic))
    if sum(end_counts.values()) < 1 and not re.search(
            r'(?s)CxPlatGreenQuicPlusEndRecoveryForConnection\s*\(',
            cubic_text):
        raise RuntimeError(
            f'{cubic}: neither an old nor an already patched recovery end hook was found')
    write_text(cubic, cubic_text)


def _gq_patch_server_transfer_tracking(repo: Path) -> None:
    header = repo / 'src/tools/interopserver/InteropServer.h'
    source = repo / 'src/tools/interopserver/InteropServer.cpp'
    ensure_file(header)
    ensure_file(source)
    backup(header)
    backup(source)

    h = read_text(header)
    if 'GreenQuicServerTxHintLcore' not in h:
        anchor = '    bool GreenQuicServerTxHintActive;\n'
        if anchor not in h:
            raise RuntimeError(f'{header}: missing V20 server transfer guard')
        h = h.replace(
            anchor,
            anchor + '    uint16_t GreenQuicServerTxHintLcore;\n',
            1)
    if 'GetGreenQuicConnection' not in h:
        # Insert a small public getter immediately before HttpConnection's first private section.
        anchor = '        return Status;\n    }\nprivate:\n    HQUIC QuicConnection;\n'
        if anchor not in h:
            raise RuntimeError(f'{header}: could not find HttpConnection private anchor')
        h = h.replace(
            anchor,
            '        return Status;\n    }\n'
            '    HQUIC GetGreenQuicConnection() const { return QuicConnection; }\n'
            'private:\n    HQUIC QuicConnection;\n',
            1)
    write_text(header, h)

    c = read_text(source)
    if 'GreenQuicServerTxHintLcore(GQPLUS_LCORE_UNKNOWN)' not in c:
        old = 'GreenQuicServerTxHintActive(false)\n'
        if old not in c:
            raise RuntimeError(f'{source}: missing V20 server constructor guard')
        c = c.replace(
            old,
            'GreenQuicServerTxHintActive(false), '
            'GreenQuicServerTxHintLcore(GQPLUS_LCORE_UNKNOWN)\n',
            1)

    c = c.replace(
        'CxPlatGreenQuicPlusBeginTransfer(GQPLUS_HINT_SERVER_FILE_TX_ACTIVE);',
        'GreenQuicServerTxHintLcore =\n'
        '                CxPlatGreenQuicPlusBeginTransferForConnection(\n'
        '                    (const void*)Connection->GetGreenQuicConnection(),\n'
        '                    GQPLUS_HINT_SERVER_FILE_TX_ACTIVE);')

    # All server end sites use either member access or pThis member access.
    c = c.replace(
        'CxPlatGreenQuicPlusEndTransfer(GQPLUS_HINT_SERVER_FILE_TX_ACTIVE);',
        'CxPlatGreenQuicPlusEndTransferForLcore(\n'
        '            GreenQuicServerTxHintLcore,\n'
        '            GQPLUS_HINT_SERVER_FILE_TX_ACTIVE);',
        1)
    c = c.replace(
        'CxPlatGreenQuicPlusEndTransfer(GQPLUS_HINT_SERVER_FILE_TX_ACTIVE);',
        'CxPlatGreenQuicPlusEndTransferForLcore(\n'
        '                pThis->GreenQuicServerTxHintLcore,\n'
        '                GQPLUS_HINT_SERVER_FILE_TX_ACTIVE);')

    # Reset the stored destination at each matching end site.
    c = c.replace(
        'GreenQuicServerTxHintActive = false;\n',
        'GreenQuicServerTxHintActive = false;\n'
        '        GreenQuicServerTxHintLcore = GQPLUS_LCORE_UNKNOWN;\n',
        1)
    c = c.replace(
        'pThis->GreenQuicServerTxHintActive = false;\n',
        'pThis->GreenQuicServerTxHintActive = false;\n'
        '            pThis->GreenQuicServerTxHintLcore = GQPLUS_LCORE_UNKNOWN;\n')

    if 'CxPlatGreenQuicPlusBeginTransfer(GQPLUS_HINT_SERVER_FILE_TX_ACTIVE)' in c or \
       'CxPlatGreenQuicPlusEndTransfer(GQPLUS_HINT_SERVER_FILE_TX_ACTIVE)' in c:
        raise RuntimeError(f'{source}: a global server transfer call remained')
    write_text(source, c)


def _gq_patch_client_transfer_tracking(repo: Path) -> None:
    path = repo / 'src/tools/interop/interop.cpp'
    ensure_file(path)
    backup(path)
    text = read_text(path)

    if 'GreenQuicConnection' not in text:
        anchor = '    HQUIC Stream{};\n'
        if anchor not in text:
            raise RuntimeError(f'{path}: could not find InteropStream HQUIC member')
        text = text.replace(anchor, anchor + '    HQUIC GreenQuicConnection{};\n', 1)
    if 'GreenQuicClientRxHintLcore' not in text:
        anchor = '    bool GreenQuicClientRxHintActive;\n'
        if anchor not in text:
            raise RuntimeError(f'{path}: missing V20 client transfer guard')
        text = text.replace(anchor, anchor + '    uint16_t GreenQuicClientRxHintLcore;\n', 1)

    constructor_anchor = (
        '    InteropStream(HQUIC Connection, const char* Request) :\n'
        '        SendRequest(Request),\n')
    if 'GreenQuicConnection(Connection)' not in text:
        if constructor_anchor not in text:
            raise RuntimeError(f'{path}: could not find InteropStream constructor anchor')
        text = text.replace(
            constructor_anchor,
            '    InteropStream(HQUIC Connection, const char* Request) :\n'
            '        GreenQuicConnection(Connection),\n'
            '        SendRequest(Request),\n',
            1)

    if 'GreenQuicClientRxHintLcore(GQPLUS_LCORE_UNKNOWN)' not in text:
        anchor = '        GreenQuicClientRxHintActive(false),\n'
        if anchor not in text:
            raise RuntimeError(f'{path}: missing V20 client constructor guard')
        text = text.replace(
            anchor,
            anchor + '        GreenQuicClientRxHintLcore(GQPLUS_LCORE_UNKNOWN),\n',
            1)

    text = text.replace(
        'CxPlatGreenQuicPlusBeginTransfer(GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE);',
        'pThis->GreenQuicClientRxHintLcore =\n'
        '                            CxPlatGreenQuicPlusBeginTransferForConnection(\n'
        '                                (const void*)pThis->GreenQuicConnection,\n'
        '                                GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE);')

    # Destructor uses direct members; callbacks use pThis.
    text = text.replace(
        'CxPlatGreenQuicPlusEndTransfer(GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE);',
        'CxPlatGreenQuicPlusEndTransferForLcore(\n'
        '                GreenQuicClientRxHintLcore,\n'
        '                GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE);',
        1)
    text = text.replace(
        'CxPlatGreenQuicPlusEndTransfer(GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE);',
        'CxPlatGreenQuicPlusEndTransferForLcore(\n'
        '                        pThis->GreenQuicClientRxHintLcore,\n'
        '                        GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE);')

    text = text.replace(
        'GreenQuicClientRxHintActive = false;\n',
        'GreenQuicClientRxHintActive = false;\n'
        '            GreenQuicClientRxHintLcore = GQPLUS_LCORE_UNKNOWN;\n',
        1)
    text = text.replace(
        'pThis->GreenQuicClientRxHintActive = false;\n',
        'pThis->GreenQuicClientRxHintActive = false;\n'
        '                    pThis->GreenQuicClientRxHintLcore = GQPLUS_LCORE_UNKNOWN;\n')

    if 'CxPlatGreenQuicPlusBeginTransfer(GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE)' in text or \
       'CxPlatGreenQuicPlusEndTransfer(GQPLUS_HINT_CLIENT_FILE_RX_ACTIVE)' in text:
        raise RuntimeError(f'{path}: a global client transfer call remained')
    write_text(path, text)


def _gq_append_trackconnection_config_note(repo: Path) -> None:
    path = repo / 'dpdk.greenquic.example.ini'
    if not path.exists():
        return
    text = read_text(path)
    if 'V21 --trackconnection build-time option' not in text:
        text += r'''

# V21 --trackconnection build-time option
# ---------------------------------------
# No runtime boolean is required. When the autopatcher is run with
# --enable-multi-core --trackconnection, each DPDK receive packet is stamped with
# its actual RX lcore and queue. MsQuic associates that provenance with the exact
# connection before ACK/CUBIC processing. GreenQuicPartitionDpdkMap remains only
# a fallback until the first packet for a connection is observed.
'''
        write_text(path, text)


def _validate_v21_trackconnection(repo: Path) -> None:
    required = {
        repo / 'src/inc/quic_datapath.h': [
            'CXPLAT_GREENQUIC_RX_PROVENANCE_MAGIC',
            'GreenQuicRxLcore',
            'GreenQuicRxQueue',
        ],
        repo / 'src/platform/datapath_raw_dpdk.c': [
            'GreenQuicRxProvenanceMagic = CXPLAT_GREENQUIC_RX_PROVENANCE_MAGIC',
            'CxPlatGreenQuicPlusSetTxOwnerLcore',
            'CxPlatGreenQuicPlusClearTxOwnerLcore',
        ],
        repo / 'src/inc/greenquic_plus.h': [
            'CxPlatGreenQuicPlusTrackConnection',
            'CxPlatGreenQuicPlusPulseHintsForConnection',
            'CxPlatGreenQuicPlusBeginTransferForConnection',
        ],
        repo / 'src/platform/greenquic_plus.c': [
            'GQPLUS_CONNECTION_TRACK_SLOTS',
            'CxPlatGreenQuicPlusFindConnectionEntry',
            'A table can contain no never-used zero slot',
            'CxPlatGreenQuicPlusBeginRecoveryForConnection',
            'LcoreClientFileRxActiveCount',
            'TxOwnerLcorePlusOne',
        ],
        repo / 'src/core/connection.c': [
            'GREENQUIC-V21: bind the actual DPDK RX lcore',
            'CxPlatGreenQuicPlusTrackConnection',
            'CxPlatGreenQuicPlusUntrackConnection',
        ],
        repo / 'src/core/ack_tracker.c': [
            'CxPlatGreenQuicPlusPulseHintsForConnection',
            'GQPLUS_HINT_ACK_PENDING',
        ],
        repo / 'src/core/cubic.c': [
            'CxPlatGreenQuicPlusPulseHintsForConnection',
            'CxPlatGreenQuicPlusBeginRecoveryForConnection',
            'CxPlatGreenQuicPlusEndRecoveryForConnection',
        ],
        repo / 'src/tools/interopserver/InteropServer.cpp': [
            'CxPlatGreenQuicPlusBeginTransferForConnection',
            'GreenQuicServerTxHintLcore',
        ],
        repo / 'src/tools/interop/interop.cpp': [
            'CxPlatGreenQuicPlusBeginTransferForConnection',
            'GreenQuicClientRxHintLcore',
            'GreenQuicConnection',
        ],
    }
    missing: list[str] = []
    for path, tokens in required.items():
        ensure_file(path)
        text = read_text(path)
        for token in tokens:
            if token not in text:
                missing.append(f'{path.relative_to(repo)}::{token}')
    if missing:
        die(f'V21 --trackconnection validation failed; missing: {missing}')

    # These old direct partition calls may exist in disabled comments, but must
    # not remain as active line-start calls in the ACK/CUBIC files.
    for relative in ('src/core/ack_tracker.c', 'src/core/cubic.c'):
        text = read_text(repo / relative)
        active_old = re.findall(
            r'(?m)^[ \t]*CxPlatGreenQuicPlus(?:PulseHints|BeginRecovery|EndRecovery)ForPartition\(',
            text)
        if active_old:
            die(f'V21 --trackconnection validation found active old partition calls in {relative}')

    log('V21 --trackconnection generated-tree validation passed.')


def patch_trackconnection(repo: Path) -> None:
    """Add exact actual-RX-lcore connection attribution on top of complete V20."""
    for relative in (
        'src/inc/quic_datapath.h',
        'src/platform/datapath_raw_dpdk.c',
        'src/inc/greenquic_plus.h',
        'src/platform/greenquic_plus.c',
        'src/core/connection.c',
        'src/core/ack_tracker.c',
        'src/core/cubic.c',
        'src/tools/interopserver/InteropServer.h',
        'src/tools/interopserver/InteropServer.cpp',
        'src/tools/interop/interop.cpp',
    ):
        ensure_file(repo / relative)

    _gq_patch_recv_provenance_header(repo)
    _gq_patch_dpdk_recv_stamp_and_tx_owner(repo)
    _gq_patch_tracking_hint_api(repo)
    _gq_patch_core_connection_tracking(repo)
    _gq_patch_core_hint_hooks(repo)
    _gq_patch_server_transfer_tracking(repo)
    _gq_patch_client_transfer_tracking(repo)
    _gq_append_trackconnection_config_note(repo)
    _validate_v21_trackconnection(repo)
    log(
        'V21 exact connection tracking patched: actual DPDK RX provenance is '
        'the primary ACK/CUBIC/client-RX hint destination; partition mapping is fallback.')


# Preserve references to the final V20 entry points for auditing/debugging.
_parse_args_v20_complete = parse_args
_apply_all_patches_v20_complete = apply_all_patches
_main_v20_complete = main


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=(
            'Full GreenQUIC / GreenQUIC+ local autopatcher v21.2: complete V20 '
            'selectable-idle implementation plus optional exact connection '
            'to DPDK RX-lcore tracking'))
    p.add_argument('--git-url', default=None)
    p.add_argument('--repo-dir', default=None, help='Existing repo dir or clone target')
    p.add_argument('--checkout', default=None, help='Branch/tag/commit, e.g. origin/main')
    p.add_argument('--branch', default=None, help='New branch for edits')
    p.add_argument('--basic-only', action='store_true', help='Do not patch ACK/CUBIC/tool hooks; run BASIC mode only')
    p.add_argument('--yes', action='store_true', help='Do not ask before applying patches')
    p.add_argument('--no-build', action='store_true')
    p.add_argument('--build-dir', default=None)
    p.add_argument('--build-type', default=None)
    p.add_argument('--tls', default=None)
    p.add_argument('--jobs', type=int, default=None)
    p.add_argument('--dpdk-mode', choices=['local', 'system', 'windows'], default='local',
                   help='local: build/use ./deps/dpdk-install by default; system: use existing pkg-config libdpdk; windows: keep Windows PMD DLL path and skip local Linux DPDK build')
    p.add_argument('--dpdk-dir', default=None, help='Local DPDK source folder. Default: <repo>/deps/dpdk')
    p.add_argument('--dpdk-install-dir', default=None, help='Local DPDK install prefix. Default: <repo>/deps/dpdk-install. If given and libdpdk.pc is not in standard paths, v13 recursively searches below it.')
    p.add_argument('--dpdk-search-root', default=None, help='Arbitrary existing DPDK folder to search recursively for libdpdk.pc, libdpdk/librte libraries, and Linux PMD/plugin driver directories; e.g. ./mohsen/dpdk21')
    p.add_argument('--dpdk-git-url', default='https://github.com/DPDK/dpdk.git', help='DPDK git URL. Default: official DPDK repo')
    p.add_argument('--dpdk-checkout', default=RECOMMENDED_DPDK_CHECKOUT, help=f'DPDK tag/branch to build locally. Recommended: {RECOMMENDED_DPDK_CHECKOUT} (DPDK 21.11 LTS final). Fallback: {FALLBACK_DPDK_CHECKOUT}. 22.11 may also work, but test NIC/PMD compatibility.')
    p.add_argument('--force-dpdk-build', action='store_true', help='Delete/rebuild the local DPDK build directory')
    p.add_argument('--no-dpdk-build', action='store_true', help='Do not build DPDK; fail if local libdpdk is not found')
    p.add_argument('--enable-example-logging', action='store_true', help='Print dpdk.ini examples with GreenQuic logging enabled; generated code still defaults logging off')
    p.add_argument('--enable-multi-core', action='store_true', help='Patch optional multi-core DPDK: one RX queue per RX owner, one dedicated TX consumer/queue, optional TX-only owner, and partition-to-RX-lcore ACK/CUBIC hints. Runtime still requires GreenQuicEnableMultiCore=1.')
    p.add_argument(
        '--trackconnection', '--track-connection',
        dest='trackconnection',
        action='store_true',
        help=(
            'Requires --enable-multi-core and PLUS hooks. Stamp every DPDK RX '
            'packet with its actual lcore/queue, associate it with the exact '
            'MsQuic connection before packet processing, and route ACK/CUBIC '
            'and file-transfer hints using the latest observed RX location '
            'for that connection. '
            'GreenQuicPartitionDpdkMap remains fallback only.'))
    return p.parse_args()


# Keep the full V20 apply function above; this V21 definition is active.
def apply_all_patches(
    repo: Path,
    basic_only: bool,
    enable_multi_core: bool = False,
    track_connection: bool = False,
    ) -> None:
    if track_connection and not enable_multi_core:
        die('--trackconnection requires --enable-multi-core.')
    if track_connection and basic_only:
        die('--trackconnection requires PLUS hooks; do not combine it with --basic-only.')

    existing = _detect_existing_greenquic_mode(repo)
    requested = 'multi' if enable_multi_core else 'single'
    if existing != 'none' and existing != requested:
        die(
            f'Existing GreenQUIC patch mode is {existing}, but this run requests '
            f'{requested}. Restore .greenquic.bak files or use a clean tree. '
            'V21 refuses to mix incompatible single/multi APIs.')

    patch_greenquic_plus_files(repo)
    patch_datapath(repo)
    if basic_only:
        warn(
            'BASIC-only selected: hint files are compiled, but ACK/CUBIC/tool '
            'hooks are skipped. Run GreenQuicMode=basic.')
    else:
        patch_precomp(repo)
        patch_ack_tracker(repo)
        patch_cubic(repo)
        patch_server_header(repo)
        patch_server_tool(repo)
        patch_client_tool(repo)

    patch_cmake(repo)
    if enable_multi_core:
        patch_multicore_support(repo, basic_only)
    else:
        log(
            'Optional multi-core patch not requested; keeping one RX queue and '
            'one TX queue/consumer.')

    post_compile_safety_fixes(repo, enable_multi_core)
    patch_directional_pressure_policy(repo, enable_multi_core)
    patch_role_complete_directional_policy(repo, enable_multi_core)
    patch_separated_signal_ewma_and_powermng(repo, enable_multi_core)
    patch_safe_cstate_idle(repo)
    patch_selectable_idle_modes(repo)

    if track_connection:
        patch_trackconnection(repo)

    _validate_v18_generated_tree(repo, enable_multi_core, basic_only)
    if track_connection:
        _validate_v21_trackconnection(repo)
    log(
        'All V21.2 patches applied (complete V20 selectable idle modes' +
        (' + exact connection tracking).' if track_connection else ').'))


def main() -> None:
    args = parse_args()

    if args.trackconnection and not args.enable_multi_core:
        die('--trackconnection requires --enable-multi-core.')
    if args.trackconnection and args.basic_only:
        die('--trackconnection requires PLUS hooks; remove --basic-only.')

    for tool in ('git', 'cmake'):
        if shutil.which(tool) is None:
            die(f'Required tool missing from PATH: {tool}')

    print(f"""
GreenQUIC full autopatcher v21.2 - complete V20 + audited connection tracking

This creates the full GreenQUIC + GreenQUIC+ code path:
  - every V20 feature and source-editing block remains present unchanged above
  - BASIC mode: DPDK RX/TX observation + RX queue pressure + proportional pressure + EWMA + step-up/step-down/max DVFS
  - PLUS mode: BASIC mode + ACK/CUBIC/app hints with ref-counted app transfer hints
  - logging is off by default; enable with GreenQuicEnableLogging=1 or GreenQuicLogLevel=1
  - guarded ref-counted transfer hints, so repeated SendData callbacks do not leak active counters
  - separate RX burst/queue and TX burst/ring EWMAs; QUIC hints are direct configurable floors; RX/TX meet only at the final per-lcore action
  - all power thresholds, alpha values, floors, DVFS timings and sleep levels are tunable in powermng.ini
  - runtime GreenQuicIdleMode: off, short, pause, monitor, epoll, auto; default short
  - monitor wakes on RX descriptor work or explicit software wake after TX publication
  - epoll wakes on NIC RX interrupt or per-lcore eventfd; watchdog is safety-only
  - explicit RX-only, TX-only and RX+TX lcore roles; unowned directions are ignored
  - optional --enable-multi-core patch: one RX queue per RX owner + optional TX-only owner + efficient TX-owner hint aggregation
  - optional --trackconnection: actual DPDK RX lcore/queue is stamped into each packet and stored as the latest observed location for the exact MsQuic connection
  - with --trackconnection, ACK/CUBIC hints use the connection latest observed RX attribution; GreenQuicPartitionDpdkMap is fallback only
  - with --trackconnection, server file TX targets the known TX owner and client file RX targets the learned RX lcore
  - power init/cleanup per DPDK worker lcore
  - local CMake build only, no sudo, no system install
  - default DPDK mode is local: ./deps/dpdk + ./deps/dpdk-install
  - can recursively search an existing DPDK folder with --dpdk-search-root ./mohsen/dpdk21
  - recommended local DPDK checkout: {RECOMMENDED_DPDK_CHECKOUT}
""")

    repo = clone_or_use_repo(args)
    prepare_branch(repo, args)
    check_expected_files(repo)

    if args.trackconnection:
        for relative in (
            'src/inc/quic_datapath.h',
            'src/core/connection.c',
            'src/tools/interopserver/InteropServer.h',
        ):
            ensure_file(repo / relative)

    if not args.yes:
        print('\nThe script will now edit files and create .greenquic.bak backups.')
        if not ask_yes('Apply full GreenQUIC patches now?', default=False):
            die('Stopped before patching.')

    apply_all_patches(
        repo,
        basic_only=args.basic_only,
        enable_multi_core=args.enable_multi_core,
        track_connection=args.trackconnection)

    if not args.no_build:
        prepare_dpdk(repo, args)
        if args.yes or ask_yes('Run local CMake build now?', default=True):
            build_repo(repo, args)
        else:
            warn('Build skipped.')

    print_test_guide(repo)
    if args.trackconnection:
        print(r'''
V21 --trackconnection verification checklist:
  1. Run with GreenQuicEnableMultiCore=1 and at least two RX-owner lcores.
  2. Use separate QUIC connections/UDP 5-tuples so RSS can distribute work.
  3. Enable diagnostic logging and verify each lcore's rxh/txh plus packet counts.
  4. Correlate source-port/RSS placement with the per-lcore rxh/txh output; the tracker itself does not add a separate log stream.
  5. Disable logging for final energy measurements.
''')

if __name__ == "__main__":
    main()
