#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$HERE/../../../.." && pwd)"
MAIN_MSQUIC="$REPO_ROOT/msquic"
P5_SOURCE="$REPO_ROOT/msquic-p5-source"
DPDK="$MAIN_MSQUIC/deps/dpdk-install"
BUILD="$MAIN_MSQUIC/build-greenquic-p5"
TRANSFORM="$HERE/apply_p5_sequence.py"
RESULTS_FIX="$HERE/apply_p5_datapath_fix.py"
SOURCE="$P5_SOURCE/src/tools/interop/interop.cpp"

[[ -d "$MAIN_MSQUIC" ]] || {
    echo "ERROR: MsQuic source not found: $MAIN_MSQUIC" >&2
    exit 2
}
[[ -d "$DPDK" ]] || {
    echo "ERROR: DPDK installation not found: $DPDK" >&2
    exit 2
}
[[ -f "$TRANSFORM" ]] || {
    echo "ERROR: P5 source transformer not found: $TRANSFORM" >&2
    exit 2
}
[[ -f "$RESULTS_FIX" ]] || {
    echo "ERROR: P5 datapath transformer not found: $RESULTS_FIX" >&2
    exit 2
}

# Keep the main msquic source and build-greenquic binaries unchanged. Create a
# separate P5 source copy and a separate P5 build directory.
rm -rf "$P5_SOURCE" "$BUILD"
mkdir -p "$P5_SOURCE"

tar -C "$MAIN_MSQUIC" \
    --exclude='./.git' \
    --exclude='./build*' \
    --exclude='./deps/dpdk-install' \
    -cf - . |
tar -C "$P5_SOURCE" -xf -

mkdir -p "$P5_SOURCE/deps"
ln -s "$DPDK" "$P5_SOURCE/deps/dpdk-install"

python3 "$TRANSFORM" "$SOURCE"
python3 "$RESULTS_FIX" "$P5_SOURCE/src/platform/datapath_raw_dpdk_linux.c"

grep -Fq 'GreenQUIC-P5-SEQUENCE-V2' "$SOURCE" || {
    echo "ERROR: P5 V2 source marker was not added: $SOURCE" >&2
    exit 2
}
grep -Fq 'SendHttpRequestsP5Sequential' "$SOURCE" || {
    echo "ERROR: sequential P5 request method was not added: $SOURCE" >&2
    exit 2
}
grep -Fq 'Feature == StreamData && GreenQuicP5SequenceEnabled()' "$SOURCE" || {
    echo "ERROR: P5 StreamData execution hook was not added: $SOURCE" >&2
    exit 2
}
grep -Fq 'GREENQUIC-P5-DATAPATH-PACKET-TOTALS-V1' \
    "$P5_SOURCE/src/platform/datapath_raw_dpdk_linux.c" || {
    echo "ERROR: P5 packet-total teardown marker was not added" >&2
    exit 2
}

export PKG_CONFIG_PATH="$DPDK/lib/pkgconfig:$DPDK/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LIBRARY_PATH="$DPDK/lib:$DPDK/lib/x86_64-linux-gnu${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LD_LIBRARY_PATH="$DPDK/lib:$DPDK/lib/x86_64-linux-gnu:$DPDK/lib/dpdk/pmds-22.0${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

cmake -S "$P5_SOURCE" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DQUIC_TLS=openssl \
    -DQUIC_BUILD_SHARED=OFF \
    -DQUIC_BUILD_TOOLS=ON \
    -DQUIC_BUILD_TEST=OFF \
    -DQUIC_BUILD_PERF=OFF \
    -DQUIC_LINUX_DPDK_ENABLED=ON

cmake --build "$BUILD" \
    --target quicinterop quicinteropserver \
    --parallel "$(nproc)"

BIN="$BUILD/bin/Release/quicinterop"
test -x "$BIN"
grep -aFq -- 'GreenQUIC-P5-SEQUENCE-V2' "$BIN" || {
    echo "ERROR: built binary does not contain the P5 V2 marker" >&2
    exit 2
}
grep -aFq -- 'ready_for_start_gate_us=' "$BIN" || {
    echo "ERROR: built binary does not contain the P5 start-gate marker" >&2
    exit 2
}
grep -aFq -- 'GreenQUIC PACKETS source=datapath_totals' "$BIN" || {
    echo "ERROR: built P5 client does not contain process-end packet totals" >&2
    exit 2
}

SERVER_BIN="$BUILD/bin/Release/quicinteropserver"
test -x "$SERVER_BIN"
grep -aFq -- 'GreenQUIC FINAL idle_mode=' "$SERVER_BIN" || {
    echo "ERROR: built P5 server does not contain final idle counter output" >&2
    exit 2
}
grep -aFq -- 'GreenQUIC PACKETS source=datapath_totals' "$SERVER_BIN" || {
    echo "ERROR: built P5 server does not contain process-end packet totals" >&2
    exit 2
}

echo
echo "P5 server binary:"
echo "PATH: $(readlink -f "$SERVER_BIN")"
sha256sum "$SERVER_BIN"

echo
echo "P5 client binary:"
echo "NAME: $(basename "$BIN")"
echo "PATH: $(readlink -f "$BIN")"
sha256sum "$BIN"
echo
echo "Main working binary was not modified:"
echo "$MAIN_MSQUIC/build-greenquic/bin/Release/quicinterop"
