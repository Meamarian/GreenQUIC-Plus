#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$HERE/../../../.." && pwd)"
MAIN_MSQUIC="$REPO_ROOT/msquic"
DPDK="$MAIN_MSQUIC/deps/dpdk-install"
BUILD="$MAIN_MSQUIC/build-greenquic-p5"
DATAPATH="$REPO_ROOT/msquic-p5-source/src/platform/datapath_raw_dpdk_linux.c"
TRANSFORM="$HERE/apply_p5_ring_experiment.py"
PROFILE="${1:-control}"
REUSE="${P5_BUILD_REUSE:-1}"

case "$PROFILE" in
    control|hts_generic|mp_classic|rts_generic|deq_generic|ring1024|ring2048|ring8192|txburst16|txburst64|txburst128) ;;
    *)
        echo "ERROR: unsupported ring profile: $PROFILE" >&2
        exit 2
        ;;
esac
case "$REUSE" in 0|1) ;; *) echo "ERROR: P5_BUILD_REUSE must be 0 or 1" >&2; exit 2;; esac

[[ -d "$DPDK" ]] || { echo "ERROR: DPDK installation not found: $DPDK" >&2; exit 2; }
[[ -f "$TRANSFORM" ]] || { echo "ERROR: missing $TRANSFORM" >&2; exit 2; }

echo "P5 ring build: base=cache128 profile=$PROFILE"
echo "P5 ring isolation: exactly one ring experiment; no other feature; GreenQUIC/GreenQUIC+ unchanged"

# This restores the disposable datapath from main and applies only cache128.
P5_STATIC_PROFILE=cache128 P5_BUILD_REUSE="$REUSE" bash "$HERE/build_p5_client.sh"

[[ -f "$DATAPATH" ]] || { echo "ERROR: generated datapath missing: $DATAPATH" >&2; exit 2; }
grep -Fq 'GREENQUIC-P5-STATIC-PERF-V2 profile=cache128 ' "$DATAPATH" || {
    echo "ERROR: cache128 baseline marker missing" >&2
    exit 2
}

markers=(
    GREENQUIC-P5-RING-HTS-GENERIC-V1
    GREENQUIC-P5-RING-MP-CLASSIC-V1
    GREENQUIC-P5-RING-RTS-GENERIC-V1
    GREENQUIC-P5-RING-DEQ-GENERIC-V1
    GREENQUIC-P5-RING-SIZE1024-V1
    GREENQUIC-P5-RING-SIZE2048-V1
    GREENQUIC-P5-RING-SIZE8192-V1
    GREENQUIC-P5-RING-TXBURST16-V1
    GREENQUIC-P5-RING-TXBURST64-V1
    GREENQUIC-P5-RING-TXBURST128-V1
)

expected=""
if [[ "$PROFILE" != control ]]; then
    python3 "$TRANSFORM" "$PROFILE" "$DATAPATH"
    python3 -m py_compile "$TRANSFORM"
    case "$PROFILE" in
        hts_generic) expected=GREENQUIC-P5-RING-HTS-GENERIC-V1 ;;
        mp_classic) expected=GREENQUIC-P5-RING-MP-CLASSIC-V1 ;;
        rts_generic) expected=GREENQUIC-P5-RING-RTS-GENERIC-V1 ;;
        deq_generic) expected=GREENQUIC-P5-RING-DEQ-GENERIC-V1 ;;
        ring1024) expected=GREENQUIC-P5-RING-SIZE1024-V1 ;;
        ring2048) expected=GREENQUIC-P5-RING-SIZE2048-V1 ;;
        ring8192) expected=GREENQUIC-P5-RING-SIZE8192-V1 ;;
        txburst16) expected=GREENQUIC-P5-RING-TXBURST16-V1 ;;
        txburst64) expected=GREENQUIC-P5-RING-TXBURST64-V1 ;;
        txburst128) expected=GREENQUIC-P5-RING-TXBURST128-V1 ;;
    esac
fi

# build_p5_client.sh exports these only within its own process.  Ring transforms
# happen afterwards, so export them again for this incremental relink.
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

for marker in "${markers[@]}"; do
    c=0; s=0
    grep -aFq -- "$marker" "$CLIENT" && c=1 || true
    grep -aFq -- "$marker" "$SERVER" && s=1 || true
    if [[ -n "$expected" && "$marker" == "$expected" ]]; then
        if (( c != 1 || s != 1 )); then
            echo "ERROR: expected ring marker missing: $marker" >&2
            exit 2
        fi
    else
        if (( c != 0 || s != 0 )); then
            echo "ERROR: ring profile contamination detected: $marker" >&2
            exit 2
        fi
    fi
done

for bad in \
    GREENQUIC-P5-ISO-TXRETRY1-V1 \
    GREENQUIC-P5-ISO-UDPCKSUM-V1 \
    GREENQUIC-P5-ISO-LOCKFREE-V1 \
    GREENQUIC-P5-ISO-COUNTERS-V1 \
    GREENQUIC-P5-ISO-RXALLOC4-V1 \
    GREENQUIC-P5-MAX-GOODPUT-V1; do
    if grep -aFq -- "$bad" "$CLIENT" || grep -aFq -- "$bad" "$SERVER"; then
        echo "ERROR: non-ring experiment contaminated build: $bad" >&2
        exit 2
    fi
done

echo
echo "P5 RING BUILD PASS"
echo "BASE: cache128"
echo "RING_PROFILE: $PROFILE"
echo "CLIENT: $(readlink -f "$CLIENT")"
sha256sum "$CLIENT"
echo "SERVER: $(readlink -f "$SERVER")"
sha256sum "$SERVER"
