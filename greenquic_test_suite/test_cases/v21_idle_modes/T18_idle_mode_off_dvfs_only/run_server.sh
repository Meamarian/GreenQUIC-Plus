#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
MODE="${1:-}"
exec "$HERE/../../../common/bin/run_role.sh" server "$HERE" "$MODE" 0
