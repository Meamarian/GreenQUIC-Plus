#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import math
import re
from pathlib import Path
from statistics import mean


def read_rapl(path: Path) -> list[dict[str, str]]:
    if not path.is_file(): return []
    lines=[line for line in path.read_text(errors='replace').splitlines() if line and not line.startswith('#')]
    return list(csv.DictReader(lines)) if lines else []

def read_jsonl(path: Path) -> list[dict]:
    out=[]
    if not path.is_file(): return out
    for raw in path.read_text(errors='replace').splitlines():
        try: row=json.loads(raw)
        except Exception: continue
        if isinstance(row,dict): out.append(row)
    return out

def union_duration_ns(windows): return sum(max(0,b-a) for a,b in windows)
def overlap_ns(a,b,windows): return sum(max(0,min(b,y)-max(a,x)) for x,y in windows)
def in_windows(ts,windows): return any(a<=ts<b for a,b in windows)

def parse_app_windows(role: str, text: str):
    if role=='client':
        starts={int(i):int(us)*1000 for i,_n,us in re.findall(r'\[GreenQUIC-P5\]\s+request=(\d+)/(\d+)\s+start_us=(\d+)',text)}
        completes={int(i):int(us)*1000 for i,_n,us in re.findall(r'\[GreenQUIC-P5\]\s+request=(\d+)/(\d+)\s+complete_us=(\d+)',text)}
    else:
        starts={int(i):int(us)*1000 for i,us in re.findall(r'\[GreenQUIC-P7\]\s+request=(\d+)\s+start_us=(\d+)',text)}
        completes={int(i):int(us)*1000 for i,us in re.findall(r'\[GreenQUIC-P7\]\s+request=(\d+)\s+complete_us=(\d+)',text)}
    ids=sorted(set(starts)&set(completes))
    active=[(starts[i],completes[i]) for i in ids if completes[i]>starts[i]]
    gaps=[]
    for left,right in zip(ids,ids[1:]):
        a,b=completes[left],starts[right]
        if b>a: gaps.append((a,b))
    combined=[(active[0][0],active[-1][1])] if active else []
    return {'active':active,'gap':gaps,'combined':combined}

def parse_p5_goodput(text: str, payload_bytes: int, downloads: int):
    starts={int(i):int(us) for i,_n,us in re.findall(r'\[GreenQUIC-P5\]\s+request=(\d+)/(\d+)\s+start_us=(\d+)',text)}
    completions={}
    pat=re.compile(r'\[GreenQUIC-P5\]\s+request=(\d+)/(\d+)\s+complete_us=(\d+)\s+path=\S+\s+duration_us=(\d+)\s+success=(\d+)')
    for i,_n,complete_us,duration_us,success in pat.findall(text):
        completions[int(i)]={'complete_us':int(complete_us),'duration_us':int(duration_us),'success':int(success)}
    expected=range(1,downloads+1)
    if any(i not in starts or i not in completions for i in expected):
        raise SystemExit(f'P7 client is missing P5-compatible timing markers: starts={len(starts)} completions={len(completions)} expected={downloads}')
    if any(completions[i]['success'] != 1 for i in expected):
        raise SystemExit('P7 client has a failed download; refusing goodput calculation')
    durations=[completions[i]['duration_us'] for i in expected]
    if any(v <= 0 for v in durations):
        raise SystemExit('P7 client has a non-positive P5 duration_us')
    active_us=sum(durations)
    workload_us=completions[downloads]['complete_us']-starts[1]
    if workload_us <= 0:
        raise SystemExit('P7 client workload elapsed time is not positive')
    total_bytes=payload_bytes*downloads
    active_gp=total_bytes*8.0/active_us/1000.0
    workload_gp=total_bytes*8.0/workload_us/1000.0
    return {
        'download_duration_us':durations,
        'download_duration_us_total':active_us,
        'workload_elapsed_us':workload_us,
        'goodput_active_downloads_gbps':active_gp,
        'goodput_workload_including_gaps_gbps':workload_gp,
    }

def control_windows(path: Path):
    rows=read_jsonl(path); last={}
    for row in rows:
        event=str(row.get('event','')); ts=int(row.get('monotonic_ns',0) or 0)
        if event and 'monotonic_ns' in row: last[event]=ts
    out={}
    for name in ('pre_cool','post_cool'):
        a,b=last.get(name+'_start'),last.get(name+'_end')
        if a is not None and b is not None and b>a: out[name]=[(a,b)]
    return out

def rapl_metrics(rows,windows):
    duration_s=union_duration_ns(windows)/1e9
    empty={'available':False,'duration_s':duration_s,'package_j':None,'dram_j':None,'total_j':None,'package_w':None,'dram_w':None,'total_w':None,'samples':0}
    if not windows or not rows: return empty
    result={'available':True,'duration_s':duration_s,'package_j':0.0,'dram_j':0.0,'total_j':0.0,'samples':0}
    for row in rows:
        try:
            end=int(float(row['sample_monotonic_ns'])); dt=float(row['actual_interval_ms'])*1e6; start=int(end-dt)
            if end<=start: continue
            ov=overlap_ns(start,end,windows)
            if ov<=0: continue
            frac=ov/(end-start); pj=float(row.get('package_delta_j',0) or 0)*frac; dj=float(row.get('dram_delta_j',0) or 0)*frac
        except (KeyError,TypeError,ValueError): continue
        result['package_j']+=pj; result['dram_j']+=dj; result['samples']+=1
    if result['samples']==0: return empty
    result['total_j']=result['package_j']+result['dram_j']
    if duration_s>0:
        result['package_w']=result['package_j']/duration_s; result['dram_w']=result['dram_j']/duration_s; result['total_w']=result['total_j']/duration_s
    else: result['package_w']=result['dram_w']=result['total_w']=None
    return result

def frequency_metrics(rows,windows):
    by_cpu={}
    for row in rows:
        if row.get('type')!='line': continue
        try: ts=int(row['monotonic_ns']); cpu=int(row['cpu']); ghz=float(row['freq_khz'])/1e6
        except (KeyError,TypeError,ValueError): continue
        if in_windows(ts,windows): by_cpu.setdefault(cpu,[]).append(ghz)
    return {str(cpu):{'n':len(vals),'min_ghz':min(vals),'mean_ghz':mean(vals),'max_ghz':max(vals)} for cpu,vals in sorted(by_cpu.items())}

def bridge_offset(rows,raw_ns):
    bridges=[r for r in rows if r.get('type')=='clock_bridge' and r.get('monotonic_raw_ns') is not None]
    if not bridges: return 0
    bridges.sort(key=lambda r:int(r['monotonic_raw_ns']))
    if len(bridges)==1: return int(bridges[0]['offset_ns'])
    a,b=bridges[0],bridges[-1]; ar,br=int(a['monotonic_raw_ns']),int(b['monotonic_raw_ns']); ao,bo=int(a['offset_ns']),int(b['offset_ns'])
    if br==ar: return ao
    f=min(1.0,max(0.0,(raw_ns-ar)/(br-ar))); return int(round(ao+f*(bo-ao)))

def load_cstate_names(path):
    names={}
    if not path.is_file(): return names
    try: data=json.loads(path.read_text())
    except Exception: return names
    for states in (data.get('cpus') or {}).values():
        for row in states:
            try: names[int(row['index'])]=str(row.get('name') or f"state{row['index']}")
            except Exception: pass
    return names

def cstate_metrics(cstate,freq_rows,names,windows):
    out={}
    if not cstate.is_file() or not windows: return {}
    with cstate.open(newline='',encoding='utf-8',errors='replace') as f:
        for row in csv.DictReader(f):
            if row.get('event')!='wake': continue
            try: raw_end=int(row['timestamp_mono_raw_ns']); duration=int(row['idle_duration_ns']); state=int(row['previous_state'])
            except (KeyError,TypeError,ValueError): continue
            if duration<=0 or state<0: continue
            raw_start=raw_end-duration; start=raw_start+bridge_offset(freq_rows,raw_start); end=raw_end+bridge_offset(freq_rows,raw_end); ov=overlap_ns(start,end,windows)
            if ov<=0: continue
            rec=out.setdefault(state,{'state':names.get(state,f'state{state}'),'seconds':0.0,'intervals':0}); rec['seconds']=float(rec['seconds'])+ov/1e9; rec['intervals']=int(rec['intervals'])+1
    return {str(k):v for k,v in sorted(out.items())}

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--role',choices=('server','client'),required=True); ap.add_argument('--run-dir',type=Path,required=True); ap.add_argument('--payload-bytes',type=int,required=True); ap.add_argument('--downloads',type=int,required=True); ap.add_argument('--output',type=Path,required=True); args=ap.parse_args()
    run=args.run_dir; text=(run/f'{args.role}.log').read_text(errors='replace'); windows=parse_app_windows(args.role,text)
    if len(windows.get('active',[]))!=args.downloads: raise SystemExit(f"expected {args.downloads} complete application windows for {args.role}, found {len(windows.get('active',[]))}")
    expected_gaps=max(0,args.downloads-1)
    if len(windows.get('gap',[]))!=expected_gaps: raise SystemExit(f"expected {expected_gaps} application gaps for {args.role}, found {len(windows.get('gap',[]))}")
    windows.update(control_windows(run/'control_timeline.jsonl')); rapl=read_rapl(run/'rapl.csv'); freq=read_jsonl(run/'frequency.jsonl'); names=load_cstate_names(run/'cstate_mapping.json')
    scopes={}
    for scope,ws in windows.items(): scopes[scope]={'window_count':len(ws),'duration_s':union_duration_ns(ws)/1e9,'rapl':rapl_metrics(rapl,ws),'frequency':frequency_metrics(freq,ws),'cstate':cstate_metrics(run/'cstate.csv',freq,names,ws)}
    data={'schema':'greenquic-p7-linux-run-v1','role':args.role,'payload_bytes_per_download':args.payload_bytes,'downloads':args.downloads,'useful_bytes':args.payload_bytes*args.downloads,'windows':{k:[[a,b] for a,b in v] for k,v in windows.items()},'scopes':scopes}
    if args.role=='client':
        p5gp=parse_p5_goodput(text,args.payload_bytes,args.downloads)
        data.update(p5gp)
        # Compatibility aliases retained for the existing P7 aggregate/charts.
        data['goodput_gbps']=p5gp['goodput_active_downloads_gbps']
        data['gap_inclusive_goodput_gbps']=p5gp['goodput_workload_including_gaps_gbps']
        bits=data['useful_bytes']*8.0; useful_gbit=bits/1e9
        for scope in ('active','combined'):
            total_j=scopes.get(scope,{}).get('rapl',{}).get('total_j')
            if total_j is not None and useful_gbit>0: scopes[scope]['j_per_useful_gbit']=total_j/useful_gbit
    args.output.parent.mkdir(parents=True,exist_ok=True); args.output.write_text(json.dumps(data,indent=2)+'\n')
    print(f"P7 {args.role} summary")
    if args.role=='client':
        goodput=data.get('goodput_active_downloads_gbps'); gap_goodput=data.get('goodput_workload_including_gaps_gbps')
        if goodput is None or gap_goodput is None: raise SystemExit('client goodput could not be derived from P5-compatible timing markers')
        print(f"goodput_active_downloads={goodput:.6f} Gbit/s")
        print(f"goodput_workload_including_gaps={gap_goodput:.6f} Gbit/s")
        print(f"download_duration_us_total={data['download_duration_us_total']}")
        print(f"workload_elapsed_us={data['workload_elapsed_us']}")
    for scope in ('pre_cool','active','gap','combined','post_cool'):
        if scope not in scopes: continue
        r=scopes[scope]['rapl']; energy=r.get('total_j'); power=r.get('total_w'); energy_text=f'{energy:.6f}J' if isinstance(energy,(int,float)) else 'N/A'; power_text=f'{power:.6f}W' if isinstance(power,(int,float)) else 'N/A'
        print(f"{scope}: duration={scopes[scope]['duration_s']:.6f}s energy={energy_text} power={power_text}")
    return 0
if __name__=='__main__': raise SystemExit(main())
