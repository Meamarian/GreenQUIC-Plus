#!/usr/bin/env python3
"""Corrected P7 D1/D2+ report entry point for C RAPL interval semantics."""
from __future__ import annotations
import importlib.util
import json
from pathlib import Path

HERE=Path(__file__).resolve().parent
BASE=HERE/'build_p7_d1_d2plus_report.py'
spec=importlib.util.spec_from_file_location('gq_p7_d1d2_base',BASE)
if spec is None or spec.loader is None:
    raise SystemExit(f'ERROR: cannot import {BASE}')
mod=importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

def read_rapl_interval_end(path):
    R=mod.rows(path); out=[]
    for r in R:
        end_ns=mod.fnum(r.get('sample_monotonic_ns'))
        dt_ms=mod.fnum(r.get('actual_interval_ms'))
        pk=mod.fnum(r.get('package_delta_j'))
        dr=mod.fnum(r.get('dram_delta_j')) or 0
        if None in (end_ns,dt_ms,pk) or dt_ms <= 0:
            continue
        start_ns=int(round(end_ns-dt_ms*1_000_000.0))
        out.append((start_ns,int(end_ns),pk,dr))
    return out

mod.read_rapl=read_rapl_interval_end
rc=mod.main()
if rc == 0:
    import sys
    try:
        root=None
        for i,a in enumerate(sys.argv[1:]):
            if a == '--input' and i+2 <= len(sys.argv[1:]):
                root=Path(sys.argv[1:][i+1]); break
        if root is not None:
            p=root/'the_sheet_rules_all'/'d1_d2plus'/'manifest.json'
            if p.is_file():
                data=json.loads(p.read_text())
                data['schema']='greenquic-p7-d1-d2plus-v2'
                data['rapl_interval_semantics']='sample_monotonic_ns is interval end; energy attributed to [end-actual_interval,end]'
                p.write_text(json.dumps(data,indent=2)+"\n")
    except Exception as e:
        print(f'WARNING: could not annotate P7 D1/D2+ manifest: {e}')
raise SystemExit(rc)
