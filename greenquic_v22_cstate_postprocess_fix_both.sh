#!/usr/bin/env bash
set -euo pipefail

# GreenQUIC V22 C-state post-processing repair
#
# Apply this same script on idex and tinyman.
#
# It:
#   1. Repairs bundle_run_results.py from the newest valid backup if the
#      current file has a Python syntax/indentation error.
#   2. Adds a safe early guard to cstate_trace.py before matplotlib is imported.
#   3. Skips C-state plotting cleanly when ENABLE_CSTATE_RECORD=0 or when the
#      C-state CSV has no data.
#   4. Installs python3-matplotlib when it is missing, so enabled C-state runs
#      can produce SVG charts.
#   5. Validates both Python files and runs a disabled-mode smoke test.

SUITE="${GQ_SUITE_ROOT:-/root/mohsen/greenquic_test_suite_v22}"
BIN="$SUITE/common/bin"
BUNDLE="$BIN/bundle_run_results.py"
CSTATE="$BIN/cstate_trace.py"

[[ -f "$BUNDLE" ]] || {
    echo "ERROR: missing $BUNDLE" >&2
    exit 1
}

[[ -f "$CSTATE" ]] || {
    echo "ERROR: missing $CSTATE" >&2
    exit 1
}

STAMP="$(date +%Y%m%d_%H%M%S)"

echo "Suite: $SUITE"
echo

# ---------------------------------------------------------------------------
# 1. Ensure bundle_run_results.py is syntactically valid.
# ---------------------------------------------------------------------------

if ! python3 -m py_compile "$BUNDLE" >/dev/null 2>&1; then
    echo "Current bundle_run_results.py is invalid."
    echo "Searching for the newest valid backup..."

    restored=""

    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue

        if python3 -m py_compile "$candidate" >/dev/null 2>&1; then
            cp -a "$BUNDLE" "${BUNDLE}.broken_${STAMP}"
            cp -a "$candidate" "$BUNDLE"
            restored="$candidate"
            break
        fi
    done < <(
        find "$BIN" -maxdepth 1 -type f             -name 'bundle_run_results.py.before_*'             -printf '%T@ %p\n' 2>/dev/null |
        sort -nr |
        cut -d' ' -f2-
    )

    if [[ -z "$restored" ]]; then
        echo "ERROR: bundle_run_results.py is invalid and no valid backup was found." >&2
        exit 1
    fi

    echo "Restored bundle_run_results.py from:"
    echo "  $restored"
else
    echo "bundle_run_results.py is already syntactically valid."
fi

python3 -m py_compile "$BUNDLE"

# ---------------------------------------------------------------------------
# 2. Install one canonical guard before the first matplotlib import.
# ---------------------------------------------------------------------------

cp -a "$CSTATE" "${CSTATE}.before_cstate_guard_${STAMP}"

python3 - "$CSTATE" <<'PY'
from pathlib import Path
import py_compile
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

begin = "# GREENQUIC-V22-CSTATE-EARLY-GUARD-BEGIN"
end = "# GREENQUIC-V22-CSTATE-EARLY-GUARD-END"
old_marker = "# GREENQUIC-V22-CSTATE-EARLY-GUARD-V1"

# Remove a previous canonical guard, if present.
if begin in text:
    start = text.index(begin)
    finish_marker = text.find(end, start)

    if finish_marker < 0:
        raise SystemExit(
            "ERROR: found the C-state guard begin marker without its end marker"
        )

    finish = finish_marker + len(end)

    while finish < len(text) and text[finish] in "\r\n":
        finish += 1

    text = text[:start] + text[finish:]

# Remove the older one-marker guard inserted by a previous repair attempt.
if old_marker in text:
    start = text.index(old_marker)
    matplotlib_pos = text.find("import matplotlib", start)

    if matplotlib_pos < 0:
        raise SystemExit(
            "ERROR: found the old C-state guard marker but no matplotlib import"
        )

    text = text[:start] + text[matplotlib_pos:]

matplotlib_pos = text.find("import matplotlib")

if matplotlib_pos < 0:
    raise SystemExit(
        "ERROR: cstate_trace.py does not contain an 'import matplotlib' line"
    )

guard = r'''# GREENQUIC-V22-CSTATE-EARLY-GUARD-BEGIN
# This block intentionally uses only Python's standard library because it must
# execute before importing matplotlib.
import os as _gq_os
import sys as _gq_sys


def _gq_cstate_arg_value(_option):
    try:
        _index = _gq_sys.argv.index(_option)
    except ValueError:
        return None

    _value_index = _index + 1

    if _value_index >= len(_gq_sys.argv):
        return None

    return _gq_sys.argv[_value_index]


_gq_cstate_enabled = (
    _gq_os.environ.get("ENABLE_CSTATE_RECORD", "0")
    .strip()
    .lower()
    in ("1", "true", "yes", "on")
)

_gq_cstate_csv = _gq_cstate_arg_value("--csv")
_gq_cstate_has_samples = False

if _gq_cstate_csv and _gq_os.path.isfile(_gq_cstate_csv):
    try:
        with open(
            _gq_cstate_csv,
            "r",
            encoding="utf-8",
            errors="replace",
        ) as _gq_cstate_file:
            _gq_cstate_header = next(_gq_cstate_file, None)
            _gq_cstate_first_sample = next(_gq_cstate_file, None)

        _gq_cstate_has_samples = (
            _gq_cstate_header is not None
            and _gq_cstate_first_sample is not None
        )
    except OSError as _gq_cstate_error:
        print(
            "[GreenQUIC-Test:WARN] Cannot read the C-state CSV: "
            f"{_gq_cstate_error}"
        )

if not _gq_cstate_enabled:
    print(
        "[GreenQUIC-Test] Skipping C-state plots: "
        "ENABLE_CSTATE_RECORD is disabled."
    )
    raise SystemExit(0)

if not _gq_cstate_has_samples:
    print(
        "[GreenQUIC-Test] Skipping C-state plots: "
        "no C-state samples were recorded."
    )
    raise SystemExit(0)

# GREENQUIC-V22-CSTATE-EARLY-GUARD-END

'''

patched = text[:matplotlib_pos] + guard + text[matplotlib_pos:]

temporary = path.with_name(path.name + ".gq_tmp")
temporary.write_text(patched, encoding="utf-8")

try:
    py_compile.compile(str(temporary), doraise=True)
except Exception:
    temporary.unlink(missing_ok=True)
    raise

temporary.replace(path)

print(f"Patched: {path}")
PY

python3 -m py_compile "$CSTATE"

# ---------------------------------------------------------------------------
# 3. Install matplotlib for runs where C-state recording is enabled.
# ---------------------------------------------------------------------------

if python3 - <<'PY' >/dev/null 2>&1
import matplotlib
PY
then
    echo "python3-matplotlib is already available."
else
    echo "python3-matplotlib is missing."

    if command -v apt-get >/dev/null 2>&1; then
        echo "Installing python3-matplotlib..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y python3-matplotlib
    else
        echo "ERROR: apt-get is unavailable; install matplotlib for Python 3 manually." >&2
        exit 1
    fi
fi

python3 - <<'PY'
import matplotlib
print("matplotlib version:", matplotlib.__version__)
PY

# ---------------------------------------------------------------------------
# 4. Disabled-mode smoke test.
# ---------------------------------------------------------------------------

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

set +e
SMOKE_OUTPUT="$(
    ENABLE_CSTATE_RECORD=0     python3 "$CSTATE"         --csv "$TMP_DIR/nonexistent.csv"         --summary "$TMP_DIR/cstate.json"         --timeline-svg "$TMP_DIR/cstate_timeseries.svg"         --histogram-svg "$TMP_DIR/cstate_histogram.svg"         --role test 2>&1
)"
SMOKE_RC=$?
set -e

printf '%s\n' "$SMOKE_OUTPUT"

if [[ "$SMOKE_RC" -ne 0 ]]; then
    echo "ERROR: disabled-mode C-state smoke test failed with exit code $SMOKE_RC." >&2
    exit 1
fi

if ! grep -q 'Skipping C-state plots' <<<"$SMOKE_OUTPUT"; then
    echo "ERROR: disabled-mode smoke test did not report that plotting was skipped." >&2
    exit 1
fi

python3 -m py_compile "$BUNDLE" "$CSTATE"

echo
echo "PASS: GreenQUIC C-state post-processing is repaired."
echo
echo "Behavior:"
echo "  ENABLE_CSTATE_RECORD=0"
echo "      C-state plotting is skipped with exit code 0."
echo
echo "  ENABLE_CSTATE_RECORD=1 with no recorded samples"
echo "      C-state plotting is skipped with exit code 0."
echo
echo "  ENABLE_CSTATE_RECORD=1 with recorded samples"
echo "      C-state SVG time series and histogram are generated."
echo
echo "Apply this same script on both idex and tinyman."
