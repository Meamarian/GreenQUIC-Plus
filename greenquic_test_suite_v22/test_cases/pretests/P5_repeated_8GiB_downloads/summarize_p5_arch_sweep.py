#!/usr/bin/env python3
from __future__ import annotations
import argparse,csv,json,re,statistics
from pathlib import Path
GOOD_RE=re.compile(r'TOTAL_goodput=([0-9.]+) Gbit/s')
LCORE_RE=re.compile(r'\[GreenQUIC-MC\] LCORE_STATS[^\n]*lcore=(\d+)[^\n]*rx_pkts=(\d+)[^\n]*tx_pkts=(\d+)[^\n]*total_pkts=(\d+)')
USO_ACTIVE_RE=re.compile(r'\[P5-PERF2-USO\][^\n]*requested=1 active=1\b')
SHARD_RE=re.compile(r'\[P5-PERF2\] registered TX producer: tid=(\d+) slot=(\d+)')
AFF_UNSUPPORTED='GreenQuicQuicAffinitize requested, but QUIC_API_ENABLE_PREVIEW_FEATURES is not enabled'

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

def log_files(case:Path, role:str):
    return sorted(case.glob(f'{role}_rep*_off.log'))

def text_of(paths):
    return '\n'.join(p.read_text(errors='replace') for p in paths if p.is_file())

def dpdk_engagement(case:Path, expected:list[int]):
    files=log_files(case,'server')+log_files(case,'client')
    if not files: return None
    roles={}
    for p in files:
        role='server' if p.name.startswith('server_') else 'client'
        roles.setdefault(role,0); roles[role]+=1
        matches=list(LCORE_RE.finditer(p.read_text(errors='replace')))
        if not matches: return None
        latest={int(m.group(1)):int(m.group(4)) for m in matches}
        if any(latest.get(cpu,0)<=0 for cpu in expected): return False
    if not roles.get('server') or not roles.get('client'): return None
    return True

def feature_evidence(case:Path):
    sfiles=log_files(case,'server'); cfiles=log_files(case,'client')
    st=text_of(sfiles); ct=text_of(cfiles); both=st+'\n'+ct
    aff_supported=AFF_UNSUPPORTED not in both
    uso_server=bool(sfiles) and bool(USO_ACTIVE_RE.search(st))
    uso_client=bool(cfiles) and bool(USO_ACTIVE_RE.search(ct))
    producer_counts=[]
    for p in sfiles:
        producers={(m.group(1),m.group(2)) for m in SHARD_RE.finditer(p.read_text(errors='replace'))}
        producer_counts.append(len(producers))
    shard_server_min=min(producer_counts) if producer_counts else 0
    return aff_supported,uso_server,uso_client,shard_server_min

def rc0(value): return str(value).strip() == '0'

def find_case(rows,prefix): return next((r for r in rows if r['case'].startswith(prefix)),None)

def delta(a,b,extra=True):
    if not extra or not a or not b or not a['scientific_valid'] or not b['scientific_valid'] or b['mean_gbps']<=0: return None
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
        transport_valid=int(rc0(build_rc) and rc0(traffic_rc) and rc0(config_rc) and mean>0)
        expected_dpdk=[int(x) for x in cfg.get('dpdk_lcores','').split(',') if x.strip().isdigit()]
        engaged=dpdk_engagement(case,expected_dpdk) if expected_dpdk else None
        aff_supported,uso_server,uso_client,shard_server_min=feature_evidence(case)
        feature_ok=True
        if case.name.startswith('N_'): feature_ok=shard_server_min>=2
        if case.name.startswith('O_'): feature_ok=uso_server and uso_client
        scientific_valid=int(transport_valid and engaged is True and feature_ok)
        sa,stotal,stopcpu,stopallow=thread_summary(case,'server'); ca,ctotal,ctopcpu,ctopallow=thread_summary(case,'client')
        rows.append({'case':case.name,'transport_valid':transport_valid,'scientific_valid':scientific_valid,'n':n,'mean_gbps':mean,'sd_gbps':sd,'max_gbps':max(raw) if raw else mean,'reached_11g':int(scientific_valid and (max(raw) if raw else mean)>=11.0),'dpdk_lcores':cfg.get('dpdk_lcores',''),'dpdk_all_lcores_engaged':'' if engaged is None else int(engaged),'quic_cpus':cfg.get('quic_cpus',''),'affinitize':cfg.get('quic_affinitize',''),'affinitize_runtime_supported':int(aff_supported),'execution_profile':cfg.get('execution_profile',''),'partition_style':cfg.get('partition_style',''),'partition_map':cfg.get('partition_map',''),'uso_active_server':int(uso_server),'uso_active_client':int(uso_client),'sharded_server_min_producers':shard_server_min,'build_profile':sr.get('build_profile',sr.get('profile','')),'build_rc':build_rc,'traffic_rc':traffic_rc,'effective_config_rc':config_rc,'effective_config_status':effective_status,'controller_rc':controller_rc,'analysis_rc':analysis_rc,'traffic_success_logs':cfg.get('traffic_success_logs',''),'goodput_files':cfg.get('goodput_files',''),'server_active_threads':sa,'client_active_threads':ca,'server_thread_cpu_s':stotal,'client_thread_cpu_s':ctotal,'server_top_thread_cpus':stopcpu,'client_top_thread_cpus':ctopcpu,'server_top_thread_allowed':stopallow,'client_top_thread_allowed':ctopallow})
    ref=find_case(rows,'B_')
    for r in rows:
        r['delta_vs_B_pct']=''
        d=delta(r,ref)
        if d is not None: r['delta_vs_B_pct']=d
    csvp=root/'ARCH_BOTTLENECK_SUMMARY.csv'
    if rows:
        with csvp.open('w',newline='',encoding='utf-8') as f: w=csv.DictWriter(f,fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)
    lines=['P5 ARCHITECTURAL BOTTLENECK SWEEP','=================================','Target: find a structural change capable of moving P5 toward >=11 Gbit/s.','TRANSPORT VALID requires build/traffic/effective-config PASS. SCIENTIFIC VALID additionally requires direct per-lcore packet engagement and case-specific feature activation. Controller/plot/analyzer failures do not erase completed traffic.','']
    for r in rows:
        d='' if r['delta_vs_B_pct']=='' else f" delta_vs_B={r['delta_vs_B_pct']:+.2f}%"
        lines.append(f"{r['case']}: TRANSPORT={r['transport_valid']} SCI={r['scientific_valid']} n={r['n']} mean={r['mean_gbps']:.6f} SD={r['sd_gbps']:.6f} max={r['max_gbps']:.6f} Gbit/s{d} dpdk_engaged={r['dpdk_all_lcores_engaged']} build={r['build_rc']} traffic={r['traffic_rc']} config={r['effective_config_rc']} controller={r['controller_rc']} analysis={r['analysis_rc']}")
    ranked=sorted((r for r in rows if r['scientific_valid']),key=lambda x:x['mean_gbps'],reverse=True)
    lines+=['','SCIENTIFICALLY VALID CASE RANKING']+[f"{i:02d}. {r['case']} {r['mean_gbps']:.6f} Gbit/s" for i,r in enumerate(ranked,1)]
    invalid=[r for r in rows if not r['scientific_valid']]
    if invalid:
        lines+=['','NON-COMPARABLE / INCOMPLETE EVIDENCE']
        for r in invalid:
            reason=[]
            if not r['transport_valid']: reason.append('transport/config')
            if r['dpdk_all_lcores_engaged'] != 1: reason.append('DPDK engagement unproven')
            if r['case'].startswith('N_') and r['sharded_server_min_producers']<2: reason.append('sharded path has <2 server producers')
            if r['case'].startswith('O_') and not (r['uso_active_server'] and r['uso_active_client']): reason.append('UDP segmentation inactive on an endpoint')
            lines.append(f"- {r['case']}: {', '.join(reason) or 'unknown'}")

    A=find_case(rows,'A_'); C=find_case(rows,'C_'); D=find_case(rows,'D_'); E=find_case(rows,'E_'); F=find_case(rows,'F_'); G=find_case(rows,'G_'); H=find_case(rows,'H_'); I=find_case(rows,'I_'); J=find_case(rows,'J_'); K=find_case(rows,'K_'); L=find_case(rows,'L_'); M=find_case(rows,'M_'); N=find_case(rows,'N_'); O=find_case(rows,'O_'); P=find_case(rows,'P_')
    affinity_supported=bool(ref and ref.get('affinitize_runtime_supported')==1)
    uso_active=bool(O and O.get('uso_active_server')==1 and O.get('uso_active_client')==1)
    sharded_active=bool(N and N.get('sharded_server_min_producers',0)>=2)
    comparisons=[
        ('AFFINITIZE B vs A',delta(ref,A,affinity_supported),'MsQuic worker hard affinity'),
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
        ('sharded handoff N vs F',delta(N,F,sharded_active),'shared producer handoff contention under safe single consumer'),
        ('UDP segmentation O vs B',delta(O,ref,uso_active),'per-packet/segmentation overhead'),
        ('drift P vs B',delta(P,ref),'thermal/time drift'),
    ]
    lines+=['','RUNTIME FEATURE EVIDENCE']
    lines.append(f"- AFFINITIZE runtime support: {'YES' if affinity_supported else 'NO/UNPROVEN'}")
    lines.append(f"- N sharded minimum server producers per repetition: {N.get('sharded_server_min_producers',0) if N else 0}")
    lines.append(f"- O UDP segmentation active server/client: {O.get('uso_active_server',0) if O else 0}/{O.get('uso_active_client',0) if O else 0}")
    lines+=['','ARCHITECTURAL COMPARISONS']+[f"- {name}: {fmt_delta(v)} [{layer}]" for name,v,layer in comparisons]
    signals=[(abs(v),v,name,layer) for name,v,layer in comparisons if v is not None and 'drift' not in name.lower() and abs(v)>=10.0]
    signals.sort(reverse=True)
    lines+=['','ARCHITECTURAL SIGNALS (|change| >= 10%)']
    if signals:
        lines += [f"- {name}: {v:+.2f}% -> investigate {layer}" for _,v,name,layer in signals]
    else:
        lines += ['- none of the scientifically valid controlled perturbations moved goodput by >=10%; inspect thread topology and perf-stat evidence, then run a dedicated raw-DPDK ceiling/function-profile follow-up rather than more small parameter tuning.']

    if ranked: lines+=['',f"BEST_VALID={ranked[0]['case']} {ranked[0]['mean_gbps']:.6f} Gbit/s",f"REACHED_11G={'YES' if ranked[0]['max_gbps']>=11 else 'NO'}"]
    else: lines+=['','BEST_VALID=NONE','REACHED_11G=NO']
    txt=root/'ARCH_BOTTLENECK_SUMMARY.txt'; txt.write_text('\n'.join(lines)+'\n'); print(txt.read_text(),end=''); return 0
if __name__=='__main__': raise SystemExit(main())
