#!/usr/bin/env python3
"""Validate every final V21 GreenQUIC diagnostic-stat line."""
from __future__ import annotations
import argparse,re,sys
from pathlib import Path
REQUIRED={"lcore","owns_rx","owns_tx","mode","profile","action","hardmax","control","rxctrl","txctrl","rxphysctrl","txphysctrl","rxburstp","rxqueuep","txburstp","txringp","rxbursta","rxqueuea","txbursta","txringa","rxfloor","txfloor","rxh","txh","txring","rxq","rx_empty","tx_empty","slept_us","cstate_attempt","cstate_ok","cstate_req_last_us","cstate_req_total_us","cstate_actual_last_us","cstate_actual_total_us","idle_mode","monitor_try","monitor_wake","monitor_timeout","epoll_try","epoll_wake","epoll_timeout","wake_signal"}
NUMERIC=REQUIRED-{"mode","profile","action","idle_mode"}
IDLE={"off","short","pause","monitor","epoll","auto"}
def main():
    ap=argparse.ArgumentParser(); ap.add_argument('log',type=Path); ap.add_argument('--require-all',action='store_true'); ap.add_argument('--expect-idle-mode'); args=ap.parse_args()
    try: raw=args.log.read_text(encoding='utf-8',errors='replace').splitlines()
    except OSError as exc: print(f"ERROR: {exc}",file=sys.stderr); return 2
    lines=[(n,t) for n,t in enumerate(raw,1) if t.startswith('GreenQUIC lcore=')]
    if not lines: print('ERROR: no final V21 GreenQUIC stats lines found',file=sys.stderr); return 2 if args.require_all else 0
    errors=[]; modes=set(); all_keys=set()
    for no,line in lines:
        values={m.group(1):m.group(2) for m in re.finditer(r"\b([A-Za-z0-9_]+)=([^\s]+)",line)}; all_keys.update(values)
        missing=sorted(REQUIRED-set(values))
        if missing: errors.append(f"line {no} missing: {', '.join(missing)}"); continue
        modes.add(values['idle_mode'])
        if values['idle_mode'] not in IDLE: errors.append(f"line {no}: invalid idle_mode={values['idle_mode']}")
        for key in NUMERIC:
            try: int(values[key],0)
            except ValueError: errors.append(f"line {no}: {key} is not numeric: {values[key]!r}")
    if args.expect_idle_mode and modes!={args.expect_idle_mode}: errors.append(f"observed idle modes {sorted(modes)}, expected only {args.expect_idle_mode}")
    print(f"stats_lines={len(lines)}"); print('fields='+','.join(sorted(all_keys))); print('idle_modes='+','.join(sorted(modes)))
    for error in errors[:30]: print('ERROR: '+error,file=sys.stderr)
    if len(errors)>30: print(f"ERROR: {len(errors)-30} additional errors",file=sys.stderr)
    if errors: return 2 if args.require_all else 0
    print('Every final V21 diagnostic line has the required fields.'); return 0
if __name__=='__main__': raise SystemExit(main())
