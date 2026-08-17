#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from statistics import mean

BATCH_START = re.compile(r"^\[GreenQUIC-PARALLEL\] batch=1 start_us=(\d+) connections=(\d+)$")
BATCH_END = re.compile(
    r"^\[GreenQUIC-PARALLEL\] batch=1 complete_us=(\d+) duration_us=(\d+) "
    r"connections=(\d+) connected=(\d+) completed=(\d+) success=(0|1)$"
)
CONN_START = re.compile(
    r"^\[GreenQUIC-PARALLEL\] conn=(\d+)/(\d+) start_us=(\d+) "
    r"local_port=(\d+) path=(\S+)$"
)
CONN_END = re.compile(
    r"^\[GreenQUIC-PARALLEL\] conn=(\d+)/(\d+) complete_us=(\d+) "
    r"duration_us=(\d+) success=(0|1) local_port=(\d+) path=(\S+)$"
)


def main() -> int:
    ap=argparse.ArgumentParser()
    ap.add_argument('--log',type=Path,required=True)
    ap.add_argument('--manifest',type=Path,required=True)
    ap.add_argument('--mode',choices=('off','basic','plus'),required=True)
    ap.add_argument('--connections',type=int,required=True)
    ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--text-out',type=Path,required=True)
    ap.add_argument('--goodput-out',type=Path)
    args=ap.parse_args()

    text=args.log.read_text(encoding='utf-8',errors='replace')
    manifest=json.loads(args.manifest.read_text(encoding='utf-8'))
    starts={}; ends={}; batch_start=None; batch_end=None
    for raw in text.splitlines():
        line=raw.strip()
        m=BATCH_START.match(line)
        if m:
            batch_start=(int(m.group(1)),int(m.group(2))); continue
        m=BATCH_END.match(line)
        if m:
            batch_end=tuple(map(int,m.groups())); continue
        m=CONN_START.match(line)
        if m:
            i,total,start,port,path=m.groups(); starts[int(i)]={'index':int(i),'total':int(total),'start_us':int(start),'local_port':int(port),'path':path}; continue
        m=CONN_END.match(line)
        if m:
            i,total,complete,duration,success,port,path=m.groups(); ends[int(i)]={'index':int(i),'total':int(total),'complete_us':int(complete),'duration_us':int(duration),'success':int(success),'local_port':int(port),'path':path}

    n=args.connections
    if n < 2: raise SystemExit('ERROR: parallel report requires >=2 connections')
    if batch_start is None or batch_end is None:
        raise SystemExit('ERROR: missing parallel batch start/end markers')
    if batch_start[1] != n or batch_end[2] != n or batch_end[3] != n or batch_end[4] != n or batch_end[5] != 1:
        raise SystemExit(f'ERROR: parallel batch did not complete cleanly: start={batch_start} end={batch_end}')
    if set(starts) != set(range(1,n+1)) or set(ends) != set(range(1,n+1)):
        raise SystemExit(f'ERROR: incomplete per-connection markers: starts={sorted(starts)} ends={sorted(ends)}')
    for i in range(1,n+1):
        if ends[i]['success'] != 1: raise SystemExit(f'ERROR: connection {i} failed')
        if starts[i]['local_port'] != ends[i]['local_port'] or starts[i]['path'] != ends[i]['path']:
            raise SystemExit(f'ERROR: connection {i} identity changed')
    ports=[starts[i]['local_port'] for i in range(1,n+1)]
    if len(set(ports)) != n:
        raise SystemExit(f'ERROR: local UDP ports are not unique: {ports}')

    files=int(manifest.get('file_count',0)); total_bytes=int(manifest.get('total_bytes',0))
    if files != n or total_bytes <= 0:
        raise SystemExit(f'ERROR: manifest mismatch files={files} expected={n} bytes={total_bytes}')
    duration_us=int(batch_end[1])
    if duration_us <= 0: raise SystemExit('ERROR: non-positive parallel batch duration')
    goodput=total_bytes*8.0/duration_us/1000.0
    per_payload=total_bytes//n
    per=[]
    for i in range(1,n+1):
        d=int(ends[i]['duration_us'])
        per.append({**starts[i],**ends[i],'goodput_gbps':per_payload*8.0/d/1000.0})

    metrics={
        'schema':'greenquic-p5-parallel-connections-v1',
        'mode':args.mode,
        'processes':{'client':1},
        'quic_connections':n,
        'streams':n,
        'payload_bytes_per_connection':per_payload,
        'payload_bytes_total':total_bytes,
        'local_udp_ports':ports,
        'batch_start_us':batch_start[0],
        'batch_complete_us':int(batch_end[0]),
        'workload_elapsed_us':duration_us,
        'aggregate_goodput_gbps':goodput,
        'aggregate_goodput_excluding_gaps_gbps':goodput,
        'aggregate_goodput_including_gaps_gbps':goodput,
        'connection_duration_us':[int(ends[i]['duration_us']) for i in range(1,n+1)],
        'connection_goodput_gbps':[row['goodput_gbps'] for row in per],
        'connections':per,
    }
    args.out.parent.mkdir(parents=True,exist_ok=True)
    args.out.write_text(json.dumps(metrics,indent=2)+'\n',encoding='utf-8')

    lines=[
        '',
        '=== GreenQUIC P5 Workload Summary ===',
        f'- GreenQUIC mode: {args.mode}',
        '- Client processes: 1',
        f'- QUIC connections: {n}',
        f'- Parallel streams/downloads: {n}',
        f'- Payload per download: {per_payload/(1024**3):.3f} GiB',
        f'- Total payload: {total_bytes/(1024**3):.3f} GiB',
        '- Configured gap: 0.000000 s',
        '- Configured total gap time: 0.000000 s',
        '- Observed total gap time: 0.000000 s',
        f'- Parallel batch wall-clock duration: {duration_us/1e6:.6f} s',
        f'- Average connection duration: {mean(row["duration_us"] for row in per)/1e6:.6f} s',
        f'- Workload elapsed time including gaps: {duration_us/1e6:.6f} s',
        f'- Aggregate goodput excluding gaps: {goodput:.6f} Gbit/s',
        f'- Aggregate goodput including gaps: {goodput:.6f} Gbit/s',
        f'- Local UDP ports: {",".join(map(str,ports))}',
        '- Goodput definition: total useful payload bits from all concurrent connections divided by batch wall-clock time.',
        '',
    ]
    args.text_out.write_text('\n'.join(lines),encoding='utf-8')

    if args.goodput_out:
        gp={
            'schema':'greenquic-goodput-v3-parallel',
            'test_id':'P5',
            'mode':args.mode,
            'definition':'total successfully downloaded payload bits across all concurrent QUIC connections divided by parallel batch wall-clock duration',
            'payload_bytes':total_bytes,
            'payload_gib':total_bytes/(1024**3),
            'quic_connections':n,
            'local_udp_ports':ports,
            'timing_source':'GreenQUIC parallel batch CLOCK_MONOTONIC microsecond markers',
            'primary':{
                'duration_s':duration_us/1e6,
                'goodput_bps':goodput*1e9,
                'goodput_mbps_decimal':goodput*1e3,
                'goodput_gbps_decimal':goodput,
            },
            'per_connection':per,
        }
        args.goodput_out.write_text(json.dumps(gp,indent=2)+'\n',encoding='utf-8')

    print('\n'.join(lines))
    return 0

if __name__=='__main__':
    raise SystemExit(main())
