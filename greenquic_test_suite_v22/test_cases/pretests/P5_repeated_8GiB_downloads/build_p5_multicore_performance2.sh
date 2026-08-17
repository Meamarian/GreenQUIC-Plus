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
TXQ_TRANSFORM="$HERE/apply_p5_multicore_txq.py"

for f in "$BASE" "$PARALLEL_TRANSFORM" "$TXQ_TRANSFORM"; do
    [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 2; }
done
[[ -d "$DPDK" ]] || { echo "ERROR: DPDK install missing: $DPDK" >&2; exit 2; }

echo "======================================================================"
echo "P5 PERFORMANCE2 PARALLEL MULTICORE BUILD"
echo "Topology target: DPDK=19,20  QUIC=21,22,23,24"
echo "RX: RSS queues 0,1  TX: per-flow queues 0,1 with one owner per DPDK core"
echo "Workload: one MsQuic/DPDK process, multiple simultaneous QUIC connections"
echo "======================================================================"

# Build the exact current Performance2 configuration first. Both additional
# transforms operate only on the disposable P5 source tree and therefore do not
# change performance2/p5-max-goodput or the normal build-greenquic binary.
bash "$BASE"

[[ -f "$SOURCE" ]] || { echo "ERROR: disposable interop source missing: $SOURCE" >&2; exit 2; }
[[ -f "$DATAPATH" ]] || { echo "ERROR: disposable datapath missing: $DATAPATH" >&2; exit 2; }

python3 "$PARALLEL_TRANSFORM" "$SOURCE"
python3 "$TXQ_TRANSFORM" "$DATAPATH"
python3 -m py_compile "$PARALLEL_TRANSFORM" "$TXQ_TRANSFORM"

# Static source audit before compilation.
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
    'GreenQuicTxQueueByLcore',
    'GreenQuicTxOwnerByQueue',
    'GreenQuicSelectTxQueue',
    'GreenQuicMcRxPacketsByQueue',
    'GreenQuicMcTxPacketsByQueue',
    'greenquic-mc-queue-v1',
    'GREENQUIC-P5-PERFORMANCE2-V1',
    'GREENQUIC-P5-PERFORMANCE2-V2',
)
missing=[x for x in required_source if x not in source] + [x for x in required_dp if x not in dp]
if missing:
    raise SystemExit('ERROR: multicore source audit missing: '+', '.join(missing))
# The old multicore architecture had exactly one NIC TX queue. It must no longer
# survive as the active role assignment in this disposable source.
if 'Dpdk->GreenQuicTxOwnerCount = NextTxQueue;' not in dp:
    raise SystemExit('ERROR: per-lcore TX owner count assignment missing')
if 'Hash % Dpdk->GreenQuicTxOwnerCount' not in dp:
    raise SystemExit('ERROR: stable flow-to-TX-queue mapping missing')
print('P5 parallel multicore source audit PASS')
PY

export PKG_CONFIG_PATH="$DPDK/lib/pkgconfig:$DPDK/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LIBRARY_PATH="$DPDK/lib:$DPDK/lib/x86_64-linux-gnu${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LD_LIBRARY_PATH="$DPDK/lib:$DPDK/lib/x86_64-linux-gnu:$DPDK/lib/dpdk/pmds-22.0${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# The source was changed after the base Performance2 build, so force the two
# interop binaries to relink from the transformed disposable tree.
cmake --build "$BUILD" --target quicinterop quicinteropserver --parallel "$(nproc)"

CLIENT="$BUILD/bin/Release/quicinterop"
SERVER="$BUILD/bin/Release/quicinteropserver"
for bin in "$CLIENT" "$SERVER"; do
    [[ -x "$bin" ]] || { echo "ERROR: missing executable $bin" >&2; exit 2; }
    for marker in \
        GreenQuicEnableMultiCore \
        GreenQuicPartitionDpdkMap \
        GREENQUIC-P5-MULTICORE-TXQ-V1 \
        greenquic-mc-queue-v1 \
        GREENQUIC-P5-PERFORMANCE2-V1 \
        GREENQUIC-P5-PERFORMANCE2-V2
    do
        grep -aFq -- "$marker" "$bin" || {
            echo "ERROR: multicore/performance marker '$marker' missing from $bin" >&2
            exit 2
        }
    done
done
for marker in \
    GREENQUIC-P5-PARALLEL-CONNECTIONS-V1 \
    GQ_INTEROP_P5_LOCAL_PORT_BASE \
    ready_for_start_gate_us=
do
    grep -aFq -- "$marker" "$CLIENT" || {
        echo "ERROR: parallel-client marker '$marker' missing from $CLIENT" >&2
        exit 2
    }
done

echo "P5 PERFORMANCE2 PARALLEL MULTICORE BUILD PASS"
sha256sum "$CLIENT" "$SERVER"
