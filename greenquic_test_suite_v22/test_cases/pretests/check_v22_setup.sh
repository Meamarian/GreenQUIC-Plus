#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(cd -- "$HERE/../.." && pwd)"
source "$ROOT/suite.env"
fail=0
for p in "$MSQUIC_DIR" "$DPDK_DIR" "$GQ_INTEROP_SERVER_BIN" "$GQ_INTEROP_CLIENT_BIN"; do
  if [[ ! -e "$p" ]]; then echo "MISSING: $p"; fail=1; else echo "OK: $p"; fi
done
for var in SERVER_DPDK_DEVICE CLIENT_DPDK_DEVICE SERVER_LOCAL_MAC CLIENT_LOCAL_MAC; do
  val="${!var:-}"
  if [[ -z "$val" || "$val" == '<SET_'* ]]; then echo "CONFIGURE: $var in $ROOT/suite.env"; fail=1; else echo "OK: $var=$val"; fi
done
printf 'host=%s expected_server=%s expected_client=%s server_ip=%s client_ip=%s\n' "$(hostname -s)" "$SERVER_NAME" "$CLIENT_NAME" "$SERVER_LOCAL_IP" "$CLIENT_LOCAL_IP"
exit "$fail"
