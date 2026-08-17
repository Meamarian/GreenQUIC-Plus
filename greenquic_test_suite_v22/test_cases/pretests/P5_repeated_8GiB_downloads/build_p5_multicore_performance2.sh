#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$HERE/../../../.." && pwd)"
DATAPATH="$REPO_ROOT/msquic-p5-source/src/platform/datapath_raw_dpdk_linux.c"
BUILD="$REPO_ROOT/msquic/build-greenquic-p5"
BASE="$HERE/build_p5_performance2.sh"

[[ -x "$BASE" || -f "$BASE" ]] || { echo "ERROR: missing $BASE" >&2; exit 2; }

echo "======================================================================"
echo "P5 PERFORMANCE2 MULTICORE BUILD"
echo "Topology target: DPDK=19,20  QUIC=21,22,23,24  TX-owner=19"
echo "======================================================================"

bash "$BASE"

[[ -f "$DATAPATH" ]] || { echo "ERROR: disposable datapath missing: $DATAPATH" >&2; exit 2; }

python3 - "$DATAPATH" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace")

required = {
    "runtime multicore gate": "GreenQuicEnableMultiCore",
    "per-lcore RX queue map": "GreenQuicRxQueueByLcore",
    "partition to DPDK map": "GreenQuicPartitionDpdkMap",
    "dedicated TX owner": "GreenQuicTxOwnerLcore",
    "TX owner RX control": "GreenQuicTxOwnerAlsoRx",
    "RX-owner count": "GreenQuicRxOwnerCount",
    "per-lcore policy state": "GreenQuicLcore[RTE_MAX_LCORE]",
    "RSS mode": "RTE_ETH_MQ_RX_RSS",
}
missing = [label for label, marker in required.items() if marker not in text]
if missing:
    raise SystemExit("ERROR: multicore source markers missing: " + ", ".join(missing))

for marker in (
    "GREENQUIC-P5-PERFORMANCE2-V1",
    "GREENQUIC-P5-PERFORMANCE2-V2",
):
    if marker not in text:
        raise SystemExit(f"ERROR: Performance2 marker missing: {marker}")

# Shared MsQuic TX ring: many producers are allowed, but the generated
# multicore path must still have one configured consumer/TX owner.
if "GreenQuicLcoreOwnsTx" not in text:
    raise SystemExit("ERROR: TX ownership helper missing")
if "GreenQuicTxOwnerConfigured" not in text:
    raise SystemExit("ERROR: TX-owner configuration state missing")
if "CxPlatDpdkGreenQuicWorkerThread" not in text:
    raise SystemExit("ERROR: multicore GreenQUIC worker entry point missing")

print("P5 multicore source audit PASS")
PY

CLIENT="$BUILD/bin/Release/quicinterop"
SERVER="$BUILD/bin/Release/quicinteropserver"
for bin in "$CLIENT" "$SERVER"; do
    [[ -x "$bin" ]] || { echo "ERROR: missing executable $bin" >&2; exit 2; }
    for marker in \
        GreenQuicEnableMultiCore \
        GreenQuicPartitionDpdkMap \
        GreenQuicTxOwnerLcore \
        GreenQuicTxOwnerAlsoRx \
        GREENQUIC-P5-PERFORMANCE2-V1 \
        GREENQUIC-P5-PERFORMANCE2-V2
    do
        grep -aFq -- "$marker" "$bin" || {
            echo "ERROR: multicore/performance marker '$marker' missing from $bin" >&2
            exit 2
        }
    done
done

echo "P5 PERFORMANCE2 MULTICORE BUILD PASS"
sha256sum "$CLIENT" "$SERVER"
