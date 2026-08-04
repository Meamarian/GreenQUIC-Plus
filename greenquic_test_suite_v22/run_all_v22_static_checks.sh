#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
python3 -m compileall -q "$ROOT/common/bin"
while IFS= read -r script; do bash -n "$script"; done < <(find "$ROOT" -type f -name '*.sh' -print)
python3 "$ROOT/common/bin/audit_v22_suite.py" --suite-root "$ROOT"
python3 "$ROOT/common/bin/selftest_v21_suite.py"
python3 "$ROOT/common/bin/verify_v22_install.py" --help >/dev/null
printf '
V22 static suite checks passed.
'
