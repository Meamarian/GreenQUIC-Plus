#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/paper_testbed_defaults.sh"

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -i "$GQ_SSH_KEY" -o IdentitiesOnly=yes)
if [[ -n "$GQ_BASTION" && "$GQ_BASTION" != none ]]; then SSH_OPTS+=(-J "$GQ_BASTION"); fi

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
