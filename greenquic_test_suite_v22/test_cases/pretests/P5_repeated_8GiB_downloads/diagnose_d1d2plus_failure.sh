#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="${1:?usage: diagnose_d1d2plus_failure.sh MATRIX_DIR}"
echo "=== D1/D2+ FAILURE DIAGNOSTICS: $ROOT ===" >&2
if [[ ! -d "$ROOT" ]]; then
  echo "diagnostic: matrix directory does not exist" >&2
  exit 0
fi
mapfile -t logs < <(find "$ROOT" -maxdepth 2 -type f \( -name 'server_*.log' -o -name 'client_*.log' -o -name '*timestamped.log' \) -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -12 | cut -d' ' -f2-)
for f in "${logs[@]}"; do
  echo >&2
  echo "--- tail: $f ---" >&2
  tail -160 "$f" >&2 || true
done

echo >&2
echo "--- high-signal errors under matrix ---" >&2
grep -RniE 'ERROR:|FATAL|Segmentation|segfault|Aborted|assert|no GreenQUIC counter|COUNTERS|P5-SNAPSHOT|EAL:|Traceback' "$ROOT" 2>/dev/null | tail -240 >&2 || true
exit 0
