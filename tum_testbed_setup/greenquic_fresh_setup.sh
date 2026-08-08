#!/usr/bin/env bash
set -Eeuo pipefail

# Public TUM/LRZ Mac-side setup entrypoint.
#
# First invocation: dispatch to the complete normal + P4 + P5 wrapper.
# The complete wrapper deliberately calls this file once for the established
# SSH/link/DPDK/P0/P4 sequence; on that nested invocation the guard below
# dispatches to the preserved base implementation instead of recursing.

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE="$HERE/greenquic_fresh_setup_base.sh"
FULL="$HERE/greenquic_fresh_setup_p4_p5.sh"

if [[ "${GREENQUIC_TUM_FULL_SETUP_ACTIVE:-0}" == 1 ]]; then
    [[ -f "$BASE" ]] || {
        echo "ERROR: missing preserved TUM setup base: $BASE" >&2
        exit 1
    }
    exec bash "$BASE" "$@"
fi

[[ -f "$FULL" ]] || {
    echo "ERROR: missing complete P4+P5 TUM setup: $FULL" >&2
    exit 1
}

export GREENQUIC_TUM_FULL_SETUP_ACTIVE=1
exec bash "$FULL" "$@"
