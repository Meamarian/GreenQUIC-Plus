#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
exec bash "$HERE/mac_run_p2_goodput_screen_v4.sh" "$@"
