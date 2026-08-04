#!/usr/bin/env python3
"""Validate mode-specific evidence in final V21 GreenQUIC stats."""
from __future__ import annotations
import argparse,re,sys
from pathlib import Path

def rows(path):
    out=[]
    for no,line in enumerate(path.read_text(encoding='utf-8',errors='replace').splitlines(),1):
        if not line.startswith('GreenQUIC lcore='): continue
        values={m.group(1):m.group(2) for m in re.finditer(r"\b([A-Za-z0-9_]+)=([^\s]+)",line)}; values['_line']=str(no); out.append(values)
    return out

def num(row,key):
    try: return int(row.get(key,'0'),0)
    except ValueError: return 0

def split_items(text): return [x.strip() for x in (text or '').split(',') if x.strip()]
def parse_field_specs(text):
    result=[]
    for item in split_items(text):
        key,sep,val=item.partition(':')
        if not sep: raise ValueError(f"field spec must be field:value, got {item!r}")
        result.append((key,int(val,0)))
    return result

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('log',type=Path); ap.add_argument('--idle-mode')
    ap.add_argument('--require-actions',default=''); ap.add_argument('--require-any-actions',default=''); ap.add_argument('--forbid-actions',default='')
    ap.add_argument('--min-fields',default=''); ap.add_argument('--max-fields',default='')
    ap.add_argument('--role-actions',default='',help='comma separated owns_rx:owns_tx:action')
    ap.add_argument('--role-min-fields',default='',help='comma separated owns_rx:owns_tx:field:value')
    ap.add_argument('--require-hints',default='',help='comma separated field:mask')
    ap.add_argument('--forbid-hint-actions',default='',help='semicolon separated field:mask:action-prefixes separated by |')
    args=ap.parse_args(); data=rows(args.log); errors=[]
    if not data: print('ERROR: no V21 stats rows',file=sys.stderr); return 2
    if args.idle_mode:
        bad=[r for r in data if r.get('idle_mode')!=args.idle_mode]
        if bad: errors.append(f"{len(bad)} rows do not report idle_mode={args.idle_mode}")
    actions=[r.get('action','') for r in data]
    for action in split_items(args.require_actions):
        if action not in actions: errors.append(f"required action not observed: {action}")
    any_actions=split_items(args.require_any_actions)
    if any_actions and not any(a in actions for a in any_actions): errors.append(f"none of the required alternative actions was observed: {any_actions}")
    for action in split_items(args.forbid_actions):
        if action in actions: errors.append(f"forbidden action observed: {action}")
    try:
        for key,minimum in parse_field_specs(args.min_fields):
            observed=max((num(r,key) for r in data),default=0)
            if observed<minimum: errors.append(f"max {key}={observed}, required >= {minimum}")
        for key,maximum in parse_field_specs(args.max_fields):
            observed=max((num(r,key) for r in data),default=0)
            if observed>maximum: errors.append(f"max {key}={observed}, required <= {maximum}")
    except ValueError as exc: errors.append(str(exc))
    for item in split_items(args.role_actions):
        parts=item.split(':',2)
        if len(parts)!=3: errors.append(f"invalid role action spec: {item}"); continue
        rx,tx,action=parts
        if not any(r.get('owns_rx')==rx and r.get('owns_tx')==tx and r.get('action')==action for r in data): errors.append(f"role action not observed: owns_rx={rx} owns_tx={tx} action={action}")
    for item in split_items(args.role_min_fields):
        parts=item.split(':',3)
        if len(parts)!=4: errors.append(f"invalid role field spec: {item}"); continue
        rx,tx,key,val=parts; minimum=int(val,0); subset=[r for r in data if r.get('owns_rx')==rx and r.get('owns_tx')==tx]
        observed=max((num(r,key) for r in subset),default=0)
        if observed<minimum: errors.append(f"role {rx}/{tx} max {key}={observed}, required >= {minimum}")
    for item in split_items(args.require_hints):
        field,sep,mask=item.partition(':')
        if not sep: errors.append(f"invalid hint spec: {item}"); continue
        m=int(mask,0)
        if not any(num(r,field)&m for r in data): errors.append(f"hint {field}&{mask} was never observed")
    if args.forbid_hint_actions:
        for item in [x.strip() for x in args.forbid_hint_actions.split(';') if x.strip()]:
            parts=item.split(':',2)
            if len(parts)!=3: errors.append(f"invalid forbid-hint-action spec: {item}"); continue
            field,mask,actions_text=parts; m=int(mask,0); prefixes=actions_text.split('|')
            bad=[r for r in data if (num(r,field)&m) and any(r.get('action','').startswith(p) for p in prefixes)]
            if bad: errors.append(f"{len(bad)} rows used {prefixes} while {field}&{mask} was active")
    summary={key:max((num(r,key) for r in data),default=0) for key in ('slept_us','cstate_attempt','cstate_ok','cstate_req_total_us','cstate_actual_total_us','monitor_try','monitor_wake','monitor_timeout','epoll_try','epoll_wake','epoll_timeout','wake_signal')}
    print('V21 idle evidence: '+ ' '.join(f"{k}={v}" for k,v in summary.items()))
    print('actions='+','.join(sorted(set(actions))))
    for error in errors: print('ERROR: '+error,file=sys.stderr)
    return 2 if errors else 0
if __name__=='__main__': raise SystemExit(main())
