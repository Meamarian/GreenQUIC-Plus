#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/paper_testbed_defaults.sh"

usage() {
  cat <<'USAGE'
GreenQUIC+ final-run live monitor

RUN ON: a second CONTROL-HOST terminal

Options:
  --server-host HOST       SERVER as seen from CONTROL/BASTION
  --bastion USER@HOST|none optional ProxyJump
  --ssh-key PATH           CONTROL private key
  -h, --help
USAGE
}

while (($#)); do
  case "$1" in
    --server-host) [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --server-host needs a value" >&2; exit 2; }; GQ_SERVER_HOST="$2"; shift 2 ;;
    --bastion) [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --bastion needs a value" >&2; exit 2; }; GQ_BASTION="$2"; shift 2 ;;
    --ssh-key) [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --ssh-key needs a value" >&2; exit 2; }; GQ_SSH_KEY="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -f "$GQ_SSH_KEY" ]] || { echo "ERROR: SSH key not found: $GQ_SSH_KEY" >&2; exit 2; }
SSH_OPTS=(-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o StrictHostKeyChecking=accept-new -i "$GQ_SSH_KEY" -o IdentitiesOnly=yes)
if [[ -n "$GQ_BASTION" && "$GQ_BASTION" != none ]]; then SSH_OPTS+=(-J "$GQ_BASTION"); fi

printf 'RUN ON: second CONTROL-HOST terminal\nSERVER=%s\nBASTION=%s\n' "$GQ_SERVER_HOST" "$GQ_BASTION"
ssh "${SSH_OPTS[@]}" "$GQ_REMOTE_USER@$GQ_SERVER_HOST" '
while true; do
  log=$(find /root -maxdepth 1 -type f -name "GQ_FAIR_REPRO_*.log" -printf "%T@ %p\n" 2>/dev/null | sort -nr | sed -n "1p" | cut -d" " -f2-)
  if [ -n "$log" ]; then
    echo "FOLLOWING: $log"
    echo
    exec tail -n +1 -F "$log"
  fi
  echo "No GQ_FAIR_REPRO log found yet; waiting..."
  sleep 2
done
'
