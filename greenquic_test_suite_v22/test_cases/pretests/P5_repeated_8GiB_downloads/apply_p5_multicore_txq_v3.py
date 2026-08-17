#!/usr/bin/env python3
from __future__ import annotations

"""Apply the P5 multicore TXQ transform while allowing one or more runtime owners.

V1/V2 intentionally failed closed when ENABLE_MULTICORE was set with fewer than
2 DPDK owners. That was useful for the original two-core fair-comparison test,
but prevents a same-binary A/B bottleneck experiment (1 lcore vs 2 lcores).

V3 keeps every V2 compatibility fix and every queue-mapping rule, but changes
only the minimum owner count from two to one. A zero-owner configuration still
fails closed. Two-or-more-owner behavior is unchanged.
"""

from pathlib import Path
import subprocess
import sys
import tempfile

if len(sys.argv) != 2:
    raise SystemExit('usage: apply_p5_multicore_txq_v3.py PATH_TO_DATAPATH')

here = Path(__file__).resolve().parent
v1 = here / 'apply_p5_multicore_txq.py'
v2 = here / 'apply_p5_multicore_txq_v2.py'
for p in (v1, v2):
    if not p.is_file():
        raise SystemExit(f'ERROR: missing transform dependency: {p}')

v1_src = v1.read_text(encoding='utf-8')
v2_src = v2.read_text(encoding='utf-8')

replacements = (
    ('NextTxQueue < 2', 'NextTxQueue == 0', 'runtime TX-owner minimum'),
    ('tx_rings < 2', 'tx_rings == 0', 'runtime TX-ring minimum'),
)
for old, new, label in replacements:
    n = v1_src.count(old)
    if n != 1:
        raise SystemExit(f'ERROR: {label} anchor count={n}, expected 1')
    v1_src = v1_src.replace(old, new, 1)

# Keep the runtime diagnostic strings stable because the binary verifier uses
# them as compiled-contract evidence. Only the numeric fail condition changes.
with tempfile.TemporaryDirectory(prefix='p5_mc_txq_v3_') as td:
    tmp = Path(td)
    (tmp / 'apply_p5_multicore_txq.py').write_text(v1_src, encoding='utf-8')
    (tmp / 'apply_p5_multicore_txq_v2.py').write_text(v2_src, encoding='utf-8')
    subprocess.run(
        [sys.executable, str(tmp / 'apply_p5_multicore_txq_v2.py'), sys.argv[1]],
        check=True,
    )

text = Path(sys.argv[1]).read_text(encoding='utf-8', errors='replace')
required = (
    'GREENQUIC-P5-MULTICORE-TXQ-V1',
    'GreenQuicTxQueueByLcore',
    'GreenQuicTxOwnerByQueue',
    'GreenQuicSelectTxQueue',
)
missing = [x for x in required if x not in text]
if missing:
    raise SystemExit('ERROR: V3 output missing: ' + ', '.join(missing))

print('P5 multicore TXQ V3 applied: runtime supports one or more DPDK TX owners')
