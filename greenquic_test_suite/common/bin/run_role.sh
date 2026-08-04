#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/../../common/bin/gq_common.sh"
role="${1:?usage: run_role.sh server|client TEST_DIR [mode] [approximate]}"
test_dir="${2:?missing TEST_DIR}"
mode="${3:-}"
approx="${4:-0}"
case "$role" in
  server) run_server "$test_dir" "$mode" ;;
  client) run_client "$test_dir" "$mode" "$approx" ;;
  *) die "unknown role $role" ;;
esac
