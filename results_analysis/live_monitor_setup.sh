#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/paper_testbed_defaults.sh"

usage() {
  cat <<'USAGE'
GreenQUIC+ setup/build live monitor

RUN ON: a second CONTROL-HOST terminal

Options:
  --server-host HOST       SERVER as seen from CONTROL/BASTION
  --client-host HOST       CLIENT as seen from CONTROL/BASTION
  --bastion USER@HOST|none optional ProxyJump
  --ssh-key PATH           CONTROL private key
  -h, --help
USAGE
}

while (($#)); do
  case "$1" in
    --server-host) [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --server-host needs a value" >&2; exit 2; }; GQ_SERVER_HOST="$2"; shift 2 ;;
    --client-host) [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --client-host needs a value" >&2; exit 2; }; GQ_CLIENT_HOST="$2"; shift 2 ;;
    --bastion) [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --bastion needs a value" >&2; exit 2; }; GQ_BASTION="$2"; shift 2 ;;
    --ssh-key) [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --ssh-key needs a value" >&2; exit 2; }; GQ_SSH_KEY="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -f "$GQ_SSH_KEY" ]] || { echo "ERROR: SSH key not found: $GQ_SSH_KEY" >&2; exit 2; }
SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -i "$GQ_SSH_KEY" -o IdentitiesOnly=yes)
if [[ -n "$GQ_BASTION" && "$GQ_BASTION" != none ]]; then SSH_OPTS+=(-J "$GQ_BASTION"); fi

printf 'RUN ON: second CONTROL-HOST terminal\nSERVER=%s\nCLIENT=%s\nBASTION=%s\n' "$GQ_SERVER_HOST" "$GQ_CLIENT_HOST" "$GQ_BASTION"
while true; do
  clear
  date
  for pair in "SERVER:$GQ_SERVER_HOST" "CLIENT:$GQ_CLIENT_HOST"; do
    role="${pair%%:*}"
    host="${pair#*:}"
    echo
    echo "===== $role ($host) ====="
    ssh "${SSH_OPTS[@]}" "$GQ_REMOTE_USER@$host" \
      'printf "hostname="; hostname; printf "branch="; git -C /root/mohsen branch --show-current 2>/dev/null || echo repo-not-ready; printf "head="; git -C /root/mohsen rev-parse --short HEAD 2>/dev/null || echo repo-not-ready; echo "active setup/build processes:"; pgrep -af "apt-get|meson|ninja|cmake|build_p5|build_p7|greenquic_fresh_setup" || echo none; printf "test NIC driver="; basename "$(readlink -f /sys/bus/pci/devices/0000:18:00.0/driver 2>/dev/null)" 2>/dev/null || echo unavailable' \
      || echo "SSH unavailable"
  done
  sleep 10
done
