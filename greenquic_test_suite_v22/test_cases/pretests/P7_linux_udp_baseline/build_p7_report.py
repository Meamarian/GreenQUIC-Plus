#!/usr/bin/env python3
from __future__ import annotations
import importlib.util
from pathlib import Path
HERE=Path(__file__).resolve().parent;IMPL=HERE/"build_p7_report_impl_v4.py"
spec=importlib.util.spec_from_file_location("greenquic_build_p7_report_impl_v4",IMPL)
if spec is None or spec.loader is None:raise SystemExit(f"ERROR: cannot import {IMPL}")
mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
legacy_read_rapl=mod.read_rapl

def read_rapl_midpoint(path):
    rows=legacy_read_rapl(path);out=[]
    for row in rows:
        item=dict(row)
        try:
            end=int(float(item["sample_monotonic_ns"]));dt=float(item["actual_interval_ms"])
            if dt>0:item["sample_monotonic_ns"]=str(int(round(end-dt*500_000.0)))
        except (KeyError,TypeError,ValueError):pass
        out.append(item)
    return out
mod.read_rapl=read_rapl_midpoint
if __name__=="__main__":mod.main()
