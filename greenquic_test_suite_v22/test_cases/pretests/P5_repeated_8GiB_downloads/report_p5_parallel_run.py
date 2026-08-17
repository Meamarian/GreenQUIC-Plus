#!/usr/bin/env python3
from __future__ import annotations

import argparse,json,re
from pathlib import Path
from statistics import mean

BATCH_START=re.compile(r'^\[GreenQUIC-PARALLEL\] batch=1 start_us=(\d+) connections=(\d+)$')
BATCH_END=re.compile(r'^\[GreenQUIC-PARALLEL\] batch=1 complete_us=(\d+) duration_us=(\d+) connections=(\d+) connected=(\d+) completed=(\d+) success=(0|1)$')
CONN_START=re.compile(r'^\[GreenQUIC-PARALLEL\] conn=(\d+)/(\d+) start_us=(\d+) local_port=(\d+) path=(\S+)$')
CONN_END=re.compile(r'^\[GreenQUIC-PARALLEL\] conn=(\d+)/(\d+) complete_us=(\d+) duration_us=(\d+) success=(0|1) local_port=(\d+) path=(\S+)$')

def main()->int:
    ap=argparse.ArgumentParser();ap.add_argument('--log',type=Path,required=True);ap.add_argument('--manifest',type=Path,required=True);ap.add_argument('--mode',choices=('off','basic','plus'),required=True);ap.add_argument('--connections',type=int,required=True);ap.add_argument('--out',type=Path,required=True);ap.add_argument('--text-out',type=Path,required=True);ap.add_argument('--goodput-out',type=Path);a=ap.parse_args()
    text=a.log.read_text(encoding='utf-8',errors='replace');manifest=json.loads(a.manifest.read_text(encoding='utf-8'));starts={};ends={};bs=None;be=None
    for raw in text.splitlines():
        line=raw.strip();m=BATCH_START.match(line)
        if m:bs=(int(m.group(1)),int(m.group(2)));continue
        m=BATCH_END.match(line)
        if m:be=tuple(map(int,m.groups()));continue
        m=CONN_START.match(line)
        if m:
            i,total,start,port,path=m.groups();starts[int(i)]={'index':int(i),'total':int(total),'start_us':int(start),'local_port':int(port),'path':path};continue
        m=CONN_END.match(line)
        if m:
            i,total,complete,duration,success,port,path=m.groups();ends[int(i)]={'index':int(i),'total':int(total),'complete_us':int(complete),'duration_us':int(duration),'success':int(success),'local_port':int(port),'path':path}
    n=a.connections
    if n<2 or bs is None or be is None:raise SystemExit('ERROR: incomplete parallel batch markers')
    if bs[1]!=n or be[2]!=n or be[3]!=n or be[4]!=n or be[5]!=1:raise SystemExit(f'ERROR: parallel batch did not complete cleanly: start={bs} end={be}')
    if set(starts)!=set(range(1,n+1)) or set(ends)!=set(range(1,n+1)):raise SystemExit(f'ERROR: incomplete per-connection markers: starts={sorted(starts)} ends={sorted(ends)}')
    for i in range(1,n+1):
        if ends[i]['success']!=1:raise SystemExit(f'ERROR: connection {i} failed')
        if starts[i]['local_port']!=ends[i]['local_port'] or starts[i]['path']!=ends[i]['path']:raise SystemExit(f'ERROR: connection {i} identity changed')
    ports=[starts[i]['local_port'] for i in range(1,n+1)]
    if len(set(ports))!=n:raise SystemExit(f'ERROR: local UDP ports are not unique: {ports}')
    files=int(manifest.get('file_count',0));total_bytes=int(manifest.get('total_bytes',0));duration_us=int(be[1])
    if files!=n or total_bytes<=0 or duration_us<=0:raise SystemExit(f'ERROR: manifest/timing mismatch files={files} bytes={total_bytes} duration_us={duration_us}')
    per_payload=total_bytes//n;aggregate=total_bytes*8.0/duration_us/1000.0;per=[]
    for i in range(1,n+1):
        d=int(ends[i]['duration_us']);per.append({**starts[i],**ends[i],'goodput_gbps':per_payload*8.0/d/1000.0})
    metrics={'schema':'greenquic-p5-parallel-connections-v2','mode':a.mode,'processes':{'client':1},'quic_connections':n,'streams':n,'payload_bytes_per_connection':per_payload,'payload_bytes_total':total_bytes,'local_udp_ports':ports,'batch_start_us':bs[0],'batch_complete_us':int(be[0]),'workload_elapsed_us':duration_us,'aggregate_goodput_gbps':aggregate,'aggregate_goodput_excluding_gaps_gbps':aggregate,'aggregate_goodput_including_gaps_gbps':aggregate,'connection_duration_us':[int(ends[i]['duration_us']) for i in range(1,n+1)],'connection_goodput_gbps':[r['goodput_gbps'] for r in per],'connections':per}
    a.out.parent.mkdir(parents=True,exist_ok=True);a.out.write_text(json.dumps(metrics,indent=2)+'\n',encoding='utf-8')
    lines=['','=== GreenQUIC P5 Parallel Goodput Summary ===',f'- GreenQUIC mode: {a.mode}',f'- QUIC connections: {n}',f'- Payload per download: {per_payload/(1024**3):.3f} GiB',f'- Total payload: {total_bytes/(1024**3):.3f} GiB',f'- Parallel batch duration: {duration_us/1e6:.6f} s']
    for r in per:lines.append(f'- Download {r["index"]}: duration={r["duration_us"]/1e6:.6f} s goodput={r["goodput_gbps"]:.6f} Gbit/s port={r["local_port"]} path={r["path"]}')
    lines += [f'- Average individual goodput: {mean(r["goodput_gbps"] for r in per):.6f} Gbit/s',f'- TOTAL aggregate goodput: {aggregate:.6f} Gbit/s','- Goodput definition: total useful payload bits from all concurrent connections / parallel batch wall-clock duration.','- Do not use quicinterop total execution/transmission time for aggregate goodput.','']
    a.text_out.write_text('\n'.join(lines),encoding='utf-8')
    if a.goodput_out:
        gp={'schema':'greenquic-goodput-v4-parallel','test_id':'P5','mode':a.mode,'definition':'total successfully downloaded payload bits across all concurrent QUIC connections divided by parallel batch wall-clock duration','payload_bytes':total_bytes,'payload_gib':total_bytes/(1024**3),'quic_connections':n,'local_udp_ports':ports,'timing_source':'GreenQUIC parallel batch CLOCK_MONOTONIC microsecond markers','primary':{'duration_s':duration_us/1e6,'goodput_bps':aggregate*1e9,'goodput_mbps_decimal':aggregate*1e3,'goodput_gbps_decimal':aggregate},'per_connection':per}
        a.goodput_out.write_text(json.dumps(gp,indent=2)+'\n',encoding='utf-8')
    print('\n'.join(lines));return 0
if __name__=='__main__':raise SystemExit(main())
