#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import py_compile
import sys
import tempfile

MARKER = "GREENQUIC-P5-ARCH-SINGLE-OWNER-VALIDATION-V1"
OLD = '    if multi==1 and len(lcores)<2: errors.append("multi-core mode requires at least two DPDK lcores")\n'
NEW = """    # GREENQUIC-P5-ARCH-SINGLE-OWNER-VALIDATION-V1
    # P5 architecture F/N deliberately keep the multicore-instrumented queue
    # path enabled with one DPDK owner. This is not a two-core scaling claim;
    # it is a single-consumer control with the same instrumentation contract.
    if multi==1 and len(lcores)<1:
        errors.append("multicore-instrumented mode requires at least one DPDK lcore")
    if multi==1 and len(lcores)==1:
        warnings.append(
            "P5 architecture single-owner multicore-instrumented control: "
            "one DPDK lcore; do not interpret this as multicore scaling"
        )
"""


def patch(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        py_compile.compile(str(path), doraise=True)
        print(f"P5 ARCH single-owner validator already present: {path}")
        return
    count = text.count(OLD)
    if count != 1:
        raise SystemExit(f"ERROR: single-owner validator anchor count={count}, expected 1")
    path.write_text(text.replace(OLD, NEW, 1), encoding="utf-8")
    py_compile.compile(str(path), doraise=True)
    print(f"P5 ARCH single-owner validator applied + py_compile PASS: {path}")


def self_test() -> None:
    sample = """def f(multi, lcores, errors, warnings):
    if multi==1 and len(lcores)<2: errors.append("multi-core mode requires at least two DPDK lcores")
"""
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "validator.py"
        path.write_text(sample, encoding="utf-8")
        patch(path)
        text = path.read_text(encoding="utf-8")
        assert text.count(MARKER) == 1
        ns: dict[str, object] = {}
        exec(compile(text, str(path), "exec"), ns)
        for lcores, expected_errors in [([19], 0), ([19, 20], 0), ([], 1)]:
            errors: list[str] = []
            warnings: list[str] = []
            ns["f"](1, lcores, errors, warnings)
            assert len(errors) == expected_errors
            if len(lcores) == 1:
                assert warnings
        patch(path)
        assert path.read_text(encoding="utf-8") == text
    print("P5 ARCH SINGLE-OWNER VALIDATOR SELF-TEST PASS")


if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
    self_test()
elif len(sys.argv) == 2:
    patch(Path(sys.argv[1]))
else:
    raise SystemExit(
        "usage: enable_p5_arch_single_owner_validation.py PATH_TO_VALIDATE_V22_CONFIG | --self-test"
    )
