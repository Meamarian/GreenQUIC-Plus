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
STATIC_PERF="$HERE/apply_p5_static_performance.py"
SOURCE="$P5_SOURCE/src/tools/interop/interop.cpp"
DATAPATH="$P5_SOURCE/src/platform/datapath_raw_dpdk_linux.c"
MAIN_DATAPATH="$MAIN_MSQUIC/src/platform/datapath_raw_dpdk_linux.c"
P5_STATIC_PROFILE="${P5_STATIC_PROFILE:-native}"
P5_BUILD_REUSE="${P5_BUILD_REUSE:-0}"

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
[[ -f "$MAIN_DATAPATH" ]] || {
    echo "ERROR: main DPDK datapath source not found: $MAIN_DATAPATH" >&2
    exit 2
}

case "$P5_BUILD_REUSE" in 0|1) ;; *) echo "ERROR: P5_BUILD_REUSE must be 0 or 1" >&2; exit 2;; esac
case "$P5_STATIC_PROFILE" in
    native) ;;
    burst64|rx64|tx64|burst128|cache128|cache512|desc2048|ring2048|ring8192|pool8191|cache128_pool8191)
        [[ -f "$STATIC_PERF" ]] || {
            echo "ERROR: P5 static performance transformer not found: $STATIC_PERF" >&2
            exit 2
        }
        ;;
    *)
        echo "ERROR: unknown P5_STATIC_PROFILE=$P5_STATIC_PROFILE" >&2
        exit 2
        ;;
esac

REUSE_ACTIVE=0
if [[ "$P5_BUILD_REUSE" == 1 && -f "$BUILD/CMakeCache.txt" && -f "$SOURCE" && -f "$DATAPATH" ]]; then
    if grep -Fq 'GreenQUIC-P5-SEQUENCE-V2' "$SOURCE"; then
        REUSE_ACTIVE=1
    fi
fi

if [[ "$REUSE_ACTIVE" == 0 ]]; then
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
    python3 "$RESULTS_FIX" "$DATAPATH"
    echo "P5 build source: clean isolated copy"
else
    cp -f "$MAIN_DATAPATH" "$DATAPATH"
    python3 "$RESULTS_FIX" "$DATAPATH"
    echo "P5 build source: incremental reuse; datapath restored from main before tuning"
fi

if [[ "$P5_STATIC_PROFILE" != native ]]; then
    python3 "$STATIC_PERF" "$P5_STATIC_PROFILE" "$DATAPATH"
fi

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
grep -Fq 'GREENQUIC-P5-DATAPATH-PACKET-TOTALS-V1' "$DATAPATH" || {
    echo "ERROR: P5 packet-total teardown marker was not added" >&2
    exit 2
}
grep -Fq 'GREENQUIC-P5-EPOLL-FD-INIT-FIX-V1' "$DATAPATH" || {
    echo "ERROR: P5 EPOLL fd initialization fix was not added" >&2
    exit 2
}
grep -Fq 'S->EpollInitialized && S->WakeEventFd >= 0' "$DATAPATH" || {
    echo "ERROR: P5 EPOLL wake-event guard was not added" >&2
    exit 2
}

if [[ "$P5_STATIC_PROFILE" == native ]]; then
    if grep -Fq 'GREENQUIC-P5-STATIC-PERF-V2' "$DATAPATH"; then
        echo "ERROR: native build was contaminated by static performance transform" >&2
        exit 2
    fi
    echo "P5 build profile: native (known-good datapath; no performance transform)"
else
    grep -Fq "GREENQUIC-P5-STATIC-PERF-V2 profile=$P5_STATIC_PROFILE" "$DATAPATH" || {
        echo "ERROR: requested static profile marker missing" >&2
        exit 2
    }
    echo "P5 build profile: static:$P5_STATIC_PROFILE"
fi

python3 -m py_compile "$TRANSFORM" "$RESULTS_FIX"
if [[ "$P5_STATIC_PROFILE" != native ]]; then
    python3 -m py_compile "$STATIC_PERF"
fi

export PKG_CONFIG_PATH="$DPDK/lib/pkgconfig:$DPDK/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LIBRARY_PATH="$DPDK/lib:$DPDK/lib/x86_64-linux-gnu${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LD_LIBRARY_PATH="$DPDK/lib:$DPDK/lib/x86_64-linux-gnu:$DPDK/lib/dpdk/pmds-22.0${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

if [[ "$REUSE_ACTIVE" == 0 ]]; then
    cmake -S "$P5_SOURCE" -B "$BUILD" \
        -DCMAKE_BUILD_TYPE=Release \
        -DQUIC_TLS=openssl \
        -DQUIC_BUILD_SHARED=OFF \
        -DQUIC_BUILD_TOOLS=ON \
        -DQUIC_BUILD_TEST=OFF \
        -DQUIC_BUILD_PERF=OFF \
        -DQUIC_LINUX_DPDK_ENABLED=ON
else
    echo "P5 build configure: reused existing CMake/OpenSSL build tree"
fi

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

for bad in \
    'P5_DPDK_UDP_CHECKSUM_OFFLOAD' \
    'P5_DPDK_TX_RETRIES' \
    'GREENQUIC-P5-MAX-GOODPUT-V1' \
    'P5 performance config:' \
    'P5 DPDK UDP offload:'; do
    if grep -aFq -- "$bad" "$BIN" || grep -aFq -- "$bad" "$SERVER_BIN"; then
        echo "ERROR: obsolete runtime performance marker found in binary: $bad" >&2
        exit 2
    fi
done

echo
echo "P5 server binary:"
echo "PROFILE: $P5_STATIC_PROFILE"
echo "REUSE: $REUSE_ACTIVE"
echo "PATH: $(readlink -f "$SERVER_BIN")"
sha256sum "$SERVER_BIN"

echo
echo "P5 client binary:"
echo "PROFILE: $P5_STATIC_PROFILE"
echo "REUSE: $REUSE_ACTIVE"
echo "NAME: $(basename "$BIN")"
echo "PATH: $(readlink -f "$BIN")"
sha256sum "$BIN"
echo
echo "Main working binary was not modified:"
echo "$MAIN_MSQUIC/build-greenquic/bin/Release/quicinterop"
