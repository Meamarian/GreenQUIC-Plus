#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
source "$ROOT/suite.env"
python3 "$ROOT/common/bin/verify_v22_install.py"   --msquic "$MSQUIC_DIR" --dpdk "$DPDK_DIR"   --server-bin "$GQ_INTEROP_SERVER_BIN" --client-bin "$GQ_INTEROP_CLIENT_BIN"   --json-out "$ROOT/v22_install_$(hostname -s).json"
"$ROOT/test_cases/pretests/check_v22_setup.sh"
