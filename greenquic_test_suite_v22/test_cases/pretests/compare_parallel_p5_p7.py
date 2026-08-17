#!/usr/bin/env python3
from __future__ import annotations
import argparse,csv
from pathlib import Path


def read_one(path:Path)->list[dict[str,str]]:
    if not path.is_file():raise SystemExit(f'ERROR: missing {path}')
    with path.open(newline='',encoding='utf-8') as f:return list(csv.DictReader(f))

def f(row,key):return float(row[key])

def main()->int:
    ap=argparse.ArgumentParser();ap.add_argument('--p5',type=Path,required=True);ap.add_argument('--p7',type=Path,required=True);ap.add_argument('--out',type=Path,required=True);a=ap.parse_args()
    p5=read_one(a.p5/'parallel_tables/parallel_goodput_summary.csv');p7=read_one(a.p7/'parallel_tables/parallel_goodput_summary.csv')
    if len(p7)!=1 or p7[0].get('mode')!='linux':raise SystemExit('ERROR: P7 summary must contain one linux row')
    linux=p7[0];connections=int(linux['connections']);rows=[]
    for src in [linux]+p5:
        if int(src['connections'])!=connections:raise SystemExit(f"ERROR: connection-count mismatch for {src.get('mode')}")
        mu=f(src,'mean_goodput_gbps');sd=f(src,'stdev_goodput_gbps');var=f(src,'variance_goodput_gbps2');lm=f(linux,'mean_goodput_gbps')
        rows.append({'mode':src['mode'],'n':int(src['n']),'connections':connections,'mean_total_goodput_gbps':mu,'stdev_goodput_gbps':sd,'variance_goodput_gbps2':var,'delta_vs_linux_gbps':mu-lm,'percent_vs_linux':(mu-lm)/lm*100.0 if lm else 0.0})
    order={'linux':0,'off':1,'basic':2,'plus':3};rows.sort(key=lambda r:order.get(r['mode'],99));a.out.parent.mkdir(parents=True,exist_ok=True)
    with a.out.open('w',newline='',encoding='utf-8') as h:w=csv.DictWriter(h,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
    print('\nFAIR PARALLEL TOTAL GOODPUT COMPARISON')
    print('mode      n   mean Gbit/s      SD       variance    vs Linux')
    for r in rows:print(f"{r['mode']:<9} {r['n']:>2}  {r['mean_total_goodput_gbps']:>11.6f}  {r['stdev_goodput_gbps']:>8.6f}  {r['variance_goodput_gbps2']:>10.6f}  {r['percent_vs_linux']:>+8.2f}%")
    print(f'CSV: {a.out}')
    return 0
if __name__=='__main__':raise SystemExit(main())
