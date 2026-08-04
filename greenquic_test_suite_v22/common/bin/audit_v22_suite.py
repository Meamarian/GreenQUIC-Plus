#!/usr/bin/env python3
"""Audit every static endpoint configuration with the strict V22 validator."""
from __future__ import annotations
import argparse,importlib.util,sys
from pathlib import Path

def load_validator(path):
    spec=importlib.util.spec_from_file_location('gq_v22_validator',path)
    if spec is None or spec.loader is None: raise RuntimeError(f"cannot load validator: {path}")
    module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module); return module

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--suite-root',type=Path,default=Path(__file__).resolve().parents[2]); args=ap.parse_args()
    root=args.suite_root.resolve(); validator=load_validator(root/'common/bin/validate_v22_config.py'); pairs=[]; errors=[]
    for dpdk in sorted(root.glob('test_cases/**/dpdk.ini')):
        power=dpdk.with_name('powermng.ini'); pairs.append((dpdk,power))
        if not power.is_file(): errors.append(f"missing {power}"); continue
        try: pair_errors,pair_warnings=validator.validate(dpdk,power,allow_device_placeholder=True)
        except Exception as exc: errors.append(f"{dpdk.parent}: validator exception: {exc}"); continue
        errors.extend(f"{dpdk.parent}: {msg}" for msg in pair_errors)
        for warning in pair_warnings: print(f"WARNING: {dpdk.parent}: {warning}",file=sys.stderr)
    if not pairs: errors.append('no endpoint dpdk.ini/powermng.ini pairs found')
    if errors:
        print('\n'.join('ERROR: '+item for item in errors),file=sys.stderr); return 2
    print(f"V22 suite audit passed: {len(pairs)} strictly validated endpoint configuration pairs"); return 0
if __name__=='__main__': raise SystemExit(main())
