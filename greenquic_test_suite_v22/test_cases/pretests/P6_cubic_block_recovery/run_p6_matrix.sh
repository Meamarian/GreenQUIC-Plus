#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(cd -- "$HERE/../../../.." && pwd)"
CLIENT_BIN="$ROOT/msquic/build-greenquic-p6/bin/Release/quicinterop"
MATRIX_WITH_SHEET="$HERE/run_matrix_with_sheet.sh"

[[ -x "$MATRIX_WITH_SHEET" ]] || { echo "ERROR: missing P6 matrix/report wrapper: $MATRIX_WITH_SHEET" >&2; exit 2; }
[[ -x "$CLIENT_BIN" ]] || { echo "ERROR: missing P6 client binary: $CLIENT_BIN; run bash ./build_p6_client.sh first" >&2; exit 2; }

# P6 defaults: Normal GreenQUIC policy, EPOLL, 16 GiB, deterministic sparse
# server-download loss (exactly one packet/event), plus a P6-only 64-KiB CUBIC
# window cap. The cap does NOT synthesize a hint; it makes the existing real
# BytesInFlight >= CongestionWindow condition reachable on the direct cable.
# The matrix/report wrapper defaults to --chart-style both, so each completed
# P6 matrix also gets the 62-chart report plus phase-scoped, normalized, and
# derived chart families. Override chart style or any environment below via "$@".
exec "$MATRIX_WITH_SHEET" \
  --client-host tinyman \
  --client-dir "$HERE" \
  --client-bin "$CLIENT_BIN" \
  --downloads 5 \
  --gap-seconds 5 \
  --server-cooldown-seconds 5 \
  --between-tests-seconds 5 \
  --server-cleanup-timeout-seconds 300 \
  --cstate-cpu 19 \
  --runs 5 \
  --mode-order balanced \
  --seed 20260817 \
  --output-dir "$HERE/matrix_results/p6_cubic_block_recovery_epoll_16GiB_$(date +%Y%m%d_%H%M%S)" \
  --env ENABLE_RECORD=1 \
  --env GQ_LOG_LEVEL=0 \
  --env GQ_IDLE_MODE_OVERRIDE=epoll \
  --env GQ_IDLE_FALLBACK_OVERRIDE=short \
  --env WORK_WAIT_MIN_LEVEL=1 \
  --env REQUEST_PATH=/file_16G.bin \
  --env PAYLOAD_BYTES=17179869184 \
  --env GQ_P6_DROP_EVERY_N=100000 \
  --env GQ_P6_DROP_START_AFTER=10000 \
  --env GQ_P6_CWND_CAP_BYTES=65536 \
  "$@"
