#!/usr/bin/env python3
from __future__ import annotations
from pathlib import Path
import subprocess,sys,tempfile

if len(sys.argv)!=2:raise SystemExit('usage: apply_p5_multicore_txq_v2.py PATH_TO_DATAPATH')
here=Path(__file__).resolve().parent;base=here/'apply_p5_multicore_txq.py'
src=base.read_text(encoding='utf-8')
old='''def function_slice(name: str, next_name: str) -> tuple[int, int, str]:
    start = text.find(name)
    if start < 0:
        raise SystemExit(f"ERROR: function anchor missing: {name}")
    # Walk back to the nearest static/IRQL declaration so replacements remain
    # scoped to the intended C function.
    back = max(text.rfind("\\nstatic", 0, start), text.rfind("\\n_IRQL", 0, start))
    if back >= 0:
        start = back + 1
    end = text.find(next_name, start + len(name))
    if end < 0:
        raise SystemExit(f"ERROR: next function anchor missing after {name}: {next_name}")
    return start, end, text[start:end]
'''
new='''def function_slice(name: str, next_name: str) -> tuple[int, int, str]:
    def definition_pos(token: str, after: int = 0) -> int:
        pos = text.find(token, after)
        while pos >= 0:
            brace = text.find("{", pos + len(token))
            semi = text.find(";", pos + len(token))
            if brace >= 0 and (semi < 0 or brace < semi):
                return pos
            pos = text.find(token, pos + len(token))
        return -1
    anchor = definition_pos(name)
    if anchor < 0:
        raise SystemExit(f"ERROR: function definition missing: {name}")
    back = max(text.rfind("\\nstatic", 0, anchor), text.rfind("\\n_IRQL", 0, anchor))
    start = back + 1 if back >= 0 else anchor
    next_anchor = definition_pos(next_name, anchor + len(name))
    if next_anchor < 0:
        raise SystemExit(f"ERROR: next function definition missing after {name}: {next_name}")
    next_back = max(text.rfind("\\nstatic", start, next_anchor), text.rfind("\\n_IRQL", start, next_anchor))
    end = next_back + 1 if next_back >= start else next_anchor
    return start, end, text[start:end]
'''
if src.count(old)!=1:raise SystemExit(f'ERROR: V1 function_slice anchor count={src.count(old)}')
src=src.replace(old,new,1)
with tempfile.NamedTemporaryFile('w',suffix='.py',delete=False,encoding='utf-8') as f:
    f.write(src);tmp=Path(f.name)
try:
    subprocess.run([sys.executable,str(tmp),sys.argv[1]],check=True)
finally:
    tmp.unlink(missing_ok=True)
