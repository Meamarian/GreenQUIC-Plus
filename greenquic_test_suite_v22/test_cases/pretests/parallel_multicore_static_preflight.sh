#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$HERE/../../.." && pwd)"
P5="$HERE/P5_repeated_8GiB_downloads"
P7="$HERE/P7_linux_udp_baseline"

BASH_FILES=(
 "$P5/build_p5_multicore_performance2.sh"
 "$P5/run_client_parallel_multicore.sh"
 "$P5/run_parallel_multicore_matrix.sh"
 "$P7/build_p7_parallel_multicore.sh"
 "$P7/run_server_parallel_multicore.sh"
 "$P7/run_client_parallel_multicore.sh"
 "$P7/run_parallel_multicore_matrix.sh"
)
PY_FILES=(
 "$P5/apply_p5_parallel_connections.py"
 "$P5/apply_p5_multicore_txq.py"
 "$P5/apply_p5_multicore_txq_v2.py"
 "$P5/report_p5_parallel_run.py"
 "$P5/aggregate_parallel_goodput.py"
 "$P5/validate_p5_multicore_matrix.py"
 "$P7/report_p7_parallel_run.py"
 "$P7/aggregate_p7_parallel_goodput.py"
 "$P7/p7_multicore_irq.py"
 "$P7/validate_p7_parallel_irq_activity.py"
 "$P7/validate_p7_multicore_matrix.py"
 "$P7/build_p7_report_multicore.py"
 "$HERE/compare_parallel_p5_p7.py"
)

for f in "${BASH_FILES[@]}"; do [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2;exit 2;};bash -n "$f";done
for f in "${PY_FILES[@]}"; do [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2;exit 2;};python3 -m py_compile "$f";done

python3 - "$REPO_ROOT" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1]);pre=root/'greenquic_test_suite_v22/test_cases/pretests';p5=pre/'P5_repeated_8GiB_downloads';p7=pre/'P7_linux_udp_baseline'
checks=[
 (p5/'run_matrix_from_idex.sh','./run_client.sh','P5 client patch anchor'),
 (p7/'run_matrix_from_idex.sh','"$HERE/run_server.sh" --run-dir "$srun" --rep "$rep"','P7 server patch anchor'),
 (p7/'run_matrix_from_idex.sh',"'$CLIENT_DIR/run_client.sh' --run-dir '$crun_remote' --rep '$rep' --gate '$gate'",'P7 client patch anchor'),
 (p7/'run_matrix_from_idex.sh','p7_pin_irqs "$iface" "$P7_DATAPLANE_CPU"; p7_disable_rps "$iface"','P7 IRQ post-channel anchor'),
 (p7/'run_client.sh','python3 "$HERE/report_p7_run.py"','P7 client reporter anchor'),
 (p7/'run_server.sh','python3 "$HERE/report_p7_run.py"','P7 server reporter anchor'),
]
for path,needle,label in checks:
 text=path.read_text(encoding='utf-8',errors='replace');count=text.count(needle)
 if count<1:raise SystemExit(f'ERROR: {label} missing in {path}')
 print(f'PASS: {label} count={count}')
dp=root/'msquic/src/platform/datapath_raw_dpdk_linux.c'
if not dp.is_file():raise SystemExit(f'ERROR: checked-in datapath missing: {dp}')
text=dp.read_text(encoding='utf-8',errors='replace')
for marker in ('GreenQuicEnableMultiCore','GreenQuicRxQueueByLcore','RTE_ETH_MQ_RX_RSS'):
 if marker not in text:raise SystemExit(f'ERROR: existing optional multicore capability missing: {marker}')
if 'GREENQUIC-P5-MULTICORE-TXQ-V1' in text:raise SystemExit('ERROR: disposable-only TXQ transform leaked into checked-in MsQuic datapath')
print('PASS: checked-in datapath remains base architecture; disposable-only TXQ marker absent')
PY

echo "PARALLEL MULTICORE STATIC PREFLIGHT PASS"
echo "No traffic was generated and no NIC/IRQ state was changed."
