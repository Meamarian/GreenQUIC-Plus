#!/usr/bin/env python3
from __future__ import annotations
import argparse
import os
import shlex
from pathlib import Path


def executables(root: Path, name: str):
    if not root.exists():
        return []
    found = []
    for p in root.rglob(name):
        try:
            if p.is_file() and os.access(p, os.X_OK):
                found.append(p.resolve())
        except OSError:
            pass
    def score(p: Path):
        s = str(p)
        return (
            0 if "/artifacts/bin/linux/" in s else 1,
            0 if "Release" in s or "release" in s else 1,
            0 if "/build/" in s else 1,
            len(s),
            s,
        )
    return sorted(set(found), key=score)


def lib_dirs(root: Path):
    if not root.exists():
        return []
    names = ("libmsquic.so", "libdpdk.so", "librte_eal.so", "librte_net_mlx5.so", "libssl.so", "libcrypto.so")
    dirs = set()
    for name in names:
        for p in root.rglob(name + "*"):
            if p.is_file() or p.is_symlink():
                dirs.add(p.parent.resolve())
    return sorted(dirs)


def pkg_dirs(root: Path):
    if not root.exists():
        return []
    return sorted({p.parent.resolve() for p in root.rglob("libdpdk.pc")})


def driver_dir(root: Path):
    if not root.exists():
        return None
    candidates = []
    for pattern in ("librte_net_mlx5.so*", "librte_net_*.so*"):
        for p in root.rglob(pattern):
            if p.is_file() or p.is_symlink():
                candidates.append(p.parent.resolve())
    if candidates:
        return sorted(set(candidates), key=lambda p: (0 if p.name == "drivers" else 1, len(str(p))))[0]
    for p in root.rglob("drivers"):
        if p.is_dir() and any(p.glob("*.so*")):
            return p.resolve()
    return None


def find_devbind(root: Path):
    if not root.exists():
        return None
    for name in ("dpdk-devbind.py", "dpdk-devbind"):
        matches = list(root.rglob(name))
        if matches:
            return matches[0].resolve()
    return None


def q(value):
    return shlex.quote(str(value) if value else "")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--msquic", required=True)
    ap.add_argument("--dpdk", required=True)
    ap.add_argument("--server-bin", default="")
    ap.add_argument("--client-bin", default="")
    ap.add_argument("--secnetperf-bin", default="")
    ap.add_argument("--inprocess-client-bin", default="")
    args = ap.parse_args()

    msquic = Path(args.msquic).expanduser().resolve()
    dpdk = Path(args.dpdk).expanduser().resolve()

    server = Path(args.server_bin).expanduser().resolve() if args.server_bin else None
    client = Path(args.client_bin).expanduser().resolve() if args.client_bin else None
    secnetperf = Path(args.secnetperf_bin).expanduser().resolve() if args.secnetperf_bin else None
    inprocess = Path(args.inprocess_client_bin).expanduser().resolve() if args.inprocess_client_bin else None

    if not server or not server.exists():
        choices = executables(msquic, "quicinteropserver")
        server = choices[0] if choices else None
    if not client or not client.exists():
        choices = executables(msquic, "quicinterop")
        client = choices[0] if choices else None
    if not secnetperf or not secnetperf.exists():
        choices = executables(msquic, "secnetperf")
        secnetperf = choices[0] if choices else None
    if not inprocess or not inprocess.exists():
        choices = executables(msquic, "greenquic_test_client")
        inprocess = choices[0] if choices else None

    libs = lib_dirs(msquic) + lib_dirs(dpdk)
    # Stable de-duplication.
    seen = set()
    libs = [p for p in libs if not (str(p) in seen or seen.add(str(p)))]
    pkgs = pkg_dirs(dpdk)
    driver = driver_dir(dpdk)
    devbind = find_devbind(dpdk)

    print(f"DETECTED_INTEROP_SERVER={q(server)}")
    print(f"DETECTED_INTEROP_CLIENT={q(client)}")
    print(f"DETECTED_SECNETPERF={q(secnetperf)}")
    print(f"DETECTED_INPROCESS_CLIENT={q(inprocess)}")
    print(f"DETECTED_LD_LIBRARY_PATH={q(':'.join(map(str, libs)))}")
    print(f"DETECTED_PKG_CONFIG_PATH={q(':'.join(map(str, pkgs)))}")
    print(f"DETECTED_DPDK_DRIVER_PATH={q(driver)}")
    print(f"DETECTED_DPDK_DEVBIND={q(devbind)}")


if __name__ == "__main__":
    main()
