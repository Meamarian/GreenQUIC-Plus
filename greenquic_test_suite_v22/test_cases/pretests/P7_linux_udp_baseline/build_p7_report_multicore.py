#!/usr/bin/env python3
"""Multicore-safe P7 report wrapper."""
from __future__ import annotations
import argparse, csv, json, math, os, shutil, statistics, tempfile
from pathlib import Path
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import build_p7_report as stock_wrapper

stock = stock_wrapper.mod

def cpus(text):
    out=set()
    for tok in text.replace(" ","").split(","):
        if not tok: continue
        if "-" in tok:
            a,b=map(int,tok.split("-",1)); out.update(range(a,b+1))
        else: out.add(int(tok))
    return sorted(out)

def env_value(text,key):
    p=key+"="
    for line in text.splitlines():
        if line.startswith(p): return line[len(p):].strip()
    return None

def runs(root,endpoint):
    out=[]
    for d in sorted((root/"runs"/endpoint).glob("rep*")):
        p=d/"summary.json"
        if p.is_file(): out.append(json.loads(p.read_text()))
    return out

def finite(v):
    try:x=float(v)
    except (TypeError,ValueError):return None
    return x if math.isfinite(x) else None

def freq(summary,scope,cpu):
    return finite((((summary.get("scopes") or {}).get(scope) or {}).get("frequency") or {}).get(str(cpu),{}).get("mean_ghz"))

def fmean(summary,scope,cores):
    v=[freq(summary,scope,c) for c in cores]
    return statistics.mean(v) if v and all(x is not None for x in v) else None

def idle_pct(summary,scope,ncpu):
    s=((summary.get("scopes") or {}).get(scope) or {})
    duration=finite(s.get("duration_s"))
    if duration is None or duration<=0:return None
    total=0.0
    for row in (s.get("cstate") or {}).values():
        x=finite((row or {}).get("seconds"))
        if x is not None: total+=x
    return total/(duration*ncpu)*100.0

def stat(values):
    v=[float(x) for x in values if x is not None and math.isfinite(float(x))]
    if not v:return 0,None,None
    return len(v),statistics.mean(v),statistics.stdev(v) if len(v)>1 else None

def bar(path,title,ylabel,categories,series,stats):
    path.parent.mkdir(parents=True,exist_ok=True)
    x=np.arange(len(categories)); width=min(.78/max(1,len(series)),.3)
    fig,ax=plt.subplots(figsize=(12,7))
    for j,(label,groups) in enumerate(series.items()):
        ss=[stat(g) for g in groups]
        means=[np.nan if s[1] is None else s[1] for s in ss]
        err=[0 if s[2] is None else s[2] for s in ss]
        pos=x+(j-(len(series)-1)/2)*width
        bars=ax.bar(pos,means,width,label=label,yerr=err,capsize=5)
        for cat,s in zip(categories,ss):
            stats.append([path.stem,label,cat,*s])
        for b,m in zip(bars,means):
            if math.isfinite(m):
                ax.annotate(f"{m:.3f}",(b.get_x()+b.get_width()/2,m),xytext=(0,5),textcoords="offset points",ha="center",fontsize=8)
    ax.set_title(title,fontweight="normal");ax.set_ylabel(ylabel);ax.set_xticks(x,categories)
    ax.set_ylim(bottom=0);ax.grid(axis="y",alpha=.3);ax.set_axisbelow(True)
    if len(series)>1:ax.legend(loc="center left",bbox_to_anchor=(1.01,.5))
    fig.tight_layout();fig.savefig(path,bbox_inches="tight",dpi=300);plt.close(fig)

def stock_report(root,report,cores,config):
    with tempfile.TemporaryDirectory(prefix="p7_multicore_report_") as td:
        view=Path(td); os.symlink(root/"runs",view/"runs",target_is_directory=True)
        shutil.copy2(root/"p7_all_runs.csv",view/"p7_all_runs.csv")
        lines=[f"dataplane_cpu={cores[0]}" if x.startswith("dataplane_cpu=") else x for x in config.splitlines()]
        (view/"matrix_config.env").write_text("\n".join(lines)+"\n")
        stock.build(view,report)

def main():
    ap=argparse.ArgumentParser();ap.add_argument("--matrix-dir",type=Path,required=True);ap.add_argument("--output",type=Path)
    a=ap.parse_args();root=a.matrix_dir.resolve();report=(a.output or root/"the_sheet_rules_all").resolve()
    cfg=(root/"matrix_config.env").read_text(); cores=cpus(env_value(cfg,"dataplane_cpu") or "")
    if len(cores)<2:raise SystemExit(f"ERROR: multicore report needs >=2 dataplane CPUs, got {cores}")
    stock_report(root,report,cores,cfg)
    S,C=runs(root,"server"),runs(root,"client")
    if not S or len(S)!=len(C):raise SystemExit("ERROR: incomplete P7 summaries")
    multi=report/"multicore";charts=multi/"charts";stats=[];errors=[]
    for scope in ("active","gap","combined"):
        cats=[f"CPU{x}" for x in cores]+["Dataplane mean"]
        sg=[[freq(s,scope,c) for s in S] for c in cores]+[[fmean(s,scope,cores) for s in S]]
        cg=[[freq(s,scope,c) for s in C] for c in cores]+[[fmean(s,scope,cores) for s in C]]
        bar(charts/f"frequency_{scope}.svg",f"Linux multicore dataplane frequency — {scope}","GHz",cats,{"Server":sg,"Client":cg},stats)
        si=[idle_pct(s,scope,len(cores)) for s in S];ci=[idle_pct(s,scope,len(cores)) for s in C]
        for ep,vals in (("server",si),("client",ci)):
            for i,v in enumerate(vals,1):
                if v is not None and not(-1e-6<=v<=100.000001):errors.append(f"{ep} rep{i:02d} {scope} normalized idle={v:.6f}%")
        bar(charts/f"cstate_idle_fraction_{scope}.svg",f"Linux multicore mean per-core C-state idle fraction — {scope}","Percent",["Server","Client"],{"Idle fraction":[si,ci]},stats)
    multi.mkdir(parents=True,exist_ok=True)
    with (multi/"multicore_chart_statistics.csv").open("w",newline="") as f:
        w=csv.writer(f);w.writerow(["chart","series","category","n","mean","sd"]);w.writerows(stats)
    data={"schema":"greenquic-p7-multicore-report-v1","dataplane_cpus":cores,
          "stock_report_frequency":f"stock CPU-specific charts remain CPU{cores[0]}-specific",
          "multicore_frequency":"per-CPU plus arithmetic dataplane-CPU mean",
          "multicore_cstate_fraction":"idle CPU-seconds / wall-clock scope / dataplane CPU count",
          "errors":errors,"status":"PASS" if not errors else "FAIL"}
    (multi/"multicore_validation.json").write_text(json.dumps(data,indent=2)+"\n")
    (multi/"README.txt").write_text("Stock P7 report plus multicore extension. Raw traces are unchanged. Multicore C-state fractions are normalized by measured dataplane CPU count.\n")
    if errors:
        for e in errors:print("ERROR:",e)
        return 2
    print(f"P7 MULTICORE REPORT PASS: CPUs={','.join(map(str,cores))}");print(f"REPORT: {report}");return 0

if __name__=="__main__":raise SystemExit(main())
