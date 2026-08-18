#!/usr/bin/env bash
# Build the same PLUS-only/no-chart temporary execution path used by the 50-case
# sweep, then run only the TOP3 combination for five independent 5-download runs.
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$HERE/run_p5_plus_sweep50_5x5_from_idex.sh"
TMP="$(mktemp "$HERE/.run_p5_plus_top3_combo_5x5.XXXXXX.sh")"

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

# v1 sweep helper had ssh -n while feeding a Python heredoc to Tinyman.
old = 'ssh -n "$CLIENT_HOST" "python3 - $(printf \'%q\' "$CLIENT_DIR") $(printf \'%q\' "$TAG")" <<\'PY\''
new = 'ssh "$CLIENT_HOST" "python3 - $(printf \'%q\' "$CLIENT_DIR") $(printf \'%q\' "$TAG")" <<\'PY\''
if text.count(old) != 1:
    raise SystemExit(f"ERROR: expected one Tinyman heredoc ssh -n site, found {text.count(old)}")
text = text.replace(old, new, 1)

# Reuse all temporary PLUS-only/no-chart wiring, but call the one-combination
# controller instead of the 50-case controller.
old_controller = 'python3 -u "$HERE/p5_plus_sweep50_5x5.py" \\\n'
new_controller = 'python3 -u "$HERE/p5_plus_top3_combo_5x5.py" \\\n'
if text.count(old_controller) != 1:
    raise SystemExit(f"ERROR: expected one sweep controller invocation, found {text.count(old_controller)}")
text = text.replace(old_controller, new_controller, 1)

text = text.replace(
    'P5 PLUS 50-CONFIG x 5-RUN SWEEP',
    'P5 PLUS TOP3 COMBO x 5 RUN x 5 DOWNLOAD',
)

needle = 'mkdir -p "$OUT"\nrm -f "$DONE" "$FAILED" "$SUMMARY"\n'
replacement = (
    'mkdir -p "$OUT"\n'
    'rm -f "$DONE" "$FAILED" "$SUMMARY"\n'
    'echo "[P5-TOP3] helper startup tag=$TAG host=$(hostname -s)"\n'
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
