#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
cat <<'EOF'
This helper runs client modes in order. Start the matching server mode manually
on the server machine before each step, because server and client must use the
same intended mode/configuration for a clean comparison.
EOF
for mode in off basic plus; do
  printf '\nReady for mode=%s. Start: ./run_server.sh %s on server.\n' "$mode" "$mode"
  read -r -p "Press Enter when server is ready, or type skip: " ans
  [[ "$ans" == skip ]] && continue
  "$HERE/run_client.sh" "$mode" "$@"
done
