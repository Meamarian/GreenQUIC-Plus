#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
[[ "$(hostname -s)" == idex ]] || echo "WARNING: expected to prepare the server payload on idex; current host=$(hostname -s)" >&2
python3 "$HERE/../../common/bin/prepare_assets.py" --common "$HERE/../../common" --create-10g
ls -lh "$HERE/../../common/files/payloads/file_10G.bin" "$HERE/../../common/files/server_root/file_10G.bin"
