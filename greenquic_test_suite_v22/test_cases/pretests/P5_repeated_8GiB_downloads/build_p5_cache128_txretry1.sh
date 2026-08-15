#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$HERE/../../../.." && pwd)"
BUILD="$REPO_ROOT/msquic/build-greenquic-p5"
DATAPATH="$REPO_ROOT/msquic-p5-source/src/platform/datapath_raw_dpdk_linux.c"
FEATURE="$HERE/apply_p5_tx_retry_once.py"
REUSE="${P5_BUILD_REUSE:-1}"

[[ -f "$FEATURE" ]] || { echo "ERROR: missing $FEATURE" >&2; exit 2; }
case "$REUSE" in 0|1) ;; *) echo "ERROR: P5_BUILD_REUSE must be 0 or 1" >&2; exit 2;; esac

echo "P5 experiment build: base=cache128 feature=txretry1"
echo "P5 experiment isolation: udp_checksum=off perf_counters=off forced_lockfree=off runtime_perf_hooks=none"

P5_STATIC_PROFILE=cache128 P5_BUILD_REUSE="$REUSE" bash "$HERE/build_p5_client.sh"

[[ -f "$DATAPATH" ]] || { echo "ERROR: generated datapath missing: $DATAPATH" >&2; exit 2; }
python3 "$FEATURE" "$DATAPATH"
grep -Fq 'GREENQUIC-P5-STATIC-PERF-V2 profile=cache128' "$DATAPATH" || {
    echo "ERROR: cache128 baseline marker missing" >&2
    exit 2
}
grep -Fq 'GREENQUIC-P5-TX-RETRY1-V1' "$DATAPATH" || {
    echo "ERROR: TX retry feature marker missing" >&2
    exit 2
}

cmake --build "$BUILD" \
    --target quicinterop quicinteropserver \
    --parallel "$(nproc)"

CLIENT="$BUILD/bin/Release/quicinterop"
SERVER="$BUILD/bin/Release/quicinteropserver"
test -x "$CLIENT"
test -x "$SERVER"

grep -aFq -- 'GREENQUIC-P5-TX-RETRY1-V1' "$CLIENT" || {
    echo "ERROR: client binary lacks isolated TX retry marker" >&2
    exit 2
}
grep -aFq -- 'GREENQUIC-P5-TX-RETRY1-V1' "$SERVER" || {
    echo "ERROR: server binary lacks isolated TX retry marker" >&2
    exit 2
}

for bad in \
    'P5_DPDK_UDP_CHECKSUM_OFFLOAD' \
    'P5_DPDK_TX_RETRIES' \
    'GREENQUIC-P5-MAX-GOODPUT-V1' \
    'P5 performance config:' \
    'P5 DPDK UDP offload:'; do
    if grep -aFq -- "$bad" "$CLIENT" || grep -aFq -- "$bad" "$SERVER"; then
        echo "ERROR: obsolete multi-feature runtime marker found: $bad" >&2
        exit 2
    fi
done

echo
echo "P5 isolated experiment build PASS"
echo "BASE: cache128"
echo "FEATURE: one immediate TX tail retry"
echo "OTHER REMOVED FEATURES: disabled/not compiled"
echo "CLIENT: $(readlink -f "$CLIENT")"
sha256sum "$CLIENT"
echo "SERVER: $(readlink -f "$SERVER")"
sha256sum "$SERVER"
