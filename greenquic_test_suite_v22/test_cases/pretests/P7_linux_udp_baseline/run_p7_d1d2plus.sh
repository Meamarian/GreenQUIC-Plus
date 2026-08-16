#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
BASE="$HERE/run_matrix_with_report.sh"
REPORTER="$HERE/build_p7_report.py"
SUMMARY="$HERE/p7_print_summary.py"
OUT=''; args=("$@")
for ((i=0;i<${#args[@]};++i)); do
  if [[ "${args[i]}" == --output-dir ]]; then OUT="${args[i+1]:-}"; ((i++)); fi
done
[[ -n "$OUT" ]] || { echo 'ERROR: --output-dir is required' >&2; exit 2; }
[[ -x "$BASE" && -f "$REPORTER" && -f "$SUMMARY" ]] || { echo 'ERROR: P7 runner/reporter/summary helper missing' >&2; exit 2; }
python3 -m py_compile "$HERE/build_p7_d1_d2plus_report_v3.py" "$HERE/p7_frequency_sampler.py" "$REPORTER" "$SUMMARY"

# run_matrix_with_report.sh historically checked the Python reporter with -x
# even though it executes it via `python3`. Keep this D1/D2+ wrapper compatible
# without permanently changing the checkout's file mode.
reporter_was_executable=0
[[ -x "$REPORTER" ]] && reporter_was_executable=1
if [[ "$reporter_was_executable" == 0 ]]; then
  chmod u+x "$REPORTER"
fi
restore_reporter_mode() {
  if [[ "$reporter_was_executable" == 0 ]]; then
    chmod u-x "$REPORTER" 2>/dev/null || true
  fi
}
trap restore_reporter_mode EXIT INT TERM

bash "$BASE" "$@"
restore_reporter_mode
trap - EXIT INT TERM
python3 "$HERE/build_p7_d1_d2plus_report_v3.py" --input "$OUT"
echo "D1_D2PLUS_REPORT=$OUT/the_sheet_rules_all/d1_d2plus"
echo "D1_D2PLUS_ALIGNMENT=$OUT/the_sheet_rules_all/d1_d2plus/alignment_quality.json"
