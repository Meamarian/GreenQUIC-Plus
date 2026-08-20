#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 2 ]] || {
  echo "Usage: $0 <main|paper> <expected-sha>" >&2
  exit 2
}

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
PAPER_MARKER='GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0'

case "$KIND" in
  main|paper) ;;
  *) echo "ERROR: kind must be main or paper" >&2; exit 2 ;;
esac

cd "$ROOT"
[[ "$EXPECTED" =~ ^[0-9a-f]{40}$ ]] || { echo "ERROR: invalid expected SHA" >&2; exit 2; }
[[ "$(git rev-parse HEAD)" == "$EXPECTED" ]] || {
  echo "ERROR: wrong checkout on $(hostname): expected=$EXPECTED actual=$(git rev-parse HEAD)" >&2
  exit 2
}
[[ "$(git branch --show-current)" == main ]] || {
  echo "ERROR: GreenQUIC+ host must be on branch main" >&2
  exit 2
}
[[ -d "$P5" && -d "$P7" ]]
chmod 0755 "$P5"/*.sh "$P7"/*.sh 2>/dev/null || true

# acpi.sh samples through `sensors` from Debian's lm-sensors package.
test -x "$ROOT/acpi.sh"
command -v sensors >/dev/null || {
  echo "ERROR: sensors command missing; install Debian package lm-sensors" >&2
  exit 2
}

# GreenQUIC-Plus/main is the final paper code line. Build exactly the P5
# Performance2 V2 configuration used by the paper/fair reproduction.
P5_BUILD_REUSE=1 bash "$P5/build_p5_performance2.sh"

test -x "$P5_CLIENT"
test -x "$P5_SERVER"
grep -aFq -- 'GreenQUIC-P5-SEQUENCE-V2' "$P5_CLIENT"
grep -aFq -- 'GREENQUIC-P5-SUPER-PERF-V2' "$P5_CLIENT"
grep -aFq -- 'GREENQUIC-P5-PERFORMANCE2-V1' "$P5_CLIENT"
grep -aFq -- 'GREENQUIC-P5-PERFORMANCE2-V2' "$P5_CLIENT"
grep -aFq -- "$PAPER_MARKER" "$P5_CLIENT"
grep -aFq -- "$PAPER_MARKER" "$P5_SERVER"
grep -aFq -- 'GreenQUIC PACKETS source=datapath_totals' "$P5_CLIENT"
grep -aFq -- 'GreenQUIC PACKETS source=datapath_totals' "$P5_SERVER"

P5C_SHA="$(sha256sum "$P5_CLIENT" | awk '{print $1}')"
P5S_SHA="$(sha256sum "$P5_SERVER" | awk '{print $1}')"

# Build P7 in its isolated normal-Linux source/build tree and prove that doing
# so does not modify the already-verified P5 binaries.
bash "$P7/build_p7_linux.sh"
test -x "$P7_CLIENT"
test -x "$P7_SERVER"
if ldd "$P7_CLIENT" 2>/dev/null | grep -qi dpdk || ldd "$P7_SERVER" 2>/dev/null | grep -qi dpdk; then
  echo "ERROR: P7 Linux binaries unexpectedly link DPDK" >&2
  exit 4
fi
[[ "$(sha256sum "$P5_CLIENT" | awk '{print $1}')" == "$P5C_SHA" ]]
[[ "$(sha256sum "$P5_SERVER" | awk '{print $1}')" == "$P5S_SHA" ]]

DRIVER="$(basename "$(readlink -f "/sys/bus/pci/devices/$PCI/driver" 2>/dev/null || true)")"
case "$DRIVER" in
  igb_uio|vfio-pci) ;;
  *) echo "ERROR: test NIC not DPDK-bound: ${DRIVER:-none}" >&2; exit 5 ;;
esac

command -v zip >/dev/null
python3 -c 'import matplotlib, numpy'

printf 'READY host=%s repo=GreenQUIC-Plus branch=main head=%s driver=%s sensors=%s\n' \
  "$(hostname)" "$(git rev-parse HEAD)" "$DRIVER" "$(command -v sensors)"
printf 'P5 marker: %s\n' "$PAPER_MARKER"
sha256sum "$P5_CLIENT" "$P5_SERVER" "$P7_CLIENT" "$P7_SERVER"
