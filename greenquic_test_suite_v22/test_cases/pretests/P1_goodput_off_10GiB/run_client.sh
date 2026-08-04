#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
source "$HERE/config.env"
"$HERE/../../../common/bin/run_role.sh" client "$HERE" "off" 0
# GREENQUIC-V22-DOWNLOAD-CLEANUP-HOTFIX
manifest="$(find "$HERE/results" -maxdepth 1 -type f -name 'client_download_manifest_off_*.json' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)"
[[ -n "$manifest" && -f "$manifest" ]] || { echo 'ERROR: latest client download manifest not found' >&2; exit 2; }
actual_bytes="$(python3 - "$manifest" <<'PY_BYTES'
import json, sys
row = json.load(open(sys.argv[1], encoding='utf-8'))
print(int(row.get('total_bytes', 0)))
PY_BYTES
)"
[[ "$actual_bytes" -gt 0 ]] || { echo "ERROR: no downloaded payload bytes were recorded in $manifest" >&2; exit 2; }
[[ "$actual_bytes" == "$PAYLOAD_BYTES" ]] || { echo "ERROR: expected $PAYLOAD_BYTES downloaded bytes, got $actual_bytes" >&2; exit 2; }
energy="$(find "$HERE/results" -maxdepth 1 -type f -name 'client_energy_off_*.json' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)"
[[ -n "$energy" && -f "$energy" ]] || { echo 'ERROR: latest client energy/timing JSON not found' >&2; exit 2; }
stamp="$(date +%Y%m%d_%H%M%S)"
python3 "$HERE/../../../common/bin/report_goodput.py" \
  --energy "$energy" --bytes "$actual_bytes" --mode "off" --test-id "$TEST_ID" \
  --out "$HERE/results/goodput_off_${stamp}.json"

# GREENQUIC-V22-RUN-BUNDLE-V2
python3 "$HERE/../../../common/bin/bundle_run_results.py" \
    --test-dir "$HERE" --role client --mode "off"
