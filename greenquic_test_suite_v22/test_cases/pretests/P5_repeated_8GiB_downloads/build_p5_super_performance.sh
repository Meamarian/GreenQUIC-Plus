#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$HERE/../../../.." && pwd)"
MAIN_MSQUIC="$REPO_ROOT/msquic"
DPDK="$MAIN_MSQUIC/deps/dpdk-install"
BUILD="$MAIN_MSQUIC/build-greenquic-p5"
DATAPATH="$REPO_ROOT/msquic-p5-source/src/platform/datapath_raw_dpdk_linux.c"
TRANSFORM="$HERE/apply_p5_super_performance.py"
REUSE="${P5_BUILD_REUSE:-1}"

P5_SUPER_CACHE="${P5_SUPER_CACHE:-128}"
P5_SUPER_RX_BURST="${P5_SUPER_RX_BURST:-32}"
P5_SUPER_TX_BURST="${P5_SUPER_TX_BURST:-16}"
P5_SUPER_RING_SIZE="${P5_SUPER_RING_SIZE:-4096}"
P5_SUPER_RING_SYNC="${P5_SUPER_RING_SYNC:-legacy}"
P5_SUPER_DRAIN_BURSTS="${P5_SUPER_DRAIN_BURSTS:-1}"
P5_SUPER_DRAIN_THRESHOLD="${P5_SUPER_DRAIN_THRESHOLD:-0}"
P5_SUPER_MTU="${P5_SUPER_MTU:-0}"
P5_SUPER_SKIP_OFF_RINGCOUNT="${P5_SUPER_SKIP_OFF_RINGCOUNT:-0}"
P5_SUPER_DEBUG_COUNTERS="${P5_SUPER_DEBUG_COUNTERS:-1}"
P5_SUPER_TRANSFER_WINDOW="${P5_SUPER_TRANSFER_WINDOW:-1}"
P5_SUPER_TRACE_RINGCOUNT="${P5_SUPER_TRACE_RINGCOUNT:-1}"
P5_SUPER_TX_META="${P5_SUPER_TX_META:-pool}"
P5_SUPER_RX_META="${P5_SUPER_RX_META:-pool}"
P5_SUPER_CAP_DIAG="${P5_SUPER_CAP_DIAG:-1}"

case "$REUSE" in 0|1) ;; *) echo "ERROR: P5_BUILD_REUSE must be 0 or 1" >&2; exit 2;; esac
[[ -d "$DPDK" ]] || { echo "ERROR: DPDK installation not found: $DPDK" >&2; exit 2; }
[[ -f "$TRANSFORM" ]] || { echo "ERROR: missing transformer $TRANSFORM" >&2; exit 2; }

echo "P5 SUPER PERFORMANCE BUILD"
echo "cache=$P5_SUPER_CACHE rxb=$P5_SUPER_RX_BURST txb=$P5_SUPER_TX_BURST ring=$P5_SUPER_RING_SIZE"
echo "sync=$P5_SUPER_RING_SYNC drain=$P5_SUPER_DRAIN_BURSTS threshold=$P5_SUPER_DRAIN_THRESHOLD mtu=$P5_SUPER_MTU"
echo "skip_off_ringcount=$P5_SUPER_SKIP_OFF_RINGCOUNT debug_counters=$P5_SUPER_DEBUG_COUNTERS transfer_window=$P5_SUPER_TRANSFER_WINDOW"
echo "trace_ringcount=$P5_SUPER_TRACE_RINGCOUNT tx_meta=$P5_SUPER_TX_META rx_meta=$P5_SUPER_RX_META cap_diag=$P5_SUPER_CAP_DIAG"
echo "GreenQUIC / GreenQUIC+ policy internals: unchanged"

P5_STATIC_PROFILE=native P5_BUILD_REUSE="$REUSE" bash "$HERE/build_p5_client.sh"

[[ -f "$DATAPATH" ]] || { echo "ERROR: disposable datapath missing: $DATAPATH" >&2; exit 2; }
if grep -Eq 'GREENQUIC-P5-(STATIC-PERF|RING-|ISO-|MAX-GOODPUT|SUPER-PERF)' "$DATAPATH"; then
    echo "ERROR: native restore did not clean previous performance markers" >&2
    exit 2
fi

python3 "$TRANSFORM" "$DATAPATH" \
    --cache "$P5_SUPER_CACHE" \
    --rx-burst "$P5_SUPER_RX_BURST" \
    --tx-burst "$P5_SUPER_TX_BURST" \
    --ring-size "$P5_SUPER_RING_SIZE" \
    --ring-sync "$P5_SUPER_RING_SYNC" \
    --drain-bursts "$P5_SUPER_DRAIN_BURSTS" \
    --drain-threshold "$P5_SUPER_DRAIN_THRESHOLD" \
    --mtu "$P5_SUPER_MTU" \
    --skip-off-ringcount "$P5_SUPER_SKIP_OFF_RINGCOUNT" \
    --debug-counters "$P5_SUPER_DEBUG_COUNTERS" \
    --transfer-window "$P5_SUPER_TRANSFER_WINDOW" \
    --trace-ringcount "$P5_SUPER_TRACE_RINGCOUNT" \
    --tx-meta "$P5_SUPER_TX_META" \
    --rx-meta "$P5_SUPER_RX_META" \
    --cap-diag "$P5_SUPER_CAP_DIAG"

python3 -m py_compile "$TRANSFORM"
grep -Fq 'GREENQUIC-P5-SUPER-PERF-V1' "$DATAPATH" || {
    echo "ERROR: super performance marker missing from generated datapath" >&2
    exit 2
}

export PKG_CONFIG_PATH="$DPDK/lib/pkgconfig:$DPDK/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LIBRARY_PATH="$DPDK/lib:$DPDK/lib/x86_64-linux-gnu${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LD_LIBRARY_PATH="$DPDK/lib:$DPDK/lib/x86_64-linux-gnu:$DPDK/lib/dpdk/pmds-22.0${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

cmake --build "$BUILD" \
    --target quicinterop quicinteropserver \
    --parallel "$(nproc)"

CLIENT="$BUILD/bin/Release/quicinterop"
SERVER="$BUILD/bin/Release/quicinteropserver"
test -x "$CLIENT"
test -x "$SERVER"

for bin in "$CLIENT" "$SERVER"; do
    grep -aFq -- 'GREENQUIC-P5-SUPER-PERF-V1' "$bin" || {
        echo "ERROR: super performance marker missing from $bin" >&2
        exit 2
    }
    for bad in \
        GREENQUIC-P5-ISO-TXRETRY1-V1 \
        GREENQUIC-P5-ISO-UDPCKSUM-V1 \
        GREENQUIC-P5-ISO-LOCKFREE-V1 \
        GREENQUIC-P5-ISO-COUNTERS-V1 \
        GREENQUIC-P5-ISO-RXALLOC4-V1 \
        GREENQUIC-P5-RING-HTS-GENERIC-V1 \
        GREENQUIC-P5-RING-MP-CLASSIC-V1 \
        GREENQUIC-P5-RING-RTS-GENERIC-V1 \
        GREENQUIC-P5-MAX-GOODPUT-V1; do
        if grep -aFq -- "$bad" "$bin"; then
            echo "ERROR: old performance experiment contaminated $bin: $bad" >&2
            exit 2
        fi
    done
done

echo
echo "P5 SUPER BUILD PASS"
echo "CLIENT: $(readlink -f "$CLIENT")"
sha256sum "$CLIENT"
echo "SERVER: $(readlink -f "$SERVER")"
sha256sum "$SERVER"
