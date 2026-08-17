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
 "$HERE/mac_run_parallel_multicore_fair_2r_v1.sh"
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

for f in "${BASH_FILES[@]}"; do
    [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 2; }
    bash -n "$f"
done
for f in "${PY_FILES[@]}"; do
    [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 2; }
    python3 -m py_compile "$f"
done

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
if 'for (uint32_t Index = 0; Index < RTE_MAX_LCORE; ++Index)' not in text:
 raise SystemExit('ERROR: current GreenQuicConfigureRoles role-map loop shape changed')
print('PASS: checked-in datapath remains base architecture; disposable-only TXQ marker absent')
PY

# Reproduce the exact disposable source transformation chain used by the P5
# multicore build, but on a temporary C file only. This catches compatibility
# failures before CMake compilation, NIC startup, or any traffic.
for f in \
    "$P5/apply_p5_super_performance.py" \
    "$P5/apply_p5_super_packet_counter_guard.py" \
    "$P5/apply_p5_performance2.py" \
    "$P5/apply_p5_performance2_v2.py" \
    "$P5/apply_p5_multicore_txq_v2.py"
do
    [[ -f "$f" ]] || { echo "ERROR: transform missing: $f" >&2; exit 2; }
done

TMP_DP="$(mktemp /tmp/greenquic_p5_fullchain_preflight.XXXXXX.c)"
trap 'rm -f "$TMP_DP"' EXIT
cp "$REPO_ROOT/msquic/src/platform/datapath_raw_dpdk_linux.c" "$TMP_DP"

python3 "$P5/apply_p5_super_performance.py" "$TMP_DP" \
    --cache 128 \
    --rx-burst 32 \
    --tx-burst 16 \
    --ring-size 4096 \
    --ring-sync legacy \
    --drain-bursts 2 \
    --drain-threshold 0 \
    --mtu 1500 \
    --skip-off-ringcount 0 \
    --debug-counters 1 \
    --transfer-window 1 \
    --trace-ringcount 1 \
    --tx-meta mbuf \
    --rx-meta mbuf \
    --tx-lock-mode single_owner \
    --cap-diag 1
python3 "$P5/apply_p5_super_packet_counter_guard.py" 1 "$TMP_DP"
python3 "$P5/apply_p5_performance2.py" "$TMP_DP" \
    --diag-interval-us 0 \
    --diag-duration-ms 3000 \
    --tx-handoff shared \
    --tx-producer-ring-size 1024 \
    --rx-prefetch 0 \
    --udp-seg 0 \
    --udp-seg-max 4
python3 "$P5/apply_p5_performance2_v2.py" "$TMP_DP" \
    --tx-alloc-batch 8 \
    --tx-enqueue-counter 0 \
    --tx-meta-zero 1 \
    --rx-pipe-prefetch 2 \
    --shard-active-mask 0
python3 "$P5/apply_p5_multicore_txq_v2.py" "$TMP_DP"

for marker in \
    GREENQUIC-P5-SUPER-PERF-V2 \
    GREENQUIC-P5-PERFORMANCE2-V1 \
    GREENQUIC-P5-PERFORMANCE2-V2 \
    GREENQUIC-P5-MULTICORE-TXQ-V1 \
    GreenQuicTxOwnerCount \
    GreenQuicSelectTxQueue
 do
    grep -Fq "$marker" "$TMP_DP" || {
        echo "ERROR: full-chain preflight missing marker: $marker" >&2
        exit 2
    }
done

grep -Fq 'Interface->TxRingByQueue[TxQueueId] : Interface->TxRingBuffer;' "$TMP_DP" || {
    echo "ERROR: TX queue selector lost the intended queue-0 fallback" >&2
    exit 2
}
if grep -Fq 'Interface->TxRingByQueue[TxQueueId] : TxRing;' "$TMP_DP"; then
    echo "ERROR: TX queue selector contains a self-referential TxRing fallback" >&2
    exit 2
fi

grep -Fq 'PortConfig.rxmode.mtu = 1500;' "$TMP_DP" || {
    echo "ERROR: full-chain preflight lost fair-comparison MTU 1500" >&2
    exit 2
}

rm -f "$TMP_DP"
trap - EXIT

echo "PASS: exact Super -> Performance2 V1 -> V2 -> multicore TXQ chain transforms current datapath"
echo "PASS: per-flow TX selector preserves explicit queue-0 fallback without self-reference"
echo "PARALLEL MULTICORE STATIC PREFLIGHT PASS"
echo "No traffic was generated and no NIC/IRQ state was changed."
