#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(cd -- "$HERE/../../../.." && pwd)"
MARK='GREENQUIC-P5-D1D2PLUS-SNAPSHOT-V3'
OUT=''
CLIENT_HOST='tinyman'
args=("$@")
for ((i=0;i<${#args[@]};++i)); do
  case "${args[i]}" in
    --output-dir) OUT="${args[i+1]:-}"; ((i++)) ;;
    --client-host) CLIENT_HOST="${args[i+1]:-tinyman}"; ((i++)) ;;
  esac
done
[[ -n "$OUT" ]] || { echo 'ERROR: --output-dir is required for D1/D2+ reporting' >&2; exit 2; }
python3 -m py_compile \
  "$HERE/build_d1_d2plus_report_v3.py" \
  "$HERE/build_d1_d2plus_report_v4.py" \
  "$HERE/clock_sync.py" \
  "$HERE/rebuild_d1d2_power_timeseries.py" \
  "$HERE/audit_d1d2plus_clock_drift.py"
bash -n "$HERE/diagnose_d1d2plus_failure.sh"
for b in "$ROOT/msquic/build-greenquic-p5/bin/Release/quicinterop" "$ROOT/msquic/build-greenquic-p5/bin/Release/quicinteropserver"; do
  grep -aFq -- "$MARK" "$b" || { echo "ERROR: local snapshot marker missing in $b" >&2; exit 3; }
done
ssh -o ConnectTimeout=15 root@"$CLIENT_HOST" "grep -aFq -- '$MARK' '$ROOT/msquic/build-greenquic-p5/bin/Release/quicinterop'" || { echo 'ERROR: client snapshot marker missing' >&2; exit 3; }
export GQ_P5_CLOCK_DRIFT_AUDIT=1
set +e
bash "$HERE/run_matrix_with_sheet.sh" "$@" --env GQ_P5_POSITION_SNAPSHOT=1
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  echo "ERROR: base P5 matrix failed rc=$rc; D1/D2+ report not generated" >&2
  bash "$HERE/diagnose_d1d2plus_failure.sh" "$OUT" || true
  exit "$rc"
fi

report_rc=0
timeseries_rc=0
audit_rc=0
set +e
python3 "$HERE/build_d1_d2plus_report_v4.py" --input "$OUT"
report_rc=$?
python3 "$HERE/rebuild_d1d2_power_timeseries.py" --input "$OUT"
timeseries_rc=$?
if [[ -f "$OUT/the_sheet_rules_all/d1_d2plus/alignment_quality.json" ]]; then
  python3 "$HERE/audit_d1d2plus_clock_drift.py" --input "$OUT"
  audit_rc=$?
else
  audit_rc=4
fi
set -e

echo "D1_D2PLUS_REPORT=$OUT/the_sheet_rules_all/d1_d2plus"
echo "D1_D2PLUS_ALIGNMENT=$OUT/the_sheet_rules_all/d1_d2plus/alignment_quality.json"
if [[ $report_rc -ne 0 || $timeseries_rc -ne 0 || $audit_rc -ne 0 ]]; then
  echo "ERROR: D1/D2+ validation failed report_rc=$report_rc timeseries_rc=$timeseries_rc drift_audit_rc=$audit_rc" >&2
  exit 4
fi
