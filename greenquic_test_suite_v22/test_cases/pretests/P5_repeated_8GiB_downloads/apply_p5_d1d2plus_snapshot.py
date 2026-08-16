#!/usr/bin/env python3
from pathlib import Path
import sys

MARK='GREENQUIC-P5-D1D2PLUS-SNAPSHOT-V1'
if len(sys.argv)!=5:
    raise SystemExit('usage: apply_p5_d1d2plus_snapshot.py CLIENT_CPP SERVER_CPP SERVER_H DATAPATH_C')
client,server,header,datapath=map(Path,sys.argv[1:])

def once(text,old,new,label):
    n=text.count(old)
    if n!=1: raise SystemExit(f'ERROR: {label}: expected 1 anchor, found {n}')
    return text.replace(old,new,1)

def ensure_clean(p):
    t=p.read_text()
    if MARK in t: raise SystemExit(f'ERROR: {p} already contains {MARK}')
    return t

# Client: calls are outside the transport hot path, exactly at request boundaries.
t=ensure_clean(client)
t=once(t,'#include "greenquic_plus.h"\n', '#include "greenquic_plus.h"\nextern "C" void CxPlatGreenQuicP5PositionSnapshot(const char* Label, uint32_t RequestIndex);\nstatic const char GreenQuicP5PositionSnapshotMarker[] __attribute__((used)) = "'+MARK+'";\n\nstatic bool GreenQuicP5PositionSnapshotEnabled() {\n    const char* v = getenv("GQ_P5_POSITION_SNAPSHOT");\n    return v != nullptr && v[0] != \'\\0\' && strcmp(v, "0") != 0;\n}\n', 'client declaration')
t=once(t,
'''            const uint64_t StartUs = GreenQuicP5MonotonicUs();\n            printf(\n''',
'''            const uint64_t StartUs = GreenQuicP5MonotonicUs();\n            if (GreenQuicP5PositionSnapshotEnabled()) {\n                CxPlatGreenQuicP5PositionSnapshot("start", (uint32_t)RequestIndex);\n            }\n            printf(\n''','client start snapshot')
t=once(t,
'''            const bool Success = Stream->SendHttpRequest(true);\n            const uint64_t CompleteUs = GreenQuicP5MonotonicUs();\n\n            printf(\n''',
'''            const bool Success = Stream->SendHttpRequest(true);\n            if (GreenQuicP5PositionSnapshotEnabled()) {\n                CxPlatGreenQuicP5PositionSnapshot("end", (uint32_t)RequestIndex);\n            }\n            const uint64_t CompleteUs = GreenQuicP5MonotonicUs();\n\n            printf(\n''','client end snapshot')
client.write_text(t)

# Server header: retain request index until final QUIC send completion.
h=ensure_clean(header)
h=once(h,'    bool GreenQuicServerTxHintActive;\n','    bool GreenQuicServerTxHintActive;\n    uint32_t GreenQuicP5SnapshotIndex;\n    bool GreenQuicP5SnapshotDone; // '+MARK+'\n','server header fields')
header.write_text(h)

# Server source.
s=ensure_clean(server)
s=once(s,'#include <unistd.h>  // for pause()\n','#include <unistd.h>  // for pause()\n#include <atomic>\n','server atomic include')
s=once(s,'#include "greenquic_plus.h"\n','#include "greenquic_plus.h"\nextern "C" void CxPlatGreenQuicP5PositionSnapshot(const char* Label, uint32_t RequestIndex);\nstatic const char GreenQuicP5PositionSnapshotMarker[] __attribute__((used)) = "'+MARK+'";\nstatic std::atomic<uint32_t> GreenQuicP5ServerRequestIndex{0};\nstatic bool GreenQuicP5PositionSnapshotEnabled() {\n    const char* v=getenv("GQ_P5_POSITION_SNAPSHOT");\n    return v != nullptr && v[0] != \'\\0\' && strcmp(v,"0") != 0;\n}\n','server declaration')
s=once(s,
'''    Shutdown(false), WriteHttp11Header(false), GreenQuicServerTxHintActive(false)\n''',
'''    Shutdown(false), WriteHttp11Header(false), GreenQuicServerTxHintActive(false),\n    GreenQuicP5SnapshotIndex(0), GreenQuicP5SnapshotDone(false)\n''','server constructor')
s=once(s,
'''    printf("[%s] GET '%s'\\n", GetRemoteAddr(MsQuic, QuicStream).Address, PathStart);\n    File = fopen(FullFilePath, "rb"); // In case of failure, SendData still works.\n''',
'''    printf("[%s] GET '%s'\\n", GetRemoteAddr(MsQuic, QuicStream).Address, PathStart);\n    if (GreenQuicP5PositionSnapshotEnabled()) {\n        GreenQuicP5SnapshotIndex = GreenQuicP5ServerRequestIndex.fetch_add(1, std::memory_order_relaxed) + 1;\n        CxPlatGreenQuicP5PositionSnapshot("start", GreenQuicP5SnapshotIndex);\n    }\n    File = fopen(FullFilePath, "rb"); // In case of failure, SendData still works.\n''','server start snapshot')
s=once(s,
'''    case QUIC_STREAM_EVENT_SEND_COMPLETE:\n        pThis->SendData();\n        break;\n''',
'''    case QUIC_STREAM_EVENT_SEND_COMPLETE:\n        if (pThis->Shutdown && pThis->GreenQuicP5SnapshotIndex != 0 && !pThis->GreenQuicP5SnapshotDone) {\n            CxPlatGreenQuicP5PositionSnapshot("end", pThis->GreenQuicP5SnapshotIndex);\n            pThis->GreenQuicP5SnapshotDone = true;\n        }\n        pThis->SendData();\n        break;\n''','server final send snapshot')
server.write_text(s)

# Datapath: one read-only cumulative snapshot at each boundary. No packet/poll loop instrumentation.
d=ensure_clean(datapath)
struct_anchor='''} DPDK_DATAPATH;\n\ntypedef struct __attribute__((aligned(64))) DPDK_RX_PACKET {\n'''
snapshot_code=r'''} DPDK_DATAPATH;

// GREENQUIC-P5-D1D2PLUS-SNAPSHOT-V1
// Measurement-only boundary snapshots. They read cumulative counters at a
// handful of request boundaries and add no branch or write to the DPDK hot path.
static DPDK_DATAPATH* volatile GreenQuicP5SnapshotDatapath = NULL;
static inline uint64_t GreenQuicP5LoadU64(const uint64_t* P) {
    return __atomic_load_n(P, __ATOMIC_RELAXED);
}

void
CxPlatGreenQuicP5PositionSnapshot(const char* Label, uint32_t RequestIndex)
{
    DPDK_DATAPATH* Dpdk = __atomic_load_n(&GreenQuicP5SnapshotDatapath, __ATOMIC_ACQUIRE);
    if (Dpdk == NULL || Label == NULL || RequestIndex == 0) return;

    uint64_t rx_pkts=GreenQuicP5LoadU64(&Dpdk->RxCounter);
    uint64_t tx_pkts=GreenQuicP5LoadU64(&Dpdk->TxCounter);
    uint64_t epoll_try=0,epoll_wake=0,epoll_timeout=0,epoll_rx_wake=0,epoll_control_wake=0,epoll_signal_wake=0;
    uint64_t epoll_rx_fd_drain=0,epoll_rx_fd_drain_error=0,wake_signal=0;
    uint64_t freq_policy_max_hard=0,freq_policy_max_control=0,freq_policy_up=0,freq_policy_down=0,freq_policy_min=0,freq_policy_txring_protect_up=0;
    uint64_t freq_changed_max=0,freq_changed_up=0,freq_changed_down=0,freq_changed_min=0,freq_unchanged=0,freq_error=0;
    for (uint16_t c=0;c<RTE_MAX_LCORE;++c) {
        GREENQUIC_LCORE_STATE* S=&Dpdk->GreenQuicLcore[c];
        epoll_try+=GreenQuicP5LoadU64(&S->EpollAttempts); epoll_wake+=GreenQuicP5LoadU64(&S->EpollWakeups); epoll_timeout+=GreenQuicP5LoadU64(&S->EpollTimeouts);
        epoll_rx_wake+=GreenQuicP5LoadU64(&S->EpollRxWakeups); epoll_control_wake+=GreenQuicP5LoadU64(&S->EpollControlWakeups); epoll_signal_wake+=GreenQuicP5LoadU64(&S->EpollSignalWakeups);
        epoll_rx_fd_drain+=GreenQuicP5LoadU64(&S->EpollRxFdDrains); epoll_rx_fd_drain_error+=GreenQuicP5LoadU64(&S->EpollRxFdDrainErrors); wake_signal+=GreenQuicP5LoadU64(&S->WakeSignals);
        freq_policy_max_hard+=GreenQuicP5LoadU64(&S->FreqPolicyMaxHard); freq_policy_max_control+=GreenQuicP5LoadU64(&S->FreqPolicyMaxControl); freq_policy_up+=GreenQuicP5LoadU64(&S->FreqPolicyUp); freq_policy_down+=GreenQuicP5LoadU64(&S->FreqPolicyDown); freq_policy_min+=GreenQuicP5LoadU64(&S->FreqPolicyMin); freq_policy_txring_protect_up+=GreenQuicP5LoadU64(&S->FreqPolicyTxRingProtectUp);
        freq_changed_max+=GreenQuicP5LoadU64(&S->FreqChangedMax); freq_changed_up+=GreenQuicP5LoadU64(&S->FreqChangedUp); freq_changed_down+=GreenQuicP5LoadU64(&S->FreqChangedDown); freq_changed_min+=GreenQuicP5LoadU64(&S->FreqChangedMin); freq_unchanged+=GreenQuicP5LoadU64(&S->FreqUnchanged); freq_error+=GreenQuicP5LoadU64(&S->FreqErrors);
    }
    GQPLUS_HINT_COUNTERS H={0}; CxPlatGreenQuicPlusGetHintCounters(&H);
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC,&ts);
    const uint64_t mono_ns=(uint64_t)ts.tv_sec*1000000000ULL+(uint64_t)ts.tv_nsec;
    printf("[GreenQUIC-P5-SNAPSHOT] schema=greenquic-p5-position-v1 label=%s request=%u monotonic_ns=%" PRIu64
           " rx_pkts=%" PRIu64 " tx_pkts=%" PRIu64
           " epoll_try=%" PRIu64 " epoll_wake=%" PRIu64 " epoll_timeout=%" PRIu64 " epoll_rx_wake=%" PRIu64 " epoll_control_wake=%" PRIu64 " epoll_signal_wake=%" PRIu64 " epoll_rx_fd_drain=%" PRIu64 " epoll_rx_fd_drain_error=%" PRIu64 " wake_signal=%" PRIu64
           " freq_policy_max_hard=%" PRIu64 " freq_policy_max_control=%" PRIu64 " freq_policy_up=%" PRIu64 " freq_policy_down=%" PRIu64 " freq_policy_min=%" PRIu64 " freq_policy_txring_protect_up=%" PRIu64
           " freq_changed_max=%" PRIu64 " freq_changed_up=%" PRIu64 " freq_changed_down=%" PRIu64 " freq_changed_min=%" PRIu64 " freq_unchanged=%" PRIu64 " freq_error=%" PRIu64
           " hint_ack_pending=%" PRIu64 " hint_cubic_cwnd_blocked=%" PRIu64 " hint_cubic_recovery=%" PRIu64 " hint_cubic_recovery_end=%" PRIu64 " hint_cubic_ramping=%" PRIu64 " hint_server_file_tx_active=%" PRIu64 " hint_server_file_tx_end=%" PRIu64 " hint_client_file_rx_active=%" PRIu64 " hint_client_file_rx_end=%" PRIu64 "\n",
           Label,RequestIndex,mono_ns,rx_pkts,tx_pkts,epoll_try,epoll_wake,epoll_timeout,epoll_rx_wake,epoll_control_wake,epoll_signal_wake,epoll_rx_fd_drain,epoll_rx_fd_drain_error,wake_signal,
           freq_policy_max_hard,freq_policy_max_control,freq_policy_up,freq_policy_down,freq_policy_min,freq_policy_txring_protect_up,
           freq_changed_max,freq_changed_up,freq_changed_down,freq_changed_min,freq_unchanged,freq_error,
           H.AckPending,H.CubicCwndBlocked,H.CubicRecovery,H.CubicRecoveryEnd,H.CubicRamping,H.ServerFileTxActive,H.ServerFileTxEnd,H.ClientFileRxActive,H.ClientFileRxEnd);
    fflush(stdout);
}

typedef struct __attribute__((aligned(64))) DPDK_RX_PACKET {
'''
d=once(d,struct_anchor,snapshot_code,'datapath snapshot implementation')
d=once(d,
'''    Status = Dpdk->StartStatus;\n\n    Error:\n''',
'''    Status = Dpdk->StartStatus;\n    if (QUIC_SUCCEEDED(Status)) {\n        __atomic_store_n(&GreenQuicP5SnapshotDatapath, Dpdk, __ATOMIC_RELEASE);\n    }\n\n    Error:\n''','datapath pointer install')
d=once(d,
'''    DPDK_DATAPATH* Dpdk = (DPDK_DATAPATH*)Datapath;\n    Dpdk->Running = FALSE;\n''',
'''    DPDK_DATAPATH* Dpdk = (DPDK_DATAPATH*)Datapath;\n    DPDK_DATAPATH* Expected = Dpdk;\n    __atomic_compare_exchange_n(&GreenQuicP5SnapshotDatapath, &Expected, NULL, FALSE, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);\n    Dpdk->Running = FALSE;\n''','datapath pointer clear')
datapath.write_text(d)
print(MARK)
