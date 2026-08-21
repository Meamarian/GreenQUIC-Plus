#!/usr/bin/env python3
"""Import the exact user-supplied paper chart/tuning ZIP contents.

This uses only the Python standard library. It validates every imported byte
against results_analysis/artifact_files.sha256.json before writing it.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import zipfile
from pathlib import Path, PurePosixPath

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
MANIFEST = HERE / "artifact_files.sha256.json"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def run(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, cwd=REPO, text=True, check=check, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def git_clean() -> bool:
    return run("git", "status", "--porcelain").stdout.strip() == ""


def check_repo_for_publish() -> None:
    branch = run("git", "branch", "--show-current").stdout.strip()
    if branch != "main":
        raise SystemExit(f"ERROR: --commit/--push requires branch main, found {branch!r}")
    origin = run("git", "remote", "get-url", "origin").stdout.strip()
    accepted = {
        "git@github.com:Meamarian/GreenQUIC-Plus.git",
        "https://github.com/Meamarian/GreenQUIC-Plus.git",
    }
    if origin not in accepted:
        raise SystemExit(f"ERROR: unexpected origin: {origin}")
    if not git_clean():
        raise SystemExit("ERROR: worktree is not clean. Commit/stash unrelated work first.")


def safe_member(name: str) -> PurePosixPath:
    p = PurePosixPath(name)
    if p.is_absolute() or ".." in p.parts:
        raise SystemExit(f"ERROR: unsafe ZIP member: {name}")
    return p


def read_sources(charts_zip: Path, tuning_zip: Path) -> tuple[dict[str, bytes], set[str]]:
    out: dict[str, bytes] = {}
    seen_members: set[str] = set()

    with zipfile.ZipFile(charts_zip) as z:
        for info in z.infolist():
            p = safe_member(info.filename)
            if info.is_dir():
                continue
            seen_members.add(info.filename)
            if p.name == ".DS_Store":
                continue
            if len(p.parts) < 2 or p.parts[0] != "Charts":
                raise SystemExit(f"ERROR: unexpected Charts ZIP member: {info.filename}")
            rel = PurePosixPath(*p.parts[1:])
            if rel == PurePosixPath("SOURCE_REFERENCE.txt"):
                dst = PurePosixPath("results_analysis/charts/SOURCE_REFERENCE.txt")
            elif rel == PurePosixPath("chart_v2.py"):
                dst = PurePosixPath("results_analysis/charts/chart_v2.py")
            elif rel.parts and rel.parts[0] == "svg":
                dst = PurePosixPath("results_analysis/charts") / rel
            else:
                raise SystemExit(f"ERROR: unexpected Charts ZIP payload: {info.filename}")
            out[dst.as_posix()] = z.read(info)

    with zipfile.ZipFile(tuning_zip) as z:
        for info in z.infolist():
            p = safe_member(info.filename)
            if info.is_dir():
                continue
            seen_members.add(info.filename)
            if len(p.parts) != 2 or p.parts[0] != "Tunning" or p.suffix.lower() != ".xlsx":
                raise SystemExit(f"ERROR: unexpected Tunning ZIP member: {info.filename}")
            dst = PurePosixPath("results_analysis/tuning") / p.name
            out[dst.as_posix()] = z.read(info)

    return out, seen_members


def main() -> int:
    ap = argparse.ArgumentParser(description="Import exact GreenQUIC+ paper chart/tuning ZIP contents")
    ap.add_argument("--charts-zip", required=True, type=Path, help="Path to Charts (2).zip")
    ap.add_argument("--tuning-zip", required=True, type=Path, help="Path to Tunning.zip")
    ap.add_argument("--overwrite", action="store_true", help="Replace a target file if its bytes differ")
    ap.add_argument("--commit", action="store_true", help="Create a Git commit containing only imported artifacts")
    ap.add_argument("--push", action="store_true", help="Push the import commit to origin/main (implies --commit)")
    args = ap.parse_args()

    if args.push:
        args.commit = True
    for p in (args.charts_zip, args.tuning_zip, MANIFEST):
        if not p.is_file():
            raise SystemExit(f"ERROR: missing file: {p}")
    if args.commit:
        check_repo_for_publish()

    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    expected = {item["path"]: item for item in manifest["files"]}
    payloads, _ = read_sources(args.charts_zip, args.tuning_zip)

    missing = sorted(set(expected) - set(payloads))
    extra = sorted(set(payloads) - set(expected))
    if missing or extra:
        if missing:
            print("ERROR: expected artifact(s) missing from ZIPs:", *missing, sep="\n  ", file=sys.stderr)
        if extra:
            print("ERROR: unexpected artifact(s) in ZIPs:", *extra, sep="\n  ", file=sys.stderr)
        return 2

    for rel, data in sorted(payloads.items()):
        meta = expected[rel]
        got = sha256(data)
        if len(data) != meta["size"] or got != meta["sha256"]:
            raise SystemExit(
                f"ERROR: source checksum mismatch for {rel}\n"
                f"  expected size={meta['size']} sha256={meta['sha256']}\n"
                f"  got      size={len(data)} sha256={got}"
            )

    changed: list[str] = []
    for rel, data in sorted(payloads.items()):
        dst = REPO / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        if dst.exists():
            current = dst.read_bytes()
            if current == data:
                print(f"OK unchanged  {rel}")
                continue
            if not args.overwrite:
                raise SystemExit(
                    f"ERROR: {rel} exists with different bytes. "
                    "Inspect it or rerun with --overwrite."
                )
        dst.write_bytes(data)
        changed.append(rel)
        print(f"IMPORTED      {rel}")

    # Re-verify the on-disk result byte-for-byte.
    for rel, meta in sorted(expected.items()):
        p = REPO / rel
        if not p.is_file():
            raise SystemExit(f"ERROR: imported target missing: {rel}")
        data = p.read_bytes()
        if len(data) != meta["size"] or sha256(data) != meta["sha256"]:
            raise SystemExit(f"ERROR: post-write verification failed: {rel}")

    print(f"\nARTIFACT IMPORT VERIFY: PASS ({len(expected)} files)")
    print("Ignored macOS metadata: Charts/svg/.DS_Store")

    if args.commit:
        if not changed:
            print("No artifact bytes changed; nothing to commit.")
        else:
            subprocess.run(["git", "add", "--", *changed], cwd=REPO, check=True)
            subprocess.run(
                ["git", "commit", "-m", "results: import supplied paper workbooks and SVG chart artifacts"],
                cwd=REPO,
                check=True,
            )
            print("Created artifact import commit.")
    if args.push:
        subprocess.run(["git", "push", "origin", "main"], cwd=REPO, check=True)
        print("Pushed artifact import commit to origin/main.")

    print("\nGit status for results_analysis:")
    subprocess.run(["git", "status", "--short", "--", "results_analysis"], cwd=REPO, check=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
