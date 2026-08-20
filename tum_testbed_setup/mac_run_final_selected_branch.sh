#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$HERE/.." rev-parse --show-toplevel 2>/dev/null || true)"
PAPER_RUNNER_REL="greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_p7_fair_repro_6x5_v3.sh"
PAPER_RUNNER="$REPO_ROOT/$PAPER_RUNNER_REL"
RUNS=6
DOWNLOADS=5

fail(){ echo "ERROR: $*" >&2; exit 1; }
usage(){ cat <<'USAGE'
Usage:
  bash tum_testbed_setup/mac_run_final_selected_branch.sh main [--runs N] [--downloads N]
  bash tum_testbed_setup/mac_run_final_selected_branch.sh paper [--runs N] [--downloads N]

GreenQUIC-Plus has one authoritative paper/development branch: main.
This wrapper delegates to mac_run_p5_p7_fair_repro_6x5_v3.sh.
USAGE
}

[[ $# -ge 1 ]] || { usage >&2; exit 2; }
INPUT="$1"; shift
case "$INPUT" in
  main|paper) ;;
  *) fail "target must be main or paper" ;;
esac

while (($#)); do
  case "$1" in
    --runs)
      [[ $# -ge 2 ]] || fail "--runs needs a value"
      RUNS="$2"; shift 2
      ;;
    --downloads)
      [[ $# -ge 2 ]] || fail "--downloads needs a value"
      DOWNLOADS="$2"; shift 2
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *) fail "unknown argument: $1" ;;
  esac
done

[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || fail "runs must be positive"
[[ "$DOWNLOADS" =~ ^[1-9][0-9]*$ ]] || fail "downloads must be positive"
[[ -n "$REPO_ROOT" && -d "$REPO_ROOT/.git" ]] || fail "run from a GreenQUIC-Plus Git clone"
[[ -f "$PAPER_RUNNER" ]] || fail "missing final fair runner: $PAPER_RUNNER"

ORIGIN_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
case "$ORIGIN_URL" in
  git@github.com:Meamarian/GreenQUIC-Plus.git|https://github.com/Meamarian/GreenQUIC-Plus.git) ;;
  *) fail "origin must be Meamarian/GreenQUIC-Plus, got: ${ORIGIN_URL:-none}" ;;
esac

cd "$REPO_ROOT"
git fetch origin main
git checkout main
git reset --hard origin/main

export GQ_FAIR_BRANCH=main
export GQ_FAIR_RUNS="$RUNS"
export GQ_FAIR_DOWNLOADS="$DOWNLOADS"

printf 'GreenQUIC+ final fair reproduction\n'
printf 'branch=main\n'
printf 'sha=%s\n' "$(git rev-parse HEAD)"
printf 'runs=%s downloads=%s\n' "$RUNS" "$DOWNLOADS"

exec bash "$PAPER_RUNNER"
