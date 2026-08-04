/*++

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

// GREENQUIC-V18-DIRECTIONAL-RXTX: global mirrors read only by the TX owner.
static atomic_uint_fast64_t GlobalTxAckUntilNs;
static atomic_uint_fast64_t GlobalTxRecoveryPulseUntilNs;
static atomic_uint_fast64_t GlobalTxRampingUntilNs;
static atomic_uint_fast32_t GlobalTxRecoveryActiveCount;

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
    atomic_fetch_add_explicit(
        &GlobalTxRecoveryActiveCount,
        1,
        memory_order_relaxed);
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
    // Mirror only TX-relevant transient information for the TX owner.
    if ((Hints & GQPLUS_HINT_ACK_PENDING) != 0) {
        CxPlatGreenQuicPlusExtendUntil(
            &GlobalTxAckUntilNs,
            Now + GQPLUS_ACK_TTL_NS);
    }
    if ((Hints & GQPLUS_HINT_CUBIC_RECOVERY) != 0) {
        CxPlatGreenQuicPlusExtendUntil(
            &GlobalTxRecoveryPulseUntilNs,
            Now + GQPLUS_RECOVERY_PULSE_NS);
    }
    if ((Hints & GQPLUS_HINT_CUBIC_RAMPING) != 0) {
        CxPlatGreenQuicPlusExtendUntil(
            &GlobalTxRampingUntilNs,
            Now + GQPLUS_RAMPING_TTL_NS);
    }

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
