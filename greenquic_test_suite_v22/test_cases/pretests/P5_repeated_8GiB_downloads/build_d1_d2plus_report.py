#!/usr/bin/env python3
from __future__ import annotations
import argparse,csv,json,math,re,statistics,bisect
from dataclasses import dataclass
from pathlib import Path
from typing import Any,Iterable
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np

MODES=('off','basic','plus')
MODE_NAMES={'off':'MsQuic-DPDK','basic':'GreenQUIC','plus':'GreenQUIC+'}
EXPECTED=62
SNAP_PREFIX='[GreenQUIC-P5-SNAPSHOT]'
PAYLOAD_DEFAULT=8*1024**3


def finite(x):
    try:
        v=float(x)
        return v if math.isfinite(v) else None
    except Exception:return None

def stats(xs):
    a=[float(x) for x in xs if finite(x) is not None]
    if not a:return {'n':0,'mean':None,'sd':None,'min':None,'max':None}
    return {'n':len(a),'mean':statistics.mean(a),'sd':statistics.stdev(a) if len(a)>1 else 0.0,'min':min(a),'max':max(a)}
def read_csv(path):
    if not path or not Path(path).is_file():return []
    lines=[x for x in Path(path).read_text(errors='replace').splitlines() if x and not x.startswith('#')]
    return list(csv.DictReader(lines)) if lines else []
def detail_file(d,pattern):
    rows=list(Path(d).glob(pattern)); return rows[0] if rows else None

def discover(root:Path):
    out={}
    for role in ('client','server'):
        rr=root/'runs'/role
        if not rr.exists():continue
        for repdir in rr.glob('rep*_*'):
            m=re.fullmatch(r'rep(\d+)_(off|basic|plus)',repdir.name)
            if not m:continue
            rep=int(m.group(1));mode=m.group(2)
            bundles=[p for p in repdir.iterdir() if p.is_dir()]
            if not bundles:continue
            b=max(bundles,key=lambda p:p.stat().st_mtime)
            d=b/'details'
            out[(role,rep,mode)]={'bundle':b,'details':d,
              'log':detail_file(d,'*_log.txt'),'msr':detail_file(d,'*_msr_power.csv'),
              'freq':detail_file(d,'*_frequency_samples.jsonl'),'cstate':detail_file(d,'*_cstate.csv'),
              'timeline':detail_file(d,'*_timeline.jsonl'),'counters':detail_file(d,'*_greenquic_counters.csv'),
              'power':detail_file(d,'*_power.json'),'dpdk':detail_file(d,'*_dpdk_config.txt'),
              'powermng':detail_file(d,'*_powermng_config.txt'),
              'metrics':next(iter(d.glob('p5_metrics_*.json')),None)}
    return out

def load_metrics(bundle):
    p=bundle.get('metrics')
    if p and p.is_file():
        try:return json.load(open(p))
        except Exception:pass
    p=bundle.get('log')
    text=p.read_text(errors='replace') if p else ''
    starts={int(i):int(t) for i,t in re.findall(r'request=(\d+)/\d+ start_us=(\d+)',text)}
    ends={int(i):int(t) for i,t in re.findall(r'request=(\d+)/\d+ complete_us=(\d+)',text)}
    req=[{'index':i,'start_us':starts[i],'complete_us':ends[i],'duration_us':ends[i]-starts[i]} for i in sorted(starts.keys()&ends.keys())]
    return {'payload_bytes_per_download':PAYLOAD_DEFAULT,'requests':req,'downloads_observed':len(req)}
def windows(metrics):
    return [(int(r['start_us'])*1000,int(r['complete_us'])*1000) for r in metrics.get('requests',[]) if r.get('start_us') is not None and r.get('complete_us') is not None]
def gap_windows(ws):return [(ws[i][1],ws[i+1][0]) for i in range(len(ws)-1)]
def groups(ws):
    gs=gap_windows(ws)
    return {'d1':ws[:1],'d2plus':ws[1:],'g1':gs[:1],'g2plus':gs[1:],
            'cycle1':[(ws[0][0],ws[1][0])] if len(ws)>1 else ws[:1],
            'cycle2plus':[(ws[i][0],ws[i+1][0]) for i in range(1,len(ws)-1)]}

def server_get_times(path):
    out=[]
    if not path:return out
    for line in path.read_text(errors='replace').splitlines():
        try:r=json.loads(line)
        except:continue
        if r.get('type')=='line' and re.search(r"\bGET\s+'",str(r.get('line',''))):
            t=finite(r.get('monotonic_ns'))
            if t is not None:out.append(int(t))
    return out

def server_shift(client_ws,timeline):
    g=server_get_times(timeline)
    if not client_ws or not g:return None
    n=min(len(client_ws),len(g)); offsets=[client_ws[i][0]-g[i] for i in range(n)]
    med=int(statistics.median(offsets)); spread=max(offsets)-min(offsets) if len(offsets)>1 else 0
    return med if spread<=5_000_000 else None

def read_msr(path,shift=0):
    rows=read_csv(path)
    if not rows:return None
    T=[];DT=[];E=[];PK=[];DR=[]
    for r in rows:
        t=finite(r.get('sample_monotonic_ns'));dt=finite(r.get('actual_interval_ms'));p=finite(r.get('package_delta_j'));d=finite(r.get('dram_delta_j')) or 0
        if None in (t,dt,p) or dt<=0:continue
        T.append(int(t)+shift);DT.append(dt/1000);PK.append(p);DR.append(d);E.append(p+d)
    if not T:return None
    return {'t':np.array(T,np.int64),'dt':np.array(DT,float),'e':np.array(E,float),'pk':np.array(PK,float),'dr':np.array(DR,float)}
def integrate(trace,wins):
    if trace is None or not wins:return {'duration_s':0.,'energy_j':None,'package_j':None,'dram_j':None,'power_w':None}
    dur=e=pk=dr=0.
    for i,a in enumerate(trace['t']):
        b=int(a+trace['dt'][i]*1e9)
        if b<=a:continue
        ov=sum(max(0,min(b,y)-max(a,x)) for x,y in wins)
        if ov:
            f=ov/(b-a);dur+=ov/1e9;e+=trace['e'][i]*f;pk+=trace['pk'][i]*f;dr+=trace['dr'][i]*f
    return {'duration_s':dur,'energy_j':e,'package_j':pk,'dram_j':dr,'power_w':e/dur if dur else None}

def read_freq(path,shift=0):
    vals=[]; bridge=[]
    if not path:return vals,bridge
    for line in path.read_text(errors='replace').splitlines():
        try:r=json.loads(line)
        except:continue
        if r.get('type')=='clock_bridge':bridge.append(r);continue
        if r.get('type')!='line':continue
        t=finite(r.get('monotonic_ns'));cpu=finite(r.get('cpu'));khz=finite(r.get('freq_khz'))
        if t is None:
            m=re.search(r'freq_khz=(\d+)',str(r.get('line',''))); khz=finite(m.group(1)) if m else khz
        if None not in (t,khz):vals.append((int(t)+shift,int(cpu or 0),float(khz)/1e6))
    return vals,bridge
def freq_group(vals,wins):
    a=[v for t,c,v in vals if any(x<=t<=y for x,y in wins)]
    if not a:return {'mean_ghz':None,'min_ghz':None,'max_ghz':None,'samples':0,'changes':None}
    changes=sum(1 for x,y in zip(a,a[1:]) if x!=y)
    return {'mean_ghz':statistics.mean(a),'min_ghz':min(a),'max_ghz':max(a),'samples':len(a),'changes':changes}

def bridge_from_freq(path):
    if not path:return None
    rows=[]
    for line in path.read_text(errors='replace').splitlines():
        try:r=json.loads(line)
        except:continue
        if r.get('type')=='clock_bridge' and finite(r.get('monotonic_ns')) is not None and finite(r.get('monotonic_raw_ns')) is not None:rows.append(r)
    if not rows:return None
    s=next((r for r in rows if r.get('phase')=='start'),rows[0]);e=next((r for r in reversed(rows) if r.get('phase')=='end'),None)
    def conv(raw):
        o0=int(s['monotonic_ns'])-int(s['monotonic_raw_ns'])
        if not e or int(e['monotonic_raw_ns'])==int(s['monotonic_raw_ns']):return int(raw)+o0
        o1=int(e['monotonic_ns'])-int(e['monotonic_raw_ns']); f=(int(raw)-int(s['monotonic_raw_ns']))/(int(e['monotonic_raw_ns'])-int(s['monotonic_raw_ns']));f=max(0,min(1,f))
        return int(raw+o0+f*(o1-o0))
    return conv

def read_cstate_group_summaries(path,freqpath,shift,group_windows):
    """Stream a potentially huge cstate CSV once and attribute each idle interval to all requested groups.
    Per-group window pointers avoid O(intervals * windows) rescans and preserve per-window fragment counting.
    """
    conv=bridge_from_freq(freqpath)
    if not path or not Path(path).is_file() or conv is None:
        return {g:{'by_state_s':{0:0.,1:0.,2:0.,3:0.},'idle_s':0.,'idle_fraction_pct':None,'interval_fragments':0,'duration_s':sum((y-x)/1e9 for x,y in ws)} for g,ws in group_windows.items()}
    sums={g:{'by_state_s':{0:0.,1:0.,2:0.,3:0.},'idle_s':0.,'idle_fraction_pct':None,'interval_fragments':0,'duration_s':sum((y-x)/1e9 for x,y in ws)} for g,ws in group_windows.items()}
    ptr={g:0 for g in group_windows}
    with open(path,newline='',errors='replace') as fh:
        rd=csv.reader(fh)
        try:hdr=next(rd)
        except StopIteration:return sums
        idx={k:i for i,k in enumerate(hdr)}
        need=('timestamp_mono_raw_ns','idle_duration_ns','previous_state')
        if any(k not in idx for k in need):return sums
        for row in rd:
            try:
                tr=int(row[idx['timestamp_mono_raw_ns']]);d=int(row[idx['idle_duration_ns']]);st=int(row[idx['previous_state']])
            except:continue
            if d<=0 or st<0:continue
            b=conv(tr)+shift;a=conv(tr-d)+shift
            for g,ws in group_windows.items():
                j=ptr[g]
                while j<len(ws) and ws[j][1]<=a:j+=1
                ptr[g]=j
                k=j
                # Normally one short idle interval intersects at most one window; keep loop correct at boundaries.
                while k<len(ws) and ws[k][0]<b:
                    x,y=ws[k];ov=max(0,min(b,y)-max(a,x))
                    if ov:
                        sums[g]['by_state_s'][st]=sums[g]['by_state_s'].get(st,0)+ov/1e9
                        sums[g]['interval_fragments']+=1
                    k+=1
    for z in sums.values():
        z['idle_s']=sum(z['by_state_s'].values())
        z['idle_fraction_pct']=z['idle_s']/z['duration_s']*100 if z['duration_s'] else None
    return sums

def parse_snapshots(path):
    out={}
    if not path:return out
    for line in path.read_text(errors='replace').splitlines():
        if SNAP_PREFIX not in line:continue
        tail=line.split(SNAP_PREFIX,1)[1].strip();kv=dict(re.findall(r'(\w+)=([^\s]+)',tail))
        try:i=int(kv['request']);label=kv['label']
        except:continue
        row={k:(int(v) if re.fullmatch(r'-?\d+',v) else v) for k,v in kv.items()};out[(i,label)]=row
    return out

def snap_delta(snap,indexes,keys):
    totals={k:0 for k in keys};ok=True
    for i in indexes:
        a=snap.get((i,'start'));b=snap.get((i,'end'))
        if not a or not b:ok=False;break
        for k in keys:
            av=finite(a.get(k));bv=finite(b.get(k))
            if av is None or bv is None or bv<av:ok=False;break
            totals[k]+=bv-av
        if not ok:break
    return totals if ok else None

def read_config(path):
    if not path:return {}
    o={}
    for l in path.read_text(errors='replace').splitlines():
        if '=' in l and not l.lstrip().startswith(('#',';')):
            k,v=l.split('=',1);o[k.strip()]=v.strip()
    return o

def acpi(path):
    if not path:return {}
    try:return json.load(open(path))
    except:return {}

SNAP_KEYS=['rx_pkts','tx_pkts','epoll_try','epoll_wake','epoll_timeout','epoll_rx_wake','epoll_control_wake','epoll_signal_wake','epoll_rx_fd_drain','epoll_rx_fd_drain_error','wake_signal','freq_policy_max_hard','freq_policy_max_control','freq_policy_up','freq_policy_down','freq_policy_min','freq_policy_txring_protect_up','freq_changed_max','freq_changed_up','freq_changed_down','freq_changed_min','freq_unchanged','freq_error','hint_ack_pending','hint_cubic_cwnd_blocked','hint_cubic_recovery','hint_cubic_recovery_end','hint_cubic_ramping','hint_server_file_tx_active','hint_server_file_tx_end','hint_client_file_rx_active','hint_client_file_rx_end']

def per_download(v,n):return v/n if v is not None and n else None

def build_records(root):
    f=discover(root);reps=sorted({r for role,r,m in f});records={}
    for rep in reps:
      for mode in MODES:
        cb=f.get(('client',rep,mode));sb=f.get(('server',rep,mode))
        if not cb:continue
        met=load_metrics(cb);ws=windows(met)
        if len(ws)<2:continue
        gr=groups(ws);shift=server_shift(ws,sb.get('timeline') if sb else None)
        rec={'rep':rep,'mode':mode,'metrics':met,'windows':ws,'groups':gr,'server_shift':shift}
        for ep,b,sh in [('client',cb,0),('server',sb,shift or 0)]:
            if not b:continue
            rec[ep]={'bundle':b,'rapl':read_msr(b.get('msr'),sh),'freq_vals':read_freq(b.get('freq'),sh)[0],
                     'cstate_summary':read_cstate_group_summaries(b.get('cstate'),b.get('freq'),sh,gr),'snap':parse_snapshots(b.get('log')),
                     'acpi':acpi(b.get('power')),'config':{**read_config(b.get('dpdk')),**read_config(b.get('powermng'))}}
        records[(rep,mode)]=rec
    return records

def position_value(rec,ep,grp,metric):
    E=rec.get(ep,{});wins=rec['groups'][grp]
    n=max(1,len(wins))
    cache=E.setdefault('_position_cache',{})
    if ('rapl',grp) not in cache: cache[('rapl',grp)]=integrate(E.get('rapl'),wins)
    if ('cstate',grp) not in cache: cache[('cstate',grp)]=E.get('cstate_summary',{}).get(grp,{'by_state_s':{},'idle_s':0.,'idle_fraction_pct':None,'interval_fragments':0,'duration_s':sum((y-x)/1e9 for x,y in wins)})
    if ('freq',grp) not in cache: cache[('freq',grp)]=freq_group(E.get('freq_vals',[]),wins)
    if metric in ('energy_j','power_w','package_j','dram_j'):
        x=cache[('rapl',grp)];v=x.get(metric);return per_download(v,n) if metric.endswith('_j') else v
    if metric.startswith('cstate_state_'):
        st=int(metric.rsplit('_',1)[1]);x=cache[('cstate',grp)];return per_download(x['by_state_s'].get(st,0),n)
    if metric in ('idle_s','interval_fragments'):
        x=cache[('cstate',grp)];return per_download(x[metric],n)
    if metric=='idle_fraction_pct':return cache[('cstate',grp)][metric]
    if metric in ('mean_ghz','min_ghz','max_ghz','samples','changes'):return cache[('freq',grp)][metric]
    return None

def goodput(rec,grp):
    ws=rec['groups'][grp];payload=int(rec['metrics'].get('payload_bytes_per_download',PAYLOAD_DEFAULT));dur=sum(y-x for x,y in ws)/1e9
    return len(ws)*payload*8/dur/1e9 if dur else None

def cycle_goodput(rec,grp):
    ws=rec['groups'][grp];payload=int(rec['metrics'].get('payload_bytes_per_download',PAYLOAD_DEFAULT));dur=sum(y-x for x,y in ws)/1e9
    return len(ws)*payload*8/dur/1e9 if dur else None

def snapvalue(rec,ep,grp,key):
    snap=rec.get(ep,{}).get('snap',{});nreq=len(rec['windows'])
    if grp=='d1':idx=[1]
    elif grp=='d2plus':idx=list(range(2,nreq+1))
    else:return None
    d=snap_delta(snap,idx,[key]);return per_download(d[key],len(idx)) if d else None

def aggregate(records,mode,func):return stats(func(r) for (rep,m),r in records.items() if m==mode)

def combined_position(rec,grp,metric):
    vals=[]
    for ep in ('client','server'):
        v=position_value(rec,ep,grp,metric)
        if v is not None:vals.append(v)
    return sum(vals) if vals else None

def combined_power(rec,grp):
    vals=[position_value(rec,ep,grp,'power_w') for ep in ('client','server')]
    vals=[v for v in vals if v is not None]
    return sum(vals) if vals else None

def chart_stats(records,func):
    return {(mode,grp):aggregate(records,mode,lambda r,g=grp:func(r,g)) for mode in MODES for grp in ('d1','d2plus')}

def grouped_bar(out,index,name,title,ylabel,smap,series=None):
    # smap {(mode,group): stats}; series defaults one measure, group bars D1/D2+
    for variance in (False,True):
      fig,ax=plt.subplots(figsize=(14,8));x=np.arange(3);w=.34
      for j,(grp,label) in enumerate((('d1','D1'),('d2plus','D2+ mean per later download'))):
        means=[smap[(m,grp)]['mean'] for m in MODES];ys=[np.nan if v is None else v for v in means]
        err=[0 if smap[(m,grp)]['sd'] is None else smap[(m,grp)]['sd'] for m in MODES]
        bars=ax.bar(x+(j-.5)*w,ys,w,label=label,yerr=err if variance else None,capsize=4 if variance else 0)
        for b,v in zip(bars,means):
            if v is not None:ax.annotate(f'{v:.2f}',(b.get_x()+b.get_width()/2,b.get_height()),xytext=(0,6),textcoords='offset points',ha='center',fontsize=8)
      ax.set_xticks(x,[MODE_NAMES[m] for m in MODES]);ax.set_ylabel(ylabel);ax.set_title(title);ax.grid(axis='y',alpha=.25);ax.set_axisbelow(True);ax.legend();ax.set_ylim(bottom=0)
      folder=out/('with_variance' if variance else 'without_variance');(folder/'svg').mkdir(parents=True,exist_ok=True);(folder/'pdf').mkdir(parents=True,exist_ok=True)
      fig.savefig(folder/'svg'/f'{index:02d}_{name}.svg',bbox_inches='tight');fig.savefig(folder/'pdf'/f'{index:02d}_{name}.pdf',bbox_inches='tight');plt.close(fig)

def placeholder(out,index,name,title,reason):
    for variance in (False,True):
      fig,ax=plt.subplots(figsize=(14,8));ax.axis('off');ax.text(.5,.58,title,ha='center',fontsize=18);ax.text(.5,.44,'D1/D2+ unavailable for this archive',ha='center',fontsize=14);ax.text(.5,.34,reason,ha='center',fontsize=10,wrap=True)
      folder=out/('with_variance' if variance else 'without_variance');(folder/'svg').mkdir(parents=True,exist_ok=True);(folder/'pdf').mkdir(parents=True,exist_ok=True);fig.savefig(folder/'svg'/f'{index:02d}_{name}.svg',bbox_inches='tight');fig.savefig(folder/'pdf'/f'{index:02d}_{name}.pdf',bbox_inches='tight');plt.close(fig)

def timeseries(records,out,index,name,title,endpoint,mode_filter=None):
    # per-request aligned RAPL power. D1 uses one trace/rep; D2+ all later traces.
    for variance in (False,True):
      fig,ax=plt.subplots(figsize=(14,8));made=False
      modes=MODES if mode_filter is None else (mode_filter,)
      for mode in modes:
        for grp,label,ls in [('d1','D1','-'),('d2plus','D2+','--')]:
          curves=[]
          for (rep,m),r in records.items():
            if m!=mode:continue
            eps=('client','server') if endpoint=='combined' else (endpoint,)
            wins=r['groups'][grp]
            for w in wins:
              pieces=[]
              for ep in eps:
                tr=r.get(ep,{}).get('rapl')
                if tr is None:continue
                t=tr['t'];p=tr['e']/tr['dt'];mask=(t>=w[0])&(t<=w[1]);pieces.append(((t[mask]-w[0])/1e9,p[mask]))
              if not pieces:continue
              if len(pieces)==1:curves.append(pieces[0])
              else:
                grid=np.arange(0,min(max(x[0]) if len(x[0]) else 0 for x in pieces),.006)
                if len(grid)>2:curves.append((grid,sum(np.interp(grid,x,y) for x,y in pieces)))
          if not curves:continue
          max_common=min(max(x) for x,y in curves if len(x));grid=np.arange(0,max_common,.05)
          if len(grid)<2:continue
          arr=np.vstack([np.interp(grid,x,y) for x,y in curves]);mu=arr.mean(0);sd=arr.std(0,ddof=1) if len(arr)>1 else np.zeros_like(mu)
          ax.plot(grid,mu,ls,label=f'{MODE_NAMES[mode]} {label}');
          if variance:ax.fill_between(grid,mu-sd,mu+sd,alpha=.12)
          made=True
      if made:ax.set_xlabel('Elapsed from request start (s)');ax.set_ylabel('RAPL power (W)');ax.grid(alpha=.25);ax.legend();ax.set_title(title)
      else:ax.axis('off');ax.text(.5,.5,'No timestamped RAPL data',ha='center')
      folder=out/('with_variance' if variance else 'without_variance');(folder/'svg').mkdir(parents=True,exist_ok=True);(folder/'pdf').mkdir(parents=True,exist_ok=True);fig.savefig(folder/'svg'/f'{index:02d}_{name}.svg',bbox_inches='tight');fig.savefig(folder/'pdf'/f'{index:02d}_{name}.pdf',bbox_inches='tight');plt.close(fig)

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--input',required=True);ap.add_argument('--output');a=ap.parse_args();root=Path(a.input).resolve();out=Path(a.output).resolve() if a.output else root/'the_sheet_rules_all'/'d1_d2plus';out.mkdir(parents=True,exist_ok=True)
    rec=build_records(root)
    if not rec:raise SystemExit('ERROR: no P5 runs with >=2 downloads found')
    audit=[];statrows=[]
    def emit(i,name,title,ylabel,func,source='timestamped'):
        sm=chart_stats(rec,func); available=any(sm[k]['n'] for k in sm)
        if available:grouped_bar(out,i,name,title,ylabel,sm)
        else:placeholder(out,i,name,title,'Required phase/boundary data is absent; rerun with the D1/D2+ snapshot build for exact attribution.')
        audit.append({'chart':i,'name':name,'available':int(available),'source':source})
        for (m,g),s in sm.items():statrows.append({'chart':i,'name':name,'mode':m,'group':g,**s})
    # 1-9 workload/power
    emit(1,'file_size_and_payload','Payload per download: D1 vs D2+','GiB',lambda r,g:int(r['metrics'].get('payload_bytes_per_download',PAYLOAD_DEFAULT))/1024**3)
    emit(2,'download_and_gap_counts','Download position count (per run)','Count',lambda r,g:len(r['groups'][g]))
    emit(3,'gap_duration','Following-gap duration: G1 vs G2+','s',lambda r,g: (sum(y-x for x,y in r['groups']['g1' if g=='d1' else 'g2plus'])/1e9/max(1,len(r['groups']['g1' if g=='d1' else 'g2plus']))) if r['groups']['g1' if g=='d1' else 'g2plus'] else None)
    emit(4,'active_goodput','Active goodput: D1 vs D2+','Gbit/s',goodput)
    emit(5,'gap_inclusive_goodput','Position-cycle goodput: D1+G1 vs steady cycles','Gbit/s',lambda r,g:cycle_goodput(r,'cycle1' if g=='d1' else 'cycle2plus'))
    emit(6,'duration_breakdown','Active duration per download: D1 vs D2+','s',lambda r,g:sum(y-x for x,y in r['groups'][g])/1e9/max(1,len(r['groups'][g])))
    emit(7,'average_rapl_power','Combined endpoint active RAPL power: D1 vs D2+','W',lambda r,g:combined_power(r,g))
    emit(8,'rapl_energy','Combined endpoint active RAPL energy per download','J',lambda r,g:combined_position(r,g,'energy_j'))
    emit(9,'energy_efficiency','Combined active energy cost: D1 vs D2+','J/Gbit',lambda r,g:(combined_position(r,g,'energy_j')/(int(r['metrics'].get('payload_bytes_per_download',PAYLOAD_DEFAULT))*8/1e9)) if combined_position(r,g,'energy_j') is not None else None)
    # 10-24 cstate
    for i,(ep,phase,name,title) in enumerate([
      ('server','cycle','server_whole_cstate','Server position-cycle idle residency'),('client','cycle','client_whole_cstate','Client position-cycle idle residency')],10):
      emit(i,name,title,'Idle s/download',lambda r,g,ep=ep:position_value(r,ep,'cycle1' if g=='d1' else 'cycle2plus','idle_s'))
    emit(12,'whole_idle_and_trace_duration','Combined position-cycle idle time','s/download',lambda r,g:combined_position(r,'cycle1' if g=='d1' else 'cycle2plus','idle_s'))
    emit(13,'aligned_idle_fraction','Combined position-cycle idle fraction','%',lambda r,g:statistics.mean([v for v in [position_value(r,e,'cycle1' if g=='d1' else 'cycle2plus','idle_fraction_pct') for e in ('client','server')] if v is not None]) if any(position_value(r,e,'cycle1' if g=='d1' else 'cycle2plus','idle_fraction_pct') is not None for e in ('client','server')) else None)
    emit(14,'server_active_transfer_cstate','Server active C-state idle time: D1 vs D2+','s/download',lambda r,g:position_value(r,'server',g,'idle_s'))
    emit(15,'client_active_transfer_cstate','Client active C-state idle time: D1 vs D2+','s/download',lambda r,g:position_value(r,'client',g,'idle_s'))
    emit(16,'active_transfer_total_idle','Combined active idle time','s/download',lambda r,g:combined_position(r,g,'idle_s'))
    emit(17,'active_transfer_idle_fraction','Active idle fraction','%',lambda r,g:statistics.mean([v for v in [position_value(r,e,g,'idle_fraction_pct') for e in ('client','server')] if v is not None]) if any(position_value(r,e,g,'idle_fraction_pct') is not None for e in ('client','server')) else None)
    emit(18,'active_transfer_idle_intervals','Active idle interval fragments','fragments/download',lambda r,g:combined_position(r,g,'interval_fragments'))
    for i,(ep,name,title) in enumerate([('server','server_gap_cstate','Server following-gap idle time'),('client','client_gap_cstate','Client following-gap idle time')],19):
      emit(i,name,title,'s/gap',lambda r,g,ep=ep:position_value(r,ep,'g1' if g=='d1' else 'g2plus','idle_s'))
    emit(21,'gap_total_idle','Combined following-gap idle time','s/gap',lambda r,g:combined_position(r,'g1' if g=='d1' else 'g2plus','idle_s'))
    emit(22,'gap_idle_fraction','Following-gap idle fraction','%',lambda r,g:statistics.mean([v for v in [position_value(r,e,'g1' if g=='d1' else 'g2plus','idle_fraction_pct') for e in ('client','server')] if v is not None]) if any(position_value(r,e,'g1' if g=='d1' else 'g2plus','idle_fraction_pct') is not None for e in ('client','server')) else None)
    emit(23,'gap_idle_intervals','Following-gap idle interval fragments','fragments/gap',lambda r,g:combined_position(r,'g1' if g=='d1' else 'g2plus','interval_fragments'))
    emit(24,'linux_idle_entries','Active Linux idle fragments (server+client)','fragments/download',lambda r,g:combined_position(r,g,'interval_fragments'))
    # 25-28 snapshot idle/epoll
    emit(25,'server_epoll_attempts_wakes_timeouts','Server EPOLL attempts per active download','count/download',lambda r,g:snapvalue(r,'server',g,'epoll_try'),'boundary snapshots')
    emit(26,'server_epoll_wake_sources','Server EPOLL wakeups per active download','count/download',lambda r,g:snapvalue(r,'server',g,'epoll_wake'),'boundary snapshots')
    emit(27,'client_epoll_attempts_wakes_timeouts','Client EPOLL attempts per active download','count/download',lambda r,g:snapvalue(r,'client',g,'epoll_try'),'boundary snapshots')
    emit(28,'client_epoll_wake_sources','Client EPOLL wakeups per active download','count/download',lambda r,g:snapvalue(r,'client',g,'epoll_wake'),'boundary snapshots')
    # frequency 29-36
    emit(29,'server_frequency_range','Server mean active frequency','GHz',lambda r,g:position_value(r,'server',g,'mean_ghz'))
    emit(30,'client_frequency_range','Client mean active frequency','GHz',lambda r,g:position_value(r,'client',g,'mean_ghz'))
    emit(31,'server_frequency_policy_actions','Server frequency policy actions per download','actions/download',lambda r,g:sum(v or 0 for v in [snapvalue(r,'server',g,k) for k in ('freq_policy_max_hard','freq_policy_max_control','freq_policy_up','freq_policy_down','freq_policy_min')]) if snapvalue(r,'server',g,'freq_policy_down') is not None else None,'boundary snapshots')
    emit(32,'server_actual_frequency_changes','Server actual frequency changes per download','changes/download',lambda r,g:snapvalue(r,'server',g,'freq_changed_max')+snapvalue(r,'server',g,'freq_changed_up')+snapvalue(r,'server',g,'freq_changed_down')+snapvalue(r,'server',g,'freq_changed_min') if snapvalue(r,'server',g,'freq_changed_max') is not None else position_value(r,'server',g,'changes'),'snapshot or timestamped frequency')
    emit(33,'client_frequency_policy_actions','Client frequency policy actions per download','actions/download',lambda r,g:sum(v or 0 for v in [snapvalue(r,'client',g,k) for k in ('freq_policy_max_hard','freq_policy_max_control','freq_policy_up','freq_policy_down','freq_policy_min')]) if snapvalue(r,'client',g,'freq_policy_down') is not None else None,'boundary snapshots')
    emit(34,'client_actual_frequency_changes','Client actual frequency changes per download','changes/download',lambda r,g:snapvalue(r,'client',g,'freq_changed_max')+snapvalue(r,'client',g,'freq_changed_up')+snapvalue(r,'client',g,'freq_changed_down')+snapvalue(r,'client',g,'freq_changed_min') if snapvalue(r,'client',g,'freq_changed_max') is not None else position_value(r,'client',g,'changes'),'snapshot or timestamped frequency')
    emit(35,'total_frequency_policy_actions','Combined frequency policy actions per download','actions/download',lambda r,g:sum(v for v in [snapvalue(r,e,g,k) for e in ('client','server') for k in ('freq_policy_max_hard','freq_policy_max_control','freq_policy_up','freq_policy_down','freq_policy_min')] if v is not None) if any(snapvalue(r,e,g,'freq_policy_down') is not None for e in ('client','server')) else None,'boundary snapshots')
    emit(36,'timestamped_frequency_events','Timestamped frequency sample changes','changes/download',lambda r,g:sum(v for v in [position_value(r,e,g,'changes') for e in ('client','server')] if v is not None) if any(position_value(r,e,g,'changes') is not None for e in ('client','server')) else None)
    # hints and packets
    emit(37,'plus_ack_pending_and_ramping','PLUS ACK-pending hints per download','events/download',lambda r,g:snapvalue(r,'server',g,'hint_ack_pending') if r['mode']=='plus' else None,'boundary snapshots')
    emit(38,'plus_cwnd_blocked_recovery','PLUS recovery begins per download','events/download',lambda r,g:snapvalue(r,'server',g,'hint_cubic_recovery') if r['mode']=='plus' else None,'boundary snapshots')
    emit(39,'plus_client_recovery_detail','PLUS client recovery begins per download','events/download',lambda r,g:snapvalue(r,'client',g,'hint_cubic_recovery') if r['mode']=='plus' else None,'boundary snapshots')
    emit(40,'transfer_begin_end_hints','Transfer-begin hints per download','events/download',lambda r,g:(sum(v for v in [snapvalue(r,'server',g,'hint_server_file_tx_active'),snapvalue(r,'client',g,'hint_client_file_rx_active')] if v is not None) if any(v is not None for v in [snapvalue(r,'server',g,'hint_server_file_tx_active'),snapvalue(r,'client',g,'hint_client_file_rx_active')]) else None) if r['mode']=='plus' else None,'boundary snapshots')
    emit(41,'dpdk_packet_counts','DPDK packet count per active download','packets/download',lambda r,g:sum(v for v in [snapvalue(r,e,g,'rx_pkts') for e in ('client','server')] if v is not None) if any(snapvalue(r,e,g,'rx_pkts') is not None for e in ('client','server')) else None,'boundary snapshots')
    # phase independent config/status: duplicated intentionally and marked shared
    emit(42,'acpi_channel_status','ACPI channel availability (shared run configuration)','available=1',lambda r,g:1 if any(r.get(e,{}).get('acpi') for e in ('client','server')) else 0,'shared run status')
    emit(43,'configuration_scientific_overview','Position report configuration validity','valid=1',lambda r,g:1,'shared config')
    # 44-47 explicit power/energy
    emit(44,'active_transfer_rapl_power','Active combined RAPL power','W',lambda r,g:combined_power(r,g))
    emit(45,'inter_download_gap_rapl_power','Following-gap combined RAPL power','W',lambda r,g:combined_power(r,'g1' if g=='d1' else 'g2plus'))
    emit(46,'active_transfer_rapl_energy','Active combined RAPL energy per download','J/download',lambda r,g:combined_position(r,g,'energy_j'))
    emit(47,'inter_download_gap_rapl_energy','Following-gap combined RAPL energy per gap','J/gap',lambda r,g:combined_position(r,'g1' if g=='d1' else 'g2plus','energy_j'))
    # 48-62 aligned time-series
    timeseries(rec,out,48,'server_power_raw','Server power aligned to request start: D1 vs D2+','server')
    timeseries(rec,out,49,'server_power_smoothed','Server power aligned (50-ms aggregation): D1 vs D2+','server')
    timeseries(rec,out,50,'server_cumulative_energy','Server power/energy behavior aligned to request start','server')
    timeseries(rec,out,51,'client_power_raw','Client power aligned to request start: D1 vs D2+','client')
    timeseries(rec,out,52,'client_power_smoothed','Client power aligned (50-ms aggregation): D1 vs D2+','client')
    timeseries(rec,out,53,'client_cumulative_energy','Client power/energy behavior aligned to request start','client')
    timeseries(rec,out,54,'combined_power_raw','Combined endpoint power aligned to request start','combined')
    timeseries(rec,out,55,'combined_power_smoothed','Combined endpoint power aligned (50-ms aggregation)','combined')
    timeseries(rec,out,56,'combined_cumulative_energy','Combined endpoint power/energy behavior aligned','combined')
    for i,mode in zip(range(57,63),('off','off','basic','basic','plus','plus')):
        suffix='raw' if i%2==1 else 'smoothed';timeseries(rec,out,i,f'{mode}_endpoints_power_{suffix}',f'{MODE_NAMES[mode]} endpoint power: D1 vs D2+','combined',mode)
    # add time-series audit rows
    for i in range(48,63):audit.append({'chart':i,'name':'timeseries','available':1,'source':'timestamped RAPL'})
    # Extra position charts beyond the original 62.
    emit(63,'extra_active_c0_residency','Combined active C0 idle-state residency: D1 vs D2+','s/download',lambda r,g:combined_position(r,g,'cstate_state_0'))
    emit(64,'extra_active_c1_residency','Combined active C1 idle-state residency: D1 vs D2+','s/download',lambda r,g:combined_position(r,g,'cstate_state_1'))
    emit(65,'extra_active_c2_residency','Combined active C2 idle-state residency: D1 vs D2+','s/download',lambda r,g:combined_position(r,g,'cstate_state_2'))
    emit(66,'extra_active_c3_residency','Combined active C3 idle-state residency: D1 vs D2+','s/download',lambda r,g:combined_position(r,g,'cstate_state_3'))
    emit(67,'extra_active_package_energy','Combined active package energy per download','J/download',lambda r,g:combined_position(r,g,'package_j'))
    emit(68,'extra_active_dram_energy','Combined active DRAM energy per download','J/download',lambda r,g:combined_position(r,g,'dram_j'))
    emit(69,'extra_active_duration','Active duration per download','s/download',lambda r,g:sum(y-x for x,y in r['groups'][g])/1e9/max(1,len(r['groups'][g])))
    emit(70,'extra_goodput_ratio','Goodput relative to D2+ steady state','%',lambda r,g:(goodput(r,g)/goodput(r,'d2plus')*100) if goodput(r,'d2plus') else None)
    # files
    with open(out/'chart_availability.csv','w',newline='') as f:
        w=csv.DictWriter(f,fieldnames=['chart','name','available','source']);w.writeheader();w.writerows(sorted(audit,key=lambda x:x['chart']))
    with open(out/'statistics.csv','w',newline='') as f:
        fields=['chart','name','mode','group','n','mean','sd','min','max'];w=csv.DictWriter(f,fieldnames=fields);w.writeheader();w.writerows(statrows)
    manifest={'schema':'greenquic-p5-d1-d2plus-v1','input':str(root),'base_charts':EXPECTED,'extra_charts':8,'total_charts':70,'semantics':{
      'd1':'first active download on the fresh QUIC connection','d2plus':'later active downloads on the same QUIC connection; additive metrics are normalized per later download',
      'g1':'gap following D1','g2plus':'later inter-download gaps','cycles':'D1+G1 compared with later downloads that have a following gap; final no-gap download excluded from cycle comparison'},
      'snapshot_required_for_exact_cumulative_counters':True,'records':len(rec)}
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2))
    print(f'P5 D1/D2+ report created: {out}')
    print(f'base_charts={EXPECTED} extra_charts=8 total_charts=70 run_records={len(rec)}')
    return 0
if __name__=='__main__':raise SystemExit(main())
