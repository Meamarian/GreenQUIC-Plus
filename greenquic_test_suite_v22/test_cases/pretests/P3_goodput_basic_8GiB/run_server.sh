#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
source "$HERE/config.env"

MODE="${GQ_MODE_OVERRIDE:-basic}"
case "$MODE" in
    off|basic|plus) ;;
    *) echo "ERROR: invalid GQ_MODE_OVERRIDE=$MODE" >&2; exit 2 ;;
esac

# Keep the server and client comparison artifacts symmetric by default.
export ENABLE_CSTATE_RECORD="${ENABLE_CSTATE_RECORD:-1}"

"$HERE/../../../common/bin/run_role.sh" server "$HERE" "$MODE" 0
