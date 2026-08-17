#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(cd -- "$HERE/../../.." && pwd)"
P5="$HERE/P5_repeated_8GiB_downloads"
P7="$HERE/P7_linux_udp_baseline"
SRC="$ROOT/msquic/src/platform/datapath_raw_dpdk_linux.c"
PATCHER="$ROOT/greenquic_autopatch_v22.py"

echo "=== GreenQUIC multicore static preflight ==="

for f in \
  "$P5/build_p5_multicore_performance2.sh" \
  "$P5/run_matrix_multicore_with_sheet.sh" \
  "$P7/run_matrix_multicore_with_report.sh"
do
  bash -n "$f"
done

python3 -m py_compile \
  "$P5/build_sheet_rules_all_multicore.py" \
  "$P5/validate_p5_multicore_matrix.py" \
  "$P7/p7_multicore_irq.py" \
  "$P7/build_p7_report_multicore.py" \
  "$P7/validate_p7_multicore_matrix.py"

python3 - "$SRC" "$PATCHER" "$P5/config.env" "$P7/run_matrix_from_idex.sh" <<'PY'
from pathlib import Path
import sys
src=Path(sys.argv[1]).read_text(encoding="utf-8",errors="replace")
patcher=Path(sys.argv[2]).read_text(encoding="utf-8",errors="replace")
cfg=Path(sys.argv[3]).read_text(encoding="utf-8",errors="replace")
p7=Path(sys.argv[4]).read_text(encoding="utf-8",errors="replace")

required=[
 "GreenQuicEnableMultiCore","GreenQuicDpdkLcores","GreenQuicPartitionDpdkMap",
 "GreenQuicTxOwnerLcore","GreenQuicTxOwnerAlsoRx","GreenQuicRxQueueByLcore",
 "GreenQuicRxOwnerCount","GreenQuicLcoreOwnsTx","RTE_ETH_MQ_RX_RSS",
]
missing=[x for x in required if x not in src]
if missing: raise SystemExit("ERROR: generated datapath lacks multicore markers: "+", ".join(missing))
if "--enable-multi-core" not in patcher:
    raise SystemExit("ERROR: autopatcher multicore CLI option missing")
if "patch_multicore_support" not in patcher:
    raise SystemExit("ERROR: autopatcher multicore implementation hook missing")
if 'ENABLE_MULTICORE="${ENABLE_MULTICORE:-0}"' not in cfg:
    raise SystemExit("ERROR: P5 normal default is no longer isolated at ENABLE_MULTICORE=0")
anchor='p7_pin_irqs "$iface" "$P7_DATAPLANE_CPU"; p7_disable_rps "$iface"'
if anchor not in p7:
    raise SystemExit("ERROR: P7 post-channel IRQ/RPS anchor changed")
print("source/autopatcher/default-isolation/P7-anchor checks PASS")
PY

echo "MULTICORE STATIC PREFLIGHT PASS"
echo "No traffic was generated and no NIC state was changed."
