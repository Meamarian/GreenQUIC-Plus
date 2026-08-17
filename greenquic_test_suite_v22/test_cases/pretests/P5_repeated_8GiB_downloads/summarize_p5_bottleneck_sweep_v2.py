#!/usr/bin/env python3
from __future__ import annotations
import argparse,csv,json,re
from pathlib import Path
CASE_RE=re.compile(r'^[A-T]_')
def pct(v,b): return ((v/b)-1.0)*100.0 if b else 0.0
def envfile(p):
 out={}
 if p.is_file():
  for raw in p.read_text(encoding='utf-8',errors='replace').splitlines():
   if '=' in raw and not raw.lstrip().startswith('#'):
    k,v=raw.split('=',1);out[k.strip()]=v.strip()
 return out
def num(r,k,d=0.0):
 try:return float(r.get(k,d))
 except:return d
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--root',type=Path,required=True);a=ap.parse_args();root=a.root.resolve();rows=[]
 for d in sorted(x for x in root.iterdir() if x.is_dir() and CASE_RE.match(x.name)):
  sp=d/'bottleneck_tables/case_summary.json';cp=d/'BOTTLENECK_CASE_CONFIG.env';bp=d/'BUILD_PROFILE.env';cfg=envfile(cp);build=envfile(bp)
  base={'case':d.name,'reference':build.get('comparison_reference',''),'build_profile':build.get('build_profile',''),'quic_cpus':cfg.get('quic_cpus',''),'dpdk_cpus':cfg.get('dpdk_lcores','')}
  if not sp.is_file():rows.append({**base,'status':'MISSING_OR_FAILED'});continue
  try:j=json.loads(sp.read_text(encoding='utf-8'))
  except Exception as e:rows.append({**base,'status':f'INVALID:{e}'});continue
  dp=[int(x) for x in j.get('dpdk_cpus',[])];q=[int(x) for x in cfg.get('quic_cpus','').split(',') if x.strip().isdigit()]
  r={**base,'status':'PASS','runs':int(j.get('runs',0)),'connections':int(j.get('connections',0)),'mean_goodput_gbps':num(j,'aggregate_goodput_gbps_mean'),'stdev_goodput_gbps':num(j,'aggregate_goodput_gbps_stdev'),'mean_connection_goodput_gbps':num(j,'mean_connection_goodput_gbps_mean'),'combined_rapl_w':num(j,'combined_rapl_w_mean'),'all_configured_dpdk_lcores_engaged':int(bool(j.get('all_configured_dpdk_lcores_engaged'))),'tx_hash_fallback_total':int(j.get('tx_hash_fallback_total',0))}
  for role in ('server','client'):
   for cpu in range(19,25):r[f'{role}_cpu{cpu}_busy_pct']=num(j,f'{role}_cpu{cpu}_busy_pct_mean')
   r[f'{role}_configured_dpdk_busy_max_pct']=max([r[f'{role}_cpu{x}_busy_pct'] for x in dp],default=0.0)
   r[f'{role}_configured_quic_busy_max_pct']=max([r.get(f'{role}_cpu{x}_busy_pct',0.0) for x in q],default=0.0)
  rows.append(r)
 passed=[r for r in rows if r.get('status')=='PASS'];by={r['case']:r for r in passed}
 for r in passed:
  ref=r if r.get('reference')=='self' else by.get(r.get('reference',''));r['delta_vs_reference_pct']=pct(num(r,'mean_goodput_gbps'),num(ref or {},'mean_goodput_gbps')) if ref else ''
  if r['case'] in ('A_1c_baseline','B_2c_baseline','R_2c_baseline_repeat'):r['effect_class']='reference'
  elif r['delta_vs_reference_pct']=='':r['effect_class']='no reference'
  elif float(r['delta_vs_reference_pct'])>=3:r['effect_class']='material positive'
  elif float(r['delta_vs_reference_pct'])<=-3:r['effect_class']='material negative'
  else:r['effect_class']='no material change (<3%)'
 fields=[]
 for r in rows:
  for k in r:
   if k not in fields:fields.append(k)
 with (root/'BOTTLENECK_SWEEP_SUMMARY.csv').open('w',newline='',encoding='utf-8') as f:
  w=csv.DictWriter(f,fieldnames=fields);w.writeheader();w.writerows(rows)
 t=['P5 BOTTLENECK SWEEP V2 SUMMARY','All cases: OFF mode, same simultaneous 8GiB downloads, repetitions and MTU 1500.','Each perturbation has an explicit reference; +/-3% is the screening threshold.','','case                         goodput   SD      reference                  delta    power    DPDK QCPUs       effect']
 for r in rows:
  if r.get('status')!='PASS':t.append(f"{r['case']:<28} {r.get('status')}");continue
  d=r.get('delta_vs_reference_pct','');ds='   n/a ' if d=='' else f'{float(d):+7.2f}%';t.append(f"{r['case']:<28} {num(r,'mean_goodput_gbps'):>7.3f} {num(r,'stdev_goodput_gbps'):>6.3f}  {str(r.get('reference','')):<25} {ds} {num(r,'combined_rapl_w'):>7.1f}W  {r.get('all_configured_dpdk_lcores_engaged',0)}    {str(r.get('quic_cpus','')):<10} {r.get('effect_class','')}")
 A=by.get('A_1c_baseline');B=by.get('B_2c_baseline');R=by.get('R_2c_baseline_repeat');t.append('')
 if A and B:
  d=pct(num(B,'mean_goodput_gbps'),num(A,'mean_goodput_gbps'));t+= [f'Core scaling A->B: {d:+.3f}%', '  '+('MATERIAL core-count effect' if abs(d)>=3 else 'NO material core-count effect')]
 if B and R:
  d=pct(num(R,'mean_goodput_gbps'),num(B,'mean_goodput_gbps'));t += [f'End baseline drift B->R: {d:+.3f}%', '  '+('WARNING: >=3% drift' if abs(d)>=3 else 'stable within 3%')]
 groups={'producer-ring sync':('C_1c_ring_mp','D_1c_ring_rts'),'TX allocation':('E_2c_txalloc1','F_2c_txalloc32'),'RX pipeline':('G_2c_rxpipe0','H_2c_rxpipe4'),'TX consumer batching':('I_2c_txburst32','J_2c_txburst64','K_2c_drain4'),'RX burst':('L_2c_rxburst64',),'TX metadata':('M_2c_txmetazero0',),'OFF bookkeeping':('N_2c_skipoffcount','O_2c_debug0'),'ring capacity':('P_2c_ring8192',),'mbuf cache':('Q_2c_cache256',),'QUIC worker count':('S_2c_quic2','T_2c_quic1')}
 t += ['','Localization flags:']
 for label,names in groups.items():
  p=[by[n] for n in names if n in by];pos=[r for r in p if r.get('delta_vs_reference_pct','')!='' and float(r['delta_vs_reference_pct'])>=3];neg=[r for r in p if r.get('delta_vs_reference_pct','')!='' and float(r['delta_vs_reference_pct'])<=-3]
  if pos:t.append('  '+label+': POSITIVE -> '+', '.join(f"{r['case']} {float(r['delta_vs_reference_pct']):+.2f}%" for r in pos))
  elif neg:t.append('  '+label+': SENSITIVE NEGATIVE -> '+', '.join(f"{r['case']} {float(r['delta_vs_reference_pct']):+.2f}%" for r in neg))
  elif p:t.append('  '+label+': no >=3% effect')
  else:t.append('  '+label+': missing/failed')
 ranked=sorted(passed,key=lambda r:num(r,'mean_goodput_gbps'),reverse=True)
 if ranked:t += ['',f"Best observed: {ranked[0]['case']} = {num(ranked[0],'mean_goodput_gbps'):.6f} Gbit/s"]
 t += ['','Before assigning causality inspect case lcore_activity.csv, CPU19-24 busy columns, and exact quic_cpu_activity JSON.','DPDK per-lcore RX/TX packet engagement is the authoritative dataplane-core evidence.']
 out=root/'BOTTLENECK_SWEEP_SUMMARY.txt';out.write_text('\n'.join(t)+'\n',encoding='utf-8');print(out.read_text(),end='');print('CSV:',root/'BOTTLENECK_SWEEP_SUMMARY.csv');return 0
if __name__=='__main__':raise SystemExit(main())
