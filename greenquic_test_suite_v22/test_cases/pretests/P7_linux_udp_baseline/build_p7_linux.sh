#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(cd -- "$HERE/../../../.." && pwd)"
MAIN_MSQUIC="$ROOT/msquic"
P5="$ROOT/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
SOURCE="$ROOT/msquic-p7-linux-source"
BUILD="$MAIN_MSQUIC/build-linux-p7"
CLIENT="$BUILD/bin/Release/quicinterop"
SERVER="$BUILD/bin/Release/quicinteropserver"

fail(){ echo "ERROR: $*" >&2; exit 1; }

[[ -d "$MAIN_MSQUIC" ]] || fail "MsQuic source not found: $MAIN_MSQUIC"
[[ -f "$P5/apply_p5_sequence.py" ]] || fail "P5 sequence transform missing"
[[ -f "$HERE/apply_p7_linux_instrumentation.py" ]] || fail "P7 transform missing"

rm -rf "$SOURCE" "$BUILD"
mkdir -p "$SOURCE"

tar -C "$MAIN_MSQUIC" \
    --exclude='./.git' \
    --exclude='./build*' \
    --exclude='./deps/dpdk-install' \
    -cf - . | tar -C "$SOURCE" -xf -

python3 "$P5/apply_p5_sequence.py" "$SOURCE/src/tools/interop/interop.cpp"
python3 "$HERE/apply_p7_linux_instrumentation.py" "$SOURCE"

grep -Fq -- 'GreenQUIC-P5-SEQUENCE-V2' "$SOURCE/src/tools/interop/interop.cpp"
grep -Fq -- 'GREENQUIC-P7-SERVER-TIMELINE-V1' "$SOURCE/src/tools/interopserver/InteropServer.cpp"
grep -Fq -- 'GREENQUIC-P7-SERVER-TIMELINE-V1' "$SOURCE/src/tools/interopserver/InteropServer.h"
grep -Fq -- 'GREENQUIC-P7-LINUX-UDP-FEATURE-OBSERVE-V1' "$SOURCE/src/platform/datapath_epoll.c"
grep -Fq -- 'GREENQUIC-P7-NO-DPDK-HEADER-LEAK-V1' "$SOURCE/src/platform/datapath_raw.h"
grep -Fq -- 'GREENQUIC-P7-NORMAL-LINUX-SOCKET-V1' "$SOURCE/src/platform/datapath_xplat.c"
! grep -Fq -- '<rte_memcpy.h>' "$SOURCE/src/platform/datapath_raw.h"

cmake -S "$SOURCE" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DQUIC_TLS=openssl \
    -DQUIC_BUILD_SHARED=OFF \
    -DQUIC_BUILD_TOOLS=ON \
    -DQUIC_BUILD_TEST=OFF \
    -DQUIC_BUILD_PERF=OFF \
    -DQUIC_LINUX_DPDK_ENABLED=OFF \
    -DQUIC_LINUX_XDP_ENABLED=OFF

cmake --build "$BUILD" \
    --target quicinterop quicinteropserver \
    --parallel "$(nproc)"

[[ -x "$CLIENT" ]] || fail "P7 client was not built: $CLIENT"
[[ -x "$SERVER" ]] || fail "P7 server was not built: $SERVER"

grep -aFq -- 'GreenQUIC-P5-SEQUENCE-V2' "$CLIENT" || fail "client lacks P5-equivalent sequence marker"
grep -aFq -- 'ready_for_start_gate_us=' "$CLIENT" || fail "client lacks start gate"
grep -aFq -- 'GreenQUIC-P7' "$SERVER" || fail "server lacks P7 local phase marker"
grep -aFq -- 'linux_udp_features' "$CLIENT" || fail "client lacks Linux UDP feature marker"
grep -aFq -- 'linux_udp_features' "$SERVER" || fail "server lacks Linux UDP feature marker"

if command -v ldd >/dev/null 2>&1; then
    if ldd "$CLIENT" 2>/dev/null | grep -qi dpdk; then
        fail "P7 client unexpectedly links a DPDK library"
    fi
    if ldd "$SERVER" 2>/dev/null | grep -qi dpdk; then
        fail "P7 server unexpectedly links a DPDK library"
    fi
fi

cat <<OUT
P7 Linux build PASS
SOURCE: $SOURCE
CLIENT: $CLIENT
SERVER: $SERVER
The build uses datapath_linux.c + datapath_epoll.c; DPDK and XDP are disabled.
OUT
sha256sum "$CLIENT" "$SERVER"
