#!/usr/bin/env python3
from __future__ import annotations

import argparse,json,select,statistics,subprocess,time
from pathlib import Path

REMOTE_PROBE = r'''python3 -u -c 'import json,sys,time
print("READY", flush=True)
for _ in sys.stdin:
    print(json.dumps({"wall_ns":time.time_ns(),"monotonic_ns":time.monotonic_ns()}), flush=True)' '''


def _readline_timeout(pipe,timeout_s:float)->str:
    ready,_,_=select.select([pipe],[],[],timeout_s)
    if not ready:raise TimeoutError('clock-sync remote response timeout')
    line=pipe.readline()
    if not line:raise RuntimeError('clock-sync remote probe exited early')
    return line.strip()


def sample_session(proc)->dict[str,int]:
    wall0=time.time_ns();mono0=time.monotonic_ns()
    proc.stdin.write('ping\n');proc.stdin.flush()
    remote=json.loads(_readline_timeout(proc.stdout,5.0))
    mono1=time.monotonic_ns();wall1=time.time_ns()
    rtt=mono1-mono0;mono_mid=(mono0+mono1)//2;wall_mid=(wall0+wall1)//2
    return {
      'controller_send_wall_ns':wall0,'controller_receive_wall_ns':wall1,'controller_midpoint_wall_ns':wall_mid,
      'controller_send_monotonic_ns':mono0,'controller_receive_monotonic_ns':mono1,'controller_midpoint_monotonic_ns':mono_mid,
      'client_wall_ns':int(remote['wall_ns']),'client_monotonic_ns':int(remote['monotonic_ns']),'round_trip_ns':rtt,
      'client_minus_controller_offset_ns':int(remote['wall_ns'])-wall_mid,
      'client_minus_controller_monotonic_offset_ns':int(remote['monotonic_ns'])-mono_mid,
      'uncertainty_ns':(rtt+1)//2,
    }


def collect(host:str,count:int)->list[dict[str,int]]:
    command=['ssh','-o','BatchMode=yes','-o','ConnectTimeout=10',f'root@{host}',REMOTE_PROBE]
    proc=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
    try:
        if _readline_timeout(proc.stdout,15.0)!='READY':raise RuntimeError('clock-sync remote probe did not become ready')
        # Discard warm-up exchanges so SSH setup/remote Python startup cannot
        # inflate the actual clock-offset uncertainty.
        for _ in range(3):sample_session(proc)
        return [sample_session(proc) for _ in range(count)]
    finally:
        try:
            if proc.stdin:proc.stdin.close()
        except Exception:pass
        try:proc.wait(timeout=2)
        except Exception:
            proc.terminate()
            try:proc.wait(timeout=2)
            except Exception:proc.kill()


def main()->int:
    ap=argparse.ArgumentParser();ap.add_argument('--host',required=True);ap.add_argument('--out',type=Path,required=True);ap.add_argument('--samples',type=int,default=25);args=ap.parse_args()
    if args.samples<1:raise SystemExit('ERROR: --samples must be positive')
    count=max(args.samples,25);samples=collect(args.host,count);best=min(samples,key=lambda r:r['round_trip_ns'])
    wall=[r['client_minus_controller_offset_ns'] for r in samples];mono=[r['client_minus_controller_monotonic_offset_ns'] for r in samples]
    result={
      'schema':'greenquic-p5-clock-sync-v3','controller_host':'idex','client_host':args.host,
      'method':'single persistent SSH session; 3 warm-up exchanges discarded; minimum-RTT midpoint estimate; direct CLOCK_MONOTONIC mapping',
      'sample_count':len(samples),'warmup_count':3,
      'client_minus_controller_offset_ns':best['client_minus_controller_offset_ns'],'round_trip_ns':best['round_trip_ns'],'uncertainty_ns':best['uncertainty_ns'],
      'offset_spread_ns':max(wall)-min(wall),'median_offset_ns':int(statistics.median(wall)),
      'client_minus_controller_monotonic_offset_ns':best['client_minus_controller_monotonic_offset_ns'],'monotonic_uncertainty_ns':best['uncertainty_ns'],
      'monotonic_offset_spread_ns':max(mono)-min(mono),'median_monotonic_offset_ns':int(statistics.median(mono)),'samples':samples}
    args.out.parent.mkdir(parents=True,exist_ok=True);args.out.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print('[P5-CLOCK-SYNC] '+f"client_minus_server_mono_ms={result['client_minus_controller_monotonic_offset_ns']/1e6:.3f} "+f"rtt_ms={result['round_trip_ns']/1e6:.3f} "+f"uncertainty_ms={result['monotonic_uncertainty_ns']/1e6:.3f} "+f"spread_ms={result['monotonic_offset_spread_ns']/1e6:.3f}",flush=True)
    return 0

if __name__=='__main__':raise SystemExit(main())
