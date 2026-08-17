#!/usr/bin/env python3
"""D1/D2+ P5 report V4: variance-chart presentation variants.

This wrapper leaves all V3 measurement/alignment semantics unchanged and only
replaces the grouped-bar renderer before V3 calls the base report main().

For every grouped bar chart it keeps the legacy outputs and additionally emits:
  with_variance/with_values/{svg,pdf}/...
  with_variance/without_values/{svg,pdf}/...

The with-values variance chart labels each bar with the mean and the numeric
variance (Var = SD^2). Error bars remain one standard deviation, exactly as in
V3. The without-values copy has the same bars/error bars and no text above bars.
"""
from __future__ import annotations

from pathlib import Path

HERE = Path(__file__).resolve().parent
V3 = HERE / "build_d1_d2plus_report_v3.py"

if not V3.is_file():
    raise SystemExit(f"ERROR: missing V3 reporter: {V3}")

src = V3.read_text(encoding="utf-8")
anchor = "mod.read_msr=read_msr\n"
if src.count(anchor) != 1:
    raise SystemExit(
        f"ERROR: expected exactly one P5 V3 renderer patch anchor, found {src.count(anchor)}"
    )

inject = r'''

def _gq_save_grouped_bar_v4(out,index,name,title,ylabel,smap,variance,show_values,folder):
    fig,ax=mod.plt.subplots(figsize=(14,8));x=mod.np.arange(3);w=.34
    plotted=[]
    for j,(grp,label) in enumerate((('d1','D1'),('d2plus','D2+ mean per later download'))):
        means=[smap[(m,grp)]['mean'] for m in mod.MODES]
        ys=[mod.np.nan if v is None else v for v in means]
        err=[0 if smap[(m,grp)]['sd'] is None else smap[(m,grp)]['sd'] for m in mod.MODES]
        bars=ax.bar(
            x+(j-.5)*w,ys,w,label=label,
            yerr=err if variance else None,
            capsize=4 if variance else 0)
        plotted.extend((v,e) for v,e in zip(means,err) if v is not None)
        if show_values:
            for k,(b,v) in enumerate(zip(bars,means)):
                if v is None:
                    continue
                sd=err[k] if variance else 0.0
                y=float(v)+(float(sd) if variance else 0.0)
                if variance:
                    var=float(sd)*float(sd)
                    text=f'{v:.2f}\nVar={var:.3g}'
                else:
                    text=f'{v:.2f}'
                ax.annotate(
                    text,
                    (b.get_x()+b.get_width()/2,y),
                    xytext=(0,5),textcoords='offset points',
                    ha='center',va='bottom',fontsize=8)
    ax.set_xticks(x,[mod.MODE_NAMES[m] for m in mod.MODES]);ax.set_ylabel(ylabel);ax.set_title(title)
    ax.grid(axis='y',alpha=.25);ax.set_axisbelow(True);ax.legend();ax.set_ylim(bottom=0)
    if plotted:
        ymax=max(float(v)+(float(e) if variance else 0.0) for v,e in plotted)
        if ymax<=0:
            ymax=1.0
        headroom=1.30 if show_values else 1.12
        ax.set_ylim(0,ymax*headroom)
    (folder/'svg').mkdir(parents=True,exist_ok=True);(folder/'pdf').mkdir(parents=True,exist_ok=True)
    fig.savefig(folder/'svg'/f'{index:02d}_{name}.svg',bbox_inches='tight')
    fig.savefig(folder/'pdf'/f'{index:02d}_{name}.pdf',bbox_inches='tight')
    mod.plt.close(fig)


def _gq_grouped_bar_v4(out,index,name,title,ylabel,smap,series=None):
    # Preserve the historical no-variance chart exactly as a labeled chart.
    _gq_save_grouped_bar_v4(
        out,index,name,title,ylabel,smap,
        variance=False,show_values=True,
        folder=out/'without_variance')

    # Compatibility path: existing consumers still find with_variance/svg|pdf.
    # It is now the labeled variance chart and includes the numeric variance.
    _gq_save_grouped_bar_v4(
        out,index,name,title,ylabel,smap,
        variance=True,show_values=True,
        folder=out/'with_variance')

    # Explicit paper-selection variants requested for D1/D2+.
    _gq_save_grouped_bar_v4(
        out,index,name,title,ylabel,smap,
        variance=True,show_values=True,
        folder=out/'with_variance'/'with_values')
    _gq_save_grouped_bar_v4(
        out,index,name,title,ylabel,smap,
        variance=True,show_values=False,
        folder=out/'with_variance'/'without_values')


mod.grouped_bar=_gq_grouped_bar_v4
'''

src = src.replace(anchor, inject + "\n" + anchor, 1)
code = compile(src, str(V3), "exec")
exec(code, {"__name__": "__main__", "__file__": str(V3)})
