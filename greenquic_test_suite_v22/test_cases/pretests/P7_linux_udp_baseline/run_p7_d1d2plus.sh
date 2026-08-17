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
for f in "$BASE" "$REPORTER" "$SUMMARY"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: missing P7 helper: $f" >&2
    ls -l "$HERE" >&2 || true
    exit 2
  fi
done
python3 -m py_compile \
  "$HERE/build_p7_d1_d2plus_report_v3.py" \
  "$HERE/build_p7_d1_d2plus_report_v4.py" \
  "$HERE/p7_frequency_sampler.py" \
  "$REPORTER" \
  "$SUMMARY"

# The base P7 wrapper historically checks BASE and REPORTER with -x even though
# both are invoked through bash/python3. Some bundle/worktree paths may not
# preserve those mode bits. Make them executable only for this invocation and
# restore the original modes on exit.
base_was_executable=0
reporter_was_executable=0
[[ -x "$BASE" ]] && base_was_executable=1
[[ -x "$REPORTER" ]] && reporter_was_executable=1
[[ "$base_was_executable" == 1 ]] || chmod u+x "$BASE"
[[ "$reporter_was_executable" == 1 ]] || chmod u+x "$REPORTER"
restore_helper_modes() {
  [[ "$base_was_executable" == 1 ]] || chmod u-x "$BASE" 2>/dev/null || true
  [[ "$reporter_was_executable" == 1 ]] || chmod u-x "$REPORTER" 2>/dev/null || true
}
trap restore_helper_modes EXIT INT TERM

bash "$BASE" "$@"
restore_helper_modes
trap - EXIT INT TERM
python3 "$HERE/build_p7_d1_d2plus_report_v4.py" --input "$OUT"
echo "D1_D2PLUS_REPORT=$OUT/the_sheet_rules_all/d1_d2plus"
echo "D1_D2PLUS_ALIGNMENT=$OUT/the_sheet_rules_all/d1_d2plus/alignment_quality.json"
