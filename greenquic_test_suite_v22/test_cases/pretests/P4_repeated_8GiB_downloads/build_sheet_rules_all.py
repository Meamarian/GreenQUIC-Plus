#!/usr/bin/env python3
from __future__ import annotations
import argparse,csv,json,math,re,statistics,zipfile
from pathlib import Path
from xml.sax.saxutils import escape
import matplotlib; matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np
MODES=('off','basic','plus'); MN={'off':'MsQuic-DPDK','basic':'GreenQUIC','plus':'GreenQUIC+'}
MC={'off':'#4C78A8','basic':'#F58518','plus':'#54A24B'}; EC={'Server':'#4C78A8','Client':'#F58518','Combined':'#54A24B'}
PC={'startup':'#E6E6E6','pre':'#DCEAF7','active':'#E4F3E7','gap':'#FFF0C9','post':'#DCEAF7','tail':'#EEE3F5'}
LS={'startup':('Startup',9),'pre':('Pre-cool',10),'active':('D{index}',16),'gap':('Gap {index}',14),'post':('Post-cool',10),'tail':('Tail',8)}
NCHART=62

def n(s): return re.sub(r'[^a-z0-9]+','_',str(s).lower()).strip('_')
def num(v):
 try:
  x=float(str(v).replace(',','').strip().split()[0]); return x if math.isfinite(x) else None
 except:return None
def avg(xs):
 a=[float(x) for x in xs if x is not None and math.isfinite(float(x))]; return statistics.mean(a) if a else None
def rcsv(p):
 if not p.is_file():return []
 with p.open(newline='',encoding='utf-8',errors='replace') as f:return list(csv.DictReader(f))
def mrows(rows):return {str(r.get('mode','')).lower():r for r in rows}
def field(r,*parts):
 if not r:return None
 q=[n(x) for x in parts]
 for k,v in r.items():
  if all(x in n(k) for x in q):
   z=num(v)
   if z is not None:return z
 return None
def load(root):
 t=root/'tables';return {k:rcsv(t/f) for k,f in {
 'ca':'client_mode_averages.csv','sa':'server_mode_averages.csv','co':'combined_endpoint_mode_averages.csv','bh':'power_management_behavior_mode_averages.csv','cr':'client_all_runs.csv','sr':'server_all_runs.csv'}.items()}
def v3(rows,*parts):
 d=mrows(rows);return [field(d.get(m),*parts) for m in MODES]

def infer(p):
 s='/'.join(p.parts[-7:]).lower(); role='client' if 'client' in s else ('server' if 'server' in s else None)
 a=re.search(r'rep[_-]?(\d+)[_-]?(off|basic|plus)',s)
 if a:return role,int(a.group(1)),a.group(2)
 b=re.search(r'(off|basic|plus).*?rep[_-]?(\d+)',s)
 return (role,int(b.group(2)),b.group(1)) if b else (None,None,None)
def runs(root):
 d={}
 for pat,key in [('*_msr_power.csv','msr'),('*_log.txt','log'),('*_timeline.jsonl','tl')]:
  for p in root.rglob(pat):
   role,rep,mode=infer(p)
   if role and rep and mode:d.setdefault((role,rep,mode),{})[key]=p
 return d
def windows(p):
 if not p:return []
 s=Path(p).read_text(encoding='utf-8',errors='replace');A={int(i):int(t)*1000 for i,t in re.findall(r'request=(\d+)/\d+\s+start_us=(\d+)',s)};B={int(i):int(t)*1000 for i,t in re.findall(r'request=(\d+)/\d+\s+complete_us=(\d+)',s)}
 return [(A[i],B[i]) for i in sorted(A.keys()&B.keys()) if B[i]>=A[i]]
def gets(p):
 if not p:return []
 out=[]
 for line in Path(p).read_text(encoding='utf-8',errors='replace').splitlines():
  if 'GET' not in line.upper():continue
  try:o=json.loads(line)
  except:continue
  for k,v in o.items():
   if isinstance(v,(int,float)) and ('mono' in n(k) or n(k) in ('timestamp_ns','time_ns')):out.append(int(v));break
 return out[:5]
def msr(p):
 if not p:return None
 rows=rcsv(Path(p));
 if not rows:return None
 ks={n(k):k for k in rows[0]}
 def pick(*q):
  for x in q:
   for nk,k in ks.items():
    if n(x)==nk or n(x) in nk:return k
 kt=pick('monotonic_ns','timestamp_ns','monotonic_us');ki=pick('actual_interval_ms','interval_ms');kp=pick('package_delta_j');kd=pick('dram_delta_j')
 if not kt or not kp:return None
 T=[];D=[];E=[]
 for r in rows:
  t=num(r.get(kt));e=num(r.get(kp));dr=num(r.get(kd)) if kd else 0;iv=num(r.get(ki)) if ki else None
  if t is None or e is None:continue
  if 'us' in n(kt) and 'ns' not in n(kt):t*=1000
  T.append(int(t));D.append(iv/1000 if iv else math.nan);E.append(e+(dr or 0))
 if len(T)<2:return None
 good=[x for x in D if math.isfinite(x) and x>0];med=statistics.median(good) if good else .006
 for i in range(len(D)):
  if not math.isfinite(D[i]) or D[i]<=0:D[i]=(T[i+1]-T[i])/1e9 if i+1<len(T) else med
 return {'t':np.array(T,dtype=np.int64),'dt':np.array(D),'e':np.array(E),'p':np.array(E)/np.array(D)}
def spans(w,t0,t1):
 if not w:return []
 out=[];first,last=w[0][0],w[-1][1];pre=max(t0,first-5_000_000_000)
 if pre>t0:out.append(('startup',None,t0,pre))
 if first>pre:out.append(('pre',None,pre,first))
 for i,(a,b) in enumerate(w,1):
  out.append(('active',i,a,b))
  if i<len(w):out.append(('gap',i,b,w[i][0]))
 post=min(t1,last+5_000_000_000)
 if post>last:out.append(('post',None,last,post))
 if t1>post:out.append(('tail',None,post,t1))
 return [(k,i,max(a,t0),min(b,t1)) for k,i,a,b in out if b>a]
def clip(M,S,kinds):
 E=T=0.
 for i,a in enumerate(M['t']):
  b=int(a+M['dt'][i]*1e9)
  for k,_,s,e in S:
   if k not in kinds:continue
   ov=max(0,min(b,e)-max(int(a),s))
   if ov:E+=M['e'][i]*ov/max(1,b-int(a));T+=ov/1e9
 return {'energy_j':E,'duration_s':T,'power_w':E/T if T else None}
def rawdata(root):
 R=runs(root);out={}
 for m in MODES:
  for rep in sorted({x[1] for x in R if x[2]==m}):
   c=R.get(('client',rep,m),{});s=R.get(('server',rep,m),{});w=windows(c.get('log'));C=msr(c.get('msr'));S=msr(s.get('msr'))
   if not w or C is None:continue
   off=0;g=gets(s.get('tl'))
   if S is not None and g:off=int(statistics.median([w[i][0]-g[i] for i in range(min(len(g),len(w)))]))
   q={'w':w,'off':off}
   for ep,M in [('client',C),('server',S)]:
    if M is None:continue
    A={**M,'t':M['t']+(off if ep=='server' else 0)};P=spans(w,int(A['t'][0]),int(A['t'][-1]+A['dt'][-1]*1e9));q[ep]=A;q[ep+'_sp']=P
    for ph,ks in [('active',{'active'}),('gap',{'gap'}),('startup',{'startup'}),('pre',{'pre'}),('post',{'post'}),('tail',{'tail'})]:q[ep+'_'+ph]=clip(A,P,ks)
   out[(rep,m)]=q
 return out

def axstyle(ax,title,y=''):
 ax.set_title(title,fontsize=18,pad=18,fontweight='normal');ax.set_ylabel(y,fontsize=13);ax.tick_params(axis='x',labelsize=11);ax.tick_params(axis='y',labelsize=10.5);ax.grid(axis='y',alpha=.3);ax.set_axisbelow(True)
 for s in ax.spines.values():s.set_linewidth(.8)
def save(fig,out,i,name):
 for ext in ('svg','pdf'):
  for vv in ('with_values','without_values'):
   p=out/ext/vv;p.mkdir(parents=True,exist_ok=True);fig.savefig(p/f'{i:02d}_{name}.{ext}',bbox_inches='tight',dpi=300)
 plt.close(fig)
def empty(out,i,name,title,msg='No recorded data available for this matrix'):
 f,a=plt.subplots(figsize=(14,7));axstyle(a,title);a.text(.5,.5,msg,ha='center',va='center',transform=a.transAxes);a.set_xticks([]);a.set_yticks([]);save(f,out,i,name)
def bars(out,i,name,title,y,series):
 if not series or not any(any(x is not None for x in z) for z in series.values()):return empty(out,i,name,title)
 f,a=plt.subplots(figsize=(15,8));x=np.arange(3);w=min(.72/len(series),.24)
 for j,(lab,z) in enumerate(series.items()):
  yy=[np.nan if v is None else v for v in z];bb=a.bar(x+(j-(len(series)-1)/2)*w,yy,w,label=lab)
  for b,v in zip(bb,z):
   if v is not None:a.annotate(f'{v:.2f}',(b.get_x()+b.get_width()/2,b.get_height()),xytext=(0,8),textcoords='offset points',ha='center',rotation=90,fontsize=8)
 a.set_xticks(x,[MN[m] for m in MODES]);a.set_ylim(bottom=0);axstyle(a,title,y);a.legend(loc='center left',bbox_to_anchor=(1.01,.5));save(f,out,i,name)
def phasebar(raw,ep,ph,key):
 z=[]
 for m in MODES:z.append(avg([r.get(ep+'_'+ph,{}).get(key) for (rep,mm),r in raw.items() if mm==m]))
 return z
def shade(a,S,t0):
 for k,i,s,e in S:
  x0=(s-t0)/1e9;x1=(e-t0)/1e9;a.axvspan(x0,x1,color=PC[k],alpha=.16,lw=0,zorder=0);tx,fs=LS[k];tx=tx.format(index=i) if i else tx;a.text((x0+x1)/2,.5,tx,transform=a.get_xaxis_transform(),ha='center',va='center',fontsize=fs,color='#555',alpha=.16,zorder=1)
def sm(x,y,S,t0):
 o=np.array(y,float).copy();step=np.median(np.diff(x)) if len(x)>1 else .006;N=max(1,int(round(.504/max(step,1e-6))))
 for _,_,s,e in S:
  ix=np.where((x>=(s-t0)/1e9)&(x<=(e-t0)/1e9))[0]
  if len(ix):
   q=y[ix];k=min(N,len(q));o[ix]=np.convolve(q,np.ones(k)/k,'same')
 return o
def panel(out,i,name,title,ep,raw,kind):
 f,A=plt.subplots(3,1,figsize=(16,11),sharey=True);ok=False
 for a,m in zip(A,MODES):
  rs=sorted([r for r,mm in raw if mm==m]);q=raw.get((rs[0],m)) if rs else None;M=q.get(ep.lower()) if q else None;S=q.get(ep.lower()+'_sp') if q else None
  if M is None or not S:axstyle(a,MN[m]);continue
  ok=True;t0=q['w'][0][0];x=(M['t']-t0)/1e9;y=np.cumsum(M['e']) if kind=='energy' else M['p'];yl='Cumulative energy (J)' if kind=='energy' else 'Power (W)';y=sm(x,y,S,t0) if kind=='smooth' else y;shade(a,S,t0);a.plot(x,y,color=MC[m],lw=1.25,zorder=3);a.set_xlim(x.min()-.75,x.max()+2);axstyle(a,MN[m],yl)
 f.suptitle(title,fontsize=19);A[-1].set_xlabel('Time relative to Download 1 start (s)')
 if not ok:plt.close(f);return empty(out,i,name,title)
 f.tight_layout(rect=(0,0,.97,.96));save(f,out,i,name)
def overlay(out,i,name,title,m,raw,smooth=False):
 rs=sorted([r for r,mm in raw if mm==m]);q=raw.get((rs[0],m)) if rs else None
 if not q:return empty(out,i,name,title)
 f,a=plt.subplots(figsize=(16,8));t0=q['w'][0][0];S=q.get('client_sp');shade(a,S,t0) if S else None;ok=False
 C=q.get('client');SV=q.get('server')
 for ep in ('Server','Client','Combined'):
  if ep=='Combined':
   if C is None or SV is None:continue
   x=(C['t']-t0)/1e9;y=C['p']+np.interp(x,(SV['t']-t0)/1e9,SV['p'],left=np.nan,right=np.nan)
  else:
   M=q.get(ep.lower());
   if M is None:continue
   x=(M['t']-t0)/1e9;y=M['p']
  if smooth and S:y=sm(x,y,S,t0)
  a.plot(x,y,label=ep,color=EC[ep],lw=1.25,zorder=3);ok=True
 if not ok:plt.close(f);return empty(out,i,name,title)
 axstyle(a,title,'Power (W)');a.set_xlabel('Time relative to Download 1 start (s)');a.legend(loc='center left',bbox_to_anchor=(1.01,.5));save(f,out,i,name)

def charts(out,T,R):
 co=T['co'];bh={(str(r.get('role','')).lower(),str(r.get('mode','')).lower()):r for r in T['bh']}
 bv=lambda role,key:[field(bh.get((role,m)),key) for m in MODES]
 bars(out,1,'file_size_and_payload','File size and total useful payload','GiB',{'Payload':v3(co,'payload_gib')});bars(out,2,'download_and_gap_counts','Downloads and configured gaps','Count',{'Downloads':[5]*3,'Gaps':[4]*3});bars(out,3,'gap_duration','Configured gap duration','Seconds',{'Gap total':[20]*3})
 bars(out,4,'active_goodput','Active goodput','Gbit/s',{'Goodput':v3(co,'goodput','excluding','gaps')});bars(out,5,'gap_inclusive_goodput','Gap-inclusive goodput','Gbit/s',{'Goodput':v3(co,'goodput','including','gaps')})
 bars(out,6,'duration_breakdown','Transfer, gap-window, and aligned duration','Seconds',{'Workload':v3(co,'workload_duration_s'),'Client aligned':v3(co,'client_aligned_duration_s'),'Server aligned':v3(co,'server_aligned_duration_s')});bars(out,7,'average_rapl_power','Average RAPL power','Power (W)',{'Server':v3(co,'server_average_power_w'),'Client':v3(co,'client_average_power_w'),'Combined':v3(co,'combined_average_power_w')});bars(out,8,'rapl_energy','RAPL energy','Energy (J)',{'Server':v3(co,'server_rapl_energy_j'),'Client':v3(co,'client_rapl_energy_j'),'Combined':v3(co,'combined_rapl_energy_j')});bars(out,9,'energy_efficiency','Energy efficiency','J/GiB',{'Server':v3(co,'server_rapl_j_per_gib'),'Client':v3(co,'client_rapl_j_per_gib'),'Combined':v3(co,'combined_rapl_j_per_gib')})
 cs=['state_0_residency_s','state_1_residency_s','state_2_residency_s','state_3_residency_s'];bars(out,10,'server_whole_cstate','Server whole-trace C-state residency','Seconds',{x:bv('server',x) for x in cs});bars(out,11,'client_whole_cstate','Client whole-trace C-state residency','Seconds',{x:bv('client',x) for x in cs});bars(out,12,'whole_idle_and_trace_duration','Whole-trace idle time and raw trace duration','Seconds',{'Server':bv('server','cstate_total_residency_s'),'Client':bv('client','cstate_total_residency_s')})
 for i,title in [(13,'Idle fraction of aligned time'),(14,'Server active-transfer C-state residency'),(15,'Client active-transfer C-state residency'),(16,'Active-transfer total idle time'),(17,'Active-transfer idle fraction'),(18,'Active-transfer idle intervals'),(19,'Server gap C-state residency'),(20,'Client gap C-state residency'),(21,'Gap total idle time'),(22,'Gap idle fraction'),(23,'Gap idle intervals'),(24,'Linux idle entries')]:empty(out,i,n(title),title)
 for i,title,role,fs in [(25,'Server EPOLL attempts / wakeups / timeouts','server',['epoll_attempts','epoll_wakeups','epoll_timeouts']),(26,'Server EPOLL wake sources','server',['rx_wake','software_control_wake','signal_wake']),(27,'Client EPOLL attempts / wakeups / timeouts','client',['epoll_attempts','epoll_wakeups','epoll_timeouts']),(28,'Client EPOLL wake sources','client',['rx_wake','software_control_wake','signal_wake']),(29,'Server observed frequency min–max','server',['frequency_min_ghz','frequency_max_ghz']),(30,'Client observed frequency min–max','client',['frequency_min_ghz','frequency_max_ghz'])]:bars(out,i,n(title),title,'Value',{x:bv(role,x) for x in fs})
 acts=sorted({k for r in T['bh'] for k in r if k.startswith('frequency_action_')});bars(out,31,'server_frequency_policy_actions','Server frequency-policy actions','Count',{x.replace('frequency_action_',''):bv('server',x) for x in acts});empty(out,32,'server_actual_frequency_changes','Server actual frequency changes');bars(out,33,'client_frequency_policy_actions','Client frequency-policy actions','Count',{x.replace('frequency_action_',''):bv('client',x) for x in acts});empty(out,34,'client_actual_frequency_changes','Client actual frequency changes');bars(out,35,'total_frequency_policy_actions','Total frequency-policy actions','Count',{'Server':[sum(field(bh.get(('server',m)),x) or 0 for x in acts) for m in MODES],'Client':[sum(field(bh.get(('client',m)),x) or 0 for x in acts) for m in MODES]});bars(out,36,'timestamped_frequency_events','Timestamped frequency events','Count',{'Server':bv('server','frequency_events'),'Client':bv('client','frequency_events')})
 for i,title in [(37,'PLUS ACK_PENDING and CUBIC ramping'),(38,'PLUS CWND blocked / recovery'),(39,'PLUS client CUBIC recovery detail'),(40,'PLUS transfer begin/end hints'),(41,'DPDK packet counts'),(42,'ACPI server/client power channel'),(43,'Current test configuration and scientific overview')]:empty(out,i,n(title),title)
 for i,title,ph,key,y in [(44,'Active-transfer RAPL power','active','power_w','Power (W)'),(45,'Inter-download gap RAPL power','gap','power_w','Power (W)'),(46,'Active-transfer RAPL energy','active','energy_j','Energy (J)'),(47,'Inter-download gap RAPL energy','gap','energy_j','Energy (J)')]:
  S=phasebar(R,'server',ph,key);C=phasebar(R,'client',ph,key);bars(out,i,n(title),title,y,{'Server':S,'Client':C,'Combined':[a+b if a is not None and b is not None else None for a,b in zip(S,C)]})
 i=48
 for ep in ('Server','Client','Combined'):
  for kind,suf,ttl in [('raw','power_raw','RAPL power over time'),('smooth','power_smoothed','phase-aware smoothed RAPL power'),('energy','cumulative_energy','cumulative RAPL energy')]:
   if ep=='Combined':empty(out,i,'combined_'+suf,'Current test — Combined '+ttl,'Use per-mode endpoint overlays for exact combined trace')
   else:panel(out,i,ep.lower()+'_'+suf,'Current test — '+ep+' '+ttl,ep,R,kind)
   i+=1
 for m in MODES:
  overlay(out,i,m+'_endpoints_power_raw',f'Current test — {MN[m]} — Server / Client / Combined RAPL power',m,R);i+=1;overlay(out,i,m+'_endpoints_power_smoothed',f'Current test — {MN[m]} — Server / Client / Combined phase-aware smoothed RAPL power',m,R,True);i+=1
 assert i-1==62

def xlcol(k):
 s=''
 while k:s=chr(65+(k-1)%26)+s;k=(k-1)//26
 return s
def sxml(rows):
 o=['<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>']
 for r,row in enumerate(rows,1):
  o.append(f'<row r="{r}">')
  for c,v in enumerate(row,1):
   if v is None:continue
   q=f'{xlcol(c)}{r}';o.append(f'<c r="{q}"><v>{v}</v></c>' if isinstance(v,(int,float)) else f'<c r="{q}" t="inlineStr"><is><t>{escape(str(v))}</t></is></c>')
  o.append('</row>')
 return ''.join(o)+'</sheetData></worksheet>'
def xlsx(p,sheets):
 names=[re.sub(r'[\\/*?:\[\]]','_',x)[:31] for x,_ in sheets]
 with zipfile.ZipFile(p,'w',zipfile.ZIP_DEFLATED) as z:
  z.writestr('[Content_Types].xml','<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'+''.join(f'<Override PartName="/xl/worksheets/sheet{i}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' for i in range(1,len(sheets)+1))+'</Types>');z.writestr('_rels/.rels','<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>');z.writestr('xl/workbook.xml','<?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>'+''.join(f'<sheet name="{escape(x)}" sheetId="{i}" r:id="rId{i}"/>' for i,x in enumerate(names,1))+'</sheets></workbook>');z.writestr('xl/_rels/workbook.xml.rels','<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'+''.join(f'<Relationship Id="rId{i}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet{i}.xml"/>' for i in range(1,len(sheets)+1))+'</Relationships>')
  for i,(_,rows) in enumerate(sheets,1):z.writestr(f'xl/worksheets/sheet{i}.xml',sxml(rows))
def tab(rows):
 if not rows:return [['No data']]
 K=[]
 for r in rows:
  for k in r:
   if k not in K:K.append(k)
 return [K]+[[r.get(k,'') for k in K] for r in rows]
def comp(T,R):
 d=mrows(T['co']);O=[['Metric','Value order / fields','MsQuic-DPDK','GreenQUIC','GreenQUIC+','Comparison / interpretation','Source / scope']];K=[]
 for r in T['co']:
  for k in r:
   if k!='mode' and k not in K:K.append(k)
 for k in K:O.append([k,'OFF / BASIC / PLUS',d.get('off',{}).get(k,''),d.get('basic',{}).get(k,''),d.get('plus',{}).get(k,''),'','combined_endpoint_mode_averages.csv'])
 for ph in ('startup','pre','active','gap','post','tail'):
  for ep in ('server','client'):
   for key in ('power_w','energy_j','duration_s'):O.append([f'{ep} {ph} {key}','OFF / BASIC / PLUS',*phasebar(R,ep,ph,key),'','native MSR RAPL + exact client download windows'])
 return O
def main():
 a=argparse.ArgumentParser();a.add_argument('--input',type=Path,required=True);a.add_argument('--output',type=Path);a.add_argument('--expected-charts',type=int,default=62);q=a.parse_args();root=q.input.resolve();out=(q.output or root/'the_sheet_rules_all').resolve();out.mkdir(parents=True,exist_ok=True);T=load(root);R=rawdata(root);P=[]
 for (rep,m),r in sorted(R.items()):
  for ep in ('server','client'):
   for ph in ('startup','pre','active','gap','post','tail'):
    d=r.get(ep+'_'+ph)
    if d:P.append({'repetition':rep,'mode':m,'endpoint':ep,'phase':ph,**d,'server_offset_to_client_ns':r.get('off',0)})
 data=out/'data';data.mkdir(exist_ok=True)
 if P:
  with (data/'phase_rapl_all_runs.csv').open('w',newline='') as f:w=csv.DictWriter(f,fieldnames=list(P[0]));w.writeheader();w.writerows(P)
 xlsx(out/'GreenQUIC_full_results.xlsx',[('Full comparison',comp(T,R)),('Combined averages',tab(T['co'])),('Client all runs',tab(T['cr'])),('Server all runs',tab(T['sr'])),('Power management',tab(T['bh'])),('Phase RAPL per-run',tab(P)),('Chart manifest',[['Expected logical charts',q.expected_charts],['Generated logical charts',NCHART]])]);charts(out/'charts',T,R);S=list((out/'charts/svg/with_values').glob('*.svg'));D=list((out/'charts/pdf/with_values').glob('*.pdf'));report={'matrix':str(root),'raw_phase_runs':len(R),'logical_charts_expected':q.expected_charts,'logical_charts_generated_svg':len(S),'logical_charts_generated_pdf':len(D),'xlsx':str(out/'GreenQUIC_full_results.xlsx')};(out/'validation_report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2));return 0 if len(S)==q.expected_charts==len(D) else 2
if __name__=='__main__':raise SystemExit(main())
