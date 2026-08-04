#!/usr/bin/env python3
from __future__ import annotations
import argparse
import os
import shutil
import subprocess
from pathlib import Path

PAYLOADS = {
    "file_8G.bin": 8 * 1024**3,
    "file_10G.bin": 10 * 1024**3,
    "chunk_1M.bin": 1 * 1024**2,
    "chunk_64M.bin": 64 * 1024**2,
    "file_4K.bin": 4 * 1024,
    "file_64K.bin": 64 * 1024,
    "file_1M.bin": 1 * 1024**2,
}


def sparse(path: Path, size: int):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as f:
        f.truncate(size)


def materialize_zero(path: Path, size: int):
    path.parent.mkdir(parents=True, exist_ok=True)
    block = b"\0" * (1024 * 1024)
    remaining = size
    with path.open("wb") as f:
        while remaining:
            part = block if remaining >= len(block) else block[:remaining]
            f.write(part)
            remaining -= len(part)


def force_symlink(target: str | Path, link: Path):
    link.parent.mkdir(parents=True, exist_ok=True)
    if link.is_symlink() or link.exists():
        link.unlink()
    link.symlink_to(target)


def certs(common: Path):
    cert_dir = common / "certs"
    cert_dir.mkdir(parents=True, exist_ok=True)
    cert = cert_dir / "server.crt"
    key = cert_dir / "server.key"
    if cert.exists() and key.exists():
        return
    openssl = shutil.which("openssl")
    if not openssl:
        print("WARNING: openssl not found; certificate was not generated.")
        return
    cmd = [
        openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes",
        "-keyout", str(key), "-out", str(cert), "-days", "3650",
        "-subj", "/CN=localhost",
    ]
    try:
        subprocess.run(cmd + ["-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    key.chmod(0o600)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--common", required=True)
    ap.add_argument("--materialize", action="store_true", help="Write real zero-filled files instead of sparse files.")
    ap.add_argument("--create-8g", action="store_true", help="Create the 8 GiB source payload now.")
    ap.add_argument("--create-10g", action="store_true", help="Create the 10 GiB source payload now.")
    args = ap.parse_args()

    common = Path(args.common).resolve()
    payload_dir = common / "files" / "payloads"
    server_root = common / "files" / "server_root"
    downloads = common / "downloads"
    payload_dir.mkdir(parents=True, exist_ok=True)
    server_root.mkdir(parents=True, exist_ok=True)
    downloads.mkdir(parents=True, exist_ok=True)

    large_payloads = {
        "file_8G.bin": args.create_8g,
        "file_10G.bin": args.create_10g,
    }

    for name, size in PAYLOADS.items():
        if name in large_payloads and not large_payloads[name]:
            continue
        path = payload_dir / name
        if not path.exists() or path.stat().st_size != size:
            print(f"Creating {'materialized' if args.materialize else 'sparse'} payload {path} ({size} bytes)")
            (materialize_zero if args.materialize else sparse)(path, size)

    links = {
        server_root / "file_8G.bin": Path("../payloads/file_8G.bin"),
        server_root / "file_10G.bin": Path("../payloads/file_10G.bin"),
        server_root / "small" / "file_4K.bin": Path("../../payloads/file_4K.bin"),
        server_root / "small" / "file_64K.bin": Path("../../payloads/file_64K.bin"),
        server_root / "small" / "file_1M.bin": Path("../../payloads/file_1M.bin"),
    }
    for link, target in links.items():
        if target.name in large_payloads and not large_payloads[target.name]:
            continue
        force_symlink(target, link)

    for i in range(1, 65):
        force_symlink(Path("../../payloads/chunk_1M.bin"), server_root / "chunks" / f"chunk_{i:03d}.bin")

    # The interop client opens <download-dir>/<basename> with fopen("wb").
    # Symlinks to /dev/null avoid storing duplicate 10 GB/chunk downloads.
    sink_names = ["file_8G.bin", "file_10G.bin", "file_4K.bin", "file_64K.bin", "file_1M.bin"]
    sink_names.extend(f"chunk_{i:03d}.bin" for i in range(1, 65))
    if os.name == "posix" and Path("/dev/null").exists():
        for name in sink_names:
            force_symlink(Path("/dev/null"), downloads / name)
    else:
        print("WARNING: /dev/null is unavailable. Client downloads will consume disk space.")

    manifest = common / "files" / "MANIFEST.txt"
    manifest.write_text("\n".join(f"{name}\t{size}" for name, size in PAYLOADS.items()) + "\n", encoding="utf-8")
    certs(common)
    print("Common assets prepared.")


if __name__ == "__main__":
    main()
