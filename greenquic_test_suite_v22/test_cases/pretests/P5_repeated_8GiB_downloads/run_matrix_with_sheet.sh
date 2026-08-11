#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
BASE_RUNNER="$HERE/run_matrix_from_idex.sh"
REPORTER="$HERE/build_sheet_rules_all.py"

usage() {
    cat <<'EOF'
Usage:
  bash ./run_matrix_with_sheet.sh [--chart-style new|old|both] [normal matrix options]

Aliases:
  --chart_style new|old|both

Behavior:
  old   current/legacy P4/P5 tables + charts only
  new   run the existing matrix unchanged, then keep its tables but remove its
        legacy charts directory and generate the finalized the_sheet_rules_all/
        workbook + 62-chart report
  both  keep legacy output and also generate the_sheet_rules_all/ report

Default: both
EOF
}

CHART_STYLE="both"
ARGS=()
OUTPUT_DIR=""
while (($#)); do
    case "$1" in
        --chart-style|--chart_style)
            CHART_STYLE="${2:?missing value for $1}"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="${2:?missing value for --output-dir}"
            ARGS+=("$1" "$2")
            shift 2
            ;;
        -h|--help)
            usage
            echo
            "$BASE_RUNNER" --help || true
            exit 0
            ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
case "$CHART_STYLE" in new|old|both) ;; *) echo "ERROR: --chart-style must be new, old, or both" >&2; exit 2;; esac

[[ -x "$BASE_RUNNER" ]] || { echo "ERROR: missing executable $BASE_RUNNER" >&2; exit 2; }
if [[ "$CHART_STYLE" != "old" ]]; then
    [[ -f "$REPORTER" ]] || { echo "ERROR: missing $REPORTER" >&2; exit 2; }
    python3 -c 'import matplotlib, numpy' >/dev/null 2>&1 || {
        echo "ERROR: new report requires Python matplotlib and numpy" >&2
        exit 2
    }
fi

# Force a known matrix path so post-processing never guesses which run was made.
if [[ -z "$OUTPUT_DIR" ]]; then
    case "$HERE" in
        *P4_repeated_8GiB_downloads*) prefix="p4" ;;
        *P5_repeated_8GiB_downloads*) prefix="p5" ;;
        *) prefix="matrix" ;;
    esac
    OUTPUT_DIR="$HERE/matrix_results/${prefix}_$(date +%Y%m%d_%H%M%S)"
    ARGS+=("--output-dir" "$OUTPUT_DIR")
fi

"$BASE_RUNNER" "${ARGS[@]}"

if [[ "$CHART_STYLE" == "old" ]]; then
    echo "[sheet-rules] chart-style=old: legacy output kept; new report skipped"
    exit 0
fi

[[ -d "$OUTPUT_DIR" ]] || { echo "ERROR: matrix output directory not found after run: $OUTPUT_DIR" >&2; exit 1; }

if [[ "$CHART_STYLE" == "new" ]]; then
    # Preserve legacy numeric tables; only legacy chart images are suppressed.
    rm -rf -- "$OUTPUT_DIR/tables/charts"
fi

python3 "$REPORTER" \
    --input "$OUTPUT_DIR" \
    --output "$OUTPUT_DIR/the_sheet_rules_all" \
    --expected-charts 62

echo "[sheet-rules] chart-style=$CHART_STYLE"
echo "[sheet-rules] report: $OUTPUT_DIR/the_sheet_rules_all"
