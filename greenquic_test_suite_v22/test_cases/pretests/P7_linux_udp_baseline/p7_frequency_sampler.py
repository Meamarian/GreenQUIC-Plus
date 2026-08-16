#!/usr/bin/env python3
from __future__ import annotations
import argparse,json
from pathlib import Path
import signal,time
running=True

def stop(_sig,_frame):
    global running;running=False

def parse_cpu_list(text:str)->list[int]:
    out:set[int]=set()
    for token in text.replace(' ','').split(','):
        if not token:continue
        if '-' in token:
            a,b=map(int,token.split('-',1));
            if b<a:raise ValueError(token)
            out.update(range(a,b+1))
        else:out.add(int(token))
    return sorted(out)

def read_khz(cpu:int)->int|None:
    root=Path(f'/sys/devices/system/cpu/cpu{cpu}/cpufreq')
    for name in ('scaling_cur_freq','cpuinfo_cur_freq'):
        try:
            value=int((root/name).read_text().strip())
            if value>0:return value
        except (OSError,ValueError):pass
    return None

def bridge(phase:str,attempts:int=9)->dict|None:
    raw_clock=getattr(time,'CLOCK_MONOTONIC_RAW',None)
    if raw_clock is None:return None
    best=None
    for _ in range(max(1,attempts)):
        raw_before=time.clock_gettime_ns(raw_clock);mono=time.monotonic_ns();raw_after=time.clock_gettime_ns(raw_clock);span=raw_after-raw_before;row=(span,raw_before,raw_after,mono)
        if best is None or row[0]<best[0]:best=row
    if best is None:return None
    span,raw_before,raw_after,mono=best;raw_mid=(raw_before+raw_after)//2
    return {'type':'clock_bridge','schema':'greenquic-p7-clock-bridge-v1','phase':phase,'monotonic_ns':int(mono),'monotonic_raw_ns':int(raw_mid),'offset_ns':int(mono-raw_mid),'uncertainty_ns':int((span+1)//2)}

def main()->int:
    ap=argparse.ArgumentParser();ap.add_argument('--cpus',required=True);ap.add_argument('--output',type=Path,required=True);ap.add_argument('--interval-ms',type=float,default=1.0);args=ap.parse_args()
    if args.interval_ms<=0:raise SystemExit('interval must be >0')
    cpus=parse_cpu_list(args.cpus)
    if not cpus:raise SystemExit('no CPUs selected')
    signal.signal(signal.SIGINT,stop);signal.signal(signal.SIGTERM,stop);args.output.parent.mkdir(parents=True,exist_ok=True)
    start=time.monotonic_ns();interval_ns=max(1,int(args.interval_ms*1_000_000));deadline=start
    with args.output.open('w',encoding='utf-8',buffering=1) as out:
        row=bridge('start')
        if row:out.write(json.dumps(row,separators=(',',':'))+'\n')
        while running:
            for cpu in cpus:
                read_before=time.monotonic_ns();khz=read_khz(cpu);read_after=time.monotonic_ns();now=(read_before+read_after)//2;elapsed_s=(now-start)/1e9
                if khz is not None:
                    out.write(json.dumps({'type':'line','schema':'greenquic-p7-frequency-v2','monotonic_ns':int(now),'read_span_ns':int(read_after-read_before),'read_uncertainty_ns':int((read_after-read_before+1)//2),'elapsed_s':elapsed_s,'cpu':cpu,'freq_khz':khz},separators=(',',':'))+'\n')
            deadline+=interval_ns;delay=deadline-time.monotonic_ns()
            if delay>0:time.sleep(delay/1e9)
            else:deadline=time.monotonic_ns()
        row=bridge('end')
        if row:out.write(json.dumps(row,separators=(',',':'))+'\n')
    return 0
if __name__=='__main__':raise SystemExit(main())
