#!/usr/bin/env python3
from __future__ import annotations

import argparse,csv,re,statistics
from pathlib import Path

MODES=('off','basic','plus')
NAME_RE=re.compile(r'client_rep(\d+)_(off|basic|plus)\.log$')
GP_RE=re.compile(r'^- Aggregate goodput excluding gaps:\s*([0-9.]+)\s+Gbit/s$',re.M)
CONN_RE=re.compile(r'^- QUIC connections:\s*(\d+)\s*$',re.M)
PORT_RE=re.compile(r'^- Local UDP ports:\s*([0-9,]+)\s*$',re.M)


def main()->int:
    ap=argparse.ArgumentParser();ap.add_argument('--matrix',type=Path,required=True);ap.add_argument('--expected-runs',type=int,required=True);ap.add_argument('--connections',type=int,required=True);a=ap.parse_args()
    root=a.matrix.resolve(); rows=[]
    for p in sorted(root.glob('client_rep*_*.log')):
        m=NAME_RE.match(p.name)
        if not m:continue
        text=p.read_text(encoding='utf-8',errors='replace');g=GP_RE.findall(text);c=CONN_RE.findall(text);ports=PORT_RE.findall(text)
        if not g:raise SystemExit(f'ERROR: aggregate goodput missing from {p}')
        if not c or int(c[-1])!=a.connections:raise SystemExit(f'ERROR: connection count mismatch in {p}')
        plist=[int(x) for x in ports[-1].split(',')] if ports else []
        if len(plist)!=a.connections or len(set(plist))!=a.connections:raise SystemExit(f'ERROR: local UDP port list invalid in {p}: {plist}')
        rows.append({'repetition':int(m.group(1)),'mode':m.group(2),'connections':a.connections,'local_udp_ports':ports[-1],'aggregate_goodput_gbps':float(g[-1]),'source':str(p)})
    for mode in MODES:
        q=[r for r in rows if r['mode']==mode]
        if len(q)!=a.expected_runs:raise SystemExit(f'ERROR: {mode} has {len(q)}/{a.expected_runs} repetitions')
    tables=root/'parallel_tables';tables.mkdir(parents=True,exist_ok=True)
    with (tables/'parallel_goodput_all_runs.csv').open('w',newline='',encoding='utf-8') as f:
        w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(sorted(rows,key=lambda r:(r['mode'],r['repetition'])))
    summary=[]
    for mode in MODES:
        vals=[r['aggregate_goodput_gbps'] for r in rows if r['mode']==mode]
        summary.append({'mode':mode,'n':len(vals),'connections':a.connections,'mean_goodput_gbps':statistics.mean(vals),'stdev_goodput_gbps':statistics.stdev(vals) if len(vals)>1 else 0.0,'variance_goodput_gbps2':statistics.variance(vals) if len(vals)>1 else 0.0,'min_goodput_gbps':min(vals),'max_goodput_gbps':max(vals)})
    with (tables/'parallel_goodput_summary.csv').open('w',newline='',encoding='utf-8') as f:
        w=csv.DictWriter(f,fieldnames=list(summary[0]));w.writeheader();w.writerows(summary)
    print('\nP5 PARALLEL AGGREGATE GOODPUT')
    print('mode      n   mean Gbit/s   SD       variance')
    for r in summary:print(f"{r['mode']:<9} {r['n']:>2}  {r['mean_goodput_gbps']:>11.6f}  {r['stdev_goodput_gbps']:>7.6f}  {r['variance_goodput_gbps2']:>10.6f}")
    print(f'CSV: {tables/"parallel_goodput_summary.csv"}')
    return 0
if __name__=='__main__':raise SystemExit(main())
