\
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
chmod -R u+rwX "$ROOT"
find "$ROOT" -type f -name '*.sh' -exec chmod 755 {} +
find "$ROOT/common/bin" -type f \( -name '*.py' -o -name 'gap_wait.c' \) -exec chmod 755 {} +
rm -rf "$ROOT"/**/__pycache__ 2>/dev/null || true
"$ROOT/run_all_v22_static_checks.sh"
echo "Installed GreenQUIC V22 suite at $ROOT"
