#!/usr/bin/env python3
from __future__ import annotations

import argparse,csv,json,re
from collections import defaultdict
from pathlib import Path


def interrupt_counts(path:Path)->dict[int,dict[int,int]]:
    lines=path.read_text(encoding='utf-8',errors='replace').splitlines()
    if not lines:raise ValueError('empty /proc/interrupts snapshot')
    header=lines[0].split();cpus=[]
    for token in header:
        m=re.fullmatch(r'CPU(\d+)',token)
        if m:cpus.append(int(m.group(1)))
    if not cpus:raise ValueError('CPU header missing')
    out={}
    for line in lines[1:]:
        m=re.match(r'^\s*(\d+):\s+(.*)$',line)
        if not m:continue
        irq=int(m.group(1));fields=m.group(2).split();vals=[]
        for token in fields[:len(cpus)]:
            try:vals.append(int(token))
            except ValueError:vals.append(0)
        if len(vals)==len(cpus):out[irq]={cpu:value for cpu,value in zip(cpus,vals)}
    return out


def softirq_row(path:Path,name:str)->dict[int,int]:
    lines=path.read_text(encoding='utf-8',errors='replace').splitlines()
    # /proc/softirqs has one CPU column per online CPU, ordered CPU0..N.
    header=[]
    for line in lines:
        if 'CPU0' in line:
            header=[int(x[3:]) for x in line.split() if re.fullmatch(r'CPU\d+',x)]
            break
    if not header:raise ValueError('softirq CPU header missing')
    target=None
    for line in lines:
        if re.match(rf'^\s*{re.escape(name)}:',line):
            target=line.split(':',1)[1].split();break
    if target is None:raise ValueError(f'{name} softirq row missing')
    vals=[]
    for token in target[:len(header)]:
        try:vals.append(int(token))
        except ValueError:vals.append(0)
    if len(vals)!=len(header):raise ValueError(f'{name} softirq column mismatch')
    return {cpu:value for cpu,value in zip(header,vals)}


def main()->int:
    ap=argparse.ArgumentParser();ap.add_argument('--matrix',type=Path,required=True);ap.add_argument('--runs',type=int,required=True);a=ap.parse_args();root=a.matrix.resolve();errors=[];audit=[]
    maps={}
    for ep in ('server','client'):
        p=root/'setup'/f'{ep}_multicore_irq_map.json'
        if not p.is_file():errors.append(f'missing {p}');continue
        data=json.load(open(p));mappings=data.get('mappings') or []
        mappings=sorted(mappings,key=lambda r:int(r.get('queue_order',999999)))[:2]
        if len(mappings)!=2:errors.append(f'{ep}: expected 2 mapped queue IRQs, got {len(mappings)}');continue
        maps[ep]=mappings
    for ep,mappings in maps.items():
        for rep in range(1,a.runs+1):
            run=root/'runs'/ep/f'rep{rep:02d}'
            before=run/'net_before_interrupts.txt';after=run/'net_after_interrupts.txt'
            sb=run/'net_before_softirqs.txt';sa=run/'net_after_softirqs.txt'
            if not before.is_file() or not after.is_file():
                errors.append(f'{ep} rep{rep:02d}: interrupt snapshots missing');continue
            try:b=interrupt_counts(before);z=interrupt_counts(after)
            except Exception as exc:errors.append(f'{ep} rep{rep:02d}: cannot parse interrupts: {exc}');continue
            try:
                netrx_b=softirq_row(sb,'NET_RX');netrx_a=softirq_row(sa,'NET_RX')
            except Exception as exc:
                errors.append(f'{ep} rep{rep:02d}: cannot parse NET_RX softirqs: {exc}')
                netrx_b={};netrx_a={}
            used_cpus=set()
            for row in mappings:
                irq=int(row['irq']);target=int(row['cpu']);bv=b.get(irq,{});av=z.get(irq,{})
                delta_total=sum(av.values())-sum(bv.values())
                delta_target=av.get(target,0)-bv.get(target,0)
                other_delta=delta_total-delta_target
                netrx_delta=netrx_a.get(target,0)-netrx_b.get(target,0) if netrx_a else 0
                rec={'endpoint':ep,'repetition':rep,'irq':irq,'target_cpu':target,'delta_total':delta_total,'delta_target_cpu':delta_target,'delta_other_cpus':other_delta,'net_rx_softirq_delta':netrx_delta,'engaged':delta_target>0 and netrx_delta>0,'label':row.get('label','')};audit.append(rec)
                if delta_total<=0:errors.append(f'{ep} rep{rep:02d}: queue IRQ {irq} had no traffic interrupts')
                if delta_target<=0:errors.append(f'{ep} rep{rep:02d}: queue IRQ {irq} had no interrupts on pinned CPU{target}')
                if other_delta!=0:errors.append(f'{ep} rep{rep:02d}: queue IRQ {irq} leaked {other_delta} interrupts outside CPU{target}')
                if netrx_delta<=0:errors.append(f'{ep} rep{rep:02d}: CPU{target} had no NET_RX softirq activity')
                if delta_target>0 and netrx_delta>0:used_cpus.add(target)
            if used_cpus!={19,20}:errors.append(f'{ep} rep{rep:02d}: active Linux dataplane CPUs={sorted(used_cpus)}, expected [19,20]')
    result={'schema':'greenquic-p7-parallel-irq-activity-v2','runs':a.runs,'engagement_rule':'pinned queue IRQ delta > 0 AND NET_RX softirq delta > 0 on CPU19 and CPU20','records':audit,'errors':errors,'status':'PASS' if not errors else 'FAIL'}
    out=root/'parallel_irq_activity_validation.json';out.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')

    table=root/'parallel_tables';table.mkdir(parents=True,exist_ok=True)
    csv_path=table/'linux_dataplane_cpu_activity.csv'
    fields=['endpoint','repetition','target_cpu','irq','label','delta_target_cpu','delta_total','delta_other_cpus','net_rx_softirq_delta','engaged']
    with csv_path.open('w',newline='',encoding='utf-8') as f:
        w=csv.DictWriter(f,fieldnames=fields);w.writeheader()
        for r in audit:w.writerow({**r,'engaged':1 if r['engaged'] else 0})
    agg=defaultdict(lambda:{'irq':0,'netrx':0,'runs':0,'engaged_runs':0})
    for r in audit:
        g=agg[(r['endpoint'],r['target_cpu'])];g['irq']+=r['delta_target_cpu'];g['netrx']+=r['net_rx_softirq_delta'];g['runs']+=1;g['engaged_runs']+=1 if r['engaged'] else 0
    summary=table/'linux_dataplane_cpu_activity_summary.csv'
    with summary.open('w',newline='',encoding='utf-8') as f:
        fs=['endpoint','cpu','runs','engaged_runs','total_pinned_irq_delta','total_net_rx_softirq_delta'];w=csv.DictWriter(f,fieldnames=fs);w.writeheader()
        for (ep,cpu),g in sorted(agg.items()):w.writerow({'endpoint':ep,'cpu':cpu,'runs':g['runs'],'engaged_runs':g['engaged_runs'],'total_pinned_irq_delta':g['irq'],'total_net_rx_softirq_delta':g['netrx']})
    for r in audit:
        print(f"P7 {r['endpoint']} rep{r['repetition']:02d} CPU{r['target_cpu']}: IRQ={r['delta_target_cpu']} NET_RX={r['net_rx_softirq_delta']} engaged={int(r['engaged'])}")
    if errors:
        for e in errors:print('ERROR:',e)
        print(f'P7 PARALLEL DATAPLANE CPU ACTIVITY FAIL: {len(errors)} error(s); results preserved');return 2
    print('P7 PARALLEL DATAPLANE CPU ACTIVITY PASS: CPU19 and CPU20 handled pinned queue IRQs and NET_RX work on both endpoints in every run')
    print(f'CSV: {csv_path}')
    return 0
if __name__=='__main__':raise SystemExit(main())
