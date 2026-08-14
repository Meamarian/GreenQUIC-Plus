#!/usr/bin/env bash
set -Eeuo pipefail

# Public TUM/LRZ Mac-side setup entrypoint.
#
# First invocation: dispatch to the complete normal + P4 + P5 + P6 + P7 wrapper.
# The complete wrapper deliberately calls the preserved P4/P5/P6 setup, which in
# turn executes the preserved base implementation for SSH/link/DPDK/P0/P4.
#
# The base script historically used `lsmod | grep -q '^msr '` under pipefail.
# On some fresh Debian runs that can terminate the remote setup without a useful
# diagnostic. Run the setup from a temporary copy where only that exact MSR
# readiness block is hardened. The checked-out repository itself stays clean.

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
old = """lsmod | grep -q '^msr '
test -e /dev/cpu/19/msr
rdmsr -p 19 0xCE >/dev/null
echo \"MSR CPU19: PASS\""" 
new = """echo \"Checking MSR readiness on CPU19...\"
modprobe msr || {
    echo \"ERROR: modprobe msr failed on $(hostname)\" >&2
    exit 1
}
grep -q '^msr ' /proc/modules || {
    echo \"ERROR: msr module is not loaded on $(hostname)\" >&2
    exit 1
}
[[ -e /dev/cpu/19/msr ]] || {
    echo \"ERROR: /dev/cpu/19/msr is missing on $(hostname)\" >&2
    exit 1
}
rdmsr -p 19 0xCE >/dev/null || {
    echo \"ERROR: rdmsr failed for CPU19 MSR 0xCE on $(hostname)\" >&2
    exit 1
}
echo \"MSR CPU19: PASS\"""

count = text.count(old)
if count != 1:
    raise SystemExit(
        f"ERROR: expected exactly one legacy MSR readiness block, found {count}"
    )
path.write_text(text.replace(old, new, 1), encoding="utf-8")
PY

bash -n "$TMP_SETUP/greenquic_fresh_setup_base.sh"
grep -Fq 'Checking MSR readiness on CPU19...' "$TMP_SETUP/greenquic_fresh_setup_base.sh"
grep -Fq "grep -q '^msr ' /proc/modules" "$TMP_SETUP/greenquic_fresh_setup_base.sh"

echo "TUM setup MSR readiness hardening: PASS"

export GREENQUIC_TUM_FULL_SETUP_ACTIVE=1
bash "$TMP_SETUP/greenquic_fresh_setup_p4_p5_p6_p7.sh" "$@"
