#!/usr/bin/env python3
from __future__ import annotations
import argparse,csv,json,statistics
from pathlib import Path
CPUS=(19,20)

def need(d,k,where):
    v=d.get(k)
    if v is None:raise SystemExit(f'ERROR: missing {k} in {where}')
    return v

def endpoint(summary:dict,where:str):
    active=need(need(summary,'scopes',where),'active',where);rapl=need(active,'rapl',where);freq=need(active,'frequency',where)
    if not rapl.get('available'):raise SystemExit(f'ERROR: active RAPL unavailable in {where}')
    f={}
    for cpu in CPUS:
        r=freq.get(str(cpu))
        if not r:raise SystemExit(f'ERROR: active CPU{cpu} frequency unavailable in {where}')
        f[cpu]=r
    return active,rapl,f

def main()->int:
    ap=argparse.ArgumentParser();ap.add_argument('--matrix',type=Path,required=True);ap.add_argument('--runs',type=int,required=True);ap.add_argument('--connections',type=int,required=True);a=ap.parse_args();root=a.matrix.resolve();rows=[]
    for rep in range(1,a.runs+1):
        cr=root/'runs/client'/f'rep{rep:02d}'/'summary.json';sr=root/'runs/server'/f'rep{rep:02d}'/'summary.json'
        if not cr.is_file() or not sr.is_file():raise SystemExit(f'ERROR: missing P7 summary for rep{rep:02d}')
        c=json.loads(cr.read_text());s=json.loads(sr.read_text())
        if int(c.get('connections',0))!=a.connections or int(s.get('connections',0))!=a.connections:raise SystemExit(f'ERROR: P7 connection count mismatch rep{rep:02d}')
        ca,ce,cf=endpoint(c,str(cr));sa,se,sf=endpoint(s,str(sr));gp=float(need(c,'goodput_gbps',str(cr)));duration=float(ca['duration_s']);combined_j=float(ce['total_j'])+float(se['total_j']);combined_w=float(ce['total_w'])+float(se['total_w']);useful_gbit=int(c['useful_bytes'])*8/1e9
        row={'repetition':rep,'mode':'linux','connections':a.connections,'active_duration_s':duration,'aggregate_goodput_gbps':gp,'server_package_j':se['package_j'],'server_dram_j':se['dram_j'],'server_total_j':se['total_j'],'server_avg_rapl_w':se['total_w'],'client_package_j':ce['package_j'],'client_dram_j':ce['dram_j'],'client_total_j':ce['total_j'],'client_avg_rapl_w':ce['total_w'],'combined_total_j':combined_j,'combined_avg_rapl_w':combined_w,'combined_j_per_useful_gbit':combined_j/useful_gbit}
        for prefix,f in (('server',sf),('client',cf)):
            for cpu in CPUS:
                for k in ('min_ghz','mean_ghz','max_ghz'):row[f'{prefix}_cpu{cpu}_{k}']=float(f[cpu][k])
            row[f'{prefix}_dataplane_mean_ghz']=statistics.mean(float(f[c]['mean_ghz']) for c in CPUS)
        rows.append(row);print(f"P7 ACTIVE rep{rep:02d}: total_goodput={gp:.6f} Gbit/s combined_RAPL={combined_j:.3f} J combined_power={combined_w:.3f} W");print(f"  server freq: CPU19={sf[19]['mean_ghz']:.3f} CPU20={sf[20]['mean_ghz']:.3f} mean={row['server_dataplane_mean_ghz']:.3f} GHz");print(f"  client freq: CPU19={cf[19]['mean_ghz']:.3f} CPU20={cf[20]['mean_ghz']:.3f} mean={row['client_dataplane_mean_ghz']:.3f} GHz")
    out=root/'parallel_tables';out.mkdir(parents=True,exist_ok=True);allp=out/'parallel_active_metrics.csv'
    with allp.open('w',newline='') as f:w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
    measures=['aggregate_goodput_gbps','combined_total_j','combined_avg_rapl_w','combined_j_per_useful_gbit','server_dataplane_mean_ghz','client_dataplane_mean_ghz'];summary={'mode':'linux','n':len(rows),'connections':a.connections}
    for m in measures:
        vals=[float(r[m]) for r in rows];summary[f'{m}_mean']=statistics.mean(vals);summary[f'{m}_stdev']=statistics.stdev(vals) if len(vals)>1 else 0.0;summary[f'{m}_variance']=statistics.variance(vals) if len(vals)>1 else 0.0
    sump=out/'parallel_active_summary.csv'
    with sump.open('w',newline='') as f:w=csv.DictWriter(f,fieldnames=list(summary));w.writeheader();w.writerow(summary)
    print(f'P7 PARALLEL ACTIVE-WINDOW AGGREGATION PASS: {allp}');print(f'P7 ACTIVE SUMMARY: {sump}');return 0
if __name__=='__main__':raise SystemExit(main())
