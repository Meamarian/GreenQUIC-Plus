#!/usr/bin/env bash
# Corrected wrapper for the P5 PLUS 50x5x5 sweep helper.
#
# v1 accidentally used `ssh -n ... <<HEREDOC` while sending the temporary
# Tinyman client builder. `-n` redirects ssh stdin from /dev/null, so the
# remote Python process received no program and the sweep died before startup.
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$HERE/run_p5_plus_sweep50_5x5_from_idex.sh"
TMP="$(mktemp "$HERE/.run_p5_plus_sweep50_5x5_from_idex_v2.XXXXXX.sh")"

cleanup() {
    rm -f -- "$TMP"
}
trap cleanup EXIT INT TERM

python3 - "$SOURCE" "$TMP" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1])
target = Path(sys.argv[2])
text = source.read_text(encoding="utf-8")

old = 'ssh -n "$CLIENT_HOST" "python3 - $(printf \'%q\' "$CLIENT_DIR") $(printf \'%q\' "$TAG")" <<\'PY\''
new = 'ssh "$CLIENT_HOST" "python3 - $(printf \'%q\' "$CLIENT_DIR") $(printf \'%q\' "$TAG")" <<\'PY\''

count = text.count(old)
if count != 1:
    raise SystemExit(
        f"ERROR: expected exactly one Tinyman Python-heredoc ssh -n bug, found {count}"
    )

text = text.replace(old, new, 1)

# Make startup visible immediately in the detached log.
needle = 'mkdir -p "$OUT"\nrm -f "$DONE" "$FAILED" "$SUMMARY"\n'
replacement = (
    'mkdir -p "$OUT"\n'
    'rm -f "$DONE" "$FAILED" "$SUMMARY"\n'
    'echo "[P5-SWEEP] helper startup tag=$TAG host=$(hostname -s)"\n'
)
if text.count(needle) != 1:
    raise SystemExit("ERROR: helper startup insertion point changed")
text = text.replace(needle, replacement, 1)

target.write_text(text, encoding="utf-8")
PY

chmod 0700 "$TMP"

set +e
bash "$TMP"
rc=$?
set -e

exit "$rc"
