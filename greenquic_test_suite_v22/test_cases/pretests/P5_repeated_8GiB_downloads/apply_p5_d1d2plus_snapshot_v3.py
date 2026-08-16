#!/usr/bin/env python3
from pathlib import Path
import sys
OLD="GREENQUIC-P5-D1D2PLUS-SNAPSHOT-V2";NEW="GREENQUIC-P5-D1D2PLUS-SNAPSHOT-V3"
if len(sys.argv)!=5:raise SystemExit("usage: apply_p5_d1d2plus_snapshot_v3.py CLIENT_CPP SERVER_CPP SERVER_H DATAPATH_C")
client,server,header,datapath=map(Path,sys.argv[1:])
for p in (client,server,header,datapath):
    t=p.read_text()
    if NEW in t:raise SystemExit(f"ERROR: {p} already contains {NEW}")
    n=t.count(OLD)
    if n<1:raise SystemExit(f"ERROR: {p} missing prerequisite {OLD}")
    p.write_text(t.replace(OLD,NEW))

s=server.read_text()
old='''    case QUIC_STREAM_EVENT_SEND_COMPLETE:
        if (pThis->Shutdown &&
            pThis->GreenQuicP5SnapshotIndex != 0 &&
            !pThis->GreenQuicP5SnapshotDone) {
            CxPlatGreenQuicP5PositionSnapshot("end", pThis->GreenQuicP5SnapshotIndex);
            pThis->GreenQuicP5SnapshotDone = true;
        }
        pThis->SendData();
        break;
'''
new='''    case QUIC_STREAM_EVENT_SEND_COMPLETE:
        pThis->SendData();
        break;
'''
if s.count(old)!=1:raise SystemExit(f"ERROR: V2 SEND_COMPLETE snapshot block expected once, got {s.count(old)}")
s=s.replace(old,new,1)
anchor='''    case QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE:
        if (pThis->GreenQuicServerTxHintActive) {
'''
insert='''    case QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE:
        // D1/D2+ V3: use stream lifecycle completion, not merely final local
        // send-buffer completion, for the server-side counter/hint boundary.
        if (pThis->GreenQuicP5SnapshotIndex != 0 && !pThis->GreenQuicP5SnapshotDone) {
            CxPlatGreenQuicP5PositionSnapshot("end", pThis->GreenQuicP5SnapshotIndex);
            pThis->GreenQuicP5SnapshotDone = true;
        }
        if (pThis->GreenQuicServerTxHintActive) {
'''
if s.count(anchor)!=1:raise SystemExit(f"ERROR: SHUTDOWN_COMPLETE anchor expected once, got {s.count(anchor)}")
s=s.replace(anchor,insert,1)
old_start='''    printf("[%s] GET '%s'\\n", GetRemoteAddr(MsQuic, QuicStream).Address, PathStart);
    if (GreenQuicP5PositionSnapshotEnabled()) {
        GreenQuicP5SnapshotIndex =
            GreenQuicP5ServerRequestIndex.fetch_add(1, std::memory_order_relaxed) + 1;
        CxPlatGreenQuicP5PositionSnapshot("start", GreenQuicP5SnapshotIndex);
    }
    File = fopen(FullFilePath, "rb"); // In case of failure, SendData still works.
'''
new_start='''    if (GreenQuicP5PositionSnapshotEnabled()) {
        GreenQuicP5SnapshotIndex =
            GreenQuicP5ServerRequestIndex.fetch_add(1, std::memory_order_relaxed) + 1;
        CxPlatGreenQuicP5PositionSnapshot("start", GreenQuicP5SnapshotIndex);
    }
    printf("[%s] GET '%s'\\n", GetRemoteAddr(MsQuic, QuicStream).Address, PathStart);
    File = fopen(FullFilePath, "rb"); // In case of failure, SendData still works.
'''
if s.count(old_start)!=1:raise SystemExit(f"ERROR: server start snapshot block expected once, got {s.count(old_start)}")
server.write_text(s.replace(old_start,new_start,1))

d=datapath.read_text()
old_struct='''    uint64_t MonotonicNs;
    uint64_t RxPackets;
'''
new_struct='''    uint64_t MonotonicNs;
    uint64_t CaptureSpanNs;
    uint64_t RxPackets;
'''
if d.count(old_struct)!=1:raise SystemExit(f"ERROR: snapshot struct timing fields expected once, got {d.count(old_struct)}")
d=d.replace(old_struct,new_struct,1)
old_entry='''    if (Label == NULL || RequestIndex == 0U) {
        return;
    }

    const unsigned Slot = atomic_fetch_add_explicit(
'''
new_entry='''    if (Label == NULL || RequestIndex == 0U) {
        return;
    }

    const uint64_t CaptureStartNs = GreenQuicTransferMonotonicNs();

    const unsigned Slot = atomic_fetch_add_explicit(
'''
if d.count(old_entry)!=1:raise SystemExit(f"ERROR: snapshot capture entry expected once, got {d.count(old_entry)}")
d=d.replace(old_entry,new_entry,1)
old_stamp='''    Snapshot->MonotonicNs = GreenQuicTransferMonotonicNs();
    Snapshot->RxPackets = atomic_load_explicit(
'''
new_stamp='''    Snapshot->MonotonicNs = CaptureStartNs;
    Snapshot->RxPackets = atomic_load_explicit(
'''
if d.count(old_stamp)!=1:raise SystemExit(f"ERROR: snapshot monotonic assignment expected once, got {d.count(old_stamp)}")
d=d.replace(old_stamp,new_stamp,1)
old_hints='''    CxPlatGreenQuicPlusGetHintCounters(&Snapshot->Hints);
}
'''
new_hints='''    CxPlatGreenQuicPlusGetHintCounters(&Snapshot->Hints);
    const uint64_t CaptureEndNs = GreenQuicTransferMonotonicNs();
    Snapshot->CaptureSpanNs =
        CaptureEndNs >= CaptureStartNs ? CaptureEndNs - CaptureStartNs : 0U;
}
'''
if d.count(old_hints)!=1:raise SystemExit(f"ERROR: snapshot hint capture expected once, got {d.count(old_hints)}")
d=d.replace(old_hints,new_hints,1)
old_fmt='''            "label=%s request=%u monotonic_ns=%" PRIu64
            " rx_pkts=%" PRIu64 " tx_pkts=%" PRIu64
'''
new_fmt='''            "label=%s request=%u monotonic_ns=%" PRIu64
            " capture_span_ns=%" PRIu64
            " rx_pkts=%" PRIu64 " tx_pkts=%" PRIu64
'''
if d.count(old_fmt)!=1:raise SystemExit(f"ERROR: snapshot printf format expected once, got {d.count(old_fmt)}")
d=d.replace(old_fmt,new_fmt,1)
old_args='''            S->RequestIndex,
            S->MonotonicNs,
            S->RxPackets,
'''
new_args='''            S->RequestIndex,
            S->MonotonicNs,
            S->CaptureSpanNs,
            S->RxPackets,
'''
if d.count(old_args)!=1:raise SystemExit(f"ERROR: snapshot printf args expected once, got {d.count(old_args)}")
datapath.write_text(d.replace(old_args,new_args,1))
print(NEW)
