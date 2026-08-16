#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
export P5_D1D2PLUS_SMOKE_IDLE_P7_ONLY=1
export P5_FINAL_RUNS="${P5_FINAL_RUNS:-2}"
export P5_FINAL_DOWNLOADS="${P5_FINAL_DOWNLOADS:-6}"
exec bash "$HERE/mac_run_p2_final_6x6_d1d2plus_p7_paper_v1.sh" "$@"
