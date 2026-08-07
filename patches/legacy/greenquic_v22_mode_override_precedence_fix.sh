#!/usr/bin/env bash
set -euo pipefail

SUITE="${GQ_SUITE_ROOT:-/root/mohsen/greenquic_test_suite_v22}"
COMMON="$SUITE/common/bin/gq_common.sh"
MARKER="# GREENQUIC-V22-MODE-OVERRIDE-PRECEDENCE-FIX-V1"

[[ -f "$COMMON" ]] || {
    echo "ERROR: missing $COMMON" >&2
    exit 1
}

stamp="$(date +%Y%m%d_%H%M%S)"
backup="${COMMON}.before_mode_override_fix_${stamp}"

cp -a "$COMMON" "$backup"
echo "Backup: $backup"

python3 - "$COMMON" "$MARKER" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
marker = sys.argv[2]

text = path.read_text(encoding="utf-8")

old = 'local mode="${mode_override:-${GQ_MODE_OVERRIDE:-$DEFAULT_MODE}}"'
new = 'local mode="${GQ_MODE_OVERRIDE:-${mode_override:-$DEFAULT_MODE}}"'

old_count = text.count(old)
new_count = text.count(new)

if old_count:
    print(f"Changing {old_count} mode-resolution expression(s).")
    text = text.replace(old, new)
elif new_count >= 2:
    print("Mode precedence is already corrected.")
else:
    raise SystemExit(
        "ERROR: expected server/client mode-resolution expressions "
        "were not found."
    )

# GQ_MODE_OVERRIDE must be an actual user override, not a value assigned
# automatically by the suite. Individual test wrappers already provide
# their correct default mode.
text, removed_defaults = re.subn(
    r'(?m)^[ \t]*:[ \t]*"\$\{GQ_MODE_OVERRIDE:=basic\}"[ \t]*\n',
    "",
    text,
)

if removed_defaults:
    print(
        f"Removed {removed_defaults} suite-wide automatic "
        "GQ_MODE_OVERRIDE=basic assignment(s)."
    )

# Remove GQ_MODE_OVERRIDE from standalone export lists while preserving
# every other exported variable.
output_lines = []

for line in text.splitlines(keepends=True):
    stripped = line.strip()

    if stripped.startswith("export "):
        indentation = line[:len(line) - len(line.lstrip())]
        newline = "\n" if line.endswith("\n") else ""
        words = stripped.split()

        if "GQ_MODE_OVERRIDE" in words[1:]:
            remaining = [
                word
                for word in words[1:]
                if word != "GQ_MODE_OVERRIDE"
            ]

            if remaining:
                line = (
                    indentation
                    + "export "
                    + " ".join(remaining)
                    + newline
                )
            else:
                line = ""

    output_lines.append(line)

text = "".join(output_lines)

if marker not in text:
    text += f"\n{marker}\n"

if text.count(new) < 2:
    raise SystemExit(
        "ERROR: corrected expression was not found for both "
        "server and client."
    )

if 'GQ_MODE_OVERRIDE:=basic' in text:
    raise SystemExit(
        "ERROR: automatic GQ_MODE_OVERRIDE default still exists."
    )

path.write_text(text, encoding="utf-8")
PY

bash -n "$COMMON"

echo
echo "Corrected mode-resolution lines:"
grep -nF \
    'local mode="${GQ_MODE_OVERRIDE:-${mode_override:-$DEFAULT_MODE}}"' \
    "$COMMON"

echo
echo "Checking for remaining direct GQ_MODE_OVERRIDE assignments:"
remaining="$(
    grep -RInE \
        '^[[:space:]]*(export[[:space:]]+)?GQ_MODE_OVERRIDE=' \
        "$SUITE" \
        --include='*.sh' \
        --include='*.env' \
        --exclude='*.before_*' \
        2>/dev/null || true
)"

if [[ -n "$remaining" ]]; then
    printf '%s\n' "$remaining"
    echo
    echo "WARNING: review the assignments shown above."
else
    echo "None found."
fi

echo
echo "PASS: explicit GQ_MODE_OVERRIDE now has highest precedence."
echo
echo "Mode selection is now:"
echo "  1. command environment GQ_MODE_OVERRIDE"
echo "  2. test wrapper mode"
echo "  3. test DEFAULT_MODE"
echo
echo "No MsQuic rebuild is required."
