#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import tempfile

GATE_MARKER = "GREENQUIC-P5-CLAIM-ACTIVE-RECORDER-GATE-V1"
AFFINITY_MARKER = "GREENQUIC-P5-CLAIM-RECORDER-AFFINITY-V1"

GATE_ANCHOR = """    fi
    export GQ_ENABLE_ACPI_POWER_TRACE GQ_ENABLE_MSR_TRACE
    export ENABLE_CSTATE_RECORD GQ_ENABLE_FREQ_TRACE GQ_POST_TRANSFER_WAIT_S
}
"""
GATE_REPLACEMENT = """    fi

    # GREENQUIC-P5-CLAIM-ACTIVE-RECORDER-GATE-V1
    # Test-only causal control. ENABLE_RECORD remains 1 so the controller,
    # boundary RAPL snapshots, result bundling and transport flow are identical.
    # Only asynchronous/high-frequency recorder processes are disabled.
    if [[ "${GQ_CLAIM_DISABLE_ACTIVE_RECORDERS:-0}" == 1 ]]; then
        GQ_ENABLE_ACPI_POWER_TRACE=0
        GQ_ENABLE_MSR_TRACE=0
        ENABLE_CSTATE_RECORD=0
        GQ_ENABLE_FREQ_TRACE=0
    fi
    export GQ_ENABLE_ACPI_POWER_TRACE GQ_ENABLE_MSR_TRACE
    export ENABLE_CSTATE_RECORD GQ_ENABLE_FREQ_TRACE GQ_POST_TRANSFER_WAIT_S
}
"""

AFFINITY_HELPER_ANCHOR = """# GREENQUIC-V22-GOODPUT-ACPI-TRACE-HOTFIX
power_trace_start() {
"""
AFFINITY_HELPERS = r'''# GREENQUIC-P5-CLAIM-RECORDER-AFFINITY-V1
# Keep high-rate observer processes off the DPDK and QUIC execution CPUs.
# Auto mode also excludes SMT siblings of those protected CPUs.
gq_claim_recorder_cpu() {
    local role="$1"
    local cfg="$TEST_DIR/runtime/$role/dpdk.ini"
    local request="${GQ_CLAIM_RECORDER_CPU:-auto}"
    python3 - "$cfg" "$request" <<'PYCPU'
from pathlib import Path
import sys

cfg = Path(sys.argv[1])
request = sys.argv[2].strip().lower()


def parse_cpu_list(value: str) -> set[int]:
    out: set[int] = set()
    for token in value.replace(" ", "").split(","):
        if not token:
            continue
        if "-" in token:
            first, last = token.split("-", 1)
            a, b = int(first), int(last)
            if b < a:
                raise ValueError(f"invalid CPU range: {token}")
            out.update(range(a, b + 1))
        else:
            out.add(int(token))
    return out


try:
    online = parse_cpu_list(Path("/sys/devices/system/cpu/online").read_text().strip())
except Exception as exc:
    print(f"cannot read online CPUs: {exc}", file=sys.stderr)
    raise SystemExit(2)

if not cfg.is_file():
    print(f"runtime config missing: {cfg}", file=sys.stderr)
    raise SystemExit(3)

used: set[int] = set()
try:
    for raw in cfg.read_text(errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith(("#", ";")) or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key.strip() in {"GreenQuicDpdkLcores", "GreenQuicQuicWorkerCpus"}:
            used.update(parse_cpu_list(value.strip()))
except Exception as exc:
    print(f"cannot parse protected CPUs from {cfg}: {exc}", file=sys.stderr)
    raise SystemExit(4)

for cpu in list(used):
    siblings = Path(f"/sys/devices/system/cpu/cpu{cpu}/topology/thread_siblings_list")
    try:
        used.update(parse_cpu_list(siblings.read_text().strip()))
    except FileNotFoundError:
        pass
    except Exception as exc:
        print(f"cannot parse SMT siblings for CPU {cpu}: {exc}", file=sys.stderr)
        raise SystemExit(5)

if request == "auto":
    candidates = sorted(online - used)
    if not candidates:
        print("no housekeeping CPU remains outside DPDK/QUIC CPUs and SMT siblings", file=sys.stderr)
        raise SystemExit(6)
    chosen = candidates[0]
else:
    try:
        chosen = int(request)
    except ValueError:
        print(f"GQ_CLAIM_RECORDER_CPU must be 'auto' or an integer, got {request!r}", file=sys.stderr)
        raise SystemExit(7)
    if chosen not in online:
        print(f"requested recorder CPU {chosen} is not online", file=sys.stderr)
        raise SystemExit(8)
    if chosen in used:
        print(f"requested recorder CPU {chosen} conflicts with DPDK/QUIC CPUs or SMT siblings", file=sys.stderr)
        raise SystemExit(9)

print(chosen)
PYCPU
}

gq_claim_record_affinity() {
    local pid="$1" cpu="$2" output="$3" kind="$4"
    {
        printf 'kind=%s\n' "$kind"
        printf 'pid=%s\n' "$pid"
        printf 'selected_cpu=%s\n' "$cpu"
        awk '/^Cpus_allowed_list:/ {print "cpus_allowed_list=" $2}' "/proc/$pid/status" 2>/dev/null || true
        taskset -pc "$pid" 2>&1 || true
    } > "$output"
}

# GREENQUIC-V22-GOODPUT-ACPI-TRACE-HOTFIX
power_trace_start() {
'''

POWER_OLD = r'''    local occurrence="${GQ_POWER_SENSOR_OCCURRENCE:-last}"
    python3 "$GQ_COMMON_DIR/bin/power_trace.py" record \
        --role "$role" --label "$label" --prefix "$prefix" \
        --interval-ms "$interval" --sensor-match "$match" --sensor-occurrence "$occurrence" \
        >"${prefix}_sampler.log" 2>&1 &
    GQ_POWER_TRACE_PID=$!
'''
POWER_NEW = r'''    local occurrence="${GQ_POWER_SENSOR_OCCURRENCE:-last}"
    local recorder_cpu
    recorder_cpu="$(gq_claim_recorder_cpu "$role")" || die "Unable to choose a safe recorder CPU for $role power trace. Set GQ_CLAIM_RECORDER_CPU to a housekeeping CPU."
    taskset -c "$recorder_cpu" python3 "$GQ_COMMON_DIR/bin/power_trace.py" record \
        --role "$role" --label "$label" --prefix "$prefix" \
        --interval-ms "$interval" --sensor-match "$match" --sensor-occurrence "$occurrence" \
        >"${prefix}_sampler.log" 2>&1 &
    GQ_POWER_TRACE_PID=$!
'''

POWER_LOG_OLD = r'''    log "Started ${role} whole-system power1 trace pid=$GQ_POWER_TRACE_PID interval=${interval}ms prefix=$prefix"
'''
POWER_LOG_NEW = r'''    gq_claim_record_affinity "$GQ_POWER_TRACE_PID" "$recorder_cpu" "${prefix}_affinity.txt" power1
    log "Started ${role} whole-system power1 trace pid=$GQ_POWER_TRACE_PID interval=${interval}ms recorder_cpu=$recorder_cpu prefix=$prefix"
'''

FREQ_OLD = r'''    local interval="${GQ_FREQ_SAMPLE_INTERVAL_MS:-10}"
    python3 "$GQ_COMMON_DIR/bin/frequency_sampler.py"         --config "$config" --output "$output" --interval-ms "$interval"         >"${output%.jsonl}_sampler.log" 2>&1 &
    GQ_FREQ_TRACE_PID=$!
'''
FREQ_NEW = r'''    local interval="${GQ_FREQ_SAMPLE_INTERVAL_MS:-10}"
    local recorder_cpu
    recorder_cpu="$(gq_claim_recorder_cpu "$role")" || die "Unable to choose a safe recorder CPU for $role frequency trace. Set GQ_CLAIM_RECORDER_CPU to a housekeeping CPU."
    taskset -c "$recorder_cpu" python3 "$GQ_COMMON_DIR/bin/frequency_sampler.py"         --config "$config" --output "$output" --interval-ms "$interval"         >"${output%.jsonl}_sampler.log" 2>&1 &
    GQ_FREQ_TRACE_PID=$!
'''

FREQ_LOG_OLD = r'''    log "Started $role CPU-frequency trace pid=$GQ_FREQ_TRACE_PID interval=${interval}ms"
'''
FREQ_LOG_NEW = r'''    gq_claim_record_affinity "$GQ_FREQ_TRACE_PID" "$recorder_cpu" "${output%.jsonl}_affinity.txt" frequency
    log "Started $role CPU-frequency trace pid=$GQ_FREQ_TRACE_PID interval=${interval}ms recorder_cpu=$recorder_cpu"
'''

MSR_OLD = r'''    "$sampler" \
        --output "$output_csv" \
        --interval-ms "$interval_ms" \
        --smooth-samples "$smooth_samples" \
        >"$sampler_log" 2>&1 &
    GQ_MSR_TRACE_PID=$!
'''
MSR_NEW = r'''    local recorder_cpu
    recorder_cpu="$(gq_claim_recorder_cpu "$role")" || die "Unable to choose a safe recorder CPU for $role RAPL/MSR trace. Set GQ_CLAIM_RECORDER_CPU to a housekeeping CPU."
    taskset -c "$recorder_cpu" "$sampler" \
        --output "$output_csv" \
        --interval-ms "$interval_ms" \
        --smooth-samples "$smooth_samples" \
        >"$sampler_log" 2>&1 &
    GQ_MSR_TRACE_PID=$!
'''

MSR_LOG_OLD = r'''    log "Started ${role} C RAPL powercap trace pid=$GQ_MSR_TRACE_PID interval=${interval_ms}ms smoothing=${smooth_samples}"
'''
MSR_LOG_NEW = r'''    gq_claim_record_affinity "$GQ_MSR_TRACE_PID" "$recorder_cpu" "${output_csv%.csv}_affinity.txt" rapl_msr
    log "Started ${role} C RAPL powercap trace pid=$GQ_MSR_TRACE_PID interval=${interval_ms}ms smoothing=${smooth_samples} recorder_cpu=$recorder_cpu"
'''


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"ERROR: {label} anchor count={count}, expected 1")
    return text.replace(old, new, 1)


def patch(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    changed = False

    if GATE_MARKER not in text:
        text = replace_once(text, GATE_ANCHOR, GATE_REPLACEMENT, "recorder gate")
        changed = True

    if AFFINITY_MARKER not in text:
        text = replace_once(text, AFFINITY_HELPER_ANCHOR, AFFINITY_HELPERS, "affinity helper")
        text = replace_once(text, POWER_OLD, POWER_NEW, "power trace launch")
        text = replace_once(text, POWER_LOG_OLD, POWER_LOG_NEW, "power trace evidence")
        text = replace_once(text, FREQ_OLD, FREQ_NEW, "frequency trace launch")
        text = replace_once(text, FREQ_LOG_OLD, FREQ_LOG_NEW, "frequency trace evidence")
        text = replace_once(text, MSR_OLD, MSR_NEW, "RAPL/MSR trace launch")
        text = replace_once(text, MSR_LOG_OLD, MSR_LOG_NEW, "RAPL/MSR trace evidence")
        changed = True

    if changed:
        path.write_text(text, encoding="utf-8")

    subprocess.run(["bash", "-n", str(path)], check=True)
    state = "applied" if changed else "already present"
    print(f"P5 CLAIM recorder gate + affinity {state} + bash -n PASS: {path}")


def self_test() -> None:
    sample = r'''#!/usr/bin/env bash
set -euo pipefail
die(){ exit 1; }
gq_apply_recording_mode() {
    if true; then
        GQ_ENABLE_ACPI_POWER_TRACE=1
        GQ_ENABLE_MSR_TRACE=1
        ENABLE_CSTATE_RECORD=1
        GQ_ENABLE_FREQ_TRACE=1
    else
        GQ_ENABLE_ACPI_POWER_TRACE=0
        GQ_ENABLE_MSR_TRACE=0
        ENABLE_CSTATE_RECORD=0
        GQ_ENABLE_FREQ_TRACE=0
        GQ_POST_TRANSFER_WAIT_S=0
    fi
    export GQ_ENABLE_ACPI_POWER_TRACE GQ_ENABLE_MSR_TRACE
    export ENABLE_CSTATE_RECORD GQ_ENABLE_FREQ_TRACE GQ_POST_TRANSFER_WAIT_S
}
# GREENQUIC-V22-GOODPUT-ACPI-TRACE-HOTFIX
power_trace_start() {
    local role="$1" prefix="$2" label="$3"
    local interval="${GQ_POWER_SAMPLE_INTERVAL_MS:-1000}"
    local match="${GQ_POWER_SENSOR_MATCH:-power1}"
    local occurrence="${GQ_POWER_SENSOR_OCCURRENCE:-last}"
    python3 "$GQ_COMMON_DIR/bin/power_trace.py" record \
        --role "$role" --label "$label" --prefix "$prefix" \
        --interval-ms "$interval" --sensor-match "$match" --sensor-occurrence "$occurrence" \
        >"${prefix}_sampler.log" 2>&1 &
    GQ_POWER_TRACE_PID=$!
    log "Started ${role} whole-system power1 trace pid=$GQ_POWER_TRACE_PID interval=${interval}ms prefix=$prefix"
}
frequency_trace_start() {
    local role="$1" config="$2" output="$3"
    local interval="${GQ_FREQ_SAMPLE_INTERVAL_MS:-10}"
    python3 "$GQ_COMMON_DIR/bin/frequency_sampler.py"         --config "$config" --output "$output" --interval-ms "$interval"         >"${output%.jsonl}_sampler.log" 2>&1 &
    GQ_FREQ_TRACE_PID=$!
    log "Started $role CPU-frequency trace pid=$GQ_FREQ_TRACE_PID interval=${interval}ms"
}
msr_trace_start() {
    local role="$1" output_csv="$2"
    local sampler="$GQ_COMMON_DIR/bin/gq_rapl_msr_sampler"
    local interval_ms="${GQ_MSR_SAMPLE_INTERVAL_MS:-6}"
    local smooth_samples="${GQ_MSR_SMOOTH_SAMPLES:-3}"
    local sampler_log="${output_csv%.csv}_sampler.log"
    "$sampler" \
        --output "$output_csv" \
        --interval-ms "$interval_ms" \
        --smooth-samples "$smooth_samples" \
        >"$sampler_log" 2>&1 &
    GQ_MSR_TRACE_PID=$!
    log "Started ${role} C RAPL powercap trace pid=$GQ_MSR_TRACE_PID interval=${interval_ms}ms smoothing=${smooth_samples}"
}
'''
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "gq_common_p5.sh"
        path.write_text(sample, encoding="utf-8")
        patch(path)
        once = path.read_text(encoding="utf-8")
        assert once.count(GATE_MARKER) == 1
        assert once.count(AFFINITY_MARKER) == 1
        assert once.count('taskset -c "$recorder_cpu"') == 3
        assert once.count("_affinity.txt") == 3
        assert "GQ_CLAIM_RECORDER_CPU" in once
        code = "\n".join(line.split("#", 1)[0] for line in GATE_REPLACEMENT.splitlines())
        assert "ENABLE_RECORD=" not in code
        assert "export ENABLE_RECORD" not in code
        assert "${ENABLE_RECORD" not in code
        patch(path)
        assert path.read_text(encoding="utf-8") == once

        # Simulate a host already patched by the old V1 gate: affinity must still be added.
        old_gate_only = sample.replace(GATE_ANCHOR, GATE_REPLACEMENT, 1)
        path.write_text(old_gate_only, encoding="utf-8")
        patch(path)
        upgraded = path.read_text(encoding="utf-8")
        assert upgraded.count(GATE_MARKER) == 1
        assert upgraded.count(AFFINITY_MARKER) == 1
        assert upgraded.count('taskset -c "$recorder_cpu"') == 3
    print("P5 CLAIM ACTIVE RECORDER GATE + AFFINITY SELF-TEST PASS")


if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
    self_test()
elif len(sys.argv) == 2:
    patch(Path(sys.argv[1]))
else:
    raise SystemExit(
        "usage: enable_p5_claim_recording_gate.py PATH_TO_GQ_COMMON_P5_SH | --self-test"
    )
