#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
STAMP="${STAMP:-$(date +%Y%m%d_%H%M%S)}"
CLIENT_HOST="${CLIENT_HOST:-tinyman}"
RESULT_ROOT="${RESULT_ROOT:-/tmp/P5_CACHE128_TXRETRY1_${STAMP}}"
MATRIX_ROOT="$HERE/matrix_results/P5_CACHE128_TXRETRY1_${STAMP}"
SUMMARY="$RESULT_ROOT/goodput_summary.tsv"
MASTER="$RESULT_ROOT/master.log"
mkdir -p "$RESULT_ROOT" "$MATRIX_ROOT"
exec > >(tee -a "$MASTER") 2>&1

clean_local() {
    for p in /proc/[0-9]*; do
        exe=$(readlink -f "$p/exe" 2>/dev/null || true)
        case "$exe" in */quicinterop|*/quicinteropserver) kill -TERM "${p##*/}" 2>/dev/null || true;; esac
    done
    sleep 1
    for p in /proc/[0-9]*; do
        exe=$(readlink -f "$p/exe" 2>/dev/null || true)
        case "$exe" in */quicinterop|*/quicinteropserver) kill -KILL "${p##*/}" 2>/dev/null || true;; esac
    done
    sleep 1
    if ! fuser /var/run/dpdk/rte/config >/dev/null 2>&1; then rm -rf /var/run/dpdk/rte; fi
}

clean_remote() {
    ssh -n root@"$CLIENT_HOST" 'bash -s' <<'CLEAN'
for p in /proc/[0-9]*; do
    exe=$(readlink -f "$p/exe" 2>/dev/null || true)
    case "$exe" in */quicinterop|*/quicinteropserver) kill -TERM "${p##*/}" 2>/dev/null || true;; esac
done
sleep 1
for p in /proc/[0-9]*; do
    exe=$(readlink -f "$p/exe" 2>/dev/null || true)
    case "$exe" in */quicinterop|*/quicinteropserver) kill -KILL "${p##*/}" 2>/dev/null || true;; esac
done
sleep 1
if ! fuser /var/run/dpdk/rte/config >/dev/null 2>&1; then rm -rf /var/run/dpdk/rte; fi
CLEAN
}

restore_native() {
    echo
    echo "RESTORING NATIVE BINARIES ON BOTH HOSTS"
    (cd "$HERE" && P5_STATIC_PROFILE=native P5_BUILD_REUSE=1 bash ./build_p5_client.sh >"$RESULT_ROOT/restore_idex.log" 2>&1) &
    p1=$!
    ssh -n root@"$CLIENT_HOST" "cd '$HERE' && P5_STATIC_PROFILE=native P5_BUILD_REUSE=1 bash ./build_p5_client.sh" >"$RESULT_ROOT/restore_tinyman.log" 2>&1 &
    p2=$!
    r1=0; r2=0
    wait "$p1" || r1=$?
    wait "$p2" || r2=$?
    echo "NATIVE RESTORE RC: idex=$r1 tinyman=$r2"
}

on_exit() {
    rc=$?
    trap - EXIT INT TERM
    restore_native || true
    exit "$rc"
}
trap on_exit EXIT INT TERM

echo "======================================================================"
echo "P5 ISOLATED FEATURE TEST"
echo "BASE: cache128 (best common result from previous sweep)"
echo "ONLY NEW FEATURE: one immediate TX retry after a partial TX burst"
echo "UDP checksum: unchanged/off"
echo "Perf counters: off"
echo "Forced lock-free: off"
echo "Runtime performance hooks: none"
echo "GreenQUIC/GreenQUIC+: unchanged"
echo "Workload: 3 downloads per mode, 5 s gaps, old charts, log level 0"
echo "======================================================================"

clean_local
clean_remote

echo
echo "BUILD cache128 + txretry1 on idex + tinyman"
(cd "$HERE" && P5_BUILD_REUSE=1 bash ./build_p5_cache128_txretry1.sh >"$RESULT_ROOT/build_idex.log" 2>&1) &
p1=$!
ssh -n root@"$CLIENT_HOST" "cd '$HERE' && P5_BUILD_REUSE=1 bash ./build_p5_cache128_txretry1.sh" >"$RESULT_ROOT/build_tinyman.log" 2>&1 &
p2=$!
r1=0; r2=0
wait "$p1" || r1=$?
wait "$p2" || r2=$?
if (( r1 != 0 || r2 != 0 )); then
    echo "BUILD FAILED idex=$r1 tinyman=$r2"
    echo "IDEX:"; tail -80 "$RESULT_ROOT/build_idex.log" || true
    echo "TINYMAN:"; tail -80 "$RESULT_ROOT/build_tinyman.log" || true
    exit 20
fi

echo "BUILD PASS ON BOTH HOSTS"
grep -E 'P5 experiment build:|P5 isolated feature:|P5 isolated experiment build PASS|BASE:|FEATURE:' "$RESULT_ROOT/build_idex.log" || true

clean_local
clean_remote

echo
echo "RUNNING OFF / BASIC / PLUS"
set +e
bash "$HERE/run_matrix_with_sheet.sh" \
    --chart-style old \
    --client-host "$CLIENT_HOST" \
    --client-dir "$HERE" \
    --client-bin /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop \
    --downloads 3 \
    --gap-seconds 5 \
    --server-cooldown-seconds 5 \
    --between-tests-seconds 0 \
    --cstate-cpu 19 \
    --runs 1 \
    --mode-order balanced \
    --seed 20260813 \
    --output-dir "$MATRIX_ROOT" \
    --env ENABLE_RECORD=1 \
    --env GQ_LOG_LEVEL=0 \
    --env GQ_IDLE_MODE_OVERRIDE=monitor \
    --env GQ_IDLE_FALLBACK_OVERRIDE=short \
    >"$RESULT_ROOT/run.log" 2>&1
RUN_RC=$?
set -e

python3 - "$RESULT_ROOT/run.log" "$SUMMARY" "$RUN_RC" <<'PY'
import re, sys
from pathlib import Path
log, out, rc = sys.argv[1:]
text = Path(log).read_text(errors="replace")
results = {}
for line in text.splitlines():
    m = re.search(r"\[MODE=(off|basic|plus)\].*?Aggregate goodput excluding gaps:\s*([0-9.]+)\s*Gbit/s", line, re.I)
    if m:
        results[m.group(1).lower()] = float(m.group(2))
with open(out, "w") as f:
    f.write("profile\tmode\tgoodput_gbps\trc\n")
    for mode in ("off", "basic", "plus"):
        value = results.get(mode)
        f.write(f"cache128_txretry1\t{mode}\t{'NA' if value is None else f'{value:.6f}'}\t{rc}\n")
print()
print("============================================================")
print("CACHE128 + TX RETRY1 GOODPUT — EXCLUDING GAPS")
print("============================================================")
for mode in ("off", "basic", "plus"):
    value = results.get(mode)
    if value is None:
        print(f"{mode.upper():5s}: NA")
    else:
        print(f"{mode.upper():5s}: {value:.6f} Gbit/s")
print("============================================================")
PY

echo
echo "PREVIOUS CACHE128 CONTROL FOR COMPARISON"
echo "OFF   8.956036 Gbit/s"
echo "BASIC 8.813568 Gbit/s"
echo "PLUS  9.743661 Gbit/s"
echo
echo "RUN RC=$RUN_RC"
echo "SUMMARY=$SUMMARY"
echo "MASTER=$MASTER"
echo "RUNLOG=$RESULT_ROOT/run.log"
echo "MATRIX_ROOT=$MATRIX_ROOT"

if (( RUN_RC != 0 )); then
    tail -100 "$RESULT_ROOT/run.log" || true
    exit "$RUN_RC"
fi
