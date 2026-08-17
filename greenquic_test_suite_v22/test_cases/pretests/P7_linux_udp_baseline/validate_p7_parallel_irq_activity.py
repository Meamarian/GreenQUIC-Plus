#!/usr/bin/env python3
from __future__ import annotations

import argparse,json,re
from pathlib import Path


def interrupt_counts(path:Path)->dict[int,dict[int,int]]:
    lines=path.read_text(encoding='utf-8',errors='replace').splitlines()
    if not lines:raise ValueError('empty /proc/interrupts snapshot')
    header=lines[0].split(); cpus=[]
    for token in header:
        m=re.fullmatch(r'CPU(\d+)',token)
        if m:cpus.append(int(m.group(1)))
    if not cpus:raise ValueError('CPU header missing')
    out={}
    for line in lines[1:]:
        m=re.match(r'^\s*(\d+):\s+(.*)$',line)
        if not m:continue
        irq=int(m.group(1));fields=m.group(2).split()
        vals=[]
        for token in fields[:len(cpus)]:
            try:vals.append(int(token))
            except ValueError:vals.append(0)
        if len(vals)==len(cpus):out[irq]={cpu:value for cpu,value in zip(cpus,vals)}
    return out


def main()->int:
    ap=argparse.ArgumentParser();ap.add_argument('--matrix',type=Path,required=True);ap.add_argument('--runs',type=int,required=True);a=ap.parse_args();root=a.matrix.resolve();errors=[];audit=[]
    maps={}
    for ep in ('server','client'):
        p=root/'setup'/f'{ep}_multicore_irq_map.json'
        if not p.is_file():errors.append(f'missing {p}');continue
        data=json.load(open(p));mappings=data.get('mappings') or []
        # Exactly the first two queue vectors are the two configured combined queues.
        mappings=sorted(mappings,key=lambda r:int(r.get('queue_order',999999)))[:2]
        if len(mappings)!=2:errors.append(f'{ep}: expected 2 mapped queue IRQs, got {len(mappings)}');continue
        maps[ep]=mappings
    for ep,mappings in maps.items():
        for rep in range(1,a.runs+1):
            run=root/'runs'/ep/f'rep{rep:02d}'
            before=run/'net_before_interrupts.txt';after=run/'net_after_interrupts.txt'
            if not before.is_file() or not after.is_file():
                errors.append(f'{ep} rep{rep:02d}: interrupt snapshots missing');continue
            try:b=interrupt_counts(before);z=interrupt_counts(after)
            except Exception as exc:errors.append(f'{ep} rep{rep:02d}: cannot parse interrupts: {exc}');continue
            used_cpus=set();
            for row in mappings:
                irq=int(row['irq']);target=int(row['cpu']);bv=b.get(irq,{});av=z.get(irq,{})
                delta_total=sum(av.values())-sum(bv.values())
                delta_target=av.get(target,0)-bv.get(target,0)
                other_delta=delta_total-delta_target
                rec={'endpoint':ep,'repetition':rep,'irq':irq,'target_cpu':target,'delta_total':delta_total,'delta_target_cpu':delta_target,'delta_other_cpus':other_delta,'label':row.get('label','')};audit.append(rec)
                if delta_total<=0:errors.append(f'{ep} rep{rep:02d}: queue IRQ {irq} had no traffic interrupts')
                if delta_target<=0:errors.append(f'{ep} rep{rep:02d}: queue IRQ {irq} had no interrupts on pinned CPU{target}')
                if other_delta!=0:errors.append(f'{ep} rep{rep:02d}: queue IRQ {irq} leaked {other_delta} interrupts outside CPU{target}')
                if delta_target>0:used_cpus.add(target)
            if used_cpus!={19,20}:errors.append(f'{ep} rep{rep:02d}: active queue IRQ CPUs={sorted(used_cpus)}, expected [19,20]')
    result={'schema':'greenquic-p7-parallel-irq-activity-v1','runs':a.runs,'records':audit,'errors':errors,'status':'PASS' if not errors else 'FAIL'}
    out=root/'parallel_irq_activity_validation.json';out.write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    if errors:
        for e in errors:print('ERROR:',e)
        print(f'P7 PARALLEL IRQ ACTIVITY VALIDATION FAIL: {len(errors)} error(s)');return 2
    print('P7 PARALLEL IRQ ACTIVITY VALIDATION PASS: both Linux queue IRQs carried traffic on CPU19/CPU20 in every endpoint/run')
    return 0
if __name__=='__main__':raise SystemExit(main())
