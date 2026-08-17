#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$HERE/../../../.." && pwd)"
SOURCE="$REPO_ROOT/msquic-p5-source/src/tools/interop/interop.cpp"
DATAPATH="$REPO_ROOT/msquic-p5-source/src/platform/datapath_raw_dpdk_linux.c"
BUILD="$REPO_ROOT/msquic/build-greenquic-p5"
DPDK="$REPO_ROOT/msquic/deps/dpdk-install"
BASE="$HERE/build_p5_performance2.sh"
PARALLEL_TRANSFORM="$HERE/apply_p5_parallel_connections.py"
TXQ_TRANSFORM="$HERE/apply_p5_multicore_txq_v4.py"
TXQ_TRANSFORM_V3="$HERE/apply_p5_multicore_txq_v3.py"
TXQ_TRANSFORM_V2="$HERE/apply_p5_multicore_txq_v2.py"
TXQ_TRANSFORM_BASE="$HERE/apply_p5_multicore_txq.py"
LCORE_STATS_TRANSFORM="$HERE/apply_p5_multicore_lcore_stats.py"
VERIFY_BINARY="$HERE/verify_p5_parallel_multicore_binary.sh"

for f in "$BASE" "$PARALLEL_TRANSFORM" "$TXQ_TRANSFORM" "$TXQ_TRANSFORM_V3" "$TXQ_TRANSFORM_V2" "$TXQ_TRANSFORM_BASE" "$LCORE_STATS_TRANSFORM" "$VERIFY_BINARY"; do
    [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 2; }
done
[[ -d "$DPDK" ]] || { echo "ERROR: DPDK install missing: $DPDK" >&2; exit 2; }

# P7 comparison uses MTU 1500. Force the disposable P5 Performance2 build to
# the same NIC MTU unless the caller explicitly overrides it for another study.
export P5_SUPER_MTU="${P5_SUPER_MTU:-1500}"

echo "======================================================================"
echo "P5 PERFORMANCE2 PARALLEL MULTICORE BUILD"
echo "Runtime topology: same binary supports one or more configured DPDK owners; QUIC worker list is runtime-configured"
echo "RX/TX: one queue per configured DPDK owner; stable per-flow TX queue mapping"
echo "Runtime proof: per-lcore RX/TX packet counters are mandatory"
echo "Workload: one MsQuic/DPDK process, multiple simultaneous QUIC connections"
echo "Fair-comparison MTU: $P5_SUPER_MTU"
echo "======================================================================"

# Build the exact current Performance2 configuration first. All additional
# transforms operate only on the disposable P5 source tree.
bash "$BASE"

[[ -f "$SOURCE" ]] || { echo "ERROR: disposable interop source missing: $SOURCE" >&2; exit 2; }
[[ -f "$DATAPATH" ]] || { echo "ERROR: disposable datapath missing: $DATAPATH" >&2; exit 2; }

python3 "$PARALLEL_TRANSFORM" "$SOURCE"
python3 "$TXQ_TRANSFORM" "$DATAPATH"
python3 "$LCORE_STATS_TRANSFORM" "$DATAPATH"
python3 -m py_compile "$PARALLEL_TRANSFORM" "$TXQ_TRANSFORM" "$TXQ_TRANSFORM_V3" "$TXQ_TRANSFORM_V2" "$TXQ_TRANSFORM_BASE" "$LCORE_STATS_TRANSFORM"

python3 - "$SOURCE" "$DATAPATH" <<'PY'
from pathlib import Path
import sys
source=Path(sys.argv[1]).read_text(encoding='utf-8',errors='replace')
dp=Path(sys.argv[2]).read_text(encoding='utf-8',errors='replace')
required_source=(
    'GREENQUIC-P5-PARALLEL-CONNECTIONS-V1',
    'GreenQuicP5RunParallelConnections',
    'GQ_INTEROP_P5_LOCAL_PORT_BASE',
    'SetLocalPort',
    'SendOneHttpRequest',
)
required_dp=(
    'GREENQUIC-P5-MULTICORE-TXQ-V1',
    'GREENQUIC-P5-MULTICORE-LCORE-STATS-V1',
    'GreenQuicTxQueueByLcore',
    'GreenQuicTxOwnerByQueue',
    'GreenQuicSelectTxQueue',
    'GreenQuicMcRxPacketsByQueue',
    'GreenQuicMcTxPacketsByQueue',
    'greenquic-mc-queue-v1',
    'greenquic-mc-lcore-v1',
    'GREENQUIC-P5-PERFORMANCE2-V1',
    'GREENQUIC-P5-PERFORMANCE2-V2',
)
missing=[x for x in required_source if x not in source] + [x for x in required_dp if x not in dp]
if missing:
    raise SystemExit('ERROR: multicore source audit missing: '+', '.join(missing))
if 'Dpdk->GreenQuicTxOwnerCount = NextTxQueue;' not in dp:
    raise SystemExit('ERROR: per-lcore TX owner count assignment missing')
if 'Hash % Dpdk->GreenQuicTxOwnerCount' not in dp:
    raise SystemExit('ERROR: stable flow-to-TX-queue mapping missing')
if 'RxPackets + TxPackets' not in dp:
    raise SystemExit('ERROR: per-lcore RX+TX runtime evidence missing')
if 'NextTxQueue != NextRxQueue || NextTxQueue == 0' not in dp:
    raise SystemExit('ERROR: V3/V4 one-or-more TX-owner runtime condition missing')
if 'Dpdk->GreenQuicTxOwnerCount != tx_rings || tx_rings == 0' not in dp:
    raise SystemExit('ERROR: V3/V4 one-or-more TX-ring runtime condition missing')
role_start=dp.find('static void\nGreenQuicConfigureRoles(')
role_end=dp.find('CxPlatDpdkReadConfig(', role_start)
role=dp[role_start:role_end] if role_start >= 0 and role_end > role_start else ''
if not role or 'Dpdk->GreenQuicTxOwnerCount = NextTxQueue;' not in role:
    raise SystemExit('ERROR: cannot prove per-lcore TX role assignment in GreenQuicConfigureRoles')
if 'PortConfig.rxmode.mtu = 1500;' not in dp:
    raise SystemExit('ERROR: P5 disposable datapath is not pinned to MTU 1500')
if 'txhandoff=sharded' in dp:
    if 'GreenQuicP2TxDequeueBurst(' not in dp:
        raise SystemExit('ERROR: sharded build lost its single-consumer dequeue path')
    if '    struct rte_ring* TxRing = GreenQuicGetTxRing(Dpdk, Interface, Core);\n' in dp:
        raise SystemExit('ERROR: sharded build retained dead queue-local TxRing variable')
    if 'static __attribute__((unused)) uint16_t\nGreenQuicSelectTxQueue(' not in dp:
        raise SystemExit('ERROR: sharded build lacks unused annotation on producer queue selector')
    if 'static __attribute__((unused)) void\nGreenQuicSignalTxQueueWork(' not in dp:
        raise SystemExit('ERROR: sharded build lacks unused annotation on queue wake helper')
print('P5 parallel multicore V4 source audit PASS: one-or-more runtime DPDK owners')
PY

export PKG_CONFIG_PATH="$DPDK/lib/pkgconfig:$DPDK/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LIBRARY_PATH="$DPDK/lib:$DPDK/lib/x86_64-linux-gnu${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LD_LIBRARY_PATH="$DPDK/lib:$DPDK/lib/x86_64-linux-gnu:$DPDK/lib/dpdk/pmds-22.0${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
cmake --build "$BUILD" --target quicinterop quicinteropserver --parallel "$(nproc)"

CLIENT="$BUILD/bin/Release/quicinterop"
SERVER="$BUILD/bin/Release/quicinteropserver"

# Build-time and run-time checks intentionally share one verifier so they
# cannot drift into checking different strings in the same executable.
bash "$VERIFY_BINARY" client "$CLIENT"
bash "$VERIFY_BINARY" server "$SERVER"

echo "P5 PERFORMANCE2 PARALLEL MULTICORE BUILD PASS"
sha256sum "$CLIENT" "$SERVER"
