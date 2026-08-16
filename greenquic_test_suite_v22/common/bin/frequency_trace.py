#!/usr/bin/env python3
from __future__ import annotations
import importlib.util,json
from pathlib import Path
HERE=Path(__file__).resolve().parent;IMPL=HERE/"frequency_trace_impl_v4.py"
spec=importlib.util.spec_from_file_location("greenquic_frequency_trace_impl_v4",IMPL)
if spec is None or spec.loader is None:raise SystemExit(f"ERROR: cannot import {IMPL}")
mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
legacy_read_events=mod.read_events

def read_events(path:Path):
    parsed=[]
    for raw in path.read_text(encoding="utf-8",errors="replace").splitlines():
        try:row=json.loads(raw)
        except json.JSONDecodeError:continue
        if row.get("type")!="line":continue
        mono=row.get("monotonic_ns")
        if mono is None:return legacy_read_events(path)
        line=str(row.get("line",""));cm=mod.CPU_RE.search(line)
        if not cm:continue
        cpu=int(cm.group(1));am=mod.ACTION_RE.search(line);sm=mod.STATS_RE.search(line)
        if am:parsed.append((int(mono),cpu,int(am.group(2)),"frequency_action",am.group(1)))
        elif sm:parsed.append((int(mono),cpu,int(sm.group(1)),"periodic_stats",None))
    if not parsed:return [],0.0
    parsed.sort(key=lambda r:(r[0],r[1],0 if r[3]=="frequency_action" else 1))
    origin=min(r[0] for r in parsed);end=max(r[0] for r in parsed);events=[]
    for mono,cpu,khz,source,action in parsed:
        elapsed=(mono-origin)/1e9
        events.append({"elapsed_s":elapsed,"elapsed_ms":elapsed*1000.0,"monotonic_ns":mono,
                       "cpu":cpu,"freq_khz":khz,"source":source,"action":action})
    return events,max(0.0,(end-origin)/1e9)
mod.read_events=read_events
if __name__=="__main__":raise SystemExit(mod.main())
