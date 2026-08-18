# P5 Mac cleanup and detached-run examples

This file keeps copy/paste commands for the IDEX + Tinyman P5 workflow. Run these commands from the Mac that has SSH aliases `idex` and `tinyman` and a local checkout at `~/Downloads/GreenQUIC`.

The cleanup command is a GreenQUIC P5/P7 cleanup, not a generic Linux process killer. It targets the known GreenQUIC/MsQuic runners, binaries, samplers, and their descendants, and then verifies that no matching stale process remains.

## 1. Reusable GreenQUIC cleanup

Use this before a new P5/P7 run, or after aborting one:

```bash
for h in idex tinyman; do
    echo "================ CLEANING $h ================"
    ssh "$h" '
        cd /root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads
        python3 ./safe_cleanup_p5_bottleneck_processes.py || true
        python3 ./safe_cleanup_p5_bottleneck_processes.py --check
    '
done
```

A successful final check prints:

```text
SAFE CLEANUP CHECK PASS host=<host>: no stale GreenQUIC/P5/P7 processes
```

This does not delete completed result folders.

## 2. Example: detached P5 PLUS-only strong-DVFS run from the Mac

This example:

- synchronizes the exact current `performance2/p5-multicore` branch head from the Mac to both hosts using a Git bundle;
- runs **PLUS only**;
- runs 5 repetitions;
- runs 5 sequential 8-GiB downloads per repetition;
- uses 5-s gaps and 5-s pre/post edge cooldowns;
- records power, C-state and 1-ms CPU-frequency traces;
- uses DPDK CPU 19 and QUIC CPUs 21-24;
- launches on IDEX with `nohup` + `setsid`, so the Mac may be disconnected after `REMOTE START OK`;
- creates temporary PLUS-only controller files on IDEX and removes them after the run;
- leaves the repository source files unchanged.

Strong-DVFS overrides used by this example:

```text
PRESSURE_MAX=800
PRESSURE_UP=350
PRESSURE_KEEP=150
FREQ_UP_PERIOD_US=250
FREQ_DOWN_PERIOD_US=10000
RX_BURST_RISE_ALPHA_PERMILLE=750
TX_BURST_RISE_ALPHA_PERMILLE=750
RX_BURST_FALL_ALPHA_PERMILLE=250
TX_BURST_FALL_ALPHA_PERMILLE=250
```

Copy/paste the complete block on the Mac:

```bash
(
set -e

BRANCH="performance2/p5-multicore"
LOCAL_REPO="$HOME/Downloads/GreenQUIC"
ROOT="/root/mohsen"
P5="$ROOT/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"

cd "$LOCAL_REPO"
git fetch origin "$BRANCH"
SHA="$(git rev-parse "origin/$BRANCH")"

TAG="P5_PLUS_ONLY_STRONG_$(date +%Y%m%d_%H%M%S)"
TMPREF="refs/heads/__p5_plus_only_${TAG}"
BUNDLE="/tmp/${TAG}.bundle"
REMOTE_BUNDLE="/tmp/${TAG}.bundle"

LOG="/root/${TAG}.log"
PID="/root/${TAG}.pid"
REMOTE_SCRIPT="/root/${TAG}_run.sh"
OUT="$P5/matrix_results/plus_only_strong_${TAG}"

PLUS_CORE="$P5/.${TAG}_core.sh"
PLUS_BASE="$P5/.${TAG}_from_idex.sh"
PLUS_SHEET="$P5/.${TAG}_with_sheet.sh"

cleanup_local() {
    git -C "$LOCAL_REPO" update-ref -d "$TMPREF" 2>/dev/null || true
    rm -f "$BUNDLE"
}
trap cleanup_local EXIT

echo "======================================================================"
echo "P5 PLUS ONLY — STRONG ACTIVE DVFS"
echo "branch=$BRANCH"
echo "sha=$SHA"
echo "tag=$TAG"
echo "======================================================================"

git cat-file -e "$SHA^{commit}"
git update-ref "$TMPREF" "$SHA"
git bundle create "$BUNDLE" "$TMPREF"
git bundle verify "$BUNDLE"

for h in idex tinyman; do
    echo
    echo "================ PREPARING $h ================"

    scp "$BUNDLE" "$h:$REMOTE_BUNDLE"

    ssh "$h" "
        set -e

        cd '$ROOT'
        git reset --hard
        git fetch '$REMOTE_BUNDLE' '$TMPREF'
        git checkout -B '$BRANCH' FETCH_HEAD

        ACTUAL=\$(git rev-parse HEAD)
        echo '[sync] HEAD='\$ACTUAL
        test \"\$ACTUAL\" = '$SHA'
        rm -f '$REMOTE_BUNDLE'

        cd '$P5'
        python3 ./safe_cleanup_p5_bottleneck_processes.py || true
        python3 ./safe_cleanup_p5_bottleneck_processes.py --check

        test -x '$ROOT/msquic/build-greenquic-p5/bin/Release/quicinterop'
        test -x '$ROOT/msquic/build-greenquic-p5/bin/Release/quicinteropserver'
    "
done

echo
echo "================ BUILDING TEMP PLUS-ONLY CONTROLLER ================"

ssh idex "P5='$P5' TAG='$TAG' python3 -" <<'PY'
import os
from pathlib import Path

p5 = Path(os.environ["P5"])
tag = os.environ["TAG"]

core_src = p5 / "run_matrix_from_idex_core.sh"
base_src = p5 / "run_matrix_from_idex.sh"
sheet_src = p5 / "run_matrix_with_sheet.sh"

core_dst = p5 / f".{tag}_core.sh"
base_dst = p5 / f".{tag}_from_idex.sh"
sheet_dst = p5 / f".{tag}_with_sheet.sh"

core = core_src.read_text(encoding="utf-8")

old = 'modes = ("off", "basic", "plus")'
if core.count(old) != 1:
    raise SystemExit(f"ERROR: expected one normal three-mode scheduler, found {core.count(old)}")
core = core.replace(old, 'modes = ("plus",)', 1)

old = 'TOTAL_TESTS=$((RUNS * 3))'
if core.count(old) != 1:
    raise SystemExit(f"ERROR: expected one TOTAL_TESTS expression, found {core.count(old)}")
core = core.replace(old, 'TOTAL_TESTS=$RUNS', 1)

core = core.replace('POSITION $position/3', 'POSITION $position/1')
core = core.replace('position=$position/3', 'position=$position/1')
core_dst.write_text(core, encoding="utf-8")

base = base_src.read_text(encoding="utf-8")
old = 'CORE="$HERE/run_matrix_from_idex_core.sh"'
if base.count(old) != 1:
    raise SystemExit(f"ERROR: expected one CORE assignment, found {base.count(old)}")
base = base.replace(old, f'CORE="$HERE/.{tag}_core.sh"', 1)
base_dst.write_text(base, encoding="utf-8")

sheet = sheet_src.read_text(encoding="utf-8")
old = 'BASE_RUNNER="$HERE/run_matrix_from_idex.sh"'
if sheet.count(old) != 1:
    raise SystemExit(f"ERROR: expected one BASE_RUNNER assignment, found {sheet.count(old)}")
sheet = sheet.replace(old, f'BASE_RUNNER="$HERE/.{tag}_from_idex.sh"', 1)
sheet_dst.write_text(sheet, encoding="utf-8")

print(f"PLUS core   : {core_dst}")
print(f"PLUS runner : {base_dst}")
print(f"PLUS sheet  : {sheet_dst}")
PY

ssh idex "
    chmod 700 '$PLUS_CORE' '$PLUS_BASE' '$PLUS_SHEET'
    grep -F 'modes = (\"plus\",)' '$PLUS_CORE'
    grep -F 'TOTAL_TESTS=\$RUNS' '$PLUS_CORE'
    echo 'PLUS-ONLY CONTROLLER VERIFIED'
"

echo
echo "================ INSTALLING DETACHED RUN ================"

ssh idex "cat > '$REMOTE_SCRIPT'" <<'REMOTE_RUN'
set -o pipefail

cd /root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads

bash "$PLUS_RUNNER" \
    --chart-style both \
    --client-host tinyman \
    --client-dir /root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads \
    --client-bin /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop \
    --downloads 5 \
    --gap-seconds 5 \
    --server-cooldown-seconds 5 \
    --between-tests-seconds 0 \
    --cstate-cpu 19 \
    --runs 5 \
    --mode-order balanced \
    --seed 20260806 \
    --output-dir "$P5_OUT" \
    --env ENABLE_RECORD=1 \
    --env GQ_CLAIM_DISABLE_ACTIVE_RECORDERS=0 \
    --env GQ_CLAIM_RECORDER_CPU=auto \
    --env GQ_LOG_LEVEL=0 \
    --env ENABLE_FREQ=1 \
    --env ENABLE_SLEEP=1 \
    --env ENABLE_PAUSE=1 \
    --env KEEP_PAUSE_ITERATIONS=1 \
    --env SHORT_PAUSE_ITERATIONS=1 \
    --env GQ_IDLE_MODE_OVERRIDE=monitor \
    --env GQ_IDLE_FALLBACK_OVERRIDE=short \
    --env GQ_POST_TRANSFER_WAIT_S=0 \
    --env ENABLE_MULTICORE=0 \
    --env SERVER_DPDK_LCORES=19 \
    --env CLIENT_DPDK_LCORES=19 \
    --env SERVER_TX_OWNER_LCORE=19 \
    --env CLIENT_TX_OWNER_LCORE=19 \
    --env SERVER_QUIC_CPUS=21,22,23,24 \
    --env CLIENT_QUIC_CPUS=21,22,23,24 \
    --env MSQUIC_EXECUTION_PROFILE=max_throughput \
    --env PRESSURE_MAX=800 \
    --env PRESSURE_UP=350 \
    --env PRESSURE_KEEP=150 \
    --env FREQ_UP_PERIOD_US=250 \
    --env FREQ_DOWN_PERIOD_US=10000 \
    --env RX_BURST_RISE_ALPHA_PERMILLE=750 \
    --env TX_BURST_RISE_ALPHA_PERMILLE=750 \
    --env RX_BURST_FALL_ALPHA_PERMILLE=250 \
    --env TX_BURST_FALL_ALPHA_PERMILLE=250

RC=$?

rm -f "$PLUS_CORE" "$PLUS_BASE" "$PLUS_RUNNER"

echo "P5_PLUS_ONLY_EXIT_CODE=$RC"
exit "$RC"
REMOTE_RUN

ssh idex "chmod 700 '$REMOTE_SCRIPT'"

echo
echo "================ STARTING PLUS-ONLY RUN ON IDEX ================"

ssh idex "
    set -e
    rm -f '$LOG' '$PID'

    nohup setsid env \
        P5_OUT='$OUT' \
        PLUS_RUNNER='$PLUS_SHEET' \
        PLUS_CORE='$PLUS_CORE' \
        PLUS_BASE='$PLUS_BASE' \
        bash '$REMOTE_SCRIPT' \
        >'$LOG' 2>&1 </dev/null &

    echo \$! > '$PID'
    sleep 3

    RUNPID=\$(cat '$PID')
    if kill -0 \$RUNPID 2>/dev/null; then
        echo 'REMOTE START OK'
        echo REMOTE_PID=\$RUNPID
    else
        echo 'ERROR: PLUS-only P5 died during startup'
        echo '---------------- LOG ----------------'
        cat '$LOG' || true
        exit 1
    fi
"

echo
echo "======================================================================"
echo "P5 PLUS-ONLY STARTED SUCCESSFULLY"
echo "TAG=$TAG"
echo "SHA=$SHA"
echo "PID=$PID"
echo "LOG=$LOG"
echo "RESULTS=$OUT"
echo
echo "LIVE MONITOR:"
echo "ssh idex 'tail -n +1 -F $LOG'"
echo
echo "PROCESS CHECK:"
echo "ssh idex 'ps -fp \$(cat $PID)'"
echo
echo "You can close the Mac after REMOTE START OK."
echo "======================================================================"

) || echo "P5 PLUS-ONLY LAUNCH FAILED — Mac terminal remains open"
```

The expected temporary schedule is:

```text
TEST 1/5 PLUS
TEST 2/5 PLUS
TEST 3/5 PLUS
TEST 4/5 PLUS
TEST 5/5 PLUS
```

Use the `LIVE MONITOR` command printed by the launcher for the exact tag of that run.
