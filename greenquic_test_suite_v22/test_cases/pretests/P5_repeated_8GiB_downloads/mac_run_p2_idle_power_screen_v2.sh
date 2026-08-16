#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
V1="$HERE/mac_run_p2_idle_power_screen.sh"
[[ -f "$V1" ]] || { echo "ERROR: missing $V1" >&2; exit 2; }

TMP="${TMPDIR:-/tmp}/mac_run_p2_idle_power_screen_v2_${$}.sh"
cp "$V1" "$TMP"
python3 - "$TMP" <<'PY'
from pathlib import Path
import re
import sys
p = Path(sys.argv[1])
s = p.read_text()

# Retry idex -> tinyman bundle delivery from the Mac, so a transient nested
# SSH failure cannot strand one node on the old branch.
old = '''ssh "${SSH_OPTS[@]}" idex "while ! scp -o ConnectTimeout=15 '$REMOTE_BUNDLE' root@tinyman:'$REMOTE_BUNDLE'; do sleep 30; done"'''
new = '''until ssh "${SSH_OPTS[@]}" idex "scp -o ConnectTimeout=15 '$REMOTE_BUNDLE' root@tinyman:'$REMOTE_BUNDLE'"; do
    log "idex -> tinyman bundle SCP failed; retry in 30 s"
    sleep 30
done'''
if s.count(old) != 1:
    raise SystemExit(f"ERROR: bundle retry anchor count={s.count(old)}")
s = s.replace(old, new, 1)

# The V1 remote command is itself inside shell quoting. Its historical
# '-printf %f\\0' spelling could lose the NUL and concatenate every filename,
# leaving DONE present but SHA256SUMS missing. Replace the manifest emitter
# with find -print0, which remains correct through nested quoting.
matches = [m for m in re.finditer(r'-printf\s+[^|]*%f[^|]*', s) if 'SHA256SUMS.tmp' in s[m.start():m.start()+500]]
if len(matches) != 1:
    matches = list(re.finditer(r'-printf\s+[^|]*%f[^|]*', s))
if len(matches) != 1:
    raise SystemExit(f"ERROR: manifest -printf anchor count={len(matches)}")
m = matches[0]
s = s[:m.start()] + '-print0 ' + s[m.end():]

p.write_text(s)
print("P2 IDLE/POWER V2 PATCH PASS: bundle retry + NUL-safe manifest")
PY
bash -n "$TMP"
trap 'rm -f "$TMP"' EXIT INT TERM
exec bash "$TMP" "$@"
