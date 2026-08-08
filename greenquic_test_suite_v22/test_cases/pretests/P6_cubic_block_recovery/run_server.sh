#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
source "$HERE/config.env"
REPO_ROOT="$(cd -- "$HERE/../../../.." && pwd)"
P6_SERVER_BIN="$REPO_ROOT/msquic/build-greenquic-p6/bin/Release/quicinteropserver"
export GQ_INTEROP_SERVER_BIN="${GQ_INTEROP_SERVER_BIN:-$P6_SERVER_BIN}"

[[ -x "$GQ_INTEROP_SERVER_BIN" ]] || {
    echo "ERROR: P6 server binary missing: $GQ_INTEROP_SERVER_BIN" >&2
    echo "Run ./build_p6_client.sh first." >&2
    exit 2
}
grep -aFq -- 'GREENQUIC-P6-DETERMINISTIC-LOSS-V2' "$GQ_INTEROP_SERVER_BIN" || {
    echo "ERROR: selected server is not the isolated P6 V2 binary: $GQ_INTEROP_SERVER_BIN" >&2
    exit 2
}

MODE="${GQ_MODE_OVERRIDE:-basic}"
case "$MODE" in
    off|basic|plus) ;;
    *) echo "ERROR: invalid GQ_MODE_OVERRIDE=$MODE" >&2; exit 2 ;;
esac

export ENABLE_CSTATE_RECORD="${ENABLE_CSTATE_RECORD:-1}"

"$HERE/run_role_p5.sh" server "$HERE" "$MODE" 0
