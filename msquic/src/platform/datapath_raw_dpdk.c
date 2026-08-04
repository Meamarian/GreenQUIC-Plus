/*++

    Copyright (c) Microsoft Corporation.
    Licensed under the MIT License.

Abstract:

    QUIC DPDK Datapath Implementation (User Mode)

    - Requires Clang to build
    - Leverages Mellanox PMD (requires CX4 or CX5)

--*/

#define _CRT_SECURE_NO_WARNINGS 1 // TODO - Remove
#define ALLOW_EXPERIMENTAL_API 1

#include "datapath_raw.h"
#include "greenquic_plus.h"
#ifdef QUIC_CLOG
#include "datapath_raw_dpdk.c.clog.h"
#endif

#include <rte_memory.h>
#include <rte_launch.h>
#include <rte_eal.h>
#include <rte_per_lcore.h>
#include <rte_lcore.h>
#include <rte_debug.h>
#include <rte_ethdev.h>
#include <rte_mbuf_core.h>
#include <rte_cycles.h>
#include <rte_pause.h>
#include <rte_power.h>
// GREENQUIC-V19-SAFE-CSTATE-IDLE
// rte_power_pause() is optional and architecture-dependent. Do not assume that
// presence of the header means the current CPU/kernel supports the instruction.
#if defined(__has_include)
#if __has_include(<rte_power_intrinsics.h>) && __has_include(<rte_cpuflags.h>)
#include <rte_power_intrinsics.h>
#include <rte_cpuflags.h>
#define GREENQUIC_HAVE_POWER_PAUSE_API 1
#define GREENQUIC_HAVE_POWER_MONITOR_API 1
#endif
#endif
#ifndef GREENQUIC_HAVE_POWER_PAUSE_API
#define GREENQUIC_HAVE_POWER_PAUSE_API 0
#endif
#ifndef GREENQUIC_HAVE_POWER_MONITOR_API
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
#include <inttypes.h>
#include <stdlib.h>
// GREENQUIC-BEGIN: DPDK RSS compatibility aliases

#ifndef RTE_ETH_MQ_RX_RSS
#define RTE_ETH_MQ_RX_RSS ETH_MQ_RX_RSS
#endif
#ifndef RTE_ETH_RSS_IP
#define RTE_ETH_RSS_IP ETH_RSS_IP
#endif
#ifndef RTE_ETH_RSS_UDP
#define RTE_ETH_RSS_UDP ETH_RSS_UDP
#endif
// GREENQUIC-END

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
#ifndef _WIN32
#include <strings.h>
#else
#define strcasecmp _stricmp
#endif

#define NUM_MBUFS 8191
#define MBUF_CACHE_SIZE 250
#define RX_BURST_SIZE 16
#define TX_BURST_SIZE 16
#define TX_RING_SIZE 1024

// GREENQUIC-BEGIN: mode, profile and runtime state

#define DEFAULT_GREENQUIC_MODE                   GREENQUIC_MODE_OFF
#define DEFAULT_GREENQUIC_PROFILE                GREENQUIC_PROFILE_SYMMETRIC
#define DEFAULT_GREENQUIC_FREQ_PERIOD_US         100000U
/* GREENQUIC-OLD-V17: DEFAULT_GREENQUIC_FREQ_UP_PERIOD_US was 1000U. */
#define DEFAULT_GREENQUIC_FREQ_UP_PERIOD_US      500U
#define DEFAULT_GREENQUIC_FREQ_DOWN_PERIOD_US    5000U
#define DEFAULT_GREENQUIC_FREQ_MIN_IDLE_US       20000U
#define DEFAULT_GREENQUIC_RX_EMPTY_POLLS         50000U
#define DEFAULT_GREENQUIC_TX_EMPTY_POLLS         50000U
#define DEFAULT_GREENQUIC_RX_QUEUE_HIGH          64U
#define DEFAULT_GREENQUIC_RX_QUEUE_SAMPLE_PERIOD 64U
#define DEFAULT_GREENQUIC_TX_RING_HIGH           64U
#define DEFAULT_GREENQUIC_PRESSURE_MAX           900U
#define DEFAULT_GREENQUIC_PRESSURE_UP            600U
/* GREENQUIC-OLD-V17: DEFAULT_GREENQUIC_PRESSURE_KEEP was 200U. */
#define DEFAULT_GREENQUIC_PRESSURE_KEEP          250U
#define DEFAULT_GREENQUIC_FULL_BURST_MAX_COUNT   8U
#define DEFAULT_GREENQUIC_EWMA_RISE_SHIFT        1U
/* GREENQUIC-OLD-V17: DEFAULT_GREENQUIC_EWMA_FALL_SHIFT was 3U. */
#define DEFAULT_GREENQUIC_EWMA_FALL_SHIFT        2U
/* GREENQUIC-OLD-V17: DEFAULT_GREENQUIC_ACK_SLEEP_US was 2U. */
#define DEFAULT_GREENQUIC_ACK_SLEEP_US           1U
/* GREENQUIC-OLD-V17: DEFAULT_GREENQUIC_DATA_SLEEP_US was 0U. */
#define DEFAULT_GREENQUIC_DATA_SLEEP_US          2U
/* GREENQUIC-OLD-V17: DEFAULT_GREENQUIC_MAX_SLEEP_US was 5U. */
#define DEFAULT_GREENQUIC_MAX_SLEEP_US           2U
#define DEFAULT_GREENQUIC_STATS_PERIOD_US        0U
#define DEFAULT_GREENQUIC_LOG_LEVEL              0U
#define DEFAULT_GREENQUIC_ENABLE_FREQ            TRUE
/* GREENQUIC-OLD-V17: DEFAULT_GREENQUIC_ENABLE_SLEEP was FALSE. */
#define DEFAULT_GREENQUIC_ENABLE_SLEEP           TRUE
#define DEFAULT_GREENQUIC_NO_SLEEP_TX_RING       TRUE

#define GREENQUIC_PRESSURE_SCALE                 1000U

typedef enum GREENQUIC_MODE {
    GREENQUIC_MODE_OFF = 0,
    GREENQUIC_MODE_BASIC = 1,
    GREENQUIC_MODE_PLUS = 2
} GREENQUIC_MODE;

typedef enum GREENQUIC_IDLE_MODE {
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
    // GREENQUIC-V19-SAFE-CSTATE-IDLE: optimized-wait diagnostics.
    uint64_t CStateAttempts;
    uint64_t CStateSuccesses;
    uint64_t TotalCStateWaitUs;
    uint32_t LastCStateWaitUs;
    BOOLEAN CStateUnavailable;
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
    // GREENQUIC-V18-DIRECTIONAL-RXTX: independent directional state.
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
    BOOLEAN LastOwnsRx;
    BOOLEAN LastOwnsTx;
    // GREENQUIC-V18-SEPARATE-SIGNALS-POWERMNG
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
    const char* LastAction;
    BOOLEAN PowerInitialized;
    BOOLEAN PowerAvailable;
    BOOLEAN FreqIsMax;
} GREENQUIC_LCORE_STATE;

// GREENQUIC-END

typedef struct DPDK_INTERFACE {

    CXPLAT_INTERFACE;

    uint16_t Port;
    CXPLAT_LOCK TxLock;
    struct rte_mempool* MemoryPool;
    struct rte_ring* TxRingBuffer;

    // Constants
    char DeviceName[32];
} DPDK_INTERFACE;

typedef struct DPDK_DATAPATH {

    CXPLAT_DATAPATH_RAW;

    BOOLEAN Running;
    CXPLAT_THREAD DpdkThread;
    QUIC_STATUS StartStatus;
    CXPLAT_EVENT StartComplete;

    CXPLAT_POOL AdditionalInfoPool;

    DPDK_INTERFACE Interface; // TODO: support multiple NIC interfaces.
    uint16_t Cpu; // GREENQUIC: DPDK EAL primary lcore when GreenQuicDpdkLcores is not set.


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
    // GREENQUIC-V18-SEPARATE-SIGNALS-POWERMNG: all algorithm knobs.
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
    // GREENQUIC-V20-SELECTABLE-IDLE-MODES
    GREENQUIC_IDLE_MODE GreenQuicIdleMode;
    GREENQUIC_IDLE_FALLBACK GreenQuicIdleFallback;
    uint32_t GreenQuicWorkWaitMinIdleUs;
    uint32_t GreenQuicWorkWaitMinLevel;
    uint32_t GreenQuicIdleWatchdogUs;
    uint32_t GreenQuicEpollMaxEvents;
    BOOLEAN GreenQuicAllowWorkWaitDuringActiveTransfer;
    BOOLEAN GreenQuicPowerMonitorSupported;
    uint32_t GreenQuicAckPathMaxSleepUs;
    uint32_t GreenQuicDataPathMaxSleepUs;
    uint32_t GreenQuicMaxSleepUs;
    uint32_t GreenQuicStatsPeriodUs;
    uint32_t GreenQuicLogLevel;      // 0=off, 1=summary, 2=verbose
    char GreenQuicDpdkLcores[64];    // optional EAL -l string, e.g., "8" or "8,9"; no multi-queue magic
    BOOLEAN GreenQuicEnableMultiCore; // runtime opt-in: GreenQuicEnableMultiCore=1 enables multi-queue/RSS mapping
    uint16_t GreenQuicQueueCount;     // actual RX queue count used by optional multi-core path
    uint16_t GreenQuicTxOwnerLcore;  // dedicated shared-ring TX consumer
    BOOLEAN GreenQuicTxOwnerConfigured;
    BOOLEAN GreenQuicTxOwnerAlsoRx; // 0 makes TX owner TX-only
    uint16_t GreenQuicRxQueueByLcore[RTE_MAX_LCORE];
    uint16_t GreenQuicRxOwnerCount;
    uint32_t GreenQuicHintLocalityWindowUs; // gate global PLUS hints to lcores with recent local datapath activity
    BOOLEAN GreenQuicPartitionDpdkMapConfigured; // TRUE if GreenQuicPartitionDpdkMap was parsed from dpdk.ini
    // GREENQUIC-V18-ROLE-COMPLETE: explicit direction ownership.
    BOOLEAN GreenQuicEnableRx;
    BOOLEAN GreenQuicEnableTx;
    BOOLEAN GreenQuicEnableFreq;
    BOOLEAN GreenQuicEnableSleep;
    BOOLEAN GreenQuicNoSleepIfTxRingNotEmpty;
    GREENQUIC_LCORE_STATE GreenQuicLcore[RTE_MAX_LCORE];
    // GREENQUIC-END

} DPDK_DATAPATH;

typedef struct DPDK_RX_PACKET {
    CXPLAT_RECV_DATA;
    CXPLAT_ROUTE RouteStorage;
    struct rte_mbuf* Mbuf;
    CXPLAT_POOL* OwnerPool;
} DPDK_RX_PACKET;

typedef struct DPDK_TX_PACKET {
    CXPLAT_SEND_DATA;
    struct rte_mbuf* Mbuf;
    DPDK_DATAPATH* Dpdk;
    DPDK_INTERFACE* Interface;
} DPDK_TX_PACKET;

CXPLAT_STATIC_ASSERT(
    sizeof(DPDK_TX_PACKET) <= sizeof(DPDK_RX_PACKET),
    "Code assumes memory allocated for RX is enough for TX");

CXPLAT_THREAD_CALLBACK(CxPlatDpdkMainThread, Context);
static int CxPlatDpdkWorkerThread(_In_ void* Context);

// GREENQUIC-BEGIN: helper prototypes
static void GreenQuicSetDefaults(_Inout_ DPDK_DATAPATH* Dpdk);
static const char* GreenQuicModeToString(_In_ GREENQUIC_MODE Mode);
static const char* GreenQuicProfileToString(_In_ GREENQUIC_PROFILE Profile);
static uint64_t GreenQuicTscDeltaToUs(_In_ uint64_t DeltaTsc);
static uint32_t GreenQuicMinU32(_In_ uint32_t A, _In_ uint32_t B);
static uint32_t GreenQuicMaxU32(_In_ uint32_t A, _In_ uint32_t B);
static uint32_t GreenQuicPressureFromRatio(_In_ uint64_t Value, _In_ uint64_t High);
static uint32_t GreenQuicUpdateEwma(_In_ uint32_t Avg, _In_ uint32_t Raw, _In_ uint32_t RiseShift, _In_ uint32_t FallShift);
static uint32_t GreenQuicPressureFromRatioConfigured(_In_ const DPDK_DATAPATH* Dpdk, _In_ uint64_t Value, _In_ uint64_t High);
static uint32_t GreenQuicUpdateEwmaAlpha(_In_ const DPDK_DATAPATH* Dpdk, _In_ uint32_t Avg, _In_ uint32_t Raw, _In_ uint32_t RiseAlphaPermille, _In_ uint32_t FallAlphaPermille);
static uint32_t GreenQuicAlphaPermilleFromShift(_In_ uint32_t Shift);
static BOOLEAN GreenQuicApplyPowerConfigValue(_Inout_ DPDK_DATAPATH* Dpdk, _In_ const char* Key, _In_ const char* Value);
static void GreenQuicReadPowerConfig(_Inout_ DPDK_DATAPATH* Dpdk);
static BOOLEAN GreenQuicIsDataPath(_In_ const DPDK_DATAPATH* Dpdk, _In_ GREENQUIC_DIR Dir);
static GREENQUIC_LCORE_STATE* GreenQuicGetLcoreState(_Inout_ DPDK_DATAPATH* Dpdk, _In_ uint16_t Core);
static uint16_t GreenQuicGetQueueId(_In_ const DPDK_DATAPATH* Dpdk, _In_ uint16_t Core);
static BOOLEAN GreenQuicHasLocalRecentActivity(_In_ const DPDK_DATAPATH* Dpdk, _In_ const GREENQUIC_LCORE_STATE* S);
static uint64_t GreenQuicGetHintsForCore(_In_ const DPDK_DATAPATH* Dpdk, _In_ const GREENQUIC_LCORE_STATE* S, _In_ uint16_t Core);
static void GreenQuicParsePartitionDpdkMap(_Inout_ DPDK_DATAPATH* Dpdk, _In_z_ const char* Value);
static void GreenQuicInstallDefaultPartitionDpdkMap(_Inout_ DPDK_DATAPATH* Dpdk);
static void GreenQuicPowerInit(_Inout_ DPDK_DATAPATH* Dpdk, _In_ uint16_t Core);
static void GreenQuicPowerCleanup(_Inout_ DPDK_DATAPATH* Dpdk, _In_ uint16_t Core);
static void GreenQuicFreqMax(_Inout_ DPDK_DATAPATH* Dpdk, _In_ uint16_t Core);
static void GreenQuicFreqUpStep(_Inout_ DPDK_DATAPATH* Dpdk, _In_ uint16_t Core);
static void GreenQuicFreqDownStep(_Inout_ DPDK_DATAPATH* Dpdk, _In_ uint16_t Core);
static void GreenQuicFreqMin(_Inout_ DPDK_DATAPATH* Dpdk, _In_ uint16_t Core);
static void GreenQuicSleepUs(_Inout_ DPDK_DATAPATH* Dpdk, _In_ uint16_t Core, _In_ uint32_t SleepUs);
static uint32_t GreenQuicGetSleepBudgetUs(_In_ const DPDK_DATAPATH* Dpdk, _In_ const GREENQUIC_LCORE_STATE* S, _In_ uint32_t TxRingCount, _In_ uint64_t RxHints, _In_ uint64_t TxHints, _In_ BOOLEAN OwnsRx, _In_ BOOLEAN OwnsTx);
static void GreenQuicInitCStateSupport(_Inout_ DPDK_DATAPATH* Dpdk);
static uint32_t GreenQuicGetEmptyLevel(_In_ const DPDK_DATAPATH* Dpdk, _In_ const GREENQUIC_LCORE_STATE* S, _In_ BOOLEAN OwnsRx, _In_ BOOLEAN OwnsTx);
static BOOLEAN GreenQuicCStateHintsBlock(_In_ const DPDK_DATAPATH* Dpdk, _In_ uint64_t RxHints, _In_ uint64_t TxHints, _In_ BOOLEAN OwnsRx, _In_ BOOLEAN OwnsTx);
static BOOLEAN GreenQuicTryCStateIdle(_Inout_ DPDK_DATAPATH* Dpdk, _In_ DPDK_INTERFACE* Interface, _Inout_ GREENQUIC_LCORE_STATE* S, _In_ uint16_t Core, _In_ uint64_t IdleUs, _In_ BOOLEAN OwnsRx, _In_ BOOLEAN OwnsTx);
static const char* GreenQuicIdleModeToString(_In_ GREENQUIC_IDLE_MODE Mode);
static GREENQUIC_IDLE_MODE GreenQuicParseIdleMode(_In_z_ const char* Value, _In_ GREENQUIC_IDLE_MODE DefaultMode);
static GREENQUIC_IDLE_FALLBACK GreenQuicParseIdleFallback(_In_z_ const char* Value, _In_ GREENQUIC_IDLE_FALLBACK DefaultMode);
static BOOLEAN GreenQuicCanEnterWorkWait(_In_ DPDK_DATAPATH* Dpdk, _In_ DPDK_INTERFACE* Interface, _In_ GREENQUIC_LCORE_STATE* S, _In_ uint16_t Core, _In_ uint64_t IdleUs, _In_ BOOLEAN OwnsRx, _In_ BOOLEAN OwnsTx);
static void GreenQuicSignalLcoreWork(_Inout_ DPDK_DATAPATH* Dpdk, _In_ uint16_t Core);
static void GreenQuicSignalTxWork(_Inout_ DPDK_DATAPATH* Dpdk);
static BOOLEAN GreenQuicTryMonitorWait(_Inout_ DPDK_DATAPATH* Dpdk, _In_ DPDK_INTERFACE* Interface, _Inout_ GREENQUIC_LCORE_STATE* S, _In_ uint16_t Core, _In_ uint64_t IdleUs, _In_ BOOLEAN OwnsRx, _In_ BOOLEAN OwnsTx);
static BOOLEAN GreenQuicTryEpollWait(_Inout_ DPDK_DATAPATH* Dpdk, _In_ DPDK_INTERFACE* Interface, _Inout_ GREENQUIC_LCORE_STATE* S, _In_ uint16_t Core, _In_ uint64_t IdleUs, _In_ BOOLEAN OwnsRx, _In_ BOOLEAN OwnsTx);
static BOOLEAN GreenQuicTrySelectedIdle(_Inout_ DPDK_DATAPATH* Dpdk, _In_ DPDK_INTERFACE* Interface, _Inout_ GREENQUIC_LCORE_STATE* S, _In_ uint16_t Core, _In_ uint64_t IdleUs, _In_ BOOLEAN OwnsRx, _In_ BOOLEAN OwnsTx);
static void GreenQuicIdleCleanupLcore(_Inout_ GREENQUIC_LCORE_STATE* S);
static void GreenQuicOnRxPoll(_Inout_ DPDK_DATAPATH* Dpdk, _In_ uint16_t Core, _In_ uint16_t BuffersCount, _In_ int RxQueueCountBefore);
static void GreenQuicOnTxPoll(_Inout_ DPDK_DATAPATH* Dpdk, _In_ uint16_t Core, _In_ uint32_t RingBefore, _In_ uint16_t BufferCount, _In_ uint16_t TxCount);
static BOOLEAN GreenQuicPlusHasActiveTransferHint(_In_ const DPDK_DATAPATH* Dpdk, _In_ uint64_t Hints);
static BOOLEAN GreenQuicLcoreOwnsRx(_In_ const DPDK_DATAPATH* Dpdk, _In_ uint16_t Core);
static BOOLEAN GreenQuicLcoreOwnsTx(_In_ const DPDK_DATAPATH* Dpdk, _In_ uint16_t Core);
static void GreenQuicGetDirectionalHintsForCore(_In_ const DPDK_DATAPATH* Dpdk, _In_ const GREENQUIC_LCORE_STATE* S, _In_ uint16_t Core, _Out_ uint64_t* RxHints, _Out_ uint64_t* TxHints);
static void GreenQuicPlusDirectionalPressure(_In_ const DPDK_DATAPATH* Dpdk, _In_ uint64_t RxHints, _In_ uint64_t TxHints, _In_ uint32_t RxPhysicalRaw, _In_ uint32_t TxPhysicalRaw, _In_ uint32_t RxPhysicalControl, _In_ uint32_t TxPhysicalControl, _In_ BOOLEAN OwnsRx, _In_ BOOLEAN OwnsTx, _Out_ uint32_t* RxQuicFloor, _Out_ uint32_t* TxQuicFloor, _Out_ BOOLEAN* RxHardMax, _Out_ BOOLEAN* TxHardMax);
static uint32_t GreenQuicComputeRawPressure(_In_ const DPDK_DATAPATH* Dpdk, _In_ GREENQUIC_LCORE_STATE* S, _In_ uint16_t Core, _In_ uint32_t TxRingCount, _Out_ BOOLEAN* HardMax);
static void GreenQuicApplyPolicy(_Inout_ DPDK_DATAPATH* Dpdk, _In_ DPDK_INTERFACE* Interface, _In_ uint16_t Core);
static void GreenQuicMaybePrintStats(_Inout_ DPDK_DATAPATH* Dpdk, _In_ uint16_t Core);
// GREENQUIC-END


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
    // GREENQUIC-V18-SEPARATE-SIGNALS-POWERMNG defaults.
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
    Dpdk->GreenQuicAckPathMaxSleepUs = DEFAULT_GREENQUIC_ACK_SLEEP_US;
    Dpdk->GreenQuicDataPathMaxSleepUs = DEFAULT_GREENQUIC_DATA_SLEEP_US;
    Dpdk->GreenQuicMaxSleepUs = DEFAULT_GREENQUIC_MAX_SLEEP_US;
    Dpdk->GreenQuicStatsPeriodUs = DEFAULT_GREENQUIC_STATS_PERIOD_US;
    Dpdk->GreenQuicLogLevel = DEFAULT_GREENQUIC_LOG_LEVEL;
    Dpdk->GreenQuicDpdkLcores[0] = '\0';
    Dpdk->GreenQuicEnableMultiCore = FALSE;
    Dpdk->GreenQuicQueueCount = 1;
    Dpdk->GreenQuicTxOwnerLcore = UINT16_MAX;
    Dpdk->GreenQuicTxOwnerConfigured = FALSE;
    Dpdk->GreenQuicTxOwnerAlsoRx = TRUE;
    Dpdk->GreenQuicRxOwnerCount = 0;
    for (uint32_t RoleIndex = 0; RoleIndex < RTE_MAX_LCORE; ++RoleIndex) {
        Dpdk->GreenQuicRxQueueByLcore[RoleIndex] = UINT16_MAX;
    }
    Dpdk->GreenQuicHintLocalityWindowUs = 2000;
    Dpdk->GreenQuicPartitionDpdkMapConfigured = FALSE;
    Dpdk->GreenQuicEnableRx = TRUE;
    Dpdk->GreenQuicEnableTx = TRUE;
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


static uint16_t
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
        if (LcoreCount < ARRAYSIZE(Lcores) &&
            Lcore <= UINT16_MAX &&
            GreenQuicLcoreOwnsRx(Dpdk, (uint16_t)Lcore)) {
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

#if 0
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

// GREENQUIC-V18-SEPARATE-SIGNALS-POWERMNG
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

    // GREENQUIC-V20-SELECTABLE-IDLE-MODES string values.
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

    // GREENQUIC-V19-SAFE-CSTATE-IDLE runtime values.
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

    // GREENQUIC-V20-SELECTABLE-IDLE-MODES sanitation and environment override.
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

static uint32_t
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


// GREENQUIC-V20-SELECTABLE-IDLE-MODES
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

// GREENQUIC-V19-SAFE-CSTATE-IDLE
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

#if 0
/* GREENQUIC-OLD-V17: old PLUS pressure policy retained verbatim below. */
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
#endif

static BOOLEAN
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

static void
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

static void
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

static uint32_t
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

    if (GreenQuicTrySelectedIdle(
            Dpdk, Interface, S, Core, IdleUs, OwnsRx, OwnsTx)) {
        return;
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
        "rx_empty=%u tx_empty=%u rx_full=%u tx_full=%u slept_us=%" PRIu64 " "
        "cstate_attempt=%" PRIu64 " cstate_ok=%" PRIu64 " "
        "cstate_last_us=%u cstate_total_us=%" PRIu64 " "
        "idle_mode=%s monitor_try=%" PRIu64 " monitor_wake=%" PRIu64 " monitor_timeout=%" PRIu64 " "
        "epoll_try=%" PRIu64 " epoll_wake=%" PRIu64 " epoll_timeout=%" PRIu64 " wake_signal=%" PRIu64 "\n",
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
        GreenQuicIdleModeToString(Dpdk->GreenQuicIdleMode),
        S->MonitorAttempts,
        S->MonitorWakeups,
        S->MonitorTimeouts,
        S->EpollAttempts,
        S->EpollWakeups,
        S->EpollTimeouts,
        S->WakeSignals);
}

// GREENQUIC-END

_IRQL_requires_max_(PASSIVE_LEVEL)
void
CxPlatDpdkReadConfig(
    _Inout_ DPDK_DATAPATH* Dpdk,
    _In_opt_ const QUIC_EXECUTION_CONFIG* Config
    )
{
    Dpdk->Cpu = (uint16_t)(CxPlatProcCount() - 1);
    GreenQuicSetDefaults(Dpdk);

    //
    // Read user-specified global config.
    //
    if (Config != NULL && Config->ProcessorCount != 0) {
        Dpdk->Cpu = Config->ProcessorList[0];
    }

    FILE *File = fopen("dpdk.ini", "r");
    if (File == NULL) {
        GreenQuicReadPowerConfig(Dpdk);
        GreenQuicInitCStateSupport(Dpdk);
        return;
    }

    char Line[256];
    while (fgets(Line, sizeof(Line), File) != NULL) {
        char* Value = strchr(Line, '=');
        if (Value == NULL) {
            continue;
        }
        *Value++ = '\0';
        if (Value[strlen(Value) - 1] == '\n') {
            Value[strlen(Value) - 1] = '\0';
        }

        if (strcmp(Line, "DeviceName") == 0) {
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
            {
                const uint32_t Alpha = GreenQuicAlphaPermilleFromShift(
                    Dpdk->GreenQuicEwmaRiseShift);
                Dpdk->GreenQuicRxBurstRiseAlphaPermille = Alpha;
                Dpdk->GreenQuicRxQueueRiseAlphaPermille = Alpha;
                Dpdk->GreenQuicTxBurstRiseAlphaPermille = Alpha;
                Dpdk->GreenQuicTxRingRiseAlphaPermille = Alpha;
            }
        } else if (strcmp(Line, "GreenQuicEwmaFallShift") == 0) {
            Dpdk->GreenQuicEwmaFallShift = (uint32_t)atoi(Value);
            {
                const uint32_t Alpha = GreenQuicAlphaPermilleFromShift(
                    Dpdk->GreenQuicEwmaFallShift);
                Dpdk->GreenQuicRxBurstFallAlphaPermille = Alpha;
                Dpdk->GreenQuicRxQueueFallAlphaPermille = Alpha;
                Dpdk->GreenQuicTxBurstFallAlphaPermille = Alpha;
                Dpdk->GreenQuicTxRingFallAlphaPermille = Alpha;
            }
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
        } else if (strcmp(Line, "GreenQuicEnableMultiCore") == 0) {
            Dpdk->GreenQuicEnableMultiCore = atoi(Value) != 0 ? TRUE : FALSE;
        } else if (strcmp(Line, "GreenQuicTxOwnerLcore") == 0) {
            Dpdk->GreenQuicTxOwnerLcore = (uint16_t)atoi(Value);
            Dpdk->GreenQuicTxOwnerConfigured = TRUE;
        } else if (strcmp(Line, "GreenQuicTxOwnerAlsoRx") == 0) {
            Dpdk->GreenQuicTxOwnerAlsoRx = atoi(Value) != 0 ? TRUE : FALSE;
        } else if (strcmp(Line, "GreenQuicHintLocalityWindowUs") == 0) {
            Dpdk->GreenQuicHintLocalityWindowUs = (uint32_t)atoi(Value);
            if (Dpdk->GreenQuicHintLocalityWindowUs == 0) {
                Dpdk->GreenQuicHintLocalityWindowUs = 1;
            }
        } else if (strcmp(Line, "GreenQuicPartitionDpdkMap") == 0) {
            GreenQuicParsePartitionDpdkMap(Dpdk, Value);
        } else if (strcmp(Line, "GreenQuicEnableRx") == 0) {
            Dpdk->GreenQuicEnableRx = atoi(Value) != 0 ? TRUE : FALSE;
        } else if (strcmp(Line, "GreenQuicEnableTx") == 0) {
            Dpdk->GreenQuicEnableTx = atoi(Value) != 0 ? TRUE : FALSE;
        } else if (strcmp(Line, "GreenQuicEnableFreq") == 0) {
            Dpdk->GreenQuicEnableFreq = atoi(Value) != 0 ? TRUE : FALSE;
        } else if (strcmp(Line, "GreenQuicEnableSleep") == 0) {
            Dpdk->GreenQuicEnableSleep = atoi(Value) != 0 ? TRUE : FALSE;
        } else if (strcmp(Line, "GreenQuicNoSleepIfTxRingNotEmpty") == 0) {
            Dpdk->GreenQuicNoSleepIfTxRingNotEmpty = atoi(Value) != 0 ? TRUE : FALSE;
        }
    }

    fclose(File);
    GreenQuicReadPowerConfig(Dpdk);
    GreenQuicInitCStateSupport(Dpdk);
}

_IRQL_requires_max_(PASSIVE_LEVEL)
size_t
CxPlatDpRawGetDatapathSize(
    _In_opt_ const QUIC_EXECUTION_CONFIG* Config
    )
{
    UNREFERENCED_PARAMETER(Config);
    return sizeof(DPDK_DATAPATH);
}

_IRQL_requires_max_(PASSIVE_LEVEL)
QUIC_STATUS
CxPlatDpRawInitialize(
    _Inout_ CXPLAT_DATAPATH_RAW* Datapath,
    _In_ uint32_t ClientRecvContextLength,
    _In_opt_ const QUIC_EXECUTION_CONFIG* Config
    )
{
    DPDK_DATAPATH* Dpdk = (DPDK_DATAPATH*)Datapath;
    CXPLAT_THREAD_CONFIG ThreadConfig = {
        0, 0, "DpdkMain", CxPlatDpdkMainThread, Dpdk
    };
    const uint32_t AdditionalBufferSize =
        sizeof(DPDK_RX_PACKET) + ClientRecvContextLength;

    CxPlatDpdkReadConfig(Dpdk, Config);

    BOOLEAN CleanUpThread = FALSE;
    CxPlatEventInitialize(&Dpdk->StartComplete, TRUE, FALSE);
    CxPlatPoolInitialize(FALSE, AdditionalBufferSize, QUIC_POOL_DATAPATH, &Dpdk->AdditionalInfoPool);
    CxPlatLockInitialize(&Dpdk->Interface.TxLock);
    CxPlatListInitializeHead(&Dpdk->Interfaces);
    CxPlatListInsertTail(&Dpdk->Interfaces, &Dpdk->Interface.Link);

    //
    // This starts a new thread to do all the DPDK initialization because DPDK
    // effectively takes that thread over. It waits for the initialization part
    // to complete before returning. After that, the DPDK main thread starts
    // running the DPDK main loop until clean up.
    //

    QUIC_STATUS Status = CxPlatThreadCreate(&ThreadConfig, &Dpdk->DpdkThread);
    if (QUIC_FAILED(Status)) {
        QuicTraceEvent(
            LibraryErrorStatus,
            "[ lib] ERROR, %u, %s.",
            Status,
            "CxPlatThreadCreate");
        goto Error;
    }
    CleanUpThread = TRUE;

    CxPlatEventWaitForever(Dpdk->StartComplete);
    Status = Dpdk->StartStatus;

Error:

    if (QUIC_FAILED(Status)) {
        if (CleanUpThread) {
            CxPlatLockUninitialize(&Dpdk->Interface.TxLock);
            CxPlatPoolUninitialize(&Dpdk->AdditionalInfoPool);
            CxPlatThreadWait(&Dpdk->DpdkThread);
            CxPlatThreadDelete(&Dpdk->DpdkThread);
        }
        CxPlatEventUninitialize(Dpdk->StartComplete);
    }

    return Status;
}

_IRQL_requires_max_(PASSIVE_LEVEL)
void
CxPlatDpRawUninitialize(
    _In_ CXPLAT_DATAPATH_RAW* Datapath
    )
{
    DPDK_DATAPATH* Dpdk = (DPDK_DATAPATH*)Datapath;
    Dpdk->Running = FALSE;
    // GREENQUIC-V20: unblock monitor/epoll workers during shutdown.
    unsigned int ShutdownCore;
    RTE_LCORE_FOREACH_WORKER(ShutdownCore) {
        GreenQuicSignalLcoreWork(Dpdk, (uint16_t)ShutdownCore);
    }
    GreenQuicSignalLcoreWork(Dpdk, Dpdk->Cpu);
    CxPlatLockUninitialize(&Dpdk->Interface.TxLock);
    CxPlatPoolUninitialize(&Dpdk->AdditionalInfoPool);
    CxPlatThreadWait(&Dpdk->DpdkThread);
    CxPlatThreadDelete(&Dpdk->DpdkThread);
    CxPlatEventUninitialize(Dpdk->StartComplete);
}

_IRQL_requires_max_(PASSIVE_LEVEL)
void
CxPlatDpRawUpdateConfig(
    _In_ CXPLAT_DATAPATH_RAW* Datapath,
    _In_ QUIC_EXECUTION_CONFIG* Config
    )
{
    UNREFERENCED_PARAMETER(Datapath);
    UNREFERENCED_PARAMETER(Config);
}

_IRQL_requires_max_(PASSIVE_LEVEL)
QUIC_STATUS
CxPlatSocketUpdateQeo(
    _In_ CXPLAT_SOCKET* Socket,
    _In_reads_(OffloadCount)
        const CXPLAT_QEO_CONNECTION* Offloads,
    _In_ uint32_t OffloadCount
    )
{
    UNREFERENCED_PARAMETER(Socket);
    UNREFERENCED_PARAMETER(Offloads);
    UNREFERENCED_PARAMETER(OffloadCount);
    return QUIC_STATUS_NOT_SUPPORTED;
}

CXPLAT_THREAD_CALLBACK(CxPlatDpdkMainThread, Context)
{
    DPDK_DATAPATH* Dpdk = (DPDK_DATAPATH*)Context;

    char DpdpCpuStr[64];
    if (Dpdk->GreenQuicDpdkLcores[0] != '\0') {
        snprintf(DpdpCpuStr, sizeof(DpdpCpuStr), "%s", Dpdk->GreenQuicDpdkLcores);
    } else {
        snprintf(DpdpCpuStr, sizeof(DpdpCpuStr), "%hu", Dpdk->Cpu);
    }
    if (strchr(DpdpCpuStr, ',') != NULL || strchr(DpdpCpuStr, '-') != NULL) {
        if (Dpdk->GreenQuicEnableMultiCore) {
            printf("GreenQUIC multi-core requested with -l %s; RSS/queue mapping will be enabled after port discovery.\n", DpdpCpuStr);
        } else {
            printf("GreenQUIC warning: multiple DPDK lcores requested with -l %s, but GreenQuicEnableMultiCore=0. "
                   "Only v10-style behavior is active. Set GreenQuicEnableMultiCore=1 after patching with --enable-multi-core.\n", DpdpCpuStr);
        }
    }

    // GREENQUIC-BEGIN: Linux-safe and Windows-safe DPDK EAL args
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

    QUIC_STATUS Status = QUIC_STATUS_SUCCESS;
    BOOLEAN CleanUpRte = FALSE;
    uint16_t Port;
    struct rte_eth_conf PortConfig = {
        .rxmode = {
            .max_rx_pkt_len = RTE_ETHER_MAX_LEN,
        },
    };
    uint16_t nb_rxd = 1024;
    uint16_t nb_txd = 1024;
    uint16_t rx_rings = 1, tx_rings = 1;
    struct rte_eth_dev_info DeviceInfo;
    struct rte_eth_rxconf rxconf;
    struct rte_eth_txconf txconf;
    struct rte_ether_addr addr;

    int ret = rte_eal_init(argc, (char**)argv);
    if (ret < 0) {
        QuicTraceEvent(
            LibraryErrorStatus,
            "[ lib] ERROR, %u, %s.",
            ret,
            "rte_eal_init");
        Status = QUIC_STATUS_INTERNAL_ERROR;
        goto Error;
    }
    CleanUpRte = TRUE;

    if (Dpdk->Interface.DeviceName[0] != '\0') {
        ret = rte_eth_dev_get_port_by_name(Dpdk->Interface.DeviceName, &Port);
    } else {
        ret = rte_eth_dev_get_port_by_name("0000:81:00.0", &Port);
        if (ret < 0) {
            ret = rte_eth_dev_get_port_by_name("0000:81:00.1", &Port);
        }
    }

    if (ret < 0) {
        QuicTraceEvent(
            LibraryErrorStatus,
            "[ lib] ERROR, %u, %s.",
            ret,
            "rte_eth_dev_get_port_by_name");
        Status = QUIC_STATUS_INTERNAL_ERROR;
        goto Error;
    }

    Dpdk->Interface.Port = Port;
    Dpdk->Interface.MemoryPool =
        rte_pktmbuf_pool_create(
            "MBUF_POOL", NUM_MBUFS, MBUF_CACHE_SIZE, 0,
            RTE_MBUF_DEFAULT_BUF_SIZE, rte_eth_dev_socket_id(Port));
    if (Dpdk->Interface.MemoryPool == NULL) {
        QuicTraceEvent(
            LibraryErrorStatus,
            "[ lib] ERROR, %u, %s.",
            0,
            "rte_pktmbuf_pool_create");
        Status = QUIC_STATUS_INTERNAL_ERROR;
        goto Error;
    }

    Dpdk->Interface.TxRingBuffer =
        rte_ring_create(
            "TxRing", TX_RING_SIZE, rte_eth_dev_socket_id(Port),
            /* GREENQUIC-OLD-V17 used MC dequeue in multi-core. */
            RING_F_MP_HTS_ENQ | RING_F_SC_DEQ);
    if (Dpdk->Interface.TxRingBuffer == NULL) {
        QuicTraceEvent(
            LibraryErrorStatus,
            "[ lib] ERROR, %u, %s.",
            ret,
            "rte_ring_create");
        Status = QUIC_STATUS_INTERNAL_ERROR;
        goto Error;
    }

    ret = rte_eth_dev_info_get(Port, &DeviceInfo);
    if (ret < 0) {
        QuicTraceEvent(
            LibraryErrorStatus,
            "[ lib] ERROR, %u, %s.",
            ret,
            "rte_eth_dev_info_get");
        Status = QUIC_STATUS_INTERNAL_ERROR;
        goto Error;
    }

    Dpdk->Interface.IfIndex = DeviceInfo.if_index;


    // GREENQUIC-BEGIN: optional multi-core queue/RSS setup
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
    GreenQuicInstallDefaultPartitionDpdkMap(Dpdk);

    if (DeviceInfo.tx_offload_capa & DEV_TX_OFFLOAD_IPV4_CKSUM) {
        printf("TX IPv4 Checksum Offload Enabled\n");
        PortConfig.txmode.offloads |= DEV_TX_OFFLOAD_IPV4_CKSUM;
        Dpdk->Interface.OffloadStatus.Transmit.NetworkLayerXsum = TRUE;
    }
    if (DeviceInfo.tx_offload_capa & DEV_TX_OFFLOAD_UDP_CKSUM) {
        printf("TX UDP Checksum Offload Enabled\n");
        PortConfig.txmode.offloads |= DEV_TX_OFFLOAD_UDP_CKSUM;
        Dpdk->Interface.OffloadStatus.Transmit.TransportLayerXsum = TRUE;
    }
    if (DeviceInfo.rx_offload_capa & DEV_RX_OFFLOAD_IPV4_CKSUM) {
        printf("RX IPv4 Checksum Offload Enabled\n");
        PortConfig.rxmode.offloads |= DEV_RX_OFFLOAD_IPV4_CKSUM;
        Dpdk->Interface.OffloadStatus.Receive.NetworkLayerXsum = TRUE;
    }
    if (DeviceInfo.rx_offload_capa & DEV_RX_OFFLOAD_UDP_CKSUM) {
        printf("RX UDP Checksum Offload Enabled\n");
        PortConfig.rxmode.offloads |= DEV_RX_OFFLOAD_UDP_CKSUM;
        Dpdk->Interface.OffloadStatus.Receive.TransportLayerXsum = TRUE;
    }

    ret = rte_eth_dev_configure(Port, rx_rings, tx_rings, &PortConfig);
    if (ret < 0) {
        QuicTraceEvent(
            LibraryErrorStatus,
            "[ lib] ERROR, %u, %s.",
            ret,
            "rte_eth_dev_configure");
        Status = QUIC_STATUS_INTERNAL_ERROR;
        goto Error;
    }

    ret = rte_eth_dev_adjust_nb_rx_tx_desc(Port, &nb_rxd, &nb_txd);
    if (ret < 0) {
        QuicTraceEvent(
            LibraryErrorStatus,
            "[ lib] ERROR, %u, %s.",
            ret,
            "rte_eth_dev_configure");
        Status = QUIC_STATUS_INTERNAL_ERROR;
        goto Error;
    }

    rxconf = DeviceInfo.default_rxconf;
    for (uint16_t q = 0; q < rx_rings; q++) {
        ret = rte_eth_rx_queue_setup(Port, q, nb_rxd, rte_eth_dev_socket_id(Port), &rxconf, Dpdk->Interface.MemoryPool);
        if (ret < 0) {
            QuicTraceEvent(
                LibraryErrorStatus,
                "[ lib] ERROR, %u, %s.",
                ret,
                "rte_eth_rx_queue_setup");
            Status = QUIC_STATUS_INTERNAL_ERROR;
            goto Error;
        }
    }

    txconf = DeviceInfo.default_txconf;
    txconf.offloads = PortConfig.txmode.offloads;
    for (uint16_t q = 0; q < tx_rings; q++) {
        ret = rte_eth_tx_queue_setup(Port, q, nb_txd, rte_eth_dev_socket_id(Port), &txconf);
        if (ret < 0) {
            QuicTraceEvent(
                LibraryErrorStatus,
                "[ lib] ERROR, %u, %s.",
                ret,
                "rte_eth_tx_queue_setup");
            Status = QUIC_STATUS_INTERNAL_ERROR;
            goto Error;
        }
    }

    ret = rte_eth_dev_start(Port);
    if (ret < 0) {
        QuicTraceEvent(
            LibraryErrorStatus,
            "[ lib] ERROR, %u, %s.",
            ret,
            "rte_eth_dev_start");
        Status = QUIC_STATUS_INTERNAL_ERROR;
        goto Error;
    }

    ret = rte_eth_macaddr_get(Port, &addr);
    if (ret < 0) {
        QuicTraceEvent(
            LibraryErrorStatus,
            "[ lib] ERROR, %u, %s.",
            ret,
            "rte_eth_macaddr_get");
        Status = QUIC_STATUS_INTERNAL_ERROR;
        goto Error;
    }

    //
    // Linux DPDK path: use the DPDK MAC address directly. The if_index, when
    // available from the PMD, was copied from rte_eth_dev_info.if_index above.
    //
    CxPlatCopyMemory(Dpdk->Interface.PhysicalAddress, addr.addr_bytes, sizeof(Dpdk->Interface.PhysicalAddress));

    printf(
        "\nStarting Port %hu on Interface %u, %02hhx:%02hhx:%02hhx:%02hhx:%02hhx:%02hhx\n",
        Dpdk->Interface.Port, Dpdk->Interface.IfIndex,
        addr.addr_bytes[0], addr.addr_bytes[1], addr.addr_bytes[2],
        addr.addr_bytes[3], addr.addr_bytes[4], addr.addr_bytes[5]);

    Dpdk->Running = TRUE;
    ret = rte_eal_mp_remote_launch(CxPlatDpdkWorkerThread, Dpdk, SKIP_MAIN);
    if (ret < 0) {
        QuicTraceEvent(
            LibraryErrorStatus,
            "[ lib] ERROR, %u, %s.",
            ret,
            "rte_eal_mp_remote_launch");
        Status = QUIC_STATUS_INTERNAL_ERROR;
        goto Error;
    }

    Dpdk->StartStatus = Status;
    CxPlatEventSet(Dpdk->StartComplete);

    CxPlatDpdkWorkerThread(Dpdk);

    rte_eal_mp_wait_lcore(); // Wait on the other cores/threads

Error:

    if (QUIC_FAILED(Status)) {
        Dpdk->StartStatus = Status;
        CxPlatEventSet(Dpdk->StartComplete);
    }

    if (Dpdk->Interface.TxRingBuffer) {
        rte_ring_free(Dpdk->Interface.TxRingBuffer);
    }

    if (Dpdk->Interface.MemoryPool) {
        rte_mempool_free(Dpdk->Interface.MemoryPool);
    }

    if (CleanUpRte) {
        rte_eal_cleanup();
    }

    CXPLAT_THREAD_RETURN(0);
}

_IRQL_requires_max_(PASSIVE_LEVEL)
void
CxPlatDpRawPlumbRulesOnSocket(
    _In_ CXPLAT_SOCKET_RAW* Socket,
    _In_ BOOLEAN IsCreated
    )
{
    UNREFERENCED_PARAMETER(Socket);
    UNREFERENCED_PARAMETER(IsCreated);
    // no-op currently since DPDK simply steals all traffic
}

_IRQL_requires_max_(PASSIVE_LEVEL)
void
CxPlatDpRawAssignQueue(
    _In_ CXPLAT_INTERFACE* Interface,
    _Inout_ CXPLAT_ROUTE* Route
    )
{
    Route->Queue = (CXPLAT_INTERFACE*)Interface;
}

_IRQL_requires_max_(DISPATCH_LEVEL)
const CXPLAT_INTERFACE*
CxPlatDpRawGetInterfaceFromQueue(
    _In_ const void* Queue
    )
{
    return (const CXPLAT_INTERFACE*)Queue;
}

static
void
CxPlatDpdkRx(
    _In_ DPDK_DATAPATH* Dpdk,
    _In_ const uint16_t Core,
    _In_ DPDK_INTERFACE* Interface
    )
{
    void* Buffers[RX_BURST_SIZE];
    const uint16_t QueueId = GreenQuicGetQueueId(Dpdk, Core);
    int RxQueueCountBefore = -1;
    if (Dpdk->GreenQuicMode != GREENQUIC_MODE_OFF) {
        GREENQUIC_LCORE_STATE* GreenQuicState = GreenQuicGetLcoreState(Dpdk, Core);
        if (GreenQuicState->Rx.QueueSampleCountdown == 0) {
            RxQueueCountBefore = rte_eth_rx_queue_count(Interface->Port, QueueId);
            GreenQuicState->Rx.QueueSampleCountdown = Dpdk->GreenQuicRxQueueSamplePeriod;
        }
        GreenQuicState->Rx.QueueSampleCountdown--;
    }
    const uint16_t BuffersCount =
        rte_eth_rx_burst(Interface->Port, QueueId, (struct rte_mbuf**)Buffers, RX_BURST_SIZE);
    GreenQuicOnRxPoll(Dpdk, Core, BuffersCount, RxQueueCountBefore);
    if (unlikely(BuffersCount == 0)) {
        return;
    }

    DPDK_RX_PACKET Packet; // Working space
    CxPlatZeroMemory(&Packet, sizeof(DPDK_RX_PACKET));
    Packet.Route = &Packet.RouteStorage;
    Packet.Route->Queue = (CXPLAT_INTERFACE*)Interface;

    uint16_t PacketCount = 0;
    for (uint16_t i = 0; i < BuffersCount; i++) {
        struct rte_mbuf* Buffer = (struct rte_mbuf*)Buffers[i];
        Packet.Buffer = NULL;
        if ((Buffer->ol_flags & (PKT_RX_IP_CKSUM_BAD | PKT_RX_L4_CKSUM_BAD)) == 0) {
            CxPlatDpRawParseEthernet(
                (CXPLAT_DATAPATH*)Dpdk,
                (CXPLAT_RECV_DATA*)&Packet,
                ((uint8_t*)Buffer->buf_addr) + Buffer->data_off,
                Buffer->pkt_len);
            //
            // The route has been filled in with the packet's src/dst IP and ETH addresses, so
            // mark it resolved. This allows stateless sends to be issued without performing
            // a route lookup.
            //
            Packet.Route->State = RouteResolved;
        } else {
            QuicTraceEvent(
                LibraryErrorStatus,
                "[ lib] ERROR, %u, %s.",
                Buffer->ol_flags,
                "L3/L4 checksum incorrect");
            CXPLAT_DBG_ASSERT(
                Interface->OffloadStatus.Receive.NetworkLayerXsum != 0 ||
                Interface->OffloadStatus.Receive.TransportLayerXsum != 0);
        }

        DPDK_RX_PACKET* NewPacket;
        if (likely(Packet.Buffer && (NewPacket = CxPlatPoolAlloc(&Dpdk->AdditionalInfoPool)) != NULL)) {
            CxPlatCopyMemory(NewPacket, &Packet, sizeof(DPDK_RX_PACKET));
            NewPacket->Allocated = TRUE;
            NewPacket->Mbuf = Buffer;
            NewPacket->OwnerPool = &Dpdk->AdditionalInfoPool;
            NewPacket->Route = &NewPacket->RouteStorage;
            Buffers[PacketCount++] = NewPacket;
        } else {
            rte_pktmbuf_free(Buffer);
        }
    }

    if (likely(PacketCount)) {
        CxPlatDpRawRxEthernet((CXPLAT_DATAPATH_RAW*)Dpdk, (CXPLAT_RECV_DATA**)Buffers, PacketCount);
    }
}

_IRQL_requires_max_(DISPATCH_LEVEL)
void
CxPlatDpRawRxFree(
    _In_opt_ const CXPLAT_RECV_DATA* PacketChain
    )
{
    while (PacketChain) {
        const DPDK_RX_PACKET* Packet = (DPDK_RX_PACKET*)PacketChain;
        PacketChain = PacketChain->Next;
        rte_pktmbuf_free(Packet->Mbuf);
        CxPlatPoolFree(Packet->OwnerPool, (void*)Packet);
    }
}

_IRQL_requires_max_(DISPATCH_LEVEL)
CXPLAT_SEND_DATA*
CxPlatDpRawTxAlloc(
    _In_ CXPLAT_SOCKET_RAW* Socket,
    _Inout_ CXPLAT_SEND_CONFIG* Config
    )
{
    DPDK_DATAPATH* Dpdk = (DPDK_DATAPATH*)Socket->RawDatapath;
    DPDK_TX_PACKET* Packet = CxPlatPoolAlloc(&Dpdk->AdditionalInfoPool);
    QUIC_ADDRESS_FAMILY Family = QuicAddrGetFamily(&Config->Route->RemoteAddress);
    DPDK_INTERFACE* Interface = (DPDK_INTERFACE*)Config->Route->Queue;

    if (likely(Packet)) {
        Packet->Interface = Interface;
        Packet->Mbuf = rte_pktmbuf_alloc(Interface->MemoryPool);
        if (likely(Packet->Mbuf)) {
            HEADER_BACKFILL HeaderFill = CxPlatDpRawCalculateHeaderBackFill(Family, Socket->UseTcp);
            Packet->Dpdk = Dpdk;
            Packet->Buffer.Length = Config->MaxPacketSize;
            Packet->Mbuf->data_off = 0;
            Packet->Buffer.Buffer = ((uint8_t*)Packet->Mbuf->buf_addr) + HeaderFill.AllLayer;
            Packet->Mbuf->l2_len = HeaderFill.LinkLayer;
            Packet->Mbuf->l3_len = HeaderFill.NetworkLayer;
        } else {
            CxPlatPoolFree(&Dpdk->AdditionalInfoPool, Packet);
            Packet = NULL;
        }
    }
    return (CXPLAT_SEND_DATA*)Packet;
}

_IRQL_requires_max_(DISPATCH_LEVEL)
void
CxPlatDpRawTxFree(
    _In_ CXPLAT_SEND_DATA* SendData
    )
{
    DPDK_TX_PACKET* Packet = (DPDK_TX_PACKET*)SendData;
    rte_pktmbuf_free(Packet->Mbuf);
    CxPlatPoolFree(&Packet->Dpdk->AdditionalInfoPool, SendData);
}

_IRQL_requires_max_(DISPATCH_LEVEL)
void
CxPlatDpRawTxEnqueue(
    _In_ CXPLAT_SEND_DATA* SendData
    )
{
    DPDK_TX_PACKET* Packet = (DPDK_TX_PACKET*)SendData;
    DPDK_INTERFACE* Interface = Packet->Interface;
    Packet->Mbuf->data_len = (uint16_t)Packet->Buffer.Length;
    Packet->Mbuf->ol_flags = PKT_TX_IPV4 | PKT_TX_IP_CKSUM | PKT_TX_UDP_CKSUM;

    DPDK_DATAPATH* Dpdk = Packet->Dpdk;
    if (unlikely(rte_ring_mp_enqueue(Interface->TxRingBuffer, Packet->Mbuf) != 0)) {
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
}

static
void
CxPlatDpdkTx(
    _In_ DPDK_DATAPATH* Dpdk,
    _In_ const uint16_t Core,
    _In_ DPDK_INTERFACE* Interface
    )
{
    struct rte_mbuf* Buffers[TX_BURST_SIZE];
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
    if (unlikely(BufferCount == 0)) {
        GreenQuicOnTxPoll(Dpdk, Core, RingBefore, BufferCount, 0);
        return;
    }

    const uint16_t TxCount = rte_eth_tx_burst(Interface->Port, 0, Buffers, BufferCount);
    GreenQuicOnTxPoll(Dpdk, Core, RingBefore, BufferCount, TxCount);
    if (unlikely(TxCount < BufferCount)) {
        for (uint16_t buf = TxCount; buf < BufferCount; buf++) {
            rte_pktmbuf_free(Buffers[buf]);
        }
    }
}

static
int
CxPlatDpdkWorkerThread(
    _In_ void* Context
    )
{
    DPDK_DATAPATH* Dpdk = (DPDK_DATAPATH*)Context;
    const uint16_t Core = (uint16_t)rte_lcore_id();
    CXPLAT_LIST_ENTRY* Entry;

    printf("Core %u worker running...\n", Core);
    GreenQuicPowerInit(Dpdk, Core);
    CxPlatGreenQuicPlusSetThreadLcore(Core);
    for (Entry = Dpdk->Interfaces.Flink; Entry != &Dpdk->Interfaces; Entry = Entry->Flink) {
        if (rte_eth_dev_socket_id(Dpdk->Interface.Port) > 0 &&
            rte_eth_dev_socket_id(Dpdk->Interface.Port) != (int)rte_socket_id()) {
            printf("\nWARNING, port %u is on remote NUMA node to polling thread.\n"
                "\tPerformance will not be optimal.\n\n",
                Dpdk->Interface.Port);
        }
    }

    while (likely(Dpdk->Running)) {
        for (Entry = Dpdk->Interfaces.Flink; Entry != &Dpdk->Interfaces; Entry = Entry->Flink) {
            DPDK_INTERFACE* Interface = CXPLAT_CONTAINING_RECORD(Entry, DPDK_INTERFACE, Link);
            const BOOLEAN OwnsRx = GreenQuicLcoreOwnsRx(Dpdk, Core);
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
        }
    }

    CxPlatGreenQuicPlusClearThreadLcore();
    GreenQuicPowerCleanup(Dpdk, Core);
    GreenQuicIdleCleanupLcore(GreenQuicGetLcoreState(Dpdk, Core));
    return 0;
}
