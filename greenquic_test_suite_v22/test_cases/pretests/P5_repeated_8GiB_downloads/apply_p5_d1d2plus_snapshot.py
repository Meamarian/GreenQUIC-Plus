#!/usr/bin/env python3
from pathlib import Path
import sys

MARK='GREENQUIC-P5-D1D2PLUS-SNAPSHOT-V2'
OLD_MARK='GREENQUIC-P5-D1D2PLUS-SNAPSHOT-V1'

if len(sys.argv)!=5:
    raise SystemExit('usage: apply_p5_d1d2plus_snapshot.py CLIENT_CPP SERVER_CPP SERVER_H DATAPATH_C')
client,server,header,datapath=map(Path,sys.argv[1:])

def once(text, old, new, label):
    n=text.count(old)
    if n!=1:
        raise SystemExit(f'ERROR: {label}: expected 1 anchor, found {n}')
    return text.replace(old,new,1)

def clean(path):
    text=path.read_text()
    for marker in (MARK, OLD_MARK):
        if marker in text:
            raise SystemExit(f'ERROR: {path} already contains {marker}')
    return text

# Client boundary calls. Snapshot work is deliberately outside the goodput
# timing window: start snapshot first; end timestamp first.
t=clean(client)
t=once(
    t,
    '#include "greenquic_plus.h"\n',
    '#include "greenquic_plus.h"\n'
    'extern "C" void CxPlatGreenQuicP5PositionSnapshot(const char* Label, uint32_t RequestIndex);\n'
    f'static const char GreenQuicP5PositionSnapshotMarker[] __attribute__((used)) = "{MARK}";\n'
    '\n'
    'static bool GreenQuicP5PositionSnapshotEnabled() {\n'
    '    const char* v = getenv("GQ_P5_POSITION_SNAPSHOT");\n'
    '    return v != nullptr && v[0] != \'\\0\' && strcmp(v, "0") != 0;\n'
    '}\n',
    'client declaration')
t=once(
    t,
    """            const uint64_t StartUs = GreenQuicP5MonotonicUs();
            printf(
""",
    """            if (GreenQuicP5PositionSnapshotEnabled()) {
                CxPlatGreenQuicP5PositionSnapshot("start", (uint32_t)RequestIndex);
            }
            const uint64_t StartUs = GreenQuicP5MonotonicUs();
            printf(
""",
    'client start snapshot outside timing')
t=once(
    t,
    """            const bool Success = Stream->SendHttpRequest(true);
            const uint64_t CompleteUs = GreenQuicP5MonotonicUs();

            printf(
""",
    """            const bool Success = Stream->SendHttpRequest(true);
            const uint64_t CompleteUs = GreenQuicP5MonotonicUs();
            if (GreenQuicP5PositionSnapshotEnabled()) {
                CxPlatGreenQuicP5PositionSnapshot("end", (uint32_t)RequestIndex);
            }

            printf(
""",
    'client end snapshot outside timing')
client.write_text(t)

# Server request bookkeeping.
h=clean(header)
h=once(
    h,
    '    bool GreenQuicServerTxHintActive;\n',
    '    bool GreenQuicServerTxHintActive;\n'
    '    uint32_t GreenQuicP5SnapshotIndex;\n'
    f'    bool GreenQuicP5SnapshotDone; // {MARK}\n',
    'server header fields')
header.write_text(h)

s=clean(server)
s=once(
    s,
    '#include <unistd.h>  // for pause()\n',
    '#include <unistd.h>  // for pause()\n#include <atomic>\n',
    'server atomic include')
s=once(
    s,
    '#include "greenquic_plus.h"\n',
    '#include "greenquic_plus.h"\n'
    'extern "C" void CxPlatGreenQuicP5PositionSnapshot(const char* Label, uint32_t RequestIndex);\n'
    f'static const char GreenQuicP5PositionSnapshotMarker[] __attribute__((used)) = "{MARK}";\n'
    'static std::atomic<uint32_t> GreenQuicP5ServerRequestIndex{0};\n'
    'static bool GreenQuicP5PositionSnapshotEnabled() {\n'
    '    const char* v = getenv("GQ_P5_POSITION_SNAPSHOT");\n'
    '    return v != nullptr && v[0] != \'\\0\' && strcmp(v, "0") != 0;\n'
    '}\n',
    'server declaration')
s=once(
    s,
    """    Connection(connection), QuicStream(stream), File(nullptr),
    Shutdown(false), WriteHttp11Header(false), GreenQuicServerTxHintActive(false)
""",
    """    Connection(connection), QuicStream(stream), File(nullptr),
    Shutdown(false), WriteHttp11Header(false), GreenQuicServerTxHintActive(false),
    GreenQuicP5SnapshotIndex(0), GreenQuicP5SnapshotDone(false)
""",
    'server constructor')
s=once(
    s,
    """    printf("[%s] GET '%s'\\n", GetRemoteAddr(MsQuic, QuicStream).Address, PathStart);
    File = fopen(FullFilePath, "rb"); // In case of failure, SendData still works.
""",
    """    printf("[%s] GET '%s'\\n", GetRemoteAddr(MsQuic, QuicStream).Address, PathStart);
    if (GreenQuicP5PositionSnapshotEnabled()) {
        GreenQuicP5SnapshotIndex =
            GreenQuicP5ServerRequestIndex.fetch_add(1, std::memory_order_relaxed) + 1;
        CxPlatGreenQuicP5PositionSnapshot("start", GreenQuicP5SnapshotIndex);
    }
    File = fopen(FullFilePath, "rb"); // In case of failure, SendData still works.
""",
    'server start snapshot')
s=once(
    s,
    """    case QUIC_STREAM_EVENT_SEND_COMPLETE:
        pThis->SendData();
        break;
""",
    """    case QUIC_STREAM_EVENT_SEND_COMPLETE:
        if (pThis->Shutdown &&
            pThis->GreenQuicP5SnapshotIndex != 0 &&
            !pThis->GreenQuicP5SnapshotDone) {
            CxPlatGreenQuicP5PositionSnapshot("end", pThis->GreenQuicP5SnapshotIndex);
            pThis->GreenQuicP5SnapshotDone = true;
        }
        pThis->SendData();
        break;
""",
    'server final send snapshot')
server.write_text(s)

# Datapath boundary recorder.
#
# Do NOT read worker-owned EPOLL/DVFS policy counters here: those fields are
# updated with ordinary non-atomic writes by the DPDK worker. Also do NOT add
# new per-poll/per-policy instrumentation just for this report.
#
# Reuse only already-existing atomics:
#   * GreenQuicTransferRxPackets / GreenQuicTransferTxPackets
#   * GreenQUIC+ hint counters via its getter
# Store records in memory and print them only at process exit.
d=clean(datapath)
anchor="""} DPDK_DATAPATH;

typedef struct __attribute__((aligned(64))) DPDK_RX_PACKET {
"""
code=r''' } DPDK_DATAPATH;

// GREENQUIC-P5-D1D2PLUS-SNAPSHOT-V2
#define GREENQUIC_P5_POSITION_MAX_SNAPSHOTS 256U

typedef struct GREENQUIC_P5_POSITION_SNAPSHOT {
    uint32_t RequestIndex;
    uint8_t IsEnd;
    uint64_t MonotonicNs;
    uint64_t RxPackets;
    uint64_t TxPackets;
    GQPLUS_HINT_COUNTERS Hints;
} GREENQUIC_P5_POSITION_SNAPSHOT;

static atomic_uint GreenQuicP5PositionSnapshotCount = ATOMIC_VAR_INIT(0);
static GREENQUIC_P5_POSITION_SNAPSHOT
    GreenQuicP5PositionSnapshots[GREENQUIC_P5_POSITION_MAX_SNAPSHOTS];

void
CxPlatGreenQuicP5PositionSnapshot(const char* Label, uint32_t RequestIndex)
{
    if (Label == NULL || RequestIndex == 0U) {
        return;
    }

    const unsigned Slot = atomic_fetch_add_explicit(
        &GreenQuicP5PositionSnapshotCount, 1U, memory_order_relaxed);
    if (Slot >= GREENQUIC_P5_POSITION_MAX_SNAPSHOTS) {
        return;
    }

    GREENQUIC_P5_POSITION_SNAPSHOT* Snapshot =
        &GreenQuicP5PositionSnapshots[Slot];
    CxPlatZeroMemory(Snapshot, sizeof(*Snapshot));
    Snapshot->RequestIndex = RequestIndex;
    Snapshot->IsEnd = strcmp(Label, "end") == 0 ? 1U : 0U;
    Snapshot->MonotonicNs = GreenQuicTransferMonotonicNs();
    Snapshot->RxPackets = atomic_load_explicit(
        &GreenQuicTransferRxPackets, memory_order_relaxed);
    Snapshot->TxPackets = atomic_load_explicit(
        &GreenQuicTransferTxPackets, memory_order_relaxed);
    CxPlatGreenQuicPlusGetHintCounters(&Snapshot->Hints);
}

__attribute__((destructor))
static void
GreenQuicP5PositionSnapshotDump(void)
{
    unsigned Count = atomic_load_explicit(
        &GreenQuicP5PositionSnapshotCount, memory_order_relaxed);
    if (Count > GREENQUIC_P5_POSITION_MAX_SNAPSHOTS) {
        Count = GREENQUIC_P5_POSITION_MAX_SNAPSHOTS;
    }

    for (unsigned Index = 0; Index < Count; ++Index) {
        const GREENQUIC_P5_POSITION_SNAPSHOT* S =
            &GreenQuicP5PositionSnapshots[Index];
        printf(
            "[GreenQUIC-P5-SNAPSHOT] schema=greenquic-p5-position-v2 "
            "label=%s request=%u monotonic_ns=%" PRIu64
            " rx_pkts=%" PRIu64 " tx_pkts=%" PRIu64
            " hint_ack_pending=%" PRIu64
            " hint_cubic_cwnd_blocked=%" PRIu64
            " hint_cubic_recovery=%" PRIu64
            " hint_cubic_recovery_end=%" PRIu64
            " hint_cubic_ramping=%" PRIu64
            " hint_server_file_tx_active=%" PRIu64
            " hint_server_file_tx_end=%" PRIu64
            " hint_client_file_rx_active=%" PRIu64
            " hint_client_file_rx_end=%" PRIu64 "\n",
            S->IsEnd ? "end" : "start",
            S->RequestIndex,
            S->MonotonicNs,
            S->RxPackets,
            S->TxPackets,
            S->Hints.AckPending,
            S->Hints.CubicCwndBlocked,
            S->Hints.CubicRecovery,
            S->Hints.CubicRecoveryEnd,
            S->Hints.CubicRamping,
            S->Hints.ServerFileTxActive,
            S->Hints.ServerFileTxEnd,
            S->Hints.ClientFileRxActive,
            S->Hints.ClientFileRxEnd);
    }
    fflush(stdout);
}

typedef struct __attribute__((aligned(64))) DPDK_RX_PACKET {
'''
# Remove the leading space before the closing brace introduced above.
code=code.replace(''' } DPDK_DATAPATH;''','''} DPDK_DATAPATH;''',1)
d=once(d,anchor,code,'datapath boundary recorder')
datapath.write_text(d)
print(MARK)
