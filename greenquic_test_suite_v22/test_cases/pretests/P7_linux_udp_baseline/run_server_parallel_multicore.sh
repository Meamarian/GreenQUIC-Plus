#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
BASE="$HERE/run_server.sh"
TMP="$(mktemp "$HERE/.run_server_parallel.XXXXXX.sh")"
trap 'rm -f "$TMP"' EXIT
python3 - "$BASE" "$TMP" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text(encoding='utf-8')
old='python3 "$HERE/report_p7_run.py"'
new='python3 "$HERE/report_p7_parallel_run.py"'
if s.count(old)!=1:raise SystemExit(f'ERROR: expected one P7 server reporter anchor, found {s.count(old)}')
Path(sys.argv[2]).write_text(s.replace(old,new,1),encoding='utf-8')
PY
chmod 0700 "$TMP";exec bash "$TMP" "$@"
