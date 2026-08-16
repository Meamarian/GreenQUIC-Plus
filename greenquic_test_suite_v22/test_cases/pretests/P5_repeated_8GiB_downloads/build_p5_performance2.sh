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
P2_V2_TRANSFORM="$HERE/apply_p5_performance2_v2.py"
P2_V2_SELFTEST="$HERE/test_p5_performance2_v2_transform.py"

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

# Performance2 V1 switches.
P5_P2_DIAG_INTERVAL_US="${P5_P2_DIAG_INTERVAL_US:-0}"
P5_P2_DIAG_DURATION_MS="${P5_P2_DIAG_DURATION_MS:-3000}"
P5_P2_TX_HANDOFF="${P5_P2_TX_HANDOFF:-shared}"
P5_P2_TX_PRODUCER_RING_SIZE="${P5_P2_TX_PRODUCER_RING_SIZE:-1024}"
P5_P2_RX_PREFETCH="${P5_P2_RX_PREFETCH:-0}"
P5_P2_UDP_SEG="${P5_P2_UDP_SEG:-0}"
P5_P2_UDP_SEG_MAX="${P5_P2_UDP_SEG_MAX:-4}"

# Performance2 V2 switches. Defaults reproduce the existing P2 baseline.
P5_P2_TX_ALLOC_BATCH="${P5_P2_TX_ALLOC_BATCH:-1}"
P5_P2_TX_ENQUEUE_COUNTER="${P5_P2_TX_ENQUEUE_COUNTER:-1}"
P5_P2_TX_META_ZERO="${P5_P2_TX_META_ZERO:-1}"
P5_P2_RX_PIPE_PREFETCH="${P5_P2_RX_PIPE_PREFETCH:-0}"
P5_P2_SHARD_ACTIVE_MASK="${P5_P2_SHARD_ACTIVE_MASK:-0}"

case "$P5_P2_TX_HANDOFF" in shared|sharded) ;; *) echo "ERROR: P5_P2_TX_HANDOFF must be shared|sharded" >&2; exit 2;; esac
case "$P5_P2_RX_PREFETCH" in 0|1) ;; *) echo "ERROR: P5_P2_RX_PREFETCH must be 0|1" >&2; exit 2;; esac
case "$P5_P2_UDP_SEG" in 0|1) ;; *) echo "ERROR: P5_P2_UDP_SEG must be 0|1" >&2; exit 2;; esac
[[ "$P5_P2_DIAG_INTERVAL_US" =~ ^[0-9]+$ ]] || { echo "ERROR: P5_P2_DIAG_INTERVAL_US must be >=0" >&2; exit 2; }
[[ "$P5_P2_DIAG_DURATION_MS" =~ ^[0-9]+$ ]] || { echo "ERROR: P5_P2_DIAG_DURATION_MS must be >=0" >&2; exit 2; }
case "$P5_P2_TX_PRODUCER_RING_SIZE" in 256|512|1024|2048|4096) ;; *) echo "ERROR: invalid producer ring size" >&2; exit 2;; esac
case "$P5_P2_UDP_SEG_MAX" in 2|4|8) ;; *) echo "ERROR: P5_P2_UDP_SEG_MAX must be 2|4|8" >&2; exit 2;; esac
case "$P5_P2_TX_ALLOC_BATCH" in 1|8|16|32) ;; *) echo "ERROR: P5_P2_TX_ALLOC_BATCH must be 1|8|16|32" >&2; exit 2;; esac
case "$P5_P2_TX_ENQUEUE_COUNTER" in 0|1) ;; *) echo "ERROR: P5_P2_TX_ENQUEUE_COUNTER must be 0|1" >&2; exit 2;; esac
case "$P5_P2_TX_META_ZERO" in 0|1) ;; *) echo "ERROR: P5_P2_TX_META_ZERO must be 0|1" >&2; exit 2;; esac
case "$P5_P2_RX_PIPE_PREFETCH" in 0|2|4) ;; *) echo "ERROR: P5_P2_RX_PIPE_PREFETCH must be 0|2|4" >&2; exit 2;; esac
case "$P5_P2_SHARD_ACTIVE_MASK" in 0|1) ;; *) echo "ERROR: P5_P2_SHARD_ACTIVE_MASK must be 0|1" >&2; exit 2;; esac

if [[ "$P5_P2_UDP_SEG" == 1 && "$P5_SUPER_TX_META" != mbuf ]]; then
    echo "ERROR: UDP segmentation requires P5_SUPER_TX_META=mbuf for safe logical-segment metadata." >&2
    exit 2
fi
if [[ "$P5_P2_UDP_SEG" == 1 && "$P5_SUPER_TRANSFER_WINDOW" != 1 ]]; then
    echo "ERROR: performance2 UDP segmentation currently requires P5_SUPER_TRANSFER_WINDOW=1 so logical transfer counters remain validated." >&2
    exit 2
fi
if [[ "$P5_P2_TX_ALLOC_BATCH" != 1 && "$P5_SUPER_TX_META" != mbuf ]]; then
    echo "ERROR: P5_P2_TX_ALLOC_BATCH>1 is validated only with P5_SUPER_TX_META=mbuf." >&2
    exit 2
fi
if [[ "$P5_P2_TX_META_ZERO" == 0 && "$P5_SUPER_TX_META" != mbuf ]]; then
    echo "ERROR: P5_P2_TX_META_ZERO=0 requires P5_SUPER_TX_META=mbuf." >&2
    exit 2
fi
if [[ "$P5_P2_RX_PIPE_PREFETCH" != 0 && "$P5_P2_RX_PREFETCH" == 1 ]]; then
    echo "ERROR: P5_P2_RX_PIPE_PREFETCH requires P5_P2_RX_PREFETCH=0." >&2
    exit 2
fi
if [[ "$P5_P2_SHARD_ACTIVE_MASK" == 1 && "$P5_P2_TX_HANDOFF" != sharded ]]; then
    echo "ERROR: P5_P2_SHARD_ACTIVE_MASK=1 requires P5_P2_TX_HANDOFF=sharded." >&2
    exit 2
fi
if [[ "$P5_P2_TX_META_ZERO" == 0 && "$P5_P2_UDP_SEG" == 1 ]]; then
    echo "ERROR: P5_P2_TX_META_ZERO=0 is intentionally disabled with experimental UDP segmentation." >&2
    exit 2
fi

for f in "$BASE_BUILD" "$P2_TRANSFORM" "$P2_SELFTEST" "$P2_V2_TRANSFORM" "$P2_V2_SELFTEST"; do
    [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 2; }
done
[[ -d "$DPDK" ]] || { echo "ERROR: DPDK install missing: $DPDK" >&2; exit 2; }

echo "======================================================================"
echo "P5 PERFORMANCE2 BUILD"
echo "Base measured performance: cache=$P5_SUPER_CACHE RX=$P5_SUPER_RX_BURST TX=$P5_SUPER_TX_BURST ring=$P5_SUPER_RING_SIZE drain=$P5_SUPER_DRAIN_BURSTS"
echo "P2 V1: diag_us=$P5_P2_DIAG_INTERVAL_US handoff=$P5_P2_TX_HANDOFF producer_ring=$P5_P2_TX_PRODUCER_RING_SIZE rx_prefetch=$P5_P2_RX_PREFETCH udp_seg=$P5_P2_UDP_SEG udp_seg_max=$P5_P2_UDP_SEG_MAX"
echo "P2 V2: tx_alloc_batch=$P5_P2_TX_ALLOC_BATCH tx_enqueue_counter=$P5_P2_TX_ENQUEUE_COUNTER tx_meta_zero=$P5_P2_TX_META_ZERO rx_pipe_prefetch=$P5_P2_RX_PIPE_PREFETCH shard_active_mask=$P5_P2_SHARD_ACTIVE_MASK"
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

python3 "$P2_V2_TRANSFORM" "$DATAPATH" \
    --tx-alloc-batch "$P5_P2_TX_ALLOC_BATCH" \
    --tx-enqueue-counter "$P5_P2_TX_ENQUEUE_COUNTER" \
    --tx-meta-zero "$P5_P2_TX_META_ZERO" \
    --rx-pipe-prefetch "$P5_P2_RX_PIPE_PREFETCH" \
    --shard-active-mask "$P5_P2_SHARD_ACTIVE_MASK"

python3 -m py_compile "$P2_TRANSFORM" "$P2_SELFTEST" "$P2_V2_TRANSFORM" "$P2_V2_SELFTEST"
python3 "$P2_SELFTEST"
python3 "$P2_V2_SELFTEST"

grep -Fq 'GREENQUIC-P5-PERFORMANCE2-V1' "$DATAPATH" || { echo "ERROR: P2 V1 source marker missing" >&2; exit 2; }
grep -Fq 'GREENQUIC-P5-PERFORMANCE2-V2' "$DATAPATH" || { echo "ERROR: P2 V2 source marker missing" >&2; exit 2; }
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
if (( P5_P2_TX_ALLOC_BATCH > 1 )); then
    grep -Fq 'GreenQuicP2V2TxMbufAlloc' "$DATAPATH" || { echo "ERROR: P2 V2 TX bulk-refill allocator missing" >&2; exit 2; }
fi
if [[ "$P5_P2_TX_ENQUEUE_COUNTER" == 0 ]]; then
    ! grep -Fq 'Dpdk->TxEnqueueCounter++;' "$DATAPATH" || { echo "ERROR: producer TxEnqueueCounter write still present" >&2; exit 2; }
fi
if [[ "$P5_P2_TX_META_ZERO" == 0 ]]; then
    ! grep -Fq 'CxPlatZeroMemory(Packet, sizeof(*Packet));' "$DATAPATH" || { echo "ERROR: TX metadata whole-struct zero still present" >&2; exit 2; }
fi
if (( P5_P2_RX_PIPE_PREFETCH > 0 )); then
    grep -Fq 'GreenQuicP2V2PrefetchIndex' "$DATAPATH" || { echo "ERROR: pipelined RX prefetch missing" >&2; exit 2; }
fi
if [[ "$P5_P2_SHARD_ACTIVE_MASK" == 1 ]]; then
    grep -Fq 'GreenQuicP2V2TxActiveMask' "$DATAPATH" || { echo "ERROR: sharded active mask missing" >&2; exit 2; }
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
    grep -aFq -- 'GREENQUIC-P5-PERFORMANCE2-V1' "$bin" || { echo "ERROR: P2 V1 marker missing from $bin" >&2; exit 2; }
    grep -aFq -- 'GREENQUIC-P5-PERFORMANCE2-V2' "$bin" || { echo "ERROR: P2 V2 marker missing from $bin" >&2; exit 2; }
done

echo "P5 PERFORMANCE2 BUILD PASS"
grep -ao 'GREENQUIC-P5-PERFORMANCE2-V1[^[:cntrl:]]*' "$CLIENT" | head -1 || true
grep -ao 'GREENQUIC-P5-PERFORMANCE2-V2[^[:cntrl:]]*' "$CLIENT" | head -1 || true
sha256sum "$CLIENT" "$SERVER"
