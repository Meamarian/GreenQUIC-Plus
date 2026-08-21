#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
BASE="$HERE/mac_run_p5_p7_fair_repro_6x5.sh"
[[ -f "$BASE" ]] || { echo "ERROR: missing base launcher: $BASE" >&2; exit 2; }

TAG="$(date +%Y%m%d_%H%M%S)_$$"
PATCHED="${TMPDIR:-/tmp}/mac_run_p5_p7_fair_repro_6x5_v2_${TAG}.sh"
trap 'rm -f "$PATCHED"' EXIT INT TERM

python3 - "$BASE" "$PATCHED" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text(encoding="utf-8")


def replace_once(old: str, new: str, label: str) -> None:
    global src
    count = src.count(old)
    if count != 1:
        raise SystemExit(f"ERROR: expected exactly one {label} anchor, found {count}")
    src = src.replace(old, new, 1)

# GreenQUIC-Plus uses main as the authoritative final paper/development branch.
# Preserve the historical base launcher but rewrite its old source-branch name
# in the generated temporary runner.
replace_once(
    'BRANCH="performance2/p5-multicore"',
    'BRANCH="${GQ_FAIR_BRANCH:-main}"',
    "GreenQUIC+ fair branch",
)

# The final GreenQUIC+ paper evaluation uses the TOP3 focused policy and the
# measurement settings that accompanied the final 6x5 P5 evaluation. Inject
# them explicitly so the reproduction never depends on config.env defaults.
replace_once(
    '    --env GQ_IDLE_MODE_OVERRIDE=monitor \\\n'
    '    --env GQ_IDLE_FALLBACK_OVERRIDE=short \\\n'
    '    --env GQ_POST_TRANSFER_WAIT_S=0 \\\n',
    '    --env GQ_IDLE_MODE_OVERRIDE=monitor \\\n'
    '    --env GQ_IDLE_FALLBACK_OVERRIDE=short \\\n'
    '    --env GQ_ENABLE_ACPI_POWER_TRACE=1 \\\n'
    '    --env GQ_POWER_SAMPLE_INTERVAL_MS=1000 \\\n'
    '    --env GQ_ENABLE_MSR_TRACE=1 \\\n'
    '    --env GQ_MSR_SAMPLE_INTERVAL_MS=6 \\\n'
    '    --env GQ_MSR_SMOOTH_SAMPLES=3 \\\n'
    '    --env ENABLE_CSTATE_RECORD=1 \\\n'
    '    --env GQ_ENABLE_FREQ_TRACE=1 \\\n'
    '    --env GQ_FREQ_SAMPLE_INTERVAL_MS=1 \\\n'
    '    --env PRESSURE_UP=450 \\\n'
    '    --env RX_QUEUE_HIGH=48 \\\n'
    '    --env ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16 \\\n'
    '    --env FREQ_PERIOD_US=10000 \\\n'
    '    --env GQ_POST_TRANSFER_WAIT_S=0 \\\n',
    "final TOP3 P5 runtime settings",
)

replace_once(
    'P5_profile=optimized_Performance2_V2_idle_monitor_normal\n'
    'P5_dpdk_cpu=19\n'
    'P5_quic_cpus=21,22,23,24\n'
    'P5_recorder_cpu=auto_housekeeping\n',
    'P5_profile=optimized_Performance2_V2_TOP3_idle_monitor_normal\n'
    'P5_power_profile=TOP3\n'
    'P5_pressure_up=450\n'
    'P5_rx_queue_high=48\n'
    'P5_active_transfer_sleep_min_level=16\n'
    'P5_freq_period_us=10000\n'
    'P5_idle_mode=monitor\n'
    'P5_idle_fallback=short\n'
    'P5_acpi_interval_ms=1000\n'
    'P5_msr_interval_ms=6\n'
    'P5_freq_trace_interval_ms=1\n'
    'P5_dpdk_cpu=19\n'
    'P5_quic_cpus=21,22,23,24\n'
    'P5_recorder_cpu=auto_housekeeping\n',
    "paper config.env P5 profile",
)

replace_once(
    'echo "P5=optimized Performance2 V2 + idle_monitor_normal + isolated recorders"\n',
    'echo "P5=optimized Performance2 V2 + TOP3 power policy + idle_monitor_normal + isolated recorders"\n',
    "paper P5 banner",
)

# Mac creates the exact-SHA bundle. Remote nodes never contact GitHub.
replace_once(
    'LOCAL_SCRIPT="${TMPDIR:-/tmp}/GQ_FAIR_REPRO_${TAG}_$$.sh"\n',
    'LOCAL_SCRIPT="${TMPDIR:-/tmp}/GQ_FAIR_REPRO_${TAG}_$$.sh"\n'
    'LOCAL_BUNDLE="${TMPDIR:-/tmp}/GQ_FAIR_REPRO_${TAG}_$$.bundle"\n'
    'REMOTE_BUNDLE="/tmp/GQ_FAIR_REPRO_${TAG}.bundle"\n'
    'BUNDLE_REF="refs/heads/__gq_fair_repro_${TAG}_$$"\n',
    "bundle variables",
)

replace_once(
    'cleanup_local(){ rm -f "$LOCAL_SCRIPT"; }\n',
    'cleanup_local(){\n'
    '    git -C "$REPO_ROOT" update-ref -d "$BUNDLE_REF" 2>/dev/null || true\n'
    '    rm -f "$LOCAL_SCRIPT" "$LOCAL_BUNDLE"\n'
    '}\n',
    "local cleanup",
)

replace_once(
    'SHA="$(git rev-parse "origin/$BRANCH")"\n\n',
    'SHA="$(git rev-parse "origin/$BRANCH")"\n\n'
    '# Export this exact commit from the Mac. IDEX/Tinyman may intentionally have\n'
    '# no GitHub SSH credentials, so they synchronize only from this bundle.\n'
    'git update-ref "$BUNDLE_REF" "$SHA"\n'
    'rm -f "$LOCAL_BUNDLE"\n'
    'git bundle create "$LOCAL_BUNDLE" "$BUNDLE_REF"\n'
    'git update-ref -d "$BUNDLE_REF"\n'
    'git bundle verify "$LOCAL_BUNDLE" >/dev/null\n\n',
    "Mac bundle creation",
)

replace_once(
    'TAG="$1"; SHA="$2"; BRANCH="$3"; RUNS="$4"; DOWNLOADS="$5"; GAP="$6"; EDGE="$7"; BETWEEN="$8"; SEED="$9"\n',
    'TAG="$1"; SHA="$2"; BRANCH="$3"; RUNS="$4"; DOWNLOADS="$5"; GAP="$6"; EDGE="$7"; BETWEEN="$8"; SEED="$9"; BUNDLE="${10}"; BUNDLE_REF="${11}"\n',
    "remote positional arguments",
)

old_sync = '''sync_host(){
    local host="$1"
    if [[ "$host" == idex ]]; then
        cd "$ROOT"
        git reset --hard
        git fetch origin "$BRANCH"
        git checkout -B "$BRANCH" "$SHA"
        test "$(git rev-parse HEAD)" = "$SHA"
    else
        ssh -o BatchMode=yes -o ConnectTimeout=20 root@tinyman \\
            "cd '$ROOT' && git reset --hard && git fetch origin '$BRANCH' && git checkout -B '$BRANCH' '$SHA' && test \\\"\\$(git rev-parse HEAD)\\\" = '$SHA'"
    fi
}
'''
new_sync = '''sync_host(){
    local host="$1"
    if [[ "$host" == idex ]]; then
        test -s "$BUNDLE" || { echo "ERROR: exact-SHA bundle missing on IDEX: $BUNDLE" >&2; return 2; }
        cd "$ROOT"
        git reset --hard
        git fetch "$BUNDLE" "$BUNDLE_REF"
        git checkout -B "$BRANCH" FETCH_HEAD
        test "$(git rev-parse HEAD)" = "$SHA"
    else
        scp -o BatchMode=yes -o ConnectTimeout=20 "$BUNDLE" root@tinyman:"$BUNDLE"
        ssh -o BatchMode=yes -o ConnectTimeout=20 root@tinyman \\
            "cd '$ROOT' && git reset --hard && git fetch '$BUNDLE' '$BUNDLE_REF' && git checkout -B '$BRANCH' FETCH_HEAD && test \\\"\\$(git rev-parse HEAD)\\\" = '$SHA'"
    fi
}
'''
replace_once(old_sync, new_sync, "remote sync_host")

# Transfer the bundle to IDEX before the detached job starts.
replace_once(
    '# Install and launch only on IDEX. All Tinyman setup/cleanup now happens inside\n'
    '# the detached job, so a setup failure is visible in REMOTE_LOG instead of\n'
    '# making the Mac launcher disappear before a monitorable process exists.\n'
    'ssh "${SSH_OPTS[@]}" idex "cat > \'$REMOTE_SCRIPT\' && chmod 0700 \'$REMOTE_SCRIPT\'" < "$LOCAL_SCRIPT"\n',
    '# Install the exact-SHA bundle and runner on IDEX. Tinyman receives the same\n'
    '# bundle from IDEX inside the detached job; neither remote host contacts GitHub.\n'
    'scp "${SSH_OPTS[@]}" "$LOCAL_BUNDLE" "idex:$REMOTE_BUNDLE"\n'
    'ssh "${SSH_OPTS[@]}" idex "test -s \'$REMOTE_BUNDLE\'"\n'
    'ssh "${SSH_OPTS[@]}" idex "cat > \'$REMOTE_SCRIPT\' && chmod 0700 \'$REMOTE_SCRIPT\'" < "$LOCAL_SCRIPT"\n',
    "IDEX bundle transfer",
)

replace_once(
    '"rm -rf \'$REMOTE_ART\'; nohup setsid bash \'$REMOTE_SCRIPT\' \'$TAG\' \'$SHA\' \'$BRANCH\' \'$RUNS\' \'$DOWNLOADS\' \'$GAP_SECONDS\' \'$EDGE_COOLDOWN_SECONDS\' \'$BETWEEN_SECONDS\' \'$SEED\' >\'$REMOTE_LOG\' 2>&1 </dev/null & echo \\$! >\'$REMOTE_PID\'; echo REMOTE_PID=\\$(cat \'$REMOTE_PID\')"\n',
    '"rm -rf \'$REMOTE_ART\'; nohup setsid bash \'$REMOTE_SCRIPT\' \'$TAG\' \'$SHA\' \'$BRANCH\' \'$RUNS\' \'$DOWNLOADS\' \'$GAP_SECONDS\' \'$EDGE_COOLDOWN_SECONDS\' \'$BETWEEN_SECONDS\' \'$SEED\' \'$REMOTE_BUNDLE\' \'$BUNDLE_REF\' >\'$REMOTE_LOG\' 2>&1 </dev/null & echo \\$! >\'$REMOTE_PID\'; echo REMOTE_PID=\\$(cat \'$REMOTE_PID\')"\n',
    "remote launch arguments",
)

# Regression guards: only the Mac-side fetch from origin may remain.
remote_start = src.index("cat > \"$LOCAL_SCRIPT\" <<'REMOTE'")
remote_end = src.index("\nREMOTE\n", remote_start)
remote_body = src[remote_start:remote_end]
if "git fetch origin" in remote_body:
    raise SystemExit("ERROR: patched detached runner still contacts GitHub")
for required in (
    'BRANCH="${GQ_FAIR_BRANCH:-main}"',
    'git fetch "$BUNDLE" "$BUNDLE_REF"',
    'scp -o BatchMode=yes -o ConnectTimeout=20 "$BUNDLE" root@tinyman:"$BUNDLE"',
    'git bundle create "$LOCAL_BUNDLE" "$BUNDLE_REF"',
    'idex:$REMOTE_BUNDLE',
    '--env PRESSURE_UP=450',
    '--env RX_QUEUE_HIGH=48',
    '--env ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16',
    '--env FREQ_PERIOD_US=10000',
    '--env GQ_ENABLE_MSR_TRACE=1',
    '--env GQ_ENABLE_FREQ_TRACE=1',
    'P5_power_profile=TOP3',
):
    if required not in src:
        raise SystemExit(f"ERROR: missing GreenQUIC+ fair-repro guard: {required}")

Path(sys.argv[2]).write_text(src, encoding="utf-8")
PY

chmod 0700 "$PATCHED"
bash -n "$PATCHED"
exec bash "$PATCHED" "$@"
