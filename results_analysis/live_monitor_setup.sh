#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/paper_testbed_defaults.sh"

usage() {
  cat <<'USAGE'
GreenQUIC+ setup/rebuild live log monitor

RUN ON: a second CONTROL-HOST terminal

This follows the exact CONTROL-side stdout/stderr log created by the currently
active setup_paper_testbed.sh or rebuild_paper_binaries.sh process. Because the
log is local to CONTROL, monitoring works even before fresh nodes accept SSH.

The management options below are accepted for command-line symmetry with older
examples but are not needed to read the local CONTROL log:
  --server-host HOST
  --client-host HOST
  --bastion USER@HOST|none
  --ssh-key PATH
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

RUNTIME_DIR="$GQ_CONTROL_REPO/results_analysis/runtime"
STATE_FILE="$RUNTIME_DIR/current_setup_operation"
printf 'RUN ON: second CONTROL-HOST terminal\nWAITING FOR ACTIVE SETUP/REBUILD LOG\n'

while true; do
  if [[ -s "$STATE_FILE" ]]; then
    op_pid="$(sed -n '1p' "$STATE_FILE" 2>/dev/null || true)"
    log_file="$(sed -n '2p' "$STATE_FILE" 2>/dev/null || true)"
    if [[ "$op_pid" =~ ^[0-9]+$ ]] && kill -0 "$op_pid" 2>/dev/null && [[ -n "$log_file" ]]; then
      if [[ -f "$log_file" ]]; then
        echo "FOLLOWING CONTROL LOG: $log_file"
        echo "OPERATION PID: $op_pid"
        echo
        exec tail -n +1 -F "$log_file"
      fi
      echo "Operation pid=$op_pid is active; waiting for log file $log_file ..."
    fi
  fi
  echo "No active setup/rebuild operation found yet; waiting..."
  sleep 2
done
