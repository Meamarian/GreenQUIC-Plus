#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path
import subprocess
import tempfile

MARKER = "P5-SINGLE-MODE-CONTROLLER-V1"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"ERROR: {label}: expected exactly one anchor, found {count}")
    return text.replace(old, new, 1)


def patch_core(text: str, mode: str) -> str:
    if mode not in {"off", "basic", "plus"}:
        raise SystemExit(f"ERROR: invalid mode {mode!r}")
    if MARKER in text:
        raise SystemExit("ERROR: core already contains single-mode marker")

    text = replace_once(
        text,
        'modes = ("off", "basic", "plus")',
        f'modes = ("{mode}",)',
        "mode tuple",
    )
    text = replace_once(
        text,
        '    if len(order) != 3 or set(order) != set(modes):\n'
        '        raise SystemExit("ERROR: fixed --mode-order must contain off,basic,plus exactly once")',
        '    if len(order) != 1 or order != modes:\n'
        f'        raise SystemExit("ERROR: P5 single-mode controller requires --mode-order {mode}")',
        "fixed mode validation",
    )
    text = replace_once(
        text,
        'TOTAL_TESTS=$((RUNS * 3))',
        'TOTAL_TESTS=$RUNS',
        "total tests",
    )
    text = replace_once(
        text,
        'position=$position/3 mode=$mode',
        'position=$position/1 mode=$mode',
        "schedule position display",
    )
    text = replace_once(
        text,
        'POSITION $position/3 | MODE=$mode',
        'POSITION $position/1 | MODE=$mode',
        "run position display",
    )
    text = replace_once(
        text,
        'python3 "$HERE/aggregate_p5_matrix.py" --input "$OUTPUT_DIR" --runs "$RUNS"\n'
        'python3 "$HERE/p5_finalize_matrix.py" --matrix "$OUTPUT_DIR"',
        f'echo "[{MARKER}] single-mode raw bundles complete; skipping three-mode aggregate/finalizer"',
        "three-mode finalizer",
    )
    text = text.replace("#!/usr/bin/env bash\n", f"#!/usr/bin/env bash\n# {MARKER} mode={mode}\n", 1)
    return text


def patch_public(text: str, core_basename: str) -> str:
    text = replace_once(
        text,
        'CORE="$HERE/run_matrix_from_idex_core.sh"',
        f'CORE="$HERE/{core_basename}"',
        "public CORE pointer",
    )
    return text


def write_outputs(core: Path, public: Path, mode: str, out_core: Path, out_public: Path) -> None:
    c = patch_core(core.read_text(encoding="utf-8"), mode)
    p = patch_public(public.read_text(encoding="utf-8"), out_core.name)
    out_core.write_text(c, encoding="utf-8")
    out_public.write_text(p, encoding="utf-8")
    out_core.chmod(0o700)
    out_public.chmod(0o700)
    subprocess.run(["bash", "-n", str(out_core)], check=True)
    subprocess.run(["bash", "-n", str(out_public)], check=True)


def self_test() -> None:
    core = '''#!/usr/bin/env bash
python3 - <<'PY'
modes = ("off", "basic", "plus")
if strategy == "balanced":
    pass
else:
    order = tuple(item.strip() for item in strategy.split(",") if item.strip())
    if len(order) != 3 or set(order) != set(modes):
        raise SystemExit("ERROR: fixed --mode-order must contain off,basic,plus exactly once")
PY
TOTAL_TESTS=$((RUNS * 3))
echo "position=$position/3 mode=$mode"
echo "POSITION $position/3 | MODE=$mode"
python3 "$HERE/aggregate_p5_matrix.py" --input "$OUTPUT_DIR" --runs "$RUNS"
python3 "$HERE/p5_finalize_matrix.py" --matrix "$OUTPUT_DIR"
'''
    public = '''#!/usr/bin/env bash
HERE=x
CORE="$HERE/run_matrix_from_idex_core.sh"
bash "$CORE" "$@"
'''
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        cp, pp = root / "core.sh", root / "public.sh"
        oc, op = root / ".single_core.sh", root / ".single_public.sh"
        cp.write_text(core, encoding="utf-8")
        pp.write_text(public, encoding="utf-8")
        write_outputs(cp, pp, "off", oc, op)
        out = oc.read_text(encoding="utf-8")
        assert 'modes = ("off",)' in out
        assert "TOTAL_TESTS=$RUNS" in out
        assert "position=$position/1" in out
        assert MARKER in out
        assert f'CORE="$HERE/{oc.name}"' in op.read_text(encoding="utf-8")
    print("P5 SINGLE-MODE CONTROLLER SELF-TEST PASS")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--core", type=Path)
    ap.add_argument("--public", type=Path)
    ap.add_argument("--mode", choices=("off", "basic", "plus"))
    ap.add_argument("--out-core", type=Path)
    ap.add_argument("--out-public", type=Path)
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        self_test(); return 0
    for name in ("core", "public", "mode", "out_core", "out_public"):
        if getattr(args, name) is None:
            ap.error(f"--{name.replace('_','-')} is required")
    write_outputs(args.core, args.public, args.mode, args.out_core, args.out_public)
    print(f"P5 SINGLE-MODE CONTROLLER PASS mode={args.mode} core={args.out_core} public={args.out_public}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
