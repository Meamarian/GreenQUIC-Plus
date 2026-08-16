#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
OUT=''; args=("$@")
for ((i=0;i<${#args[@]};++i)); do
  if [[ "${args[i]}" == --output-dir ]]; then OUT="${args[i+1]:-}"; ((i++)); fi
done
[[ -n "$OUT" ]] || { echo 'ERROR: --output-dir is required' >&2; exit 2; }
python3 -m py_compile "$HERE/build_p7_d1_d2plus_report_v3.py" "$HERE/p7_frequency_sampler.py"
bash "$HERE/run_matrix_with_report.sh" "$@"
python3 "$HERE/build_p7_d1_d2plus_report_v3.py" --input "$OUT"
echo "D1_D2PLUS_REPORT=$OUT/the_sheet_rules_all/d1_d2plus"
echo "D1_D2PLUS_ALIGNMENT=$OUT/the_sheet_rules_all/d1_d2plus/alignment_quality.json"
