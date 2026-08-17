#!/usr/bin/env python3
from pathlib import Path
import sys, tempfile

MARKER = "GREENQUIC-P5-ARCH-AFFINITIZE-RUNTIME-V1"

def patch(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        print(f"{MARKER} already present: {path}")
        return
    old = "GreenQuicQuicWorkerCpus=$cpus\nGreenQuicPartitionDpdkMap=$pmap\n"
    new = (
        "GreenQuicQuicWorkerCpus=$cpus\n"
        "# GREENQUIC-P5-ARCH-AFFINITIZE-RUNTIME-V1\n"
        "GreenQuicQuicAffinitize=${MSQUIC_QUIC_AFFINITIZE:-0}\n"
        "GreenQuicPartitionDpdkMap=$pmap\n"
    )
    if text.count(old) != 1:
        raise SystemExit(f"ERROR: expected one dpdk.ini worker/map anchor, found {text.count(old)}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"{MARKER} applied: {path}")

def self_test() -> None:
    sample = "prefix\nGreenQuicQuicWorkerCpus=$cpus\nGreenQuicPartitionDpdkMap=$pmap\nsuffix\n"
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "gq_common_p5.sh"
        p.write_text(sample, encoding="utf-8")
        patch(p)
        out = p.read_text(encoding="utf-8")
        assert out.count(MARKER) == 1
        assert "GreenQuicQuicAffinitize=${MSQUIC_QUIC_AFFINITIZE:-0}" in out
        patch(p)
        assert p.read_text(encoding="utf-8") == out
    print("P5 ARCH runtime-affinitize patch SELF-TEST PASS")

if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
    self_test()
elif len(sys.argv) == 2:
    patch(Path(sys.argv[1]))
else:
    raise SystemExit("usage: enable_p5_arch_runtime_config.py PATH_TO_GQ_COMMON_P5_SH | --self-test")
