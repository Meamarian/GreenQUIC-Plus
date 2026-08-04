#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
SUITE_ROOT="$(cd -- "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
source "$SUITE_ROOT/suite.env"
resolve_suite_path() {
  if [[ "$1" = /* ]]; then printf '%s\n' "$1"; else printf '%s\n' "$SUITE_ROOT/$1"; fi
}
exec python3 "$HERE/detect_runtime.py" \
  --msquic "$(resolve_suite_path "$MSQUIC_DIR")" \
  --dpdk "$(resolve_suite_path "$DPDK_DIR")" \
  --server-bin "$GQ_INTEROP_SERVER_BIN" \
  --client-bin "$GQ_INTEROP_CLIENT_BIN" \
  --secnetperf-bin "$GQ_SECNETPERF_BIN" \
  --inprocess-client-bin "$INPROCESS_CLIENT_BIN"
