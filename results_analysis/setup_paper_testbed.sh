#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/paper_testbed_defaults.sh"

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
