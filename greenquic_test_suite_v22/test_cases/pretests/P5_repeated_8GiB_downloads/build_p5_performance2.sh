#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$HERE/../../../.." && pwd)"
MAIN_MSQUIC="$REPO_ROOT/msquic"
DPDK="$MAIN_MSQUIC/deps/dpdk-install"
BUILD="$MAIN_MSQUIC/build-greenquic-p5"
DATAPATH="$REPO_ROOT/msquic-p5-source/src/platform/datapath_raw_dpdk_linux.c"
BASE_BUILD="$HERE/build_p5_super_performance.sh"
P2_TRANSFORM="$HERE/apply_p5_performance2.py"
P2_SELFTEST="$HERE/test_p5_performance2_transform.py"

P5_SUPER_CACHE="${P5_SUPER_CACHE:-128}"
P5_SUPER_RX_BURST="${P5_SUPER_RX_BURST:-32}"
P5_SUPER_TX_BURST="${P5_SUPER_TX_BURST:-16}"
P5_SUPER_RING_SIZE="${P5_SUPER_RING_SIZE:-4096}"
P5_SUPER_RING_SYNC="${P5_SUPER_RING_SYNC:-legacy}"
P5_SUPER_DRAIN_BURSTS="${P5_SUPER_DRAIN_BURSTS:-2}"
P5_SUPER_DRAIN_THRESHOLD="${P5_SUPER_DRAIN_THRESHOLD:-0}"
P5_SUPER_MTU="${P5_SUPER_MTU:-0}"
P5_SUPER_SKIP_OFF_RINGCOUNT="${P5_SUPER_SKIP_OFF_RINGCOUNT:-0}"
P5_SUPER_DEBUG_COUNTERS="${P5_SUPER_DEBUG_COUNTERS:-1}"
P5_SUPER_TRANSFER_WINDOW="${P5_SUPER_TRANSFER_WINDOW:-1}"
P5_SUPER_TRACE_RINGCOUNT="${P5_SUPER_TRACE_RINGCOUNT:-1}"
P5_SUPER_TX_META="${P5_SUPER_TX_META:-mbuf}"
P5_SUPER_RX_META="${P5_SUPER_RX_META:-mbuf}"
P5_SUPER_TX_LOCK_MODE="${P5_SUPER_TX_LOCK_MODE:-single_owner}"
P5_SUPER_CAP_DIAG="${P5_SUPER_CAP_DIAG:-1}"

P5_P2_DIAG_INTERVAL_US="${P5_P2_DIAG_INTERVAL_US:-0}"
P5_P2_DIAG_DURATION_MS="${P5_P2_DIAG_DURATION_MS:-3000}"
P5_P2_TX_HANDOFF="${P5_P2_TX_HANDOFF:-shared}"
P5_P2_TX_PRODUCER_RING_SIZE="${P5_P2_TX_PRODUCER_RING_SIZE:-1024}"
P5_P2_RX_PREFETCH="${P5_P2_RX_PREFETCH:-0}"
P5_P2_UDP_SEG="${P5_P2_UDP_SEG:-0}"
P5_P2_UDP_SEG_MAX="${P5_P2_UDP_SEG_MAX:-4}"

case "$P5_P2_TX_HANDOFF" in shared|sharded) ;; *) echo "ERROR: P5_P2_TX_HANDOFF must be shared|sharded" >&2; exit 2;; esac
case "$P5_P2_RX_PREFETCH" in 0|1) ;; *) echo "ERROR: P5_P2_RX_PREFETCH must be 0|1" >&2; exit 2;; esac
case "$P5_P2_UDP_SEG" in 0|1) ;; *) echo "ERROR: P5_P2_UDP_SEG must be 0|1" >&2; exit 2;; esac
[[ "$P5_P2_DIAG_INTERVAL_US" =~ ^[0-9]+$ ]] || { echo "ERROR: P5_P2_DIAG_INTERVAL_US must be >=0" >&2; exit 2; }
[[ "$P5_P2_DIAG_DURATION_MS" =~ ^[0-9]+$ ]] || { echo "ERROR: P5_P2_DIAG_DURATION_MS must be >=0" >&2; exit 2; }
case "$P5_P2_TX_PRODUCER_RING_SIZE" in 256|512|1024|2048|4096) ;; *) echo "ERROR: invalid producer ring size" >&2; exit 2;; esac
case "$P5_P2_UDP_SEG_MAX" in 2|4|8) ;; *) echo "ERROR: P5_P2_UDP_SEG_MAX must be 2|4|8" >&2; exit 2;; esac
if [[ "$P5_P2_UDP_SEG" == 1 && "$P5_SUPER_TX_META" != mbuf ]]; then
    echo "ERROR: UDP segmentation requires P5_SUPER_TX_META=mbuf for safe logical-segment metadata." >&2
    exit 2
fi
if [[ "$P5_P2_UDP_SEG" == 1 && "$P5_SUPER_TRANSFER_WINDOW" != 1 ]]; then
    echo "ERROR: performance2 UDP segmentation currently requires P5_SUPER_TRANSFER_WINDOW=1 so logical transfer counters remain validated." >&2
    exit 2
fi

[[ -x "$BASE_BUILD" || -f "$BASE_BUILD" ]] || { echo "ERROR: missing $BASE_BUILD" >&2; exit 2; }
[[ -f "$P2_TRANSFORM" ]] || { echo "ERROR: missing $P2_TRANSFORM" >&2; exit 2; }
[[ -f "$P2_SELFTEST" ]] || { echo "ERROR: missing $P2_SELFTEST" >&2; exit 2; }
[[ -d "$DPDK" ]] || { echo "ERROR: DPDK install missing: $DPDK" >&2; exit 2; }

echo "======================================================================"
echo "P5 PERFORMANCE2 BUILD"
echo "Base measured performance: cache=$P5_SUPER_CACHE RX=$P5_SUPER_RX_BURST TX=$P5_SUPER_TX_BURST ring=$P5_SUPER_RING_SIZE drain=$P5_SUPER_DRAIN_BURSTS"
echo "P2: diag_us=$P5_P2_DIAG_INTERVAL_US diag_ms=$P5_P2_DIAG_DURATION_MS handoff=$P5_P2_TX_HANDOFF producer_ring=$P5_P2_TX_PRODUCER_RING_SIZE rx_prefetch=$P5_P2_RX_PREFETCH udp_seg=$P5_P2_UDP_SEG udp_seg_max=$P5_P2_UDP_SEG_MAX"
echo "GreenQUIC / GreenQUIC+ policy thresholds, hints, DVFS and idle algorithms: unchanged"
echo "======================================================================"

env \
    P5_BUILD_REUSE="${P5_BUILD_REUSE:-1}" \
    P5_SUPER_CACHE="$P5_SUPER_CACHE" \
    P5_SUPER_RX_BURST="$P5_SUPER_RX_BURST" \
    P5_SUPER_TX_BURST="$P5_SUPER_TX_BURST" \
    P5_SUPER_RING_SIZE="$P5_SUPER_RING_SIZE" \
    P5_SUPER_RING_SYNC="$P5_SUPER_RING_SYNC" \
    P5_SUPER_DRAIN_BURSTS="$P5_SUPER_DRAIN_BURSTS" \
    P5_SUPER_DRAIN_THRESHOLD="$P5_SUPER_DRAIN_THRESHOLD" \
    P5_SUPER_MTU="$P5_SUPER_MTU" \
    P5_SUPER_SKIP_OFF_RINGCOUNT="$P5_SUPER_SKIP_OFF_RINGCOUNT" \
    P5_SUPER_DEBUG_COUNTERS="$P5_SUPER_DEBUG_COUNTERS" \
    P5_SUPER_TRANSFER_WINDOW="$P5_SUPER_TRANSFER_WINDOW" \
    P5_SUPER_TRACE_RINGCOUNT="$P5_SUPER_TRACE_RINGCOUNT" \
    P5_SUPER_TX_META="$P5_SUPER_TX_META" \
    P5_SUPER_RX_META="$P5_SUPER_RX_META" \
    P5_SUPER_TX_LOCK_MODE="$P5_SUPER_TX_LOCK_MODE" \
    P5_SUPER_CAP_DIAG="$P5_SUPER_CAP_DIAG" \
    bash "$BASE_BUILD"

[[ -f "$DATAPATH" ]] || { echo "ERROR: disposable datapath missing: $DATAPATH" >&2; exit 2; }
python3 "$P2_TRANSFORM" "$DATAPATH" \
    --diag-interval-us "$P5_P2_DIAG_INTERVAL_US" \
    --diag-duration-ms "$P5_P2_DIAG_DURATION_MS" \
    --tx-handoff "$P5_P2_TX_HANDOFF" \
    --tx-producer-ring-size "$P5_P2_TX_PRODUCER_RING_SIZE" \
    --rx-prefetch "$P5_P2_RX_PREFETCH" \
    --udp-seg "$P5_P2_UDP_SEG" \
    --udp-seg-max "$P5_P2_UDP_SEG_MAX"
python3 -m py_compile "$P2_TRANSFORM" "$P2_SELFTEST"
python3 "$P2_SELFTEST"

grep -Fq 'GREENQUIC-P5-PERFORMANCE2-V1' "$DATAPATH" || { echo "ERROR: P2 source marker missing" >&2; exit 2; }
if [[ "$P5_P2_TX_HANDOFF" == sharded ]]; then
    grep -Fq 'GreenQuicP2TxDequeueBurst' "$DATAPATH" || { echo "ERROR: sharded TX helper missing" >&2; exit 2; }
fi
if [[ "$P5_P2_RX_PREFETCH" == 1 ]]; then
    grep -Fq 'GreenQuicP2PrefetchIndex' "$DATAPATH" || { echo "ERROR: RX prefetch helper missing" >&2; exit 2; }
fi
if [[ "$P5_P2_UDP_SEG" == 1 ]]; then
    grep -Fq 'GreenQuicP2UdpSegCoalesce' "$DATAPATH" || { echo "ERROR: UDP segmentation helper missing" >&2; exit 2; }
    grep -Fq 'GreenQuicP2LogicalPerPhysical' "$DATAPATH" || { echo "ERROR: logical UDP segment accounting missing" >&2; exit 2; }
fi
if (( P5_P2_DIAG_INTERVAL_US > 0 )); then
    grep -Fq '[P5-PERF2-DIAG]' "$DATAPATH" || { echo "ERROR: startup diagnostic helper missing" >&2; exit 2; }
fi

export PKG_CONFIG_PATH="$DPDK/lib/pkgconfig:$DPDK/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LIBRARY_PATH="$DPDK/lib:$DPDK/lib/x86_64-linux-gnu${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LD_LIBRARY_PATH="$DPDK/lib:$DPDK/lib/x86_64-linux-gnu:$DPDK/lib/dpdk/pmds-22.0${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
cmake --build "$BUILD" --target quicinterop quicinteropserver --parallel "$(nproc)"

CLIENT="$BUILD/bin/Release/quicinterop"
SERVER="$BUILD/bin/Release/quicinteropserver"
for bin in "$CLIENT" "$SERVER"; do
    test -x "$bin"
    grep -aFq -- 'GREENQUIC-P5-SUPER-PERF-V2' "$bin" || { echo "ERROR: base performance marker missing from $bin" >&2; exit 2; }
    grep -aFq -- 'GREENQUIC-P5-PERFORMANCE2-V1' "$bin" || { echo "ERROR: performance2 marker missing from $bin" >&2; exit 2; }
done

echo "P5 PERFORMANCE2 BUILD PASS"
grep -ao 'GREENQUIC-P5-PERFORMANCE2-V1[^[:cntrl:]]*' "$CLIENT" | head -1 || true
sha256sum "$CLIENT" "$SERVER"
