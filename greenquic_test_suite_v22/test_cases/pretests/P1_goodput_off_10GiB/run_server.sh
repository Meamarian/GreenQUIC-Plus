#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
exec "$HERE/../../../common/bin/run_role.sh" server "$HERE" "off" 0
