#!/usr/bin/env python3
from __future__ import annotations

import argparse,csv,json,re,statistics
from pathlib import Path

GOODPUT_RE=re.compile(r'TOTAL_goodput=([0-9.]+)\s+Gbit/s')

def read_env(path:Path)->dict[str,str]:
    out={}
    if not path.is_file(): return out
    for raw in path.read_text(encoding='utf-8',errors='replace').splitlines():
        if '=' in raw and not raw.lstrip().startswith('#'):
            k,v=raw.split('=',1);out[k.strip()]=v.strip()
    return out

def fallback_goodput(case:Path)->tuple[float|None,float|None,int]:
    vals=[]
    for p in sorted(case.glob('client_rep*_off*.log')):
        m=GOODPUT_RE.findall(p.read_text(encoding='utf-8',errors='replace'))
        if m: vals.append(float(m[-1]))
    if not vals:
        for p in sorted(case.rglob('client_rep*_off*.log')):
            m=GOODPUT_RE.findall(p.read_text(encoding='utf-8',errors='replace'))
            if m: vals.append(float(m[-1]))
    if not vals: return None,None,0
    return statistics.mean(vals),statistics.stdev(vals) if len(vals)>1 else 0.0,len(vals)

def active_cpus(path:Path)->tuple[str,float]:
    if not path.is_file(): return '',0.0
    try:j=json.loads(path.read_text(encoding='utf-8'))
    except Exception:return '',0.0
    rows=j.get('rows',[])
    active=[str(r.get('cpu')) for r in rows if float(r.get('cpu_time_s',0) or 0)>0]
    total=sum(float(r.get('cpu_time_s',0) or 0) for r in rows)
    return ';'.join(active),total

def main()->int:
    ap=argparse.ArgumentParser();ap.add_argument('--root',type=Path,required=True);a=ap.parse_args();root=a.root.resolve()
    status=root/'CASE_STATUS.tsv'
    rows=[]
    if status.is_file():
        with status.open(newline='',encoding='utf-8') as f: source=list(csv.DictReader(f,delimiter='\t'))
    else:
        source=[{'case':p.name} for p in sorted(root.iterdir()) if p.is_dir() and (p/'ARCH_CASE_STATUS.env').is_file()]
    for s in source:
        name=s.get('case','');case=root/name;env=read_env(case/'ARCH_CASE_STATUS.env')
        summ=case/'bottleneck_tables'/'case_summary.json'; mean=sd=None;n=0;engaged=''
        if summ.is_file():
            try:
                j=json.loads(summ.read_text(encoding='utf-8'));mean=float(j.get('aggregate_goodput_gbps_mean'));sd=float(j.get('aggregate_goodput_gbps_stdev',0));n=int(j.get('runs',0));engaged=str(int(bool(j.get('all_configured_dpdk_lcores_engaged'))))
            except Exception: mean=sd=None
        if mean is None: mean,sd,n=fallback_goodput(case)
        sa,st=active_cpus(case/'quic_runtime_allcpus_server.json');ca,ct=active_cpus(case/'quic_runtime_allcpus_client.json')
        row={**s,**env,'case':name,'goodput_mean_gbps':'' if mean is None else mean,'goodput_sd_gbps':'' if sd is None else sd,'goodput_n':n,'dpdk_all_engaged':engaged,'server_quic_active_cpus':sa,'client_quic_active_cpus':ca,'server_quic_cpu_time_s':st,'client_quic_cpu_time_s':ct}
        rows.append(row)
    ref=next((r for r in rows if r['case']=='A1_2d4q_aff'),None)
    refv=float(ref['goodput_mean_gbps']) if ref and ref.get('goodput_mean_gbps') not in ('',None) else None
    for r in rows:
        v=r.get('goodput_mean_gbps');r['delta_vs_A1_pct']=''
        if refv and v not in ('',None):r['delta_vs_A1_pct']=100*(float(v)-refv)/refv
    fields=[]
    preferred=['case','group','dpdk_lcores','quic_cpus','quic_affinitize','execution_profile','partition_map','build_profile','build_rc','case_rc','traffic_rc','controller_rc','analysis_rc','goodput_n','goodput_mean_gbps','goodput_sd_gbps','delta_vs_A1_pct','dpdk_all_engaged','server_quic_active_cpus','client_quic_active_cpus','server_quic_cpu_time_s','client_quic_cpu_time_s']
    for k in preferred:
        if any(k in r for r in rows):fields.append(k)
    for r in rows:
        for k in r:
            if k not in fields:fields.append(k)
    outcsv=root/'ARCH_SWEEP_SUMMARY.csv'
    with outcsv.open('w',newline='',encoding='utf-8') as f:w=csv.DictWriter(f,fieldnames=fields);w.writeheader();w.writerows(rows)
    lines=['P5 ARCHITECTURAL BOTTLENECK SWEEP V4','===================================','Reference: A1_2d4q_aff (2 DPDK lcores, 4 QUIC CPUs, AFFINITIZE=1, max_throughput).','Traffic PASS is independent of controller/plot/analyzer RC.','']
    for r in rows:
        gp=r.get('goodput_mean_gbps');sd=r.get('goodput_sd_gbps');d=r.get('delta_vs_A1_pct')
        gps='N/A' if gp in ('',None) else f'{float(gp):.6f}';sds='N/A' if sd in ('',None) else f'{float(sd):.6f}';ds='N/A' if d in ('',None) else f'{float(d):+.2f}%'
        lines.append(f"{r['case']}: traffic_rc={r.get('traffic_rc','?')} controller_rc={r.get('controller_rc','?')} analysis_rc={r.get('analysis_rc','?')} goodput={gps} Gbit/s SD={sds} delta={ds}")
        lines.append(f"  server QUIC active CPUs={r.get('server_quic_active_cpus','') or '-'}; client={r.get('client_quic_active_cpus','') or '-'}; DPDK engaged={r.get('dpdk_all_engaged','') or '?'}")
    (root/'ARCH_SWEEP_SUMMARY.txt').write_text('\n'.join(lines)+'\n',encoding='utf-8')
    print('\n'.join(lines));return 0
if __name__=='__main__':raise SystemExit(main())
