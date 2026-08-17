#!/usr/bin/env python3
from __future__ import annotations
import argparse,csv,json,re,statistics
from pathlib import Path
GOOD_RE=re.compile(r'TOTAL_goodput=([0-9.]+) Gbit/s')

def envread(p:Path):
    out={}
    if p.is_file():
        for line in p.read_text(errors='replace').splitlines():
            if '=' in line and not line.lstrip().startswith('#'):
                k,v=line.split('=',1); out[k.strip()]=v.strip()
    return out

def raw_goodput(case:Path):
    vals=[]
    for p in sorted(case.glob('client_rep*_off.log')):
        ms=list(GOOD_RE.finditer(p.read_text(errors='replace')))
        if ms: vals.append(float(ms[-1].group(1)))
    return vals

def thread_summary(case:Path, role:str):
    p=case/f'thread_topology_{role}.json'
    if not p.is_file(): return 0,0.0,'',''
    try: j=json.loads(p.read_text())
    except Exception: return 0,0.0,'',''
    ts=sorted(j.get('threads',[]),key=lambda x:float(x.get('cpu_time_s',0.0)),reverse=True)
    active=int(j.get('active_threads',sum(float(x.get('cpu_time_s',0.0))>0.01 for x in ts)))
    if not ts: return active,float(j.get('total_cpu_time_s',0.0)),'',''
    top=ts[0]
    return active,float(j.get('total_cpu_time_s',0.0)),str(top.get('cpus_seen','')),str(top.get('allowed',''))

def rc0(value): return str(value).strip() == '0'

def find_case(rows,prefix): return next((r for r in rows if r['case'].startswith(prefix)),None)

def delta(a,b):
    if not a or not b or not a['valid_case'] or not b['valid_case'] or b['mean_gbps']<=0: return None
    return 100.0*(a['mean_gbps']/b['mean_gbps']-1.0)

def fmt_delta(v): return 'N/A' if v is None else f'{v:+.2f}%'

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--root',type=Path,required=True); a=ap.parse_args(); root=a.root.resolve()
    st={}; sp=root/'CASE_STATUS.tsv'
    if sp.is_file():
        with sp.open(newline='',encoding='utf-8') as f:
            for r in csv.DictReader(f,delimiter='\t'): st[r['case']]=r
    rows=[]
    for case in sorted(p for p in root.iterdir() if p.is_dir() and re.match(r'^[A-P]_',p.name)):
        cfg=envread(case/'ARCH_CASE_STATUS.env'); raw=raw_goodput(case)
        mean=statistics.mean(raw) if raw else 0.0; sd=statistics.stdev(raw) if len(raw)>1 else 0.0
        js=case/'bottleneck_tables/case_summary.json'
        if not raw and js.is_file():
            try:
                j=json.loads(js.read_text()); mean=float(j.get('aggregate_goodput_gbps_mean',0)); sd=float(j.get('aggregate_goodput_gbps_stdev',0)); n=int(j.get('runs',0))
            except Exception: n=0
        else: n=len(raw)
        sr=st.get(case.name,{})
        build_rc=sr.get('build_rc','')
        traffic_rc=cfg.get('traffic_rc',sr.get('traffic_rc',''))
        controller_rc=cfg.get('controller_rc',sr.get('controller_rc',''))
        analysis_rc=cfg.get('analysis_rc',sr.get('analysis_rc',''))
        config_rc=sr.get('effective_config_rc',cfg.get('config_rc',''))
        effective_json=case/'ARCH_EFFECTIVE_CONFIG.json'
        effective_status=''
        if effective_json.is_file():
            try: effective_status=str(json.loads(effective_json.read_text()).get('status',''))
            except Exception: effective_status='INVALID_JSON'
        valid_case=int(rc0(build_rc) and rc0(traffic_rc) and rc0(config_rc) and mean>0)
        sa,stotal,stopcpu,stopallow=thread_summary(case,'server'); ca,ctotal,ctopcpu,ctopallow=thread_summary(case,'client')
        rows.append({'case':case.name,'valid_case':valid_case,'n':n,'mean_gbps':mean,'sd_gbps':sd,'max_gbps':max(raw) if raw else mean,'reached_11g':int(valid_case and (max(raw) if raw else mean)>=11.0),'dpdk_lcores':cfg.get('dpdk_lcores',''),'quic_cpus':cfg.get('quic_cpus',''),'affinitize':cfg.get('quic_affinitize',''),'execution_profile':cfg.get('execution_profile',''),'partition_style':cfg.get('partition_style',''),'partition_map':cfg.get('partition_map',''),'build_profile':sr.get('build_profile',sr.get('profile','')),'build_rc':build_rc,'traffic_rc':traffic_rc,'effective_config_rc':config_rc,'effective_config_status':effective_status,'controller_rc':controller_rc,'analysis_rc':analysis_rc,'traffic_success_logs':cfg.get('traffic_success_logs',''),'goodput_files':cfg.get('goodput_files',''),'server_active_threads':sa,'client_active_threads':ca,'server_thread_cpu_s':stotal,'client_thread_cpu_s':ctotal,'server_top_thread_cpus':stopcpu,'client_top_thread_cpus':ctopcpu,'server_top_thread_allowed':stopallow,'client_top_thread_allowed':ctopallow})
    ref=find_case(rows,'B_')
    for r in rows:
        r['delta_vs_B_pct']=''
        d=delta(r,ref)
        if d is not None: r['delta_vs_B_pct']=d
    csvp=root/'ARCH_BOTTLENECK_SUMMARY.csv'
    if rows:
        with csvp.open('w',newline='',encoding='utf-8') as f: w=csv.DictWriter(f,fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
    lines=['P5 ARCHITECTURAL BOTTLENECK SWEEP','=================================','Target: find a structural change capable of moving P5 toward >=11 Gbit/s.','VALID requires build_rc=0, traffic_rc=0, effective_config_rc=0 and measured goodput. Controller/plot/analyzer failures do not erase completed traffic.','']
    for r in rows:
        d='' if r['delta_vs_B_pct']=='' else f" delta_vs_B={r['delta_vs_B_pct']:+.2f}%"
        lines.append(f"{r['case']}: VALID={r['valid_case']} n={r['n']} mean={r['mean_gbps']:.6f} SD={r['sd_gbps']:.6f} max={r['max_gbps']:.6f} Gbit/s{d} build_rc={r['build_rc']} traffic_rc={r['traffic_rc']} effective_config_rc={r['effective_config_rc']} effective={r['effective_config_status']} controller_rc={r['controller_rc']} analysis_rc={r['analysis_rc']}")
    ranked=sorted((r for r in rows if r['valid_case']),key=lambda x:x['mean_gbps'],reverse=True)
    lines+=['','VALID CASE RANKING']+[f"{i:02d}. {r['case']} {r['mean_gbps']:.6f} Gbit/s" for i,r in enumerate(ranked,1)]
    invalid=[r for r in rows if not r['valid_case']]
    if invalid:
        lines+=['','INVALID / NON-COMPARABLE CASES']+[f"- {r['case']} build={r['build_rc']} traffic={r['traffic_rc']} effective_config={r['effective_config_rc']} controller={r['controller_rc']} analysis={r['analysis_rc']}" for r in invalid]

    A=find_case(rows,'A_'); C=find_case(rows,'C_'); D=find_case(rows,'D_'); E=find_case(rows,'E_'); F=find_case(rows,'F_'); G=find_case(rows,'G_'); H=find_case(rows,'H_'); I=find_case(rows,'I_'); J=find_case(rows,'J_'); K=find_case(rows,'K_'); L=find_case(rows,'L_'); M=find_case(rows,'M_'); N=find_case(rows,'N_'); O=find_case(rows,'O_'); P=find_case(rows,'P_')
    comparisons=[
        ('AFFINITIZE B vs A',delta(ref,A),'MsQuic worker affinity'),
        ('QUIC workers C(1Q) vs B(4Q)',delta(C,ref),'QUIC worker serialization/scaling'),
        ('QUIC workers D(2Q) vs B(4Q)',delta(D,ref),'QUIC worker serialization/scaling'),
        ('QUIC workers E(8Q) vs B(4Q)',delta(E,ref),'QUIC execution-capacity ceiling'),
        ('DPDK F(1D) vs B(2D)',delta(F,ref),'DPDK consumer scaling'),
        ('DPDK G(4D) vs B(2D)',delta(G,ref),'DPDK consumer scaling'),
        ('combined H(4D8Q) vs B',delta(H,ref),'combined QUIC+DPDK scaling'),
        ('low-latency I vs B',delta(I,ref),'MsQuic scheduling profile'),
        ('partition all-first J vs B',delta(J,ref),'partition-to-DPDK serialization'),
        ('partition grouped K vs B',delta(K,ref),'partition-to-DPDK locality'),
        ('ring MP L vs B',delta(L,ref),'producer-ring synchronization'),
        ('ring RTS M vs B',delta(M,ref),'producer-ring synchronization'),
        ('sharded handoff N vs B',delta(N,ref),'shared producer handoff contention'),
        ('UDP segmentation O vs B',delta(O,ref),'per-packet/segmentation overhead'),
        ('drift P vs B',delta(P,ref),'thermal/time drift'),
    ]
    lines+=['','ARCHITECTURAL COMPARISONS']+[f"- {name}: {fmt_delta(v)} [{layer}]" for name,v,layer in comparisons]
    signals=[(abs(v),v,name,layer) for name,v,layer in comparisons if v is not None and 'drift' not in name.lower() and abs(v)>=10.0]
    signals.sort(reverse=True)
    lines+=['','ARCHITECTURAL SIGNALS (|change| >= 10%)']
    if signals:
        lines += [f"- {name}: {v:+.2f}% -> investigate {layer}" for _,v,name,layer in signals]
    else:
        lines += ['- none of the valid controlled perturbations moved goodput by >=10%; the major ceiling is likely outside the tested worker/queue/handoff controls and should be localized with cycle-level profiling/raw-DPDK ceiling testing.']

    if ranked: lines+=['',f"BEST_VALID={ranked[0]['case']} {ranked[0]['mean_gbps']:.6f} Gbit/s",f"REACHED_11G={'YES' if ranked[0]['max_gbps']>=11 else 'NO'}"]
    else: lines+=['','BEST_VALID=NONE','REACHED_11G=NO']
    txt=root/'ARCH_BOTTLENECK_SUMMARY.txt'; txt.write_text('\n'.join(lines)+'\n'); print(txt.read_text(),end=''); return 0
if __name__=='__main__': raise SystemExit(main())
