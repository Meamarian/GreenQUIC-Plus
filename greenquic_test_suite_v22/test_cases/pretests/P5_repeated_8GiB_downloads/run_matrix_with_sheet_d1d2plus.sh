#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(cd -- "$HERE/../../../.." && pwd)"
MARK='GREENQUIC-P5-D1D2PLUS-SNAPSHOT-V2'
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
for b in "$ROOT/msquic/build-greenquic-p5/bin/Release/quicinterop" "$ROOT/msquic/build-greenquic-p5/bin/Release/quicinteropserver"; do
  grep -aFq -- "$MARK" "$b" || { echo "ERROR: local D1/D2+ V2 marker missing in $b" >&2; exit 3; }
done
ssh -o ConnectTimeout=15 root@"$CLIENT_HOST" "grep -aFq -- '$MARK' '$ROOT/msquic/build-greenquic-p5/bin/Release/quicinterop'" || { echo 'ERROR: client D1/D2+ V2 marker missing' >&2; exit 3; }
set +e
bash "$HERE/run_matrix_with_sheet.sh" "$@" --env GQ_P5_POSITION_SNAPSHOT=1
rc=$?
set -e
if [[ $rc -ne 0 ]]; then echo "ERROR: base P5 matrix failed rc=$rc; D1/D2+ report not generated" >&2; exit "$rc"; fi
python3 "$HERE/build_d1_d2plus_report_v2.py" --input "$OUT"
echo "D1_D2PLUS_REPORT=$OUT/the_sheet_rules_all/d1_d2plus"
