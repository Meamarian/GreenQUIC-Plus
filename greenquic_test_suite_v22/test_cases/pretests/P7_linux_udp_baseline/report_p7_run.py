#!/usr/bin/env python3
from __future__ import annotations
import importlib.util
from pathlib import Path
HERE=Path(__file__).resolve().parent;IMPL=HERE/"report_p7_run_impl_v4.py"
spec=importlib.util.spec_from_file_location("greenquic_report_p7_impl_v4",IMPL)
if spec is None or spec.loader is None:raise SystemExit(f"ERROR: cannot import {IMPL}")
mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)

def cells(samples):
    samples=sorted(samples)
    if not samples:return []
    if len(samples)==1:
        t,v=samples[0];return [(t-500_000,t+500_000,v)]
    out=[]
    for i,(t,v) in enumerate(samples):
        left=(samples[i-1][0]+t)//2 if i else t-(samples[1][0]-t)//2
        right=(t+samples[i+1][0])//2 if i+1<len(samples) else t+(t-samples[i-1][0])//2
        if right>left:out.append((left,right,v))
    return out

def frequency_metrics(rows,windows):
    by={}
    for row in rows:
        if row.get("type")!="line":continue
        try:t=int(row["monotonic_ns"]);cpu=int(row["cpu"]);ghz=float(row["freq_khz"])/1e6
        except (KeyError,TypeError,ValueError):continue
        by.setdefault(cpu,[]).append((t,ghz))
    result={}
    for cpu,samples in sorted(by.items()):
        weighted=0.0;covered=0;seen=[];fragments=0
        for a,b,v in cells(samples):
            ov=mod.overlap_ns(a,b,windows)
            if ov<=0:continue
            weighted+=v*ov;covered+=ov;seen.append(v);fragments+=1
        if covered:
            result[str(cpu)]={"n":fragments,"min_ghz":min(seen),"mean_ghz":weighted/covered,
                              "max_ghz":max(seen),"covered_s":covered/1e9,
                              "aggregation":"midpoint-cell time weighted"}
    return result
mod.frequency_metrics=frequency_metrics
if __name__=="__main__":raise SystemExit(mod.main())
