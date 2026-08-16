#!/usr/bin/env python3
from __future__ import annotations
import importlib.util
from pathlib import Path
HERE=Path(__file__).resolve().parent;IMPL=HERE/"rapl_msr_trace_impl_v4.py"
spec=importlib.util.spec_from_file_location("greenquic_rapl_msr_trace_impl_v4",IMPL)
if spec is None or spec.loader is None:raise SystemExit(f"ERROR: cannot import {IMPL}")
mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)

def write_scope_plots(*,rows,role,scope,power_svg,energy_svg,histogram,duration_ms):
    power_x=[r["elapsed_ms"]-r["actual_interval_ms"]/2.0 for r in rows]
    energy_x=[r["elapsed_ms"] for r in rows]
    package=[r["package_power_smoothed_w"] for r in rows];dram=[r["dram_power_smoothed_w"] for r in rows];total=[r["total_power_smoothed_w"] for r in rows]
    power_plot=mod.write_line_svg(power_svg,kind="msr",title=f"GreenQUIC {role} RAPL package and DRAM power — {scope}",y_label="Power [W]",
        series=[{"label":"Package","points":list(zip(power_x,package))},{"label":"DRAM","points":list(zip(power_x,dram))},{"label":"Package + DRAM","points":list(zip(power_x,total))}],
        duration_ms=duration_ms,step=False,y_value_format=".2f")
    mod.histogram_svg(histogram,total,role,scope)
    cp=[];cd=[];ct=[];pr=0.0;dr=0.0
    for r in rows:
        pr+=r["package_delta_j"];dr+=r["dram_delta_j"];cp.append(pr);cd.append(dr);ct.append(pr+dr)
    energy_plot=mod.write_line_svg(energy_svg,kind="msr",title=f"GreenQUIC {role} RAPL cumulative energy — {scope}",y_label="Energy [J]",
        series=[{"label":"Package","points":list(zip(energy_x,cp))},{"label":"DRAM","points":list(zip(energy_x,cd))},{"label":"Package + DRAM","points":list(zip(energy_x,ct))}],
        duration_ms=duration_ms,step=False,y_value_format=".3f")
    return power_plot,energy_plot
mod.write_scope_plots=write_scope_plots
if __name__=="__main__":raise SystemExit(mod.main())
