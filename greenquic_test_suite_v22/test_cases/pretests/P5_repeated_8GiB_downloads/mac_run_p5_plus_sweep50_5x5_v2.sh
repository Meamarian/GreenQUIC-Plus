#!/usr/bin/env bash
# Safe Mac-side v2 entry point for the P5 PLUS 50x5x5 sweep.
# It reuses the main launcher but points it at the corrected remote helper.
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$HERE/mac_run_p5_plus_sweep50_5x5.sh"
TMP="$(mktemp "$HERE/.mac_run_p5_plus_sweep50_5x5_v2.XXXXXX.sh")"

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

old = 'REMOTE_HELPER="$P5/run_p5_plus_sweep50_5x5_from_idex.sh"'
new = 'REMOTE_HELPER="$P5/run_p5_plus_sweep50_5x5_from_idex_v2.sh"'

count = text.count(old)
if count != 1:
    raise SystemExit(f"ERROR: expected one REMOTE_HELPER assignment, found {count}")
text = text.replace(old, new, 1)

target.write_text(text, encoding="utf-8")
PY

chmod 0700 "$TMP"

set +e
bash "$TMP"
rc=$?
set -e

exit "$rc"
