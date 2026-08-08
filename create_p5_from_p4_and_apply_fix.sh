#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-/root/mohsen}"
P4_REL="greenquic_test_suite_v22/test_cases/pretests/P4_repeated_8GiB_downloads"
P5_REL="greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
P4="$REPO/$P4_REL"
P5="$REPO/$P5_REL"
FORCE=0
BUILD=1

while (($#)); do
    case "$1" in
        --force) FORCE=1; shift ;;
        --no-build) BUILD=0; shift ;;
        *) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
    esac
done

cd "$REPO"
[[ -d "$P4" ]] || { echo "ERROR: missing P4: $P4" >&2; exit 1; }
[[ -f "$P4/apply_p4_sequence.py" ]] || { echo "ERROR: current P4 sequence transformer missing" >&2; exit 1; }
grep -Fq 'GreenQUIC-P4-SEQUENCE-V2' "$P4/apply_p4_sequence.py" || {
    echo "ERROR: P4 is not the current V2 sequential/start-gate implementation." >&2
    exit 1
}
grep -Fq 'GQ_INTEROP_P4_START_GATE' "$P4/run_matrix_from_idex.sh" || {
    echo "ERROR: current P4 start-gate controller is missing." >&2
    exit 1
}

# P5 must be based on the checked-out GitHub P4, not local experimental edits.
git diff --quiet -- "$P4_REL" || {
    echo "ERROR: P4 has local tracked edits. Refusing to clone a dirty P4." >&2
    git status --short -- "$P4_REL" >&2
    exit 1
}
git diff --cached --quiet -- "$P4_REL" || {
    echo "ERROR: P4 has staged edits. Refusing to clone a dirty P4." >&2
    git status --short -- "$P4_REL" >&2
    exit 1
}

if [[ -e "$P5" ]]; then
    if ((FORCE)); then
        rm -rf "$P5"
    else
        echo "ERROR: P5 already exists: $P5 (use --force to recreate it)" >&2
        exit 1
    fi
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$(dirname "$P5")"

git archive HEAD "$P4_REL" | tar -x -C "$TMP"
mv "$TMP/$P4_REL" "$P5"

python3 - "$REPO" "$P5" <<'PY'
from __future__ import annotations
from pathlib import Path
import os
import re
import shutil
import sys

repo = Path(sys.argv[1])
p5 = Path(sys.argv[2])
shared = repo / "greenquic_test_suite_v22/common/bin"


def die(msg: str) -> None:
    raise SystemExit("ERROR: " + msg)


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        die(f"expected exactly one {label}, found {count}")
    return text.replace(old, new, 1)

# Rename P4-named files/directories first, deepest paths first.
for path in sorted(p5.rglob("*"), key=lambda x: len(x.parts), reverse=True):
    new_name = path.name.replace("P4", "P5").replace("p4", "p5")
    if new_name != path.name:
        target = path.with_name(new_name)
        if target.exists():
            die(f"rename collision: {target}")
        path.rename(target)

# Convert P4 identifiers/paths/markers to P5 only inside the copied tree.
for path in p5.rglob("*"):
    if not path.is_file():
        continue
    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        continue
    new = text.replace("P4", "P5").replace("p4", "p5")
    if new != text:
        path.write_text(new, encoding="utf-8")

# Keep reporting changes P5-local: P4/common remain untouched.
for src_name, dst_name in (
    ("run_role.sh", "run_role_p5.sh"),
    ("gq_common.sh", "gq_common_p5.sh"),
    ("bundle_run_results.py", "bundle_run_results_p5.py"),
    ("write_run_summary.py", "write_run_summary.py"),
):
    shutil.copy2(shared / src_name, p5 / dst_name)

# P5 run_role uses a P5-local gq_common, while that gq_common still points at
# the normal suite common directory for samplers/assets.
run_role = p5 / "run_role_p5.sh"
text = run_role.read_text(encoding="utf-8")
text = replace_once(
    text,
    'source "$HERE/gq_common.sh"',
    'source "$HERE/gq_common_p5.sh"',
    "run_role gq_common source",
)
run_role.write_text(text, encoding="utf-8")
os.chmod(run_role, 0o755)

gq = p5 / "gq_common_p5.sh"
text = gq.read_text(encoding="utf-8")
old_head = '''GQ_COMMON_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SUITE_ROOT="$(cd -- "$GQ_COMMON_DIR/.." && pwd)"'''
new_head = '''GQ_P5_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GQ_COMMON_DIR="$(cd -- "$GQ_P5_DIR/../../../common" && pwd)"
SUITE_ROOT="$(cd -- "$GQ_COMMON_DIR/.." && pwd)"'''
text = replace_once(text, old_head, new_head, "P5 gq_common path header")
needle = 'python3 "$GQ_COMMON_DIR/bin/bundle_run_results.py"'
if text.count(needle) < 1:
    die("cannot find bundle_run_results invocation in gq_common")
text = text.replace(needle, 'python3 "$GQ_P5_DIR/bundle_run_results_p5.py"')
gq.write_text(text, encoding="utf-8")
os.chmod(gq, 0o755)

# Point P5 role launchers to the isolated P5 binaries and P5-local reporting.
for name, binary_var, binary_name in (
    ("run_server.sh", "GQ_INTEROP_SERVER_BIN", "quicinteropserver"),
    ("run_client.sh", "GQ_INTEROP_CLIENT_BIN", "quicinterop"),
):
    path = p5 / name
    text = path.read_text(encoding="utf-8")
    text = replace_once(
        text,
        'source "$HERE/config.env"',
        'source "$HERE/config.env"\nREPO_ROOT="$(cd -- "$HERE/../../../.." && pwd)"\n'
        f'export {binary_var}="${{{binary_var}:-$REPO_ROOT/msquic/build-greenquic-p5/bin/Release/{binary_name}}}"',
        f"{name} binary override",
    )
    role_needle = '"$HERE/../../../common/bin/run_role.sh"'
    if role_needle not in text:
        die(f"cannot find shared run_role call in {name}")
    text = text.replace(role_needle, '"$HERE/run_role_p5.sh"')
    path.write_text(text, encoding="utf-8")
    os.chmod(path, 0o755)

# P5 build already has isolated msquic-p5-source/build-greenquic-p5 after the
# P4->P5 conversion. Extend it to patch the isolated datapath and build server.
build = p5 / "build_p5_client.sh"
text = build.read_text(encoding="utf-8")
text = replace_once(
    text,
    'TRANSFORM="$HERE/apply_p5_sequence.py"\nSOURCE="$P5_SOURCE/src/tools/interop/interop.cpp"',
    'TRANSFORM="$HERE/apply_p5_sequence.py"\nRESULTS_FIX="$HERE/apply_p5_datapath_fix.py"\nSOURCE="$P5_SOURCE/src/tools/interop/interop.cpp"',
    "P5 build transformer variables",
)
text = replace_once(
    text,
    'python3 "$TRANSFORM" "$SOURCE"',
    'python3 "$TRANSFORM" "$SOURCE"\npython3 "$RESULTS_FIX" "$P5_SOURCE/src/platform/datapath_raw_dpdk_linux.c"',
    "P5 datapath transform call",
)
text = replace_once(
    text,
    '    --target quicinterop \\\n',
    '    --target quicinterop quicinteropserver \\\n',
    "P5 build targets",
)
insert_before = 'echo\necho "P5 client binary:"'
server_check = '''SERVER_BIN="$BUILD/bin/Release/quicinteropserver"
test -x "$SERVER_BIN"
grep -aFq -- 'GreenQUIC FINAL idle_mode=' "$SERVER_BIN" || {
    echo "ERROR: built P5 server does not contain final idle counter output" >&2
    exit 2
}

echo
echo "P5 server binary:"
echo "PATH: $(readlink -f "$SERVER_BIN")"
sha256sum "$SERVER_BIN"

'''
if insert_before not in text:
    die("cannot find P5 client summary block in build script")
text = text.replace(insert_before, server_check + insert_before, 1)
build.write_text(text, encoding="utf-8")
os.chmod(build, 0o755)

# Create the isolated datapath patcher used by build_p5_client.sh.
datapath_fixer = p5 / "apply_p5_datapath_fix.py"
datapath_fixer.write_text(r'''#!/usr/bin/env python3
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
marker = "GREENQUIC-V22-FINAL-IDLE-COUNTERS-V1"
if marker in text:
    raise SystemExit(0)

def once(old, new, label):
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"ERROR: {label}: expected 1 old block, found {count}")
    text = text.replace(old, new, 1)

once(
    "static void GreenQuicIdleCleanupLcore(_Inout_ GREENQUIC_LCORE_STATE* S);",
    """static void GreenQuicIdleCleanupLcore(
    _In_ const DPDK_DATAPATH* Dpdk,
    _Inout_ GREENQUIC_LCORE_STATE* S,
    _In_ uint16_t Core);""",
    "cleanup declaration",
)
once(
    """GreenQuicIdleCleanupLcore(
    _Inout_ GREENQUIC_LCORE_STATE* S
    )
{""",
    """GreenQuicIdleCleanupLcore(
    _In_ const DPDK_DATAPATH* Dpdk,
    _Inout_ GREENQUIC_LCORE_STATE* S,
    _In_ uint16_t Core
    )
{
    /* GREENQUIC-V22-FINAL-IDLE-COUNTERS-V1: P5 isolated build. */
    printf(
        "[CPU %u] GreenQUIC FINAL idle_mode=%s "
        "monitor_try=%" PRIu64 " monitor_wake=%" PRIu64
        " monitor_timeout=%" PRIu64 " "
        "epoll_try=%" PRIu64 " epoll_wake=%" PRIu64
        " epoll_timeout=%" PRIu64 " wake_signal=%" PRIu64 "\\n",
        Core,
        GreenQuicIdleModeToString(Dpdk->GreenQuicIdleMode),
        S->MonitorAttempts,
        S->MonitorWakeups,
        S->MonitorTimeouts,
        S->EpollAttempts,
        S->EpollWakeups,
        S->EpollTimeouts,
        S->WakeSignals);
    fflush(stdout);""",
    "cleanup definition",
)
old_call = "GreenQuicIdleCleanupLcore(GreenQuicGetLcoreState(Dpdk, Core));"
count = text.count(old_call)
if count < 1:
    raise SystemExit("ERROR: no GreenQuicIdleCleanupLcore call sites found")
text = text.replace(
    old_call,
    "GreenQuicIdleCleanupLcore(\n            Dpdk, GreenQuicGetLcoreState(Dpdk, Core), Core);",
)
path.write_text(text, encoding="utf-8")
print(f"P5 datapath fix applied to {path}; call_sites={count}")
''', encoding="utf-8")
os.chmod(datapath_fixer, 0o755)

# P5-local bundle script: use shared plotting helpers, but local patched summary.
bundle = p5 / "bundle_run_results_p5.py"
text = bundle.read_text(encoding="utf-8")
anchor = "from pathlib import Path\n"
text = replace_once(
    text,
    anchor,
    anchor + '\nCOMMON_BIN = (Path(__file__).resolve().parent / "../../../common/bin").resolve()\n',
    "bundle COMMON_BIN",
)
text = re.sub(
    r'Path\(__file__\)\.with_name\("(frequency_trace\.py|rapl_msr_trace\.py|cstate_trace\.py)"\)',
    r'(COMMON_BIN / "\1")',
    text,
)
old_cstate = '''        if _gq_cstate_has_data:
            subprocess.run([
                "python3", str((COMMON_BIN / "cstate_trace.py")),
                "--csv", str(cstate_csv),
                "--summary", str(cstate_json),
                "--timeline-svg", str(run_dir / f"{stem}_cstate_timeseries.svg"),
                "--histogram-svg", str(run_dir / f"{stem}_cstate_wakeup_histogram.svg"),
                "--role", args.role,
            ], check=True)'''
new_cstate = '''        if _gq_cstate_has_data:
            # GREENQUIC-V22-CSTATE-PLOT-BEST-EFFORT-V1 (P5-local)
            try:
                subprocess.run([
                    "python3", str((COMMON_BIN / "cstate_trace.py")),
                    "--csv", str(cstate_csv),
                    "--summary", str(cstate_json),
                    "--timeline-svg", str(run_dir / f"{stem}_cstate_timeseries.svg"),
                    "--histogram-svg", str(run_dir / f"{stem}_cstate_wakeup_histogram.svg"),
                    "--role", args.role,
                ], check=True)
            except subprocess.CalledProcessError as exc:
                print(
                    "[GreenQUIC-Test:WARN] C-state plot generation failed "
                    f"(rc={exc.returncode}); preserving raw C-state data and "
                    "continuing bundle/summary generation."
                )'''
text = replace_once(text, old_cstate, new_cstate, "best-effort C-state plot block")
bundle.write_text(text, encoding="utf-8")
os.chmod(bundle, 0o755)

# P5-local write_run_summary fixes.
summary = p5 / "write_run_summary.py"
text = summary.read_text(encoding="utf-8")
# GREENQUIC-P5-COUNTER-AWARE-GENERATOR-V1
# The final shared summary already consumes the mandatory
# *_greenquic_counters.csv artifact and is independent of GQ_LOG_LEVEL.
# Only apply the older P5 log-derived EPOLL summary rewrite when that newer
# counter-aware summary is not present.
if (
    "GREENQUIC-V22-IDLE-COUNTER-PARSE-V1" not in text
    and "def counter_details(" not in text
):
    old = '''    actions = Counter(re.findall(r"policy_action=([^\\s]+)", text))
    watchdogs = [int(value) for value in re.findall(r"\\bwatchdog_us=(\\d+)", text)]
    return {
        "transmission_us": transmission[-1] if transmission else None,
        "completions": completions,
        "idle_modes": sorted(set(re.findall(r"\\bidle_mode=([^\\s]+)", text))),
        "epoll_try": max([int(value) for value in re.findall(r"\\bepoll_try=(\\d+)", text)] or [0]),
        "epoll_wake": max([int(value) for value in re.findall(r"\\bepoll_wake=(\\d+)", text)] or [0]),
        "epoll_timeout": max([int(value) for value in re.findall(r"\\bepoll_timeout=(\\d+)", text)] or [0]),
        "epoll_watchdog_us": watchdogs[-1] if watchdogs else None,
        "freq_action_counts": dict(actions),
    }'''
    new = '''    actions = Counter(re.findall(r"policy_action=([^\\s]+)", text))
    watchdogs = [int(value) for value in re.findall(r"\\bwatchdog_us=(\\d+)", text)]

    # GREENQUIC-V22-IDLE-COUNTER-PARSE-V1 (P5-local)
    idle_by_cpu: dict[int, tuple[int, int, int]] = {}
    for raw in text.splitlines():
        cpu = re.search(r"^\\[CPU\\s+(\\d+)\\]", raw)
        epoll_try = re.search(r"\\bepoll_try=(\\d+)\\b", raw)
        epoll_wake = re.search(r"\\bepoll_wake=(\\d+)\\b", raw)
        epoll_timeout = re.search(r"\\bepoll_timeout=(\\d+)\\b", raw)
        if cpu and epoll_try and epoll_wake and epoll_timeout:
            idle_by_cpu[int(cpu.group(1))] = (
                int(epoll_try.group(1)),
                int(epoll_wake.group(1)),
                int(epoll_timeout.group(1)),
            )
    configured_idle_modes = re.findall(r"GreenQUIC idle config:\\s+mode=([^\\s]+)", text)
    periodic_idle_modes = re.findall(r"\\bidle_mode=([^\\s]+)", text)
    return {
        "transmission_us": transmission[-1] if transmission else None,
        "completions": completions,
        "idle_modes": sorted(set(configured_idle_modes + periodic_idle_modes)),
        "epoll_try": sum(v[0] for v in idle_by_cpu.values()) if idle_by_cpu else None,
        "epoll_wake": sum(v[1] for v in idle_by_cpu.values()) if idle_by_cpu else None,
        "epoll_timeout": sum(v[2] for v in idle_by_cpu.values()) if idle_by_cpu else None,
        "epoll_watchdog_us": watchdogs[-1] if watchdogs else None,
        "freq_action_counts": dict(actions),
    }'''
    text = replace_once(text, old, new, "idle counter parser")

    text = replace_once(
        text,
        '''    timeout_count = int(log.get("epoll_timeout", 0) or 0)
    watchdog_us = log.get("epoll_watchdog_us")''',
        '''    timeout_raw = log.get("epoll_timeout")
    timeout_count = int(timeout_raw) if timeout_raw is not None else None
    watchdog_us = log.get("epoll_watchdog_us")''',
        "timeout availability",
    )
    text = replace_once(
        text,
        '''        f"- EPOLL attempts: {log.get('epoll_try', 0)}",
        f"- EPOLL wakeups: {log.get('epoll_wake', 0)}",
    ])
    if watchdog_us is not None:''',
        '''        f"- EPOLL attempts: {log.get('epoll_try') if log.get('epoll_try') is not None else 'unavailable'}",
        f"- EPOLL wakeups: {log.get('epoll_wake') if log.get('epoll_wake') is not None else 'unavailable'}",
    ])
    if timeout_count is not None and watchdog_us is not None:''',
        "EPOLL availability rendering",
    )
    text = replace_once(
        text,
        '''        lines.append(
            f"- EPOLL timeouts: {timeout_count} (configured timeout {timeout_ms:.3f} ms each; approximately {total_s:.3f} s total)"
        )
    else:
        lines.append(f"- EPOLL timeouts: {timeout_count}")''',
        '''        lines.append(
            f"- EPOLL timeouts: {timeout_count} (configured timeout {timeout_ms:.3f} ms each; approximately {total_s:.3f} s total)"
        )
    elif timeout_count is None:
        lines.append("- EPOLL timeouts: unavailable")
    else:
        lines.append(f"- EPOLL timeouts: {timeout_count}")''',
        "EPOLL timeout rendering",
    )

if "GREENQUIC-V22-RAW-CSTATE-SUMMARY-FALLBACK-V1" not in text:
    old = '''        state_counts = cstate.get("state_interval_counts") or {}
        state_idle_ms = cstate.get("state_total_idle_ms") or {}
        lines.extend([
            f"- Trace clock: {cstate.get('clock', 'unavailable')}",
            f"- CPUs traced: {', '.join(str(v) for v in cstate.get('cpus', [])) or 'none'}",
            f"- cpu_idle entries: {total_entries}",
            f"- Wakeups / idle exits: {total_wakeups}",
            f"- Completed idle intervals: {cstate.get('completed_idle_intervals', 0)}",
        ])'''
    new = '''        state_counts = cstate.get("state_interval_counts") or {}
        state_idle_ms = cstate.get("state_total_idle_ms") or {}

        # GREENQUIC-V22-RAW-CSTATE-SUMMARY-FALLBACK-V1 (P5-local)
        if not state_counts:
            recovered_counts: Counter[str] = Counter()
            recovered_idle_ms: dict[str, float] = {}
            for cpu_row in per_cpu.values():
                for state, state_row in (cpu_row.get("states") or {}).items():
                    recovered_counts[str(state)] += int(state_row.get("entries", 0) or 0)
                    recovered_idle_ms[str(state)] = (
                        recovered_idle_ms.get(str(state), 0.0)
                        + float(state_row.get("total_idle_ns", 0) or 0) / 1_000_000.0
                    )
            state_counts = dict(recovered_counts)
            state_idle_ms = recovered_idle_ms
        completed_intervals = cstate.get("completed_idle_intervals")
        if completed_intervals is None and state_counts:
            completed_intervals = sum(int(value) for value in state_counts.values())
        lines.extend([
            f"- Trace clock: {cstate.get('clock', 'unavailable')}",
            f"- CPUs traced: {', '.join(str(v) for v in cstate.get('cpus', [])) or 'none'}",
            f"- cpu_idle entries: {total_entries}",
            f"- Wakeups / idle exits: {total_wakeups}",
            f"- Completed idle intervals: {completed_intervals if completed_intervals is not None else 'unavailable'}",
        ])'''
    text = replace_once(text, old, new, "raw C-state fallback")
summary.write_text(text, encoding="utf-8")
os.chmod(summary, 0o755)

# P5 matrix core: long cleanup timeout so reporting can finish.
core = p5 / "run_matrix_from_idex_core.sh"
text = core.read_text(encoding="utf-8")
if "GREENQUIC-P5-SERVER-CLEANUP-TIMEOUT-V1" not in text:
    text = replace_once(
        text,
        'READY_TIMEOUT_SECONDS=90\nP5_CSTATE_CPU=19',
        'READY_TIMEOUT_SECONDS=90\nSERVER_CLEANUP_TIMEOUT_SECONDS="${SERVER_CLEANUP_TIMEOUT_SECONDS:-300}"\nP5_CSTATE_CPU=19',
        "cleanup timeout variable",
    )
    text = replace_once(
        text,
        '  --server-cooldown-seconds N  measured idle time before first and after last download (default 5)\n',
        '  --server-cooldown-seconds N  measured idle time before first and after last download (default 5)\n'
        '  --server-cleanup-timeout-seconds N\n'
        '                               maximum time for server samplers/report bundling\n'
        '                               after SIGINT (default 300)\n',
        "cleanup timeout usage",
    )
    text = replace_once(
        text,
        '        --server-cooldown-seconds) SERVER_COOLDOWN_SECONDS="${2:?missing value}"; shift 2 ;;\n',
        '        --server-cooldown-seconds) SERVER_COOLDOWN_SECONDS="${2:?missing value}"; shift 2 ;;\n'
        '        --server-cleanup-timeout-seconds) SERVER_CLEANUP_TIMEOUT_SECONDS="${2:?missing value}"; shift 2 ;;\n',
        "cleanup timeout parser",
    )
    text = replace_once(
        text,
        '[[ "$SERVER_COOLDOWN_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "ERROR: invalid --server-cooldown-seconds" >&2; exit 2; }\n',
        '[[ "$SERVER_COOLDOWN_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "ERROR: invalid --server-cooldown-seconds" >&2; exit 2; }\n'
        '[[ "$SERVER_CLEANUP_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: invalid --server-cleanup-timeout-seconds" >&2; exit 2; }\n',
        "cleanup timeout validation",
    )
    text = replace_once(text, '    local rc=0 app_pids=""\n', '    local rc=0 app_pids="" cleanup_polls\n', "stop_server locals")
    text = replace_once(
        text,
        '''        for _ in $(seq 1 300); do
            kill -0 "$SERVER_PGID" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$SERVER_PGID" 2>/dev/null; then
            warn "server did not stop cleanly after 30s; terminating its process group"''',
        '''        # GREENQUIC-P5-SERVER-CLEANUP-TIMEOUT-V1
        cleanup_polls=$((SERVER_CLEANUP_TIMEOUT_SECONDS * 10))
        for _ in $(seq 1 "$cleanup_polls"); do
            kill -0 "$SERVER_PGID" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$SERVER_PGID" 2>/dev/null; then
            warn "server cleanup did not finish after ${SERVER_CLEANUP_TIMEOUT_SECONDS}s; terminating its process group"''',
        "stop_server cleanup loop",
    )
core.write_text(text, encoding="utf-8")
os.chmod(core, 0o755)

# P5 matrix aggregation: prefer authoritative bundle summaries when needed.
agg = p5 / "aggregate_p5_matrix.py"
text = agg.read_text(encoding="utf-8")
if "GREENQUIC-P5-BUNDLE-SUMMARY-FALLBACK-V1" not in text:
    old = '''        rows = parse_sections(path.read_text(encoding="utf-8", errors="replace"))
        payload_gib = extract_number(rows.get("greenquic_p5_workload_summary__total_payload"))'''
    new = '''        repetition = int(match.group(2))
        mode = match.group(3)
        rows = parse_sections(path.read_text(encoding="utf-8", errors="replace"))

        # GREENQUIC-P5-BUNDLE-SUMMARY-FALLBACK-V1
        rep_dir = folder / "runs" / role / f"rep{repetition:02d}_{mode}"
        bundle_summaries = sorted(rep_dir.glob("*/details/*_summary.txt"))
        if bundle_summaries:
            bundle_rows = parse_sections(
                bundle_summaries[-1].read_text(encoding="utf-8", errors="replace")
            )
            for key, value in bundle_rows.items():
                current = str(rows.get(key, "")).strip().upper()
                if not current or current in {"N/A", "UNAVAILABLE"}:
                    rows[key] = value

        payload_gib = extract_number(rows.get("greenquic_p5_workload_summary__total_payload"))'''
    text = replace_once(text, old, new, "aggregate bundle fallback")
    text = replace_once(
        text,
        '''            "repetition": int(match.group(2)),
            "mode": match.group(3),''',
        '''            "repetition": repetition,
            "mode": mode,''',
        "aggregate repetition/mode",
    )
agg.write_text(text, encoding="utf-8")
os.chmod(agg, 0o755)

# P5 finalizer requires summaries as well as bundles.
fin = p5 / "p5_finalize_matrix.py"
text = fin.read_text(encoding="utf-8")
if "all_run_summaries_present" not in text:
    text = replace_once(
        text,
        '''    server_bundles = sorted((matrix / "runs" / "server").glob("rep*/*"))
    client_bundles = sorted((matrix / "runs" / "client").glob("rep*/*"))''',
        '''    server_bundles = sorted((matrix / "runs" / "server").glob("rep*/*"))
    client_bundles = sorted((matrix / "runs" / "client").glob("rep*/*"))
    server_summaries = sorted((matrix / "runs" / "server").glob("rep*/*/details/*_summary.txt"))
    client_summaries = sorted((matrix / "runs" / "client").glob("rep*/*/details/*_summary.txt"))''',
        "finalizer summary lists",
    )
    text = replace_once(
        text,
        '''        "server_run_bundles": len(server_bundles),
        "client_run_bundles": len(client_bundles),''',
        '''        "server_run_bundles": len(server_bundles),
        "client_run_bundles": len(client_bundles),
        "server_run_summaries": len(server_summaries),
        "client_run_summaries": len(client_summaries),''',
        "finalizer summary counts",
    )
    text = replace_once(
        text,
        '''        "all_run_bundles_present": (
            expected > 0
            and len(server_bundles) == expected
            and len(client_bundles) == expected
        ),''',
        '''        "all_run_bundles_present": (
            expected > 0
            and len(server_bundles) == expected
            and len(client_bundles) == expected
        ),
        "all_run_summaries_present": (
            expected > 0
            and len(server_summaries) == expected
            and len(client_summaries) == expected
        ),''',
        "finalizer summary status",
    )
    text = replace_once(
        text,
        '''        f"Server bundles found: {len(server_bundles)}\\n"
        f"Client bundles found: {len(client_bundles)}\\n"''',
        '''        f"Server bundles found: {len(server_bundles)}\\n"
        f"Client bundles found: {len(client_bundles)}\\n"
        f"Server summaries found: {len(server_summaries)}\\n"
        f"Client summaries found: {len(client_summaries)}\\n"''',
        "finalizer report text",
    )
    text = replace_once(
        text,
        '''        len(server_bundles) != expected
        or len(client_bundles) != expected
        or len(env_server) != expected''',
        '''        len(server_bundles) != expected
        or len(client_bundles) != expected
        or len(server_summaries) != expected
        or len(client_summaries) != expected
        or len(env_server) != expected''',
        "finalizer required summaries",
    )
fin.write_text(text, encoding="utf-8")
os.chmod(fin, 0o755)

# Add a short provenance note without changing P4.
readme = p5 / "README_P5_ISOLATION.md"
readme.write_text(
    "P5 is generated from the current tracked P4 at the same Git commit.\n"
    "P4 is not modified. P5 uses msquic-p5-source/build-greenquic-p5,\n"
    "P5-local gq_common/run_role/bundle/summary files, and the V2 start gate.\n",
    encoding="utf-8",
)

# Basic structural verification.
checks = [
    (p5 / "apply_p5_sequence.py", "GreenQUIC-P5-SEQUENCE-V2"),
    (p5 / "run_matrix_from_idex.sh", "GQ_INTEROP_P5_START_GATE"),
    (p5 / "run_matrix_from_idex_core.sh", "GREENQUIC-P5-SERVER-CLEANUP-TIMEOUT-V1"),
    (p5 / "aggregate_p5_matrix.py", "GREENQUIC-P5-BUNDLE-SUMMARY-FALLBACK-V1"),
    (p5 / "p5_finalize_matrix.py", "all_run_summaries_present"),
    (p5 / "write_run_summary.py", "QUIC-Side Hint Events"),
    (p5 / "bundle_run_results_p5.py", "GREENQUIC-V22-CSTATE-PLOT-BEST-EFFORT-V1"),
]
for path, marker in checks:
    if marker not in path.read_text(encoding="utf-8", errors="replace"):
        die(f"P5 marker missing: {marker} in {path}")

print(f"P5 created and patched: {p5}")
PY

# GREENQUIC-P5-SERVER-FINALIZATION-GENERATOR-V1
# Reapply the P5-only server shutdown/logger safety after every regeneration.
python3 "$REPO/greenquic_p5_finalize_generated_tree.py" "$REPO" "$P5"
# GREENQUIC-P5-FINALIZER-V2-HOOK
python3 "$REPO/greenquic_p5_finalize_generated_tree_v2.py" "$REPO" "$P5"

# P4 must still be untouched.
git diff --quiet -- "$P4_REL" || {
    echo "ERROR: P4 changed unexpectedly." >&2
    git diff -- "$P4_REL" >&2
    exit 1
}
git diff --cached --quiet -- "$P4_REL" || {
    echo "ERROR: staged P4 changes appeared unexpectedly." >&2
    exit 1
}

if ((BUILD)); then
    echo
    echo "===== BUILD ISOLATED P5 BINARIES ON $(hostname) ====="
    "$P5/build_p5_client.sh"

    test -x "$REPO/msquic/build-greenquic-p5/bin/Release/quicinterop"
    test -x "$REPO/msquic/build-greenquic-p5/bin/Release/quicinteropserver"
    grep -aFq 'GreenQUIC-P5-SEQUENCE-V2' "$REPO/msquic/build-greenquic-p5/bin/Release/quicinterop"
    grep -aFq 'GreenQUIC FINAL idle_mode=' "$REPO/msquic/build-greenquic-p5/bin/Release/quicinteropserver"
fi

echo
echo "============================================================"
echo "P5 READY ON $(hostname)"
echo "P4 UNCHANGED: $P4"
echo "P5 TEST DIR:  $P5"
echo "P5 BUILD:     $REPO/msquic/build-greenquic-p5"
echo "============================================================"
