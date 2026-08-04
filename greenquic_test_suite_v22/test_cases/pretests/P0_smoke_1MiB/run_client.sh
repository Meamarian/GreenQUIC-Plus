#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
source "$HERE/config.env"
TARGET="$HERE/results/downloads/file_1M.bin"
# GREENQUIC-V22-DOWNLOAD-CLEANUP-HOTFIX
cleanup_download() { rm -f -- "$TARGET"; }
trap cleanup_download EXIT
rm -f -- "$TARGET"
GQ_CLEANUP_DOWNLOADED_FILES=0 "$HERE/../../../common/bin/run_role.sh" client "$HERE" off 0
[[ -f "$TARGET" ]] || { echo "ERROR: smoke download file was not created: $TARGET" >&2; exit 2; }
actual_size="$(stat -c %s "$TARGET")"
[[ "$actual_size" == "$PAYLOAD_BYTES" ]] || { echo "ERROR: expected $PAYLOAD_BYTES bytes, got $actual_size" >&2; exit 2; }
source_file="$HERE/../../../common/files/payloads/file_1M.bin"
expected_hash="$(sha256sum "$source_file" | awk '{print $1}')"
actual_hash="$(sha256sum "$TARGET" | awk '{print $1}')"
[[ "$actual_hash" == "$expected_hash" ]] || { echo "ERROR: SHA-256 mismatch" >&2; exit 2; }
printf '\nP0 PASS: client/server QUIC download works. size=%s sha256=%s\n' "$actual_size" "$actual_hash"

# GREENQUIC-V22-RUN-BUNDLE-V2
python3 "$HERE/../../../common/bin/bundle_run_results.py" \
    --test-dir "$HERE" --role client --mode "off"
