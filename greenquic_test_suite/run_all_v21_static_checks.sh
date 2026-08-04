#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
python3 -m compileall -q "$ROOT/common/bin"
while IFS= read -r script; do bash -n "$script"; done < <(find "$ROOT" -type f -name '*.sh' -print)
python3 "$ROOT/common/bin/audit_v21_suite.py" --suite-root "$ROOT"
python3 "$ROOT/common/bin/selftest_v21_suite.py" --suite-root "$ROOT"
printf '
V21 static suite checks passed.
'
