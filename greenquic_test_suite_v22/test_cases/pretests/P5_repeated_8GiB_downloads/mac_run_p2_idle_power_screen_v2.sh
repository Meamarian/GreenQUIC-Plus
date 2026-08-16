#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
V1="$HERE/mac_run_p2_idle_power_screen.sh"
[[ -f "$V1" ]] || { echo "ERROR: missing $V1" >&2; exit 2; }

TMP="${TMPDIR:-/tmp}/mac_run_p2_idle_power_screen_v2_${$}.sh"
cp "$V1" "$TMP"
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = '''ssh "${SSH_OPTS[@]}" idex "while ! scp -o ConnectTimeout=15 '$REMOTE_BUNDLE' root@tinyman:'$REMOTE_BUNDLE'; do sleep 30; done"'''
new = '''until ssh "${SSH_OPTS[@]}" idex "scp -o ConnectTimeout=15 '$REMOTE_BUNDLE' root@tinyman:'$REMOTE_BUNDLE'"; do
    log "idex -> tinyman bundle SCP failed; retry in 30 s"
    sleep 30
done'''
if s.count(old) != 1:
    raise SystemExit(f"ERROR: bundle retry anchor count={s.count(old)}")
s = s.replace(old, new, 1)
old = '''ssh "${SSH_OPTS[@]}" idex "cd /root/mohsen && git reset --hard && git fetch '$REMOTE_BUNDLE' '$REF' && git checkout -B '$BRANCH' FETCH_HEAD && test \\\"\\$(git rev-parse HEAD)\\\" = '$SHA'"
ssh "${SSH_OPTS[@]}" idex "ssh -o ConnectTimeout=15 root@tinyman \\\"cd /root/mohsen && git reset --hard && git fetch '$REMOTE_BUNDLE' '$REF' && git checkout -B '$BRANCH' FETCH_HEAD && test \\\\\\\"\\\\\\\$(git rev-parse HEAD)\\\\\\\" = '$SHA'\\\""'''
# The exact quoting in V1 is intentionally not patched here; the important
# transient failure before checkout is the idex->tinyman bundle copy. V1's
# subsequent wait_clean_both still verifies both nodes before execution.
p.write_text(s)
print("P2 IDLE/POWER V2 PATCH PASS")
PY
bash -n "$TMP"
trap 'rm -f "$TMP"' EXIT INT TERM
exec bash "$TMP" "$@"
