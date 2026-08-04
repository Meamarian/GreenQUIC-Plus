\
#!/usr/bin/env python3
"""Verify that a suite run targets the exact V22 private split-Linux-DPDK build."""
from __future__ import annotations
import argparse, json, os, re, subprocess
from pathlib import Path

EXPECTED_VERSION = "22-private-split-linux-dpdk"
EXPECTED_DPDK = "21.11.9"
RUNTIME_MARKERS = (
    "GreenQuicQuicWorkerCpus",
    "GreenQuicQuicProfile",
    "GreenQuicEnableMultiCore",
    "GreenQuicPartitionDpdkMap",
    "GREENQUIC_POWER_CONFIG",
    "GreenQuicRxBurstRiseAlphaPermille",
    "GreenQuicTxRingRiseAlphaPermille",
    "GreenQuicIdleMode",
    "GreenQuicIdleWatchdogUs",
    "epoll_work_wait",
)

def fail(errors: list[str], msg: str) -> None:
    errors.append(msg)

def read_version_from_pc(dpdk: Path) -> str:
    pcs = sorted(dpdk.rglob("libdpdk.pc"), key=lambda p: ("pkgconfig" not in str(p.parent), len(str(p))))
    for pc in pcs:
        try:
            for line in pc.read_text(encoding="utf-8", errors="replace").splitlines():
                if line.startswith("Version:"):
                    return line.split(":", 1)[1].strip()
        except OSError:
            pass
    return ""

def binary_markers(path: Path) -> list[str]:
    if not path.is_file():
        return list(RUNTIME_MARKERS)
    data = path.read_bytes()
    return [m for m in RUNTIME_MARKERS if m.encode() not in data]

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--msquic", type=Path, required=True)
    ap.add_argument("--dpdk", type=Path, required=True)
    ap.add_argument("--server-bin", type=Path, required=True)
    ap.add_argument("--client-bin", type=Path, required=True)
    ap.add_argument("--json-out", type=Path)
    args = ap.parse_args()
    msquic = args.msquic.resolve(); dpdk = args.dpdk.resolve()
    errors: list[str] = []; warnings: list[str] = []

    manifest = msquic / "greenquic_patch_manifest.txt"
    if not manifest.is_file():
        fail(errors, f"missing V22 manifest: {manifest}")
    else:
        text = manifest.read_text(encoding="utf-8", errors="replace")
        if f"GreenQUIC autopatcher version={EXPECTED_VERSION}" not in text:
            fail(errors, f"manifest is not V22 ({EXPECTED_VERSION}): {manifest}")
        if "backend=split-linux-dpdk" not in text:
            fail(errors, "manifest does not identify split-linux-dpdk as the active backend")
        if "enable_multi_core=1" not in text:
            fail(errors, "V22 was not built with --enable-multi-core")

    active = msquic / "src/platform/datapath_raw_dpdk_linux.c"
    if not active.is_file():
        fail(errors, f"missing active backend: {active}")
    else:
        source = active.read_text(encoding="utf-8", errors="replace")
        if "GREENQUIC-V22-SPLIT-LINUX-DPDK-PORT" not in source:
            fail(errors, "active split backend lacks the V22 port marker")
        macro = source.find("ALLOW_EXPERIMENTAL_API")
        first_include = source.find("#include")
        if macro < 0:
            fail(errors, "active backend lacks ALLOW_EXPERIMENTAL_API")
        elif first_include >= 0 and macro > first_include:
            fail(errors, "ALLOW_EXPERIMENTAL_API appears after a header include")

    cmake = msquic / "src/platform/CMakeLists.txt"
    if not cmake.is_file():
        fail(errors, f"missing platform CMakeLists: {cmake}")
    else:
        ctext = cmake.read_text(encoding="utf-8", errors="replace")
        if "datapath_raw_dpdk_linux.c" not in ctext:
            fail(errors, "CMake does not compile datapath_raw_dpdk_linux.c")
        if re.search(r"\bdatapath_raw_dpdk\.c\b", ctext):
            fail(errors, "CMake still compiles the incompatible legacy datapath_raw_dpdk.c")
        if "greenquic_plus.c" not in ctext:
            fail(errors, "CMake does not compile greenquic_plus.c")

    active_object = msquic / "build-greenquic/src/platform/CMakeFiles/msquic_platform.dir/datapath_raw_dpdk_linux.c.o"
    if not active_object.is_file():
        fail(errors, f"active split-backend object is missing: {active_object}")

    for label, binary in (("server", args.server_bin), ("client", args.client_bin)):
        if not binary.is_file() or not os.access(binary, os.X_OK):
            fail(errors, f"{label} binary missing or not executable: {binary}")
            continue
        missing = binary_markers(binary)
        if missing:
            fail(errors, f"{label} binary lacks V22 runtime markers: {', '.join(missing)}")

    version = read_version_from_pc(dpdk)
    if not version:
        fail(errors, f"could not read libdpdk.pc below {dpdk}")
    elif version != EXPECTED_DPDK:
        fail(errors, f"DPDK version is {version}; expected {EXPECTED_DPDK}")

    report = {
        "msquic": str(msquic), "dpdk": str(dpdk),
        "expected_v22": EXPECTED_VERSION, "dpdk_version": version,
        "server_binary": str(args.server_bin), "client_binary": str(args.client_bin),
        "errors": errors, "warnings": warnings,
    }
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    for w in warnings: print("WARNING:", w)
    for e in errors: print("ERROR:", e)
    if errors: return 2
    print(f"V22 installation valid: GreenQUIC {EXPECTED_VERSION}, split Linux backend, DPDK {version}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
