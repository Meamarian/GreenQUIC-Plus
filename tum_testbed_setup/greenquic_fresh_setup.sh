#!/usr/bin/env bash
set -Eeuo pipefail

# Public TUM/LRZ Mac-side setup entrypoint.
#
# First invocation: dispatch to the complete normal + P4 + P5 + P6 + P7 wrapper.
# The complete wrapper deliberately calls the preserved P4/P5/P6 setup, which in
# turn executes the preserved base implementation for SSH/link/DPDK/P0/P4.

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

export GREENQUIC_TUM_FULL_SETUP_ACTIVE=1
exec bash "$FULL" "$@"
