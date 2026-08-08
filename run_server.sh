#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/greenquic-env.sh"

if ((EUID != 0)); then
    echo "ERROR: DPDK server must be run as root on this test node." >&2
    exit 1
fi

[[ -n "${SECNETPERF_BIN:-}" && -x "$SECNETPERF_BIN" ]] || {
    echo "ERROR: secnetperf is missing. Run ./bootstrap_greenquic.sh first." >&2
    exit 1
}

DPDK_INI="$MSQUIC_ROOT/dpdk.ini"
[[ -f "$DPDK_INI" ]] || {
    echo "ERROR: missing $DPDK_INI" >&2
    echo "Rerun bootstrap with --pci, --local-ip, --peer-mac and --lcores." >&2
    exit 1
}

for key in DeviceName LocalIp PeerMac DpdkInitArgs; do
    grep -q "^${key}=" "$DPDK_INI" || {
        echo "ERROR: $key is missing from $DPDK_INI" >&2
        exit 1
    }
done

PCI="$(awk -F= '$1 == "DeviceName" {print $2; exit}' "$DPDK_INI")"
PEER_MAC="$(awk -F= '$1 == "PeerMac" {print $2; exit}' "$DPDK_INI")"

[[ "$PEER_MAC" != "00:00:00:00:00:00" ]] || {
    echo "ERROR: PeerMac is still zero in $DPDK_INI" >&2
    exit 1
}

PCI_FULL="$PCI"
[[ "$PCI_FULL" =~ ^[0-9a-fA-F]{2}: ]] && PCI_FULL="0000:$PCI_FULL"

[[ -e "/sys/bus/pci/devices/$PCI_FULL" ]] || {
    echo "ERROR: PCI device $PCI_FULL does not exist on this server" >&2
    exit 1
}

DRIVER="$(basename "$(readlink -f "/sys/bus/pci/devices/$PCI_FULL/driver" 2>/dev/null || true)")"
case "$DRIVER" in
    igb_uio|vfio-pci)
        ;;
    *)
        echo "ERROR: $PCI_FULL is bound to '${DRIVER:-no driver}', not a DPDK userspace driver." >&2
        echo "Use bootstrap --bind-dpdk or bind the NIC manually before starting the server." >&2
        exit 1
        ;;
esac

HUGEPAGES_TOTAL="$(awk '/^HugePages_Total:/ {print $2}' /proc/meminfo)"
if [[ -z "$HUGEPAGES_TOTAL" || "$HUGEPAGES_TOTAL" == "0" ]]; then
    echo "ERROR: no hugepages are configured." >&2
    echo "Use bootstrap --hugepages N or configure hugepages manually before starting the server." >&2
    exit 1
fi

ulimit -l unlimited 2>/dev/null || true
cd "$MSQUIC_ROOT"

exec "$SECNETPERF_BIN" -exec:maxtput "$@"
