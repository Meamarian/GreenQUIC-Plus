#!/usr/bin/env python3
from __future__ import annotations
import argparse,csv
from pathlib import Path

def read(path):
    if not path.is_file():raise SystemExit(f'ERROR: missing {path}')
    with path.open(newline='',encoding='utf-8') as f:return list(csv.DictReader(f))
def fl(r,k):return float(r[k])
def pct(v,b):return (v-b)/b*100.0 if b else 0.0

def main()->int:
    ap=argparse.ArgumentParser();ap.add_argument('--p5',type=Path,required=True);ap.add_argument('--p7',type=Path,required=True);ap.add_argument('--out',type=Path,required=True);a=ap.parse_args()
    p5=read(a.p5/'parallel_tables/parallel_goodput_summary.csv');p7=read(a.p7/'parallel_tables/parallel_goodput_summary.csv')
    if len(p7)!=1 or p7[0].get('mode')!='linux':raise SystemExit('ERROR: P7 summary must contain one linux row')
    linux=p7[0];connections=int(linux['connections']);rows=[]
    for src in [linux]+p5:
        if int(src['connections'])!=connections:raise SystemExit(f"ERROR: connection-count mismatch for {src.get('mode')}")
        mu=fl(src,'mean_goodput_gbps');lm=fl(linux,'mean_goodput_gbps');rows.append({'mode':src['mode'],'n':int(src['n']),'connections':connections,'mean_total_goodput_gbps':mu,'stdev_goodput_gbps':fl(src,'stdev_goodput_gbps'),'variance_goodput_gbps2':fl(src,'variance_goodput_gbps2'),'delta_vs_linux_gbps':mu-lm,'percent_goodput_vs_linux':pct(mu,lm)})
    order={'linux':0,'off':1,'basic':2,'plus':3};rows.sort(key=lambda r:order.get(r['mode'],99));a.out.parent.mkdir(parents=True,exist_ok=True)
    with a.out.open('w',newline='',encoding='utf-8') as h:w=csv.DictWriter(h,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
    print('\nFAIR PARALLEL TOTAL GOODPUT COMPARISON');print('mode      n   mean Gbit/s      SD       variance    vs Linux')
    for r in rows:print(f"{r['mode']:<9} {r['n']:>2}  {r['mean_total_goodput_gbps']:>11.6f}  {r['stdev_goodput_gbps']:>8.6f}  {r['variance_goodput_gbps2']:>10.6f}  {r['percent_goodput_vs_linux']:>+8.2f}%")

    p5a=read(a.p5/'parallel_tables/parallel_active_summary.csv');p7a=read(a.p7/'parallel_tables/parallel_active_summary.csv')
    if len(p7a)!=1 or p7a[0].get('mode')!='linux':raise SystemExit('ERROR: P7 active summary must contain one linux row')
    la=p7a[0];active=[]
    keys=('aggregate_goodput_gbps','combined_total_j','combined_avg_rapl_w','combined_j_per_useful_gbit','server_dataplane_mean_ghz','client_dataplane_mean_ghz')
    for src in [la]+p5a:
        if int(src['connections'])!=connections:raise SystemExit(f"ERROR: active connection-count mismatch for {src.get('mode')}")
        r={'mode':src['mode'],'n':int(src['n']),'connections':connections}
        for k in keys:
            val=fl(src,f'{k}_mean');base=fl(la,f'{k}_mean');r[f'{k}_mean']=val;r[f'{k}_stdev']=fl(src,f'{k}_stdev');r[f'{k}_variance']=fl(src,f'{k}_variance');r[f'{k}_percent_vs_linux']=pct(val,base)
        active.append(r)
    active.sort(key=lambda r:order.get(r['mode'],99));active_out=a.out.with_name(a.out.stem+'_active'+a.out.suffix)
    with active_out.open('w',newline='',encoding='utf-8') as h:w=csv.DictWriter(h,fieldnames=list(active[0]));w.writeheader();w.writerows(active)
    print('\nFAIR PARALLEL ACTIVE-WINDOW COMPARISON');print('mode      goodput    energy J   power W   J/Gbit   srv GHz  cli GHz')
    for r in active:print(f"{r['mode']:<9} {r['aggregate_goodput_gbps_mean']:>8.3f}  {r['combined_total_j_mean']:>9.1f}  {r['combined_avg_rapl_w_mean']:>8.2f}  {r['combined_j_per_useful_gbit_mean']:>7.3f}  {r['server_dataplane_mean_ghz_mean']:>7.3f}  {r['client_dataplane_mean_ghz_mean']:>7.3f}")
    print(f'Goodput CSV: {a.out}');print(f'Active metrics CSV: {active_out}');return 0
if __name__=='__main__':raise SystemExit(main())
