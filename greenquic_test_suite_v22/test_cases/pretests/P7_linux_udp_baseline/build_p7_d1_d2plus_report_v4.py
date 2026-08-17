#!/usr/bin/env python3
"""D1/D2+ P7 report V4: variance-chart presentation variants.

All V3 measurement/alignment semantics remain unchanged. This wrapper only
replaces the categorical bar renderer before the V3 report runs.

Outputs for every bar chart:
  with_variance/with_values/{svg,pdf}/...
  with_variance/without_values/{svg,pdf}/...

The with-values copy shows mean and numeric variance (Var = SD^2). Error bars
remain one standard deviation, matching V3. The clean copy has no text labels.
"""
from __future__ import annotations

from pathlib import Path

HERE = Path(__file__).resolve().parent
V3 = HERE / "build_p7_d1_d2plus_report_v3.py"

if not V3.is_file():
    raise SystemExit(f"ERROR: missing V3 reporter: {V3}")

src = V3.read_text(encoding="utf-8")
anchor = "mod.read_rapl=read_rapl\n"
if src.count(anchor) != 1:
    raise SystemExit(
        f"ERROR: expected exactly one P7 V3 renderer patch anchor, found {src.count(anchor)}"
    )

inject = r'''

def _gq_save_bar_v4(out,i,name,title,ylabel,S,variance,show_values,folder):
    fig,ax=mod.plt.subplots(figsize=(10,7));x=mod.np.arange(2)
    groups=('d1','d2plus')
    means=[S[g]['mean'] for g in groups]
    ys=[mod.np.nan if v is None else v for v in means]
    err=[S[g]['sd'] or 0 for g in groups]
    bars=ax.bar(x,ys,yerr=err if variance else None,capsize=5 if variance else 0)
    ax.set_xticks(x,['D1','D2+ mean per later download']);ax.set_ylabel(ylabel);ax.set_title(title)
    ax.grid(axis='y',alpha=.25);ax.set_axisbelow(True);ax.set_ylim(bottom=0)
    if show_values:
        for k,(b,v) in enumerate(zip(bars,means)):
            if v is None:
                continue
            sd=float(err[k]) if variance else 0.0
            y=float(v)+(sd if variance else 0.0)
            if variance:
                var=sd*sd
                text=f'{v:.2f}\nVar={var:.3g}'
            else:
                text=f'{v:.2f}'
            ax.annotate(
                text,(b.get_x()+b.get_width()/2,y),
                xytext=(0,5),textcoords='offset points',
                ha='center',va='bottom',fontsize=9)
    plotted=[(float(v),float(e)) for v,e in zip(means,err) if v is not None]
    if plotted:
        ymax=max(v+(e if variance else 0.0) for v,e in plotted)
        if ymax<=0:
            ymax=1.0
        ax.set_ylim(0,ymax*(1.30 if show_values else 1.12))
    (folder/'svg').mkdir(parents=True,exist_ok=True);(folder/'pdf').mkdir(parents=True,exist_ok=True)
    fig.savefig(folder/'svg'/f'{i:02d}_{name}.svg',bbox_inches='tight')
    fig.savefig(folder/'pdf'/f'{i:02d}_{name}.pdf',bbox_inches='tight')
    mod.plt.close(fig)


def _gq_bar_v4(out,i,name,title,ylabel,S):
    _gq_save_bar_v4(
        out,i,name,title,ylabel,S,
        variance=False,show_values=True,
        folder=out/'without_variance')
    _gq_save_bar_v4(
        out,i,name,title,ylabel,S,
        variance=True,show_values=True,
        folder=out/'with_variance')
    _gq_save_bar_v4(
        out,i,name,title,ylabel,S,
        variance=True,show_values=True,
        folder=out/'with_variance'/'with_values')
    _gq_save_bar_v4(
        out,i,name,title,ylabel,S,
        variance=True,show_values=False,
        folder=out/'with_variance'/'without_values')


mod.bar=_gq_bar_v4
'''

src = src.replace(anchor, inject + "\n" + anchor, 1)
code = compile(src, str(V3), "exec")
exec(code, {"__name__": "__main__", "__file__": str(V3)})
