#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
source "$HERE/config.env"
REPO_ROOT="$(cd -- "$HERE/../../../.." && pwd)"
export GQ_INTEROP_SERVER_BIN="${GQ_INTEROP_SERVER_BIN:-$REPO_ROOT/msquic/build-greenquic-p5/bin/Release/quicinteropserver}"

MODE="${GQ_MODE_OVERRIDE:-basic}"
case "$MODE" in
    off|basic|plus) ;;
    *) echo "ERROR: invalid GQ_MODE_OVERRIDE=$MODE" >&2; exit 2 ;;
esac

export ENABLE_CSTATE_RECORD="${ENABLE_CSTATE_RECORD:-1}"

"$HERE/run_role_p5.sh" server "$HERE" "$MODE" 0
