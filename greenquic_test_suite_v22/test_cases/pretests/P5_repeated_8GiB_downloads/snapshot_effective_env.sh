#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
source "$HERE/../../../common/bin/gq_common.sh"
load_test "$HERE"

python3 - "$HERE/config.env" "$HERE/../../../suite.env" <<'PY'
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

names: set[str] = set()
for raw_path in sys.argv[1:]:
    path = Path(raw_path).resolve()
    if not path.is_file():
        continue
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)=", line)
        if match:
            names.add(match.group(1))

prefixes = (
    "GQ_", "GREENQUIC_", "P5_", "ENABLE_", "RX_", "TX_",
    "PRESSURE_", "FREQ_", "ACK_", "CWND_", "RECOVERY_",
    "BLOCKED_", "SLEEP_", "WORK_WAIT_", "IDLE_", "CSTATE_",
    "DOWNLOADS_", "GAP_", "SERVER_", "CLIENT_", "CASE_",
)

for key in os.environ:
    if key.startswith(prefixes):
        names.add(key)

for key in sorted(names):
    if key in os.environ:
        print(f"{key}={os.environ[key]}")
PY
