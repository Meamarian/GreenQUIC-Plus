#!/usr/bin/env python3
from pathlib import Path
import py_compile
import subprocess
import sys
import tempfile

AFF_MARKER = "GREENQUIC-P5-ARCH-AFFINITIZE-RUNTIME-V1"
CPU_MARKER = "GREENQUIC-P5-ARCH-OFF-ALL-CPU-MAX-V1"


def replace_function_by_next(text: str, function: str, next_function: str, replacement: str) -> str:
    """Replace one top-level shell function without depending on its body text."""
    start_token = f"{function}() {{"
    next_token = f"{next_function}() {{"
    starts = []
    pos = 0
    while True:
        pos = text.find(start_token, pos)
        if pos < 0:
            break
        if pos == 0 or text[pos - 1] == "\n":
            starts.append(pos)
        pos += len(start_token)
    if len(starts) != 1:
        raise SystemExit(
            f"ERROR: expected one top-level {function} declaration, found {len(starts)}"
        )
    start = starts[0]

    next_start = text.find("\n" + next_token, start + len(start_token))
    if next_start < 0:
        raise SystemExit(
            f"ERROR: could not locate next top-level function {next_function} after {function}"
        )

    return text[:start] + replacement.rstrip("\n") + "\n" + text[next_start + 1 :]


def shell_syntax_check(path: Path) -> None:
    p = subprocess.run(
        ["bash", "-n", str(path)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if p.returncode != 0:
        detail = (p.stderr or p.stdout).strip()
        raise SystemExit(
            f"ERROR: patched runtime helper fails bash -n: {path}: {detail}"
        )


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
            raise SystemExit(
                f"ERROR: expected one dpdk.ini worker/map anchor, found {text.count(old)}"
            )
        text = text.replace(old, new, 1)

    if CPU_MARKER not in text:
        new_function = '''# GREENQUIC-P5-ARCH-OFF-ALL-CPU-MAX-V1
# Architecture tests compare DPDK and MsQuic worker counts. OFF must therefore
# fix BOTH configured DPDK lcores and configured QUIC worker CPUs at maximum
# frequency. Keep the helper result as one comma-separated CPU-list string;
# off_cpu_max_{start,emit_log} already call gq_expand_cpu_list on that string.
gq_dpdk_cpus_from_config() {
    local cfg="$1" dpdk quic cpus
    dpdk="$(sed -n 's/^[[:space:]]*GreenQuicDpdkLcores[[:space:]]*=[[:space:]]*//p' "$cfg" 2>/dev/null | tail -n 1 | tr -d '[:space:]')"
    quic="$(sed -n 's/^[[:space:]]*GreenQuicQuicWorkerCpus[[:space:]]*=[[:space:]]*//p' "$cfg" 2>/dev/null | tail -n 1 | tr -d '[:space:]')"
    [[ -n "$dpdk" ]] || return 1
    cpus="$dpdk"
    [[ -n "$quic" ]] && cpus="$cpus,$quic"
    printf '%s\\n' "$cpus"
}
'''
        text = replace_function_by_next(
            text,
            "gq_dpdk_cpus_from_config",
            "off_cpu_max_start",
            new_function,
        )

    path.write_text(text, encoding="utf-8")
    shell_syntax_check(path)
    print(f"P5 ARCH runtime patch applied + bash -n PASS: {path}")


def one_self_test_sample(helper_body: str) -> None:
    sample = f'''# prefix
GreenQuicQuicWorkerCpus=$cpus
GreenQuicPartitionDpdkMap=$pmap

gq_expand_cpu_list() {{ :; }}
{helper_body.rstrip()}

off_cpu_max_start() {{
    :
}}
# suffix
'''
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        p = root / "gq_common_p5.sh"
        cfg = root / "dpdk.ini"
        p.write_text(sample, encoding="utf-8")
        patch(p)
        out = p.read_text(encoding="utf-8")
        assert out.count(AFF_MARKER) == 1
        assert out.count(CPU_MARKER) == 1
        assert out.count("gq_dpdk_cpus_from_config() {") == 1
        assert "GreenQuicQuicAffinitize=${MSQUIC_QUIC_AFFINITIZE:-0}" in out
        assert 'GreenQuicQuicWorkerCpus' in out
        assert 'quic="$(sed -n' in out
        assert "printf '%s\\\\n' \"$cpus\"" in out
        assert "off_cpu_max_start() {" in out

        cfg.write_text(
            "GreenQuicDpdkLcores=19,20\nGreenQuicQuicWorkerCpus=21,22,23,24\n",
            encoding="utf-8",
        )
        cp = subprocess.run(
            [
                "bash",
                "-c",
                'cpus=""; pmap=""; source "$1"; gq_dpdk_cpus_from_config "$2"',
                "bash",
                str(p),
                str(cfg),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if cp.returncode != 0 or cp.stdout.strip() != "19,20,21,22,23,24":
            raise AssertionError(
                f"OFF CPU-list helper contract failed rc={cp.returncode} "
                f"stdout={cp.stdout!r} stderr={cp.stderr!r}"
            )

        patch(p)
        assert p.read_text(encoding="utf-8") == out


def self_test() -> None:
    one_self_test_sample('''gq_dpdk_cpus_from_config() {
    local cfg="$1" cpus
    cpus="$(sed -n 's/^[[:space:]]*GreenQuicDpdkLcores[[:space:]]*=[[:space:]]*//p' "$cfg" 2>/dev/null | tail -n 1 | tr -d '[:space:]')"
    [[ -n "$cpus" ]] || return 1
    printf '%s\\n' "$cpus"
}''')

    one_self_test_sample('''gq_dpdk_cpus_from_config() {
    # harmless formatting/body drift must not break architecture preflight
    local cfg="$1"
    local cpus=""
    cpus=$(awk -F= '/GreenQuicDpdkLcores/{print $2}' "$cfg" | tail -1)
    test -n "$cpus" || return 1
    printf "%s\\n" "$cpus"
}''')

    verifier = Path(__file__).with_name("verify_p5_arch_effective_config.py")
    if not verifier.is_file():
        raise SystemExit(
            f"ERROR: architecture effective-config verifier missing: {verifier}"
        )
    py_compile.compile(str(verifier), doraise=True)
    print(
        "P5 ARCH runtime patch SELF-TEST PASS; structural helper replacement, "
        "CSV CPU-list contract, bash syntax validation, and effective-config verifier compile"
    )


if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
    self_test()
elif len(sys.argv) == 2:
    patch(Path(sys.argv[1]))
else:
    raise SystemExit(
        "usage: enable_p5_arch_runtime_config.py PATH_TO_GQ_COMMON_P5_SH | --self-test"
    )
