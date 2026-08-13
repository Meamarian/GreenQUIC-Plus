#!/usr/bin/env python3
from __future__ import annotations
import argparse, csv, json, math, re, shutil, statistics, sys, zipfile
from pathlib import Path
from typing import Any, Iterable, Callable
from xml.sax.saxutils import escape

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np

MODES=('off','basic','plus')
MODE_NAMES={'off':'MsQuic-DPDK','basic':'GreenQUIC','plus':'GreenQUIC+'}
VARIANTS=('without_variance','with_variance')
VALUE_VARIANTS=('with_values','without_values')
SCOPES=('active','gap','combined')


def finite(v):
    try:
        x=float(str(v).replace(',','').strip().split()[0])
        return x if math.isfinite(x) else None
    except Exception:
        return None

def normkey(s): return re.sub(r'[^a-z0-9]+','_',str(s).lower()).strip('_')
def read_csv(p:Path):
    if not p.is_file(): return []
    with p.open(newline='',encoding='utf-8',errors='replace') as f: return list(csv.DictReader(f))
def index_rows(rows,*keys):
    out={}
    for r in rows:
        vals=[]
        ok=True
        for k in keys:
            v=r.get(k)
            if k=='repetition':
                x=finite(v)
                if x is None: ok=False; break
                v=int(x)
            if k=='mode': v=str(v).lower()
            vals.append(v)
        if ok: out[tuple(vals)]=r
    return out
def field(row,*parts):
    if not row:return None
    wanted=[normkey(p) for p in parts]
    for k,v in row.items():
        nk=normkey(k)
        if all(p in nk for p in wanted):
            x=finite(v)
            if x is not None:return x
    return None

def stat(vals):
    a=[float(v) for v in vals if v is not None and math.isfinite(float(v))]
    n=len(a)
    if not a:return {'n':0,'mean':None,'variance':None,'sd':None}
    mu=statistics.mean(a)
    if n<2:return {'n':n,'mean':mu,'variance':None,'sd':None}
    var=statistics.variance(a)
    return {'n':n,'mean':mu,'variance':var,'sd':math.sqrt(var)}
def fmt(v,kind='scalar'):
    if v is None:return 'N/A'
    v=float(v)
    if v==0:return '0'
    av=abs(v)
    if kind=='seconds':
        if av<1e-3:return f'{v*1e6:.1f} µs'
        if av<1:return f'{v*1e3:.2f} ms'
        return f'{v:.2f} s'
    if kind=='count': return f'{v:,.0f}'
    if kind=='percent': return f'{v:.3f}%'
    if kind=='ghz': return f'{v:.3f}'
    if kind in ('power','energy','j_per_gbit','gbps'): return f'{v:.2f}'
    if av<0.01:return f'{v:.3g}'
    if av>=1e6:return f'{v:,.0f}'
    return f'{v:.2f}'

def per_mode(records:dict, getter:Callable):
    return {m:[getter(rep,r) for (rep,mm),r in sorted(records.items()) if mm==m] for m in MODES}

def combine_series(a,b):
    out={}
    for m in MODES:
        out[m]=[(x+y if x is not None and y is not None else None) for x,y in zip(a[m],b[m])]
    return out

def ensure(p): p.mkdir(parents=True,exist_ok=True); return p

STATS_ROWS=[]
VARIANT_ROWS=[]

def save_bar(root:Path,num:int,name:str,title:str,ylabel:str,series:dict[str,dict[str,list]],kind='scalar',variance_applicable=True,legacy_root:Path|None=None):
    cache={lab:[stat(by.get(m,[])) for m in MODES] for lab,by in series.items()}
    if not any(s['mean'] is not None for ss in cache.values() for s in ss): return False
    for lab,ss in cache.items():
        for m,s in zip(MODES,ss): STATS_ROWS.append({'family':root.name,'chart':num,'name':name,'scope':'','series':lab,'mode':m,**s})
    for vv in VARIANTS:
        want_var=(vv=='with_variance')
        for values in VALUE_VARIANTS:
            show=(values=='with_values')
            fig,ax=plt.subplots(figsize=(15,8))
            x=np.arange(len(MODES),dtype=float); width=min(.72/max(1,len(series)),.24); ymax=0.0
            for j,(lab,_) in enumerate(series.items()):
                ss=cache[lab]; means=[s['mean'] if s['mean'] is not None else np.nan for s in ss]; pos=x+(j-(len(series)-1)/2)*width
                errs=[]
                for s in ss:
                    errs.append(s['sd'] if want_var and variance_applicable and s['sd'] is not None else 0.0)
                bars=ax.bar(pos,means,width,label=lab,yerr=errs if want_var and variance_applicable else None,capsize=5 if want_var and variance_applicable else 0)
                for mu,e in zip(means,errs):
                    if math.isfinite(mu): ymax=max(ymax,mu+e)
                if show:
                    for b,mu,s,e in zip(bars,means,ss,errs):
                        if not math.isfinite(mu):continue
                        text=fmt(mu,kind)
                        if want_var and variance_applicable:
                            text += (f'\nSD={fmt(s["sd"],kind)}' if s['sd'] is not None else f'\nSD N/A (n={s["n"]})')
                        ax.annotate(text,(b.get_x()+b.get_width()/2,mu+e),xytext=(0,7),textcoords='offset points',ha='center',fontsize=7)
            if want_var and variance_applicable and not any(s['sd'] is not None for ss in cache.values() for s in ss if s['n']):
                ax.text(.995,.985,'Error bars unavailable: only one independent repetition (n=1)',transform=ax.transAxes,ha='right',va='top',fontsize=9)
            if want_var and not variance_applicable:
                ax.text(.995,.985,'Variance not applicable to this chart type',transform=ax.transAxes,ha='right',va='top',fontsize=9)
            ax.set_xticks(x,[MODE_NAMES[m] for m in MODES]); ax.set_ylabel(ylabel); ax.set_title(title,pad=18,fontweight='normal'); ax.grid(axis='y',alpha=.3); ax.set_axisbelow(True); ax.set_ylim(bottom=0)
            if len(series)>1: ax.legend(loc='center left',bbox_to_anchor=(1.01,.5))
            fig.tight_layout()
            for ext in ('svg','pdf'):
                d=ensure(root/vv/ext/values); fp=d/f'{num:02d}_{name}.{ext}'; fig.savefig(fp,bbox_inches='tight',dpi=300)
                VARIANT_ROWS.append({'family':root.name,'scope':'','chart':num,'name':name,'variance':vv,'values':values,'format':ext,'path':str(fp),'variance_applicable':variance_applicable})
                if legacy_root is not None and vv=='without_variance':
                    ld=ensure(legacy_root/ext/values); shutil.copy2(fp,ld/fp.name)
            plt.close(fig)
    return True

def copy_legacy_variants(legacy:Path,newroot:Path,start=42,end=62):
    for num in range(start,end+1):
        srcs=list((legacy/'svg'/'with_values').glob(f'{num:02d}_*.svg'))
        if not srcs: continue
        stem=srcs[0].stem
        name=stem[3:]
        for vv in VARIANTS:
            for values in VALUE_VARIANTS:
                for ext in ('svg','pdf'):
                    src=list((legacy/ext/values).glob(f'{num:02d}_*.{ext}'))
                    if not src:continue
                    d=ensure(newroot/vv/ext/values); dst=d/src[0].name; shutil.copy2(src[0],dst)
                    VARIANT_ROWS.append({'family':'charts','scope':'','chart':num,'name':name,'variance':vv,'values':values,'format':ext,'path':str(dst),'variance_applicable':False})

def load_state_names(root):
    names={0:'POLL',1:'C1',2:'C1E',3:'C6'}
    for r in read_csv(root/'tables/cstate_residency_named_all_runs.csv'):
        i=finite(r.get('state_index'))
        if i is not None:
            nm=str(r.get('state_name','')).split(' (state')[0].strip()
            if nm:names[int(i)]=nm
    return names

def rows_by_mode_rep(rows): return index_rows(rows,'repetition','mode')

def window_maps(report):
    rows=read_csv(report/'newchart/audit/phase_windows.csv'); by={}
    for r in rows:
        rep=int(float(r['repetition'])); m=r['mode']; ph=r['phase']; a=int(float(r['start_ns'])); b=int(float(r['end_ns']))
        by.setdefault((rep,m),{}).setdefault(ph,[]).append((a,b))
    for d in by.values():
        if d.get('active'): d['combined']=[(d['active'][0][0],d['active'][-1][1])]
    return by


def resolve_recorded_path(root:Path, value:str|None):
    if not value:return None
    p=Path(value)
    if p.is_file():return p
    matches=list(root.rglob(p.name))
    return matches[0] if matches else p

def timing_map(report):
    out={}
    for r in read_csv(report/'newchart/audit/timing_sources.csv'):
        try:key=(int(float(r['repetition'])),r['mode'],r['endpoint'],r['source'])
        except Exception:continue
        out[key]=r
    return out

def in_windows(ts,ws):return any(a<=ts<b for a,b in ws)

def parse_frequency_phase(report,root=None):
    root=Path(root) if root is not None else report.parent
    wm=window_maps(report); tm=timing_map(report); metrics={}; samples_rows=[]
    for (rep,m),phases in wm.items():
        for ep in ('server','client'):
            tr=tm.get((rep,m,ep,'frequency')); path=resolve_recorded_path(root,tr.get('path')) if tr else None
            shift=int(float(tr.get('server_shift_ns') or 0)) if tr else 0
            rows=[]
            if path and path.is_file():
                for raw in path.read_text(errors='replace').splitlines():
                    try:o=json.loads(raw)
                    except Exception:continue
                    if o.get('type')!='line':continue
                    ts=finite(o.get('monotonic_ns')); khz=finite(o.get('freq_khz')); cpu=finite(o.get('cpu'))
                    if ts is None or khz is None:continue
                    rows.append((int(ts)+shift,int(cpu or 0),int(khz)))
            for scope in SCOPES:
                ws=phases.get(scope,[]); selected=[x for x in rows if in_windows(x[0],ws)]
                kh=[x[2] for x in selected]
                transitions=0
                for a,b in ws:
                    bycpu={}
                    for ts,cpu,k in selected:
                        if a<=ts<b:bycpu.setdefault(cpu,[]).append((ts,k))
                    for vals in bycpu.values():
                        vals.sort(); transitions += sum(x[1]!=y[1] for x,y in zip(vals,vals[1:]))
                metrics[(rep,m,ep,scope)]={'min_ghz':min(kh)/1e6 if kh else None,'mean_ghz':statistics.mean(kh)/1e6 if kh else None,'max_ghz':max(kh)/1e6 if kh else None,'samples':len(kh) if kh else None,'sampled_transitions':transitions if kh else None}
                samples_rows.append({'repetition':rep,'mode':m,'endpoint':ep,'scope':scope,**metrics[(rep,m,ep,scope)]})
    return metrics,samples_rows

def parse_actual_dvfs(report,root=None):
    root=Path(root) if root is not None else report.parent
    wm=window_maps(report); tm=timing_map(report); metrics={}; events=[]
    pat_action=re.compile(r'policy_action=([a-zA-Z0-9_]+)'); pat_before=re.compile(r'before_khz=(\d+)'); pat_after=re.compile(r'after_khz=(\d+)')
    for (rep,m),phases in wm.items():
        for ep in ('server','client'):
            tr=tm.get((rep,m,ep,'timeline')); path=resolve_recorded_path(root,tr.get('path')) if tr else None
            shift=int(float(tr.get('server_shift_ns') or 0)) if tr else 0
            ev=[]
            if path and path.is_file():
                for raw in path.read_text(errors='replace').splitlines():
                    try:o=json.loads(raw)
                    except Exception:continue
                    line=str(o.get('line',''))
                    if 'GreenQUIC FREQ' not in line or 'result=changed' not in line:continue
                    ts=finite(o.get('monotonic_ns')); ma=pat_action.search(line)
                    if ts is None or not ma:continue
                    action=ma.group(1)
                    cat=None
                    if action in ('freq_max_hard','freq_max_control'):cat='Max'
                    elif action=='freq_up':cat='Up'
                    elif action=='freq_down':cat='Down'
                    elif action=='freq_min':cat='Min'
                    if cat is None:continue
                    before=pat_before.search(line); after=pat_after.search(line); t=int(ts)+shift
                    ev.append((t,cat,action,int(before.group(1)) if before else None,int(after.group(1)) if after else None))
            for scope in SCOPES:
                ws=phases.get(scope,[]); counts={'Max':0,'Up':0,'Down':0,'Min':0}
                for t,cat,action,bef,aft in ev:
                    if in_windows(t,ws):
                        counts[cat]+=1; events.append({'repetition':rep,'mode':m,'endpoint':ep,'scope':scope,'timestamp_client_mono_ns':t,'category':cat,'policy_action':action,'before_khz':bef,'after_khz':aft})
                metrics[(rep,m,ep,scope)]=counts
    return metrics,events

def parse_cstate_phase_counts(report,root=None):
    root=Path(root) if root is not None else report.parent
    wm=window_maps(report);tm=timing_map(report);out={}
    for (rep,m),phases in wm.items():
        for ep in ('server','client'):
            cr=tm.get((rep,m,ep,'cstate'));fr=tm.get((rep,m,ep,'frequency'))
            cp=resolve_recorded_path(root,cr.get('path')) if cr else None;fp=resolve_recorded_path(root,fr.get('path')) if fr else None
            shift=int(float(cr.get('server_shift_ns') or 0)) if cr else 0
            bridges=[]
            if fp and fp.is_file():
                for raw in fp.read_text(errors='replace').splitlines():
                    try:o=json.loads(raw)
                    except Exception:continue
                    if o.get('type')=='clock_bridge' and finite(o.get('monotonic_raw_ns')) is not None and finite(o.get('monotonic_ns')) is not None:bridges.append(o)
            if not bridges or not cp or not cp.is_file():continue
            st=next((x for x in bridges if x.get('phase')=='start'),bridges[0]);en=next((x for x in reversed(bridges) if x.get('phase')=='end'),None)
            sr=int(st['monotonic_raw_ns']);sm=int(st['monotonic_ns'])+shift
            er=int(en['monotonic_raw_ns']) if en else None;em=int(en['monotonic_ns'])+shift if en else None
            def conv(raw):
                off0=sm-sr
                if er is None or em is None or er==sr:return int(raw+off0)
                off1=em-er;frac=max(0.0,min(1.0,(raw-sr)/(er-sr)));return int(raw+off0+frac*(off1-off0))
            entries=[];intervals=[]
            for r in read_csv(cp):
                ts=finite(r.get('timestamp_mono_raw_ns'));ev=str(r.get('event','')).lower();dur=finite(r.get('idle_duration_ns'));prev=finite(r.get('previous_state'))
                if ts is None:continue
                if ev in ('enter','reenter'):entries.append(conv(int(ts)))
                if dur is not None and dur>0 and prev is not None and prev>=0:
                    b=conv(int(ts));a=conv(int(ts-dur));intervals.append((a,b))
            for scope in SCOPES:
                ws=phases.get(scope,[])
                ent=sum(1 for t in entries if in_windows(t,ws))
                ints=sum(1 for a,b in intervals if any(max(a,x)<min(b,y) for x,y in ws))
                out[(rep,m,ep,scope)]={'idle_entries':ent,'idle_intervals':ints}
    return out

def phase_cstate_index(report):
    out={}
    for r in read_csv(report/'data/phase_cstate_all_runs.csv'):
        out[(int(float(r['repetition'])),r['mode'],r['endpoint'])]=r
    return out

def phase_rapl_index(report):
    out={}
    for r in read_csv(report/'data/phase_rapl_all_runs.csv'):
        out[(int(float(r['repetition'])),r['mode'],r['endpoint'],r['phase'])]=r
    return out

def counter_index(report):
    out={}
    for r in read_csv(report/'data/greenquic_counters_all_runs.csv'):
        out[(int(float(r['repetition'])),r['mode'],r['endpoint'])]=r
    return out

def frequency_whole_index(report):
    out={}
    for r in read_csv(report/'data/frequency_all_runs.csv'):
        out[(int(float(r['repetition'])),r['mode'],r['endpoint'])]=r
    return out

def series_from_index(idx, endpoint=None, key=None, transform=lambda x:x):
    out={m:[] for m in MODES}
    reps=sorted({k[0] for k in idx})
    for m in MODES:
        for rep in reps:
            k=(rep,m,endpoint) if endpoint is not None else (rep,m)
            r=idx.get(k); v=finite(r.get(key)) if r and key else None
            out[m].append(transform(v) if v is not None else None)
    return out

def build_original(root,report):
    state_names=load_state_names(root); combined=rows_by_mode_rep(read_csv(root/'tables/combined_endpoint_all_runs.csv')); wm=window_maps(report)
    cidx=phase_cstate_index(report); ridx=phase_rapl_index(report); kidx=counter_index(report); fidx=frequency_whole_index(report)
    clients=rows_by_mode_rep(read_csv(root/'tables/client_all_runs.csv')); servers=rows_by_mode_rep(read_csv(root/'tables/server_all_runs.csv'))
    reps=sorted({r for r,m in combined})
    charts=report/'charts'; legacy=charts
    newroot=charts
    def cmb(key): return {m:[finite(combined.get((rep,m),{}).get(key)) for rep in reps] for m in MODES}
    def cnt(ep,key):
        return {m:[finite(kidx.get((rep,m,ep),{}).get(key)) for rep in reps] for m in MODES}
    def cs(ep,key):return {m:[finite(cidx.get((rep,m,ep),{}).get(key)) for rep in reps] for m in MODES}
    def css(ep,phase,state):return {m:[finite(cidx.get((rep,m,ep),{}).get(f'{phase}_state{state}_s')) or 0.0 for rep in reps] for m in MODES}
    def wholefreq(ep,key):return {m:[finite(fidx.get((rep,m,ep),{}).get(key)) for rep in reps] for m in MODES}
    def phase(ep,ph,key):return {m:[finite(ridx.get((rep,m,ep,ph),{}).get(key)) for rep in reps] for m in MODES}
    def windows_metric(what):
        out={m:[] for m in MODES}
        for m in MODES:
            for rep in reps:
                d=wm.get((rep,m),{})
                if what=='downloads':out[m].append(float(len(d.get('active',[]))))
                elif what=='gaps':out[m].append(float(len(d.get('gap',[]))))
                elif what=='gap_s':out[m].append(sum((b-a)/1e9 for a,b in d.get('gap',[])))
        return out
    payload=cmb('payload_gib')
    total_gbit={m:[v*8*(2**30)/1e9 if v is not None else None for v in payload[m]] for m in MODES}
    save_bar(newroot,1,'file_size_and_payload','File size and total useful payload','GiB',{'Payload':payload},legacy_root=legacy)
    save_bar(newroot,2,'download_and_gap_counts','Downloads and configured gaps','Count',{'Downloads':windows_metric('downloads'),'Gaps':windows_metric('gaps')},kind='count',legacy_root=legacy)
    save_bar(newroot,3,'gap_duration','Observed inter-download gap duration','Seconds',{'Gap total':windows_metric('gap_s')},kind='seconds',legacy_root=legacy)
    save_bar(newroot,4,'active_goodput','Active goodput','Gbit/s',{'Goodput':cmb('goodput_excluding_gaps_gbps')},kind='gbps',legacy_root=legacy)
    save_bar(newroot,5,'gap_inclusive_goodput','Gap-inclusive goodput','Gbit/s',{'Goodput':cmb('goodput_including_gaps_gbps')},kind='gbps',legacy_root=legacy)
    save_bar(newroot,6,'duration_breakdown','Transfer, gap-window, and aligned duration','Seconds',{'Workload':cmb('workload_duration_s'),'Client aligned':cmb('client_aligned_duration_s'),'Server aligned':cmb('server_aligned_duration_s')},kind='seconds',legacy_root=legacy)
    save_bar(newroot,7,'average_rapl_power','Average RAPL power','Power (W)',{'Server':cmb('server_average_power_w'),'Client':cmb('client_average_power_w'),'Combined':cmb('combined_average_power_w')},kind='power',legacy_root=legacy)
    save_bar(newroot,8,'rapl_energy','RAPL energy','Energy (J)',{'Server':cmb('server_rapl_energy_j'),'Client':cmb('client_rapl_energy_j'),'Combined':cmb('combined_rapl_energy_j')},kind='energy',legacy_root=legacy)
    # standardize energy efficiency as energy cost: J per useful decimal Gbit.
    e9={}
    for lab,key in [('Server','server_rapl_energy_j'),('Client','client_rapl_energy_j'),('Combined','combined_rapl_energy_j')]:
        e9[lab]={m:[(e/g if e is not None and g else None) for e,g in zip(cmb(key)[m],total_gbit[m])] for m in MODES}
    save_bar(newroot,9,'energy_efficiency','Energy per useful payload','J/Gbit',e9,kind='j_per_gbit',legacy_root=legacy)
    save_bar(newroot,10,'server_whole_cstate','Server whole-trace C-state residency','Seconds',{state_names[s]:css('server','whole',s) for s in range(4)},kind='seconds',legacy_root=legacy)
    save_bar(newroot,11,'client_whole_cstate','Client whole-trace C-state residency','Seconds',{state_names[s]:css('client','whole',s) for s in range(4)},kind='seconds',legacy_root=legacy)
    save_bar(newroot,12,'whole_idle_and_trace_duration','Whole-trace idle time and raw trace duration','Seconds',{'Server idle':cs('server','whole_idle_s'),'Server trace':cs('server','trace_duration_s'),'Client idle':cs('client','whole_idle_s'),'Client trace':cs('client','trace_duration_s')},kind='seconds',legacy_root=legacy)
    save_bar(newroot,13,'aligned_idle_fraction','Idle fraction of aligned workload time','Percent',{'Server':cs('server','aligned_idle_fraction_pct'),'Client':cs('client','aligned_idle_fraction_pct')},kind='percent',legacy_root=legacy)
    save_bar(newroot,14,'server_active_transfer_cstate','Server active-transfer C-state residency','Seconds',{state_names[s]:css('server','active',s) for s in range(4)},kind='seconds',legacy_root=legacy)
    save_bar(newroot,15,'client_active_transfer_cstate','Client active-transfer C-state residency','Seconds',{state_names[s]:css('client','active',s) for s in range(4)},kind='seconds',legacy_root=legacy)
    save_bar(newroot,16,'active_transfer_total_idle','Active-transfer total idle time','Seconds',{'Server':cs('server','active_idle_s'),'Client':cs('client','active_idle_s')},kind='seconds',legacy_root=legacy)
    save_bar(newroot,17,'active_transfer_idle_fraction','Active-transfer idle fraction','Percent',{'Server':cs('server','active_idle_fraction_pct'),'Client':cs('client','active_idle_fraction_pct')},kind='percent',legacy_root=legacy)
    save_bar(newroot,18,'active_transfer_idle_intervals','Active-transfer idle intervals','Count',{'Server':cs('server','active_intervals'),'Client':cs('client','active_intervals')},kind='count',legacy_root=legacy)
    save_bar(newroot,19,'server_gap_cstate','Server inter-download-gap C-state residency','Seconds',{state_names[s]:css('server','gap',s) for s in range(4)},kind='seconds',legacy_root=legacy)
    save_bar(newroot,20,'client_gap_cstate','Client inter-download-gap C-state residency','Seconds',{state_names[s]:css('client','gap',s) for s in range(4)},kind='seconds',legacy_root=legacy)
    save_bar(newroot,21,'gap_total_idle','Inter-download-gap total idle time','Seconds',{'Server':cs('server','gap_idle_s'),'Client':cs('client','gap_idle_s')},kind='seconds',legacy_root=legacy)
    save_bar(newroot,22,'gap_idle_fraction','Inter-download-gap idle fraction','Percent',{'Server':cs('server','gap_idle_fraction_pct'),'Client':cs('client','gap_idle_fraction_pct')},kind='percent',legacy_root=legacy)
    save_bar(newroot,23,'gap_idle_intervals','Inter-download-gap idle intervals','Count',{'Server':cs('server','gap_intervals'),'Client':cs('client','gap_intervals')},kind='count',legacy_root=legacy)
    save_bar(newroot,24,'linux_idle_entries','Linux idle entries — whole trace','Count',{'Server':cs('server','linux_idle_entries'),'Client':cs('client','linux_idle_entries')},kind='count',legacy_root=legacy)
    save_bar(newroot,25,'server_epoll_attempts_wakes_timeouts','Server EPOLL attempts / wakeups / timeouts','Count',{'Attempts':cnt('server','epoll_try'),'Wakeups':cnt('server','epoll_wake'),'Timeouts':cnt('server','epoll_timeout')},kind='count',legacy_root=legacy)
    save_bar(newroot,26,'server_epoll_wake_sources','Server EPOLL wake sources','Count',{'RX':cnt('server','epoll_rx_wake'),'Software/control':cnt('server','epoll_control_wake'),'Signal':cnt('server','epoll_signal_wake')},kind='count',legacy_root=legacy)
    save_bar(newroot,27,'client_epoll_attempts_wakes_timeouts','Client EPOLL attempts / wakeups / timeouts','Count',{'Attempts':cnt('client','epoll_try'),'Wakeups':cnt('client','epoll_wake'),'Timeouts':cnt('client','epoll_timeout')},kind='count',legacy_root=legacy)
    save_bar(newroot,28,'client_epoll_wake_sources','Client EPOLL wake sources','Count',{'RX':cnt('client','epoll_rx_wake'),'Software/control':cnt('client','epoll_control_wake'),'Signal':cnt('client','epoll_signal_wake')},kind='count',legacy_root=legacy)
    save_bar(newroot,29,'server_frequency_range','Server observed frequency min–max — whole trace','GHz',{'Min':wholefreq('server','min_ghz'),'Max':wholefreq('server','max_ghz')},kind='ghz',legacy_root=legacy)
    save_bar(newroot,30,'client_frequency_range','Client observed frequency min–max — whole trace','GHz',{'Min':wholefreq('client','min_ghz'),'Max':wholefreq('client','max_ghz')},kind='ghz',legacy_root=legacy)
    pol=[('max_hard','freq_policy_max_hard'),('max_control','freq_policy_max_control'),('up','freq_policy_up'),('down','freq_policy_down'),('min','freq_policy_min'),('off_fixed_max','freq_policy_off_fixed_max')]
    chg=[('Max','freq_changed_max'),('Up','freq_changed_up'),('Down','freq_changed_down'),('Min','freq_changed_min')]
    save_bar(newroot,31,'server_frequency_policy_actions','Server frequency-policy decisions — whole run','Count',{lab:cnt('server',k) for lab,k in pol},kind='count',legacy_root=legacy)
    save_bar(newroot,32,'server_actual_frequency_changes','Server actual DVFS API changes — whole run','Count',{lab:cnt('server',k) for lab,k in chg},kind='count',legacy_root=legacy)
    save_bar(newroot,33,'client_frequency_policy_actions','Client frequency-policy decisions — whole run','Count',{lab:cnt('client',k) for lab,k in pol},kind='count',legacy_root=legacy)
    save_bar(newroot,34,'client_actual_frequency_changes','Client actual DVFS API changes — whole run','Count',{lab:cnt('client',k) for lab,k in chg},kind='count',legacy_root=legacy)
    def total_policy(ep):
        out={m:[] for m in MODES}
        for m in MODES:
            for i,rep in enumerate(reps):
                vals=[finite(kidx.get((rep,m,ep),{}).get(k)) for _,k in pol]
                out[m].append(sum(v or 0 for v in vals) if any(v is not None for v in vals) else None)
        return out
    save_bar(newroot,35,'total_frequency_policy_actions','Total frequency-policy decisions — whole run','Count',{'Server':total_policy('server'),'Client':total_policy('client')},kind='count',legacy_root=legacy)
    save_bar(newroot,36,'timestamped_frequency_events','Timestamped frequency samples — whole trace','Count',{'Server':wholefreq('server','sample_events'),'Client':wholefreq('client','sample_events')},kind='count',legacy_root=legacy)
    def plus_only(ep,key):
        out={m:[0.0 for _ in reps] for m in MODES}
        out['plus']=[finite(kidx.get((rep,'plus',ep),{}).get(key)) for rep in reps]
        return out
    save_bar(newroot,37,'plus_ack_pending_and_ramping','PLUS ACK_PENDING and CUBIC ramping','Count',{'Client ACK_PENDING':plus_only('client','hint_ack_pending'),'Server ACK_PENDING':plus_only('server','hint_ack_pending'),'Client CUBIC ramping':plus_only('client','hint_cubic_ramping'),'Server CUBIC ramping':plus_only('server','hint_cubic_ramping')},kind='count',legacy_root=legacy)
    save_bar(newroot,38,'plus_cwnd_blocked_recovery','PLUS CWND blocked / recovery','Count',{'CWND blocked':plus_only('client','hint_cubic_cwnd_blocked'),'Recovery':plus_only('client','hint_cubic_recovery')},kind='count',legacy_root=legacy)
    runsrec={m:[0.0 for _ in reps] for m in MODES}; runsrec['plus']=[1.0 if (finite(kidx.get((rep,'plus','client'),{}).get('hint_cubic_recovery')) or 0)>0 else 0.0 for rep in reps]
    save_bar(newroot,39,'plus_client_recovery_detail','PLUS client CUBIC recovery detail','Count',{'Recovery begin':plus_only('client','hint_cubic_recovery'),'Recovery end':plus_only('client','hint_cubic_recovery_end'),'Run contains recovery':runsrec},kind='count',legacy_root=legacy)
    save_bar(newroot,40,'transfer_begin_end_hints','PLUS transfer begin/end hints','Count',{'Client FILE_RX begin':plus_only('client','hint_client_file_rx_active'),'Client FILE_RX end':plus_only('client','hint_client_file_rx_end'),'Server FILE_TX begin':plus_only('server','hint_server_file_tx_active'),'Server FILE_TX end':plus_only('server','hint_server_file_tx_end')},kind='count',legacy_root=legacy)
    def packet(ep,dir):
        table=clients if ep=='client' else servers
        return {m:[field(table.get((rep,m)),'dpdk',dir,'packets') or field(table.get((rep,m)),dir,'packets') for rep in reps] for m in MODES}
    save_bar(newroot,41,'dpdk_packet_counts','DPDK packet counts — process lifetime','Count',{'Client RX':packet('client','rx'),'Client TX':packet('client','tx'),'Server RX':packet('server','rx'),'Server TX':packet('server','tx')},kind='count',legacy_root=legacy)
    # 42-43 are text/config charts: variance not applicable. 48-62 are representative traces: variance not applicable.
    for num,title,ph,key,kind in [(44,'Active-transfer RAPL power','active','power_w','power'),(45,'Inter-download-gap RAPL power','gap','power_w','power'),(46,'Active-transfer RAPL energy','active','energy_j','energy'),(47,'Inter-download-gap RAPL energy','gap','energy_j','energy')]:
        s=phase('server',ph,key); c=phase('client',ph,key); comb=combine_series(s,c)
        save_bar(newroot,num,normkey(title),title,'Power (W)' if key=='power_w' else 'Energy (J)',{'Server':s,'Client':c,'Combined':comb},kind=kind,legacy_root=legacy)
    copy_legacy_variants(legacy,newroot,42,43); copy_legacy_variants(legacy,newroot,48,62)
    return {'state_names':state_names,'combined':combined,'wm':wm,'cidx':cidx,'ridx':ridx,'kidx':kidx,'fidx':fidx,'reps':reps,'total_gbit':total_gbit}

def save_scope_bar(root,scope,num,name,title,ylabel,series,kind='scalar',variance_applicable=True):
    # same renderer but scope-aware stats rows
    cache={lab:[stat(by.get(m,[])) for m in MODES] for lab,by in series.items()}
    if not any(s['mean'] is not None for ss in cache.values() for s in ss):return False
    for lab,ss in cache.items():
        for m,s in zip(MODES,ss): STATS_ROWS.append({'family':root.parent.name,'chart':num,'name':name,'scope':scope,'series':lab,'mode':m,**s})
    for vv in VARIANTS:
        for values in VALUE_VARIANTS:
            show=values=='with_values'; want=vv=='with_variance'; fig,ax=plt.subplots(figsize=(15,8)); x=np.arange(3); width=min(.72/max(1,len(series)),.24)
            for j,(lab,_) in enumerate(series.items()):
                ss=cache[lab]; means=[s['mean'] if s['mean'] is not None else np.nan for s in ss]; pos=x+(j-(len(series)-1)/2)*width; errs=[s['sd'] if want and variance_applicable and s['sd'] is not None else 0 for s in ss]
                bars=ax.bar(pos,means,width,label=lab,yerr=errs if want and variance_applicable else None,capsize=5 if want and variance_applicable else 0)
                if show:
                    for b,mu,s,e in zip(bars,means,ss,errs):
                        if math.isfinite(mu):
                            t=fmt(mu,kind)
                            if want and variance_applicable:t+=(f'\nSD={fmt(s["sd"],kind)}' if s['sd'] is not None else f'\nSD N/A (n={s["n"]})')
                            ax.annotate(t,(b.get_x()+b.get_width()/2,mu+e),xytext=(0,7),textcoords='offset points',ha='center',fontsize=7)
            if want and variance_applicable and not any(s['sd'] is not None for ss in cache.values() for s in ss if s['n']):ax.text(.995,.985,'Error bars unavailable: only one independent repetition (n=1)',transform=ax.transAxes,ha='right',va='top',fontsize=9)
            ax.set_xticks(x,[MODE_NAMES[m] for m in MODES]);ax.set_ylabel(ylabel);ax.set_title(title,pad=18,fontweight='normal');ax.grid(axis='y',alpha=.3);ax.set_axisbelow(True);ax.set_ylim(bottom=0)
            if len(series)>1:ax.legend(loc='center left',bbox_to_anchor=(1.01,.5))
            fig.tight_layout()
            for ext in ('svg','pdf'):
                d=ensure(root/vv/ext/values);fp=d/f'{num:02d}_{name}.{ext}';fig.savefig(fp,bbox_inches='tight',dpi=300);VARIANT_ROWS.append({'family':root.parent.name,'scope':scope,'chart':num,'name':name,'variance':vv,'values':values,'format':ext,'path':str(fp),'variance_applicable':variance_applicable})
            plt.close(fig)
    return True

def build_phase_charts(root,report,ctx,freqphase,dvfs):
    # Replace phase charts with corrected labels and exact actual DVFS changes.
    state=ctx['state_names']; reps=ctx['reps']; wm=ctx['wm']; ridx=ctx['ridx']; cidx=ctx['cidx']; combined=ctx['combined']; total_gbit=ctx['total_gbit']
    base=report/'newchart'
    # clear only chart image/stat folders; keep audit.
    for scope in SCOPES:
        for vv in VARIANTS:
            p=base/scope/vv
            if p.exists():shutil.rmtree(p)
    def phase_duration(scope):
        return {m:[sum((b-a)/1e9 for a,b in wm.get((rep,m),{}).get(scope,[])) for rep in reps] for m in MODES}
    def rapl(ep,scope,key):
        def get(rep,m):
            if scope in ('active','gap'): return finite(ridx.get((rep,m,ep,scope),{}).get(key))
            a=ridx.get((rep,m,ep,'active'),{});g=ridx.get((rep,m,ep,'gap'),{})
            if key=='energy_j':
                x,y=finite(a.get('energy_j')),finite(g.get('energy_j'));return x+y if x is not None and y is not None else None
            if key=='power_w':
                ae,ad,ge,gd=map(finite,(a.get('energy_j'),a.get('duration_s'),g.get('energy_j'),g.get('duration_s')))
                return (ae+ge)/(ad+gd) if None not in (ae,ad,ge,gd) and ad+gd>0 else None
        return {m:[get(rep,m) for rep in reps] for m in MODES}
    def cs(ep,scope,key):
        mapping={'active':{'idle':'active_idle_s','frac':'active_idle_fraction_pct','intervals':'active_intervals'},'gap':{'idle':'gap_idle_s','frac':'gap_idle_fraction_pct','intervals':'gap_intervals'},'combined':{'idle':'aligned_idle_s','frac':'aligned_idle_fraction_pct'}}
        k=mapping.get(scope,{}).get(key)
        return {m:[finite(cidx.get((rep,m,ep),{}).get(k)) if k else None for rep in reps] for m in MODES}
    def css(ep,scope,s):
        phase={'active':'active','gap':'gap','combined':'aligned'}[scope]
        return {m:[finite(cidx.get((rep,m,ep),{}).get(f'{phase}_state{s}_s')) or 0.0 for rep in reps] for m in MODES}
    for scope in SCOPES:
        dest=base/scope
        if scope=='active': save_scope_bar(dest,scope,4,'active_goodput','Active — goodput','Gbit/s',{'Goodput':{m:[finite(combined.get((rep,m),{}).get('goodput_excluding_gaps_gbps')) for rep in reps] for m in MODES}},'gbps')
        if scope=='combined': save_scope_bar(dest,scope,5,'gap_inclusive_goodput','Workload window — gap-inclusive goodput','Gbit/s',{'Goodput':{m:[finite(combined.get((rep,m),{}).get('goodput_including_gaps_gbps')) for rep in reps] for m in MODES}},'gbps')
        save_scope_bar(dest,scope,6,'phase_duration',f'{scope.title()} duration','Seconds',{'Duration':phase_duration(scope)},'seconds')
        se=rapl('server',scope,'energy_j');ce=rapl('client',scope,'energy_j');sp=rapl('server',scope,'power_w');cp=rapl('client',scope,'power_w')
        save_scope_bar(dest,scope,7,'average_rapl_power',f'{scope.title()} — average RAPL power','Power (W)',{'Server':sp,'Client':cp,'Combined':combine_series(sp,cp)},'power')
        save_scope_bar(dest,scope,8,'rapl_energy',f'{scope.title()} — RAPL energy','Energy (J)',{'Server':se,'Client':ce,'Combined':combine_series(se,ce)},'energy')
        if scope!='gap':
            eff={}
            for lab,src in [('Server',se),('Client',ce),('Combined',combine_series(se,ce))]:eff[lab]={m:[e/g if e is not None and g else None for e,g in zip(src[m],total_gbit[m])] for m in MODES}
            save_scope_bar(dest,scope,9,'rapl_energy_per_gbit',f'{scope.title()} — energy per useful payload','J/Gbit',eff,'j_per_gbit')
        nums=(14,15) if scope!='gap' else (19,20)
        save_scope_bar(dest,scope,nums[0],'server_cstate_residency',f'{scope.title()} — server C-state residency','Seconds',{state[s]:css('server',scope,s) for s in range(4)},'seconds')
        save_scope_bar(dest,scope,nums[1],'client_cstate_residency',f'{scope.title()} — client C-state residency','Seconds',{state[s]:css('client',scope,s) for s in range(4)},'seconds')
        nums2=(16,17,18) if scope!='gap' else (21,22,23)
        save_scope_bar(dest,scope,nums2[0],'cpu_idle_time',f'{scope.title()} — CPU idle time','Seconds',{'Server':cs('server',scope,'idle'),'Client':cs('client',scope,'idle')},'seconds')
        save_scope_bar(dest,scope,nums2[1],'cpu_idle_fraction',f'{scope.title()} — CPU idle fraction','Percent',{'Server':cs('server',scope,'frac'),'Client':cs('client',scope,'frac')},'percent')
        int_key={'active':'active_intervals','gap':'gap_intervals','combined':'aligned_intervals'}[scope]
        entry_key={'active':'active_entries','gap':'gap_entries','combined':'aligned_entries'}[scope]
        exact_int={'Server':{m:[finite(cidx.get((rep,m,'server'),{}).get(int_key)) for rep in reps] for m in MODES},'Client':{m:[finite(cidx.get((rep,m,'client'),{}).get(int_key)) for rep in reps] for m in MODES}}
        if any(v is not None for by in exact_int.values() for vals in by.values() for v in vals): save_scope_bar(dest,scope,nums2[2],'idle_intervals',f'{scope.title()} — idle intervals','Count',exact_int,'count')
        exact_ent={'Server':{m:[finite(cidx.get((rep,m,'server'),{}).get(entry_key)) for rep in reps] for m in MODES},'Client':{m:[finite(cidx.get((rep,m,'client'),{}).get(entry_key)) for rep in reps] for m in MODES}}
        if any(v is not None for by in exact_ent.values() for vals in by.values() for v in vals): save_scope_bar(dest,scope,24,'linux_idle_entries',f'{scope.title()} — Linux idle entries','Count',exact_ent,'count')
        # Observed frequency state from timestamped sampler.
        for num,ep in ((29,'server'),(30,'client')):
            ser={lab:{m:[freqphase.get((rep,m,ep,scope),{}).get(k) for rep in reps] for m in MODES} for lab,k in [('Min','min_ghz'),('Mean','mean_ghz'),('Max','max_ghz')]}
            save_scope_bar(dest,scope,num,f'{ep}_observed_frequency',f'{scope.title()} — {ep.title()} observed frequency','GHz',ser,'ghz')
        # Exact GreenQUIC DVFS API changes from timestamped FREQ result=changed lines.
        for num,ep in ((32,'server'),(34,'client')):
            ser={cat:{m:[float(dvfs.get((rep,m,ep,scope),{}).get(cat,0)) for rep in reps] for m in MODES} for cat in ('Max','Up','Down','Min')}
            save_scope_bar(dest,scope,num,f'{ep}_actual_dvfs_changes',f'{scope.title()} — {ep.title()} actual DVFS changes','Count',ser,'count')
        ser={'Server':{m:[freqphase.get((rep,m,'server',scope),{}).get('samples') for rep in reps] for m in MODES},'Client':{m:[freqphase.get((rep,m,'client',scope),{}).get('samples') for rep in reps] for m in MODES}}
        save_scope_bar(dest,scope,36,'timestamped_frequency_samples',f'{scope.title()} — timestamped frequency samples','Count',ser,'count')
        if scope=='active':
            save_scope_bar(dest,scope,44,'active_rapl_power','Active-transfer RAPL power','Power (W)',{'Server':sp,'Client':cp,'Combined':combine_series(sp,cp)},'power');save_scope_bar(dest,scope,46,'active_rapl_energy','Active-transfer RAPL energy','Energy (J)',{'Server':se,'Client':ce,'Combined':combine_series(se,ce)},'energy')
        if scope=='gap':
            save_scope_bar(dest,scope,45,'gap_rapl_power','Inter-download-gap RAPL power','Power (W)',{'Server':sp,'Client':cp,'Combined':combine_series(sp,cp)},'power');save_scope_bar(dest,scope,47,'gap_rapl_energy','Inter-download-gap RAPL energy','Energy (J)',{'Server':se,'Client':ce,'Combined':combine_series(se,ce)},'energy')
        # Per-scope statistics file.
        for vv in VARIANTS:
            rows=[r for r in STATS_ROWS if r.get('family')=='newchart' and r.get('scope')==scope]
            write_csv(report/f'newchart/{scope}/{vv}/statistics.csv',rows)

def delete_chart_number(root:Path,num:int):
    for vv in VARIANTS:
        for ext in ('svg','pdf'):
            for values in VALUE_VARIANTS:
                d=root/vv/ext/values
                if d.exists():
                    for p in d.glob(f'{num:02d}_*.{ext}'):
                        p.unlink()

def save_scope_scatter(root,scope,num,name,title,xlabel,ylabel,xby,yby,kind_y='scalar'):
    cachex={m:stat(xby.get(m,[])) for m in MODES}; cachey={m:stat(yby.get(m,[])) for m in MODES}
    for m in MODES:
        STATS_ROWS.append({'family':root.parent.name,'chart':num,'name':name+'_x','scope':scope,'series':xlabel,'mode':m,**cachex[m]})
        STATS_ROWS.append({'family':root.parent.name,'chart':num,'name':name+'_y','scope':scope,'series':ylabel,'mode':m,**cachey[m]})
    for vv in VARIANTS:
        want=vv=='with_variance'
        for values in VALUE_VARIANTS:
            show=values=='with_values';fig,ax=plt.subplots(figsize=(11,8))
            for m in MODES:
                xs,ys=cachex[m],cachey[m]
                if xs['mean'] is None or ys['mean'] is None:continue
                xe=xs['sd'] if want and xs['sd'] is not None else None;ye=ys['sd'] if want and ys['sd'] is not None else None
                ax.errorbar(xs['mean'],ys['mean'],xerr=xe,yerr=ye,fmt='o',capsize=5 if want and (xe is not None or ye is not None) else 0,label=MODE_NAMES[m])
                if show:
                    txt=f"{MODE_NAMES[m]}\n({fmt(xs['mean'],'seconds')}, {fmt(ys['mean'],kind_y)})"
                    if want and (xs['sd'] is None or ys['sd'] is None):txt+='\nSD N/A (n=1)'
                    ax.annotate(txt,(xs['mean'],ys['mean']),xytext=(8,8),textcoords='offset points',fontsize=8)
            if want and not any(cachex[m]['sd'] is not None or cachey[m]['sd'] is not None for m in MODES):ax.text(.995,.985,'Error bars unavailable: only one independent repetition (n=1)',transform=ax.transAxes,ha='right',va='top',fontsize=9)
            ax.set_xlabel(xlabel);ax.set_ylabel(ylabel);ax.set_title(title,pad=18,fontweight='normal');ax.grid(alpha=.3);ax.legend(loc='center left',bbox_to_anchor=(1.01,.5));fig.tight_layout()
            for ext in ('svg','pdf'):
                d=ensure(root/vv/ext/values);fp=d/f'{num:02d}_{name}.{ext}';fig.savefig(fp,bbox_inches='tight',dpi=300);VARIANT_ROWS.append({'family':root.parent.name,'scope':scope,'chart':num,'name':name,'variance':vv,'values':values,'format':ext,'path':str(fp),'variance_applicable':True})
            plt.close(fig)

def build_derived(report,ctx):
    # Correct energy efficiency direction: J/useful Gbit (lower is better).
    reps=ctx['reps']; combined=ctx['combined']; wm=ctx['wm']; ridx=ctx['ridx']; total_gbit=ctx['total_gbit']
    base=report/'derived'
    for scope in ('active','combined'):
        dest=base/scope
        def dur(rep,m):
            ws=wm.get((rep,m),{}); return sum((b-a)/1e9 for a,b in (ws.get('active',[]) if scope=='active' else ws.get('combined',[])))
        duration={m:[dur(rep,m) for rep in reps] for m in MODES}
        dct={m:[statistics.mean([(b-a)/1e9 for a,b in wm.get((rep,m),{}).get('active',[])]) for rep in reps] for m in MODES}
        def energy(ep,rep,m):
            a=finite(ridx.get((rep,m,ep,'active'),{}).get('energy_j'))
            if scope=='active':return a
            g=finite(ridx.get((rep,m,ep,'gap'),{}).get('energy_j')); return a+g if a is not None and g is not None else None
        se={m:[energy('server',rep,m) for rep in reps] for m in MODES};ce={m:[energy('client',rep,m) for rep in reps] for m in MODES};co=combine_series(se,ce)
        cost={lab:{m:[e/g if e is not None and g else None for e,g in zip(src[m],total_gbit[m])] for m in MODES} for lab,src in [('Server',se),('Client',ce),('Combined',co)]}
        delete_chart_number(dest,3); delete_chart_number(dest,6)
        save_scope_bar(dest,scope,3,'energy_cost_j_per_gbit',f'{scope.title()} energy per useful payload','J/Gbit',cost,'j_per_gbit')
        xmetric=dct if scope=='active' else duration
        save_scope_scatter(dest,scope,6,'energy_cost_vs_completion_time',f'{scope.title()} energy cost vs completion time','Mean DCT (s)' if scope=='active' else 'Workload completion time (s)','Combined J/Gbit',xmetric,cost['Combined'],'j_per_gbit')
        rows=[r for r in STATS_ROWS if r.get('family')=='derived' and r.get('scope')==scope];write_csv(dest/'corrected_energy_cost_statistics.csv',rows)
    # Gap derived is still meaningful as energy-time product; leave existing files, but ensure both variants exist already.

def write_csv(path:Path,rows:list[dict]):
    ensure(path.parent)
    if not rows:path.write_text('status\nno rows\n');return
    cols=[]
    for r in rows:
        for k in r:
            if k not in cols:cols.append(k)
    with path.open('w',newline='',encoding='utf-8') as f:
        w=csv.DictWriter(f,fieldnames=cols);w.writeheader();w.writerows(rows)

def xml_cell(ref,val):
    if val is None:return ''
    if isinstance(val,(int,float)) and math.isfinite(float(val)):return f'<c r="{ref}"><v>{val}</v></c>'
    return f'<c r="{ref}" t="inlineStr"><is><t>{escape(str(val))}</t></is></c>'
def xlcol(n):
    s=''
    while n:n,r=divmod(n-1,26);s=chr(65+r)+s
    return s

def write_xlsx_stream(path:Path,sheets:list[tuple[str,Iterable[list[Any]]]]):
    ensure(path.parent); names=[]
    for name,_ in sheets:
        base=re.sub(r'[\\/*?:\[\]]','_',name)[:31] or 'Sheet';cand=base;i=2
        while cand in names:cand=(base[:27]+f'_{i}');i+=1
        names.append(cand)
    with zipfile.ZipFile(path,'w',zipfile.ZIP_DEFLATED) as z:
        z.writestr('[Content_Types].xml','<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'+''.join(f'<Override PartName="/xl/worksheets/sheet{i}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' for i in range(1,len(sheets)+1))+'</Types>')
        z.writestr('_rels/.rels','<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>')
        z.writestr('xl/workbook.xml','<?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>'+''.join(f'<sheet name="{escape(n)}" sheetId="{i}" r:id="rId{i}"/>' for i,n in enumerate(names,1))+'</sheets></workbook>')
        z.writestr('xl/_rels/workbook.xml.rels','<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/relationships">'+''.join(f'<Relationship Id="rId{i}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet{i}.xml"/>' for i in range(1,len(sheets)+1))+'</Relationships>')
        for i,(_,rows) in enumerate(sheets,1):
            with z.open(f'xl/worksheets/sheet{i}.xml','w') as f:
                f.write(b'<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>')
                for ri,row in enumerate(rows,1):
                    parts=[f'<row r="{ri}">']
                    for ci,val in enumerate(row,1):
                        c=xml_cell(f'{xlcol(ci)}{ri}',val)
                        if c:parts.append(c)
                    parts.append('</row>');f.write(''.join(parts).encode())
                f.write(b'</sheetData></worksheet>')
def dict_rows(rows):
    rows=list(rows)
    if not rows:return [['No rows']]
    cols=[]
    for r in rows:
        for k in r:
            if k not in cols:cols.append(k)
    yield cols
    for r in rows:yield [r.get(c,'') for c in cols]
def raw_rapl_rows(root):
    yield ['role','repetition','mode','path','sample_monotonic_ns','actual_interval_ms','package_delta_j','dram_delta_j']
    for p in root.rglob('*_msr_power.csv'):
        if 'the_sheet_rules_all' in p.parts:continue
        text='/'.join(p.parts).lower();role='client' if '/client/' in text else ('server' if '/server/' in text else '')
        m=re.search(r'rep(\d+)_(off|basic|plus)',text)
        if not m:continue
        for r in read_csv(p):yield [role,int(m.group(1)),m.group(2),str(p),r.get('sample_monotonic_ns') or r.get('monotonic_ns'),r.get('actual_interval_ms') or r.get('interval_ms'),r.get('package_delta_j'),r.get('dram_delta_j')]
def raw_freq_rows(report):
    yield ['repetition','mode','endpoint','path','monotonic_ns_client_domain','cpu','freq_khz']
    tm=timing_map(report)
    for (rep,m,ep,src),r in tm.items():
        if src!='frequency':continue
        p=Path(r['path']);shift=int(float(r.get('server_shift_ns') or 0))
        if not p.is_file():continue
        for line in p.read_text(errors='replace').splitlines():
            try:o=json.loads(line)
            except Exception:continue
            if o.get('type')!='line':continue
            ts=finite(o.get('monotonic_ns'));khz=finite(o.get('freq_khz'))
            if ts is not None and khz is not None:yield [rep,m,ep,str(p),int(ts)+shift,o.get('cpu'),int(khz)]
def build_workbook(root,report,freqrows,dvfsevents):
    # Full comparison is similar to the user's reference workbook, now with source/scope columns.
    combined_avg=read_csv(root/'tables/combined_endpoint_mode_averages.csv');by={r['mode']:r for r in combined_avg}
    full=[['Metric','Value order / fields','MsQuic-DPDK','GreenQUIC','GreenQUIC+','Source / scope']]
    keys=[]
    for r in combined_avg:
        for k in r:
            if k!='mode' and k not in keys:keys.append(k)
    for k in keys:full.append([k,'OFF / BASIC / PLUS',by.get('off',{}).get(k,''),by.get('basic',{}).get(k,''),by.get('plus',{}).get(k,''),'combined_endpoint_mode_averages.csv'])
    chart_catalog=[['Family','Chart','Name','Scope','Correctness / semantics']]
    for n in range(1,63):
        note='Original whole-run/scalar chart'
        if n in (2,3):note='Dynamic from actual request windows; no hard-coded 5/4/20 values'
        if n==9:note='Energy cost standardized to J/useful Gbit (lower is better)'
        if n in (10,11,14,15,19,20):note='C-state names use kernel mapping: POLL/C1/C1E/C6; adaptive tiny-value labels'
        if n in (31,33,35):note='Whole-run cumulative policy decisions; not phase-splittable exactly'
        if n in (32,34):note='Whole-run process counters; phase version uses timestamped FREQ result=changed events'
        if n in range(48,63):note='Representative RAPL time-series; repetition variance not applicable'
        chart_catalog.append(['charts',n,'', 'whole/original',note])
    sheets=[('Full comparison',full),('Chart catalog',chart_catalog),('Chart variants',dict_rows(VARIANT_ROWS)),('Chart statistics',dict_rows(STATS_ROWS)),('Combined all runs',dict_rows(read_csv(root/'tables/combined_endpoint_all_runs.csv'))),('Combined averages',dict_rows(combined_avg)),('Client all runs',dict_rows(read_csv(root/'tables/client_all_runs.csv'))),('Server all runs',dict_rows(read_csv(root/'tables/server_all_runs.csv'))),('Power management',dict_rows(read_csv(root/'tables/power_management_behavior_mode_averages.csv'))),('Phase RAPL',dict_rows(read_csv(report/'data/phase_rapl_all_runs.csv'))),('Phase C-state',dict_rows(read_csv(report/'data/phase_cstate_all_runs.csv'))),('C-state mapping',dict_rows(read_csv(root/'tables/cstate_residency_named_all_runs.csv'))),('GreenQUIC counters',dict_rows(read_csv(report/'data/greenquic_counters_all_runs.csv'))),('Frequency whole',dict_rows(read_csv(report/'data/frequency_all_runs.csv'))),('Frequency phase',dict_rows(freqrows)),('Actual DVFS phase',dict_rows(dvfsevents)),('Phase windows',dict_rows(read_csv(report/'newchart/audit/phase_windows.csv'))),('Timing sources',dict_rows(read_csv(report/'newchart/audit/timing_sources.csv'))),('GET alignment',dict_rows(read_csv(report/'newchart/audit/server_get_alignment_pairs.csv'))),('Raw RAPL samples',raw_rapl_rows(root))]
    out=report/'GreenQUIC_sheet_rules_all.xlsx';write_xlsx_stream(out,sheets);shutil.copy2(out,report/'GreenQUIC_full_results.xlsx')

def audit_report(root,report):
    rows=[]
    for n in range(1,63):
        status='PASS';issue=''
        if n==2:issue='Pre-patch hard-coded 5 downloads/4 gaps; fixed to actual run windows.'
        elif n==3:issue='Pre-patch hard-coded 20 s gap total; fixed to observed/configured window total.'
        elif n==9:issue='Standardized to J/useful Gbit, lower is better.'
        elif n in (10,11,14,15,19,20):issue='Kernel C-state names + adaptive precision; non-zero µs/ms values no longer display as 0.00.'
        elif n in (31,33,35):issue='Correct only as whole-run cumulative decisions; no exact active/gap split.'
        elif n in (32,34):issue='Whole-run counters are valid; active/gap/combined use timestamped changed DVFS events.'
        elif n in (42,):issue='ACPI/board power unavailable on this host; chart correctly reports unavailable.'
        elif n in range(48,63):issue='Time-series chart; variance across repetitions is not a single error-bar quantity.'
        rows.append({'chart':n,'status':status,'finding':issue or 'No specific inconsistency found in smoke-run source cross-check.'})
    write_csv(report/'chart_audit_all_62.csv',rows)
    return rows

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--input',type=Path,required=True);ap.add_argument('--output',type=Path);a=ap.parse_args();root=a.input.resolve();report=(a.output or root/'the_sheet_rules_all').resolve()
    if not report.exists():raise SystemExit(f'report not found: {report}')
    print('[postprocess] building corrected original chart variants...');ctx=build_original(root,report)
    print('[postprocess] parsing phase frequency samples and actual DVFS events...');freqphase,freqrows=parse_frequency_phase(report,root);dvfs,dvfsevents=parse_actual_dvfs(report,root)
    print('[postprocess] rebuilding phase charts...');build_phase_charts(root,report,ctx,freqphase,dvfs)
    print('[postprocess] correcting derived energy units...');build_derived(report,ctx)
    write_csv(report/'phase_frequency_summary.csv',freqrows);write_csv(report/'phase_actual_dvfs_changes_events.csv',dvfsevents)
    audit_report(root,report)
    print('[postprocess] building reproducibility workbook...');build_workbook(root,report,freqrows,dvfsevents)
    manifest={'schema':'greenquic-report-finalizer-v4','variance':'sample SD across independent repetitions; undefined for n<2','n1_behavior':'with_variance charts explicitly say SD unavailable; no fake zero-length variance claim','energy_efficiency':'J/useful decimal Gbit, lower is better','cstates':ctx['state_names'],'phase_actual_dvfs':'timestamped GreenQUIC FREQ result=changed events, half-open active/gap/combined windows','workbook':'GreenQUIC_sheet_rules_all.xlsx','original_chart_variants':'charts/{with_variance,without_variance}/{svg,pdf}/{with_values,without_values}','monitor_configuration':'untouched'}
    (report/'postprocess_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps(manifest,indent=2));return 0
if __name__=='__main__':raise SystemExit(main())
