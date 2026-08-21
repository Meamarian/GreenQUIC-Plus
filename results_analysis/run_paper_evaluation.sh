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

usage() {
  cat <<'USAGE'
GreenQUIC+ final paper evaluation wrapper

RUN ON: CONTROL HOST

Paper defaults come from results_analysis/paper_testbed_defaults.sh.
Override management routing without editing files:
  --server-host HOST       SERVER as seen from CONTROL/BASTION
  --client-host HOST       CLIENT as seen from SERVER
  --bastion USER@HOST|none optional ProxyJump for CONTROL -> SERVER
  --ssh-key PATH           CONTROL private key for CONTROL -> SERVER
  --tag STRING             optional exact result/log tag
  -h, --help

The exact paper workload/configuration remains fixed by the authoritative
launcher; this wrapper exposes management routing and an optional run tag.
The selected tag is recorded locally so live_monitor_run.sh follows this exact
run instead of accidentally attaching to an older GQ_FAIR_REPRO log.
USAGE
}

RUN_TAG="${GQ_FAIR_TAG:-}"
while (($#)); do
  case "$1" in
    --server-host) [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --server-host needs a value" >&2; exit 2; }; GQ_SERVER_HOST="$2"; shift 2 ;;
    --client-host) [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --client-host needs a value" >&2; exit 2; }; GQ_SERVER_TO_CLIENT_HOST="$2"; shift 2 ;;
    --bastion) [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --bastion needs a value" >&2; exit 2; }; GQ_BASTION="$2"; shift 2 ;;
    --ssh-key) [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --ssh-key needs a value" >&2; exit 2; }; GQ_SSH_KEY="$2"; shift 2 ;;
    --tag) [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: --tag needs a value" >&2; exit 2; }; RUN_TAG="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

RUN_TAG="${RUN_TAG:-$(date +%Y%m%d_%H%M%S)}"
[[ "$RUN_TAG" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "ERROR: --tag may contain only letters, digits, dot, underscore, and dash" >&2; exit 2; }

cd "$GQ_CONTROL_REPO"
RUNTIME_DIR="$GQ_CONTROL_REPO/results_analysis/runtime"
mkdir -p "$RUNTIME_DIR"
printf '%s\n' "$RUN_TAG" > "$RUNTIME_DIR/latest_run_tag"

python3 results_analysis/verify_paper_configuration.py

printf '%s\n' \
  'GREENQUIC+ FINAL PAPER EVALUATION' \
  'RUN ON: CONTROL HOST' \
  "SERVER=$GQ_SERVER_HOST" \
  "CLIENT(server view)=$GQ_SERVER_TO_CLIENT_HOST" \
  "BASTION=$GQ_BASTION" \
  "SSH_KEY=$GQ_SSH_KEY" \
  "TAG=$RUN_TAG"

exec bash greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_p7_fair_repro_6x5.sh \
  --server-host "$GQ_SERVER_HOST" \
  --client-host "$GQ_SERVER_TO_CLIENT_HOST" \
  --bastion "$GQ_BASTION" \
  --ssh-key "$GQ_SSH_KEY" \
  --tag "$RUN_TAG"
