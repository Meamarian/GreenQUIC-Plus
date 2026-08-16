#!/usr/bin/env python3
from pathlib import Path
import sys
OLD='GREENQUIC-P5-D1D2PLUS-SNAPSHOT-V2'
NEW='GREENQUIC-P5-D1D2PLUS-SNAPSHOT-V3'
if len(sys.argv)!=5:raise SystemExit('usage: apply_p5_d1d2plus_snapshot_v3.py CLIENT_CPP SERVER_CPP SERVER_H DATAPATH_C')
client,server,header,datapath=map(Path,sys.argv[1:])
for p in (client,server,header,datapath):
    t=p.read_text()
    if NEW in t:raise SystemExit(f'ERROR: {p} already contains {NEW}')
    n=t.count(OLD)
    if n<1:raise SystemExit(f'ERROR: {p} missing prerequisite {OLD}')
    p.write_text(t.replace(OLD,NEW))

s=server.read_text()
old='''    case QUIC_STREAM_EVENT_SEND_COMPLETE:\n        if (pThis->Shutdown &&\n            pThis->GreenQuicP5SnapshotIndex != 0 &&\n            !pThis->GreenQuicP5SnapshotDone) {\n            CxPlatGreenQuicP5PositionSnapshot("end", pThis->GreenQuicP5SnapshotIndex);\n            pThis->GreenQuicP5SnapshotDone = true;\n        }\n        pThis->SendData();\n        break;\n'''
new='''    case QUIC_STREAM_EVENT_SEND_COMPLETE:\n        pThis->SendData();\n        break;\n'''
if s.count(old)!=1:raise SystemExit(f'ERROR: V2 SEND_COMPLETE snapshot block expected once, got {s.count(old)}')
s=s.replace(old,new,1)
anchor='''    case QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE:\n        if (pThis->GreenQuicServerTxHintActive) {\n'''
insert='''    case QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE:\n        // D1/D2+ V3: use stream lifecycle completion, not merely final local\n        // send-buffer completion, for the server-side counter/hint boundary.\n        if (pThis->GreenQuicP5SnapshotIndex != 0 && !pThis->GreenQuicP5SnapshotDone) {\n            CxPlatGreenQuicP5PositionSnapshot("end", pThis->GreenQuicP5SnapshotIndex);\n            pThis->GreenQuicP5SnapshotDone = true;\n        }\n        if (pThis->GreenQuicServerTxHintActive) {\n'''
if s.count(anchor)!=1:raise SystemExit(f'ERROR: SHUTDOWN_COMPLETE anchor expected once, got {s.count(anchor)}')
server.write_text(s.replace(anchor,insert,1))
print(NEW)
