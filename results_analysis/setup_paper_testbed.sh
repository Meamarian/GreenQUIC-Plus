#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/paper_testbed_defaults.sh"

# Make the high-level paper entrypoint safe for a clone that is merely behind
# origin/main. Never discard local work or unique local commits. If a safe
# fast-forward occurred, re-exec this wrapper from the refreshed tree so the
# orchestration code itself is the exact current main version.
sync_rc=0
bash "$HERE/control_main_sync.sh" || sync_rc=$?
case "$sync_rc" in
  0) ;;
  10) exec bash "$GQ_CONTROL_REPO/results_analysis/setup_paper_testbed.sh" "$@" ;;
  *) exit "$sync_rc" ;;
esac

usage() {
  cat <<'USAGE'
GreenQUIC+ paper-testbed deployment/build wrapper

RUN ON: CONTROL HOST

Paper defaults come from results_analysis/paper_testbed_defaults.sh.
Override management routing without editing files:
  --server-host HOST              SERVER as seen from CONTROL/BASTION
  --client-host HOST              CLIENT as seen from CONTROL/BASTION
  --server-to-client-host HOST    CLIENT as seen from SERVER; defaults to --client-host
  --bastion USER@HOST|none        optional SSH jump/bootstrap host
  --ssh-key PATH                  CONTROL private key; only its public half is installed on nodes
  -h, --help

This wrapper deploys exact origin/main by Git bundle, prepares both hosts, and
builds/verifies P5 and P7. It does not allocate/reimage POS nodes.
The complete CONTROL-side stdout/stderr stream is recorded under
results_analysis/runtime/ so live_monitor_setup.sh can follow the exact run.
After successful provisioning it also records the effective CONTROL/SERVER/
CLIENT dependency versions in that same setup log.
USAGE
}

server_to_client_explicit=0
while (($#)); do
  case "$1" in
    --server-host) [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --server-host needs a value" >&2; exit 2; }; GQ_SERVER_HOST="$2"; shift 2 ;;
    --client-host) [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --client-host needs a value" >&2; exit 2; }; GQ_CLIENT_HOST="$2"; shift 2 ;;
    --server-to-client-host) [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --server-to-client-host needs a value" >&2; exit 2; }; GQ_SERVER_TO_CLIENT_HOST="$2"; server_to_client_explicit=1; shift 2 ;;
    --bastion) [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --bastion needs a value" >&2; exit 2; }; GQ_BASTION="$2"; shift 2 ;;
    --ssh-key) [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --ssh-key needs a value" >&2; exit 2; }; GQ_SSH_KEY="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
if (( server_to_client_explicit == 0 )); then
  GQ_SERVER_TO_CLIENT_HOST="$GQ_CLIENT_HOST"
fi

cd "$GQ_CONTROL_REPO"
RUNTIME_DIR="$GQ_CONTROL_REPO/results_analysis/runtime"
STATE_FILE="$RUNTIME_DIR/current_setup_operation"
mkdir -p "$RUNTIME_DIR"
if [[ -s "$STATE_FILE" ]]; then
  old_pid="$(sed -n '1p' "$STATE_FILE" 2>/dev/null || true)"
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
    echo "ERROR: another setup/rebuild operation is already active on this CONTROL HOST (pid=$old_pid)" >&2
    exit 2
  fi
fi
LOG_FILE="$RUNTIME_DIR/setup_$(date +%Y%m%d_%H%M%S)_$$.log"
printf '%s\n%s\n' "$$" "$LOG_FILE" > "$STATE_FILE"
cleanup_state(){ rm -f "$STATE_FILE"; }
trap cleanup_state EXIT
trap 'cleanup_state; exit 130' INT
trap 'cleanup_state; exit 143' TERM
exec > >(tee -a "$LOG_FILE") 2>&1
printf 'CONTROL_LIVE_LOG=%s\n' "$LOG_FILE"

python3 results_analysis/verify_paper_configuration.py

printf '%s\n' \
  'GREENQUIC+ PAPER TESTBED SETUP' \
  'RUN ON: CONTROL HOST' \
  "SERVER=$GQ_SERVER_HOST" \
  "CLIENT(control view)=$GQ_CLIENT_HOST" \
  "CLIENT(server view)=$GQ_SERVER_TO_CLIENT_HOST" \
  "BASTION=$GQ_BASTION" \
  "SSH_KEY=$GQ_SSH_KEY"

bash tum_testbed_setup/greenquic_fresh_setup.sh \
  --server-host "$GQ_SERVER_HOST" \
  --client-host "$GQ_CLIENT_HOST" \
  --server-to-client-host "$GQ_SERVER_TO_CLIENT_HOST" \
  --bastion "$GQ_BASTION" \
  --ssh-key "$GQ_SSH_KEY"

echo
echo "===== EFFECTIVE DEPENDENCY/VERSION SNAPSHOT AFTER SETUP ====="
bash results_analysis/print_dependency_versions.sh \
  --server-host "$GQ_SERVER_HOST" \
  --client-host "$GQ_CLIENT_HOST" \
  --bastion "$GQ_BASTION" \
  --ssh-key "$GQ_SSH_KEY"

echo "DEPENDENCY VERSION SNAPSHOT: PASS"
