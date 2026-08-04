#!/usr/bin/env bash
set -euo pipefail

printf 'WARNING: run_local.sh puts server and client on one package. Their RAPL intervals overlap and cannot be interpreted as independent endpoint energy. Use two hosts for authoritative energy results.\n' >&2
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
MODE="${1:-}"
APPROX="${2:-}"
SERVER_LOG="$HERE/logs/local_server_launcher_$(date +%Y%m%d_%H%M%S).log"
"$HERE/run_server.sh" "$MODE" >"$SERVER_LOG" 2>&1 &
server_pid=$!
cleanup() { kill -TERM "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
sleep 3
if [[ "$APPROX" == "--approximate" ]]; then
  "$HERE/run_client.sh" "$MODE" --approximate
else
  "$HERE/run_client.sh" "$MODE"
fi
