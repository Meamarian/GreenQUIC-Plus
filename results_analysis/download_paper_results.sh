#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/paper_testbed_defaults.sh"

cd "$GQ_CONTROL_REPO"
exec bash results_analysis/download_latest_reproduction.sh \
  --server-host "$GQ_SERVER_HOST" \
  --bastion "$GQ_BASTION" \
  --ssh-key "$GQ_SSH_KEY" \
  "$@"
