#!/usr/bin/env bash
set -Eeuo pipefail

# Public TUM/LRZ Mac-side setup entrypoint.
#
# First invocation: dispatch to the complete normal + P4 + P5 + P6 + P7 wrapper.
# The complete wrapper deliberately calls the preserved P4/P5/P6 setup, which in
# turn executes the preserved base implementation for SSH/link/DPDK/P0/P4.
#
# The preserved base script contains two fresh-boot hazards:
#   1) an MSR readiness pipeline that can fail under `set -o pipefail`;
#   2) a physical-link check that tests IDEX before Tinyman's peer port is up.
# Run from a temporary copy and harden those exact blocks before dispatch.

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE="$HERE/greenquic_fresh_setup_base.sh"
FULL="$HERE/greenquic_fresh_setup_p4_p5_p6_p7.sh"

if [[ "${GREENQUIC_TUM_FULL_SETUP_ACTIVE:-0}" == 1 ]]; then
    [[ -f "$BASE" ]] || {
        echo "ERROR: missing preserved TUM setup base: $BASE" >&2
        exit 1
    }
    exec bash "$BASE" "$@"
fi

[[ -f "$FULL" ]] || {
    echo "ERROR: missing complete P4+P5+P6+P7 TUM setup: $FULL" >&2
    exit 1
}
[[ -f "$BASE" ]] || {
    echo "ERROR: missing preserved TUM setup base: $BASE" >&2
    exit 1
}

TMP_SETUP="$(mktemp -d "${TMPDIR:-/tmp}/greenquic-tum-setup.XXXXXX")"
cleanup() {
    rm -rf "$TMP_SETUP"
}
trap cleanup EXIT HUP INT TERM

cp "$HERE"/greenquic_fresh_setup*.sh "$TMP_SETUP"/

python3 - "$TMP_SETUP/greenquic_fresh_setup_base.sh" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

# Harden the MSR check without using an lsmod|grep -q pipeline under pipefail.
old_msr = "\n".join([
    "lsmod | grep -q '^msr '",
    "test -e /dev/cpu/19/msr",
    "rdmsr -p 19 0xCE >/dev/null",
    'echo "MSR CPU19: PASS"',
])
new_msr = "\n".join([
    'echo "Checking MSR readiness on CPU19..."',
    'modprobe msr || {',
    '    echo "ERROR: modprobe msr failed on $(hostname)" >&2',
    '    exit 1',
    '}',
    "grep -q '^msr ' /proc/modules || {",
    '    echo "ERROR: msr module is not loaded on $(hostname)" >&2',
    '    exit 1',
    '}',
    '[[ -e /dev/cpu/19/msr ]] || {',
    '    echo "ERROR: /dev/cpu/19/msr is missing on $(hostname)" >&2',
    '    exit 1',
    '}',
    'rdmsr -p 19 0xCE >/dev/null || {',
    '    echo "ERROR: rdmsr failed for CPU19 MSR 0xCE on $(hostname)" >&2',
    '    exit 1',
    '}',
    'echo "MSR CPU19: PASS"',
])
if text.count(old_msr) != 1:
    raise SystemExit(
        f"ERROR: expected exactly one legacy MSR block, found {text.count(old_msr)}"
    )
text = text.replace(old_msr, new_msr, 1)

# On the direct cable, both E810 ports must be admin-UP before either side can
# report carrier. The old setup called restore_and_check_link(idex) first while
# Tinyman could still be DOWN, causing the proven carrier=0/ethtool=no failure.
old_link_order = "\n".join([
    '# Both sides remain kernel/ICE-managed until both checks have passed.',
    'restore_and_check_link idex',
    'restore_and_check_link tinyman',
])
new_link_order = "\n".join([
    '# Both direct-cable peers must be on ICE and admin-UP before either carrier check.',
    'prepare_link_peer() {',
    '    local host="$1"',
    "    remote \"$host\" bash -s <<'LINKPREP'",
    'set -Eeuo pipefail',
    'PCI="0000:18:00.0"',
    'DEVBIND="/root/mohsen/msquic/deps/dpdk/usertools/dpdk-devbind.py"',
    'test -e "/sys/bus/pci/devices/$PCI"',
    'test -f "$DEVBIND"',
    'modprobe ice',
    'CURRENT="$(basename "$(readlink -f "/sys/bus/pci/devices/$PCI/driver" 2>/dev/null || true)")"',
    'if [[ -n "$CURRENT" && "$CURRENT" != ice ]]; then',
    '    python3 "$DEVBIND" --unbind "$PCI"',
    '    sleep 1',
    'fi',
    'CURRENT="$(basename "$(readlink -f "/sys/bus/pci/devices/$PCI/driver" 2>/dev/null || true)")"',
    'if [[ "$CURRENT" != ice ]]; then',
    '    python3 "$DEVBIND" --bind=ice "$PCI"',
    'fi',
    'IFACE="$(find "/sys/bus/pci/devices/$PCI/net" -mindepth 1 -maxdepth 1 -printf "%f\\n" | head -n1)"',
    '[[ -n "$IFACE" ]] || { echo "ERROR: no Linux netdev for $PCI on $(hostname)" >&2; exit 1; }',
    'ip link set dev "$IFACE" up',
    'echo "LINK PEER PREPARED: host=$(hostname) iface=$IFACE driver=ice"',
    'LINKPREP',
    '}',
    '',
    'prepare_link_peer idex',
    'prepare_link_peer tinyman',
    'sleep 2',
    'restore_and_check_link idex',
    'restore_and_check_link tinyman',
])
if text.count(old_link_order) != 1:
    raise SystemExit(
        "ERROR: expected exactly one legacy physical-link ordering block, "
        f"found {text.count(old_link_order)}"
    )
text = text.replace(old_link_order, new_link_order, 1)

path.write_text(text, encoding="utf-8")
PY

bash -n "$TMP_SETUP/greenquic_fresh_setup_base.sh"
grep -Fq 'Checking MSR readiness on CPU19...' "$TMP_SETUP/greenquic_fresh_setup_base.sh"
grep -Fq 'prepare_link_peer idex' "$TMP_SETUP/greenquic_fresh_setup_base.sh"
grep -Fq 'prepare_link_peer tinyman' "$TMP_SETUP/greenquic_fresh_setup_base.sh"

echo "TUM setup MSR + direct-link ordering hardening: PASS"

export GREENQUIC_TUM_FULL_SETUP_ACTIVE=1
bash "$TMP_SETUP/greenquic_fresh_setup_p4_p5_p6_p7.sh" "$@"
