#!/usr/bin/env bash
set -Eeuo pipefail

# RUN ON: CONTROL HOST. This is the simple manual/re-download entrypoint.
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/paper_testbed_defaults.sh"

cd "$GQ_CONTROL_REPO"
ARGS=(
  --server-host "$GQ_SERVER_HOST"
  --bastion "$GQ_BASTION"
  --ssh-key "$GQ_SSH_KEY"
  --expect-runs 6
  --expect-downloads 5
)
TAG_FILE="$GQ_CONTROL_REPO/results_analysis/runtime/latest_run_tag"
if [[ -s "$TAG_FILE" ]]; then
  ARGS+=(--tag "$(sed -n '1p' "$TAG_FILE")")
fi

# User-supplied options come last and may intentionally override --tag/destination.
exec bash results_analysis/download_latest_reproduction.sh "${ARGS[@]}" "$@"
