#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
cat <<'EOF'
Run the matching server and client with the same GreenQUIC mode and idle mode.
This comparison helper disables the testcase's fixed-mode evidence gate; inspect
V21 stats and run the dedicated default case to prove a specific mechanism.
EOF
for idle in off short pause monitor epoll auto; do
  printf '
Start server with: GQ_IDLE_MODE_OVERRIDE=%s VALIDATE_IDLE_EVIDENCE=0 ./run_server.sh plus
' "$idle"
  read -r -p "Press Enter when the matching server is ready, or type skip: " ans
  [[ "$ans" == skip ]] && continue
  GQ_IDLE_MODE_OVERRIDE="$idle" VALIDATE_IDLE_EVIDENCE=0 "$HERE/run_client.sh" plus "$@"
done
