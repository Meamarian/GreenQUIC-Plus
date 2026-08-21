#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/paper_testbed_defaults.sh"

# Ensure the CONTROL-HOST wrapper and the exact code sent to the experiment
# nodes come from the same current main revision. Safe fast-forward only; local
# work and unique local commits are never discarded.
sync_rc=0
bash "$HERE/control_main_sync.sh" || sync_rc=$?
case "$sync_rc" in
  0) ;;
  10) exec bash "$GQ_CONTROL_REPO/results_analysis/run_paper_evaluation.sh" "$@" ;;
  *) exit "$sync_rc" ;;
esac

cd "$GQ_CONTROL_REPO"
python3 results_analysis/verify_paper_configuration.py

printf '%s\n' \
  'GREENQUIC+ FINAL PAPER EVALUATION' \
  'RUN ON: CONTROL HOST' \
  "SERVER=$GQ_SERVER_HOST" \
  "CLIENT(server view)=$GQ_SERVER_TO_CLIENT_HOST" \
  "BASTION=$GQ_BASTION" \
  "SSH_KEY=$GQ_SSH_KEY"

exec bash greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_p7_fair_repro_6x5.sh \
  --server-host "$GQ_SERVER_HOST" \
  --client-host "$GQ_SERVER_TO_CLIENT_HOST" \
  --bastion "$GQ_BASTION" \
  --ssh-key "$GQ_SSH_KEY"
