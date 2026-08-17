#!/usr/bin/env python3
from pathlib import Path
import py_compile
import sys, tempfile

AFF_MARKER = "GREENQUIC-P5-ARCH-AFFINITIZE-RUNTIME-V1"
CPU_MARKER = "GREENQUIC-P5-ARCH-OFF-ALL-CPU-MAX-V1"


def patch(path: Path) -> None:
    text = path.read_text(encoding="utf-8")

    if AFF_MARKER not in text:
        old = "GreenQuicQuicWorkerCpus=$cpus\nGreenQuicPartitionDpdkMap=$pmap\n"
        new = (
            "GreenQuicQuicWorkerCpus=$cpus\n"
            "# GREENQUIC-P5-ARCH-AFFINITIZE-RUNTIME-V1\n"
            "GreenQuicQuicAffinitize=${MSQUIC_QUIC_AFFINITIZE:-0}\n"
            "GreenQuicPartitionDpdkMap=$pmap\n"
        )
        if text.count(old) != 1:
            raise SystemExit(f"ERROR: expected one dpdk.ini worker/map anchor, found {text.count(old)}")
        text = text.replace(old, new, 1)

    if CPU_MARKER not in text:
        old = '''gq_dpdk_cpus_from_config() {
    local cfg="$1" cpus
    cpus="$(sed -n 's/^[[:space:]]*GreenQuicDpdkLcores[[:space:]]*=[[:space:]]*//p' "$cfg" 2>/dev/null | tail -n 1 | tr -d '[:space:]')"
    [[ -n "$cpus" ]] || return 1
    printf '%s\n' "$cpus"
}
'''
        new = '''# GREENQUIC-P5-ARCH-OFF-ALL-CPU-MAX-V1
# Architecture tests compare DPDK and MsQuic worker counts. OFF must therefore
# fix BOTH configured DPDK lcores and configured QUIC worker CPUs at maximum
# frequency. Return one CPU per line because off_cpu_max_{start,emit_log}
# consume this function with `while read`.
gq_dpdk_cpus_from_config() {
    local cfg="$1" dpdk quic cpus
    dpdk="$(sed -n 's/^[[:space:]]*GreenQuicDpdkLcores[[:space:]]*=[[:space:]]*//p' "$cfg" 2>/dev/null | tail -n 1 | tr -d '[:space:]')"
    quic="$(sed -n 's/^[[:space:]]*GreenQuicQuicWorkerCpus[[:space:]]*=[[:space:]]*//p' "$cfg" 2>/dev/null | tail -n 1 | tr -d '[:space:]')"
    [[ -n "$dpdk" ]] || return 1
    cpus="$dpdk"
    [[ -n "$quic" ]] && cpus="$cpus,$quic"
    gq_expand_cpu_list "$cpus"
}
'''
        if text.count(old) != 1:
            raise SystemExit(f"ERROR: expected one OFF CPU-list helper anchor, found {text.count(old)}")
        text = text.replace(old, new, 1)

    path.write_text(text, encoding="utf-8")
    print(f"P5 ARCH runtime patch applied: {path}")


def self_test() -> None:
    sample = '''prefix
GreenQuicQuicWorkerCpus=$cpus
GreenQuicPartitionDpdkMap=$pmap

gq_expand_cpu_list() { :; }
gq_dpdk_cpus_from_config() {
    local cfg="$1" cpus
    cpus="$(sed -n 's/^[[:space:]]*GreenQuicDpdkLcores[[:space:]]*=[[:space:]]*//p' "$cfg" 2>/dev/null | tail -n 1 | tr -d '[:space:]')"
    [[ -n "$cpus" ]] || return 1
    printf '%s\n' "$cpus"
}
suffix
'''
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "gq_common_p5.sh"
        p.write_text(sample, encoding="utf-8")
        patch(p)
        out = p.read_text(encoding="utf-8")
        assert out.count(AFF_MARKER) == 1
        assert out.count(CPU_MARKER) == 1
        assert "GreenQuicQuicAffinitize=${MSQUIC_QUIC_AFFINITIZE:-0}" in out
        assert 'GreenQuicQuicWorkerCpus' in out
        assert 'gq_expand_cpu_list "$cpus"' in out
        patch(p)
        assert p.read_text(encoding="utf-8") == out

    verifier = Path(__file__).with_name("verify_p5_arch_effective_config.py")
    if not verifier.is_file():
        raise SystemExit(f"ERROR: architecture effective-config verifier missing: {verifier}")
    py_compile.compile(str(verifier), doraise=True)
    print("P5 ARCH runtime patch SELF-TEST PASS; effective-config verifier compiles")


if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
    self_test()
elif len(sys.argv) == 2:
    patch(Path(sys.argv[1]))
else:
    raise SystemExit("usage: enable_p5_arch_runtime_config.py PATH_TO_GQ_COMMON_P5_SH | --self-test")
