#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
MODE=""
APPROX=0
for arg in "$@"; do
  case "$arg" in
    off|basic|plus) MODE="$arg" ;;
    --approximate) APPROX=1 ;;
    -h|--help)
      echo "usage: $0 [off|basic|plus] [--approximate]"
      exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
exec "$HERE/../../../common/bin/run_role.sh" client "$HERE" "$MODE" "$APPROX"

# GREENQUIC-ENABLE-RECORD-V1: run_role already printed goodput and removed transient artifacts.
if [[ "${ENABLE_RECORD:-1}" == 0 ]]; then
    exit 0
fi
