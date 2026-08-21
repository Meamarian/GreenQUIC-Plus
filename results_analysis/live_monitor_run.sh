#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/paper_testbed_defaults.sh"

usage() {
  cat <<'USAGE'
GreenQUIC+ final-run live log monitor

RUN ON: a second CONTROL-HOST terminal

By default this reads the exact tag written by run_paper_evaluation.sh and tails
that run's SERVER-side GQ_FAIR_REPRO log. This prevents attachment to an older
reproduction log that happens to be newer than expected.

Options:
  --server-host HOST       SERVER as seen from CONTROL/BASTION
  --bastion USER@HOST|none optional ProxyJump
  --ssh-key PATH           CONTROL private key
  --tag STRING             explicitly select a run tag instead of latest_run_tag
  -h, --help
USAGE
}

RUN_TAG=""
while (($#)); do
  case "$1" in
    --server-host) [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --server-host needs a value" >&2; exit 2; }; GQ_SERVER_HOST="$2"; shift 2 ;;
    --bastion) [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --bastion needs a value" >&2; exit 2; }; GQ_BASTION="$2"; shift 2 ;;
    --ssh-key) [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --ssh-key needs a value" >&2; exit 2; }; GQ_SSH_KEY="$2"; shift 2 ;;
    --tag) [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --tag needs a value" >&2; exit 2; }; RUN_TAG="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$RUN_TAG" ]]; then
  TAG_FILE="$GQ_CONTROL_REPO/results_analysis/runtime/latest_run_tag"
  [[ -s "$TAG_FILE" ]] || {
    echo "ERROR: no latest run tag found at $TAG_FILE; start run_paper_evaluation.sh first or pass --tag" >&2
    exit 2
  }
  RUN_TAG="$(sed -n '1p' "$TAG_FILE")"
fi
[[ "$RUN_TAG" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "ERROR: invalid run tag: $RUN_TAG" >&2; exit 2; }

[[ -f "$GQ_SSH_KEY" ]] || { echo "ERROR: SSH key not found: $GQ_SSH_KEY" >&2; exit 2; }
SSH_OPTS=(-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o StrictHostKeyChecking=accept-new -i "$GQ_SSH_KEY" -o IdentitiesOnly=yes)
if [[ -n "$GQ_BASTION" && "$GQ_BASTION" != none ]]; then SSH_OPTS+=(-J "$GQ_BASTION"); fi

REMOTE_LOG="/root/GQ_FAIR_REPRO_${RUN_TAG}.log"
printf 'RUN ON: second CONTROL-HOST terminal\nSERVER=%s\nBASTION=%s\nTAG=%s\nREMOTE_LOG=%s\n' \
  "$GQ_SERVER_HOST" "$GQ_BASTION" "$RUN_TAG" "$REMOTE_LOG"

ssh "${SSH_OPTS[@]}" "$GQ_REMOTE_USER@$GQ_SERVER_HOST" bash -s -- "$REMOTE_LOG" <<'REMOTE'
set -Eeuo pipefail
log="$1"
while [[ ! -f "$log" ]]; do
  echo "Waiting for exact run log: $log"
  sleep 2
done
echo "FOLLOWING: $log"
echo
exec tail -n +1 -F "$log"
REMOTE
