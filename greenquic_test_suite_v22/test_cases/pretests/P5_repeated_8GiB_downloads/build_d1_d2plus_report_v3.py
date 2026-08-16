#!/usr/bin/env python3
"""Precision D1/D2+ P5 report wrapper.

V3 fixes phase-edge attribution without changing the legacy 62-chart report:
- RAPL samples are interval-end records and are clipped as [end-dt,end].
- server CLOCK_MONOTONIC is mapped directly into the client MONOTONIC domain
  from clock_sync.py v2; zero-shift fallback is forbidden.
- frequency means are time-weighted from midpoint cells, not sample-count means.
- RAPL aligned plots include edge-overlap samples and place them at clipped
  interval midpoints.
- combined endpoint values require both endpoints.
- alignment_quality.json records coverage, cadence and a conservative temporal
  accuracy estimate for every repetition/mode.
"""
from __future__ import annotations
import importlib.util
import json
import math
import statistics
import sys
from pathlib import Path

HERE=Path(__file__).resolve().parent
BASE=HERE/'build_d1_d2plus_report.py'
spec=importlib.util.spec_from_file_location('gq_d1d2_base_v3',BASE)
if spec is None or spec.loader is None:
    raise SystemExit(f'ERROR: cannot import {BASE}')
mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)

MAX_CLOCK_UNCERTAINTY_NS=5_000_000
MAX_RAPL_P95_MS=15.0
MAX_FREQ_P95_MS=5.0
MAX_GET_RESIDUAL_SPREAD_NS=5_000_000
MAX_SNAPSHOT_EDGE_P95_MS=5.0
LAST_RECORDS={}


def pct(values,p):
    a=sorted(float(x) for x in values if x is not None and math.isfinite(float(x)))
    if not a:return None
    if len(a)==1:return a[0]
    k=(len(a)-1)*p/100.0;i=int(math.floor(k));j=min(i+1,len(a)-1);f=k-i
    return a[i]*(1-f)+a[j]*f


def read_msr(path,shift=0):
    rows=mod.read_csv(path)
    if not rows:return None
    T=[];DT=[];E=[];PK=[];DR=[]
    for r in rows:
        end_ns=mod.finite(r.get('sample_monotonic_ns'));dt_ms=mod.finite(r.get('actual_interval_ms'))
        pk=mod.finite(r.get('package_delta_j'));dr=mod.finite(r.get('dram_delta_j')) or 0
        if None in (end_ns,dt_ms,pk) or dt_ms<=0:continue
        start_ns=int(round(end_ns-dt_ms*1_000_000.0))+int(shift)
        T.append(start_ns);DT.append(dt_ms/1000.0);PK.append(pk);DR.append(dr);E.append(pk+dr)
    if not T:return None
    return {'t':mod.np.array(T,mod.np.int64),'dt':mod.np.array(DT,float),'e':mod.np.array(E,float),'pk':mod.np.array(PK,float),'dr':mod.np.array(DR,float)}


def _cpu_cells(rows):
    rows=sorted(rows)
    if not rows:return []
    if len(rows)==1:return [(rows[0][0]-500_000,rows[0][0]+500_000,rows[0][1])]
    out=[]
    for i,(t,v) in enumerate(rows):
        left=(rows[i-1][0]+t)//2 if i else t-(rows[1][0]-t)//2
        right=(t+rows[i+1][0])//2 if i+1<len(rows) else t+(t-rows[i-1][0])//2
        if right>left:out.append((left,right,v))
    return out


def freq_group(vals,wins):
    if not vals or not wins:return {'mean_ghz':None,'min_ghz':None,'max_ghz':None,'samples':0,'changes':None}
    bycpu={}
    for t,c,v in vals:bycpu.setdefault(c,[]).append((int(t),float(v)))
    weighted=0.0;covered=0;seen=[];sample_count=0;changes=0
    for rows in bycpu.values():
        rows=sorted(rows);cells=_cpu_cells(rows)
        for x,y in wins:
            for a,b,v in cells:
                ov=max(0,min(b,y)-max(a,x))
                if ov:
                    weighted+=v*ov;covered+=ov;seen.append(v);sample_count+=1
            for (t0,v0),(t1,v1) in zip(rows,rows[1:]):
                if v0!=v1 and x <= (t0+t1)//2 < y:changes+=1
    if not covered:return {'mean_ghz':None,'min_ghz':None,'max_ghz':None,'samples':0,'changes':None}
    return {'mean_ghz':weighted/covered,'min_ghz':min(seen),'max_ghz':max(seen),'samples':sample_count,'changes':changes}


def load_clock_sync(root,rep,mode):
    p=root/f'clock_sync_rep{rep:02d}_{mode}.json'
    if not p.is_file():return None
    try:d=json.loads(p.read_text())
    except Exception:return None
    off=mod.finite(d.get('client_minus_controller_monotonic_offset_ns'))
    unc=mod.finite(d.get('monotonic_uncertainty_ns'))
    if off is None or unc is None:return None
    return {'path':str(p),'shift_ns':int(off),'uncertainty_ns':int(unc),'rtt_ns':int(d.get('round_trip_ns',2*unc)),'offset_spread_ns':int(d.get('monotonic_offset_spread_ns',0)),'schema':d.get('schema')}


def get_residuals(client_ws,timeline,shift):
    gets=mod.server_get_times(timeline)
    n=min(len(client_ws),len(gets));
    if n<1:return []
    return [(gets[i]+shift)-client_ws[i][0] for i in range(n)]


def build_records(root):
    global LAST_RECORDS
    f=mod.discover(root);reps=sorted({r for role,r,m in f});records={}
    for rep in reps:
      for mode in mod.MODES:
        cb=f.get(('client',rep,mode));sb=f.get(('server',rep,mode))
        if not cb:continue
        met=mod.load_metrics(cb);ws=mod.windows(met)
        if len(ws)<2:continue
        gr=mod.groups(ws);sync=load_clock_sync(root,rep,mode)
        pre_ok=bool(sync and sync['uncertainty_ns']<=MAX_CLOCK_UNCERTAINTY_NS)
        shift=sync['shift_ns'] if pre_ok else None
        residuals=get_residuals(ws,sb.get('timeline') if sb else None,shift) if shift is not None and sb else []
        residual_spread=max(residuals)-min(residuals) if len(residuals)>1 else (0 if residuals else None)
        align_ok=bool(pre_ok and residuals and (residual_spread is None or residual_spread<=MAX_GET_RESIDUAL_SPREAD_NS))
        if not align_ok: shift=None
        align={'accepted':align_ok,'clock_sync':sync,'get_residual_ns':residuals,
               'get_residual_median_ns':int(statistics.median(residuals)) if residuals else None,
               'get_residual_spread_ns':residual_spread}
        rec={'rep':rep,'mode':mode,'metrics':met,'windows':ws,'groups':gr,'server_shift':shift,'server_alignment':align}
        b=cb
        fv,fb=mod.read_freq(b.get('freq'),0)
        rec['client']={'bundle':b,'rapl':read_msr(b.get('msr'),0),'freq_vals':fv,'freq_bridge':fb,
            'cstate_summary':mod.read_cstate_group_summaries(b.get('cstate'),b.get('freq'),0,gr),'snap':mod.parse_snapshots(b.get('log')),
            'acpi':mod.acpi(b.get('power')),'config':{**mod.read_config(b.get('dpdk')),**mod.read_config(b.get('powermng'))}}
        if sb and shift is not None:
            fv,fb=mod.read_freq(sb.get('freq'),shift)
            rec['server']={'bundle':sb,'rapl':read_msr(sb.get('msr'),shift),'freq_vals':fv,'freq_bridge':fb,
                'cstate_summary':mod.read_cstate_group_summaries(sb.get('cstate'),sb.get('freq'),shift,gr),'snap':mod.parse_snapshots(sb.get('log')),
                'acpi':mod.acpi(sb.get('power')),'config':{**mod.read_config(sb.get('dpdk')),**mod.read_config(sb.get('powermng'))}}
        records[(rep,mode)]=rec
    LAST_RECORDS=records
    return records


def combined_position(rec,grp,metric):
    vals=[mod.position_value(rec,ep,grp,metric) for ep in ('client','server')]
    return sum(vals) if all(v is not None for v in vals) else None


def combined_power(rec,grp):
    vals=[mod.position_value(rec,ep,grp,'power_w') for ep in ('client','server')]
    return sum(vals) if all(v is not None for v in vals) else None


def timeseries(records,out,index,name,title,endpoint,mode_filter=None):
    for variance in (False,True):
      fig,ax=mod.plt.subplots(figsize=(14,8));made=False
      modes=mod.MODES if mode_filter is None else (mode_filter,)
      for mode in modes:
        for grp,label,ls in [('d1','D1','-'),('d2plus','D2+','--')]:
          curves=[]
          for (rep,m),r in records.items():
            if m!=mode:continue
            eps=('client','server') if endpoint=='combined' else (endpoint,)
            if endpoint=='combined' and not all(ep in r for ep in eps):continue
            for w in r['groups'][grp]:
              pieces=[]
              for ep in eps:
                tr=r.get(ep,{}).get('rapl')
                if tr is None:continue
                xs=[];ys=[]
                for i,a in enumerate(tr['t']):
                    b=int(a+tr['dt'][i]*1e9);lo=max(int(a),w[0]);hi=min(b,w[1])
                    if hi<=lo:continue
                    xs.append((((lo+hi)//2)-w[0])/1e9);ys.append(float(tr['e'][i]/tr['dt'][i]))
                if xs:pieces.append((mod.np.array(xs),mod.np.array(ys)))
              if len(pieces)!=len(eps):continue
              if len(pieces)==1:curves.append(pieces[0])
              else:
                max_common=min(max(x) for x,y in pieces);grid=mod.np.arange(0,max_common,.006)
                if len(grid)>2:curves.append((grid,sum(mod.np.interp(grid,x,y) for x,y in pieces)))
          if not curves:continue
          max_common=min(max(x) for x,y in curves if len(x));grid=mod.np.arange(0,max_common,.05)
          if len(grid)<2:continue
          arr=mod.np.vstack([mod.np.interp(grid,x,y) for x,y in curves]);mu=arr.mean(0);sd=arr.std(0,ddof=1) if len(arr)>1 else mod.np.zeros_like(mu)
          ax.plot(grid,mu,ls=ls,label=f'{mod.MODE_NAMES[mode]} {label}');made=True
          if variance:ax.fill_between(grid,mu-sd,mu+sd,alpha=.12)
      if made:
        ax.set_xlabel('Elapsed from request start (s)');ax.set_ylabel('RAPL power (W)');ax.set_title(title);ax.grid(alpha=.25);ax.legend()
      else:ax.axis('off');ax.text(.5,.5,'No aligned RAPL samples',ha='center')
      folder=out/('with_variance' if variance else 'without_variance');(folder/'svg').mkdir(parents=True,exist_ok=True);(folder/'pdf').mkdir(parents=True,exist_ok=True)
      fig.savefig(folder/'svg'/f'{index:02d}_{name}.svg',bbox_inches='tight');fig.savefig(folder/'pdf'/f'{index:02d}_{name}.pdf',bbox_inches='tight');mod.plt.close(fig)


def bridge_uncertainty(rows):
    vals=[mod.finite(r.get('uncertainty_ns')) for r in rows if r.get('type')=='clock_bridge']
    vals=[int(v) for v in vals if v is not None]
    return max(vals) if vals else None


def trace_quality(rec,ep):
    E=rec.get(ep);wins=rec['windows'];first=wins[0][0];last=wins[-1][1]
    if not E:return {'present':False,'pass':False,'reason':'endpoint phase alignment unavailable'}
    q={'present':True}
    tr=E.get('rapl');
    if tr is not None and len(tr['t']):
        starts=[int(x) for x in tr['t']];ends=[int(tr['t'][i]+tr['dt'][i]*1e9) for i in range(len(tr['t']))]
        ms=[float(x)*1000 for x in tr['dt']]
        q.update(rapl_coverage=starts[0]<=first and ends[-1]>=last,rapl_interval_median_ms=pct(ms,50),rapl_interval_p95_ms=pct(ms,95),rapl_interval_max_ms=max(ms))
    else:q.update(rapl_coverage=False,rapl_interval_median_ms=None,rapl_interval_p95_ms=None,rapl_interval_max_ms=None)
    vals=sorted(E.get('freq_vals',[]))
    if vals:
        ts=sorted({int(t) for t,c,v in vals});gaps=[(b-a)/1e6 for a,b in zip(ts,ts[1:]) if b>a]
        q.update(freq_coverage=ts[0]<=first and ts[-1]>=last,freq_gap_median_ms=pct(gaps,50),freq_gap_p95_ms=pct(gaps,95),freq_gap_max_ms=max(gaps) if gaps else None)
    else:q.update(freq_coverage=False,freq_gap_median_ms=None,freq_gap_p95_ms=None,freq_gap_max_ms=None)
    q['clock_bridge_uncertainty_ns']=bridge_uncertainty(E.get('freq_bridge',[]))
    spans=[]
    fp=E.get('bundle',{}).get('freq')
    if fp and Path(fp).is_file():
      for l in Path(fp).read_text(errors='replace').splitlines():
        try:rr=json.loads(l)
        except:continue
        if rr.get('type')=='line' and mod.finite(rr.get('read_span_ns')) is not None:spans.append(float(rr['read_span_ns'])/2e6)
    q['freq_read_uncertainty_p95_ms']=pct(spans,95)
    n=len(wins);snap=E.get('snap',{});q['snapshot_pairs']=sum(1 for i in range(1,n+1) if (i,'start') in snap and (i,'end') in snap);q['snapshot_expected']=n
    snap_edge=[];shift=(rec.get('server_shift') or 0) if ep=='server' else 0
    for i,(ws,we) in enumerate(wins,1):
        a=snap.get((i,'start'));b=snap.get((i,'end'))
        if not a or not b:continue
        sa=mod.finite(a.get('monotonic_ns'));sb=mod.finite(b.get('monotonic_ns'))
        if sa is not None:snap_edge.append(abs((int(sa)+shift)-ws)/1e6)
        if sb is not None:snap_edge.append(abs((int(sb)+shift)-we)/1e6)
    q['snapshot_edge_median_ms']=pct(snap_edge,50);q['snapshot_edge_p95_ms']=pct(snap_edge,95);q['snapshot_edge_max_ms']=max(snap_edge) if snap_edge else None
    q['pass']=bool(q['rapl_coverage'] and q['freq_coverage'] and q['snapshot_pairs']==n and
        q['rapl_interval_p95_ms'] is not None and q['rapl_interval_p95_ms']<=MAX_RAPL_P95_MS and
        (q['freq_gap_p95_ms'] is None or q['freq_gap_p95_ms']<=MAX_FREQ_P95_MS) and
        q['snapshot_edge_p95_ms'] is not None and q['snapshot_edge_p95_ms']<=MAX_SNAPSHOT_EDGE_P95_MS)
    return q


def write_quality(root,records):
    rows=[];all_pass=True;durations=[];edge_ns=[]
    for (rep,mode),r in sorted(records.items()):
        durs=[e-s for s,e in r['windows']];durations.extend(durs)
        cq=trace_quality(r,'client');sq=trace_quality(r,'server')
        sync=r['server_alignment'].get('clock_sync') or {};sync_ok=bool(r['server_alignment'].get('accepted'))
        for ep,q in [('client',cq),('server',sq)]:
            rapl_ns=(q.get('rapl_interval_p95_ms') or 0)*1e6
            sync_ns=(sync.get('uncertainty_ns',0) if ep=='server' else 0)
            if ep=='server': sync_ns += (r['server_alignment'].get('get_residual_spread_ns') or 0)/2
            bridge_ns=q.get('clock_bridge_uncertainty_ns') or 0
            freq_ns=((q.get('freq_gap_p95_ms') or 0)*1e6/2)
            read_ns=(q.get('freq_read_uncertainty_p95_ms') or 0)*1e6
            snapshot_ns=(q.get('snapshot_edge_p95_ms') or 0)*1e6
            edge=max(1000.0,rapl_ns+sync_ns,bridge_ns+sync_ns,freq_ns+read_ns+sync_ns,snapshot_ns)
            q['conservative_edge_uncertainty_ns']=int(edge);edge_ns.append(edge)
        rec_pass=cq['pass'] and sq['pass'] and sync_ok
        all_pass=all_pass and rec_pass
        rows.append({'repetition':rep,'mode':mode,'pass':rec_pass,'server_alignment':r['server_alignment'],'client':cq,'server':sq})
    median_dur=pct(durations,50) or 0;worst_edge=max(edge_ns) if edge_ns else 0
    accuracy=100.0*(1.0-min(1.0,(2*worst_edge/median_dur))) if median_dur else None
    out={'schema':'greenquic-d1d2plus-alignment-quality-v1','pass':all_pass,'thresholds':{
        'max_server_clock_uncertainty_ms':MAX_CLOCK_UNCERTAINTY_NS/1e6,'max_get_residual_spread_ms':MAX_GET_RESIDUAL_SPREAD_NS/1e6,'max_rapl_interval_p95_ms':MAX_RAPL_P95_MS,'max_frequency_gap_p95_ms':MAX_FREQ_P95_MS,'max_snapshot_edge_p95_ms':MAX_SNAPSHOT_EDGE_P95_MS},
        'goodput_timestamp_quantization_us':1,'median_active_duration_ms':median_dur/1e6 if median_dur else None,
        'worst_conservative_edge_uncertainty_ms':worst_edge/1e6 if edge_ns else None,
        'temporal_alignment_accuracy_pct':accuracy,
        'accuracy_definition':'100*(1-2*worst_edge_uncertainty/median_active_duration); temporal/window alignment only, not Intel RAPL absolute electrical accuracy',
        'records':rows}
    od=root/'the_sheet_rules_all'/'d1_d2plus';od.mkdir(parents=True,exist_ok=True);(od/'alignment_quality.json').write_text(json.dumps(out,indent=2)+'\n')
    p=od/'manifest.json'
    if p.is_file():
        d=json.loads(p.read_text());d['schema']='greenquic-p5-d1-d2plus-v3';d['alignment_quality_file']='alignment_quality.json';d['server_clock_mapping']='direct client-minus-server CLOCK_MONOTONIC offset from clock_sync v2; no zero-offset fallback';d['frequency_aggregation']='midpoint-cell time weighted';d['rapl_plot_edges']='overlap-aware, clipped interval midpoint';p.write_text(json.dumps(d,indent=2)+'\n')
    print(f"P5 ALIGNMENT QUALITY pass={int(all_pass)} temporal_accuracy_pct={accuracy:.6f}" if accuracy is not None else f"P5 ALIGNMENT QUALITY pass={int(all_pass)} accuracy=N/A")
    return all_pass

mod.read_msr=read_msr
mod.freq_group=freq_group
mod.build_records=build_records
mod.combined_position=combined_position
mod.combined_power=combined_power
mod.timeseries=timeseries

rc=mod.main()
root=None
for i,a in enumerate(sys.argv[1:]):
    if a=='--input' and i+2<=len(sys.argv[1:]):root=Path(sys.argv[1:][i+1]);break
if rc==0 and root is not None:
    ok=write_quality(root,LAST_RECORDS)
    raise SystemExit(0 if ok else 4)
raise SystemExit(rc)
