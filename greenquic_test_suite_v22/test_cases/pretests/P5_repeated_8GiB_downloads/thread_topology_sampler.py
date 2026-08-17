#!/usr/bin/env python3
from __future__ import annotations
import argparse,csv,json,os,signal,time
from pathlib import Path

STOP=False

def sig(*_):
    global STOP; STOP=True

def proc_exe(pid:int)->str:
    try:return os.path.realpath(f'/proc/{pid}/exe')
    except OSError:return ''

def parse_stat(path:Path):
    s=path.read_text(errors='replace')
    r=s.rfind(')')
    if r<0:return None
    comm=s[s.find('(')+1:r]
    f=s[r+2:].split()
    # fields after comm start at stat field 3
    if len(f)<37:return None
    return comm,int(f[11]),int(f[12]),int(f[36]) # utime(14), stime(15), processor(39)

def allowed_list(path:Path)->str:
    try:
        for line in path.read_text(errors='replace').splitlines():
            if line.startswith('Cpus_allowed_list:'):
                return line.split(':',1)[1].strip()
    except OSError:pass
    return ''

def find_pids(binary:str):
    want=os.path.realpath(binary)
    out=[]
    for p in Path('/proc').iterdir():
        if p.name.isdigit() and proc_exe(int(p.name))==want: out.append(int(p.name))
    return out

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--binary',required=True)
    ap.add_argument('--json',required=True)
    ap.add_argument('--csv',required=True)
    ap.add_argument('--interval-ms',type=int,default=20)
    a=ap.parse_args()
    signal.signal(signal.SIGTERM,sig); signal.signal(signal.SIGINT,sig)
    clk=os.sysconf(os.sysconf_names['SC_CLK_TCK'])
    state={}
    while not STOP:
        now=time.monotonic_ns()
        for pid in find_pids(a.binary):
            tdir=Path(f'/proc/{pid}/task')
            try:tids=list(tdir.iterdir())
            except OSError:continue
            for td in tids:
                if not td.name.isdigit(): continue
                tid=int(td.name)
                try: st=parse_stat(td/'stat')
                except OSError: continue
                if not st:continue
                comm,u,s,cpu=st; ticks=u+s
                key=(pid,tid)
                row=state.setdefault(key,{'pid':pid,'tid':tid,'comm':comm,'allowed':allowed_list(td/'status'),'first_ns':now,'last_ns':now,'first_ticks':ticks,'last_ticks':ticks,'samples':0,'cpus':set()})
                row['last_ns']=now; row['last_ticks']=ticks; row['samples']+=1; row['cpus'].add(cpu)
        time.sleep(max(1,a.interval_ms)/1000)
    rows=[]
    for r in state.values():
        d=dict(r); d['cpus_seen']=','.join(map(str,sorted(d.pop('cpus')))); d['cpu_time_s']=max(0,d['last_ticks']-d['first_ticks'])/clk
        d['wall_s']=max(0,d['last_ns']-d['first_ns'])/1e9
        d['cpu_util_one_core_pct']=100*d['cpu_time_s']/d['wall_s'] if d['wall_s']>0 else 0.0
        rows.append(d)
    rows.sort(key=lambda x:x['cpu_time_s'],reverse=True)
    Path(a.csv).parent.mkdir(parents=True,exist_ok=True)
    fields=['pid','tid','comm','allowed','cpus_seen','samples','cpu_time_s','wall_s','cpu_util_one_core_pct']
    with open(a.csv,'w',newline='',encoding='utf-8') as f:
        w=csv.DictWriter(f,fieldnames=fields); w.writeheader(); w.writerows({k:r.get(k,'') for k in fields} for r in rows)
    js={'schema':'greenquic-thread-topology-v1','binary':os.path.realpath(a.binary),'threads':rows,'total_cpu_time_s':sum(r['cpu_time_s'] for r in rows),'active_threads':sum(r['cpu_time_s']>0.01 for r in rows)}
    Path(a.json).write_text(json.dumps(js,indent=2)+'\n')
    print(f"THREAD_TOPOLOGY active_threads={js['active_threads']} total_cpu_time_s={js['total_cpu_time_s']:.3f}")
if __name__=='__main__':main()
