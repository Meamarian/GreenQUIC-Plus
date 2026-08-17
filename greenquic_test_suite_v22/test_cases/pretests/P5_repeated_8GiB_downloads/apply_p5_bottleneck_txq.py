#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import tempfile

if len(sys.argv) != 2:
    raise SystemExit("usage: apply_p5_bottleneck_txq.py PATH_TO_DATAPATH")

here = Path(__file__).resolve().parent
base = here / "apply_p5_multicore_txq.py"
v2 = here / "apply_p5_multicore_txq_v2.py"
for p in (base, v2):
    if not p.is_file():
        raise SystemExit(f"ERROR: missing transform dependency: {p}")

base_src = base.read_text(encoding="utf-8")
v2_src = v2.read_text(encoding="utf-8")

# The normal fair-comparison transform intentionally fails closed unless at
# least two TX owners exist. The bottleneck sweep needs an exact one-core
# control using the same compiled datapath. Relax ONLY those two minimum-count
# guards while preserving the one-TX-queue-per-RX-owner equality check.
repls = (
    (
        "NextTxQueue != NextRxQueue || NextTxQueue < 2",
        "NextTxQueue != NextRxQueue || NextTxQueue == 0",
        "role assignment minimum TX owner count",
    ),
    (
        "Dpdk->GreenQuicTxOwnerCount != tx_rings || tx_rings < 2",
        "Dpdk->GreenQuicTxOwnerCount != tx_rings || tx_rings == 0",
        "TX ring topology minimum count",
    ),
)
for old, new, label in repls:
    n = base_src.count(old)
    if n != 1:
        raise SystemExit(f"ERROR: {label} anchor count={n}, expected 1")
    base_src = base_src.replace(old, new, 1)

with tempfile.TemporaryDirectory(prefix="p5_bottleneck_txq_") as td:
    t = Path(td)
    (t / "apply_p5_multicore_txq.py").write_text(base_src, encoding="utf-8")
    (t / "apply_p5_multicore_txq_v2.py").write_text(v2_src, encoding="utf-8")
    subprocess.run(
        [sys.executable, str(t / "apply_p5_multicore_txq_v2.py"), sys.argv[1]],
        check=True,
    )

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
required = (
    "GREENQUIC-P5-MULTICORE-TXQ-V1",
    "GreenQuicTxQueueByLcore",
    "GreenQuicTxOwnerByQueue",
    "GreenQuicTxOwnerCount",
    "NextTxQueue != NextRxQueue || NextTxQueue == 0",
    "Dpdk->GreenQuicTxOwnerCount != tx_rings || tx_rings == 0",
)
missing = [x for x in required if x not in text]
if missing:
    raise SystemExit("ERROR: bottleneck TXQ transform missing generated evidence: " + ", ".join(missing))

print("P5 BOTTLENECK TXQ TRANSFORM PASS: runtime supports exactly one or multiple DPDK owners")
