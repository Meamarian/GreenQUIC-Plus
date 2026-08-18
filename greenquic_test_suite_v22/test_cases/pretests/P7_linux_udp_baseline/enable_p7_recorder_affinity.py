#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import tempfile

MARKER = "GREENQUIC-P7-RECORDER-AFFINITY-V1"

OLD_CHOOSER = r'''p7_choose_reader_cpu() {
    local measured="$1"
    python3 - "$measured" "$P7_QUIC_CPUS" <<'PY'
from pathlib import Path
import sys
def parse(s):
    out=set()
    for t in s.replace(' ','').split(','):
        if not t: continue
        if '-' in t:
            a,b=map(int,t.split('-',1)); out.update(range(a,b+1))
        else: out.add(int(t))
    return out
online=parse(Path('/sys/devices/system/cpu/online').read_text().strip())
used=parse(sys.argv[1]) | parse(sys.argv[2])
for cpu in list(used):
    p=Path(f'/sys/devices/system/cpu/cpu{cpu}/topology/thread_siblings_list')
    if p.exists(): used |= parse(p.read_text().strip())
left=sorted(online-used)
if not left: raise SystemExit('no housekeeping CPU available for C-state recorder')
print(left[0])
PY
}
'''

NEW_CHOOSER = r'''# GREENQUIC-P7-RECORDER-AFFINITY-V1
# One observer CPU is shared by RAPL, frequency, and C-state readers. Auto mode
# excludes measured CPUs, the configured Linux dataplane CPU, MsQuic CPUs, and
# all SMT siblings of those protected CPUs.
p7_choose_reader_cpu() {
    local measured="$1"
    python3 - "$measured" "$P7_QUIC_CPUS" "$P7_DATAPLANE_CPU" "${P7_RECORDER_CPU:-auto}" <<'PY'
from pathlib import Path
import sys

def parse(s):
    out=set()
    for t in s.replace(' ','').split(','):
        if not t: continue
        if '-' in t:
            a,b=map(int,t.split('-',1))
            if b<a: raise ValueError(f'invalid CPU range: {t}')
            out.update(range(a,b+1))
        else: out.add(int(t))
    return out

online=parse(Path('/sys/devices/system/cpu/online').read_text().strip())
used=parse(sys.argv[1]) | parse(sys.argv[2]) | parse(sys.argv[3])
for cpu in list(used):
    p=Path(f'/sys/devices/system/cpu/cpu{cpu}/topology/thread_siblings_list')
    if p.exists(): used |= parse(p.read_text().strip())

request=sys.argv[4].strip().lower()
if request == 'auto':
    left=sorted(online-used)
    if not left: raise SystemExit('no housekeeping CPU available outside dataplane/QUIC/measured CPUs and SMT siblings')
    chosen=left[0]
else:
    try: chosen=int(request)
    except ValueError: raise SystemExit(f"P7_RECORDER_CPU must be 'auto' or an integer, got {request!r}")
    if chosen not in online: raise SystemExit(f'requested P7 recorder CPU {chosen} is not online')
    if chosen in used: raise SystemExit(f'requested P7 recorder CPU {chosen} conflicts with dataplane/QUIC/measured CPUs or SMT siblings')
print(chosen)
PY
}
'''

PID_ANCHOR = 'P7_RAPL_PID=""; P7_FREQ_PID=""; P7_CSTATE_PID=""\n'
PID_REPLACEMENT = r'''p7_record_affinity_evidence() {
    local pid="$1" cpu="$2" out="$3" kind="$4"
    {
        printf 'kind=%s\n' "$kind"
        printf 'pid=%s\n' "$pid"
        printf 'selected_cpu=%s\n' "$cpu"
        awk '/^Cpus_allowed_list:/ {print "cpus_allowed_list=" $2}' "/proc/$pid/status" 2>/dev/null || true
        taskset -pc "$pid" 2>&1 || true
    } > "$out"
}

P7_RAPL_PID=""; P7_FREQ_PID=""; P7_CSTATE_PID=""
'''

RAPL_OLD = r'''    "$P7_COMMON_BIN/gq_rapl_msr_sampler" --output "$run_dir/rapl.csv" --interval-ms "$P7_RAPL_INTERVAL_MS" --smooth-samples "$P7_RAPL_SMOOTH_SAMPLES" > "$run_dir/rapl_sampler.log" 2>&1 & P7_RAPL_PID=$!
'''
RAPL_NEW = r'''    taskset -c "$reader" "$P7_COMMON_BIN/gq_rapl_msr_sampler" --output "$run_dir/rapl.csv" --interval-ms "$P7_RAPL_INTERVAL_MS" --smooth-samples "$P7_RAPL_SMOOTH_SAMPLES" > "$run_dir/rapl_sampler.log" 2>&1 & P7_RAPL_PID=$!
'''

FREQ_OLD = r'''    python3 "$P7_DIR/p7_frequency_sampler.py" --cpus "$cpus" --output "$run_dir/frequency.jsonl" --interval-ms "$P7_FREQ_INTERVAL_MS" > "$run_dir/frequency_sampler.log" 2>&1 & P7_FREQ_PID=$!
'''
FREQ_NEW = r'''    taskset -c "$reader" python3 "$P7_DIR/p7_frequency_sampler.py" --cpus "$cpus" --output "$run_dir/frequency.jsonl" --interval-ms "$P7_FREQ_INTERVAL_MS" > "$run_dir/frequency_sampler.log" 2>&1 & P7_FREQ_PID=$!
'''

CSTATE_OLD = r'''    taskset -c "$reader" "$P7_COMMON_BIN/gq_cstate_trace" --cpus "$cpus" --output "$run_dir/cstate.csv" --summary "$run_dir/cstate.json" > "$run_dir/cstate_sampler.log" 2>&1 & P7_CSTATE_PID=$!
    sleep 0.12
'''
CSTATE_NEW = r'''    taskset -c "$reader" "$P7_COMMON_BIN/gq_cstate_trace" --cpus "$cpus" --output "$run_dir/cstate.csv" --summary "$run_dir/cstate.json" > "$run_dir/cstate_sampler.log" 2>&1 & P7_CSTATE_PID=$!
    sleep 0.12
    p7_record_affinity_evidence "$P7_RAPL_PID" "$reader" "$run_dir/rapl_affinity.txt" rapl_msr
    p7_record_affinity_evidence "$P7_FREQ_PID" "$reader" "$run_dir/frequency_affinity.txt" frequency
    p7_record_affinity_evidence "$P7_CSTATE_PID" "$reader" "$run_dir/cstate_affinity.txt" cstate
'''

LOG_OLD = r'''    p7_log "$role recorders started: RAPL=$P7_RAPL_PID frequency=$P7_FREQ_PID cstate=$P7_CSTATE_PID cpus=$cpus reader=$reader"
'''
LOG_NEW = r'''    p7_log "$role recorders started: RAPL=$P7_RAPL_PID frequency=$P7_FREQ_PID cstate=$P7_CSTATE_PID measured_cpus=$cpus recorder_cpu=$reader"
'''


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"ERROR: {label} anchor count={count}, expected 1")
    return text.replace(old, new, 1)


def patch_text(text: str) -> str:
    if MARKER in text:
        return text
    text = replace_once(text, OLD_CHOOSER, NEW_CHOOSER, "reader chooser")
    text = replace_once(text, PID_ANCHOR, PID_REPLACEMENT, "recorder PID block")
    text = replace_once(text, RAPL_OLD, RAPL_NEW, "RAPL launch")
    text = replace_once(text, FREQ_OLD, FREQ_NEW, "frequency launch")
    text = replace_once(text, CSTATE_OLD, CSTATE_NEW, "C-state/evidence block")
    text = replace_once(text, LOG_OLD, LOG_NEW, "recorder log")
    return text


def patch(source: Path, output: Path | None = None) -> None:
    target = output or source
    original = source.read_text(encoding="utf-8")
    updated = patch_text(original)
    target.write_text(updated, encoding="utf-8")
    subprocess.run(["bash", "-n", str(target)], check=True)
    state = "already present" if updated == original and MARKER in original else "applied"
    print(f"P7 recorder affinity {state} + bash -n PASS: {target}")


def self_test() -> None:
    sample = r'''#!/usr/bin/env bash
p7_choose_reader_cpu() {
    local measured="$1"
    python3 - "$measured" "$P7_QUIC_CPUS" <<'PY'
from pathlib import Path
import sys
def parse(s):
    out=set()
    for t in s.replace(' ','').split(','):
        if not t: continue
        if '-' in t:
            a,b=map(int,t.split('-',1)); out.update(range(a,b+1))
        else: out.add(int(t))
    return out
online=parse(Path('/sys/devices/system/cpu/online').read_text().strip())
used=parse(sys.argv[1]) | parse(sys.argv[2])
for cpu in list(used):
    p=Path(f'/sys/devices/system/cpu/cpu{cpu}/topology/thread_siblings_list')
    if p.exists(): used |= parse(p.read_text().strip())
left=sorted(online-used)
if not left: raise SystemExit('no housekeeping CPU available for C-state recorder')
print(left[0])
PY
}
P7_RAPL_PID=""; P7_FREQ_PID=""; P7_CSTATE_PID=""
p7_start_recorders() {
    local role="$1" run_dir="$2" cpus reader
    cpus="19"; reader="$(p7_choose_reader_cpu "$cpus")"
    "$P7_COMMON_BIN/gq_rapl_msr_sampler" --output "$run_dir/rapl.csv" --interval-ms "$P7_RAPL_INTERVAL_MS" --smooth-samples "$P7_RAPL_SMOOTH_SAMPLES" > "$run_dir/rapl_sampler.log" 2>&1 & P7_RAPL_PID=$!
    python3 "$P7_DIR/p7_frequency_sampler.py" --cpus "$cpus" --output "$run_dir/frequency.jsonl" --interval-ms "$P7_FREQ_INTERVAL_MS" > "$run_dir/frequency_sampler.log" 2>&1 & P7_FREQ_PID=$!
    taskset -c "$reader" "$P7_COMMON_BIN/gq_cstate_trace" --cpus "$cpus" --output "$run_dir/cstate.csv" --summary "$run_dir/cstate.json" > "$run_dir/cstate_sampler.log" 2>&1 & P7_CSTATE_PID=$!
    sleep 0.12
    p7_log "$role recorders started: RAPL=$P7_RAPL_PID frequency=$P7_FREQ_PID cstate=$P7_CSTATE_PID cpus=$cpus reader=$reader"
}
'''
    with tempfile.TemporaryDirectory() as td:
        src = Path(td) / "p7_common.sh"
        dst = Path(td) / "patched.sh"
        src.write_text(sample, encoding="utf-8")
        patch(src, dst)
        text = dst.read_text(encoding="utf-8")
        assert text.count(MARKER) == 1
        assert text.count('taskset -c "$reader"') == 3
        assert "P7_DATAPLANE_CPU" in text
        assert "P7_RECORDER_CPU" in text
        assert text.count("_affinity.txt") == 3
        patch(dst)
        assert dst.read_text(encoding="utf-8") == text
    print("P7 RECORDER AFFINITY SELF-TEST PASS")


if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
    self_test()
elif len(sys.argv) == 2:
    patch(Path(sys.argv[1]))
elif len(sys.argv) == 3:
    patch(Path(sys.argv[1]), Path(sys.argv[2]))
else:
    raise SystemExit(
        "usage: enable_p7_recorder_affinity.py P7_COMMON [OUTPUT] | --self-test"
    )
