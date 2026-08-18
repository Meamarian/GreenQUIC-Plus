#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
V2="$HERE/mac_run_p5_p7_fair_repro_6x5_v2.sh"
[[ -f "$V2" ]] || { echo "ERROR: missing V2 launcher: $V2" >&2; exit 2; }

# V2 generates its final launcher in /tmp. The generated base launcher supports
# GREENQUIC_REPO explicitly, so export the real repository root before V2 execs
# that temporary copy. Otherwise dirname($0) points at /tmp and repo discovery
# fails before the remote job is created.
REPO_ROOT="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO_ROOT" && -d "$REPO_ROOT/.git" ]] || {
    echo "ERROR: cannot resolve GreenQUIC repository root from $HERE" >&2
    exit 2
}

export GREENQUIC_REPO="$REPO_ROOT"

# Regression guard for the exact failure fixed here.
[[ "$(git -C "$GREENQUIC_REPO" rev-parse --show-toplevel)" == "$GREENQUIC_REPO" ]] || {
    echo "ERROR: GREENQUIC_REPO validation failed: $GREENQUIC_REPO" >&2
    exit 2
}

exec bash "$V2" "$@"
