#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(cd -- "$HERE/../../../.." && pwd)"
DPDK="$ROOT/msquic/deps/dpdk-install"
SRC="$ROOT/msquic-p5-source"
BUILD="$ROOT/msquic/build-greenquic-p5"
TRANSFORM_V2="$HERE/apply_p5_d1d2plus_snapshot.py"
TRANSFORM_V3="$HERE/apply_p5_d1d2plus_snapshot_v3.py"
BASE="$HERE/build_p5_performance2.sh"
MARK='GREENQUIC-P5-D1D2PLUS-SNAPSHOT-V3'
P2MARK='GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0'
[[ -f "$TRANSFORM_V2" && -f "$TRANSFORM_V3" ]] || { echo "ERROR: missing D1/D2+ transform" >&2; exit 2; }
[[ -f "$BASE" ]] || { echo "ERROR: missing $BASE" >&2; exit 2; }
python3 -m py_compile "$TRANSFORM_V2" "$TRANSFORM_V3"
# Recreate the exact promoted Performance2 source/binary first. The D1/D2+
# measurement transforms touch only the disposable P5 source tree.
P5_BUILD_REUSE="${P5_BUILD_REUSE:-1}" bash "$BASE"
python3 "$TRANSFORM_V2" \
  "$SRC/src/tools/interop/interop.cpp" \
  "$SRC/src/tools/interopserver/InteropServer.cpp" \
  "$SRC/src/tools/interopserver/InteropServer.h" \
  "$SRC/src/platform/datapath_raw_dpdk_linux.c"
python3 "$TRANSFORM_V3" \
  "$SRC/src/tools/interop/interop.cpp" \
  "$SRC/src/tools/interopserver/InteropServer.cpp" \
  "$SRC/src/tools/interopserver/InteropServer.h" \
  "$SRC/src/platform/datapath_raw_dpdk_linux.c"
export PKG_CONFIG_PATH="$DPDK/lib/pkgconfig:$DPDK/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LIBRARY_PATH="$DPDK/lib:$DPDK/lib/x86_64-linux-gnu${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LD_LIBRARY_PATH="$DPDK/lib:$DPDK/lib/x86_64-linux-gnu:$DPDK/lib/dpdk/pmds-22.0${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
cmake --build "$BUILD" --target quicinterop quicinteropserver --parallel "$(nproc)"
for bin in "$BUILD/bin/Release/quicinterop" "$BUILD/bin/Release/quicinteropserver"; do
  test -x "$bin"
  grep -aFq -- "$P2MARK" "$bin" || { echo "ERROR: promoted P2 marker missing: $bin" >&2; exit 3; }
  grep -aFq -- "$MARK" "$bin" || { echo "ERROR: D1/D2+ V3 marker missing: $bin" >&2; exit 3; }
done
echo "P5 PERFORMANCE2 D1/D2+ BUILD PASS"
echo "$MARK"
