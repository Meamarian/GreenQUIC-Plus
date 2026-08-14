#!/usr/bin/env bash
set -Eeuo pipefail

PCI="0000:18:00.0"
DEVBIND="/root/mohsen/msquic/deps/dpdk/usertools/dpdk-devbind.py"

trap 'rc=$?; echo "[ERROR] line $LINENO: $BASH_COMMAND (exit=$rc)" >&2; exit $rc' ERR

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 {linux|dpdk}" >&2
    exit 2
fi

case "$1" in
    linux)
        TARGET="ice"
        ;;
    dpdk)
        TARGET="vfio-pci"
        ;;
    *)
        echo "[ERROR] Invalid mode: $1" >&2
        echo "Usage: $0 {linux|dpdk}" >&2
        exit 2
        ;;
esac

[[ -x "$DEVBIND" || -f "$DEVBIND" ]] || {
    echo "[ERROR] dpdk-devbind.py not found: $DEVBIND" >&2
    exit 1
}

[[ -e "/sys/bus/pci/devices/$PCI" ]] || {
    echo "[ERROR] PCI device $PCI does not exist" >&2
    exit 1
}

echo "========================================"
echo " PCI device : $PCI"
echo " Mode       : $1"
echo " Driver     : $TARGET"
echo "========================================"

echo
echo "[1] Current state:"
python3 "$DEVBIND" -s | grep "$PCI" || true

CURRENT=""
if [[ -L "/sys/bus/pci/devices/$PCI/driver" ]]; then
    CURRENT="$(basename "$(readlink -f "/sys/bus/pci/devices/$PCI/driver")")"
fi

if [[ -n "$CURRENT" ]]; then
    echo
    echo "[2] Unbinding from: $CURRENT"
    echo "$PCI" > "/sys/bus/pci/drivers/$CURRENT/unbind"
    echo "[OK] Unbound from $CURRENT"
else
    echo
    echo "[2] Device is already unbound"
fi

echo
echo "[3] Loading target driver: $TARGET"
modprobe "$TARGET"

echo
echo "[4] Binding $PCI -> $TARGET"
python3 "$DEVBIND" -b "$TARGET" "$PCI"

if [[ "$TARGET" == "ice" ]]; then
    sleep 1
    IFACE="$(ls "/sys/bus/pci/devices/$PCI/net/" 2>/dev/null | head -n1 || true)"

    if [[ -n "$IFACE" ]]; then
        echo
        echo "[5] Linux interface: $IFACE"
        ip link set "$IFACE" up
        echo "[OK] Interface brought UP"
    else
        echo "[WARNING] ice is bound but no Linux interface was found" >&2
    fi
fi

echo
echo "Final state:"
python3 "$DEVBIND" -s | grep "$PCI" || {
    echo "[ERROR] Could not verify final state" >&2
    exit 1
}

FINAL=""
if [[ -L "/sys/bus/pci/devices/$PCI/driver" ]]; then
    FINAL="$(basename "$(readlink -f "/sys/bus/pci/devices/$PCI/driver")")"
fi

if [[ "$FINAL" != "$TARGET" ]]; then
    echo "[ERROR] Expected driver '$TARGET', but device is bound to '${FINAL:-none}'" >&2
    exit 1
fi

echo
echo "[SUCCESS] $PCI is bound to $TARGET"
