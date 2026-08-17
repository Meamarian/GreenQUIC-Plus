#!/usr/bin/env python3
from __future__ import annotations

import argparse,csv,json,statistics
from pathlib import Path

MODES=('off','basic','plus')
CPUS=(19,20)

def one(root:Path,pattern:str)->Path:
    rows=list(root.rglob(pattern))
    if len(rows)!=1:raise SystemExit(f'ERROR: expected exactly one {pattern} under {root}, found {len(rows)}')
    return rows[0]

def read_rapl(path:Path):
    data=[];lines=[]
    for raw in path.read_text(encoding='utf-8',errors='replace').splitlines():
        if raw and not raw.startswith('#'):lines.append(raw)
    for row in csv.DictReader(lines):
        try:data.append({k:float(v) for k,v in row.items() if k and v not in (None,'')})
        except ValueError:continue
    if not data or 'sample_monotonic_ns' not in data[0]:raise SystemExit(f'ERROR: invalid RAPL CSV {path}')
    return data

def rapl_metrics(rows,start_ns:int,end_ns:int):
    pkg=dram=0.0;n=0
    for row in rows:
        sample_end=int(row['sample_monotonic_ns']);interval_ns=max(1,int(row['actual_interval_ms']*1_000_000.0));sample_start=sample_end-interval_ns
        a=max(sample_start,start_ns);b=min(sample_end,end_ns)
        if b<=a:continue
        frac=(b-a)/interval_ns;pkg+=row.get('package_delta_j',0.0)*frac;dram+=row.get('dram_delta_j',0.0)*frac;n+=1
    duration=(end_ns-start_ns)/1e9
    if n==0 or duration<=0:raise SystemExit('ERROR: no RAPL samples overlap active window')
    total=pkg+dram
    return {'samples':n,'duration_s':duration,'package_j':pkg,'dram_j':dram,'total_j':total,'avg_total_w':total/duration}

def read_freq(path:Path):
    by={}
    for raw in path.read_text(encoding='utf-8',errors='replace').splitlines():
        try:r=json.loads(raw)
        except Exception:continue
        if r.get('type')!='line':continue
        try:cpu=int(r['cpu']);t=int(r['monotonic_ns']);ghz=float(r['freq_khz'])/1e6
        except (KeyError,TypeError,ValueError):continue
        by.setdefault(cpu,[]).append((t,ghz))
    return by

def cells(samples):
    s=sorted(samples)
    if not s:return []
    if len(s)==1:return [(s[0][0]-500_000,s[0][0]+500_000,s[0][1])]
    out=[]
    for i,(t,v) in enumerate(s):
        left=(s[i-1][0]+t)//2 if i else t-(s[1][0]-t)//2
        right=(t+s[i+1][0])//2 if i+1<len(s) else t+(t-s[i-1][0])//2
        if right>left:out.append((left,right,v))
    return out

def freq_metrics(by,start_ns:int,end_ns:int):
    out={}
    for cpu in CPUS:
        weighted=0.0;covered=0;seen=[];n=0
        for a,b,v in cells(by.get(cpu,[])):
            ov=max(0,min(b,end_ns)-max(a,start_ns))
            if not ov:continue
            weighted+=v*ov;covered+=ov;seen.append(v);n+=1
        if not covered:raise SystemExit(f'ERROR: CPU{cpu} has no frequency samples in active window')
        out[cpu]={'samples':n,'min_ghz':min(seen),'mean_ghz':weighted/covered,'max_ghz':max(seen),'covered_s':covered/1e9}
    out['dataplane_mean_ghz']=statistics.mean(out[c]['mean_ghz'] for c in CPUS)
    return out

def flatten_freq(row,prefix,f):
    for cpu in CPUS:
        for key in ('min_ghz','mean_ghz','max_ghz'):
            row[f'{prefix}_cpu{cpu}_{key}']=f[cpu][key]
    row[f'{prefix}_dataplane_mean_ghz']=f['dataplane_mean_ghz']

def main()->int:
    ap=argparse.ArgumentParser();ap.add_argument('--matrix',type=Path,required=True);ap.add_argument('--runs',type=int,required=True);ap.add_argument('--connections',type=int,required=True);a=ap.parse_args();root=a.matrix.resolve();rows=[];json_dir=root/'parallel_active_metrics';json_dir.mkdir(parents=True,exist_ok=True)
    for rep in range(1,a.runs+1):
        for mode in MODES:
            run_id=f'rep{rep:02d}_{mode}';croot=root/'runs/client'/run_id;sroot=root/'runs/server'/run_id
            if not croot.is_dir() or not sroot.is_dir():raise SystemExit(f'ERROR: missing unified P5 bundles for {run_id}')
            metrics=json.loads(one(croot,'*p5_parallel_metrics_*.json').read_text());conns=metrics.get('connections',[])
            if int(metrics.get('quic_connections',0))!=a.connections or len(conns)!=a.connections:raise SystemExit(f'ERROR: bad parallel metrics for {run_id}')
            cstart=int(metrics['batch_start_us'])*1000;cend=int(metrics['batch_complete_us'])*1000
            if cend<=cstart:raise SystemExit(f'ERROR: non-positive client active window for {run_id}')
            syncp=root/f'clock_sync_{run_id}.json'
            if not syncp.is_file():raise SystemExit(f'ERROR: clock sync missing for {run_id}: {syncp}')
            sync=json.loads(syncp.read_text());offset=int(sync['client_minus_controller_monotonic_offset_ns']);sstart=cstart-offset;send=cend-offset
            cr=rapl_metrics(read_rapl(one(croot,'*_msr_power.csv')),cstart,cend);sr=rapl_metrics(read_rapl(one(sroot,'*_msr_power.csv')),sstart,send)
            cf=freq_metrics(read_freq(one(croot,'*_frequency_samples.jsonl')),cstart,cend);sf=freq_metrics(read_freq(one(sroot,'*_frequency_samples.jsonl')),sstart,send)
            total_bytes=int(metrics['payload_bytes_total']);useful_gbit=total_bytes*8/1e9;combined_j=cr['total_j']+sr['total_j'];combined_w=cr['avg_total_w']+sr['avg_total_w']
            row={'repetition':rep,'mode':mode,'connections':a.connections,'active_duration_s':(cend-cstart)/1e9,'aggregate_goodput_gbps':float(metrics['aggregate_goodput_gbps']),'average_individual_goodput_gbps':statistics.mean(float(x['goodput_gbps']) for x in conns),'server_package_j':sr['package_j'],'server_dram_j':sr['dram_j'],'server_total_j':sr['total_j'],'server_avg_rapl_w':sr['avg_total_w'],'client_package_j':cr['package_j'],'client_dram_j':cr['dram_j'],'client_total_j':cr['total_j'],'client_avg_rapl_w':cr['avg_total_w'],'combined_total_j':combined_j,'combined_avg_rapl_w':combined_w,'combined_j_per_useful_gbit':combined_j/useful_gbit,'clock_sync_uncertainty_ms':float(sync.get('monotonic_uncertainty_ns',0))/1e6}
            for i,x in enumerate(conns,1):row[f'conn{i}_duration_s']=int(x['duration_us'])/1e6;row[f'conn{i}_goodput_gbps']=float(x['goodput_gbps'])
            flatten_freq(row,'server',sf);flatten_freq(row,'client',cf)
            detail={'schema':'greenquic-p5-parallel-active-v1','run_id':run_id,'timing_definition':'parallel batch start to parallel batch complete; client CLOCK_MONOTONIC mapped to server CLOCK_MONOTONIC with pre-run clock_sync','client_window_ns':[cstart,cend],'server_window_ns':[sstart,send],'clock_sync':{'client_minus_server_monotonic_offset_ns':offset,'uncertainty_ns':int(sync.get('monotonic_uncertainty_ns',0))},'goodput':{'aggregate_gbps':row['aggregate_goodput_gbps'],'connections':conns},'rapl':{'server':sr,'client':cr,'combined_total_j':combined_j,'combined_avg_w':combined_w,'combined_j_per_useful_gbit':row['combined_j_per_useful_gbit']},'frequency':{'server':sf,'client':cf}}
            (json_dir/f'{run_id}.json').write_text(json.dumps(detail,indent=2)+'\n');rows.append(row)
            print(f"P5 ACTIVE {run_id}: total_goodput={row['aggregate_goodput_gbps']:.6f} Gbit/s combined_RAPL={combined_j:.3f} J combined_power={combined_w:.3f} W")
            print('  individual: '+' '.join(f"c{i}={row[f'conn{i}_goodput_gbps']:.6f}" for i in range(1,a.connections+1)))
            print(f"  server freq: CPU19={sf[19]['mean_ghz']:.3f} CPU20={sf[20]['mean_ghz']:.3f} mean={sf['dataplane_mean_ghz']:.3f} GHz")
            print(f"  client freq: CPU19={cf[19]['mean_ghz']:.3f} CPU20={cf[20]['mean_ghz']:.3f} mean={cf['dataplane_mean_ghz']:.3f} GHz")
    out=root/'parallel_tables';out.mkdir(parents=True,exist_ok=True)
    allp=out/'parallel_active_metrics.csv'
    with allp.open('w',newline='') as f:w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
    measures=['aggregate_goodput_gbps','average_individual_goodput_gbps','combined_total_j','combined_avg_rapl_w','combined_j_per_useful_gbit','server_dataplane_mean_ghz','client_dataplane_mean_ghz'];summ=[]
    for mode in MODES:
        subset=[r for r in rows if r['mode']==mode]
        s={'mode':mode,'n':len(subset),'connections':a.connections}
        for m in measures:
            vals=[float(r[m]) for r in subset];s[f'{m}_mean']=statistics.mean(vals);s[f'{m}_stdev']=statistics.stdev(vals) if len(vals)>1 else 0.0;s[f'{m}_variance']=statistics.variance(vals) if len(vals)>1 else 0.0
        summ.append(s)
    sump=out/'parallel_active_summary.csv'
    with sump.open('w',newline='') as f:w=csv.DictWriter(f,fieldnames=list(summ[0]));w.writeheader();w.writerows(summ)
    print(f'P5 PARALLEL ACTIVE-WINDOW ANALYSIS PASS: {allp}');print(f'P5 ACTIVE SUMMARY: {sump}');return 0
if __name__=='__main__':raise SystemExit(main())
