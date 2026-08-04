\
#!/usr/bin/env python3
from __future__ import annotations
import argparse, json
from pathlib import Path

def latest(folder: Path, pattern: str) -> Path:
    files=sorted(folder.glob(pattern), key=lambda p:p.stat().st_mtime_ns, reverse=True)
    if not files: raise SystemExit(f'no result matching {folder/pattern}')
    return files[0]

def main() -> int:
    ap=argparse.ArgumentParser(); ap.add_argument('--suite-root',type=Path,default=Path(__file__).resolve().parents[2]); args=ap.parse_args()
    root=args.suite_root.resolve()
    offp=latest(root/'test_cases/pretests/P1_goodput_off_10GiB/results','goodput_off_*.json')
    basicp=latest(root/'test_cases/pretests/P2_goodput_basic_10GiB/results','goodput_basic_*.json')
    off=json.loads(offp.read_text()); basic=json.loads(basicp.read_text())
    og=float(off['goodput_gbps_decimal']); bg=float(basic['goodput_gbps_decimal']); delta=(bg-og)/og*100 if og else float('nan')
    print('\n=== V22 OFF vs BASIC pretest ===')
    print(f"OFF:   {og:.3f} Gbit/s, {off['elapsed_s']:.6f} s")
    print(f"BASIC: {bg:.3f} Gbit/s, {basic['elapsed_s']:.6f} s")
    print(f"BASIC relative to OFF: {delta:+.2f}%")
    print(f"OFF result:   {offp}")
    print(f"BASIC result: {basicp}")
    return 0
if __name__=='__main__': raise SystemExit(main())
