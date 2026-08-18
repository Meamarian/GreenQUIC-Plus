#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$HERE/../../../.." && pwd)"
BASE="$HERE/build_p5_super_performance.sh"
TRANSFORM="$HERE/apply_p5_tx_pacing_probe.py"
DATAPATH="$REPO_ROOT/msquic-p5-source/src/platform/datapath_raw_dpdk_linux.c"
BUILD="$REPO_ROOT/msquic/build-greenquic-p5"
DPDK="$REPO_ROOT/msquic/deps/dpdk-install"

BACKOFF_NS="${P5_TX_PACING_BACKOFF_NS:-0}"
SLEEP_US="${P5_TX_PACING_SLEEP_US:-0}"

[[ "$BACKOFF_NS" =~ ^[0-9]+$ ]] || { echo "ERROR: P5_TX_PACING_BACKOFF_NS must be non-negative" >&2; exit 2; }
[[ "$SLEEP_US" =~ ^[0-9]+$ ]] || { echo "ERROR: P5_TX_PACING_SLEEP_US must be non-negative" >&2; exit 2; }
if (( BACKOFF_NS > 0 && SLEEP_US > 0 )); then
    echo "ERROR: choose busy backoff or scheduler-yield sleep, not both" >&2
    exit 2
fi
for f in "$BASE" "$TRANSFORM"; do [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 2; }; done
[[ -d "$DPDK" ]] || { echo "ERROR: DPDK install missing: $DPDK" >&2; exit 2; }

python3 "$TRANSFORM" --self-test

# Reproduce the exact promoted one-DPDK-owner Super Performance profile that
# produced the historical ~10.45--10.49 Gbit/s PLUS steady result. Do not base
# this causality probe on the parallel/multicore architecture transforms.
SUPER_ENV=(
    P5_BUILD_REUSE=1
    P5_SUPER_CACHE=128
    P5_SUPER_RX_BURST=32
    P5_SUPER_TX_BURST=16
    P5_SUPER_RING_SIZE=4096
    P5_SUPER_RING_SYNC=legacy
    P5_SUPER_DRAIN_BURSTS=2
    P5_SUPER_DRAIN_THRESHOLD=0
    P5_SUPER_MTU=0
    P5_SUPER_SKIP_OFF_RINGCOUNT=0
    P5_SUPER_DEBUG_COUNTERS=1
    P5_SUPER_TRANSFER_WINDOW=1
    P5_SUPER_TRACE_RINGCOUNT=1
    P5_SUPER_TX_META=mbuf
    P5_SUPER_RX_META=mbuf
    P5_SUPER_TX_LOCK_MODE=single_owner
    P5_SUPER_CAP_DIAG=1
)

echo "======================================================================"
echo "P5 ONE-CORE TX PACING PROBE BUILD"
echo "Super reference: cache=128 RX=32 TX=16 ring=4096 drain=2 metadata=mbuf lock=single_owner mtu=default"
echo "Probe: OFF empty-dequeue backoff_ns=$BACKOFF_NS sleep_us=$SLEEP_US"
echo "======================================================================"

env "${SUPER_ENV[@]}" bash "$BASE"

[[ -f "$DATAPATH" ]] || { echo "ERROR: disposable datapath missing: $DATAPATH" >&2; exit 2; }
python3 "$TRANSFORM" "$DATAPATH" --backoff-ns "$BACKOFF_NS" --sleep-us "$SLEEP_US"

export PKG_CONFIG_PATH="$DPDK/lib/pkgconfig:$DPDK/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LIBRARY_PATH="$DPDK/lib:$DPDK/lib/x86_64-linux-gnu${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LD_LIBRARY_PATH="$DPDK/lib:$DPDK/lib/x86_64-linux-gnu:$DPDK/lib/dpdk/pmds-22.0${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
cmake --build "$BUILD" --target quicinterop quicinteropserver --parallel "$(nproc)"

CLIENT="$BUILD/bin/Release/quicinterop"
SERVER="$BUILD/bin/Release/quicinteropserver"
for bin in "$CLIENT" "$SERVER"; do
    test -x "$bin"
    grep -aFq -- 'GREENQUIC-P5-SUPER-PERF-V2' "$bin" || {
        echo "ERROR: exact Super Performance marker missing from $bin" >&2
        exit 2
    }
    grep -aFq -- 'GREENQUIC-P5-TX-PACING-PROBE-V1' "$bin" || {
        echo "ERROR: pacing marker missing from $bin" >&2
        exit 2
    }
done

echo "P5 TX PACING BUILD PASS backoff_ns=$BACKOFF_NS sleep_us=$SLEEP_US"
sha256sum "$CLIENT" "$SERVER"
