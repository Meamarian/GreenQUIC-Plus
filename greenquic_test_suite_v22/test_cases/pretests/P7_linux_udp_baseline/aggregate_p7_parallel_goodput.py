#!/usr/bin/env python3
from __future__ import annotations
import argparse,csv,json,statistics
from pathlib import Path

def main()->int:
    ap=argparse.ArgumentParser();ap.add_argument('--matrix',type=Path,required=True);ap.add_argument('--runs',type=int,required=True);ap.add_argument('--connections',type=int,required=True);a=ap.parse_args();root=a.matrix.resolve();rows=[]
    for i,d in enumerate(sorted((root/'runs/client').glob('rep*')),1):
        p=d/'summary.json'
        if not p.is_file():raise SystemExit(f'ERROR: missing {p}')
        s=json.load(open(p));gp=float(s.get('goodput_gbps') or 0);conn=int(s.get('connections') or 0)
        if gp<=0 or conn!=a.connections:raise SystemExit(f'ERROR: invalid P7 parallel summary {p}: gp={gp} connections={conn}')
        rows.append({'repetition':i,'mode':'linux','connections':conn,'aggregate_goodput_gbps':gp,'source':str(p)})
    if len(rows)!=a.runs:raise SystemExit(f'ERROR: P7 has {len(rows)}/{a.runs} runs')
    vals=[r['aggregate_goodput_gbps'] for r in rows];out=root/'parallel_tables';out.mkdir(parents=True,exist_ok=True)
    with (out/'parallel_goodput_all_runs.csv').open('w',newline='') as f:w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
    summary={'mode':'linux','n':len(vals),'connections':a.connections,'mean_goodput_gbps':statistics.mean(vals),'stdev_goodput_gbps':statistics.stdev(vals) if len(vals)>1 else 0.0,'variance_goodput_gbps2':statistics.variance(vals) if len(vals)>1 else 0.0,'min_goodput_gbps':min(vals),'max_goodput_gbps':max(vals)}
    with (out/'parallel_goodput_summary.csv').open('w',newline='') as f:w=csv.DictWriter(f,fieldnames=list(summary));w.writeheader();w.writerow(summary)
    print(f"P7 Linux parallel goodput: n={len(vals)} mean={summary['mean_goodput_gbps']:.6f} Gbit/s SD={summary['stdev_goodput_gbps']:.6f} variance={summary['variance_goodput_gbps2']:.6f}")
    print(f"CSV: {out/'parallel_goodput_summary.csv'}")
    return 0
if __name__=='__main__':raise SystemExit(main())
