#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$HERE/../../../.." && pwd)"
BASE="$HERE/build_p7_linux.sh"
TRANSFORM="$HERE/../P5_repeated_8GiB_downloads/apply_p5_parallel_connections.py"
SOURCE="$REPO_ROOT/msquic-p7-linux-source/src/tools/interop/interop.cpp"
BUILD="$REPO_ROOT/msquic/build-linux-p7"

[[ -f "$BASE" && -f "$TRANSFORM" ]] || { echo "ERROR: P7 parallel build dependency missing" >&2; exit 2; }
bash "$BASE"
[[ -f "$SOURCE" ]] || { echo "ERROR: P7 disposable interop source missing: $SOURCE" >&2; exit 2; }
python3 "$TRANSFORM" "$SOURCE"
python3 -m py_compile "$TRANSFORM"
cmake --build "$BUILD" --target quicinterop quicinteropserver --parallel "$(nproc)"
CLIENT="$BUILD/bin/Release/quicinterop"; SERVER="$BUILD/bin/Release/quicinteropserver"
for bin in "$CLIENT" "$SERVER"; do [[ -x "$bin" ]] || { echo "ERROR: missing $bin" >&2; exit 2; }; done
for marker in GREENQUIC-P5-PARALLEL-CONNECTIONS-V1 GQ_INTEROP_P5_LOCAL_PORT_BASE; do
    grep -aFq -- "$marker" "$CLIENT" || { echo "ERROR: $marker missing from P7 client" >&2; exit 2; }
done
# P7 must remain normal Linux, not DPDK.
! grep -aFq -- GREENQUIC-P5-MULTICORE-TXQ-V1 "$CLIENT" || { echo "ERROR: DPDK multicore marker leaked into P7" >&2; exit 2; }
echo "P7 PARALLEL MULTICORE-COMPARISON BUILD PASS"
sha256sum "$CLIENT" "$SERVER"
