#!/usr/bin/env python3
from __future__ import annotations
import argparse,csv,math,re,statistics,sys
from pathlib import Path
from typing import Any
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np

SCOPES=('active','gap','combined'); VERSIONS=('without_variance','with_variance')

def finite(v):
    try:
        x=float(v); return x if math.isfinite(x) else None
    except (TypeError,ValueError): return None

def stats(vals):
    a=[float(v) for v in vals if v is not None and math.isfinite(float(v))]; n=len(a)
    if not a:return {'n':0,'mean':None,'variance':None,'sd':None}
    mu=statistics.mean(a)
    if n<2:return {'n':n,'mean':mu,'variance':None,'sd':None}
    var=statistics.variance(a); return {'n':n,'mean':mu,'variance':var,'sd':math.sqrt(var)}

def per_mode(records,mode,getter): return [getter(rep,r) for (rep,m),r in sorted(records.items()) if m==mode]
def windows(r): return r.get('windows') or []
def duration(r,scope):
    w=windows(r)
    if not w:return None
    active=sum(max(0,b-a) for a,b in w)/1e9; combined=max(0,w[-1][1]-w[0][0])/1e9
    return active if scope=='active' else (max(0.0,combined-active) if scope=='gap' else combined)
def mean_dct(r):
    ds=[(b-a)/1e9 for a,b in windows(r) if b>=a]; return statistics.mean(ds) if ds else None
def phase_rapl(r,ep,scope,key):
    if scope in ('active','gap'): return finite((r.get(f'{ep}_{scope}') or {}).get(key))
    a=r.get(f'{ep}_active') or {}; g=r.get(f'{ep}_gap') or {}
    if key=='energy_j':
        x,y=finite(a.get(key)),finite(g.get(key)); return x+y if x is not None and y is not None else None
    if key=='power_w':
        ae,ad,ge,gd=map(finite,(a.get('energy_j'),a.get('duration_s'),g.get('energy_j'),g.get('duration_s')))
        return (ae+ge)/(ad+gd) if None not in (ae,ad,ge,gd) and ad+gd>0 else None
    return None

def norm(by,modes):
    off=[float(v) for v in by.get('off',[]) if v is not None and math.isfinite(float(v))]
    if not off:return {m:[None]*len(by.get(m,[])) for m in modes}
    d=statistics.mean(off)
    if d==0:return {m:[None]*len(by.get(m,[])) for m in modes}
    return {m:[float(v)/d if v is not None and math.isfinite(float(v)) else None for v in by.get(m,[])] for m in modes}
def combine(a,b): return [x+y if x is not None and y is not None else None for x,y in zip(a,b)]
def render_dir(root,ext,show): return root/ext/('with_values' if show else 'without_values')

def save_bar(root,num,name,title,ylabel,series,modes,names,variance,rows,scope,baseline=False):
    cache={label:[stats(by.get(m,[])) for m in modes] for label,by in series.items()}
    if not any(s['mean'] is not None for ss in cache.values() for s in ss): return
    for label,ss in cache.items():
        for m,s in zip(modes,ss): rows.append({'chart':num,'name':name,'scope':scope,'series':label,'mode':m,**s})
    for show in (True,False):
        fig,ax=plt.subplots(figsize=(15,8)); x=np.arange(len(modes)); width=min(.72/max(1,len(series)),.24); ymax=1.0 if baseline else 0.0
        for j,(label,_) in enumerate(series.items()):
            ss=cache[label]; means=[s['mean'] if s['mean'] is not None else np.nan for s in ss]; pos=x+(j-(len(series)-1)/2)*width
            err=[s['sd'] if variance and s['sd'] is not None else 0.0 for s in ss]
            bars=ax.bar(pos,means,width,label=label,yerr=err if variance else None,capsize=5 if variance else 0)
            for mu,e in zip(means,err):
                if math.isfinite(mu): ymax=max(ymax,mu+e)
            if show:
                for b,mu,s,e in zip(bars,means,ss,err):
                    if math.isfinite(mu):
                        txt=f"μ={mu:.2f}\nσ²={s['variance']:.3g}" if variance and s['variance'] is not None else f'{mu:.2f}'
                        ax.annotate(txt,(b.get_x()+b.get_width()/2,mu+e),xytext=(0,7),textcoords='offset points',ha='center',fontsize=7)
        if baseline: ax.axhline(1.0,ls='--',lw=1,alpha=.65)
        ax.set_xticks(x,[names[m] for m in modes]); ax.set_ylabel(ylabel); ax.set_title(title,pad=18,fontweight='normal'); ax.grid(axis='y',alpha=.3); ax.set_axisbelow(True); ax.set_ylim(0,max(1.15,ymax*(1.35 if show else 1.22)))
        if len(series)>1: ax.legend(loc='center left',bbox_to_anchor=(1.01,.5))
        fig.tight_layout()
        for ext in ('svg','pdf'):
            d=render_dir(root,ext,show); d.mkdir(parents=True,exist_ok=True); fig.savefig(d/f'{num:02d}_{name}.{ext}',bbox_inches='tight',dpi=300)
        plt.close(fig)

def save_scatter(root,num,name,title,xlabel,ylabel,xby,yby,modes,names,variance,rows,scope,origin=False):
    xs={m:stats(xby.get(m,[])) for m in modes}; ys={m:stats(yby.get(m,[])) for m in modes}
    for m in modes:
        rows += [{'chart':num,'name':name+'_x','scope':scope,'series':xlabel,'mode':m,**xs[m]},{'chart':num,'name':name+'_y','scope':scope,'series':ylabel,'mode':m,**ys[m]}]
    for show in (True,False):
        fig,ax=plt.subplots(figsize=(11,8))
        if origin: ax.axhline(0,ls='--',lw=.9,alpha=.45); ax.axvline(0,ls='--',lw=.9,alpha=.45)
        for m in modes:
            if xs[m]['mean'] is None or ys[m]['mean'] is None: continue
            xe=xs[m]['sd'] if variance else None; ye=ys[m]['sd'] if variance else None
            ax.errorbar(xs[m]['mean'],ys[m]['mean'],xerr=xe,yerr=ye,fmt='o',capsize=5 if variance else 0,label=names[m])
            if show: ax.annotate(f"{names[m]}\n({xs[m]['mean']:.2f}, {ys[m]['mean']:.2f})",(xs[m]['mean'],ys[m]['mean']),xytext=(8,8),textcoords='offset points',fontsize=8)
        ax.set_xlabel(xlabel); ax.set_ylabel(ylabel); ax.set_title(title,pad=18,fontweight='normal'); ax.grid(alpha=.3); ax.legend(loc='center left',bbox_to_anchor=(1.01,.5)); fig.tight_layout()
        for ext in ('svg','pdf'):
            d=render_dir(root,ext,show); d.mkdir(parents=True,exist_ok=True); fig.savefig(d/f'{num:02d}_{name}.{ext}',bbox_inches='tight',dpi=300)
        plt.close(fig)

def write_stats(path,rows):
    cols=['chart','name','scope','series','mode','n','mean','variance','sd']; path.parent.mkdir(parents=True,exist_ok=True)
    with path.open('w',newline='',encoding='utf-8') as f:
        w=csv.DictWriter(f,fieldnames=cols); w.writeheader(); w.writerows({k:r.get(k) for k in cols} for r in rows)

def idx(rows):
    out={}
    for row in rows:
        rep=finite(row.get('repetition')); mode=str(row.get('mode','')).lower()
        if rep is not None and mode: out[(int(rep),mode)]=row
    return out

def metric(base,table,rep,mode,*parts): return base.field(table.get((rep,mode)),*parts)
def payload(base,clients,rep,mode): return metric(base,clients,rep,mode,'total','payload') or metric(base,clients,rep,mode,'payload','gib')
def p_gbit(gib): return gib*8*(2**30)/1e9 if gib is not None and gib>0 else None

def freq_values(old,record,bundle,ep,scope,kind): return old.freq_metric(record,bundle,ep,scope,kind)

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--input',type=Path,required=True); ap.add_argument('--output',type=Path); ap.add_argument('--reporter-dir',type=Path,required=True); a=ap.parse_args()
    sys.path.insert(0,str(a.reporter_dir.resolve())); import build_sheet_rules_all_aligned as aligned
    base=aligned.base; modes=base.MODES; names=base.MODE_NAMES; root=a.input.resolve(); report=(a.output or root/'the_sheet_rules_all').resolve(); records=base.raw_data(root); files=base.discover_files(root); tables=base.load_tables(root); clients=idx(tables['client_runs']); servers=idx(tables['server_runs'])
    common=a.reporter_dir.resolve().parents[2]/'common'/'bin'; sys.path.insert(0,str(common)); import build_newchart_variants as old
    payloads={m:[payload(base,clients,rep,m) for (rep,mm),_ in sorted(records.items()) if mm==m] for m in modes}; gbits={m:[p_gbit(v) for v in payloads[m]] for m in modes}; dcts={m:per_mode(records,m,lambda rep,r:mean_dct(r)) for m in modes}
    allrows=[]
    for scope in SCOPES:
      for version in VERSIONS:
        variance=version=='with_variance'; xdest=report/'x_msquic_dpdk'/scope/version; ddest=report/'derived'/scope/version; xr=[]; dr=[]
        dur={m:per_mode(records,m,lambda rep,r,s=scope:duration(r,s)) for m in modes}
        se={m:per_mode(records,m,lambda rep,r,s=scope:phase_rapl(r,'server',s,'energy_j')) for m in modes}; ce={m:per_mode(records,m,lambda rep,r,s=scope:phase_rapl(r,'client',s,'energy_j')) for m in modes}; coe={m:combine(se[m],ce[m]) for m in modes}
        sp={m:per_mode(records,m,lambda rep,r,s=scope:phase_rapl(r,'server',s,'power_w')) for m in modes}; cp={m:per_mode(records,m,lambda rep,r,s=scope:phase_rapl(r,'client',s,'power_w')) for m in modes}; cop={m:combine(sp[m],cp[m]) for m in modes}
        save_bar(xdest,6,'duration_x_baseline',f'{scope.title()} duration — × MsQuic-DPDK','× baseline',{'Duration':norm(dur,modes)},modes,names,variance,xr,scope,True)
        save_bar(xdest,7,'average_rapl_power_x_baseline',f'{scope.title()} average RAPL power — × MsQuic-DPDK','× baseline',{k:norm(v,modes) for k,v in {'Server':sp,'Client':cp,'Combined':cop}.items()},modes,names,variance,xr,scope,True)
        save_bar(xdest,8,'rapl_energy_x_baseline',f'{scope.title()} RAPL energy — × MsQuic-DPDK','× baseline',{k:norm(v,modes) for k,v in {'Server':se,'Client':ce,'Combined':coe}.items()},modes,names,variance,xr,scope,True)
        if scope=='active':
            gp={m:[metric(base,clients,rep,m,'goodput','excluding','gaps') for (rep,mm),_ in sorted(records.items()) if mm==m] for m in modes}; save_bar(xdest,4,'active_goodput_x_baseline','Active goodput — × MsQuic-DPDK','× baseline',{'Goodput':norm(gp,modes)},modes,names,variance,xr,scope,True)
            save_bar(xdest,44,'active_rapl_power_x_baseline','Active-transfer RAPL power — × MsQuic-DPDK','× baseline',{k:norm(v,modes) for k,v in {'Server':sp,'Client':cp,'Combined':cop}.items()},modes,names,variance,xr,scope,True); save_bar(xdest,46,'active_rapl_energy_x_baseline','Active-transfer RAPL energy — × MsQuic-DPDK','× baseline',{k:norm(v,modes) for k,v in {'Server':se,'Client':ce,'Combined':coe}.items()},modes,names,variance,xr,scope,True)
        if scope=='gap':
            save_bar(xdest,45,'gap_rapl_power_x_baseline','Inter-download gap RAPL power — × MsQuic-DPDK','× baseline',{k:norm(v,modes) for k,v in {'Server':sp,'Client':cp,'Combined':cop}.items()},modes,names,variance,xr,scope,True); save_bar(xdest,47,'gap_rapl_energy_x_baseline','Inter-download gap RAPL energy — × MsQuic-DPDK','× baseline',{k:norm(v,modes) for k,v in {'Server':se,'Client':ce,'Combined':coe}.items()},modes,names,variance,xr,scope,True)
        if scope=='combined':
            gp={m:[metric(base,clients,rep,m,'goodput','including','gaps') for (rep,mm),_ in sorted(records.items()) if mm==m] for m in modes}; save_bar(xdest,5,'gap_inclusive_goodput_x_baseline','Gap-inclusive goodput — × MsQuic-DPDK','× baseline',{'Goodput':norm(gp,modes)},modes,names,variance,xr,scope,True)
            packets={}
            for ep,t in (('Client',clients),('Server',servers)):
                for d in ('RX','TX'):
                    raw={m:[metric(base,t,rep,m,'dpdk',d,'packets') or metric(base,t,rep,m,d,'packets') for (rep,mm),_ in sorted(records.items()) if mm==m] for m in modes}; packets[f'{ep} {d}']=norm(raw,modes)
            save_bar(xdest,41,'dpdk_packet_counts_x_baseline','DPDK packet counts — × MsQuic-DPDK','× baseline',packets,modes,names,variance,xr,scope,True)
        if scope in ('active','combined'):
            epg={label:{m:[e/p if e is not None and p is not None and p>0 else None for e,p in zip(src[m],payloads[m])] for m in modes} for label,src in {'Server':se,'Client':ce,'Combined':coe}.items()}; save_bar(xdest,9,'energy_per_gib_x_baseline',f'{scope.title()} RAPL energy per GiB — × MsQuic-DPDK','× baseline',{k:norm(v,modes) for k,v in epg.items()},modes,names,variance,xr,scope,True)
        for num,ep in ((29,'server'),(30,'client')):
            ser={}
            for kind,label in (('min','Min'),('max','Max')):
                raw={m:[freq_values(old,r,files.get((ep,rep,m),{}),ep,scope,kind) for (rep,mm),r in sorted(records.items()) if mm==m] for m in modes}; ser[label]=norm(raw,modes)
            save_bar(xdest,num,f'{ep}_frequency_x_baseline',f'{scope.title()} — {ep.title()} frequency — × MsQuic-DPDK','× baseline',ser,modes,names,variance,xr,scope,True)
        if scope=='active': save_bar(ddest,1,'download_completion_time','Mean download completion time (D1–D5)','Seconds',{'DCT':dcts},modes,names,variance,dr,scope); save_bar(ddest,2,'total_active_transfer_time','Total active transfer time','Seconds',{'Active time':dur},modes,names,variance,dr,scope)
        elif scope=='gap': save_bar(ddest,1,'inter_download_gap_time','Total inter-download gap time','Seconds',{'Gap time':dur},modes,names,variance,dr,scope)
        else: save_bar(ddest,1,'workload_completion_time','Workload completion time (D1 start to D5 completion)','Seconds',{'Completion time':dur},modes,names,variance,dr,scope)
        if scope in ('active','combined'):
            eff={label:{m:[g/e if g is not None and e is not None and e>0 else None for g,e in zip(gbits[m],src[m])] for m in modes} for label,src in {'Server':se,'Client':ce,'Combined':coe}.items()}; save_bar(ddest,3,'energy_efficiency_gbit_per_j',f'{scope.title()} energy efficiency','Useful Gbit/J',eff,modes,names,variance,dr,scope)
            edp={label:{m:[e*t if e is not None and t is not None else None for e,t in zip(src[m],dur[m])] for m in modes} for label,src in {'Server':se,'Client':ce,'Combined':coe}.items()}; save_bar(ddest,4,'energy_delay_product',f'{scope.title()} energy–delay product','J·s',edp,modes,names,variance,dr,scope); save_bar(ddest,5,'normalized_energy_delay_product',f'{scope.title()} EDP — × MsQuic-DPDK','× baseline',{k:norm(v,modes) for k,v in edp.items()},modes,names,variance,dr,scope,True)
            xt=dcts if scope=='active' else dur; save_scatter(ddest,6,'energy_efficiency_vs_completion_time',f'{scope.title()} energy efficiency vs completion time','Mean DCT (s)' if scope=='active' else 'Workload completion time (s)','Combined useful Gbit/J',xt,eff['Combined'],modes,names,variance,dr,scope)
            tn=norm(xt,modes); en=norm(coe,modes); to={m:[(v-1)*100 if v is not None else None for v in tn[m]] for m in modes}; es={m:[(1-v)*100 if v is not None else None for v in en[m]] for m in modes}; save_scatter(ddest,7,'energy_saving_vs_completion_overhead',f'{scope.title()} energy saving vs completion-time overhead','DCT overhead (%)' if scope=='active' else 'Workload-time overhead (%)','Combined energy saving (%)',to,es,modes,names,variance,dr,scope,True)
        else:
            etp={label:{m:[e*t if e is not None and t is not None else None for e,t in zip(src[m],dur[m])] for m in modes} for label,src in {'Server':se,'Client':ce,'Combined':coe}.items()}; save_bar(ddest,2,'gap_energy_time_product','Inter-download gap energy–time product','J·s',etp,modes,names,variance,dr,scope); save_bar(ddest,3,'normalized_gap_energy_time_product','Inter-download gap energy–time product — × MsQuic-DPDK','× baseline',{k:norm(v,modes) for k,v in etp.items()},modes,names,variance,dr,scope,True)
        write_stats(xdest/'statistics.csv',xr); write_stats(ddest/'statistics.csv',dr); allrows += xr+dr
    write_stats(report/'derived_and_normalized_statistics.csv',allrows); return 0
if __name__=='__main__': raise SystemExit(main())
