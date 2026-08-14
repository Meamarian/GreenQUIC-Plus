#!/usr/bin/env python3
from __future__ import annotations
import argparse,csv,json,math,shutil,statistics,tempfile
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np

VARS=('without_variance','with_variance'); VALS=('without_values','with_values')
def num(v):
    try:
        x=float(v); return x if math.isfinite(x) else None
    except Exception:return None
def stat(a):
    a=[float(x) for x in a if x is not None and math.isfinite(float(x))]
    if not a:return 0,None,None,None
    if len(a)==1:return 1,a[0],None,None
    return len(a),statistics.mean(a),statistics.stdev(a),statistics.variance(a)
def js(p):return json.loads(p.read_text())
def endpoint(root,e):return [(d,js(d/'summary.json')) for d in sorted((root/'runs'/e).glob('rep*')) if (d/'summary.json').is_file()]
def rapl(s,scope,k):return num(((((s.get('scopes')or{}).get(scope)or{}).get('rapl')or{}).get(k)))
def freq(s,scope,cpu):return num((((s.get('scopes')or{}).get(scope)or{}).get('frequency')or{}).get(str(cpu),{}).get('mean_ghz'))
def ensure(p):p.mkdir(parents=True,exist_ok=True);return p
def bar(report,n,name,title,ylabel,cats,series,stats,manifest):
    cache={label:[stat(v) for v in groups] for label,groups in series.items()}
    if not any(x[1] is not None for g in cache.values() for x in g):return
    for label,ss in cache.items():
        for cat,(nn,mu,sd,var) in zip(cats,ss):stats.append([n,name,label,cat,nn,mu,sd,var])
    x=np.arange(len(cats)); w=min(.78/max(1,len(series)),.28)
    for vv in VARS:
      for val in VALS:
        fig,ax=plt.subplots(figsize=(12,7))
        for j,(label,ss) in enumerate(cache.items()):
            means=[np.nan if s[1] is None else s[1] for s in ss]; errs=[0 if vv=='without_variance' or s[2] is None else s[2] for s in ss]
            pos=x+(j-(len(series)-1)/2)*w; bars=ax.bar(pos,means,w,label=label,yerr=errs if vv=='with_variance' else None,capsize=5)
            if val=='with_values':
                for b,mu,er,s in zip(bars,means,errs,ss):
                    if math.isfinite(mu):ax.annotate(f'{mu:.3f}'+(f'\nSD={s[2]:.3f}' if vv=='with_variance' and s[2] is not None else ''),(b.get_x()+b.get_width()/2,mu+er),xytext=(0,5),textcoords='offset points',ha='center',fontsize=8)
        ax.set_title(title,fontweight='normal');ax.set_ylabel(ylabel);ax.set_xticks(x,cats);ax.grid(axis='y',alpha=.3);ax.set_axisbelow(True);ax.set_ylim(bottom=0)
        if len(series)>1:ax.legend(loc='center left',bbox_to_anchor=(1.01,.5))
        fig.tight_layout()
        for ext in ('svg','pdf'):
            p=ensure(report/'charts'/vv/ext/val)/f'{n:02d}_{name}.{ext}';fig.savefig(p,bbox_inches='tight',dpi=300);manifest.append([n,name,vv,val,ext,str(p.relative_to(report))])
            if vv=='without_variance':shutil.copy2(p,ensure(report/'charts'/ext/val)/p.name)
        plt.close(fig)
def read_rapl(p):
    if not p.is_file():return[]
    lines=[x for x in p.read_text(errors='replace').splitlines() if x and not x.startswith('#')]
    return list(csv.DictReader(lines)) if lines else []
def read_freq(p,cpu):
    out=[]
    if not p.is_file():return out
    for l in p.read_text(errors='replace').splitlines():
        try:r=json.loads(l)
        except:continue
        try:
            if r.get('type')=='line' and int(r['cpu'])==cpu:out.append((int(r['monotonic_ns']),float(r['freq_khz'])/1e6))
        except:pass
    return out
def phases(s):
    w=s.get('windows')or{};out=[]
    if w.get('pre_cool'):out.append(('Pre',*w['pre_cool'][0]))
    aa=w.get('active')or[];gg=w.get('gap')or[]
    for i,a in enumerate(aa):
        out.append((f'D{i+1}',*a))
        if i<len(gg):out.append((f'Gap{i+1}',*gg[i]))
    if w.get('post_cool'):out.append(('Post',*w['post_cool'][0]))
    return out
def interp(samples,a,b,n=60):
    q=[(t,v) for t,v in samples if a<=t<=b]
    if not q:return np.full(n,np.nan)
    x=np.array([(t-a)/(b-a) for t,v in q]);y=np.array([v for t,v in q]);z=np.linspace(0,1,n)
    return np.interp(z,x,y,left=y[0],right=y[-1]) if len(q)>1 else np.full(n,y[0])
def timeseries(report,root,e,kind,cpu,n,name,title,ylabel,manifest):
    runs=endpoint(root,e);seq=[phases(s) for d,s in runs]
    if not seq:return
    labels=[x[0] for x in seq[0]]
    if any([x[0] for x in q]!=labels for q in seq):return
    mats=[];durs=[]
    for (d,s),q in zip(runs,seq):
        if kind=='rapl':samples=[(int(float(r['sample_monotonic_ns'])),float(r.get('total_power_smoothed_w')or r.get('total_power_w'))) for r in read_rapl(d/'rapl.csv')]
        else:samples=read_freq(d/'frequency.jsonl',cpu)
        mats.append([interp(samples,a,b) for _,a,b in q]);durs.append([(b-a)/1e9 for _,a,b in q])
    dur=np.nanmean(np.array(durs),axis=0);xs=[];parts=[];bounds=[0];cur=0
    for j,x in enumerate(dur):xs.append(np.linspace(cur,cur+x,60));cur+=x;bounds.append(cur);parts.append(np.array([m[j] for m in mats]))
    X=np.concatenate(xs);A=np.concatenate(parts,axis=1);M=np.nanmean(A,axis=0);SD=np.nanstd(A,axis=0,ddof=1) if len(runs)>1 else np.full_like(M,np.nan)
    for vv in VARS:
      for val in VALS:
        fig,ax=plt.subplots(figsize=(14,7));ax.plot(X,M,label=f'{e.title()} mean (n={len(runs)})')
        if vv=='with_variance' and np.isfinite(SD).any():ax.fill_between(X,M-SD,M+SD,alpha=.18,label='±1 SD')
        for b in bounds[1:-1]:ax.axvline(b,lw=.8,alpha=.3)
        for j,l in enumerate(labels):ax.text((bounds[j]+bounds[j+1])/2,1.01,l,transform=ax.get_xaxis_transform(),ha='center',fontsize=8)
        ax.set_title(title,fontweight='normal');ax.set_xlabel('Phase-aligned elapsed time (s)');ax.set_ylabel(ylabel);ax.grid(alpha=.25);ax.legend();fig.tight_layout()
        for ext in ('svg','pdf'):
            p=ensure(report/'charts'/vv/ext/val)/f'{n:02d}_{name}.{ext}';fig.savefig(p,bbox_inches='tight',dpi=300);manifest.append([n,name,vv,val,ext,str(p.relative_to(report))])
            if vv=='without_variance':shutil.copy2(p,ensure(report/'charts'/ext/val)/p.name)
        plt.close(fig)
def build(root,report):
    rows=list(csv.DictReader((root/'p7_all_runs.csv').open()));S=[x[1] for x in endpoint(root,'server')];C=[x[1] for x in endpoint(root,'client')]
    if not rows or len(S)!=len(C):raise SystemExit('P7 summaries incomplete')
    text=(root/'matrix_config.env').read_text();cpu=int(text.split('dataplane_cpu=',1)[1].splitlines()[0]) if 'dataplane_cpu=' in text else 19
    stats=[];manifest=[];col=lambda k:[num(r.get(k)) for r in rows]
    bar(report,1,'active_goodput','Linux UDP active-download goodput','Gbit/s',['MsQuic-Linux'],{'Goodput':[col('goodput_gbps')]},stats,manifest)
    bar(report,2,'gap_inclusive_goodput','Linux UDP gap-inclusive goodput','Gbit/s',['MsQuic-Linux'],{'Goodput':[col('gap_inclusive_goodput_gbps')]},stats,manifest)
    for n,scope in ((3,'active'),(4,'gap'),(5,'combined')):bar(report,n,f'{scope}_energy',f'RAPL energy — {scope}','J',['Server','Client'],{'CPU package + DRAM':[[rapl(s,scope,'total_j') for s in S],[rapl(c,scope,'total_j') for c in C]]},stats,manifest)
    for n,scope in ((6,'active'),(7,'gap'),(8,'combined')):bar(report,n,f'{scope}_power',f'Average RAPL power — {scope}','W',['Server','Client'],{'CPU package + DRAM':[[rapl(s,scope,'total_w') for s in S],[rapl(c,scope,'total_w') for c in C]]},stats,manifest)
    bar(report,9,'active_j_per_gbit','Combined active energy cost','J/Gbit',['Server + Client'],{'Energy cost':[col('combined_active_j_per_useful_gbit')]},stats,manifest)
    bar(report,10,'combined_j_per_gbit','Combined D1→Dn energy cost','J/Gbit',['Server + Client'],{'Energy cost':[col('combined_combined_j_per_useful_gbit')]},stats,manifest)
    for n,scope in ((11,'active'),(12,'gap'),(13,'combined')):bar(report,n,f'{scope}_frequency',f'CPU{cpu} mean frequency — {scope}','GHz',['Server','Client'],{f'CPU{cpu}':[[freq(s,scope,cpu) for s in S],[freq(c,scope,cpu) for c in C]]},stats,manifest)
    timeseries(report,root,'server','rapl',cpu,14,'server_rapl_over_time','Server RAPL power over pre-cool, downloads and gaps','W',manifest)
    timeseries(report,root,'client','rapl',cpu,15,'client_rapl_over_time','Client RAPL power over pre-cool, downloads and gaps','W',manifest)
    timeseries(report,root,'server','freq',cpu,16,'server_frequency_over_time',f'Server CPU{cpu} frequency over pre-cool, downloads and gaps','GHz',manifest)
    timeseries(report,root,'client','freq',cpu,17,'client_frequency_over_time',f'Client CPU{cpu} frequency over pre-cool, downloads and gaps','GHz',manifest)
    with (report/'chart_statistics.csv').open('w',newline='') as f: w=csv.writer(f);w.writerow(['chart','name','series','category','n','mean','sd','variance']);w.writerows(stats)
    with (report/'chart_manifest.csv').open('w',newline='') as f:w=csv.writer(f);w.writerow(['chart','name','variance','values','format','path']);w.writerows(manifest)
    (report/'validation_report.json').write_text(json.dumps({'schema':'greenquic-p7-report-v1','repetitions':len(rows),'chart_numbers':sorted({x[0] for x in manifest}),'variant_files':len(manifest),'warnings':[]},indent=2)+'\n')
    (report/'README.txt').write_text('P7 Linux UDP report. Same P5 chart-variant convention; Linux-equivalent metrics only. DPDK-only pressure/action/hint charts are intentionally absent.\n')
    print(f'P7 report: {report}');print(f'P7 charts: {len(set(x[0] for x in manifest))} chart numbers, {len(manifest)} variant files')
def selftest():
    with tempfile.TemporaryDirectory() as td:
        r=Path(td);(r/'runs/server/rep01').mkdir(parents=True);(r/'runs/client/rep01').mkdir(parents=True);base=1_000_000_000
        for e in ('server','client'):
            s={'windows':{'pre_cool':[[base,base+1_000_000_000]],'active':[[base+1_000_000_000,base+2_000_000_000]],'combined':[[base+1_000_000_000,base+2_000_000_000]],'post_cool':[[base+2_000_000_000,base+3_000_000_000]],'gap':[]},'scopes':{x:{'rapl':{'total_j':80,'total_w':80},'frequency':{'19':{'mean_ghz':2.2}}} for x in ('pre_cool','active','combined','post_cool','gap')}};(r/f'runs/{e}/rep01/summary.json').write_text(json.dumps(s))
            (r/f'runs/{e}/rep01/rapl.csv').write_text('sample_monotonic_ns,total_power_w,total_power_smoothed_w\n'+''.join(f'{base+i*10_000_000},80,80\n' for i in range(301)))
            (r/f'runs/{e}/rep01/frequency.jsonl').write_text(''.join(json.dumps({'type':'line','monotonic_ns':base+i*10_000_000,'cpu':19,'freq_khz':2200000})+'\n' for i in range(301)))
        (r/'p7_all_runs.csv').write_text('repetition,goodput_gbps,gap_inclusive_goodput_gbps,combined_active_j_per_useful_gbit,combined_combined_j_per_useful_gbit\n1,8,8,20,20\n');(r/'matrix_config.env').write_text('dataplane_cpu=19\n');build(r,r/'the_sheet_rules_all');print('P7 report self-test PASS')
def main():
    a=argparse.ArgumentParser();a.add_argument('--matrix-dir',type=Path);a.add_argument('--output',type=Path);a.add_argument('--self-test',action='store_true');z=a.parse_args()
    if z.self_test:selftest();return
    if not z.matrix_dir:a.error('--matrix-dir required')
    out=z.output or z.matrix_dir/'the_sheet_rules_all';ensure(out);build(z.matrix_dir.resolve(),out.resolve())
if __name__=='__main__':main()
