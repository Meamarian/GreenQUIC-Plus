#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
CC_BIN="${CC:-cc}"
command -v "$CC_BIN" >/dev/null 2>&1 || {
  echo "ERROR: C compiler not found. Set CC or install cc/gcc/clang." >&2
  exit 1
}
"$CC_BIN" -std=c11 -O2 -Wall -Wextra -Werror \
  "$HERE/gap_wait.c" -o "$HERE/gap_wait"
chmod +x "$HERE/gap_wait"
echo "Built $HERE/gap_wait"
