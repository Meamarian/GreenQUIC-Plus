#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
exec bash "$HERE/mac_chain_p1_resume_p2_best_and_sweep_v4.sh" "$@"
