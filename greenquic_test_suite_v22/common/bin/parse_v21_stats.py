#!/usr/bin/env python3
"""Extract final V21 GreenQUIC diagnostic lines to CSV."""
from __future__ import annotations
import argparse, csv, re
from pathlib import Path
FIELDS = [
"lcore","owns_rx","owns_tx","mode","profile","action","hardmax","rxhard","txhard","control",
"rxctrl","txctrl","rxphysctrl","txphysctrl","rxburstp","rxqueuep","txburstp","txringp",
"rxbursta","rxqueuea","txbursta","txringa","rxfloor","txfloor","rxh","txh","txring","rxq",
"rx_pkts","tx_pkts","rx_empty","tx_empty","rx_full","tx_full","slept_us",
"cstate_attempt","cstate_ok","cstate_req_last_us","cstate_req_total_us","cstate_actual_last_us","cstate_actual_total_us",
"idle_mode","monitor_try","monitor_wake","monitor_timeout","epoll_try","epoll_wake","epoll_timeout","wake_signal"]
def main():
    ap=argparse.ArgumentParser(); ap.add_argument('log',type=Path); ap.add_argument('--out',type=Path,required=True); args=ap.parse_args()
    rows=[]
    for no,line in enumerate(args.log.read_text(errors='replace').splitlines(),1):
        # GREENQUIC-V22-TRUNCATED-STATS-GUARD
        if not (line.startswith('GreenQUIC lcore=') or re.match(r'^\[CPU \d+\] GreenQUIC lcore=',line)) or 'wake_signal=' not in line: continue
        row={'source_line':no}
        for m in re.finditer(r"\b([A-Za-z0-9_]+)=([^\s]+)",line): row[m.group(1)]=m.group(2)
        rows.append(row)
    args.out.parent.mkdir(parents=True,exist_ok=True)
    with args.out.open('w',newline='',encoding='utf-8') as f:
        w=csv.DictWriter(f,fieldnames=['source_line']+FIELDS,extrasaction='ignore'); w.writeheader(); w.writerows(rows)
    print(f"wrote {len(rows)} V21 stats rows to {args.out}")
if __name__=='__main__': main()
