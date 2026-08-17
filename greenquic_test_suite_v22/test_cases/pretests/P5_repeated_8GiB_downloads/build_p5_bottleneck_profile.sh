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
TXQ_TRANSFORM="$HERE/apply_p5_bottleneck_txq.py"
LCORE_STATS_TRANSFORM="$HERE/apply_p5_multicore_lcore_stats.py"
VERIFY_BINARY="$HERE/verify_p5_parallel_multicore_binary.sh"

for f in "$BASE" "$PARALLEL_TRANSFORM" "$TXQ_TRANSFORM" "$LCORE_STATS_TRANSFORM" "$VERIFY_BINARY"; do
    [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 2; }
done
[[ -d "$DPDK" ]] || { echo "ERROR: DPDK install missing: $DPDK" >&2; exit 2; }

# Every sweep case is compared at the same MTU.
export P5_SUPER_MTU="${P5_SUPER_MTU:-1500}"

echo "======================================================================"
echo "P5 BOTTLENECK PROFILE BUILD"
echo "Runtime topology support: DPDK lcores=19 OR 19,20; QUIC workers=21-24"
echo "Workload contract: 4 simultaneous QUIC connections, OFF mode at runtime"
echo "MTU=$P5_SUPER_MTU"
echo "======================================================================"

# Rebuild disposable P5 source from the selected Performance2 profile.
bash "$BASE"

[[ -f "$SOURCE" ]] || { echo "ERROR: disposable interop source missing: $SOURCE" >&2; exit 2; }
[[ -f "$DATAPATH" ]] || { echo "ERROR: disposable datapath missing: $DATAPATH" >&2; exit 2; }

python3 "$PARALLEL_TRANSFORM" "$SOURCE"
python3 "$TXQ_TRANSFORM" "$DATAPATH"
python3 "$LCORE_STATS_TRANSFORM" "$DATAPATH"
python3 -m py_compile "$PARALLEL_TRANSFORM" "$TXQ_TRANSFORM" "$LCORE_STATS_TRANSFORM"

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
    'greenquic-mc-queue-v1',
    'greenquic-mc-lcore-v1',
    'GreenQuicTxQueueByLcore',
    'GreenQuicTxOwnerByQueue',
    'GreenQuicSelectTxQueue',
    'NextTxQueue != NextRxQueue || NextTxQueue == 0',
    'Dpdk->GreenQuicTxOwnerCount != tx_rings || tx_rings == 0',
    'GREENQUIC-P5-PERFORMANCE2-V1',
    'GREENQUIC-P5-PERFORMANCE2-V2',
)
missing=[x for x in required_source if x not in source] + [x for x in required_dp if x not in dp]
if missing:
    raise SystemExit('ERROR: bottleneck source audit missing: '+', '.join(missing))
if 'Hash % Dpdk->GreenQuicTxOwnerCount' not in dp:
    raise SystemExit('ERROR: stable flow-to-TX-queue mapping missing')
if 'RxPackets + TxPackets' not in dp:
    raise SystemExit('ERROR: per-lcore RX+TX runtime evidence missing')
if 'PortConfig.rxmode.mtu = 1500;' not in dp:
    raise SystemExit('ERROR: bottleneck datapath is not pinned to MTU 1500')
print('P5 BOTTLENECK SOURCE AUDIT PASS: one-core and two-core runtime topologies supported')
PY

export PKG_CONFIG_PATH="$DPDK/lib/pkgconfig:$DPDK/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LIBRARY_PATH="$DPDK/lib:$DPDK/lib/x86_64-linux-gnu${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LD_LIBRARY_PATH="$DPDK/lib:$DPDK/lib/x86_64-linux-gnu:$DPDK/lib/dpdk/pmds-22.0${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
cmake --build "$BUILD" --target quicinterop quicinteropserver --parallel "$(nproc)"

CLIENT="$BUILD/bin/Release/quicinterop"
SERVER="$BUILD/bin/Release/quicinteropserver"
bash "$VERIFY_BINARY" client "$CLIENT"
bash "$VERIFY_BINARY" server "$SERVER"

echo "P5 BOTTLENECK PROFILE BUILD PASS"
sha256sum "$CLIENT" "$SERVER"
