#!/usr/bin/env python3
from __future__ import annotations
import argparse, csv, json, math, statistics
from pathlib import Path


def get(d, *ks):
    for k in ks:
        if not isinstance(d, dict): return None
        d=d.get(k)
    return d

def stats(vals):
    a=[float(x) for x in vals if x is not None and math.isfinite(float(x))]
    if not a: return {'n':0,'mean':None,'sd':None,'variance':None}
    if len(a)==1: return {'n':1,'mean':a[0],'sd':None,'variance':None}
    return {'n':len(a),'mean':statistics.mean(a),'sd':statistics.stdev(a),'variance':statistics.variance(a)}

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--matrix-dir',type=Path,required=True)
    ap.add_argument('--runs',type=int,required=True)
    args=ap.parse_args()
    rows=[]
    for rep in range(1,args.runs+1):
        sp=args.matrix_dir/'runs'/'server'/f'rep{rep:02d}'/'summary.json'
        cp=args.matrix_dir/'runs'/'client'/f'rep{rep:02d}'/'summary.json'
        if not sp.is_file() or not cp.is_file():
            raise SystemExit(f'missing summary for repetition {rep}: {sp} / {cp}')
        s=json.loads(sp.read_text()); c=json.loads(cp.read_text())
        row={'repetition':rep,'goodput_gbps':c.get('goodput_gbps'),'gap_inclusive_goodput_gbps':c.get('gap_inclusive_goodput_gbps')}
        for scope in ('pre_cool','active','gap','combined','post_cool'):
            se=get(s,'scopes',scope,'rapl') or {}; ce=get(c,'scopes',scope,'rapl') or {}
            sj=se.get('total_j'); cj=ce.get('total_j')
            sw=se.get('total_w'); cw=ce.get('total_w')
            row[f'server_{scope}_energy_j']=sj; row[f'client_{scope}_energy_j']=cj
            row[f'server_{scope}_power_w']=sw; row[f'client_{scope}_power_w']=cw
            row[f'combined_{scope}_energy_j']=(sj+cj) if sj is not None and cj is not None else None
            row[f'combined_{scope}_power_w']=(sw + cw) if sw is not None and cw is not None else None
        bits=float(c['useful_bytes'])*8.0; gbit=bits/1e9
        for scope in ('active','combined'):
            e=row.get(f'combined_{scope}_energy_j')
            row[f'combined_{scope}_j_per_useful_gbit']=e/gbit if e is not None and gbit else None
        rows.append(row)

    fields=list(rows[0])
    out=args.matrix_dir/'p7_all_runs.csv'
    with out.open('w',newline='') as f:
        w=csv.DictWriter(f,fieldnames=fields); w.writeheader(); w.writerows(rows)
    summary={k:stats([r.get(k) for r in rows]) for k in fields if k!='repetition'}
    (args.matrix_dir/'p7_statistics.json').write_text(json.dumps(summary,indent=2)+'\n')
    with (args.matrix_dir/'p7_statistics.csv').open('w',newline='') as f:
        w=csv.DictWriter(f,fieldnames=['metric','n','mean','sd','variance']); w.writeheader()
        for k,v in summary.items(): w.writerow({'metric':k,**v})
    print(f'P7 matrix aggregated: n={len(rows)}')
    for k in ('goodput_gbps','combined_active_energy_j','combined_active_j_per_useful_gbit','combined_combined_energy_j','combined_combined_j_per_useful_gbit'):
        v=summary.get(k); print(k,v)
    return 0
if __name__=='__main__': raise SystemExit(main())
