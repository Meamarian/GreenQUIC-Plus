#!/usr/bin/env python3
"""Corrected P5 D1/D2+ report entry point.

The C RAPL sampler timestamps each row *after* reading the counters, and
actual_interval_ms is the elapsed interval since the previous sample. Therefore
sample energy belongs to [sample_monotonic_ns - actual_interval, sample_monotonic_ns].
The original D1/D2+ reporter treated sample_monotonic_ns as the interval start;
this wrapper corrects that without changing the existing 62-chart report.
"""
from __future__ import annotations
import importlib.util
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
BASE = HERE / "build_d1_d2plus_report.py"
spec = importlib.util.spec_from_file_location("gq_d1d2_base", BASE)
if spec is None or spec.loader is None:
    raise SystemExit(f"ERROR: cannot import {BASE}")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def read_msr_interval_end(path, shift=0):
    rows = mod.read_csv(path)
    if not rows:
        return None
    T=[]; DT=[]; E=[]; PK=[]; DR=[]
    for r in rows:
        end_ns=mod.finite(r.get('sample_monotonic_ns'))
        dt_ms=mod.finite(r.get('actual_interval_ms'))
        pk=mod.finite(r.get('package_delta_j'))
        dr=mod.finite(r.get('dram_delta_j')) or 0
        if None in (end_ns,dt_ms,pk) or dt_ms <= 0:
            continue
        dt_s=dt_ms/1000.0
        start_ns=int(round(end_ns-dt_ms*1_000_000.0))+int(shift)
        T.append(start_ns); DT.append(dt_s); PK.append(pk); DR.append(dr); E.append(pk+dr)
    if not T:
        return None
    return {
        't':mod.np.array(T,mod.np.int64),
        'dt':mod.np.array(DT,float),
        'e':mod.np.array(E,float),
        'pk':mod.np.array(PK,float),
        'dr':mod.np.array(DR,float),
    }

mod.read_msr = read_msr_interval_end
rc = mod.main()
if rc == 0:
    # Make the corrected semantics auditable in the generated report.
    # The V2 boundary snapshot intentionally does not read DPDK-worker-owned
    # EPOLL/DVFS policy counters; those chart slots remain explicitly unavailable.
    import sys
    try:
        args=sys.argv[1:]
        root=None
        for i,a in enumerate(args):
            if a == '--input' and i+1 < len(args):
                root=Path(args[i+1])
                break
        if root is not None:
            p=root/'the_sheet_rules_all'/'d1_d2plus'/'manifest.json'
            if p.is_file():
                data=json.loads(p.read_text())
                data['schema']='greenquic-p5-d1-d2plus-v2'
                data['rapl_interval_semantics']='sample_monotonic_ns is interval end; energy attributed to [end-actual_interval,end]'
                data['snapshot_schema']='greenquic-p5-position-v2'
                data['snapshot_exact_fields']=['rx_pkts','tx_pkts','QUIC hint counters']
                data['snapshot_unavailable_fields']=['EPOLL counters','DVFS policy-action counters','DVFS result counters']
                data['snapshot_unavailable_reason']='worker-owned counters are not read concurrently and no extra per-poll/per-policy instrumentation is added'
                p.write_text(json.dumps(data,indent=2)+"\n")
    except Exception as e:
        print(f'WARNING: could not annotate D1/D2+ manifest: {e}')
raise SystemExit(rc)
