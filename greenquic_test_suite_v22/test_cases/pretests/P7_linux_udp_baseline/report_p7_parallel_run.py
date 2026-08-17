#!/usr/bin/env python3
from __future__ import annotations

import argparse,json,re,time
from pathlib import Path
import report_p7_run as wrapper

base=wrapper.mod
BSTART=re.compile(r'^\[GreenQUIC-PARALLEL\] batch=1 start_us=(\d+) connections=(\d+)$',re.M)
BEND=re.compile(r'^\[GreenQUIC-PARALLEL\] batch=1 complete_us=(\d+) duration_us=(\d+) connections=(\d+) connected=(\d+) completed=(\d+) success=(0|1)$',re.M)
P7START=re.compile(r'^\[GreenQUIC-P7\] request=(\d+) start_us=(\d+) path=(\S+)$',re.M)
P7END=re.compile(r'^\[GreenQUIC-P7\] request=(\d+) complete_us=(\d+) duration_us=(\d+) success=1$',re.M)


def parallel_windows(role:str,text:str,n:int):
    if role=='client':
        starts=BSTART.findall(text);ends=BEND.findall(text)
        if len(starts)!=1 or len(ends)!=1:raise SystemExit(f'expected exactly one parallel batch, got starts={len(starts)} ends={len(ends)}')
        a,c=map(int,starts[0]);e,d,c2,connected,completed,success=map(int,ends[0])
        if c!=n or c2!=n or connected!=n or completed!=n or success!=1 or e<=a or d<=0:raise SystemExit('parallel client batch markers invalid')
        return {'active':[(a*1000,e*1000)],'gap':[],'combined':[(a*1000,e*1000)]},d
    starts={int(i):int(us)*1000 for i,us,_ in P7START.findall(text)}
    ends={int(i):int(us)*1000 for i,us,_ in P7END.findall(text)}
    ids=sorted(set(starts)&set(ends))
    if len(ids)!=n:raise SystemExit(f'P7 server has {len(ids)}/{n} completed request windows')
    individual=[(starts[i],ends[i]) for i in ids if ends[i]>starts[i]]
    if len(individual)!=n:raise SystemExit('P7 server contains non-positive request window')
    a=min(x for x,_ in individual);b=max(y for _,y in individual)
    return {'active':[(a,b)],'gap':[],'combined':[(a,b)],'individual_connections':individual},(b-a)//1000


def main()->int:
    started=time.perf_counter();ap=argparse.ArgumentParser();ap.add_argument('--role',choices=('server','client'),required=True);ap.add_argument('--run-dir',type=Path,required=True);ap.add_argument('--payload-bytes',type=int,required=True);ap.add_argument('--downloads',type=int,required=True);ap.add_argument('--output',type=Path,required=True);a=ap.parse_args()
    run=a.run_dir;text=(run/f'{a.role}.log').read_text(errors='replace');windows,batch_us=parallel_windows(a.role,text,a.downloads)
    windows.update(base.control_windows(run/'control_timeline.jsonl'))
    rapl=base.read_rapl(run/'rapl.csv');freq=base.read_jsonl(run/'frequency.jsonl');names=base.load_cstate_names(run/'cstate_mapping.json');bridges=base.build_bridge_model(freq)
    cstate=base.cstate_metrics_all(run/'cstate.csv',bridges,names,windows)
    scopes={}
    for scope,ws in windows.items():
        if scope=='individual_connections':continue
        scopes[scope]={'window_count':len(ws),'duration_s':base.union_duration_ns(ws)/1e9,'rapl':base.rapl_metrics(rapl,ws),'frequency':base.frequency_metrics(freq,ws),'cstate':cstate.get(scope,{})}
    useful=a.payload_bytes*a.downloads;data={'schema':'greenquic-p7-linux-parallel-run-v1','role':a.role,'payload_bytes_per_connection':a.payload_bytes,'connections':a.downloads,'useful_bytes':useful,'windows':{k:[[x,y] for x,y in v] for k,v in windows.items()},'scopes':scopes,'parallel_batch_duration_us':batch_us}
    if a.role=='client':
        gp=useful*8.0/batch_us/1000.0
        data['workload_elapsed_us']=batch_us;data['goodput_active_downloads_gbps']=gp;data['goodput_workload_including_gaps_gbps']=gp;data['goodput_gbps']=gp;data['gap_inclusive_goodput_gbps']=gp
        useful_gbit=useful*8.0/1e9
        for scope in ('active','combined'):
            total_j=(scopes.get(scope,{}).get('rapl')or{}).get('total_j')
            if total_j is not None and useful_gbit>0:scopes[scope]['j_per_useful_gbit']=total_j/useful_gbit
    a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(data,indent=2)+'\n')
    print(f'P7 parallel {a.role} summary: connections={a.downloads} active_s={batch_us/1e6:.6f}'+(f' goodput={data["goodput_gbps"]:.6f} Gbit/s' if a.role=='client' else ''))
    print(f'analysis_time={time.perf_counter()-started:.3f}s')
    return 0
if __name__=='__main__':raise SystemExit(main())
