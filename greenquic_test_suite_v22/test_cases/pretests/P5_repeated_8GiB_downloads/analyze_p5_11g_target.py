#!/usr/bin/env python3
from __future__ import annotations
import argparse,csv,json,math,re,statistics
from pathlib import Path
PAYLOAD=8589934592
BITS=PAYLOAD*8.0
COMPLETE=re.compile(r"\[GreenQUIC-P5\]\s+request=(\d+)/(\d+).*?\bduration_us=(\d+).*?\bsuccess=1")

def mean_sd(v): return (statistics.mean(v), statistics.stdev(v) if len(v)>1 else 0.0)
def tcrit90(n):
    table={1:6.314,2:2.920,3:2.353,4:2.132,5:2.015,6:1.943,7:1.895,8:1.860,9:1.833,10:1.812}
    return table.get(n-1,1.645 if n>31 else 1.697)
def parse(path,downloads):
    rows={}; total=None
    for m in COMPLETE.finditer(path.read_text(errors='replace')):
        i,n,u=map(int,m.groups()); rows[i]=u; total=n
    if total!=downloads or any(i not in rows for i in range(1,downloads+1)):
        raise RuntimeError(f'incomplete timing evidence: {path}')
    ds=[rows[i] for i in range(1,downloads+1)]
    agg=BITS*downloads/(sum(ds)/1e6)/1e9
    steady=BITS*(downloads-1)/(sum(ds[1:])/1e6)/1e9 if downloads>1 else agg
    return agg,steady

def stats(case_dir,downloads):
    logs=sorted(case_dir.glob('client_rep??_plus.log'))
    if not logs: raise RuntimeError(f'no PLUS logs: {case_dir}')
    vals=[parse(p,downloads) for p in logs]
    am,asd=mean_sd([x[0] for x in vals]); sm,ssd=mean_sd([x[1] for x in vals])
    return {'n':len(vals),'aggregate_mean':am,'aggregate_sd':asd,'steady_mean':sm,'steady_sd':ssd,'steady_values':[x[1] for x in vals]}

def screen(root,downloads,target):
    spec=root/'SCREEN_CASES.tsv'
    rows=[]
    for r in csv.DictReader(spec.open(),delimiter='\t'):
        s=stats(root/r['case'],downloads)
        rows.append({**r,**s,'target_reached_screen':s['steady_mean']>=target})
    rows.sort(key=lambda r:(r['steady_mean'],r['aggregate_mean']),reverse=True)
    winner=rows[0]
    with (root/'SCREEN_SUMMARY.tsv').open('w',newline='') as f:
        fields=['case','binary_profile','rx_empty_polls','tx_empty_polls','active_transfer_sleep_min_level','n','aggregate_mean','aggregate_sd','steady_mean','steady_sd','target_reached_screen']
        w=csv.DictWriter(f,fieldnames=fields,delimiter='\t',extrasaction='ignore');w.writeheader();w.writerows(rows)
    (root/'WINNER.env').write_text('\n'.join([
        f"winner_case={winner['case']}",f"winner_binary_profile={winner['binary_profile']}",
        f"winner_rx_empty_polls={winner['rx_empty_polls']}",f"winner_tx_empty_polls={winner['tx_empty_polls']}",
        f"winner_active_transfer_sleep_min_level={winner['active_transfer_sleep_min_level']}",
        f"winner_screen_steady_gbps={winner['steady_mean']:.9f}",f"target_gbps={target:.6f}"])+'\n')
    out={'schema':'greenquic-p5-onecore-11g-screen-v1','target_gbps':target,'winner':winner,'rows':rows,
         'rule':'screen is directional only; target requires repeated validation'}
    (root/'SCREEN_SUMMARY.json').write_text(json.dumps(out,indent=2)+'\n')
    print(f"11G SCREEN WINNER case={winner['case']} steady={winner['steady_mean']:.6f} Gbit/s")
    if winner['steady_mean']>=target: print('11G SCREEN PASS (directional only; repeated validation still required)')
    else: print('11G SCREEN BELOW TARGET; validating best candidate anyway')

def validation(root,downloads,target,min_robust):
    win=stats(root/'validation_winner',downloads); ref=stats(root/'validation_super_reference',downloads)
    n=win['n']; mean=win['steady_mean']; sd=win['steady_sd']
    half=tcrit90(n)*sd/math.sqrt(n) if n>1 else math.inf
    lo,hi=(mean-half,mean+half) if math.isfinite(half) else (float('-inf'),float('inf'))
    mean_pass=mean>=target; robust=n>=min_robust and lo>=target
    out={'schema':'greenquic-p5-onecore-11g-validation-v1','target_gbps':target,'winner':win,'super_reference':ref,
         'winner_ci90_low_gbps':lo,'winner_ci90_high_gbps':hi,'mean_target_pass':mean_pass,
         'robust_target_pass':robust,'robust_min_runs':min_robust}
    (root/'VALIDATION_SUMMARY.json').write_text(json.dumps(out,indent=2)+'\n')
    with (root/'VALIDATION_SUMMARY.tsv').open('w',newline='') as f:
        fields=['case','n','aggregate_mean','aggregate_sd','steady_mean','steady_sd','ci90_low','ci90_high','target_pass']
        w=csv.DictWriter(f,fieldnames=fields,delimiter='\t');w.writeheader();
        w.writerow({'case':'winner','n':n,'aggregate_mean':win['aggregate_mean'],'aggregate_sd':win['aggregate_sd'],'steady_mean':mean,'steady_sd':sd,'ci90_low':lo,'ci90_high':hi,'target_pass':int(mean_pass)})
        w.writerow({'case':'super_reference','n':ref['n'],'aggregate_mean':ref['aggregate_mean'],'aggregate_sd':ref['aggregate_sd'],'steady_mean':ref['steady_mean'],'steady_sd':ref['steady_sd'],'ci90_low':'NA','ci90_high':'NA','target_pass':int(ref['steady_mean']>=target)})
    print(f"11G VALIDATION winner steady={mean:.6f} sd={sd:.6f} n={n} CI90=[{lo:.6f},{hi:.6f}]")
    print(f"SUPER REFERENCE steady={ref['steady_mean']:.6f} Gbit/s")
    if mean_pass: print('11G PASS')
    else: print('11G TARGET NOT REACHED')
    if robust: print('11G ROBUST PASS (90% CI lower bound >= target)')
    elif n>=min_robust: print('11G ROBUST PASS NOT ESTABLISHED')

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--root',type=Path,required=True);ap.add_argument('--phase',choices=['screen','validation'],required=True);ap.add_argument('--downloads',type=int,required=True);ap.add_argument('--target-gbps',type=float,default=11.0);ap.add_argument('--robust-min-runs',type=int,default=6);a=ap.parse_args()
    if a.phase=='screen': screen(a.root.resolve(),a.downloads,a.target_gbps)
    else: validation(a.root.resolve(),a.downloads,a.target_gbps,a.robust_min_runs)
if __name__=='__main__': main()
