#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
V2="$HERE/mac_run_p5_p7_fair_repro_6x5_v2.sh"
[[ -f "$V2" ]] || { echo "ERROR: missing V2 launcher: $V2" >&2; exit 2; }

# GreenQUIC-Plus uses main as the authoritative final paper/development branch.
export GQ_FAIR_BRANCH="${GQ_FAIR_BRANCH:-main}"
[[ "$GQ_FAIR_BRANCH" == main ]] || {
    echo "ERROR: GreenQUIC-Plus fair reproduction must use branch main" >&2
    exit 2
}

# V2 generates its final launcher in /tmp. Export the real repository root
# before V2 execs that temporary copy; otherwise dirname($0) would point to
# /tmp and repository discovery would fail before the remote job is created.
REPO_ROOT="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO_ROOT" && -d "$REPO_ROOT/.git" ]] || {
    echo "ERROR: cannot resolve GreenQUIC-Plus repository root from $HERE" >&2
    exit 2
}

ORIGIN_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
case "$ORIGIN_URL" in
  git@github.com:Meamarian/GreenQUIC-Plus.git|https://github.com/Meamarian/GreenQUIC-Plus.git) ;;
  *)
    echo "ERROR: origin must be Meamarian/GreenQUIC-Plus, got: ${ORIGIN_URL:-none}" >&2
    exit 2
    ;;
esac

export GREENQUIC_REPO="$REPO_ROOT"

[[ "$(git -C "$GREENQUIC_REPO" rev-parse --show-toplevel)" == "$GREENQUIC_REPO" ]] || {
    echo "ERROR: GREENQUIC_REPO validation failed: $GREENQUIC_REPO" >&2
    exit 2
}

exec bash "$V2" "$@"
