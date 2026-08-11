#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import math
import re
import statistics
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable
from xml.sax.saxutils import escape

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

MODES = ("off", "basic", "plus")
MODE_NAMES = {"off": "MsQuic-DPDK", "basic": "GreenQUIC", "plus": "GreenQUIC+"}
MODE_COLORS = {"off": "#4C78A8", "basic": "#F58518", "plus": "#54A24B"}
ENDPOINT_COLORS = {"Server": "#4C78A8", "Client": "#F58518", "Combined": "#54A24B"}
PHASE_COLORS = {"startup": "#E6E6E6", "pre": "#DCEAF7", "active": "#E4F3E7", "gap": "#FFF0C9", "post": "#DCEAF7", "tail": "#EEE3F5"}
PHASE_LABELS = {
    "startup": ("Startup", 9),
    "pre": ("Pre-cool", 10),
    "active": ("D{index}", 16),
    "gap": ("Gap {index}", 14),
    "post": ("Post-cool", 10),
    "tail": ("Tail", 8),
}
EXPECTED_CHARTS = 62
WARNINGS: list[dict[str, str]] = []
WARNING_CHARTS: set[int] = set()


def warn(code: str, message: str, context: str = "") -> None:
    row = {"code": code, "message": message, "context": context}
    WARNINGS.append(row)
    suffix = f" ({context})" if context else ""
    print(f"[the_sheet_rules_all:WARN] {code}: {message}{suffix}")


def normalized(value: Any) -> str:
    return re.sub(r"[^a-z0-9]+", "_", str(value).lower()).strip("_")


def finite(value: Any) -> float | None:
    try:
        result = float(str(value).replace(",", "").strip().split()[0])
    except (TypeError, ValueError, IndexError):
        return None
    return result if math.isfinite(result) else None


def mean_value(values: Iterable[Any]) -> float | None:
    rows = [float(v) for v in values if finite(v) is not None]
    return statistics.mean(rows) if rows else None


def read_csv(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        return []
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = [line for line in text.splitlines() if line and not line.startswith("#")]
    if not lines:
        return []
    return list(csv.DictReader(lines))


def mode_rows(rows: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    return {str(row.get("mode", "")).lower(): row for row in rows}


def field(row: dict[str, Any] | None, *parts: str) -> float | None:
    if not row:
        return None
    wanted = [normalized(part) for part in parts]
    for key, value in row.items():
        key_norm = normalized(key)
        if all(part in key_norm for part in wanted):
            result = finite(value)
            if result is not None:
                return result
    return None


def load_tables(root: Path) -> dict[str, list[dict[str, str]]]:
    table_root = root / "tables"
    return {
        "client_avg": read_csv(table_root / "client_mode_averages.csv"),
        "server_avg": read_csv(table_root / "server_mode_averages.csv"),
        "combined_avg": read_csv(table_root / "combined_endpoint_mode_averages.csv"),
        "behavior": read_csv(table_root / "power_management_behavior_mode_averages.csv"),
        "client_runs": read_csv(table_root / "client_all_runs.csv"),
        "server_runs": read_csv(table_root / "server_all_runs.csv"),
    }


def values3(rows: list[dict[str, Any]], *parts: str) -> list[float | None]:
    indexed = mode_rows(rows)
    return [field(indexed.get(mode), *parts) for mode in MODES]


def infer_run(path: Path) -> tuple[str | None, int | None, str | None]:
    text = "/".join(path.parts[-9:]).lower()
    role = "client" if "client" in text else ("server" if "server" in text else None)
    for pattern, swapped in ((r"rep[_-]?(\d+)[_-]?(off|basic|plus)", False), (r"rep(\d+)_(off|basic|plus)", False), (r"(off|basic|plus).*?rep[_-]?(\d+)", True)):
        match = re.search(pattern, text)
        if match:
            return (role, int(match.group(2)), match.group(1)) if swapped else (role, int(match.group(1)), match.group(2))
    return None, None, None


def discover_files(root: Path) -> dict[tuple[str, int, str], dict[str, Path]]:
    result: dict[tuple[str, int, str], dict[str, Path]] = {}
    patterns = {
        "msr": "*_msr_power.csv", "log": "*_log.txt", "timeline": "*_timeline.jsonl",
        "cstate": "*_cstate.csv", "cstate_json": "*_cstate.json",
        "frequency": "*_frequency_samples.jsonl", "counters": "*_greenquic_counters.csv",
        "dpdk_config": "*_dpdk_config.txt", "powermng_config": "*_powermng_config.txt",
        "power_json": "*_power.json",
    }
    for key, pattern in patterns.items():
        for path in root.rglob(pattern):
            if "the_sheet_rules_all" in path.parts:
                continue
            role, repetition, mode = infer_run(path)
            if role and repetition and mode:
                result.setdefault((role, repetition, mode), {})[key] = path
    return result


def read_request_windows(path: Path | None) -> list[tuple[int, int]]:
    if path is None or not path.is_file():
        return []
    text = path.read_text(encoding="utf-8", errors="replace")
    starts = {int(i): int(ts) * 1000 for i, ts in re.findall(r"request=(\d+)/\d+\s+start_us=(\d+)", text)}
    ends = {int(i): int(ts) * 1000 for i, ts in re.findall(r"request=(\d+)/\d+\s+complete_us=(\d+)", text)}
    return [(starts[i], ends[i]) for i in sorted(starts.keys() & ends.keys()) if ends[i] >= starts[i]]


def read_get_times(path: Path | None) -> list[int]:
    if path is None or not path.is_file():
        return []
    output: list[int] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "GET" not in line.upper():
            continue
        try:
            row = json.loads(line)
        except Exception:
            continue
        for key, value in row.items():
            if isinstance(value, (int, float)) and ("mono" in normalized(key) or normalized(key) in {"timestamp_ns", "time_ns"}):
                output.append(int(value)); break
    return output[:5]


def read_msr(path: Path | None) -> dict[str, np.ndarray] | None:
    if path is None or not path.is_file():
        return None
    rows = read_csv(path)
    if not rows:
        return None
    keys = {normalized(key): key for key in rows[0]}
    def choose(*candidates: str) -> str | None:
        for candidate in candidates:
            c = normalized(candidate)
            for nk, key in keys.items():
                if c == nk or c in nk:
                    return key
        return None
    time_key = choose("sample_monotonic_ns", "monotonic_ns", "timestamp_ns", "monotonic_us")
    interval_key = choose("actual_interval_ms", "interval_ms")
    package_key = choose("package_delta_j")
    dram_key = choose("dram_delta_j")
    if not time_key or not package_key:
        return None
    times=[]; durations=[]; energies=[]
    for row in rows:
        t=finite(row.get(time_key)); p=finite(row.get(package_key)); d=finite(row.get(dram_key)) if dram_key else 0.0; iv=finite(row.get(interval_key)) if interval_key else None
        if t is None or p is None: continue
        if "us" in normalized(time_key) and "ns" not in normalized(time_key): t *= 1000.0
        times.append(int(t)); durations.append(iv/1000.0 if iv else math.nan); energies.append(p+(d or 0.0))
    if len(times)<2: return None
    good=[v for v in durations if math.isfinite(v) and v>0]; median=statistics.median(good) if good else .006
    for i in range(len(durations)):
        if not math.isfinite(durations[i]) or durations[i]<=0: durations[i]=(times[i+1]-times[i])/1e9 if i+1<len(times) else median
    t=np.asarray(times,dtype=np.int64); dt=np.asarray(durations,float); e=np.asarray(energies,float)
    return {"t":t,"dt":dt,"e":e,"p":e/dt}


def phase_spans(windows, trace_start, trace_end):
    if not windows:return []
    output=[]; first=windows[0][0]; last=windows[-1][1]; pre=max(trace_start,first-5_000_000_000)
    if pre>trace_start: output.append(("startup",None,trace_start,pre))
    if first>pre: output.append(("pre",None,pre,first))
    for i,(start,end) in enumerate(windows,1):
        output.append(("active",i,start,end))
        if i<len(windows): output.append(("gap",i,end,windows[i][0]))
    post=min(trace_end,last+5_000_000_000)
    if post>last: output.append(("post",None,last,post))
    if trace_end>post: output.append(("tail",None,post,trace_end))
    return [(k,i,max(a,trace_start),min(b,trace_end)) for k,i,a,b in output if b>a]


def integrate_msr(trace, spans, kinds):
    energy=duration=0.0
    for i,a in enumerate(trace["t"]):
        b=int(a+trace["dt"][i]*1e9)
        for kind,_,s,e in spans:
            if kind not in kinds: continue
            overlap=max(0,min(b,e)-max(int(a),s))
            if overlap:
                energy+=float(trace["e"][i])*overlap/max(1,b-int(a)); duration+=overlap/1e9
    return {"energy_j":energy,"duration_s":duration,"power_w":energy/duration if duration else None}


@dataclass
class ClockBridge:
    start_raw_ns:int; start_mono_ns:int; start_uncertainty_ns:int
    end_raw_ns:int|None=None; end_mono_ns:int|None=None; end_uncertainty_ns:int|None=None
    method:str="clock_bridge_v1"
    def raw_to_mono(self, raw_ns:int)->int:
        start_offset=self.start_mono_ns-self.start_raw_ns
        if self.end_raw_ns is None or self.end_mono_ns is None or self.end_raw_ns==self.start_raw_ns:return int(raw_ns+start_offset)
        end_offset=self.end_mono_ns-self.end_raw_ns
        fraction=max(0.0,min(1.0,(raw_ns-self.start_raw_ns)/(self.end_raw_ns-self.start_raw_ns)))
        return int(raw_ns+start_offset+fraction*(end_offset-start_offset))


def read_clock_bridge(path:Path|None)->ClockBridge|None:
    if path and path.is_file():
        rows=[]
        for line in path.read_text(encoding="utf-8",errors="replace").splitlines():
            try: row=json.loads(line)
            except Exception: continue
            if row.get("type")=="clock_bridge" and finite(row.get("monotonic_ns")) is not None and finite(row.get("monotonic_raw_ns")) is not None: rows.append(row)
        if rows:
            start=next((r for r in rows if r.get("phase")=="start"),rows[0]); end=next((r for r in reversed(rows) if r.get("phase")=="end"),None)
            return ClockBridge(int(start["monotonic_raw_ns"]),int(start["monotonic_ns"]),int(start.get("uncertainty_ns",0)),int(end["monotonic_raw_ns"]) if end else None,int(end["monotonic_ns"]) if end else None,int(end.get("uncertainty_ns",0)) if end else None)
    return None


def read_cstate(path:Path|None,bridge:ClockBridge|None,windows:list[tuple[int,int]])->dict[str,Any]|None:
    if path is None or not path.is_file():return None
    rows=read_csv(path)
    if not rows:return None
    intervals=[]; entries=0; raw_times=[]
    for row in rows:
        ts=finite(row.get("timestamp_mono_raw_ns")); duration=finite(row.get("idle_duration_ns")); previous=finite(row.get("previous_state")); event=str(row.get("event","")).lower()
        if ts is None:continue
        raw_times.append(int(ts))
        if event in {"enter","reenter"}:entries+=1
        if duration is None or duration<=0 or previous is None or previous<0:continue
        end=int(ts); intervals.append((end-int(duration),end,int(previous)))
    if not raw_times:return None
    whole={}
    for a,b,state in intervals:whole[state]=whole.get(state,0.0)+(b-a)/1e9
    result={"whole_by_state_s":whole,"whole_idle_s":sum(whole.values()),"trace_duration_s":(max(raw_times)-min(raw_times))/1e9 if len(raw_times)>1 else 0.0,"linux_idle_entries":entries,"clock_method":bridge.method if bridge else "unmapped_mono_raw","clock_uncertainty_ns":max(bridge.start_uncertainty_ns,bridge.end_uncertainty_ns or 0) if bridge else None}
    if bridge is None or not windows:return result
    mapped=[(bridge.raw_to_mono(a),bridge.raw_to_mono(b),state) for a,b,state in intervals]
    gaps=[(windows[i][1],windows[i+1][0]) for i in range(len(windows)-1)]
    def clip(targets):
        by={}; total=0.0; count=0
        for a,b,state in mapped:
            hit=False
            for s,e in targets:
                overlap=max(0,min(b,e)-max(a,s))
                if overlap:
                    sec=overlap/1e9;by[state]=by.get(state,0.0)+sec;total+=sec;hit=True
            if hit:count+=1
        return by,total,count
    active_by,active_idle,active_count=clip(windows); gap_by,gap_idle,gap_count=clip(gaps); aligned_by,aligned_idle,_=clip([(windows[0][0],windows[-1][1])])
    active_duration=sum((b-a)/1e9 for a,b in windows); gap_duration=sum((b-a)/1e9 for a,b in gaps); aligned_duration=(windows[-1][1]-windows[0][0])/1e9
    result.update({"active_by_state_s":active_by,"gap_by_state_s":gap_by,"aligned_by_state_s":aligned_by,"active_idle_s":active_idle,"gap_idle_s":gap_idle,"aligned_idle_s":aligned_idle,"active_intervals":active_count,"gap_intervals":gap_count,"active_duration_s":active_duration,"gap_duration_s":gap_duration,"aligned_duration_s":aligned_duration,"active_idle_fraction_pct":active_idle/active_duration*100 if active_duration else None,"gap_idle_fraction_pct":gap_idle/gap_duration*100 if gap_duration else None,"aligned_idle_fraction_pct":aligned_idle/aligned_duration*100 if aligned_duration else None})
    return result


def read_counters(path):
    rows=read_csv(path) if path else []
    if not rows:return {}
    out={}
    for k,v in rows[-1].items():
        number=finite(v);out[k]=number if number is not None else v
    return out


def read_frequency(path):
    if path is None or not path.is_file():return None
    bridge=read_clock_bridge(path); values=[]
    for line in path.read_text(encoding="utf-8",errors="replace").splitlines():
        try:row=json.loads(line)
        except Exception:continue
        if row.get("type")!="line":continue
        match=re.search(r"\[CPU\s+(\d+)\].*?freq_khz=(\d+)",str(row.get("line","")));elapsed=finite(row.get("elapsed_s"))
        if match and elapsed is not None:values.append((elapsed,int(match.group(1)),int(match.group(2))))
    if not values:return {"bridge":bridge}
    by={}
    for elapsed,cpu,khz in values:by.setdefault(cpu,[]).append((elapsed,khz))
    changed=0
    for rows in by.values():
        rows.sort();changed+=sum(1 for (_,a),(_,b) in zip(rows,rows[1:]) if a!=b)
    return {"bridge":bridge,"min_ghz":min(v for _,_,v in values)/1e6,"max_ghz":max(v for _,_,v in values)/1e6,"sample_events":len(values),"changed_samples":changed}


def read_config(path):
    if path is None or not path.is_file():return {}
    out={}
    for raw in path.read_text(encoding="utf-8",errors="replace").splitlines():
        line=raw.strip()
        if line and not line.startswith(("#",";")) and "=" in line:
            key,value=line.split("=",1);out[key.strip()]=value.strip()
    return out


def read_acpi(path):
    if path is None or not path.is_file():return {}
    try:row=json.loads(path.read_text(encoding="utf-8",errors="replace"))
    except Exception:return {}
    return row if isinstance(row,dict) else {}


def raw_data(root):
    files=discover_files(root);output={};reps=sorted({rep for _,rep,_ in files})
    for mode in MODES:
        for rep in reps:
            client=files.get(("client",rep,mode),{});server=files.get(("server",rep,mode),{});windows=read_request_windows(client.get("log"));C=read_msr(client.get("msr"));S=read_msr(server.get("msr"))
            if not windows and C is None and S is None and not client and not server:continue
            shift=0;gets=read_get_times(server.get("timeline"))
            if windows and gets:shift=int(statistics.median([windows[i][0]-gets[i] for i in range(min(len(windows),len(gets)))]))
            elif S is not None and windows:warn("server_clock_alignment","Server RAPL exists but no GET timestamps were found; server phase alignment uses zero shift",f"rep{rep:02d} {mode}")
            record={"windows":windows,"server_shift_ns":shift}
            for endpoint,trace in (("client",C),("server",S)):
                if trace is None:continue
                aligned={**trace,"t":trace["t"]+(shift if endpoint=="server" else 0)};spans=phase_spans(windows,int(aligned["t"][0]),int(aligned["t"][-1]+aligned["dt"][-1]*1e9)) if windows else []
                record[endpoint]=aligned;record[f"{endpoint}_spans"]=spans
                for phase,kinds in (("active",{"active"}),("gap",{"gap"}),("startup",{"startup"}),("pre",{"pre"}),("post",{"post"}),("tail",{"tail"})):
                    record[f"{endpoint}_{phase}"]=integrate_msr(aligned,spans,kinds) if spans else {}
            for endpoint,bundle in (("client",client),("server",server)):
                freq=read_frequency(bundle.get("frequency"));bridge=freq.get("bridge") if freq else None;cstate=read_cstate(bundle.get("cstate"),bridge,windows)
                if bundle.get("cstate") and bridge is None:warn("cstate_clock_bridge_missing","C-state data exists but no MONOTONIC_RAW↔MONOTONIC bridge was recorded; whole-trace C-state remains available, phase C-state is omitted",f"{endpoint} rep{rep:02d} {mode}")
                elif bundle.get("cstate") is None:warn("missing_cstate_csv","C-state CSV is unavailable",f"{endpoint} rep{rep:02d} {mode}")
                record[f"{endpoint}_cstate"]=cstate;record[f"{endpoint}_frequency"]=freq;record[f"{endpoint}_counters"]=read_counters(bundle.get("counters"));record[f"{endpoint}_dpdk_config"]=read_config(bundle.get("dpdk_config"));record[f"{endpoint}_powermng_config"]=read_config(bundle.get("powermng_config"));record[f"{endpoint}_acpi"]=read_acpi(bundle.get("power_json"))
            output[(rep,mode)]=record
    return output


def phase_metric(records,endpoint,phase,key):return [mean_value([row.get(f"{endpoint}_{phase}",{}).get(key) for (rep,mode),row in records.items() if mode==wanted]) for wanted in MODES]
def counter_metric(records,endpoint,key,mode_filter=None):
    out=[]
    for wanted in MODES:
        if mode_filter and wanted!=mode_filter:out.append(0.0);continue
        out.append(mean_value([row.get(f"{endpoint}_counters",{}).get(key) for (rep,mode),row in records.items() if mode==wanted]))
    return out
def frequency_metric(records,endpoint,key):return [mean_value([row.get(f"{endpoint}_frequency",{}).get(key) for (rep,mode),row in records.items() if mode==wanted and row.get(f"{endpoint}_frequency")]) for wanted in MODES]
def cstate_metric(records,endpoint,key):return [mean_value([row.get(f"{endpoint}_cstate",{}).get(key) for (rep,mode),row in records.items() if mode==wanted and row.get(f"{endpoint}_cstate")]) for wanted in MODES]
def cstate_state_metric(records,endpoint,phase,state):
    key={"whole":"whole_by_state_s","active":"active_by_state_s","gap":"gap_by_state_s"}[phase]
    return [mean_value([row.get(f"{endpoint}_cstate",{}).get(key,{}).get(state) for (rep,mode),row in records.items() if mode==wanted and row.get(f"{endpoint}_cstate")]) for wanted in MODES]
def dpdk_packets(tables,endpoint,direction):
    indexed=mode_rows(tables["client_avg"] if endpoint=="client" else tables["server_avg"]);out=[]
    for mode in MODES:
        value=None
        for parts in (("dpdk",direction,"packets"),(direction,"packets"),("packet",direction)):
            value=field(indexed.get(mode),*parts)
            if value is not None:break
        out.append(value)
    return out


def ax_style(ax,title,ylabel=""):
    ax.set_title(title,fontsize=18,pad=18,fontweight="normal");ax.set_ylabel(ylabel,fontsize=13);ax.tick_params(axis="x",labelsize=11);ax.tick_params(axis="y",labelsize=10.5);ax.grid(axis="y",alpha=.30);ax.set_axisbelow(True)
    for spine in ax.spines.values():spine.set_linewidth(.8)
def save_chart(fig,output,index,name):
    for ext in ("svg","pdf"):
        for variant in ("with_values","without_values"):
            folder=output/ext/variant;folder.mkdir(parents=True,exist_ok=True);fig.savefig(folder/f"{index:02d}_{name}.{ext}",bbox_inches="tight",dpi=300)
    plt.close(fig)
def warning_chart(output,index,name,title,reason):
    WARNING_CHARTS.add(index);warn("chart_warning",reason,f"chart {index} {title}");fig,ax=plt.subplots(figsize=(14,7));ax_style(ax,title);ax.text(.5,.55,"Warning: data unavailable",ha="center",va="center",transform=ax.transAxes,fontsize=16);ax.text(.5,.43,reason,ha="center",va="center",transform=ax.transAxes,fontsize=11,wrap=True);ax.set_xticks([]);ax.set_yticks([]);save_chart(fig,output,index,name)
def bar_chart(output,index,name,title,ylabel,series,reason="The required metric was not recorded for this matrix."):
    if not series or not any(any(v is not None for v in values) for values in series.values()):warning_chart(output,index,name,title,reason);return
    fig,ax=plt.subplots(figsize=(15,8));x=np.arange(3);width=min(.72/max(1,len(series)),.24)
    for pos,(label,values) in enumerate(series.items()):
        y=[np.nan if v is None else v for v in values];bars=ax.bar(x+(pos-(len(series)-1)/2)*width,y,width,label=label)
        for bar,v in zip(bars,values):
            if v is not None:ax.annotate(f"{v:.2f}",(bar.get_x()+bar.get_width()/2,bar.get_height()),xytext=(0,8),textcoords="offset points",ha="center",rotation=90,fontsize=8)
    ax.set_xticks(x,[MODE_NAMES[m] for m in MODES]);ax.set_ylim(bottom=0);ax_style(ax,title,ylabel)
    if len(series)>1:ax.legend(loc="center left",bbox_to_anchor=(1.01,.5))
    save_chart(fig,output,index,name)
def phase_bar(records,endpoint,phase,key):return phase_metric(records,endpoint,phase,key)
def shade_phases(ax,spans,zero):
    for kind,index,start,end in spans:
        x0=(start-zero)/1e9;x1=(end-zero)/1e9;ax.axvspan(x0,x1,color=PHASE_COLORS[kind],alpha=.16,linewidth=0,zorder=0);template,size=PHASE_LABELS[kind];label=template.format(index=index) if index is not None else template;ax.text((x0+x1)/2,.5,label,transform=ax.get_xaxis_transform(),ha="center",va="center",fontsize=size,color="#555",alpha=.16,zorder=1)
def phase_smooth(x,y,spans,zero):
    result=np.asarray(y,float).copy();step=np.median(np.diff(x)) if len(x)>1 else .006;count=max(1,int(round(.504/max(step,1e-6))))
    for _,_,start,end in spans:
        indexes=np.where((x>=(start-zero)/1e9)&(x<=(end-zero)/1e9))[0]
        if len(indexes):
            source=y[indexes];k=min(count,len(source));kernel=np.ones(k);result[indexes]=np.convolve(source,kernel,mode="same")/np.maximum(np.convolve(np.ones_like(source),kernel,mode="same"),1.0)
    return result
def endpoint_trace(record,endpoint):
    windows=record.get("windows") or []
    if not windows:return None
    zero=windows[0][0]
    if endpoint.lower() in {"server","client"}:
        trace=record.get(endpoint.lower());spans=record.get(f"{endpoint.lower()}_spans")
        if trace is None or not spans:return None
        return (trace["t"]-zero)/1e9,trace["p"],spans,zero
    client=record.get("client");server=record.get("server");spans=record.get("client_spans") or record.get("server_spans")
    if client is None or server is None or not spans:return None
    x=(client["t"]-zero)/1e9;server_x=(server["t"]-zero)/1e9;server_power=np.interp(x,server_x,server["p"],left=np.nan,right=np.nan);return x,client["p"]+server_power,spans,zero
def mode_panels(output,index,name,title,endpoint,records,kind):
    fig,axes=plt.subplots(3,1,figsize=(16,11),sharey=True);found=False
    for ax,mode in zip(axes,MODES):
        reps=sorted(rep for rep,candidate in records if candidate==mode);record=records.get((reps[0],mode)) if reps else None;trace=endpoint_trace(record,endpoint) if record else None
        if trace is None:ax_style(ax,MODE_NAMES[mode]);ax.text(.5,.5,"Warning: trace unavailable",transform=ax.transAxes,ha="center",va="center");continue
        found=True;x,power,spans,zero=trace
        if kind=="energy":
            y=np.zeros_like(power,float);valid=np.nan_to_num(power,nan=0.0)
            if len(x)>1:y[1:]=np.cumsum((valid[1:]+valid[:-1])*.5*np.diff(x))
            ylabel="Cumulative energy (J)"
        else:y=phase_smooth(x,power,spans,zero) if kind=="smooth" else power;ylabel="Power (W)"
        shade_phases(ax,spans,zero);ax.plot(x,y,color=MODE_COLORS[mode],linewidth=1.25,zorder=3);ax.set_xlim(float(np.nanmin(x))-.75,float(np.nanmax(x))+2);ax_style(ax,MODE_NAMES[mode],ylabel)
    fig.suptitle(title,fontsize=19,fontweight="normal");axes[-1].set_xlabel("Time relative to Download 1 start (s)")
    if not found:plt.close(fig);warning_chart(output,index,name,title,"No raw RAPL time series with request phase markers was recorded.");return
    fig.tight_layout(rect=(0,0,.97,.96));save_chart(fig,output,index,name)
def endpoint_overlay(output,index,name,title,mode,records,smooth):
    reps=sorted(rep for rep,candidate in records if candidate==mode);record=records.get((reps[0],mode)) if reps else None
    if not record:warning_chart(output,index,name,title,"No representative run was recorded for this mode.");return
    fig,ax=plt.subplots(figsize=(16,8));zero=record.get("windows",[(0,0)])[0][0];spans=record.get("client_spans") or record.get("server_spans")
    if spans:shade_phases(ax,spans,zero)
    found=False
    for endpoint in ("Server","Client","Combined"):
        trace=endpoint_trace(record,endpoint)
        if trace is None:continue
        x,y,local_spans,local_zero=trace
        if smooth:y=phase_smooth(x,y,local_spans,local_zero)
        ax.plot(x,y,label=endpoint,color=ENDPOINT_COLORS[endpoint],linewidth=1.25,zorder=3);found=True
    if not found:plt.close(fig);warning_chart(output,index,name,title,"No endpoint RAPL traces were recorded for this mode.");return
    ax_style(ax,title,"Power (W)");ax.set_xlabel("Time relative to Download 1 start (s)");ax.legend(loc="center left",bbox_to_anchor=(1.01,.5));save_chart(fig,output,index,name)
def text_chart(output,index,name,title,lines,warning_reason=None):
    if not lines:warning_chart(output,index,name,title,warning_reason or "No status/configuration data was recorded.");return
    fig,ax=plt.subplots(figsize=(16,9));ax.axis("off");ax.set_title(title,fontsize=18,pad=18,fontweight="normal");ax.text(.03,.95,"\n".join(lines),transform=ax.transAxes,ha="left",va="top",fontsize=11,family="monospace");save_chart(fig,output,index,name)


def generate_charts(output,tables,records):
    combined=tables["combined_avg"]
    bar_chart(output,1,"file_size_and_payload","File size and total useful payload","GiB",{"Payload":values3(combined,"payload_gib")});bar_chart(output,2,"download_and_gap_counts","Downloads and configured gaps","Count",{"Downloads":[5.]*3,"Gaps":[4.]*3});bar_chart(output,3,"gap_duration","Configured gap duration","Seconds",{"Gap total":[20.]*3});bar_chart(output,4,"active_goodput","Active goodput","Gbit/s",{"Goodput":values3(combined,"goodput","excluding","gaps")});bar_chart(output,5,"gap_inclusive_goodput","Gap-inclusive goodput","Gbit/s",{"Goodput":values3(combined,"goodput","including","gaps")})
    bar_chart(output,6,"duration_breakdown","Transfer, gap-window, and aligned duration","Seconds",{"Workload":values3(combined,"workload_duration_s"),"Client aligned":values3(combined,"client_aligned_duration_s"),"Server aligned":values3(combined,"server_aligned_duration_s")});bar_chart(output,7,"average_rapl_power","Average RAPL power","Power (W)",{"Server":values3(combined,"server_average_power_w"),"Client":values3(combined,"client_average_power_w"),"Combined":values3(combined,"combined_average_power_w")});bar_chart(output,8,"rapl_energy","RAPL energy","Energy (J)",{"Server":values3(combined,"server_rapl_energy_j"),"Client":values3(combined,"client_rapl_energy_j"),"Combined":values3(combined,"combined_rapl_energy_j")});bar_chart(output,9,"energy_efficiency","Energy efficiency","J/GiB",{"Server":values3(combined,"server_rapl_j_per_gib"),"Client":values3(combined,"client_rapl_j_per_gib"),"Combined":values3(combined,"combined_rapl_j_per_gib")})
    bar_chart(output,10,"server_whole_cstate","Server whole-trace C-state residency","Seconds",{f"state{s}":cstate_state_metric(records,"server","whole",s) for s in range(4)});bar_chart(output,11,"client_whole_cstate","Client whole-trace C-state residency","Seconds",{f"state{s}":cstate_state_metric(records,"client","whole",s) for s in range(4)});bar_chart(output,12,"whole_idle_and_trace_duration","Whole-trace idle time and raw trace duration","Seconds",{"Server idle":cstate_metric(records,"server","whole_idle_s"),"Server trace":cstate_metric(records,"server","trace_duration_s"),"Client idle":cstate_metric(records,"client","whole_idle_s"),"Client trace":cstate_metric(records,"client","trace_duration_s")});bar_chart(output,13,"aligned_idle_fraction","Idle fraction of aligned workload time","Percent",{"Server":cstate_metric(records,"server","aligned_idle_fraction_pct"),"Client":cstate_metric(records,"client","aligned_idle_fraction_pct")},"Phase C-state needs the recorded MONOTONIC_RAW↔MONOTONIC bridge; the run is preserved and a warning is emitted if it is missing.")
    bar_chart(output,14,"server_active_transfer_cstate","Server active-transfer C-state residency","Seconds",{f"state{s}":cstate_state_metric(records,"server","active",s) for s in range(4)});bar_chart(output,15,"client_active_transfer_cstate","Client active-transfer C-state residency","Seconds",{f"state{s}":cstate_state_metric(records,"client","active",s) for s in range(4)});bar_chart(output,16,"active_transfer_total_idle","Active-transfer total idle time","Seconds",{"Server":cstate_metric(records,"server","active_idle_s"),"Client":cstate_metric(records,"client","active_idle_s")});bar_chart(output,17,"active_transfer_idle_fraction","Active-transfer idle fraction","Percent",{"Server":cstate_metric(records,"server","active_idle_fraction_pct"),"Client":cstate_metric(records,"client","active_idle_fraction_pct")});bar_chart(output,18,"active_transfer_idle_intervals","Active-transfer idle intervals","Count",{"Server":cstate_metric(records,"server","active_intervals"),"Client":cstate_metric(records,"client","active_intervals")});bar_chart(output,19,"server_gap_cstate","Server gap C-state residency","Seconds",{f"state{s}":cstate_state_metric(records,"server","gap",s) for s in range(4)});bar_chart(output,20,"client_gap_cstate","Client gap C-state residency","Seconds",{f"state{s}":cstate_state_metric(records,"client","gap",s) for s in range(4)});bar_chart(output,21,"gap_total_idle","Gap total idle time","Seconds",{"Server":cstate_metric(records,"server","gap_idle_s"),"Client":cstate_metric(records,"client","gap_idle_s")});bar_chart(output,22,"gap_idle_fraction","Gap idle fraction","Percent",{"Server":cstate_metric(records,"server","gap_idle_fraction_pct"),"Client":cstate_metric(records,"client","gap_idle_fraction_pct")});bar_chart(output,23,"gap_idle_intervals","Gap idle intervals","Count",{"Server":cstate_metric(records,"server","gap_intervals"),"Client":cstate_metric(records,"client","gap_intervals")});bar_chart(output,24,"linux_idle_entries","Linux idle entries","Count",{"Server":cstate_metric(records,"server","linux_idle_entries"),"Client":cstate_metric(records,"client","linux_idle_entries")})
    bar_chart(output,25,"server_epoll_attempts_wakes_timeouts","Server EPOLL attempts / wakeups / timeouts","Count",{"Attempts":counter_metric(records,"server","epoll_try"),"Wakeups":counter_metric(records,"server","epoll_wake"),"Timeouts":counter_metric(records,"server","epoll_timeout")});bar_chart(output,26,"server_epoll_wake_sources","Server EPOLL wake sources","Count",{"RX":counter_metric(records,"server","epoll_rx_wake"),"Software/control":counter_metric(records,"server","epoll_control_wake"),"Signal":counter_metric(records,"server","epoll_signal_wake")});bar_chart(output,27,"client_epoll_attempts_wakes_timeouts","Client EPOLL attempts / wakeups / timeouts","Count",{"Attempts":counter_metric(records,"client","epoll_try"),"Wakeups":counter_metric(records,"client","epoll_wake"),"Timeouts":counter_metric(records,"client","epoll_timeout")});bar_chart(output,28,"client_epoll_wake_sources","Client EPOLL wake sources","Count",{"RX":counter_metric(records,"client","epoll_rx_wake"),"Software/control":counter_metric(records,"client","epoll_control_wake"),"Signal":counter_metric(records,"client","epoll_signal_wake")});bar_chart(output,29,"server_frequency_range","Server observed frequency min–max","GHz",{"Min":frequency_metric(records,"server","min_ghz"),"Max":frequency_metric(records,"server","max_ghz")});bar_chart(output,30,"client_frequency_range","Client observed frequency min–max","GHz",{"Min":frequency_metric(records,"client","min_ghz"),"Max":frequency_metric(records,"client","max_ghz")})
    policy={"max_hard":"freq_policy_max_hard","max_control":"freq_policy_max_control","up":"freq_policy_up","down":"freq_policy_down","min":"freq_policy_min","off_fixed_max":"freq_policy_off_fixed_max"};changed={"changed_max":"freq_changed_max","changed_up":"freq_changed_up","changed_down":"freq_changed_down","changed_min":"freq_changed_min"}
    bar_chart(output,31,"server_frequency_policy_actions","Server frequency-policy actions","Count",{label:counter_metric(records,"server",key) for label,key in policy.items()});bar_chart(output,32,"server_actual_frequency_changes","Server actual frequency changes","Count",{label:counter_metric(records,"server",key) for label,key in changed.items()});bar_chart(output,33,"client_frequency_policy_actions","Client frequency-policy actions","Count",{label:counter_metric(records,"client",key) for label,key in policy.items()});bar_chart(output,34,"client_actual_frequency_changes","Client actual frequency changes","Count",{label:counter_metric(records,"client",key) for label,key in changed.items()})
    server_total=[];client_total=[]
    for j,_ in enumerate(MODES):
        sv=[counter_metric(records,"server",key)[j] for key in policy.values()];cv=[counter_metric(records,"client",key)[j] for key in policy.values()];server_total.append(sum(v or 0 for v in sv) if any(v is not None for v in sv) else None);client_total.append(sum(v or 0 for v in cv) if any(v is not None for v in cv) else None)
    bar_chart(output,35,"total_frequency_policy_actions","Total frequency-policy actions","Count",{"Server":server_total,"Client":client_total});bar_chart(output,36,"timestamped_frequency_events","Timestamped frequency events","Count",{"Server":frequency_metric(records,"server","sample_events"),"Client":frequency_metric(records,"client","sample_events")})
    def plus(endpoint,key):return counter_metric(records,endpoint,key,"plus")[2]
    bar_chart(output,37,"plus_ack_pending_and_ramping","PLUS ACK_PENDING and CUBIC ramping","Mean count per run",{"Client ACK_PENDING":[0,0,plus("client","hint_ack_pending")],"Server ACK_PENDING":[0,0,plus("server","hint_ack_pending")],"Client CUBIC ramping":[0,0,plus("client","hint_cubic_ramping")],"Server CUBIC ramping":[0,0,plus("server","hint_cubic_ramping")]});bar_chart(output,38,"plus_cwnd_blocked_recovery","PLUS CWND blocked / recovery","Mean count per run",{"CWND blocked":[0,0,plus("client","hint_cubic_cwnd_blocked")],"Recovery":[0,0,plus("client","hint_cubic_recovery")]});runs_with=sum(1 for (rep,mode),row in records.items() if mode=="plus" and (finite(row.get("client_counters",{}).get("hint_cubic_recovery")) or 0)>0);bar_chart(output,39,"plus_client_recovery_detail","PLUS client CUBIC recovery detail","Count / mean per run",{"Recovery begin mean":[0,0,plus("client","hint_cubic_recovery")],"Recovery end mean":[0,0,plus("client","hint_cubic_recovery_end")],"Runs containing recovery":[0,0,float(runs_with)]});bar_chart(output,40,"transfer_begin_end_hints","PLUS transfer begin/end hints","Mean count per run",{"Client FILE_RX begin":[0,0,plus("client","hint_client_file_rx_active")],"Client FILE_RX end":[0,0,plus("client","hint_client_file_rx_end")],"Server FILE_TX begin":[0,0,plus("server","hint_server_file_tx_active")],"Server FILE_TX end":[0,0,plus("server","hint_server_file_tx_end")]});bar_chart(output,41,"dpdk_packet_counts","DPDK packet counts","Mean packet count per repetition",{"Client RX":dpdk_packets(tables,"client","rx"),"Client TX":dpdk_packets(tables,"client","tx"),"Server RX":dpdk_packets(tables,"server","rx"),"Server TX":dpdk_packets(tables,"server","tx")})
    acpi=[]
    for mode in MODES:
        for endpoint in ("server","client"):
            rows=[row.get(f"{endpoint}_acpi") for (rep,candidate),row in records.items() if candidate==mode and row.get(f"{endpoint}_acpi")];acpi.append(f"{MODE_NAMES[mode]:12s} {endpoint:6s}: "+("unavailable / not recorded" if not rows else "power trace recorded"))
    text_chart(output,42,"acpi_channel_status","ACPI server/client power channel",acpi);configs=[]
    for mode in MODES:
        rows=[row for (rep,candidate),row in records.items() if candidate==mode]
        if rows:
            for endpoint in ("server","client"):
                cfg=rows[0].get(f"{endpoint}_powermng_config",{});configs.append(f"{MODE_NAMES[mode]:12s} {endpoint:6s}: idle={cfg.get('GreenQuicIdleMode','?')}, freq={cfg.get('GreenQuicEnableFreq','?')}, sleep={cfg.get('GreenQuicEnableSleep','?')}")
    text_chart(output,43,"configuration_scientific_overview","Current test configuration and scientific overview",["Current matrix scientific/configuration overview","","Modes: MsQuic-DPDK / GreenQUIC / GreenQUIC+",f"Discovered mode/repetition records: {len(records)}","Phase RAPL: native package+DRAM deltas clipped by exact D1..D5 and Gap1..Gap4 windows.","Phase C-state: cpu_idle MONOTONIC_RAW intervals converted through recorded clock bridge to MONOTONIC.","Warnings never abort report generation; see validation_report.json.",""]+configs)
    for index,title,phase,key,ylabel in ((44,"Active-transfer RAPL power","active","power_w","Power (W)"),(45,"Inter-download gap RAPL power","gap","power_w","Power (W)"),(46,"Active-transfer RAPL energy","active","energy_j","Energy (J)"),(47,"Inter-download gap RAPL energy","gap","energy_j","Energy (J)")):
        server=phase_bar(records,"server",phase,key);client=phase_bar(records,"client",phase,key);bar_chart(output,index,normalized(title),title,ylabel,{"Server":server,"Client":client,"Combined":[a+b if a is not None and b is not None else None for a,b in zip(server,client)]})
    index=48
    for endpoint in ("Server","Client","Combined"):
        for kind,suffix,label in (("raw","power_raw","RAPL power over time"),("smooth","power_smoothed","phase-aware smoothed RAPL power"),("energy","cumulative_energy","cumulative RAPL energy")):
            mode_panels(output,index,f"{endpoint.lower()}_{suffix}",f"Current test — {endpoint} {label}",endpoint,records,kind);index+=1
    for mode in MODES:
        endpoint_overlay(output,index,f"{mode}_endpoints_power_raw",f"Current test — {MODE_NAMES[mode]} — Server / Client / Combined RAPL power",mode,records,False);index+=1;endpoint_overlay(output,index,f"{mode}_endpoints_power_smoothed",f"Current test — {MODE_NAMES[mode]} — Server / Client / Combined phase-aware smoothed RAPL power",mode,records,True);index+=1
    if index-1!=EXPECTED_CHARTS:warn("chart_count_internal",f"Internal chart numbering ended at {index-1}, expected {EXPECTED_CHARTS}")


def xlcol(index):
    text=""
    while index:index,remainder=divmod(index-1,26);text=chr(65+remainder)+text
    return text
def sheet_xml(rows):
    output=['<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>']
    for r,row in enumerate(rows,1):
        output.append(f'<row r="{r}">')
        for c,value in enumerate(row,1):
            if value is None:continue
            ref=f"{xlcol(c)}{r}";output.append(f'<c r="{ref}"><v>{value}</v></c>' if isinstance(value,(int,float)) and math.isfinite(float(value)) else f'<c r="{ref}" t="inlineStr"><is><t>{escape(str(value))}</t></is></c>')
        output.append('</row>')
    return ''.join(output)+'</sheetData></worksheet>'
def write_xlsx(path,sheets):
    names=[re.sub(r'[\\/*?:\[\]]','_',name)[:31] for name,_ in sheets]
    with zipfile.ZipFile(path,'w',zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('[Content_Types].xml','<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'+''.join(f'<Override PartName="/xl/worksheets/sheet{i}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' for i in range(1,len(sheets)+1))+'</Types>');archive.writestr('_rels/.rels','<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>');archive.writestr('xl/workbook.xml','<?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>'+''.join(f'<sheet name="{escape(name)}" sheetId="{i}" r:id="rId{i}"/>' for i,name in enumerate(names,1))+'</sheets></workbook>');archive.writestr('xl/_rels/workbook.xml.rels','<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/relationships">'+''.join(f'<Relationship Id="rId{i}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet{i}.xml"/>' for i in range(1,len(sheets)+1))+'</Relationships>')
        for i,(_,rows) in enumerate(sheets,1):archive.writestr(f'xl/worksheets/sheet{i}.xml',sheet_xml(rows))
def rows_for_sheet(rows):
    if not rows:return [["No rows available"]]
    columns=[]
    for row in rows:
        for key in row:
            if key not in columns:columns.append(key)
    return [columns]+[[row.get(key,"") for key in columns] for row in rows]
def phase_rapl_rows(records):
    rows=[]
    for (rep,mode),record in sorted(records.items()):
        for endpoint in ("server","client"):
            for phase in ("startup","pre","active","gap","post","tail"):
                metric=record.get(f"{endpoint}_{phase}")
                if metric:rows.append({"repetition":rep,"mode":mode,"endpoint":endpoint,"phase":phase,**metric,"server_offset_to_client_ns":record.get("server_shift_ns",0)})
    return rows
def phase_cstate_rows(records):
    rows=[]
    for (rep,mode),record in sorted(records.items()):
        for endpoint in ("server","client"):
            c=record.get(f"{endpoint}_cstate") or {}
            if not c:continue
            row={"repetition":rep,"mode":mode,"endpoint":endpoint,"clock_method":c.get("clock_method"),"clock_uncertainty_ns":c.get("clock_uncertainty_ns"),"whole_idle_s":c.get("whole_idle_s"),"trace_duration_s":c.get("trace_duration_s"),"aligned_idle_s":c.get("aligned_idle_s"),"aligned_idle_fraction_pct":c.get("aligned_idle_fraction_pct"),"active_idle_s":c.get("active_idle_s"),"active_idle_fraction_pct":c.get("active_idle_fraction_pct"),"active_intervals":c.get("active_intervals"),"gap_idle_s":c.get("gap_idle_s"),"gap_idle_fraction_pct":c.get("gap_idle_fraction_pct"),"gap_intervals":c.get("gap_intervals"),"linux_idle_entries":c.get("linux_idle_entries")}
            for phase,key in (("whole","whole_by_state_s"),("active","active_by_state_s"),("gap","gap_by_state_s")):
                for state,value in (c.get(key) or {}).items():row[f"{phase}_state{state}_s"]=value
            rows.append(row)
    return rows
def simple_rows(records,key):
    rows=[]
    for (rep,mode),record in sorted(records.items()):
        for endpoint in ("server","client"):
            value=record.get(f"{endpoint}_{key}") or {}
            if value:
                if key=="frequency":
                    bridge=value.get("bridge");rows.append({"repetition":rep,"mode":mode,"endpoint":endpoint,"min_ghz":value.get("min_ghz"),"max_ghz":value.get("max_ghz"),"sample_events":value.get("sample_events"),"changed_samples":value.get("changed_samples"),"clock_bridge_method":bridge.method if bridge else "none","clock_bridge_start_uncertainty_ns":bridge.start_uncertainty_ns if bridge else None,"clock_bridge_end_uncertainty_ns":bridge.end_uncertainty_ns if bridge else None})
                else:rows.append({"repetition":rep,"mode":mode,"endpoint":endpoint,**value})
    return rows
def configuration_rows(records):
    rows=[]
    for (rep,mode),record in sorted(records.items()):
        for endpoint in ("server","client"):
            dpdk=record.get(f"{endpoint}_dpdk_config") or {};power=record.get(f"{endpoint}_powermng_config") or {}
            if dpdk or power:
                row={"repetition":rep,"mode":mode,"endpoint":endpoint};row.update({f"dpdk.{k}":v for k,v in dpdk.items()});row.update({f"power.{k}":v for k,v in power.items()});rows.append(row)
    return rows
def full_comparison(tables,records):
    indexed=mode_rows(tables["combined_avg"]);out=[["Metric","Value order / fields","MsQuic-DPDK","GreenQUIC","GreenQUIC+","Source / scope"]];keys=[]
    for row in tables["combined_avg"]:
        for key in row:
            if key!="mode" and key not in keys:keys.append(key)
    for key in keys:out.append([key,"OFF / BASIC / PLUS",indexed.get("off",{}).get(key,""),indexed.get("basic",{}).get(key,""),indexed.get("plus",{}).get(key,""),"combined_endpoint_mode_averages.csv"])
    for phase in ("startup","pre","active","gap","post","tail"):
        for endpoint in ("server","client"):
            for key in ("power_w","energy_j","duration_s"):out.append([f"{endpoint} {phase} {key}","OFF / BASIC / PLUS",*phase_metric(records,endpoint,phase,key),"native MSR RAPL + exact client request windows"])
    for endpoint in ("server","client"):
        for phase in ("active","gap"):
            for state in range(4):out.append([f"{endpoint} {phase} state{state} residency_s","OFF / BASIC / PLUS",*cstate_state_metric(records,endpoint,phase,state),"raw cpu_idle intervals aligned through MONOTONIC↔MONOTONIC_RAW bridge"])
    return out
def write_csv_rows(path,rows):
    path.parent.mkdir(parents=True,exist_ok=True)
    if not rows:path.write_text("warning\nno rows available\n",encoding="utf-8");return
    columns=[]
    for row in rows:
        for key in row:
            if key not in columns:columns.append(key)
    with path.open("w",newline="",encoding="utf-8") as handle:writer=csv.DictWriter(handle,fieldnames=columns);writer.writeheader();writer.writerows(rows)


def main():
    parser=argparse.ArgumentParser(description="Generate the complete the_sheet_rules_all report for one P4/P5 matrix.");parser.add_argument("--input",type=Path,required=True);parser.add_argument("--output",type=Path);parser.add_argument("--expected-charts",type=int,default=EXPECTED_CHARTS);args=parser.parse_args();root=args.input.resolve();output=(args.output or root/"the_sheet_rules_all").resolve();output.mkdir(parents=True,exist_ok=True)
    if not root.exists():warn("input_missing","Input matrix directory does not exist",str(root))
    tables=load_tables(root);records=raw_data(root)
    if not records:warn("no_run_bundles","No run bundles were discovered; charts will carry explicit warnings",str(root))
    data=output/"data";data.mkdir(parents=True,exist_ok=True);rapl=phase_rapl_rows(records);cstate=phase_cstate_rows(records);counters=simple_rows(records,"counters");frequencies=simple_rows(records,"frequency");configs=configuration_rows(records);write_csv_rows(data/"phase_rapl_all_runs.csv",rapl);write_csv_rows(data/"phase_cstate_all_runs.csv",cstate);write_csv_rows(data/"greenquic_counters_all_runs.csv",counters);write_csv_rows(data/"frequency_all_runs.csv",frequencies);write_csv_rows(data/"effective_configuration_all_runs.csv",configs);generate_charts(output/"charts",tables,records)
    svgs=sorted((output/"charts/svg/with_values").glob("*.svg"));pdfs=sorted((output/"charts/pdf/with_values").glob("*.pdf"))
    if len(svgs)!=args.expected_charts or len(pdfs)!=args.expected_charts:warn("chart_count",f"Generated SVG/PDF counts are {len(svgs)}/{len(pdfs)}, expected {args.expected_charts}")
    warning_rows=WARNINGS or [{"code":"none","message":"No reporter warnings","context":""}];xlsx_path=output/"GreenQUIC_full_results.xlsx";write_xlsx(xlsx_path,[("Full comparison",full_comparison(tables,records)),("Combined averages",rows_for_sheet(tables["combined_avg"])),("Client all runs",rows_for_sheet(tables["client_runs"])),("Server all runs",rows_for_sheet(tables["server_runs"])),("Power management",rows_for_sheet(tables["behavior"])),("Phase RAPL per-run",rows_for_sheet(rapl)),("Phase C-state per-run",rows_for_sheet(cstate)),("GreenQUIC counters",rows_for_sheet(counters)),("Frequency per-run",rows_for_sheet(frequencies)),("Configuration",rows_for_sheet(configs)),("Validation warnings",rows_for_sheet(warning_rows)),("Chart manifest",[["Expected logical charts",args.expected_charts],["Generated SVG charts",len(svgs)],["Generated PDF charts",len(pdfs)],["Warning charts",len(WARNING_CHARTS)]])]);report={"matrix":str(root),"run_pairs_discovered":len(records),"logical_charts_expected":args.expected_charts,"logical_charts_generated_svg":len(svgs),"logical_charts_generated_pdf":len(pdfs),"warning_chart_count":len(WARNING_CHARTS),"warning_charts":sorted(WARNING_CHARTS),"warning_count":len(WARNINGS),"warnings":WARNINGS,"xlsx":str(xlsx_path)};(output/"validation_report.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8");print(json.dumps(report,indent=2));return 0
if __name__=="__main__":raise SystemExit(main())
