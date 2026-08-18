#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import tempfile

MARKER = "GREENQUIC-P5-CLAIM-ACTIVE-RECORDER-GATE-V1"
ANCHOR = """    fi
    export GQ_ENABLE_ACPI_POWER_TRACE GQ_ENABLE_MSR_TRACE
    export ENABLE_CSTATE_RECORD GQ_ENABLE_FREQ_TRACE GQ_POST_TRANSFER_WAIT_S
}
"""
REPLACEMENT = """    fi

    # GREENQUIC-P5-CLAIM-ACTIVE-RECORDER-GATE-V1
    # Test-only causal control. ENABLE_RECORD remains 1 so the controller,
    # boundary RAPL snapshots, result bundling and transport flow are identical.
    # Only asynchronous/high-frequency recorder processes are disabled.
    if [[ "${GQ_CLAIM_DISABLE_ACTIVE_RECORDERS:-0}" == 1 ]]; then
        GQ_ENABLE_ACPI_POWER_TRACE=0
        GQ_ENABLE_MSR_TRACE=0
        ENABLE_CSTATE_RECORD=0
        GQ_ENABLE_FREQ_TRACE=0
    fi
    export GQ_ENABLE_ACPI_POWER_TRACE GQ_ENABLE_MSR_TRACE
    export ENABLE_CSTATE_RECORD GQ_ENABLE_FREQ_TRACE GQ_POST_TRANSFER_WAIT_S
}
"""


def patch(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        subprocess.run(["bash", "-n", str(path)], check=True)
        print(f"P5 CLAIM recorder gate already present + bash -n PASS: {path}")
        return
    count = text.count(ANCHOR)
    if count != 1:
        raise SystemExit(f"ERROR: recorder-gate anchor count={count}, expected 1")
    text = text.replace(ANCHOR, REPLACEMENT, 1)
    path.write_text(text, encoding="utf-8")
    subprocess.run(["bash", "-n", str(path)], check=True)
    print(f"P5 CLAIM recorder gate applied + bash -n PASS: {path}")


def self_test() -> None:
    sample = """#!/usr/bin/env bash
gq_apply_recording_mode() {
    if true; then
        GQ_ENABLE_ACPI_POWER_TRACE=1
        GQ_ENABLE_MSR_TRACE=1
        ENABLE_CSTATE_RECORD=1
        GQ_ENABLE_FREQ_TRACE=1
    else
        GQ_ENABLE_ACPI_POWER_TRACE=0
        GQ_ENABLE_MSR_TRACE=0
        ENABLE_CSTATE_RECORD=0
        GQ_ENABLE_FREQ_TRACE=0
        GQ_POST_TRANSFER_WAIT_S=0
    fi
    export GQ_ENABLE_ACPI_POWER_TRACE GQ_ENABLE_MSR_TRACE
    export ENABLE_CSTATE_RECORD GQ_ENABLE_FREQ_TRACE GQ_POST_TRANSFER_WAIT_S
}
"""
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "gq_common_p5.sh"
        path.write_text(sample, encoding="utf-8")
        patch(path)
        once = path.read_text(encoding="utf-8")
        assert once.count(MARKER) == 1
        assert "GQ_CLAIM_DISABLE_ACTIVE_RECORDERS" in once
        # The gate may mention ENABLE_RECORD in comments, but it must never
        # assign/export it or branch on it.
        code = "\n".join(
            line.split("#", 1)[0] for line in REPLACEMENT.splitlines()
        )
        assert "ENABLE_RECORD=" not in code
        assert "export ENABLE_RECORD" not in code
        assert "${ENABLE_RECORD" not in code
        patch(path)
        assert path.read_text(encoding="utf-8") == once
    print("P5 CLAIM ACTIVE RECORDER GATE SELF-TEST PASS")


if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
    self_test()
elif len(sys.argv) == 2:
    patch(Path(sys.argv[1]))
else:
    raise SystemExit(
        "usage: enable_p5_claim_recording_gate.py PATH_TO_GQ_COMMON_P5_SH | --self-test"
    )
