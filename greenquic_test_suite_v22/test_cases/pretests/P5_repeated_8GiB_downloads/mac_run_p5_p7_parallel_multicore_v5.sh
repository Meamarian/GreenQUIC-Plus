#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
V4="$HERE/mac_run_p5_p7_parallel_multicore_v4.sh"
CLEANER="$HERE/safe_cleanup_greenquic_processes.py"
BRANCH=performance2/p5-multicore
RUNS="${P5_MC_RUNS:-2}"
CONNECTIONS="${P5_MC_CONNECTIONS:-4}"
TAG="${P5_MC_TAG:-$(date +%Y%m%d_%H%M%S)}"
LOCAL_LOG="$HOME/Downloads/P5_P7_MC_${TAG}.mac.log"
LOCAL_EXPORT="$HOME/Downloads/P5_P7_MC_EXPORT_${TAG}"
REMOTE_CLEANER="/tmp/safe_cleanup_greenquic_processes_${TAG}.py"
SSH=(-o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3)

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
retry(){
    local rc
    while true; do
        if "$@"; then return 0; else rc=$?; fi
        if (( rc == 255 )); then
            log "SSH/SCP transport lost; retrying in 5 s"
            sleep 5
        else
            return "$rc"
        fi
    done
}

tiny(){
    local cmd="${1:?missing Tinyman command}" q
    printf -v q '%q' "$cmd"
    retry ssh "${SSH[@]}" idex "ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman $q"
}

[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: P5_MC_RUNS must be positive" >&2; exit 2; }
[[ "$CONNECTIONS" =~ ^[2-9][0-9]*$ ]] || { echo "ERROR: P5_MC_CONNECTIONS must be >=2" >&2; exit 2; }
[[ -f "$V4" && -f "$CLEANER" ]] || { echo "ERROR: V4/cleanup helper missing" >&2; exit 2; }
python3 "$CLEANER" --help >/dev/null

if [[ "${1:-}" == "--detach" ]]; then
    shift
    nohup caffeinate -dimsu env \
        P5_MC_RUNS="$RUNS" \
        P5_MC_CONNECTIONS="$CONNECTIONS" \
        P5_MC_TAG="$TAG" \
        bash "$0" --foreground >"$LOCAL_LOG" 2>&1 </dev/null &
    pid=$!
    disown "$pid" 2>/dev/null || true
    echo "STARTED P5+P7 PARALLEL MULTICORE V5 PID=$pid"
    echo "TAG=$TAG"
    echo "MAC_LOG=$LOCAL_LOG"
    echo "FINAL_EXPORT=$LOCAL_EXPORT"
    echo "V5 performs safe stale-process cleanup, always attempts P5 then P7, and separates traffic failures from fairness diagnostics."
    exit 0
fi
[[ "${1:-}" == "--foreground" ]] && shift || true
[[ $# -eq 0 ]] || { echo "ERROR: unknown arguments: $*" >&2; exit 2; }

cd "$HERE"
LOCAL_REPO="$(git rev-parse --show-toplevel)"
LOCAL_BRANCH="$(git -C "$LOCAL_REPO" branch --show-current)"
[[ "$LOCAL_BRANCH" == "$BRANCH" ]] || { echo "ERROR: local branch=$LOCAL_BRANCH expected=$BRANCH" >&2; exit 2; }
[[ -z "$(git -C "$LOCAL_REPO" status --porcelain --untracked-files=no)" ]] || {
    echo "ERROR: tracked local changes present; commit/stash before launch" >&2
    exit 2
}

# FIRST REMOTE ACTION: install and execute the ancestry-safe process cleanup.
log "installing safe cleanup helper on IDEX + Tinyman"
retry scp "${SSH[@]}" "$CLEANER" "idex:$REMOTE_CLEANER"
retry ssh "${SSH[@]}" idex "scp -q -o BatchMode=yes -o ConnectTimeout=15 '$REMOTE_CLEANER' root@tinyman:'$REMOTE_CLEANER'"
retry ssh "${SSH[@]}" idex "chmod 0700 '$REMOTE_CLEANER'"
tiny "chmod 0700 '$REMOTE_CLEANER'"

run_cleanup_idex(){
    local marker="/tmp/gq_cleanup_${TAG}_idex.done"
    local logf="/tmp/gq_cleanup_${TAG}_idex.log"
    local jsonf="/tmp/gq_cleanup_${TAG}_idex.json"
    retry ssh "${SSH[@]}" idex \
        "rm -f '$marker' '$logf' '$jsonf'; nohup setsid python3 '$REMOTE_CLEANER' --marker '$marker' --json '$jsonf' >'$logf' 2>&1 </dev/null & echo CLEANUP_PID=\$!"
    while true; do
        if ssh "${SSH[@]}" idex "test -f '$marker'" >/dev/null 2>&1; then break; fi
        sleep 1
    done
    retry ssh "${SSH[@]}" idex \
        "cat '$logf'; test \"\$(cat '$marker')\" = PASS; python3 '$REMOTE_CLEANER' --check"
}

run_cleanup_tinyman(){
    local marker="/tmp/gq_cleanup_${TAG}_tinyman.done"
    local logf="/tmp/gq_cleanup_${TAG}_tinyman.log"
    local jsonf="/tmp/gq_cleanup_${TAG}_tinyman.json"
    tiny "rm -f '$marker' '$logf' '$jsonf'; nohup setsid python3 '$REMOTE_CLEANER' --marker '$marker' --json '$jsonf' >'$logf' 2>&1 </dev/null & echo CLEANUP_PID=\$!"
    while true; do
        if tiny "test -f '$marker'" >/dev/null 2>&1; then break; fi
        sleep 1
    done
    tiny "cat '$logf'; test \"\$(cat '$marker')\" = PASS; python3 '$REMOTE_CLEANER' --check"
}

log "cleaning stale GreenQUIC/P5/P7 process trees on IDEX"
run_cleanup_idex
log "cleaning stale GreenQUIC/P5/P7 process trees on Tinyman"
run_cleanup_tinyman
log "SAFE STALE-PROCESS CLEANUP PASS: IDEX + Tinyman"

# V4 retains the proven branch-bundle sync, detached remote launch, resumable
# live log and exports. V5 rewrites only orchestration semantics:
#   * safe cleanup is already complete;
#   * P5/P7 use fair wrappers;
#   * a phase diagnostic/failure never prevents the other phase from being attempted;
#   * final validity is carried as data, not by killing the suite early.
TMP_V4="$(mktemp "${TMPDIR:-/tmp}/greenquic_mc_v4_fair.XXXXXX.sh")"
python3 - "$V4" "$TMP_V4" <<'PY'
from pathlib import Path
import sys
src = Path(sys.argv[1]).read_text(encoding="utf-8")

start_marker = "# FIRST ACTION: kill stale P5/P7/GreenQUIC processes on both test hosts."
end_marker = 'log "stale-process cleanup PASS on IDEX + Tinyman"\n'
start = src.find(start_marker)
end = src.find(end_marker)
if start < 0 or end < 0 or end < start:
    raise SystemExit("ERROR: V4 cleanup anchors changed; refusing unsafe transform")
end += len(end_marker)
src = src[:start] + (
    "# GREENQUIC-V5-SAFE-CLEANUP-V1\n"
    "# Safe stale-process cleanup was already completed and verified by V5.\n"
    'log "V5 safe stale-process cleanup already PASS on IDEX + Tinyman"\n'
) + src[end:]

# Both directories provide this fair wrapper name. Preflight and actual traffic
# must use the same wrapper contract.
runner_count = src.count("run_parallel_multicore_matrix.sh")
if runner_count != 4:
    raise SystemExit(f"ERROR: expected 4 P5/P7 runner references in V4, found {runner_count}")
src = src.replace("run_parallel_multicore_matrix.sh", "run_parallel_multicore_fair.sh")

# Phase return codes are recorded, but P7 is ALWAYS attempted after P5.
p5_old='if [[ $P5RC -ne 0 ]]; then echo "P5:$P5RC" > "$STATE.FAIL"; exit "$P5RC"; fi\n'
p5_new='if [[ $P5RC -ne 0 ]]; then echo "WARN: P5 phase rc=$P5RC; preserving results and continuing to mandatory P7"; fi\n'
p7_old='if [[ $P7RC -ne 0 ]]; then echo "P7:$P7RC" > "$STATE.FAIL"; exit "$P7RC"; fi\n'
p7_new='if [[ $P7RC -ne 0 ]]; then echo "WARN: P7 phase rc=$P7RC; preserving results and building partial final summary"; fi\n'
if src.count(p5_old)!=1 or src.count(p7_old)!=1:
    raise SystemExit("ERROR: V4 phase abort anchors changed")
src=src.replace(p5_old,p5_new,1).replace(p7_old,p7_new,1)

# Replace the old all-or-nothing CSV combiner. The new builder tolerates a
# missing/failed phase, reports which cases exist, and marks fair validity only
# when both dataplanes prove CPU19/CPU20 engagement.
summary_start = r'''python3 - \
 "$P5_MATRIX/parallel_tables/parallel_goodput_summary.csv"'''
summary_end = 'touch "$STATE.DONE"\n'
s0 = src.find(summary_start)
s1 = src.find(summary_end, s0)
if s0 < 0 or s1 < 0:
    raise SystemExit("ERROR: V4 summary block anchors changed")
s1 += len(summary_end)
summary_new = '''python3 "$P5/build_p5_p7_fair_summary.py" \\
  --p5-matrix "$P5_MATRIX" \\
  --p7-matrix "$P7_MATRIX" \\
  --p5-rc "$P5RC" \\
  --p7-rc "$P7RC" \\
  --output "$SUMMARY"
SUMMARY_RC=$?
if [[ $SUMMARY_RC -ne 0 ]]; then echo "SUMMARY:$SUMMARY_RC" > "$STATE.FAIL"; exit "$SUMMARY_RC"; fi
printf 'P5_RC=%s\\nP7_RC=%s\\n' "$P5RC" "$P7RC" > "$STATE.PHASES"
touch "$STATE.DONE"
'''
src = src[:s0] + summary_new + src[s1:]

# Export the new core-engagement evidence and fix the old P7 IRQ filename.
p5_anchor='''    parallel_queue_activity.json \\
    multicore_validation.json \\
'''
p5_insert='''    parallel_queue_activity.json \\
    parallel_tables/dpdk_lcore_activity.csv \\
    parallel_tables/dpdk_lcore_activity_summary.csv \\
    dpdk_lcore_activity_validation.json \\
    P5_FAIRNESS_STATUS.json \\
    multicore_validation.json \\
'''
if src.count(p5_anchor)!=1:
    raise SystemExit(f"ERROR: P5 export anchor count={src.count(p5_anchor)}")
src=src.replace(p5_anchor,p5_insert,1)

src=src.replace('    parallel_irq_activity.json \\\n', '''    parallel_irq_activity_validation.json \\
    parallel_tables/linux_dataplane_cpu_activity.csv \\
    parallel_tables/linux_dataplane_cpu_activity_summary.csv \\
    P7_FAIRNESS_STATUS.json \\
''', 1)

# P5 exports are best-effort too, so a partial phase does not break delivery of
# the P7 results that were still run.
p5_copy_old='''do
    retry scp "${SSH[@]}" "idex:$P5_MATRIX/$rel" "$LOCAL_EXPORT/P5/$(basename "$rel")"
done
for rel in \\
'''
p5_copy_new='''do
    if ssh "${SSH[@]}" idex "test -f '$P5_MATRIX/$rel'" >/dev/null 2>&1; then
        retry scp "${SSH[@]}" "idex:$P5_MATRIX/$rel" "$LOCAL_EXPORT/P5/$(basename "$rel")"
    fi
done
for rel in \\
'''
if src.count(p5_copy_old)!=1:
    raise SystemExit(f"ERROR: P5 export loop anchor count={src.count(p5_copy_old)}")
src=src.replace(p5_copy_old,p5_copy_new,1)

# Final Mac-side diagnostic must not reintroduce the old all-QUIC-CPUs hard
# gate. Use the authoritative DPDK lcore status and report QUIC use only.
src=src.replace(
    '"$LOCAL_EXPORT/P5/parallel_queue_activity.json"',
    '"$LOCAL_EXPORT/P5/dpdk_lcore_activity_validation.json"',
    1,
)
src=src.replace(
    "print('P5 DPDK MULTICORE QUEUE VALIDATION:',q.get('status','UNKNOWN'))",
    "print('P5 DPDK LCORE ACTIVITY:',q.get('status','UNKNOWN'))",
    1,
)
src=src.replace(
    "if q.get('status')!='PASS': raise SystemExit(1)",
    "if q.get('status')!='PASS': print('WARN: P5 DPDK lcore fairness status is not PASS; comparison is marked invalid but results are preserved')",
    1,
)
src=src.replace(
    "if j.get('status')!='PASS': raise SystemExit(1)",
    "if j.get('status')!='PASS': print('WARN: not every configured QUIC worker CPU was observed active; diagnostic only')",
    1,
)
src=src.replace(
    "print('ALL REQUESTED QUIC CPUs 21,22,23,24 HAVE RUNTIME PROCESS ACTIVITY ON BOTH ENDPOINTS')",
    "print('QUIC worker CPU activity reported above; configured set 21-24 is fixed, actual scheduler use is not a hard gate')",
    1,
)

Path(sys.argv[2]).write_text(src, encoding="utf-8")
PY
chmod 0700 "$TMP_V4"
bash -n "$TMP_V4"
grep -Fq 'GREENQUIC-V5-SAFE-CLEANUP-V1' "$TMP_V4" || { echo "ERROR: V5 transform missing" >&2; exit 2; }
grep -Fq 'run_parallel_multicore_fair.sh' "$TMP_V4" || { echo "ERROR: fair runner transform missing" >&2; exit 2; }
if grep -Fq 'pkill -TERM -f' "$TMP_V4"; then
    echo "ERROR: unsafe broad cleanup survived V5 transform" >&2
    exit 2
fi

log "starting V4 sync/detached/live-stream path with V5 fair P5+P7 orchestration"
export P5_MC_RUNS="$RUNS" P5_MC_CONNECTIONS="$CONNECTIONS" P5_MC_TAG="$TAG"
exec bash "$TMP_V4" --foreground
