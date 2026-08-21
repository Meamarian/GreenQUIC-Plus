#!/usr/bin/env bash
set -Eeuo pipefail

# Safe CONTROL-HOST synchronization helper for the supported paper wrappers.
#
# It never discards local work. It only fast-forwards a clean local `main`
# checkout when the local HEAD is an ancestor of origin/main. If the checkout
# is dirty, on another branch, ahead of origin/main, or diverged, it fails and
# asks the operator to resolve that state explicitly.
#
# Exit codes:
#   0  already at exact origin/main
#   10 safely fast-forwarded; caller should re-exec itself from the new tree
#   other nonzero  unsafe/incompatible local Git state

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${GQ_CONTROL_REPO:-$(cd -- "$HERE/.." && pwd)}"

fail(){ echo "CONTROL MAIN SYNC: FAIL: $*" >&2; exit 2; }

[[ -d "$ROOT/.git" ]] || fail "not a Git checkout: $ROOT"
cd "$ROOT"

ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
case "$ORIGIN_URL" in
  git@github.com:Meamarian/GreenQUIC-Plus.git|https://github.com/Meamarian/GreenQUIC-Plus.git) ;;
  *) fail "origin must be Meamarian/GreenQUIC-Plus, got: ${ORIGIN_URL:-none}" ;;
esac

BRANCH="$(git branch --show-current)"
[[ "$BRANCH" == main ]] || fail "CONTROL checkout must be on main; current branch is ${BRANCH:-detached}"

if [[ -n "$(git status --porcelain=v1 --untracked-files=all)" ]]; then
  fail "CONTROL checkout has uncommitted/untracked changes; preserve or commit them before paper setup/run"
fi

# Explicit refspec also repairs clones originally created with --single-branch.
git fetch origin '+refs/heads/main:refs/remotes/origin/main'
LOCAL_SHA="$(git rev-parse HEAD)"
REMOTE_SHA="$(git rev-parse refs/remotes/origin/main)"

if [[ "$LOCAL_SHA" == "$REMOTE_SHA" ]]; then
  echo "CONTROL MAIN SYNC: PASS head=$LOCAL_SHA"
  exit 0
fi

if ! git merge-base --is-ancestor "$LOCAL_SHA" "$REMOTE_SHA"; then
  fail "local main is ahead of or diverged from origin/main (local=$LOCAL_SHA remote=$REMOTE_SHA); refusing to reset unique local commits"
fi

# Safe because the checkout is clean and local HEAD is strictly behind remote.
git reset --hard "$REMOTE_SHA"
echo "CONTROL MAIN SYNC: FAST-FORWARDED old=$LOCAL_SHA new=$REMOTE_SHA"
exit 10
