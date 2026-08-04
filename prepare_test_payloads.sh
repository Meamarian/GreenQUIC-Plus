#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_DIR="$ROOT_DIR/greenquic_test_suite_v22/common/files/payloads"
PAYLOAD="$PAYLOAD_DIR/file_10G.bin"
EXPECTED_SIZE=10737418240

mkdir -p "$PAYLOAD_DIR"

if [ -e "$PAYLOAD" ]; then
    CURRENT_SIZE="$(stat -c '%s' "$PAYLOAD")"

    if [ "$CURRENT_SIZE" -eq "$EXPECTED_SIZE" ]; then
        echo "Payload already exists with the correct size:"
        ls -lh "$PAYLOAD"
        exit 0
    fi

    echo "ERROR: Existing payload has the wrong size: $CURRENT_SIZE bytes" >&2
    echo "Nothing was overwritten." >&2
    exit 1
fi

AVAILABLE="$(df --output=avail -B1 "$PAYLOAD_DIR" | tail -n 1 | tr -d ' ')"

if [ "$AVAILABLE" -lt "$EXPECTED_SIZE" ]; then
    echo "ERROR: At least 10 GiB of free space is required." >&2
    df -h "$PAYLOAD_DIR"
    exit 1
fi

if command -v fallocate >/dev/null 2>&1; then
    fallocate -l "$EXPECTED_SIZE" "$PAYLOAD"
else
    dd if=/dev/zero of="$PAYLOAD" bs=1M count=10240 status=progress
fi

ACTUAL_SIZE="$(stat -c '%s' "$PAYLOAD")"

if [ "$ACTUAL_SIZE" -ne "$EXPECTED_SIZE" ]; then
    echo "ERROR: Generated payload has the wrong size." >&2
    exit 1
fi

echo "Created payload:"
ls -lh "$PAYLOAD"
