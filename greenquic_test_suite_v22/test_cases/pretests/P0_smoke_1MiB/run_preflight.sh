#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
ROLE="${1:-both}"
source "$HERE/../../../common/bin/gq_common.sh"
preflight "$HERE" "$ROLE"
