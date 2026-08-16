#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$HERE/.." rev-parse --show-toplevel 2>/dev/null || true)"
BASTION="mohsen@coinbase"
SSH_OPTS=(-o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o StrictHostKeyChecking=accept-new)
RUNS=6
DOWNLOADS=5
SEED="${P5_FINAL_SEED:-20260806}"
LOCAL_LOCK="$HOME/Downloads/.greenquic_final_selected.lock"

fail(){ echo "ERROR: $*" >&2; exit 1; }
remote(){ local host="$1"; shift; ssh "${SSH_OPTS[@]}" -J "$BASTION" root@"$host" "$@"; }
usage(){ cat <<'USAGE'
Usage:
  bash tum_testbed_setup/mac_run_final_selected_branch.sh <main|performance|performance2> [--runs N] [--downloads N]
USAGE
}

[[ $# -ge 1 ]] || { usage >&2; exit 2; }
INPUT="$1"; shift
case "$INPUT" in
  main) TARGET_BRANCH=main; BRANCH_TAG=main ;;
  performance|performance/p5-max-goodput) TARGET_BRANCH=performance/p5-max-goodput; BRANCH_TAG=performance ;;
  performance2|performance2/p5-max-goodput) TARGET_BRANCH=performance2/p5-max-goodput; BRANCH_TAG=performance2 ;;
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
command -v shasum >/dev/null || fail "shasum is required"

if [[ -d "$LOCAL_LOCK" ]]; then
  old="$(cat "$LOCAL_LOCK/pid" 2>/dev/null || true)"
  if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then fail "another final runner is alive PID=$old"; fi
  rm -rf "$LOCAL_LOCK"
fi
mkdir -p "$LOCAL_LOCK"; echo $$ > "$LOCAL_LOCK/pid"
REMOTE_SCRIPT_LOCAL=""
cleanup(){ rm -rf "$LOCAL_LOCK"; [[ -z "$REMOTE_SCRIPT_LOCAL" ]] || rm -f "$REMOTE_SCRIPT_LOCAL"; }
trap cleanup EXIT INT TERM

cd "$REPO_ROOT"
git fetch origin "$TARGET_BRANCH"
EXPECTED="$(git rev-parse "origin/$TARGET_BRANCH")"
[[ "$EXPECTED" =~ ^[0-9a-f]{40}$ ]] || fail "cannot resolve origin/$TARGET_BRANCH"
[[ "$(remote idex 'git -C /root/mohsen rev-parse HEAD 2>/dev/null || true')" == "$EXPECTED" ]] || fail "IDEX is not on expected selected SHA"
[[ "$(remote tinyman 'git -C /root/mohsen rev-parse HEAD 2>/dev/null || true')" == "$EXPECTED" ]] || fail "Tinyman is not on expected selected SHA"
remote idex 'ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman true'

verify_binary(){
  local host="$1"
  remote "$host" bash -s -- "$BRANCH_TAG" <<'VERIFY'
set -Eeuo pipefail
KIND="$1"; ROOT=/root/mohsen
P5="$ROOT/msquic/build-greenquic-p5/bin/Release/quicinterop"
P5S="$ROOT/msquic/build-greenquic-p5/bin/Release/quicinteropserver"
P7="$ROOT/msquic/build-linux-p7/bin/Release/quicinterop"
test -x "$P5"; test -x "$P5S"; test -x "$P7"; test -x "$ROOT/acpi.sh"
command -v sensors >/dev/null; command -v zip >/dev/null
python3 -c 'import matplotlib, numpy'
grep -aFq -- 'GreenQUIC-P5-SEQUENCE-V2' "$P5"
case "$KIND" in
  main) ! grep -aFq -- 'GREENQUIC-P5-SUPER-PERF-V2' "$P5" ;;
  performance)
    grep -aFq -- 'GREENQUIC-P5-SUPER-PERF-V2' "$P5"
    ! grep -aFq -- 'GREENQUIC-P5-PERFORMANCE2-V1' "$P5"
    ! grep -aFq -- 'GREENQUIC-P5-PERFORMANCE2-V2' "$P5"
    ;;
  performance2)
    grep -aFq -- 'GREENQUIC-P5-SUPER-PERF-V2' "$P5"
    grep -aFq -- 'GREENQUIC-P5-PERFORMANCE2-V1' "$P5"
    grep -aFq -- 'GREENQUIC-P5-PERFORMANCE2-V2' "$P5"
    ;;
esac
DRIVER="$(basename "$(readlink -f /sys/bus/pci/devices/0000:18:00.0/driver 2>/dev/null || true)")"
case "$DRIVER" in igb_uio|vfio-pci) ;; *) echo "ERROR: NIC driver=${DRIVER:-none}" >&2; exit 3;; esac
echo "VERIFY PASS host=$(hostname) kind=$KIND driver=$DRIVER sensors=$(command -v sensors)"
VERIFY
}
verify_binary idex
verify_binary tinyman
remote idex 'test -x /root/run_p5.sh && test -x /root/run_p7.sh'

TAG="$(date +%Y%m%d_%H%M%S)"
REMOTE_SCRIPT_LOCAL="${TMPDIR:-/tmp}/GreenQUIC_FINAL_${BRANCH_TAG}_${TAG}_$$.sh"
REMOTE_SCRIPT="/tmp/GreenQUIC_FINAL_${BRANCH_TAG}_${TAG}.sh"
REMOTE_LOG="/root/GreenQUIC_FINAL_${BRANCH_TAG}_${TAG}.remote.log"
REMOTE_PID="/tmp/GreenQUIC_FINAL_${BRANCH_TAG}_${TAG}.pid"
EXPORT_REMOTE="/tmp/GreenQUIC_FINAL_${BRANCH_TAG}_${TAG}"
EXPORT_LOCAL="$HOME/Downloads/GreenQUIC_FINAL_${BRANCH_TAG}_${TAG}"

cat > "$REMOTE_SCRIPT_LOCAL" <<'REMOTE'
#!/usr/bin/env bash
set +e
BT="$1"; TB="$2"; SHA="$3"; RUNS="$4"; DOWNLOADS="$5"; SEED="$6"; TAG="$7"; SELF_LOG="$8"
P5=/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads
P7=/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline
MON="$P5/matrix_results/${BT}_idle_monitor_normal_${TAG}"
PWR="$P5/matrix_results/${BT}_main_power_friendly_${TAG}"
SHORT="$P5/matrix_results/${BT}_main_normal_short_8GiB_${TAG}"
P7OUT="$P7/matrix_results/${BT}_P7_MAIN_linux_${RUNS}runs_${TAG}"
P7LOG="/root/${BT}_P7_MAIN_${TAG}.log"
EX="/tmp/GreenQUIC_FINAL_${BT}_${TAG}"
rm -rf "$EX"; mkdir -p "$EX"
run_p5(){ local out="$1"; shift; cd "$P5" || return 90; bash ./run_matrix_with_sheet.sh --chart-style both --client-host tinyman --client-dir "$P5" --client-bin /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop --downloads "$DOWNLOADS" --gap-seconds 5 --server-cooldown-seconds 5 --between-tests-seconds 0 --cstate-cpu 19 --runs "$RUNS" --mode-order balanced --seed "$SEED" --output-dir "$out" --env ENABLE_RECORD=1 --env GQ_LOG_LEVEL=0 "$@"; }
echo '=== 1/4 P5 IDLE_MONITOR_NORMAL ==='; run_p5 "$MON" --env GQ_IDLE_MODE_OVERRIDE=monitor --env GQ_IDLE_FALLBACK_OVERRIDE=short; RC1=$?
echo "P5 IDLE_MONITOR_NORMAL RC=$RC1"
echo '=== 2/4 P5 POWER_FRIENDLY ==='; run_p5 "$PWR" --env ENABLE_FREQ=1 --env ENABLE_SLEEP=1 --env GQ_IDLE_MODE_OVERRIDE=epoll --env GQ_IDLE_FALLBACK_OVERRIDE=short; RC2=$?
echo "P5 POWER_FRIENDLY RC=$RC2"
echo '=== 3/4 P5 NORMAL_SHORT_8GiB ==='; run_p5 "$SHORT" --env GQ_IDLE_MODE_OVERRIDE=short --env GQ_IDLE_FALLBACK_OVERRIDE=short --env REQUEST_PATH=/file_8G.bin --env PAYLOAD_BYTES=8589934592; RC3=$?
echo "P5 NORMAL_SHORT_8GiB RC=$RC3"
echo '=== 4/4 P7 LINUX UDP BASELINE ==='
/root/run_p7.sh --chart-style both --log-level 0 --downloads "$DOWNLOADS" --gap-seconds 5 --runs "$RUNS" --pre-cooldown-seconds 5 --post-cooldown-seconds 5 --between-runs-seconds 5 --dataplane-cpu 19 --quic-cpus 21,22,23,24 --pin-irq 1 --pin-quic 1 --disable-rps 1 --nic-offloads native --record-quic-cpus 0 --enable-record 1 --rapl-interval-ms 6 --freq-interval-ms 1 --require-rapl 1 --stop-irqbalance 1 --mtu 1500 --output-dir "$P7OUT" 2>&1 | tee "$P7LOG"
RC4=${PIPESTATUS[0]}; echo "P7 LINUX RC=$RC4"
printf '%s %s %s %s\n' "$RC1" "$RC2" "$RC3" "$RC4" > "$EX/test_rc.txt"
printf 'branch=%s\ncommit=%s\nP5_MON=%s\nP5_PWR=%s\nP5_SHORT=%s\nP7=%s\n' "$TB" "$SHA" "$MON" "$PWR" "$SHORT" "$P7OUT" > "$EX/source_paths.txt"
cp -f "$SELF_LOG" "$EX/remote.log" 2>/dev/null || true
[ -f "$P7LOG" ] && cp -f "$P7LOG" "$EX/" || true
zip_one(){ local src="$1"; [ -d "$src" ] || return 0; (cd "$(dirname "$src")" && zip -qr "$EX/$(basename "$src").zip" "$(basename "$src")"); }
zip_one "$MON"; zip_one "$PWR"; zip_one "$SHORT"; zip_one "$P7OUT"
printf 'REMOTE_WRAPPER_RC=0\n' > "$EX/result_rc.txt"
cd "$EX" || exit 91
rm -f SHA256SUMS SHA256SUMS.tmp DONE EXPORT_FAILED
find . -maxdepth 1 -type f ! -name SHA256SUMS ! -name SHA256SUMS.tmp ! -name DONE ! -name EXPORT_FAILED -print0 | sort -z | xargs -0 -r sha256sum > SHA256SUMS.tmp
MRC=$?; if [ "$MRC" -ne 0 ]; then printf 'MANIFEST_RC=%s\n' "$MRC" > EXPORT_FAILED; exit 92; fi
mv SHA256SUMS.tmp SHA256SUMS
sha256sum -c SHA256SUMS >/dev/null 2>&1; VRC=$?
if [ "$VRC" -ne 0 ]; then printf 'VERIFY_RC=%s\n' "$VRC" > EXPORT_FAILED; exit 93; fi
date -Is > DONE
REMOTE
bash -n "$REMOTE_SCRIPT_LOCAL"

while ! scp "${SSH_OPTS[@]}" -o ProxyJump="$BASTION" "$REMOTE_SCRIPT_LOCAL" root@idex:"$REMOTE_SCRIPT"; do echo "SCP transport/setup failed; retrying in 30 s"; sleep 30; done
remote idex "chmod +x '$REMOTE_SCRIPT'; nohup setsid bash '$REMOTE_SCRIPT' '$BRANCH_TAG' '$TARGET_BRANCH' '$EXPECTED' '$RUNS' '$DOWNLOADS' '$SEED' '$TAG' '$REMOTE_LOG' >'$REMOTE_LOG' 2>&1 </dev/null & echo \$! > '$REMOTE_PID'; echo REMOTE_PID=\$(cat '$REMOTE_PID')"

echo "FINAL suite detached on IDEX: branch=$TARGET_BRANCH commit=$EXPECTED log=$REMOTE_LOG"
while true; do
  if remote idex "test -f '$EXPORT_REMOTE/DONE'" >/dev/null 2>&1; then break; fi
  if remote idex "test -f '$EXPORT_REMOTE/EXPORT_FAILED'" >/dev/null 2>&1; then remote idex "cat '$EXPORT_REMOTE/EXPORT_FAILED'; tail -100 '$REMOTE_LOG'" >&2 || true; exit 92; fi
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] waiting; temporary Mac->IDEX SSH loss cannot kill remote job"
  sleep 60
done

mkdir -p "$EXPORT_LOCAL"
while ! scp "${SSH_OPTS[@]}" -o ProxyJump="$BASTION" root@idex:"$EXPORT_REMOTE/SHA256SUMS" "$EXPORT_LOCAL/SHA256SUMS"; do echo "manifest SCP failed; retrying in 30 s"; sleep 30; done
while read -r hash file; do
  [[ -n "${file:-}" ]] || continue
  rel="${file#./}"
  if [[ -f "$EXPORT_LOCAL/$rel" ]] && printf '%s  %s\n' "$hash" "$rel" | (cd "$EXPORT_LOCAL" && shasum -a 256 -c - >/dev/null 2>&1); then echo "already verified $rel"; continue; fi
  while true; do
    rm -f "$EXPORT_LOCAL/$rel.part"; echo "copying $rel"
    if scp "${SSH_OPTS[@]}" -o ProxyJump="$BASTION" root@idex:"$EXPORT_REMOTE/$rel" "$EXPORT_LOCAL/$rel.part"; then
      got="$(shasum -a 256 "$EXPORT_LOCAL/$rel.part" | awk '{print $1}')"
      if [[ "$got" == "$hash" ]]; then mv "$EXPORT_LOCAL/$rel.part" "$EXPORT_LOCAL/$rel"; echo "verified $rel"; break; fi
    fi
    echo "SCP/hash failed for $rel; retrying in 60 s"; sleep 60
  done
done < "$EXPORT_LOCAL/SHA256SUMS"
(cd "$EXPORT_LOCAL" && shasum -a 256 -c SHA256SUMS)
date "+%Y-%m-%dT%H:%M:%S%z" > "$EXPORT_LOCAL/SCP_DONE"
RC_LINE="$(cat "$EXPORT_LOCAL/test_rc.txt" 2>/dev/null || echo 'NA NA NA NA')"
echo "DONE + SHA256 VERIFIED: $EXPORT_LOCAL"
echo "TEST RCs: $RC_LINE"
read -r RC1 RC2 RC3 RC4 <<< "$RC_LINE"
if [[ "$RC1" =~ ^[0-9]+$ && "$RC2" =~ ^[0-9]+$ && "$RC3" =~ ^[0-9]+$ && "$RC4" =~ ^[0-9]+$ ]] && (( RC1 == 0 && RC2 == 0 && RC3 == 0 && RC4 == 0 )); then exit 0; fi
exit 1
