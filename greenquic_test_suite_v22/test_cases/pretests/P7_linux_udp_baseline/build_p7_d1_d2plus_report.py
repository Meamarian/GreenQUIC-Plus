#!/usr/bin/env python3
from __future__ import annotations
import argparse,csv,json,math,statistics,bisect
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np

EXPECTED_BASE=18
EXTRA_COUNT=6
PAYLOAD_DEFAULT=8*1024**3

def fnum(x):
    try:
        v=float(x);return v if math.isfinite(v) else None
    except:return None
def stat(xs):
    a=[float(x) for x in xs if fnum(x) is not None]
    return {'n':len(a),'mean':statistics.mean(a) if a else None,'sd':statistics.stdev(a) if len(a)>1 else (0.0 if a else None),'min':min(a) if a else None,'max':max(a) if a else None}
def rows(path):
    if not path.is_file():return []
    ls=[l for l in path.read_text(errors='replace').splitlines() if l and not l.startswith('#')]
    return list(csv.DictReader(ls)) if ls else []
def read_rapl(path):
    R=rows(path);o=[]
    for r in R:
        t=fnum(r.get('sample_monotonic_ns'));dt=fnum(r.get('actual_interval_ms'));pk=fnum(r.get('package_delta_j'));dr=fnum(r.get('dram_delta_j')) or 0
        if None in (t,dt,pk) or dt<=0:continue
        o.append((int(t),int(t+dt*1e6),pk,dr))
    return o
def integrate(tr,wins):
    e=pk=dr=dur=0.
    for a,b,p,d in tr:
      for x,y in wins:
        ov=max(0,min(b,y)-max(a,x))
        if ov:
          frac=ov/(b-a);e+=(p+d)*frac;pk+=p*frac;dr+=d*frac;dur+=ov/1e9
    return {'energy_j':e if dur else None,'package_j':pk if dur else None,'dram_j':dr if dur else None,'duration_s':dur,'power_w':e/dur if dur else None}
def read_freq(path):
    o=[]
    if not path.is_file():return o
    for l in path.read_text(errors='replace').splitlines():
      try:r=json.loads(l)
      except:continue
      t=fnum(r.get('monotonic_ns'));khz=fnum(r.get('freq_khz'));cpu=fnum(r.get('cpu'))
      if None not in (t,khz):o.append((int(t),int(cpu or 0),khz/1e6))
    return o
def frequency(v,wins):
    a=[x for t,c,x in v if any(s<=t<=e for s,e in wins)]
    return {'mean_ghz':statistics.mean(a) if a else None,'min_ghz':min(a) if a else None,'max_ghz':max(a) if a else None,'changes':sum(x!=y for x,y in zip(a,a[1:])) if a else None}
def bridge_from_summary(run):
    # P7 cstate.csv is mono_raw. cstate_mapping.json carries bridge when available.
    p=run/'cstate_mapping.json'
    if p.is_file():
      try:
        d=json.load(open(p));
        # accept common scalar offset schemas
        for k in ('offset_ns','mono_minus_raw_ns','monotonic_minus_raw_ns'):
          if fnum(d.get(k)) is not None:
            off=int(d[k]);return lambda raw:int(raw)+off
        if all(k in d for k in ('start_monotonic_ns','start_monotonic_raw_ns')):
          off=int(d['start_monotonic_ns'])-int(d['start_monotonic_raw_ns']);return lambda raw:int(raw)+off
      except:pass
    # frequency often carries clock_bridge
    fp=run/'frequency.jsonl'; bridges=[]
    if fp.is_file():
      for l in fp.read_text(errors='replace').splitlines():
       try:r=json.loads(l)
       except:continue
       if r.get('type')=='clock_bridge' and fnum(r.get('monotonic_ns')) is not None and fnum(r.get('monotonic_raw_ns')) is not None:bridges.append(r)
    if bridges:
      b=bridges[0];off=int(b['monotonic_ns'])-int(b['monotonic_raw_ns']);return lambda raw:int(raw)+off
    return None
def read_cstate(run):
    p=run/'cstate.csv';conv=bridge_from_summary(run);R=rows(p)
    if not R or not conv:return []
    out=[]
    for r in R:
      t=fnum(r.get('timestamp_mono_raw_ns'));d=fnum(r.get('idle_duration_ns'));s=fnum(r.get('previous_state'))
      if None in (t,d,s) or d<=0 or s<0:continue
      out.append((conv(int(t-d)),conv(int(t)),int(s)))
    return out
def cstate(v,wins):
    starts=[x[0] for x in v];by={0:0.,1:0.,2:0.,3:0.};fr=0;dur=sum(e-s for s,e in wins)/1e9
    for s,e in wins:
      j=max(0,bisect.bisect_left(starts,s)-1)
      while j<len(v):
        a,b,st=v[j]
        if a>=e:break
        ov=max(0,min(b,e)-max(a,s))
        if ov:by[st]=by.get(st,0)+ov/1e9;fr+=1
        j+=1
    idle=sum(by.values());return {'by':by,'idle_s':idle,'idle_pct':idle/dur*100 if dur else None,'fragments':fr}
def group_windows(ws):
    gap=[(ws[i][1],ws[i+1][0]) for i in range(len(ws)-1)]
    return {'d1':ws[:1],'d2plus':ws[1:],'g1':gap[:1],'g2plus':gap[1:],
            'cycle1':[(ws[0][0],ws[1][0])] if len(ws)>1 else ws[:1],
            'cycle2plus':[(ws[i][0],ws[i+1][0]) for i in range(1,len(ws)-1)]}
def discover(root):
    rec=[]
    cr=root/'runs/client';sr=root/'runs/server'
    for c in sorted(cr.glob('rep*')):
      if not c.is_dir():continue
      try:rep=int(c.name.replace('rep',''))
      except:continue
      s=sr/c.name
      if not (c/'summary.json').is_file():continue
      cd=json.load(open(c/'summary.json'));sd=json.load(open(s/'summary.json')) if (s/'summary.json').is_file() else {}
      cws=[tuple(map(int,x)) for x in cd.get('windows',{}).get('active',[])];sws=[tuple(map(int,x)) for x in sd.get('windows',{}).get('active',[])]
      if len(cws)<2:continue
      rec.append({'rep':rep,'payload':int(cd.get('payload_bytes_per_download',PAYLOAD_DEFAULT)),
        'client':{'run':c,'summary':cd,'g':group_windows(cws),'rapl':read_rapl(c/'rapl.csv'),'freq':read_freq(c/'frequency.jsonl'),'cstate':read_cstate(c)},
        'server':{'run':s,'summary':sd,'g':group_windows(sws) if sws else group_windows(cws),'rapl':read_rapl(s/'rapl.csv') if s.exists() else [],'freq':read_freq(s/'frequency.jsonl') if s.exists() else [],'cstate':read_cstate(s) if s.exists() else []}})
    return rec
def endpoint_metric(r,ep,grp,metric):
    E=r[ep];wins=E['g'][grp];n=max(1,len(wins));cache=E.setdefault('_cache',{})
    if ('rapl',grp) not in cache:cache[('rapl',grp)]=integrate(E['rapl'],wins)
    if ('freq',grp) not in cache:cache[('freq',grp)]=frequency(E['freq'],wins)
    if ('cstate',grp) not in cache:cache[('cstate',grp)]=cstate(E['cstate'],wins)
    if metric in ('energy_j','package_j','dram_j'):v=cache[('rapl',grp)][metric];return v/n if v is not None else None
    if metric=='power_w':return cache[('rapl',grp)]['power_w']
    if metric in ('mean_ghz','min_ghz','max_ghz','changes'):return cache[('freq',grp)][metric]
    if metric=='idle_s':return cache[('cstate',grp)]['idle_s']/n
    if metric=='idle_pct':return cache[('cstate',grp)]['idle_pct']
    if metric=='fragments':return cache[('cstate',grp)]['fragments']/n
    if metric.startswith('state'):
      st=int(metric[-1]);return cache[('cstate',grp)]['by'].get(st,0)/n
    return None
def combined(r,grp,metric):
    vals=[endpoint_metric(r,e,grp,metric) for e in ('client','server')];vals=[x for x in vals if x is not None]
    return sum(vals) if vals else None
def goodput(r,grp,ep='client'):
    wins=r[ep]['g'][grp];dur=sum(e-s for s,e in wins)/1e9
    return len(wins)*r['payload']*8/dur/1e9 if dur else None
def stmap(rec,func):return {g:stat(func(r,g) for r in rec) for g in ('d1','d2plus')}
def bar(out,i,name,title,ylabel,S):
    for var in (False,True):
      fig,ax=plt.subplots(figsize=(10,7));x=np.arange(2);means=[S[g]['mean'] for g in ('d1','d2plus')];ys=[np.nan if v is None else v for v in means];err=[S[g]['sd'] or 0 for g in ('d1','d2plus')]
      b=ax.bar(x,ys,yerr=err if var else None,capsize=5 if var else 0);ax.set_xticks(x,['D1','D2+ mean per later download']);ax.set_ylabel(ylabel);ax.set_title(title);ax.grid(axis='y',alpha=.25);ax.set_axisbelow(True);ax.set_ylim(bottom=0)
      for q,v in zip(b,means):
       if v is not None:ax.annotate(f'{v:.2f}',(q.get_x()+q.get_width()/2,q.get_height()),xytext=(0,6),textcoords='offset points',ha='center')
      p=out/('with_variance' if var else 'without_variance');(p/'svg').mkdir(parents=True,exist_ok=True);(p/'pdf').mkdir(parents=True,exist_ok=True);fig.savefig(p/'svg'/f'{i:02d}_{name}.svg',bbox_inches='tight');fig.savefig(p/'pdf'/f'{i:02d}_{name}.pdf',bbox_inches='tight');plt.close(fig)
def ts_power(rec,out,i,name,title,ep):
    for var in (False,True):
      fig,ax=plt.subplots(figsize=(12,7));made=False
      for grp,lab in [('d1','D1'),('d2plus','D2+')]:
        curves=[]
        for r in rec:
          E=r[ep]
          for s,e in E['g'][grp]:
            pts=[]
            for a,b,pk,dr in E['rapl']:
              if s<=a<=e:pts.append(((a-s)/1e9,(pk+dr)/((b-a)/1e9)))
            if len(pts)>2:curves.append((np.array([x for x,y in pts]),np.array([y for x,y in pts])))
        if not curves:continue
        mx=min(x[-1] for x,y in curves);grid=np.arange(0,mx,.05)
        if len(grid)<2:continue
        A=np.vstack([np.interp(grid,x,y) for x,y in curves]);mu=A.mean(0);sd=A.std(0,ddof=1) if len(A)>1 else np.zeros_like(mu);ax.plot(grid,mu,label=lab);made=True
        if var:ax.fill_between(grid,mu-sd,mu+sd,alpha=.15)
      if made:ax.set_xlabel('Elapsed from request start (s)');ax.set_ylabel('RAPL power (W)');ax.set_title(title);ax.grid(alpha=.25);ax.legend()
      else:ax.axis('off');ax.text(.5,.5,'No RAPL samples',ha='center')
      p=out/('with_variance' if var else 'without_variance');(p/'svg').mkdir(parents=True,exist_ok=True);(p/'pdf').mkdir(parents=True,exist_ok=True);fig.savefig(p/'svg'/f'{i:02d}_{name}.svg',bbox_inches='tight');fig.savefig(p/'pdf'/f'{i:02d}_{name}.pdf',bbox_inches='tight');plt.close(fig)
def ts_freq(rec,out,i,name,title,ep):
    for var in (False,True):
      fig,ax=plt.subplots(figsize=(12,7));made=False
      for grp,lab in [('d1','D1'),('d2plus','D2+')]:
        curves=[]
        for r in rec:
          E=r[ep]
          for s,e in E['g'][grp]:
            pts=[((t-s)/1e9,v) for t,c,v in E['freq'] if s<=t<=e]
            if len(pts)>2:curves.append((np.array([x for x,y in pts]),np.array([y for x,y in pts])))
        if not curves:continue
        mx=min(x[-1] for x,y in curves);grid=np.arange(0,mx,.05)
        if len(grid)<2:continue
        A=np.vstack([np.interp(grid,x,y) for x,y in curves]);mu=A.mean(0);sd=A.std(0,ddof=1) if len(A)>1 else np.zeros_like(mu);ax.plot(grid,mu,label=lab);made=True
        if var:ax.fill_between(grid,mu-sd,mu+sd,alpha=.15)
      if made:ax.set_xlabel('Elapsed from request start (s)');ax.set_ylabel('Frequency (GHz)');ax.set_title(title);ax.grid(alpha=.25);ax.legend()
      else:ax.axis('off');ax.text(.5,.5,'No frequency samples',ha='center')
      p=out/('with_variance' if var else 'without_variance');(p/'svg').mkdir(parents=True,exist_ok=True);(p/'pdf').mkdir(parents=True,exist_ok=True);fig.savefig(p/'svg'/f'{i:02d}_{name}.svg',bbox_inches='tight');fig.savefig(p/'pdf'/f'{i:02d}_{name}.pdf',bbox_inches='tight');plt.close(fig)
def main():
    ap=argparse.ArgumentParser();ap.add_argument('--input',required=True);ap.add_argument('--output');a=ap.parse_args();root=Path(a.input).resolve();out=Path(a.output).resolve() if a.output else root/'the_sheet_rules_all'/'d1_d2plus';out.mkdir(parents=True,exist_ok=True);rec=discover(root)
    if not rec:raise SystemExit('ERROR: no P7 repetitions with >=2 active windows')
    statsrows=[];audit=[]
    def emit(i,name,title,unit,func):
      S=stmap(rec,func);bar(out,i,name,title,unit,S);audit.append({'chart':i,'name':name,'available':int(any(S[g]['n'] for g in S))})
      for g,z in S.items():statsrows.append({'chart':i,'name':name,'group':g,**z})
    emit(1,'active_goodput','Linux active goodput: D1 vs D2+','Gbit/s',goodput)
    emit(2,'gap_inclusive_goodput','Linux position-cycle goodput','Gbit/s',lambda r,g:goodput(r,'cycle1' if g=='d1' else 'cycle2plus'))
    emit(3,'active_energy','Combined endpoint active RAPL energy per download','J/download',lambda r,g:combined(r,g,'energy_j'))
    emit(4,'gap_energy','Combined endpoint following-gap RAPL energy','J/gap',lambda r,g:combined(r,'g1' if g=='d1' else 'g2plus','energy_j'))
    emit(5,'combined_energy','Combined endpoint position-cycle RAPL energy','J/cycle',lambda r,g:combined(r,'cycle1' if g=='d1' else 'cycle2plus','energy_j'))
    emit(6,'active_power','Combined endpoint active RAPL power','W',lambda r,g:combined(r,g,'power_w'))
    emit(7,'gap_power','Combined endpoint following-gap RAPL power','W',lambda r,g:combined(r,'g1' if g=='d1' else 'g2plus','power_w'))
    emit(8,'combined_power','Combined endpoint position-cycle RAPL power','W',lambda r,g:combined(r,'cycle1' if g=='d1' else 'cycle2plus','power_w'))
    emit(9,'active_energy_efficiency','Active energy cost','J/Gbit',lambda r,g:combined(r,g,'energy_j')/(r['payload']*8/1e9) if combined(r,g,'energy_j') is not None else None)
    emit(10,'combined_energy_efficiency','Position-cycle energy cost','J/Gbit',lambda r,g:combined(r,'cycle1' if g=='d1' else 'cycle2plus','energy_j')/(r['payload']*8/1e9) if combined(r,'cycle1' if g=='d1' else 'cycle2plus','energy_j') is not None else None)
    emit(11,'active_frequency','Mean active CPU frequency (server+client sum)','GHz (sum endpoints)',lambda r,g:combined(r,g,'mean_ghz'))
    emit(12,'gap_frequency','Mean following-gap CPU frequency (server+client sum)','GHz (sum endpoints)',lambda r,g:combined(r,'g1' if g=='d1' else 'g2plus','mean_ghz'))
    emit(13,'combined_frequency','Mean position-cycle CPU frequency (server+client sum)','GHz (sum endpoints)',lambda r,g:combined(r,'cycle1' if g=='d1' else 'cycle2plus','mean_ghz'))
    ts_power(rec,out,14,'server_rapl_over_time','Linux server RAPL power aligned to request start','server');audit.append({'chart':14,'name':'server_rapl_over_time','available':1})
    ts_power(rec,out,15,'client_rapl_over_time','Linux client RAPL power aligned to request start','client');audit.append({'chart':15,'name':'client_rapl_over_time','available':1})
    ts_freq(rec,out,16,'server_frequency_over_time','Linux server frequency aligned to request start','server');audit.append({'chart':16,'name':'server_frequency_over_time','available':1})
    ts_freq(rec,out,17,'client_frequency_over_time','Linux client frequency aligned to request start','client');audit.append({'chart':17,'name':'client_frequency_over_time','available':1})
    emit(18,'duration_breakdown','Linux active duration per download','s/download',lambda r,g:sum(e-s for s,e in r['client']['g'][g])/1e9/max(1,len(r['client']['g'][g])))
    # extras 19-24
    emit(19,'server_active_idle','Server active idle time','s/download',lambda r,g:endpoint_metric(r,'server',g,'idle_s'))
    emit(20,'client_active_idle','Client active idle time','s/download',lambda r,g:endpoint_metric(r,'client',g,'idle_s'))
    emit(21,'server_gap_idle','Server following-gap idle time','s/gap',lambda r,g:endpoint_metric(r,'server','g1' if g=='d1' else 'g2plus','idle_s'))
    emit(22,'client_gap_idle','Client following-gap idle time','s/gap',lambda r,g:endpoint_metric(r,'client','g1' if g=='d1' else 'g2plus','idle_s'))
    emit(23,'combined_active_idle_fraction','Combined endpoint active idle fraction (sum)','percentage points',lambda r,g:combined(r,g,'idle_pct'))
    emit(24,'combined_active_idle_fragments','Combined endpoint active idle fragments','fragments/download',lambda r,g:combined(r,g,'fragments'))
    with open(out/'statistics.csv','w',newline='') as f:
      w=csv.DictWriter(f,fieldnames=['chart','name','group','n','mean','sd','min','max']);w.writeheader();w.writerows(statsrows)
    with open(out/'chart_availability.csv','w',newline='') as f:
      w=csv.DictWriter(f,fieldnames=['chart','name','available']);w.writeheader();w.writerows(sorted(audit,key=lambda x:x['chart']))
    (out/'manifest.json').write_text(json.dumps({'schema':'greenquic-p7-d1-d2plus-v1','base_charts':18,'extra_charts':6,'total_charts':24,'repetitions':len(rec),'semantics':{'d1':'first download','d2plus':'later downloads; additive metrics normalized per later download','cycle':'D1+G1 vs later downloads with a following gap; final no-gap download excluded'}},indent=2))
    print(f'P7 D1/D2+ report created: {out}');print('charts=24 repetitions='+str(len(rec)))
if __name__=='__main__':main()
