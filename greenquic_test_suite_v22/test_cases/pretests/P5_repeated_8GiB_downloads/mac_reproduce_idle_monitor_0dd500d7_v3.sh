#!/usr/bin/env bash
set -Eeuo pipefail

# Thin validated launcher for the pinned historical reproduction controller.
# It corrects the remote $! escaping in v2 without changing measurement logic.

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
SRC="$HERE/mac_reproduce_idle_monitor_0dd500d7_v2.sh"
[[ -f "$SRC" ]] || { echo "ERROR: missing reproduction controller: $SRC" >&2; exit 2; }

TAG="$(date +%Y%m%d_%H%M%S)_$$"
TMP="${TMPDIR:-/tmp}/mac_reproduce_idle_monitor_0dd500d7_v3_${TAG}.sh"

python3 - "$SRC" "$TMP" <<'PY'
from pathlib import Path
import sys

src=Path(sys.argv[1]).read_text(encoding='utf-8')
lines=src.splitlines(True)
count=0
out=[]
for line in lines:
    if line.startswith('REMOTE_PID="$(ssh ') and '& echo ' in line:
        prefix=line.split('& echo ',1)[0]
        # Desired shell source is: ... & echo \$!")"
        # One backslash prevents the Mac shell expanding $!, so the remote
        # idex shell returns the PID of the detached runner it just launched.
        line=prefix + '& echo \\$!\")"\n'
        count += 1
    out.append(line)
if count != 1:
    raise SystemExit(f'ERROR: expected one remote-PID launch line, found {count}')
Path(sys.argv[2]).write_text(''.join(out),encoding='utf-8')
PY

chmod 0700 "$TMP"
bash -n "$TMP"

# Keep TMP in place: when --detach is used, the generated script re-execs its
# own path in the background. /tmp cleanup after reboot is sufficient.
exec bash "$TMP" "$@"
