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

cd "$GQ_CONTROL_REPO"
python3 results_analysis/verify_paper_configuration.py

printf '%s\n' \
  'GREENQUIC+ PAPER TESTBED SETUP' \
  'RUN ON: CONTROL HOST' \
  "SERVER=$GQ_SERVER_HOST" \
  "CLIENT(control view)=$GQ_CLIENT_HOST" \
  "CLIENT(server view)=$GQ_SERVER_TO_CLIENT_HOST" \
  "BASTION=$GQ_BASTION" \
  "SSH_KEY=$GQ_SSH_KEY"

exec bash tum_testbed_setup/greenquic_fresh_setup.sh \
  --server-host "$GQ_SERVER_HOST" \
  --client-host "$GQ_CLIENT_HOST" \
  --server-to-client-host "$GQ_SERVER_TO_CLIENT_HOST" \
  --bastion "$GQ_BASTION" \
  --ssh-key "$GQ_SSH_KEY"
