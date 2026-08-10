#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$HERE/../../../.." && pwd)"
MAIN_MSQUIC="$REPO_ROOT/msquic"
P6_SOURCE="$REPO_ROOT/msquic-p6-source"
DPDK="$MAIN_MSQUIC/deps/dpdk-install"
BUILD="$MAIN_MSQUIC/build-greenquic-p6"
SEQUENCE="$HERE/apply_p5_sequence.py"
DATAPATH_FIX="$HERE/apply_p5_datapath_fix.py"
P6_IMPAIRMENT="$HERE/apply_p6_impairment.py"
P6_CUBIC_CAP="$HERE/apply_p6_cubic_cap.py"
INTEROP_SOURCE="$P6_SOURCE/src/tools/interop/interop.cpp"
DPDK_LINUX_SOURCE="$P6_SOURCE/src/platform/datapath_raw_dpdk_linux.c"
CUBIC_SOURCE="$P6_SOURCE/src/core/cubic.c"

for f in "$SEQUENCE" "$DATAPATH_FIX" "$P6_IMPAIRMENT" "$P6_CUBIC_CAP"; do
    [[ -f "$f" ]] || { echo "ERROR: missing P6 transformer: $f" >&2; exit 2; }
done
[[ -d "$MAIN_MSQUIC" ]] || { echo "ERROR: MsQuic source not found: $MAIN_MSQUIC" >&2; exit 2; }
[[ -d "$DPDK" ]] || { echo "ERROR: DPDK installation not found: $DPDK" >&2; exit 2; }

# P6 is isolated. Never modify main MsQuic, P4 or P5 generated sources/builds.
rm -rf "$P6_SOURCE" "$BUILD"
mkdir -p "$P6_SOURCE"
tar -C "$MAIN_MSQUIC" \
    --exclude='./.git' \
    --exclude='./build*' \
    --exclude='./deps/dpdk-install' \
    -cf - . | tar -C "$P6_SOURCE" -xf -
mkdir -p "$P6_SOURCE/deps"
ln -s "$DPDK" "$P6_SOURCE/deps/dpdk-install"

# Reuse P6-local copies of the proven P5 transforms, then add the two P6-only
# mechanisms: exact-one-packet network loss and a runtime CUBIC window cap.
# P5/common/main MsQuic stay unchanged.
python3 "$SEQUENCE" "$INTEROP_SOURCE"
python3 "$DATAPATH_FIX" "$DPDK_LINUX_SOURCE"
python3 "$P6_IMPAIRMENT" "$DPDK_LINUX_SOURCE"
python3 "$P6_CUBIC_CAP" "$CUBIC_SOURCE"

grep -Fq 'GreenQUIC-P5-SEQUENCE-V2' "$INTEROP_SOURCE" || { echo "ERROR: P6 lacks sequential transfer base" >&2; exit 2; }
grep -Fq 'GREENQUIC-P5-DATAPATH-PACKET-TOTALS-V1' "$DPDK_LINUX_SOURCE" || { echo "ERROR: P6 lacks datapath packet totals" >&2; exit 2; }
grep -Fq 'GREENQUIC-P5-EPOLL-FD-INIT-FIX-V1' "$DPDK_LINUX_SOURCE" || { echo "ERROR: P6 lacks EPOLL fd initialization fix" >&2; exit 2; }
grep -Fq 'S->EpollInitialized && S->WakeEventFd >= 0' "$DPDK_LINUX_SOURCE" || { echo "ERROR: P6 lacks EPOLL wake-event guard" >&2; exit 2; }
grep -Fq 'GREENQUIC-P6-DETERMINISTIC-LOSS-V2' "$DPDK_LINUX_SOURCE" || { echo "ERROR: P6 Linux-DPDK impairment marker missing" >&2; exit 2; }
grep -Fq 'GREENQUIC-P6-EXACT-ONE-PACKET-LOSS-V1' "$DPDK_LINUX_SOURCE" || { echo "ERROR: P6 exact-one-packet loss marker missing" >&2; exit 2; }
grep -Fq 'GREENQUIC-P6-CUBIC-CWND-CAP-V1' "$CUBIC_SOURCE" || { echo "ERROR: P6 CUBIC cap marker missing" >&2; exit 2; }

export PKG_CONFIG_PATH="$DPDK/lib/pkgconfig:$DPDK/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LIBRARY_PATH="$DPDK/lib:$DPDK/lib/x86_64-linux-gnu${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LD_LIBRARY_PATH="$DPDK/lib:$DPDK/lib/x86_64-linux-gnu:$DPDK/lib/dpdk/pmds-22.0${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

cmake -S "$P6_SOURCE" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DQUIC_TLS=openssl \
    -DQUIC_BUILD_SHARED=OFF \
    -DQUIC_BUILD_TOOLS=ON \
    -DQUIC_BUILD_TEST=OFF \
    -DQUIC_BUILD_PERF=OFF \
    -DQUIC_LINUX_DPDK_ENABLED=ON
cmake --build "$BUILD" --target quicinterop quicinteropserver --parallel "$(nproc)"

CLIENT="$BUILD/bin/Release/quicinterop"
SERVER="$BUILD/bin/Release/quicinteropserver"
[[ -x "$CLIENT" && -x "$SERVER" ]] || { echo "ERROR: P6 binaries missing" >&2; exit 2; }
grep -aFq -- 'GreenQUIC-P5-SEQUENCE-V2' "$CLIENT" || { echo "ERROR: P6 client lacks sequential marker" >&2; exit 2; }
for marker in \
    'GREENQUIC-P6-DETERMINISTIC-LOSS-V2' \
    'GREENQUIC-P6-EXACT-ONE-PACKET-LOSS-V1' \
    'GREENQUIC-P6-CUBIC-CWND-CAP-V1'; do
    grep -aFq -- "$marker" "$CLIENT" || { echo "ERROR: P6 client lacks marker: $marker" >&2; exit 2; }
    grep -aFq -- "$marker" "$SERVER" || { echo "ERROR: P6 server lacks marker: $marker" >&2; exit 2; }
done
grep -aFq -- 'hint_cubic_cwnd_blocked=' "$SERVER" || { echo "ERROR: P6 server lacks CWND-blocked hint counter" >&2; exit 2; }
grep -aFq -- 'hint_cubic_recovery=' "$SERVER" || { echo "ERROR: P6 server lacks recovery hint counter" >&2; exit 2; }

# Negative isolation checks: none of the P6 markers may leak into tracked main
# MsQuic or an existing P5 generated source.
for marker in \
    'GREENQUIC-P6-DETERMINISTIC-LOSS-V2' \
    'GREENQUIC-P6-EXACT-ONE-PACKET-LOSS-V1' \
    'GREENQUIC-P6-CUBIC-CWND-CAP-V1'; do
    if grep -R -Fq -- "$marker" "$MAIN_MSQUIC/src"; then
        echo "ERROR: P6 marker leaked into main MsQuic source: $marker" >&2
        exit 2
    fi
    if [[ -d "$REPO_ROOT/msquic-p5-source/src" ]] && \
       grep -R -Fq -- "$marker" "$REPO_ROOT/msquic-p5-source/src"; then
        echo "ERROR: P6 marker leaked into P5 generated source: $marker" >&2
        exit 2
    fi
done

echo
echo "P6 server binary: $(readlink -f "$SERVER")"
sha256sum "$SERVER"
echo "P6 client binary: $(readlink -f "$CLIENT")"
sha256sum "$CLIENT"
echo "P6 isolated source: $P6_SOURCE"
echo "P5/main MsQuic isolation checks: PASS"
