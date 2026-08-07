#!/usr/bin/env bash
set -euo pipefail

SUITE="${GQ_SUITE_ROOT:-/root/mohsen/greenquic_test_suite_v22}"
GQ_COMMON="$SUITE/common/bin/gq_common.sh"
STAMP="$(date +%Y%m%d_%H%M%S)"
MARKER="GREENQUIC-V22-CSTATE-READER-AFFINITY-V1"

[[ -f "$GQ_COMMON" ]] || { echo "ERROR: missing $GQ_COMMON" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required" >&2; exit 1; }
command -v taskset >/dev/null 2>&1 || { echo "ERROR: taskset (util-linux) is required" >&2; exit 1; }

if grep -Fq "$MARKER" "$GQ_COMMON"; then
    echo "PASS: C-state reader affinity fix is already installed."
    exit 0
fi

cp -a "$GQ_COMMON" "$GQ_COMMON.before_cstate_reader_affinity_$STAMP"

python3 - "$GQ_COMMON" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
marker = "GREENQUIC-V22-CSTATE-READER-AFFINITY-V1"

# Add the new suite-wide setting.
default_anchor = ': "${GQ_CSTATE_CPUS:=}"\n'
if ': "${GQ_CSTATE_READER_CPU:=' not in text:
    if default_anchor not in text:
        raise SystemExit("ERROR: GQ_CSTATE_CPUS default anchor not found")
    text = text.replace(
        default_anchor,
        default_anchor + ': "${GQ_CSTATE_READER_CPU:=auto}"\n',
        1,
    )

old_export = 'export ENABLE_CSTATE_RECORD GQ_REQUIRE_CSTATE_RECORD GQ_CSTATE_CPUS\n'
new_export = 'export ENABLE_CSTATE_RECORD GQ_REQUIRE_CSTATE_RECORD GQ_CSTATE_CPUS GQ_CSTATE_READER_CPU\n'
if new_export not in text:
    if old_export not in text:
        raise SystemExit("ERROR: C-state export anchor not found")
    text = text.replace(old_export, new_export, 1)

cpu_anchor = '    [[ -n "$cpus" ]] || cpus="19"\n'
selection = r'''    [[ -n "$cpus" ]] || cpus="19"

    # GREENQUIC-V22-CSTATE-READER-AFFINITY-V1
    # GQ_CSTATE_CPUS identifies the CPUs being measured.  The trace reader
    # must run on a different physical core, otherwise its own wakeups can
    # generate cpu_idle events on the measured CPU and create a feedback loop.
    local reader_request="${GQ_CSTATE_READER_CPU:-auto}"
    local reader_cpu
    if ! reader_cpu="$(python3 - "$TEST_DIR/runtime/$role/dpdk.ini" "$cpus" "$reader_request" <<'PYCPU'
import pathlib
import sys

cfg_path = pathlib.Path(sys.argv[1])
trace_text = sys.argv[2]
request = sys.argv[3].strip().lower()


def parse_cpu_list(value):
    result = set()
    for token in value.replace(" ", "").split(","):
        if not token:
            continue
        if "-" in token:
            start_text, end_text = token.split("-", 1)
            start, end = int(start_text), int(end_text)
            if end < start:
                raise ValueError(f"invalid CPU range: {token}")
            result.update(range(start, end + 1))
        else:
            result.add(int(token))
    return result


try:
    online = parse_cpu_list(
        pathlib.Path("/sys/devices/system/cpu/online").read_text().strip()
    )
    traced = parse_cpu_list(trace_text)
except Exception as exc:
    print(f"cannot parse CPU list: {exc}", file=sys.stderr)
    raise SystemExit(2)

used = set(traced)
if cfg_path.is_file():
    for raw in cfg_path.read_text(errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith(("#", ";")) or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key.strip() in {"GreenQuicDpdkLcores", "GreenQuicQuicWorkerCpus"}:
            try:
                used.update(parse_cpu_list(value.strip()))
            except Exception as exc:
                print(f"cannot parse {key.strip()}: {exc}", file=sys.stderr)
                raise SystemExit(2)

# Exclude SMT siblings of every DPDK and QUIC CPU as well.
for cpu in list(used):
    sibling_path = pathlib.Path(
        f"/sys/devices/system/cpu/cpu{cpu}/topology/thread_siblings_list"
    )
    try:
        used.update(parse_cpu_list(sibling_path.read_text().strip()))
    except FileNotFoundError:
        pass
    except Exception as exc:
        print(f"cannot parse siblings for CPU {cpu}: {exc}", file=sys.stderr)
        raise SystemExit(2)

if request == "auto":
    candidates = sorted(online - used)
    if not candidates:
        print("no housekeeping CPU remains outside DPDK/QUIC CPUs and their SMT siblings", file=sys.stderr)
        raise SystemExit(3)
    chosen = candidates[0]
else:
    try:
        chosen = int(request)
    except ValueError:
        print(f"GQ_CSTATE_READER_CPU must be 'auto' or an integer, got {request!r}", file=sys.stderr)
        raise SystemExit(4)
    if chosen not in online:
        print(f"requested reader CPU {chosen} is not online", file=sys.stderr)
        raise SystemExit(5)
    if chosen in used:
        print(
            f"requested reader CPU {chosen} conflicts with a DPDK/QUIC CPU "
            "or one of their SMT siblings",
            file=sys.stderr,
        )
        raise SystemExit(6)

print(chosen)
PYCPU
)"; then
        die "Unable to choose a safe CPU for the C-state trace reader. Set GQ_CSTATE_READER_CPU to a housekeeping CPU."
    fi
'''
if marker not in text:
    if cpu_anchor not in text:
        raise SystemExit("ERROR: C-state CPU-selection anchor not found")
    text = text.replace(cpu_anchor, selection, 1)

old_launch = '''    "$helper" --cpus "$cpus" --output "${output_prefix}.csv" --summary "${output_prefix}.json" \\
        >"${output_prefix}_sampler.log" 2>&1 &
'''
new_launch = '''    taskset -c "$reader_cpu" \\
        "$helper" --cpus "$cpus" --output "${output_prefix}.csv" --summary "${output_prefix}.json" \\
        >"${output_prefix}_sampler.log" 2>&1 &
'''
if new_launch not in text:
    if old_launch not in text:
        raise SystemExit("ERROR: C-state helper launch anchor not found")
    text = text.replace(old_launch, new_launch, 1)

old_log = '    log "Started ${role} Linux cpu_idle trace pid=$GQ_CSTATE_TRACE_PID CPUs=$cpus clock=mono_raw"\n'
new_log = '    log "Started ${role} Linux cpu_idle trace pid=$GQ_CSTATE_TRACE_PID traced_cpus=$cpus reader_cpu=$reader_cpu clock=mono_raw"\n'
if new_log not in text:
    if old_log not in text:
        raise SystemExit("ERROR: C-state startup log anchor not found")
    text = text.replace(old_log, new_log, 1)

path.write_text(text, encoding="utf-8")
PY

bash -n "$GQ_COMMON"

echo "PASS: C-state reader affinity fix installed."
echo "Backup: $GQ_COMMON.before_cstate_reader_affinity_$STAMP"
echo
echo "Defaults:"
echo "  GQ_CSTATE_CPUS=<DPDK CPUs being measured>"
echo "  GQ_CSTATE_READER_CPU=auto"
echo
echo "The auto selector excludes DPDK CPUs, QUIC worker CPUs, and their SMT siblings."
echo "No MsQuic rebuild is required."
