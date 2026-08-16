#!/usr/bin/env python3
"""Precision D1/D2+ Linux/P7 report wrapper.

V3 uses interval-end RAPL semantics, time-weighted frequency state, overlap-aware
edge plotting, and emits a strict recorder/cadence quality report.
"""
from __future__ import annotations
import importlib.util,json,math,statistics,sys
from pathlib import Path

HERE=Path(__file__).resolve().parent
BASE=HERE/'build_p7_d1_d2plus_report.py'
spec=importlib.util.spec_from_file_location('gq_p7_d1d2_base_v3',BASE)
if spec is None or spec.loader is None:raise SystemExit(f'ERROR: cannot import {BASE}')
mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
MAX_RAPL_P95_MS=15.0;MAX_FREQ_P95_MS=5.0
LAST_REC=[]


def pct(values,p):
    a=sorted(float(x) for x in values if x is not None and math.isfinite(float(x)))
    if not a:return None
    if len(a)==1:return a[0]
    k=(len(a)-1)*p/100;i=int(math.floor(k));j=min(i+1,len(a)-1);f=k-i
    return a[i]*(1-f)+a[j]*f


def read_rapl(path):
    R=mod.rows(path);o=[]
    for r in R:
        end=mod.fnum(r.get('sample_monotonic_ns'));dt=mod.fnum(r.get('actual_interval_ms'));pk=mod.fnum(r.get('package_delta_j'));dr=mod.fnum(r.get('dram_delta_j')) or 0
        if None in (end,dt,pk) or dt<=0:continue
        start=int(round(end-dt*1_000_000.0));o.append((start,int(end),pk,dr))
    return o


def _cells(rows):
    rows=sorted(rows)
    if not rows:return []
    if len(rows)==1:return [(rows[0][0]-500_000,rows[0][0]+500_000,rows[0][1])]
    out=[]
    for i,(t,v) in enumerate(rows):
        l=(rows[i-1][0]+t)//2 if i else t-(rows[1][0]-t)//2
        rr=(t+rows[i+1][0])//2 if i+1<len(rows) else t+(t-rows[i-1][0])//2
        if rr>l:out.append((l,rr,v))
    return out


def frequency(v,wins):
    if not v or not wins:return {'mean_ghz':None,'min_ghz':None,'max_ghz':None,'changes':None}
    by={}
    for t,c,x in v:by.setdefault(c,[]).append((int(t),float(x)))
    total=0.0;dur=0;seen=[];changes=0
    for rows in by.values():
        rows=sorted(rows)
        for s,e in wins:
            for a,b,x in _cells(rows):
                ov=max(0,min(b,e)-max(a,s))
                if ov:total+=x*ov;dur+=ov;seen.append(x)
            for (t0,x0),(t1,x1) in zip(rows,rows[1:]):
                if x0!=x1 and s <= (t0+t1)//2 < e:changes+=1
    return {'mean_ghz':total/dur if dur else None,'min_ghz':min(seen) if seen else None,'max_ghz':max(seen) if seen else None,'changes':changes if dur else None}


def ts_power(rec,out,i,name,title,ep):
    for var in (False,True):
      fig,ax=mod.plt.subplots(figsize=(12,7));made=False
      for grp,lab in [('d1','D1'),('d2plus','D2+')]:
        curves=[]
        for r in rec:
          E=r[ep]
          for s,e in E['g'][grp]:
            pts=[]
            for a,b,pk,dr in E['rapl']:
              lo=max(a,s);hi=min(b,e)
              if hi>lo:pts.append(((((lo+hi)//2)-s)/1e9,(pk+dr)/((b-a)/1e9)))
            if len(pts)>2:curves.append((mod.np.array([x for x,y in pts]),mod.np.array([y for x,y in pts])))
        if not curves:continue
        mx=min(x[-1] for x,y in curves);grid=mod.np.arange(0,mx,.05)
        if len(grid)<2:continue
        A=mod.np.vstack([mod.np.interp(grid,x,y) for x,y in curves]);mu=A.mean(0);sd=A.std(0,ddof=1) if len(A)>1 else mod.np.zeros_like(mu);ax.plot(grid,mu,label=lab);made=True
        if var:ax.fill_between(grid,mu-sd,mu+sd,alpha=.15)
      if made:ax.set_xlabel('Elapsed from request start (s)');ax.set_ylabel('RAPL power (W)');ax.set_title(title);ax.grid(alpha=.25);ax.legend()
      else:ax.axis('off');ax.text(.5,.5,'No RAPL samples',ha='center')
      p=out/('with_variance' if var else 'without_variance');(p/'svg').mkdir(parents=True,exist_ok=True);(p/'pdf').mkdir(parents=True,exist_ok=True);fig.savefig(p/'svg'/f'{i:02d}_{name}.svg',bbox_inches='tight');fig.savefig(p/'pdf'/f'{i:02d}_{name}.pdf',bbox_inches='tight');mod.plt.close(fig)


def ts_freq(rec,out,i,name,title,ep):
    def hold_values(rows,grid_ns,start_ns):
        rows=sorted(rows)
        if not rows:return None
        ts=mod.np.array([t for t,v in rows],dtype=mod.np.int64);vs=mod.np.array([v for t,v in rows],dtype=float)
        targets=start_ns+(grid_ns*1e9).astype(mod.np.int64)
        idx=mod.np.searchsorted(ts,targets,side='right')-1
        if (idx<0).any():return None
        return vs[idx]
    for var in (False,True):
      fig,ax=mod.plt.subplots(figsize=(12,7));made=False
      for grp,lab in [('d1','D1'),('d2plus','D2+')]:
        curves=[]
        for r in rec:
          E=r[ep];by={}
          for t,c,v in E['freq']:by.setdefault(c,[]).append((int(t),float(v)))
          for s,e in E['g'][grp]:
            dur=(e-s)/1e9;grid=mod.np.arange(0,dur,.001)
            if len(grid)<2:continue
            cpu_curves=[]
            for rows in by.values():
                vals=hold_values(rows,grid,s)
                if vals is not None:cpu_curves.append(vals)
            if cpu_curves:curves.append((grid,mod.np.mean(mod.np.vstack(cpu_curves),axis=0)))
        if not curves:continue
        mx=min(x[-1] for x,y in curves);grid=mod.np.arange(0,mx,.05)
        if len(grid)<2:continue
        A=mod.np.vstack([mod.np.interp(grid,x,y) for x,y in curves]);mu=A.mean(0);sd=A.std(0,ddof=1) if len(A)>1 else mod.np.zeros_like(mu);ax.plot(grid,mu,label=lab);made=True
        if var:ax.fill_between(grid,mu-sd,mu+sd,alpha=.15)
      if made:ax.set_xlabel('Elapsed from request start (s)');ax.set_ylabel('Frequency (GHz)');ax.set_title(title);ax.grid(alpha=.25);ax.legend()
      else:ax.axis('off');ax.text(.5,.5,'No frequency samples',ha='center')
      p=out/('with_variance' if var else 'without_variance');(p/'svg').mkdir(parents=True,exist_ok=True);(p/'pdf').mkdir(parents=True,exist_ok=True);fig.savefig(p/'svg'/f'{i:02d}_{name}.svg',bbox_inches='tight');fig.savefig(p/'pdf'/f'{i:02d}_{name}.pdf',bbox_inches='tight');mod.plt.close(fig)


def discover(root):
    global LAST_REC
    LAST_REC=mod._original_discover(root)
    return LAST_REC


def bridge_uncertainty(path):
    vals=[]
    if path.is_file():
      for l in path.read_text(errors='replace').splitlines():
        try:r=json.loads(l)
        except:continue
        if r.get('type')=='clock_bridge' and mod.fnum(r.get('uncertainty_ns')) is not None:vals.append(int(r['uncertainty_ns']))
    return max(vals) if vals else None


def endpoint_quality(r,ep):
    E=r[ep];wins=E['g']['d1']+E['g']['d2plus'];first=min(s for s,e in wins);last=max(e for s,e in wins)
    rapl=E['rapl'];q={}
    if rapl:
        ms=[(b-a)/1e6 for a,b,pk,dr in rapl];q.update(rapl_coverage=rapl[0][0]<=first and rapl[-1][1]>=last,rapl_interval_median_ms=pct(ms,50),rapl_interval_p95_ms=pct(ms,95),rapl_interval_max_ms=max(ms))
    else:q.update(rapl_coverage=False,rapl_interval_median_ms=None,rapl_interval_p95_ms=None,rapl_interval_max_ms=None)
    freq=sorted(E['freq']);ts=sorted({t for t,c,x in freq});gaps=[(b-a)/1e6 for a,b in zip(ts,ts[1:]) if b>a]
    q.update(freq_coverage=bool(ts and ts[0]<=first and ts[-1]>=last),freq_gap_median_ms=pct(gaps,50),freq_gap_p95_ms=pct(gaps,95),freq_gap_max_ms=max(gaps) if gaps else None)
    q['clock_bridge_uncertainty_ns']=bridge_uncertainty(E['run']/'frequency.jsonl')
    spans=[]
    fp=E['run']/'frequency.jsonl'
    if fp.is_file():
      for l in fp.read_text(errors='replace').splitlines():
        try:rr=json.loads(l)
        except:continue
        if rr.get('type')=='line' and mod.fnum(rr.get('read_span_ns')) is not None:spans.append(float(rr['read_span_ns'])/2e6)
    q['freq_read_uncertainty_p95_ms']=pct(spans,95)
    q['pass']=bool(q['rapl_coverage'] and q['freq_coverage'] and q['rapl_interval_p95_ms'] is not None and q['rapl_interval_p95_ms']<=MAX_RAPL_P95_MS and (q['freq_gap_p95_ms'] is None or q['freq_gap_p95_ms']<=MAX_FREQ_P95_MS))
    return q


def write_quality(root,rec):
    rows=[];all_pass=True;durs=[];edges=[]
    for r in rec:
      durs.extend(e-s for s,e in r['client']['g']['d1']+r['client']['g']['d2plus'])
      row={'repetition':r['rep']};rp=True
      for ep in ('client','server'):
        q=endpoint_quality(r,ep);row[ep]=q;rp=rp and q['pass']
        rapl=(q.get('rapl_interval_p95_ms') or 0)*1e6;freq=(q.get('freq_gap_p95_ms') or 0)*1e6/2;read=(q.get('freq_read_uncertainty_p95_ms') or 0)*1e6;bridge=q.get('clock_bridge_uncertainty_ns') or 0
        edge=max(1000.0,rapl,freq+read,bridge);q['conservative_edge_uncertainty_ns']=int(edge);edges.append(edge)
      row['pass']=rp;all_pass=all_pass and rp;rows.append(row)
    md=pct(durs,50) or 0;edge=max(edges) if edges else 0;accuracy=100*(1-min(1,2*edge/md)) if md else None
    out={'schema':'greenquic-p7-d1d2plus-alignment-quality-v1','pass':all_pass,'thresholds':{'max_rapl_interval_p95_ms':MAX_RAPL_P95_MS,'max_frequency_gap_p95_ms':MAX_FREQ_P95_MS},'goodput_timestamp_quantization_us':1,'median_active_duration_ms':md/1e6 if md else None,'worst_conservative_edge_uncertainty_ms':edge/1e6 if edges else None,'temporal_alignment_accuracy_pct':accuracy,'accuracy_definition':'100*(1-2*worst_edge_uncertainty/median_active_duration); temporal/window alignment only, not Intel RAPL absolute electrical accuracy','records':rows}
    od=root/'the_sheet_rules_all'/'d1_d2plus';(od/'alignment_quality.json').write_text(json.dumps(out,indent=2)+'\n')
    p=od/'manifest.json'
    if p.is_file():
      d=json.loads(p.read_text());d['schema']='greenquic-p7-d1-d2plus-v3';d['alignment_quality_file']='alignment_quality.json';d['frequency_aggregation']='midpoint-cell time weighted';d['rapl_interval_semantics']='sample timestamp is interval end; clip [end-dt,end]';d['rapl_plot_edges']='overlap-aware, clipped interval midpoint';p.write_text(json.dumps(d,indent=2)+'\n')
    print(f"P7 ALIGNMENT QUALITY pass={int(all_pass)} temporal_accuracy_pct={accuracy:.6f}" if accuracy is not None else f"P7 ALIGNMENT QUALITY pass={int(all_pass)} accuracy=N/A")
    return all_pass

mod.read_rapl=read_rapl
mod.frequency=frequency
mod.ts_power=ts_power
mod.ts_freq=ts_freq
mod._original_discover=mod.discover
mod.discover=discover
mod.main()
root=None
for i,a in enumerate(sys.argv[1:]):
    if a=='--input' and i+2<=len(sys.argv[1:]):root=Path(sys.argv[1:][i+1]);break
if root is not None:
    ok=write_quality(root,LAST_REC);raise SystemExit(0 if ok else 4)
raise SystemExit(2)
