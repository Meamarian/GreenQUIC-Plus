#!/usr/bin/env bash
set -Eeuo pipefail

# Compatibility entrypoint retained for old notes/scripts.
# RUN ON: control host.
# The authoritative implementation is mac_run_p5_p7_fair_repro_6x5.sh.
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$HERE/mac_run_p5_p7_fair_repro_6x5.sh" "$@"
