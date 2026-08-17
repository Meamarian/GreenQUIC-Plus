#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import sys

MARKER = "GREENQUIC-P5-ARCH-RUNTIME-OVERLAY-V4"

if len(sys.argv) != 2:
    raise SystemExit("usage: apply_p5_arch_runtime_overlay_v4.py PATH_TO_GQ_COMMON_P5")

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
if MARKER in text:
    print(f"{MARKER} already present: {path}")
    raise SystemExit(0)

anchor = "GreenQuicQuicWorkerCpus=$cpus\n"
if text.count(anchor) != 1:
    raise SystemExit(f"ERROR: expected exactly one worker-CPU config anchor, found {text.count(anchor)}")

replacement = (
    anchor
    + "# " + MARKER + ": make MsQuic AFFINITIZE explicit and testable.\n"
    + "GreenQuicQuicAffinitize=${MSQUIC_AFFINITIZE:-0}\n"
)
text = text.replace(anchor, replacement, 1)
path.write_text(text, encoding="utf-8")
print(f"P5 architecture runtime overlay applied: {path}")
