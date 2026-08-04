#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
TEST_DIR="${1:-$HERE/../../test_cases/core/T1_one_10GB_file}"
# shellcheck source=/dev/null
source "$HERE/gq_common.sh"
preflight "$TEST_DIR"
