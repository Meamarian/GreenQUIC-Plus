#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
echo "NOTE: forwarding legacy script name to V22 checks." >&2
exec "$HERE/run_all_v22_static_checks.sh"
