#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$HERE/../../../.." && pwd)"
BUILD="$REPO_ROOT/msquic/build-greenquic-p5"
DATAPATH="$REPO_ROOT/msquic-p5-source/src/platform/datapath_raw_dpdk_linux.c"
FEATURE_TRANSFORM="$HERE/apply_p5_isolated_feature.py"
FEATURE="${1:-control}"
REUSE="${P5_BUILD_REUSE:-1}"
BASE="cache128_pool8191"

case "$FEATURE" in
    control|txretry1|udpcksum|lockfree|counters|rxalloc4) ;;
    *)
        echo "ERROR: feature must be control|txretry1|udpcksum|lockfree|counters|rxalloc4" >&2
        exit 2
        ;;
esac
case "$REUSE" in 0|1) ;; *) echo "ERROR: P5_BUILD_REUSE must be 0 or 1" >&2; exit 2;; esac

if [[ "$FEATURE" != control ]]; then
    [[ -f "$FEATURE_TRANSFORM" ]] || {
        echo "ERROR: missing isolated feature transformer: $FEATURE_TRANSFORM" >&2
        exit 2
    }
fi

echo "P5 isolated build: base=$BASE feature=$FEATURE"
echo "P5 isolation rule: exactly one optional feature; GreenQUIC/GreenQUIC+ unchanged"

P5_STATIC_PROFILE="$BASE" P5_BUILD_REUSE="$REUSE" bash "$HERE/build_p5_client.sh"

[[ -f "$DATAPATH" ]] || { echo "ERROR: generated datapath missing: $DATAPATH" >&2; exit 2; }
grep -Fq 'GREENQUIC-P5-STATIC-PERF-V2 profile=cache128_pool8191' "$DATAPATH" || {
    echo "ERROR: combined cache128_pool8191 baseline marker missing" >&2
    exit 2
}

if [[ "$FEATURE" != control ]]; then
    python3 "$FEATURE_TRANSFORM" "$FEATURE" "$DATAPATH"
fi

python3 -m py_compile "$FEATURE_TRANSFORM"

cmake --build "$BUILD" \
    --target quicinterop quicinteropserver \
    --parallel "$(nproc)"

CLIENT="$BUILD/bin/Release/quicinterop"
SERVER="$BUILD/bin/Release/quicinteropserver"
test -x "$CLIENT"
test -x "$SERVER"

markers=(
    GREENQUIC-P5-ISO-TXRETRY1-V1
    GREENQUIC-P5-ISO-UDPCKSUM-V1
    GREENQUIC-P5-ISO-LOCKFREE-V1
    GREENQUIC-P5-ISO-COUNTERS-V1
    GREENQUIC-P5-ISO-RXALLOC4-V1
)

expected=""
case "$FEATURE" in
    txretry1) expected=GREENQUIC-P5-ISO-TXRETRY1-V1 ;;
    udpcksum) expected=GREENQUIC-P5-ISO-UDPCKSUM-V1 ;;
    lockfree) expected=GREENQUIC-P5-ISO-LOCKFREE-V1 ;;
    counters) expected=GREENQUIC-P5-ISO-COUNTERS-V1 ;;
    rxalloc4) expected=GREENQUIC-P5-ISO-RXALLOC4-V1 ;;
esac

for marker in "${markers[@]}"; do
    in_client=0
    in_server=0
    grep -aFq -- "$marker" "$CLIENT" && in_client=1 || true
    grep -aFq -- "$marker" "$SERVER" && in_server=1 || true
    if [[ -n "$expected" && "$marker" == "$expected" ]]; then
        if (( in_client != 1 || in_server != 1 )); then
            echo "ERROR: expected isolated feature marker missing: $marker" >&2
            exit 2
        fi
    else
        if (( in_client != 0 || in_server != 0 )); then
            echo "ERROR: another isolated feature contaminated this build: $marker" >&2
            exit 2
        fi
    fi
done

for bad in \
    'GREENQUIC-P5-MAX-GOODPUT-V1' \
    'P5_DPDK_TX_RETRIES' \
    'P5_DPDK_FORCE_TX_LOCKFREE' \
    'P5_DPDK_PERF_COUNTERS' \
    'P5_DPDK_UDP_CHECKSUM_OFFLOAD' \
    'P5 performance config:'; do
    if grep -aFq -- "$bad" "$CLIENT" || grep -aFq -- "$bad" "$SERVER"; then
        echo "ERROR: obsolete multi-feature runtime implementation found: $bad" >&2
        exit 2
    fi
done

echo
echo "P5 ISOLATED BUILD PASS"
echo "BASE: cache128_pool8191"
echo "FEATURE: $FEATURE"
echo "CLIENT: $(readlink -f "$CLIENT")"
sha256sum "$CLIENT"
echo "SERVER: $(readlink -f "$SERVER")"
sha256sum "$SERVER"
