#!/usr/bin/env bash
# Safe Mac-side child-Bash launcher for the P5 PLUS TOP3 combo.
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$HERE/mac_run_p5_plus_sweep50_5x5.sh"
TMP="$(mktemp "$HERE/.mac_run_p5_plus_top3_combo_5x5.XXXXXX.sh")"

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

replacements = [
    (
        'TAG="P5_PLUS_SWEEP50_5RUNS_$(date +%Y%m%d_%H%M%S)"',
        'TAG="P5_PLUS_TOP3_COMBO_5RUNS_$(date +%Y%m%d_%H%M%S)"',
    ),
    (
        'REMOTE_HELPER="$P5/run_p5_plus_sweep50_5x5_from_idex.sh"',
        'REMOTE_HELPER="$P5/run_p5_plus_top3_combo_5x5_from_idex.sh"',
    ),
    (
        'P5 PLUS — 50 CONFIG x 5 RUN x 5 DOWNLOAD SWEEP',
        'P5 PLUS TOP3 COMBO — 5 RUN x 5 DOWNLOAD',
    ),
    (
        '50 configurations x 5 runs/config x 5 downloads/run',
        'TOP3 combo: PRESSURE_UP=450 RX_QUEUE_HIGH=48 ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16\n5 independent runs x 5 downloads/run',
    ),
    (
        '250 P5 workloads / 1250 downloads',
        '5 P5 workloads / 25 downloads',
    ),
    (
        'P5 PLUS SWEEP STARTED',
        'P5 PLUS TOP3 COMBO STARTED',
    ),
]

for old, new in replacements:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"ERROR: expected one occurrence of {old!r}, found {count}")
    text = text.replace(old, new, 1)

# Ensure the two new TOP3 files are present after exact branch synchronization.
needle = "        test -f ./p5_plus_sweep50_5x5.py\n"
extra = (
    needle
    + "        test -f ./run_p5_plus_top3_combo_5x5_from_idex.sh\n"
    + "        test -f ./p5_plus_top3_combo_5x5.py\n"
)
if text.count(needle) != 1:
    raise SystemExit("ERROR: preflight insertion point changed")
text = text.replace(needle, extra, 1)

target.write_text(text, encoding="utf-8")
PY

chmod 0700 "$TMP"
set +e
bash "$TMP"
rc=$?
set -e
exit "$rc"
