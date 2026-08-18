#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$HERE/../../../.." && pwd)"
SUPER="$HERE/build_p5_super_performance.sh"
P2="$HERE/build_p5_performance2.sh"
PROFILE="${P5_11G_PROFILE:-p2}"
DRAIN="${P5_11G_DRAIN:-2}"
case "$PROFILE" in super|p2) ;; *) echo "ERROR: P5_11G_PROFILE must be super|p2" >&2; exit 2;; esac
[[ "$DRAIN" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: P5_11G_DRAIN must be positive" >&2; exit 2; }
for f in "$SUPER" "$P2"; do [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 2; }; done

BASE_ENV=(
  P5_BUILD_REUSE=1 P5_SUPER_CACHE=128 P5_SUPER_RX_BURST=32 P5_SUPER_TX_BURST=16
  P5_SUPER_RING_SIZE=4096 P5_SUPER_RING_SYNC=legacy P5_SUPER_DRAIN_BURSTS="$DRAIN"
  P5_SUPER_DRAIN_THRESHOLD=0 P5_SUPER_MTU=0 P5_SUPER_SKIP_OFF_RINGCOUNT=0
  P5_SUPER_DEBUG_COUNTERS=1 P5_SUPER_TRANSFER_WINDOW=1 P5_SUPER_TRACE_RINGCOUNT=1
  P5_SUPER_TX_META=mbuf P5_SUPER_RX_META=mbuf P5_SUPER_TX_LOCK_MODE=single_owner P5_SUPER_CAP_DIAG=1
)

echo "======================================================================"
echo "P5 ONE-CORE 11G CANDIDATE BUILD profile=$PROFILE drain=$DRAIN"
echo "======================================================================"
if [[ "$PROFILE" == super ]]; then
  env "${BASE_ENV[@]}" bash "$SUPER"
else
  env "${BASE_ENV[@]}" \
    P5_P2_DIAG_INTERVAL_US=0 \
    P5_P2_TX_HANDOFF=shared \
    P5_P2_RX_PREFETCH=0 \
    P5_P2_UDP_SEG=0 \
    P5_P2_TX_ALLOC_BATCH=8 \
    P5_P2_TX_ENQUEUE_COUNTER=0 \
    P5_P2_TX_META_ZERO=1 \
    P5_P2_RX_PIPE_PREFETCH=2 \
    P5_P2_SHARD_ACTIVE_MASK=0 \
    bash "$P2"
fi

BUILD="$REPO_ROOT/msquic/build-greenquic-p5/bin/Release"
for bin in "$BUILD/quicinterop" "$BUILD/quicinteropserver"; do
  test -x "$bin"
  grep -aFq -- 'GREENQUIC-P5-SUPER-PERF-V2' "$bin" || { echo "ERROR: Super marker missing: $bin" >&2; exit 2; }
  if [[ "$PROFILE" == p2 ]]; then
    grep -aFq -- 'GREENQUIC-P5-PERFORMANCE2-V1' "$bin" || { echo "ERROR: P2 V1 marker missing: $bin" >&2; exit 2; }
    grep -aFq -- 'GREENQUIC-P5-PERFORMANCE2-V2' "$bin" || { echo "ERROR: P2 V2 marker missing: $bin" >&2; exit 2; }
  fi
done
echo "P5 11G CANDIDATE BUILD PASS profile=$PROFILE drain=$DRAIN"
sha256sum "$BUILD/quicinterop" "$BUILD/quicinteropserver"
