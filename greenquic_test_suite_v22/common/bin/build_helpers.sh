#!/usr/bin/env bash
set -Eeuo pipefail
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

"$CC_BIN" -std=c11 -O2 -Wall -Wextra -Werror \
    "$HERE/rapl_msr_sampler.c" -o "$HERE/gq_rapl_msr_sampler"
chmod +x "$HERE/gq_rapl_msr_sampler"
echo "Built $HERE/gq_rapl_msr_sampler"
