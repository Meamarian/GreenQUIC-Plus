#!/usr/bin/env python3
from __future__ import annotations
import argparse,csv,json,statistics
from pathlib import Path
import report_p7_run as wrapper
base=wrapper.mod;CPUS=(19,20)

def client_endpoint(summary,where):
    active=(summary.get('scopes')or{}).get('active')or{};rapl=active.get('rapl')or{};freq=active.get('frequency')or{}
    if not rapl.get('available'):raise SystemExit(f'ERROR: active client RAPL unavailable in {where}')
    for cpu in CPUS:
        if str(cpu) not in freq:raise SystemExit(f'ERROR: active client CPU{cpu} frequency unavailable in {where}')
    return active,rapl,freq

def check_freq(freq,where):
    for cpu in CPUS:
        if str(cpu) not in freq:raise SystemExit(f'ERROR: active CPU{cpu} frequency unavailable in {where}')

def main()->int:
    ap=argparse.ArgumentParser();ap.add_argument('--matrix',type=Path,required=True);ap.add_argument('--runs',type=int,required=True);ap.add_argument('--connections',type=int,required=True);a=ap.parse_args();root=a.matrix.resolve();rows=[]
    for rep in range(1,a.runs+1):
        cr=root/'runs/client'/f'rep{rep:02d}'/'summary.json';sr=root/'runs/server'/f'rep{rep:02d}'/'summary.json';syncp=root/f'clock_sync_rep{rep:02d}.json'
        if not cr.is_file() or not sr.is_file() or not syncp.is_file():raise SystemExit(f'ERROR: missing P7 summary/clock-sync for rep{rep:02d}')
        c=json.loads(cr.read_text());s=json.loads(sr.read_text());sync=json.loads(syncp.read_text())
        if int(c.get('connections',0))!=a.connections or int(s.get('connections',0))!=a.connections:raise SystemExit(f'ERROR: P7 connection count mismatch rep{rep:02d}')
        ca,ce,cf=client_endpoint(c,str(cr));cwindows=c.get('windows',{}).get('active',[])
        if len(cwindows)!=1:raise SystemExit(f'ERROR: P7 client needs one exact batch window rep{rep:02d}')
        cstart,cend=map(int,cwindows[0]);offset=int(sync['client_minus_controller_monotonic_offset_ns']);swindow=[(cstart-offset,cend-offset)]
        srun=sr.parent;se=base.rapl_metrics(base.read_rapl(srun/'rapl.csv'),swindow);sf=base.frequency_metrics(base.read_jsonl(srun/'frequency.jsonl'),swindow)
        if not se.get('available'):raise SystemExit(f'ERROR: synchronized server active RAPL unavailable rep{rep:02d}')
        check_freq(sf,f'P7 server rep{rep:02d}');gp=float(c['goodput_gbps']);duration=(cend-cstart)/1e9;combined_j=float(ce['total_j'])+float(se['total_j']);combined_w=float(ce['total_w'])+float(se['total_w']);useful_gbit=int(c['useful_bytes'])*8/1e9;per=c.get('per_connection')or[]
        if len(per)!=a.connections:raise SystemExit(f'ERROR: P7 per-connection metrics missing rep{rep:02d}')
        row={'repetition':rep,'mode':'linux','connections':a.connections,'active_duration_s':duration,'aggregate_goodput_gbps':gp,'average_individual_goodput_gbps':statistics.mean(float(x['goodput_gbps']) for x in per),'server_package_j':se['package_j'],'server_dram_j':se['dram_j'],'server_total_j':se['total_j'],'server_avg_rapl_w':se['total_w'],'client_package_j':ce['package_j'],'client_dram_j':ce['dram_j'],'client_total_j':ce['total_j'],'client_avg_rapl_w':ce['total_w'],'combined_total_j':combined_j,'combined_avg_rapl_w':combined_w,'server_j_per_useful_gbit':float(se['total_j'])/useful_gbit,'client_j_per_useful_gbit':float(ce['total_j'])/useful_gbit,'combined_j_per_useful_gbit':combined_j/useful_gbit,'clock_sync_uncertainty_ms':float(sync.get('monotonic_uncertainty_ns',0))/1e6}
        for i,x in enumerate(per,1):row[f'conn{i}_duration_s']=int(x['duration_us'])/1e6;row[f'conn{i}_goodput_gbps']=float(x['goodput_gbps'])
        for prefix,freq in (('server',sf),('client',cf)):
            for cpu in CPUS:
                r=freq[str(cpu)]
                for k in ('min_ghz','mean_ghz','max_ghz'):row[f'{prefix}_cpu{cpu}_{k}']=float(r[k])
            row[f'{prefix}_dataplane_mean_ghz']=statistics.mean(float(freq[str(cpu)]['mean_ghz']) for cpu in CPUS)
        rows.append(row);print(f"P7 ACTIVE rep{rep:02d}: total_goodput={gp:.6f} Gbit/s server_RAPL={float(se['total_j']):.3f} J client_RAPL={float(ce['total_j']):.3f} J combined_RAPL={combined_j:.3f} J combined_power={combined_w:.3f} W sync_uncertainty={row['clock_sync_uncertainty_ms']:.3f}ms");print('  individual: '+' '.join(f"c{i}={row[f'conn{i}_goodput_gbps']:.6f}" for i in range(1,a.connections+1)));print(f"  server freq: CPU19={sf['19']['mean_ghz']:.3f} CPU20={sf['20']['mean_ghz']:.3f} mean={row['server_dataplane_mean_ghz']:.3f} GHz");print(f"  client freq: CPU19={cf['19']['mean_ghz']:.3f} CPU20={cf['20']['mean_ghz']:.3f} mean={row['client_dataplane_mean_ghz']:.3f} GHz")
    out=root/'parallel_tables';out.mkdir(parents=True,exist_ok=True);allp=out/'parallel_active_metrics.csv'
    with allp.open('w',newline='') as f:w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
    measures=['aggregate_goodput_gbps','average_individual_goodput_gbps','server_total_j','client_total_j','combined_total_j','server_avg_rapl_w','client_avg_rapl_w','combined_avg_rapl_w','server_j_per_useful_gbit','client_j_per_useful_gbit','combined_j_per_useful_gbit','server_cpu19_mean_ghz','server_cpu20_mean_ghz','server_dataplane_mean_ghz','client_cpu19_mean_ghz','client_cpu20_mean_ghz','client_dataplane_mean_ghz'];summary={'mode':'linux','n':len(rows),'connections':a.connections}
    for m in measures:
        vals=[float(r[m]) for r in rows];summary[f'{m}_mean']=statistics.mean(vals);summary[f'{m}_stdev']=statistics.stdev(vals) if len(vals)>1 else 0.0;summary[f'{m}_variance']=statistics.variance(vals) if len(vals)>1 else 0.0
    sump=out/'parallel_active_summary.csv'
    with sump.open('w',newline='') as f:w=csv.DictWriter(f,fieldnames=list(summary));w.writeheader();w.writerow(summary)
    print(f'P7 PARALLEL ACTIVE-WINDOW AGGREGATION PASS: {allp}');print(f'P7 ACTIVE SUMMARY: {sump}');return 0
if __name__=='__main__':raise SystemExit(main())
