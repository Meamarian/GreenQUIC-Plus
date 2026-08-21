#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/paper_testbed_defaults.sh"

usage(){
  cat <<'USAGE'
GreenQUIC+ dependency/version report

RUN ON: CONTROL HOST

Defaults reproduce our paper management topology:
  SERVER=idex
  CLIENT=tinyman
  BASTION=mohsen@coinbase
  SSH key=$HOME/.ssh/id_ed25519

Options:
  --server-host HOST
  --client-host HOST
  --bastion USER@HOST|none
  --ssh-key PATH
  -h, --help

This is inspection only. It does not build, configure NICs, or start traffic.
USAGE
}

while (($#)); do
  case "$1" in
    --server-host) [[ $# -ge 2 ]] || { echo "ERROR: --server-host needs a value" >&2; exit 2; }; GQ_SERVER_HOST="$2"; shift 2 ;;
    --client-host) [[ $# -ge 2 ]] || { echo "ERROR: --client-host needs a value" >&2; exit 2; }; GQ_CLIENT_HOST="$2"; shift 2 ;;
    --bastion) [[ $# -ge 2 ]] || { echo "ERROR: --bastion needs a value" >&2; exit 2; }; GQ_BASTION="$2"; shift 2 ;;
    --ssh-key) [[ $# -ge 2 ]] || { echo "ERROR: --ssh-key needs a value" >&2; exit 2; }; GQ_SSH_KEY="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

ROOT="$GQ_CONTROL_REPO"
[[ -d "$ROOT/.git" ]] || { echo "ERROR: CONTROL checkout missing: $ROOT" >&2; exit 2; }

printf '%s\n' \
  '======================================================================' \
  'GREENQUIC+ DEPENDENCY VERSION REPORT' \
  'RUN ON: CONTROL HOST' \
  '======================================================================'

echo "CONTROL_HOST=$(hostname)"
echo "CONTROL_REPO=$ROOT"
echo "CONTROL_HEAD=$(git -C "$ROOT" rev-parse HEAD)"
echo "CONTROL_BRANCH=$(git -C "$ROOT" branch --show-current)"
echo "MSQUIC_SOURCE_VERSION=$(sed -n 's/^[[:space:]]*set(QUIC_FULL_VERSION[[:space:]]*\([^)]*\)).*/\1/p' "$ROOT/msquic/CMakeLists.txt" | head -1)"
echo "DPDK_SOURCE_VERSION=$(cat "$ROOT/msquic/deps/dpdk/VERSION")"
echo "CONTROL_GIT=$(git --version 2>/dev/null || true)"
echo "CONTROL_PYTHON=$(python3 --version 2>&1 || true)"
echo "CONTROL_SSH=$(ssh -V 2>&1 | head -1 || true)"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)
[[ -n "$GQ_SSH_KEY" ]] && SSH_OPTS+=(-i "$GQ_SSH_KEY" -o IdentitiesOnly=yes)
if [[ -n "$GQ_BASTION" && "$GQ_BASTION" != none ]]; then
  SSH_OPTS+=(-J "$GQ_BASTION")
fi

remote_report(){
  local role="$1" host="$2"
  echo
  echo "===== $role ROLE: $host ====="
  ssh "${SSH_OPTS[@]}" root@"$host" 'bash -s' <<'REMOTE'
set -Eeuo pipefail
printf 'HOSTNAME=%s\n' "$(hostname)"
printf 'KERNEL=%s\n' "$(uname -r)"
. /etc/os-release
printf 'OS_ID=%s\nOS_VERSION_ID=%s\nOS_CODENAME=%s\n' "$ID" "${VERSION_ID:-}" "${VERSION_CODENAME:-}"
printf 'GIT=%s\n' "$(git --version 2>/dev/null || true)"
printf 'CMAKE=%s\n' "$(cmake --version 2>/dev/null | head -1 || true)"
printf 'MESON=%s\n' "$(meson --version 2>/dev/null || true)"
printf 'NINJA=%s\n' "$(ninja --version 2>/dev/null || true)"
printf 'GCC=%s\n' "$(gcc --version 2>/dev/null | head -1 || true)"
printf 'GXX=%s\n' "$(g++ --version 2>/dev/null | head -1 || true)"
printf 'PYTHON=%s\n' "$(python3 --version 2>&1 || true)"
printf 'OPENSSL=%s\n' "$(openssl version 2>/dev/null || true)"
printf 'ETHTOOL=%s\n' "$(ethtool --version 2>/dev/null | head -1 || true)"
printf 'REPO_HEAD=%s\n' "$(git -C /root/mohsen rev-parse HEAD 2>/dev/null || echo missing)"
printf 'REPO_BRANCH=%s\n' "$(git -C /root/mohsen branch --show-current 2>/dev/null || echo missing)"
printf 'MSQUIC_SOURCE_VERSION=%s\n' "$(sed -n 's/^[[:space:]]*set(QUIC_FULL_VERSION[[:space:]]*\([^)]*\)).*/\1/p' /root/mohsen/msquic/CMakeLists.txt 2>/dev/null | head -1 || true)"
printf 'DPDK_SOURCE_VERSION=%s\n' "$(cat /root/mohsen/msquic/deps/dpdk/VERSION 2>/dev/null || true)"
echo 'KEY_DEBIAN_PACKAGES:'
dpkg-query -W -f='  ${Package}=${Version}\n' \
  cmake meson ninja-build gcc g++ libssl-dev python3 python3-matplotlib \
  python3-numpy ethtool msr-tools lm-sensors irqbalance 2>/dev/null || true
REMOTE
}

remote_report SERVER "$GQ_SERVER_HOST"
remote_report CLIENT "$GQ_CLIENT_HOST"
