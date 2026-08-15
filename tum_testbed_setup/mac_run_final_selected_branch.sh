#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$HERE/.." rev-parse --show-toplevel 2>/dev/null || true)"
BASTION="mohsen@coinbase"
SSH_OPTS=(-o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o StrictHostKeyChecking=accept-new)
RUNS=6
DOWNLOADS=5
SEED="${P5_FINAL_SEED:-20260806}"

fail(){ echo "ERROR: $*" >&2; exit 1; }
remote(){ local host="$1"; shift; ssh "${SSH_OPTS[@]}" -J "$BASTION" root@"$host" "$@"; }

usage() {
    cat <<'USAGE'
Usage:
  bash tum_testbed_setup/mac_run_final_selected_branch.sh <main|performance|performance2> [--runs N] [--downloads N]
USAGE
}

[[ $# -ge 1 ]] || { usage >&2; exit 2; }
INPUT="$1"; shift
case "$INPUT" in
    main) TARGET_BRANCH="main"; BRANCH_TAG="main" ;;
    performance|performance/p5-max-goodput)
        TARGET_BRANCH="performance/p5-max-goodput"; BRANCH_TAG="performance" ;;
    performance2|performance2/p5-max-goodput)
        TARGET_BRANCH="performance2/p5-max-goodput"; BRANCH_TAG="performance2" ;;
    *) fail "branch must be main, performance, or performance2" ;;
esac
while (($#)); do
    case "$1" in
        --runs) RUNS="${2:?missing value}"; shift 2 ;;
        --downloads) DOWNLOADS="${2:?missing value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown argument: $1" ;;
    esac
done
[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || fail "runs must be positive"
[[ "$DOWNLOADS" =~ ^[1-9][0-9]*$ ]] || fail "downloads must be positive"
[[ -n "$REPO_ROOT" && -d "$REPO_ROOT/.git" ]] || fail "run from a GreenQUIC Git clone"
command -v ssh >/dev/null || fail "ssh is required"
command -v scp >/dev/null || fail "scp is required"

cd "$REPO_ROOT"
git fetch origin "$TARGET_BRANCH"
EXPECTED="$(git rev-parse "origin/$TARGET_BRANCH")"
[[ "$EXPECTED" =~ ^[0-9a-f]{40}$ ]] || fail "cannot resolve origin/$TARGET_BRANCH"

IDEX_SHA="$(remote idex 'git -C /root/mohsen rev-parse HEAD 2>/dev/null || true')"
TINY_SHA="$(remote tinyman 'git -C /root/mohsen rev-parse HEAD 2>/dev/null || true')"
[[ "$IDEX_SHA" == "$EXPECTED" ]] || fail "IDEX HEAD=$IDEX_SHA, expected=$EXPECTED; rerun branch-aware TUM setup"
[[ "$TINY_SHA" == "$EXPECTED" ]] || fail "Tinyman HEAD=$TINY_SHA, expected=$EXPECTED; rerun branch-aware TUM setup"
remote idex 'ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman true'

verify_binary() {
    local host="$1"
    remote "$host" bash -s -- "$BRANCH_TAG" <<'VERIFY'
set -Eeuo pipefail
KIND="$1"
ROOT=/root/mohsen
P5="$ROOT/msquic/build-greenquic-p5/bin/Release/quicinterop"
P5S="$ROOT/msquic/build-greenquic-p5/bin/Release/quicinteropserver"
P7="$ROOT/msquic/build-linux-p7/bin/Release/quicinterop"
test -x "$P5"; test -x "$P5S"; test -x "$P7"
grep -aFq -- 'GreenQUIC-P5-SEQUENCE-V2' "$P5"
case "$KIND" in
  main)
    ! grep -aFq -- 'GREENQUIC-P5-SUPER-PERF-V2' "$P5"
    ;;
  performance)
    grep -aFq -- 'GREENQUIC-P5-SUPER-PERF-V2' "$P5"
    ! grep -aFq -- 'GREENQUIC-P5-PERFORMANCE2-V1' "$P5"
    ;;
  performance2)
    grep -aFq -- 'GREENQUIC-P5-SUPER-PERF-V2' "$P5"
    grep -aFq -- 'GREENQUIC-P5-PERFORMANCE2-V1' "$P5"
    ;;
esac
DRIVER="$(basename "$(readlink -f /sys/bus/pci/devices/0000:18:00.0/driver 2>/dev/null || true)")"
case "$DRIVER" in igb_uio|vfio-pci) ;; *) echo "ERROR: NIC driver=${DRIVER:-none}" >&2; exit 3;; esac
command -v zip >/dev/null
echo "VERIFY PASS host=$(hostname) kind=$KIND driver=$DRIVER"
VERIFY
}
verify_binary idex
verify_binary tinyman
remote idex 'test -x /root/run_p7.sh && test -x /root/run_p5.sh'

TAG="$(date +%Y%m%d_%H%M%S)"
P5="/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
P7="/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline"
P5_MON="$P5/matrix_results/${BRANCH_TAG}_idle_monitor_normal_${TAG}"
P5_PWR="$P5/matrix_results/${BRANCH_TAG}_main_power_friendly_${TAG}"
P5_SHORT="$P5/matrix_results/${BRANCH_TAG}_main_normal_short_8GiB_${TAG}"
P7_OUT="$P7/matrix_results/${BRANCH_TAG}_P7_MAIN_linux_${RUNS}runs_${TAG}"
P7_LOG="/root/${BRANCH_TAG}_P7_MAIN_${TAG}.log"
EXPORT_REMOTE="/tmp/GreenQUIC_FINAL_${BRANCH_TAG}_${TAG}"
EXPORT_LOCAL="$HOME/Downloads/GreenQUIC_FINAL_${BRANCH_TAG}_${TAG}"

printf '%s\n' \
  "======================================================================" \
  "FINAL SELECTED-BRANCH SUITE" \
  "branch=$TARGET_BRANCH" \
  "commit=$EXPECTED" \
  "P5 profiles=3 runs=$RUNS downloads=$DOWNLOADS" \
  "P7 runs=$RUNS downloads=$DOWNLOADS" \
  "All test attempts finish before ZIP/SCP." \
  "======================================================================"

set +e
remote idex bash -s -- "$P5" "$P7" "$P5_MON" "$P5_PWR" "$P5_SHORT" "$P7_OUT" "$P7_LOG" "$RUNS" "$DOWNLOADS" "$SEED" <<'RUN_SUITE'
set -u
P5="$1"; P7="$2"; P5_MON="$3"; P5_PWR="$4"; P5_SHORT="$5"; P7_OUT="$6"; P7_LOG="$7"; RUNS="$8"; DOWNLOADS="$9"; SEED="${10}"

run_p5() {
    local output="$1"; shift
    cd "$P5" || return 90
    bash ./run_matrix_with_sheet.sh \
        --chart-style both \
        --client-host tinyman \
        --client-dir "$P5" \
        --client-bin /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop \
        --downloads "$DOWNLOADS" \
        --gap-seconds 5 \
        --server-cooldown-seconds 5 \
        --between-tests-seconds 0 \
        --cstate-cpu 19 \
        --runs "$RUNS" \
        --mode-order balanced \
        --seed "$SEED" \
        --output-dir "$output" \
        --env ENABLE_RECORD=1 \
        --env GQ_LOG_LEVEL=0 \
        "$@"
}

echo "=== 1/4 P5 IDLE_MONITOR_NORMAL ==="
run_p5 "$P5_MON" --env GQ_IDLE_MODE_OVERRIDE=monitor --env GQ_IDLE_FALLBACK_OVERRIDE=short
RC1=$?
echo "P5 IDLE_MONITOR_NORMAL RC=$RC1"

echo "=== 2/4 P5 POWER_FRIENDLY ==="
run_p5 "$P5_PWR" --env ENABLE_FREQ=1 --env ENABLE_SLEEP=1 --env GQ_IDLE_MODE_OVERRIDE=epoll --env GQ_IDLE_FALLBACK_OVERRIDE=short
RC2=$?
echo "P5 POWER_FRIENDLY RC=$RC2"

echo "=== 3/4 P5 NORMAL_SHORT_8GiB ==="
run_p5 "$P5_SHORT" --env GQ_IDLE_MODE_OVERRIDE=short --env GQ_IDLE_FALLBACK_OVERRIDE=short --env REQUEST_PATH=/file_8G.bin --env PAYLOAD_BYTES=8589934592
RC3=$?
echo "P5 NORMAL_SHORT_8GiB RC=$RC3"

echo "=== 4/4 P7 LINUX UDP BASELINE ==="
/root/run_p7.sh \
    --chart-style both \
    --log-level 0 \
    --downloads "$DOWNLOADS" \
    --gap-seconds 5 \
    --runs "$RUNS" \
    --pre-cooldown-seconds 5 \
    --post-cooldown-seconds 5 \
    --between-runs-seconds 5 \
    --dataplane-cpu 19 \
    --quic-cpus 21,22,23,24 \
    --pin-irq 1 \
    --pin-quic 1 \
    --disable-rps 1 \
    --nic-offloads native \
    --record-quic-cpus 0 \
    --enable-record 1 \
    --rapl-interval-ms 6 \
    --freq-interval-ms 1 \
    --require-rapl 1 \
    --stop-irqbalance 1 \
    --mtu 1500 \
    --output-dir "$P7_OUT" \
    2>&1 | tee "$P7_LOG"
RC4=${PIPESTATUS[0]}
echo "P7 LINUX RC=$RC4"
echo "TEST_RC P5_MONITOR=$RC1 P5_POWER=$RC2 P5_SHORT=$RC3 P7_LINUX=$RC4"
printf '%s %s %s %s\n' "$RC1" "$RC2" "$RC3" "$RC4" > /tmp/greenquic_selected_final_rc.txt
exit 0
RUN_SUITE
SUITE_WRAPPER_RC=$?
set -e

echo "======================================================================"
echo "ALL TEST ATTEMPTS FINISHED — ZIP STAGE"
echo "======================================================================"
remote idex bash -s -- "$P5_MON" "$P5_PWR" "$P5_SHORT" "$P7_OUT" "$P7_LOG" "$EXPORT_REMOTE" "$TARGET_BRANCH" "$EXPECTED" <<'ZIP_RESULTS'
set -Eeuo pipefail
P5_MON="$1"; P5_PWR="$2"; P5_SHORT="$3"; P7_OUT="$4"; P7_LOG="$5"; EXPORT="$6"; BRANCH="$7"; SHA="$8"
mkdir -p "$EXPORT"
zip_one() {
    local src="$1"
    if [[ ! -d "$src" ]]; then echo "WARNING: missing result folder: $src"; return 0; fi
    local parent base
    parent="$(dirname "$src")"; base="$(basename "$src")"
    (cd "$parent" && zip -qr "$EXPORT/${base}.zip" "$base")
    echo "CREATED $EXPORT/${base}.zip"
}
zip_one "$P5_MON"
zip_one "$P5_PWR"
zip_one "$P5_SHORT"
zip_one "$P7_OUT"
if [[ -f "$P7_LOG" ]]; then cp "$P7_LOG" "$EXPORT/"; fi
cp /tmp/greenquic_selected_final_rc.txt "$EXPORT/test_rc.txt" 2>/dev/null || true
printf 'branch=%s\ncommit=%s\nP5_MON=%s\nP5_PWR=%s\nP5_SHORT=%s\nP7=%s\n' "$BRANCH" "$SHA" "$P5_MON" "$P5_PWR" "$P5_SHORT" "$P7_OUT" > "$EXPORT/source_paths.txt"
ls -lh "$EXPORT"
ZIP_RESULTS

echo "======================================================================"
echo "SCP ZIP EXPORT TO MAC DOWNLOADS"
echo "======================================================================"
mkdir -p "$HOME/Downloads"
rm -rf "$EXPORT_LOCAL"
scp "${SSH_OPTS[@]}" -o ProxyJump="$BASTION" -r root@idex:"$EXPORT_REMOTE" "$HOME/Downloads/"
[[ -d "$EXPORT_LOCAL" ]] || fail "Mac export folder not created: $EXPORT_LOCAL"

RC_LINE="$(cat "$EXPORT_LOCAL/test_rc.txt" 2>/dev/null || echo 'NA NA NA NA')"
echo "======================================================================"
echo "DONE"
echo "Mac export: $EXPORT_LOCAL"
echo "TEST RCs: $RC_LINE"
echo "suite wrapper rc=$SUITE_WRAPPER_RC"
echo "8 GiB PAYLOAD_BYTES=8589934592"
echo "======================================================================"

read -r RC1 RC2 RC3 RC4 <<< "$RC_LINE"
if [[ "$RC1" =~ ^[0-9]+$ && "$RC2" =~ ^[0-9]+$ && "$RC3" =~ ^[0-9]+$ && "$RC4" =~ ^[0-9]+$ ]]; then
    if (( RC1 != 0 || RC2 != 0 || RC3 != 0 || RC4 != 0 )); then
        exit 1
    fi
else
    exit 1
fi
