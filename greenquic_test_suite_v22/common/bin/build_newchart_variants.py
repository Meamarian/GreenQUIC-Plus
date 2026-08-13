#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import math
import os
import re
import statistics
import sys
from pathlib import Path
from typing import Any

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

SCOPES = ("active", "gap", "combined")
VERSIONS = ("without_variance", "with_variance")
EXPECTED_CHARTS = 62
T975 = {1:12.706,2:4.303,3:3.182,4:2.776,5:2.571,6:2.447,7:2.365,8:2.306,9:2.262,10:2.228,11:2.201,12:2.179,13:2.160,14:2.145,15:2.131,16:2.120,17:2.110,18:2.101,19:2.093,20:2.086,21:2.080,22:2.074,23:2.069,24:2.064,25:2.060,26:2.056,27:2.052,28:2.048,29:2.045,30:2.042}


def finite(v: Any) -> float | None:
    try:
        x = float(v)
        return x if math.isfinite(x) else None
    except (TypeError, ValueError):
        return None


def windows_for(windows: list[tuple[int,int]], scope: str) -> list[tuple[int,int]]:
    if not windows:
        return []
    if scope == "active":
        return list(windows)
    if scope == "gap":
        return [(windows[i][1], windows[i+1][0]) for i in range(len(windows)-1) if windows[i+1][0] > windows[i][1]]
    return [(windows[0][0], windows[-1][1])]


def inside(ts: int, windows: list[tuple[int,int]]) -> bool:
    return any(a <= ts <= b for a,b in windows)


def stats(values: list[float | None]) -> dict[str, Any]:
    a = [float(v) for v in values if v is not None and math.isfinite(float(v))]
    n = len(a)
    if not a:
        return {"n":0,"mean":None,"variance":None,"sd":None,"sem":None,"ci95_low":None,"ci95_high":None}
    mean = statistics.mean(a)
    if n < 2:
        return {"n":n,"mean":mean,"variance":None,"sd":None,"sem":None,"ci95_low":None,"ci95_high":None}
    variance = statistics.variance(a)  # unbiased sample variance, denominator n-1
    sd = math.sqrt(variance)
    sem = sd / math.sqrt(n)
    half = T975.get(n-1, 1.96) * sem
    return {"n":n,"mean":mean,"variance":variance,"sd":sd,"sem":sem,"ci95_low":mean-half,"ci95_high":mean+half}


def phase_rapl(record: dict[str,Any], endpoint: str, scope: str, key: str) -> float | None:
    if scope in ("active","gap"):
        return finite((record.get(f"{endpoint}_{scope}") or {}).get(key))
    a = record.get(f"{endpoint}_active") or {}
    g = record.get(f"{endpoint}_gap") or {}
    if key in ("energy_j","duration_s"):
        av,gv = finite(a.get(key)),finite(g.get(key))
        return av+gv if av is not None and gv is not None else None
    if key == "power_w":
        ae,ad,ge,gd = finite(a.get("energy_j")),finite(a.get("duration_s")),finite(g.get("energy_j")),finite(g.get("duration_s"))
        if None in (ae,ad,ge,gd) or ad+gd <= 0:
            return None
        return (ae+ge)/(ad+gd)
    return None


def cstate(record: dict[str,Any], endpoint: str, scope: str, metric: str, state: int | None = None) -> float | None:
    c = record.get(f"{endpoint}_cstate") or {}
    if not c:
        return None
    if state is not None:
        key = {"active":"active_by_state_s","gap":"gap_by_state_s","combined":"aligned_by_state_s"}[scope]
        return finite((c.get(key) or {}).get(state))
    keys = {
        ("active","idle_s"):"active_idle_s", ("gap","idle_s"):"gap_idle_s", ("combined","idle_s"):"aligned_idle_s",
        ("active","idle_fraction_pct"):"active_idle_fraction_pct", ("gap","idle_fraction_pct"):"gap_idle_fraction_pct", ("combined","idle_fraction_pct"):"aligned_idle_fraction_pct",
        ("active","intervals"):"active_intervals", ("gap","intervals"):"gap_intervals",
    }
    if (scope,metric) in keys:
        return finite(c.get(keys[(scope,metric)]))
    if scope == "combined" and metric == "intervals":
        a,g = finite(c.get("active_intervals")),finite(c.get("gap_intervals"))
        return a+g if a is not None and g is not None else None
    return None


def freq_rows(path: Path | None, shift: int) -> list[tuple[int,int,int]]:
    out=[]
    if path is None or not path.is_file():
        return out
    for raw in path.read_text(encoding="utf-8",errors="replace").splitlines():
        try: row=json.loads(raw)
        except Exception: continue
        if row.get("type") != "line": continue
        ts=finite(row.get("monotonic_ns"))
        m=re.search(r"\[CPU\s+(\d+)\].*?freq_khz=(\d+)",str(row.get("line","")))
        if ts is not None and m:
            out.append((int(ts)+shift,int(m.group(1)),int(m.group(2))))
    return out


def freq_metric(record: dict[str,Any], bundle: dict[str,Path], endpoint: str, scope: str, metric: str) -> float | None:
    ws=windows_for(record.get("windows") or [],scope)
    shift=int(record.get("server_shift_ns",0)) if endpoint=="server" else 0
    rows=[r for r in freq_rows(bundle.get("frequency"),shift) if inside(r[0],ws)]
    if not rows: return None
    khz=[r[2] for r in rows]
    if metric=="min": return min(khz)/1e6
    if metric=="mean": return statistics.mean(khz)/1e6
    if metric=="max": return max(khz)/1e6
    if metric=="samples": return float(len(rows))
    if metric=="changes":
        by={}
        for ts,cpu,f in rows: by.setdefault(cpu,[]).append((ts,f))
        return float(sum(sum(x[1]!=y[1] for x,y in zip(sorted(v),sorted(v)[1:])) for v in by.values()))
    return None


def timeline_counts(path: Path | None, windows: list[tuple[int,int]], tokens: dict[str,tuple[str,...]]) -> dict[str,float]:
    if path is None or not path.is_file() or not windows: return {}
    out={k:0.0 for k in tokens}; seen=False
    for raw in path.read_text(encoding="utf-8",errors="replace").splitlines():
        try: row=json.loads(raw)
        except Exception: continue
        ts=finite(row.get("monotonic_ns"))
        if ts is None or not inside(int(ts),windows): continue
        line=str(row.get("line","")).lower()
        for k,choices in tokens.items():
            if any(c.lower() in line for c in choices): out[k]+=1.0; seen=True
    return out if seen else {}


def per_mode(records, mode, getter):
    return [getter(rep,row) for (rep,m),row in sorted(records.items()) if m==mode]


def save_placeholder(root: Path, number: int, title: str, variance: bool):
    fig,ax=plt.subplots(figsize=(14,7)); ax.axis("off"); ax.set_title(title)
    ax.text(.5,.5,"Phase-attributed data unavailable\n(no valid timestamped source for this metric)",ha="center",va="center",transform=ax.transAxes)
    for ext in ("svg","pdf"):
        d=root/ext; d.mkdir(parents=True,exist_ok=True); fig.savefig(d/f"{number:02d}_unavailable.{ext}",bbox_inches="tight",dpi=300)
    plt.close(fig)


def save_scalar(root: Path, number: int, name: str, title: str, ylabel: str, series: dict[str,dict[str,list[float|None]]], modes, mode_names, variance: bool, stat_rows: list[dict[str,Any]], scope: str):
    if not any(any(v is not None for v in vals) for mm in series.values() for vals in mm.values()):
        save_placeholder(root,number,title,variance); return
    fig,ax=plt.subplots(figsize=(15,8)); x=np.arange(len(modes),dtype=float); width=min(.72/max(1,len(series)),.24)
    for j,(label,by_mode) in enumerate(series.items()):
        ss=[stats(by_mode.get(m,[])) for m in modes]; means=[s["mean"] if s["mean"] is not None else np.nan for s in ss]; pos=x+(j-(len(series)-1)/2)*width
        if variance:
            sd=[s["sd"] if s["sd"] is not None else 0.0 for s in ss]; ax.errorbar(pos,means,yerr=sd,fmt="o",capsize=5,label=label)
            for px,mu,s in zip(pos,means,ss):
                if math.isfinite(mu): ax.annotate((f"μ={mu:.2f}\nσ²={s['variance']:.3g}" if s['variance'] is not None else f"μ={mu:.2f}\nn={s['n']}"),(px,mu),xytext=(0,10),textcoords="offset points",ha="center",fontsize=7)
        else:
            bars=ax.bar(pos,means,width,label=label)
            for b,mu in zip(bars,means):
                if math.isfinite(mu): ax.annotate(f"{mu:.2f}",(b.get_x()+b.get_width()/2,b.get_height()),xytext=(0,7),textcoords="offset points",ha="center",fontsize=8)
        for mode,s in zip(modes,ss): stat_rows.append({"chart":number,"name":name,"scope":scope,"series":label,"mode":mode,**s})
    ax.set_xticks(x,[mode_names[m] for m in modes]); ax.set_ylabel(ylabel); ax.set_title(title); ax.grid(axis="y",alpha=.3); ax.set_axisbelow(True); ax.set_ylim(bottom=0)
    if len(series)>1: ax.legend(loc="center left",bbox_to_anchor=(1.01,.5))
    for ext in ("svg","pdf"):
        d=root/ext; d.mkdir(parents=True,exist_ok=True); fig.savefig(d/f"{number:02d}_{name}.{ext}",bbox_inches="tight",dpi=300)
    plt.close(fig)


def write_stats(path: Path, rows: list[dict[str,Any]]):
    cols=["chart","name","scope","series","mode","n","mean","variance","sd","sem","ci95_low","ci95_high"]
    path.parent.mkdir(parents=True,exist_ok=True)
    with path.open("w",newline="",encoding="utf-8") as f:
        w=csv.DictWriter(f,fieldnames=cols); w.writeheader(); [w.writerow({k:r.get(k) for k in cols}) for r in rows]


def main() -> int:
    p=argparse.ArgumentParser(description="Generate six non-destructive active/gap/combined chart sets")
    p.add_argument("--input",type=Path,required=True); p.add_argument("--output",type=Path); p.add_argument("--reporter-dir",type=Path,required=True)
    a=p.parse_args(); reporter=a.reporter_dir.resolve(); sys.path.insert(0,str(reporter))
    import build_sheet_rules_all_aligned as aligned
    base=aligned.base; modes=base.MODES; mode_names=base.MODE_NAMES
    root=a.input.resolve(); report=(a.output or (root/"the_sheet_rules_all")).resolve(); out=report/"newchart"
    records=base.raw_data(root); files=base.discover_files(root); all_stats=[]
    event_specs={25:("server",{"Attempts":("policy_action=epoll",),"Wakeups":("epoll_wake",),"Timeouts":("epoll_timeout",)}),27:("client",{"Attempts":("policy_action=epoll",),"Wakeups":("epoll_wake",),"Timeouts":("epoll_timeout",)}),31:("server",{"max_hard":("policy_action=freq_max_hard",),"max_control":("policy_action=freq_max_control",),"up":("policy_action=freq_up",),"down":("policy_action=freq_down",),"min":("policy_action=freq_min",)}),33:("client",{"max_hard":("policy_action=freq_max_hard",),"max_control":("policy_action=freq_max_control",),"up":("policy_action=freq_up",),"down":("policy_action=freq_down",),"min":("policy_action=freq_min",)}),37:("client",{"ACK_PENDING":("ack_pending",),"CUBIC ramping":("cubic_ramping",)}),38:("client",{"CWND blocked":("cubic_cwnd_blocked",),"Recovery":("cubic_recovery",)})}
    for scope in SCOPES:
        for version in VERSIONS:
            variance=version=="with_variance"; dest=out/scope/version; rows=[]; generated=set()
            for num,ep in ((14,"server"),(15,"client"),(19,"server"),(20,"client")):
                ser={f"state{s}":{m:per_mode(records,m,lambda rep,r,ep=ep,s=s:cstate(r,ep,scope,"state",s)) for m in modes} for s in range(4)}
                save_scalar(dest,num,f"{ep}_cstate",f"{scope.title()} — {ep.title()} C-state residency","Seconds",ser,modes,mode_names,variance,rows,scope); generated.add(num)
            for num,metric,title,ylabel in ((16,"idle_s","Total CPU idle time","Seconds"),(17,"idle_fraction_pct","CPU idle fraction","Percent"),(18,"intervals","Idle intervals","Count"),(21,"idle_s","Gap/phase CPU idle time","Seconds"),(22,"idle_fraction_pct","Gap/phase idle fraction","Percent"),(23,"intervals","Gap/phase idle intervals","Count")):
                ser={ep.title():{m:per_mode(records,m,lambda rep,r,ep=ep,metric=metric:cstate(r,ep,scope,metric)) for m in modes} for ep in ("server","client")}
                save_scalar(dest,num,f"cstate_{metric}_{num}",f"{scope.title()} — {title}",ylabel,ser,modes,mode_names,variance,rows,scope); generated.add(num)
            for num,key,title,ylabel in ((7,"power_w","Average RAPL power","Power (W)"),(8,"energy_j","RAPL energy","Energy (J)"),(44,"power_w","RAPL power","Power (W)"),(45,"power_w","RAPL power","Power (W)"),(46,"energy_j","RAPL energy","Energy (J)"),(47,"energy_j","RAPL energy","Energy (J)")):
                srv={m:per_mode(records,m,lambda rep,r,key=key:phase_rapl(r,"server",scope,key)) for m in modes}; cli={m:per_mode(records,m,lambda rep,r,key=key:phase_rapl(r,"client",scope,key)) for m in modes}; comb={}
                for m in modes:
                    comb[m]=[(x+y if x is not None and y is not None else None) for x,y in zip(srv[m],cli[m])]
                save_scalar(dest,num,f"rapl_{key}_{num}",f"{scope.title()} — {title}",ylabel,{"Server":srv,"Client":cli,"Combined":comb},modes,mode_names,variance,rows,scope); generated.add(num)
            for num,ep in ((29,"server"),(30,"client")):
                ser={}
                for metric,label in (("min","Min"),("mean","Mean"),("max","Max")):
                    ser[label]={m:[freq_metric(r,files.get((ep,rep,m),{}),ep,scope,metric) for (rep,mm),r in sorted(records.items()) if mm==m] for m in modes}
                save_scalar(dest,num,f"{ep}_frequency",f"{scope.title()} — {ep.title()} observed frequency","GHz",ser,modes,mode_names,variance,rows,scope); generated.add(num)
            ser={ep.title():{m:[freq_metric(r,files.get((ep,rep,m),{}),ep,scope,"samples") for (rep,mm),r in sorted(records.items()) if mm==m] for m in modes} for ep in ("server","client")}
            save_scalar(dest,36,"frequency_samples",f"{scope.title()} — timestamped frequency samples","Count",ser,modes,mode_names,variance,rows,scope); generated.add(36)
            for num,(ep,tokens) in event_specs.items():
                ser={name:{m:[] for m in modes} for name in tokens}
                for (rep,m),r in sorted(records.items()):
                    ws=windows_for(r.get("windows") or [],scope)
                    if ep=="server":
                        sh=int(r.get("server_shift_ns",0)); ws=[(x-sh,y-sh) for x,y in ws]
                    counts=timeline_counts(files.get((ep,rep,m),{}).get("timeline"),ws,tokens)
                    for name in tokens: ser[name][m].append(counts.get(name) if counts else None)
                save_scalar(dest,num,f"events_{num}",f"{scope.title()} — timestamped {ep} events","Count",ser,modes,mode_names,variance,rows,scope); generated.add(num)
            for num in range(1,EXPECTED_CHARTS+1):
                if num not in generated: save_placeholder(dest,num,f"{scope.title()} — chart {num}",variance)
            write_stats(dest/"statistics.csv",rows); all_stats.extend(rows)
    write_stats(out/"statistics_all_scopes.csv",all_stats)
    manifest={"schema":"greenquic-newchart-v1","six_versions":[f"{s}/{v}" for s in SCOPES for v in VERSIONS],"charts_per_version":EXPECTED_CHARTS,"variance":"unbiased sample variance across independent repetitions (n-1)","error_bars":"mean ± sample SD across independent repetitions","ci95":"Student-t 95% CI of the repetition mean","combined":"D1 start through D5 completion = active transfer + inter-download gaps only","timestamp_policy":"phase attribution requires absolute MONOTONIC timestamps; legacy elapsed-only frequency traces are not inferred","existing_charts":"unchanged"}
    out.mkdir(parents=True,exist_ok=True); (out/"manifest.json").write_text(json.dumps(manifest,indent=2)+"\n",encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
