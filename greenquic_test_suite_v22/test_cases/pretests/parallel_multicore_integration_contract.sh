#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
P5="$HERE/P5_repeated_8GiB_downloads"
P7="$HERE/P7_linux_udp_baseline"
MAC="$HERE/mac_run_parallel_multicore_fair_2r_v1.sh"

FILES=(
    "$P5/verify_p5_parallel_multicore_binary.sh"
    "$P5/build_p5_multicore_performance2.sh"
    "$P5/run_client_parallel_multicore.sh"
    "$P5/run_parallel_multicore_matrix.sh"
    "$P7/build_p7_parallel_multicore.sh"
    "$P7/run_server_parallel_multicore.sh"
    "$P7/run_client_parallel_multicore.sh"
    "$P7/run_parallel_multicore_matrix.sh"
    "$MAC"
)
for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || { echo "ERROR: integration-contract file missing: $f" >&2; exit 2; }
    bash -n "$f"
done

python3 - "$P5" "$P7" "$MAC" <<'PY'
from pathlib import Path
import sys
p5=Path(sys.argv[1]); p7=Path(sys.argv[2]); mac=Path(sys.argv[3])

def text(path):
    return path.read_text(encoding='utf-8', errors='replace')

def require(hay, needle, label):
    if needle not in hay:
        raise SystemExit(f"ERROR: integration contract missing {label}: {needle}")

def forbid(hay, needle, label):
    if needle in hay:
        raise SystemExit(f"ERROR: integration contract contains forbidden {label}: {needle}")

verify=text(p5/'verify_p5_parallel_multicore_binary.sh')
build=text(p5/'build_p5_multicore_performance2.sh')
client=text(p5/'run_client_parallel_multicore.sh')
p5matrix=text(p5/'run_parallel_multicore_matrix.sh')
p7build=text(p7/'build_p7_parallel_multicore.sh')
p7matrix=text(p7/'run_parallel_multicore_matrix.sh')
macs=text(mac)

# One source of truth for compiled P5 evidence. The source-only TXQ marker must
# never be used as an ELF/runtime requirement.
for marker in (
    'GreenQuicEnableMultiCore',
    'GreenQuicPartitionDpdkMap',
    'greenquic-mc-queue-v1',
    'GreenQUIC multicore TX queue topology invalid',
    'GreenQUIC multicore TX requires one TX queue per DPDK RX owner',
    'GREENQUIC-P5-PERFORMANCE2-V1',
    'GREENQUIC-P5-PERFORMANCE2-V2',
    'GREENQUIC-P5-PARALLEL-CONNECTIONS-V1',
    'GQ_INTEROP_P5_LOCAL_PORT_BASE',
    'ready_for_start_gate_us=',
):
    require(verify, marker, 'compiled-runtime evidence')
forbid(verify, 'GREENQUIC-P5-MULTICORE-TXQ-V1', 'source-only marker in compiled-runtime verifier')
forbid(client, 'GREENQUIC-P5-MULTICORE-TXQ-V1', 'source-only marker in P5 runtime wrapper')
require(client, 'bash "$VERIFY_BINARY" client "$actual_client_bin"', 'P5 client shared runtime verifier call')
require(build, 'bash "$VERIFY_BINARY" client "$CLIENT"', 'P5 build client verifier call')
require(build, 'bash "$VERIFY_BINARY" server "$SERVER"', 'P5 build server verifier call')

# P7's anti-DPDK check must also inspect real compiled strings, not comments.
forbid(p7build, 'GREENQUIC-P5-MULTICORE-TXQ-V1', 'source-only P7 binary check')
for marker in (
    'greenquic-mc-queue-v1',
    'GreenQUIC multicore TX queue topology invalid',
    'GreenQUIC multicore TX requires one TX queue per DPDK RX owner',
):
    require(p7build, marker, 'P7 compiled anti-DPDK evidence')

# Branch-only shell files created through the GitHub contents API may be 0644.
# Controllers must invoke them with bash rather than depend on executable bits.
require(p5matrix, "new='bash ./run_client_parallel_multicore.sh'", 'P5 bash wrapper invocation')
forbid(p5matrix, "new='./run_client_parallel_multicore.sh'", 'P5 direct wrapper invocation')
require(p7matrix, 'bash "$HERE/run_server_parallel_multicore.sh" --run-dir "$srun" --rep "$rep"', 'P7 server bash wrapper invocation')
require(p7matrix, "bash '$CLIENT_DIR/run_client_parallel_multicore.sh' --run-dir '$crun_remote' --rep '$rep' --gate '$gate'", 'P7 client bash wrapper invocation')

# The Mac orchestrator must not let tee hide a failed remote matrix and must
# invoke branch-only scripts through bash.
if macs.count('set -o pipefail;') < 2:
    raise SystemExit('ERROR: Mac launcher must preserve pipefail for both P5 and P7 tee pipelines')
for needle,label in (
    ('bash ./parallel_multicore_integration_contract.sh', 'integration audit invocation'),
    ('bash ./parallel_multicore_static_preflight.sh', 'static preflight invocation'),
    ('bash ./build_p5_multicore_performance2.sh', 'P5 build invocation'),
    ('bash ./run_parallel_multicore_matrix.sh', 'matrix invocation'),
    ('bash ./build_p7_parallel_multicore.sh', 'P7 build invocation'),
):
    require(macs, needle, label)

print('PARALLEL MULTICORE INTEGRATION CONTRACT PASS')
print('  compiled evidence: centralized; source-only markers forbidden in ELF checks')
print('  branch shell wrappers: bash-invoked; executable-bit independent')
print('  remote tee pipelines: pipefail preserved')
print('  P7 anti-DPDK audit: compiled runtime evidence only')
PY
