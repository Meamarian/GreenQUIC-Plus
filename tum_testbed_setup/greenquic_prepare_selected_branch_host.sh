#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 2 ]] || { echo "Usage: $0 <main|performance|performance2> <expected-sha>" >&2; exit 2; }
KIND="$1"
EXPECTED="$2"
ROOT=/root/mohsen
P5="$ROOT/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
P7="$ROOT/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline"
P5_BUILD="$ROOT/msquic/build-greenquic-p5"
P5_CLIENT="$P5_BUILD/bin/Release/quicinterop"
P5_SERVER="$P5_BUILD/bin/Release/quicinteropserver"
P7_BUILD="$ROOT/msquic/build-linux-p7"
P7_CLIENT="$P7_BUILD/bin/Release/quicinterop"
P7_SERVER="$P7_BUILD/bin/Release/quicinteropserver"
PCI=0000:18:00.0

cd "$ROOT"
[[ "$EXPECTED" =~ ^[0-9a-f]{40}$ ]]
[[ "$(git rev-parse HEAD)" == "$EXPECTED" ]] || { echo "ERROR: wrong checkout on $(hostname)" >&2; exit 2; }
[[ -d "$P5" && -d "$P7" ]]
chmod 0755 "$P5"/*.sh "$P7"/*.sh 2>/dev/null || true

case "$KIND" in
  main)
    bash "$P5/build_p5_client.sh"
    grep -aFq -- 'GreenQUIC-P5-SEQUENCE-V2' "$P5_CLIENT"
    ! grep -aFq -- 'GREENQUIC-P5-SUPER-PERF-V2' "$P5_CLIENT"
    ;;
  performance)
    bash "$P5/build_p5_super_performance.sh"
    grep -aFq -- 'GREENQUIC-P5-SUPER-PERF-V2' "$P5_CLIENT"
    ! grep -aFq -- 'GREENQUIC-P5-PERFORMANCE2-V1' "$P5_CLIENT"
    ;;
  performance2)
    env P5_P2_DIAG_INTERVAL_US=0 P5_P2_TX_HANDOFF=shared P5_P2_RX_PREFETCH=0 P5_P2_UDP_SEG=0 \
      bash "$P5/build_p5_performance2.sh"
    grep -aFq -- 'GREENQUIC-P5-SUPER-PERF-V2' "$P5_CLIENT"
    grep -aFq -- 'GREENQUIC-P5-PERFORMANCE2-V1' "$P5_CLIENT"
    ;;
  *) echo "ERROR: unknown branch kind: $KIND" >&2; exit 2 ;;
esac

test -x "$P5_CLIENT"; test -x "$P5_SERVER"
grep -aFq -- 'GreenQUIC-P5-SEQUENCE-V2' "$P5_CLIENT"
grep -aFq -- 'GreenQUIC PACKETS source=datapath_totals' "$P5_CLIENT"
grep -aFq -- 'GreenQUIC PACKETS source=datapath_totals' "$P5_SERVER"
P5C_SHA="$(sha256sum "$P5_CLIENT" | awk '{print $1}')"
P5S_SHA="$(sha256sum "$P5_SERVER" | awk '{print $1}')"

bash "$P7/build_p7_linux.sh"
test -x "$P7_CLIENT"; test -x "$P7_SERVER"
if ldd "$P7_CLIENT" 2>/dev/null | grep -qi dpdk || ldd "$P7_SERVER" 2>/dev/null | grep -qi dpdk; then
  echo "ERROR: P7 Linux binaries unexpectedly link DPDK" >&2
  exit 4
fi
[[ "$(sha256sum "$P5_CLIENT" | awk '{print $1}')" == "$P5C_SHA" ]]
[[ "$(sha256sum "$P5_SERVER" | awk '{print $1}')" == "$P5S_SHA" ]]

DRIVER="$(basename "$(readlink -f "/sys/bus/pci/devices/$PCI/driver" 2>/dev/null || true)")"
case "$DRIVER" in igb_uio|vfio-pci) ;; *) echo "ERROR: test NIC not DPDK-bound: ${DRIVER:-none}" >&2; exit 5;; esac
command -v zip >/dev/null
python3 -c 'import matplotlib, numpy'
printf 'READY host=%s kind=%s head=%s driver=%s\n' "$(hostname)" "$KIND" "$(git rev-parse HEAD)" "$DRIVER"
sha256sum "$P5_CLIENT" "$P5_SERVER" "$P7_CLIENT" "$P7_SERVER"
