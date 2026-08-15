#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$HERE/.." rev-parse --show-toplevel 2>/dev/null || true)"
BASE="$HERE/greenquic_fresh_setup_p4_p5_p6_p7.sh"
FINAL_RUNNER="$HERE/mac_run_final_selected_branch.sh"
BASTION="mohsen@coinbase"
SSH_OPTS=(-o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o StrictHostKeyChecking=accept-new)
fail(){ echo "ERROR: $*" >&2; exit 1; }
remote(){ local h="$1"; shift; ssh "${SSH_OPTS[@]}" -J "$BASTION" root@"$h" "$@"; }

usage(){ cat <<'USAGE'
Usage:
  bash tum_testbed_setup/greenquic_fresh_setup_branch.sh main
  bash tum_testbed_setup/greenquic_fresh_setup_branch.sh performance
  bash tum_testbed_setup/greenquic_fresh_setup_branch.sh performance2
Aliases: performance=performance/p5-max-goodput, performance2=performance2/p5-max-goodput
USAGE
}
[[ $# -eq 1 ]] || { usage >&2; exit 2; }
INPUT="$1"
case "$INPUT" in
  main) TARGET_BRANCH=main; TAG=main ;;
  performance|performance/p5-max-goodput) TARGET_BRANCH=performance/p5-max-goodput; TAG=performance ;;
  performance2|performance2/p5-max-goodput) TARGET_BRANCH=performance2/p5-max-goodput; TAG=performance2 ;;
  *) fail "branch must be main, performance, or performance2" ;;
esac
[[ -n "$REPO_ROOT" && -d "$REPO_ROOT/.git" ]] || fail "run from a GreenQUIC Git clone"
[[ -f "$BASE" && -f "$FINAL_RUNNER" ]] || fail "missing TUM setup/final runner"
command -v git >/dev/null; command -v ssh >/dev/null; command -v scp >/dev/null
cd "$REPO_ROOT"

git fetch origin "$TARGET_BRANCH"
TARGET_SHA="$(git rev-parse "origin/$TARGET_BRANCH")"
[[ "$TARGET_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "cannot resolve origin/$TARGET_BRANCH"
printf 'Selected branch: %s\nSelected SHA:    %s\n' "$TARGET_BRANCH" "$TARGET_SHA"

echo "=== RUNNING PRESERVED COMPLETE TUM SETUP ==="
bash "$BASE"

echo "=== DISTRIBUTING SELECTED BRANCH TO BOTH NODES ==="
STAMP="$(date +%Y%m%d_%H%M%S)"
BUNDLE="/tmp/GreenQUIC_${TAG}_${STAMP}.bundle"
REMOTE_BUNDLE="/tmp/GreenQUIC_selected_branch.bundle"
TMP_REF="refs/heads/__greenquic_setup_${STAMP}_$$"
cleanup(){ git update-ref -d "$TMP_REF" >/dev/null 2>&1 || true; rm -f "$BUNDLE"; }
trap cleanup EXIT
git update-ref "$TMP_REF" "$TARGET_SHA"
git bundle create "$BUNDLE" "$TMP_REF"
git bundle verify "$BUNDLE" >/dev/null
scp "${SSH_OPTS[@]}" -o ProxyJump="$BASTION" "$BUNDLE" root@idex:"$REMOTE_BUNDLE"
scp "${SSH_OPTS[@]}" -o ProxyJump="$BASTION" "$BUNDLE" root@tinyman:"$REMOTE_BUNDLE"

for HOST in idex tinyman; do
  remote "$HOST" bash -s -- "$TARGET_BRANCH" "$TARGET_SHA" "$REMOTE_BUNDLE" "$TMP_REF" <<'CHECKOUT'
set -Eeuo pipefail
BRANCH="$1"; SHA="$2"; BUNDLE="$3"; REF="$4"
cd /root/mohsen
git reset --hard
git fetch "$BUNDLE" "$REF"
git checkout -B "$BRANCH" FETCH_HEAD
[[ "$(git rev-parse HEAD)" == "$SHA" ]]
printf 'CHECKOUT READY host=%s branch=%s head=%s\n' "$(hostname)" "$(git branch --show-current)" "$(git rev-parse HEAD)"
CHECKOUT
  remote "$HOST" bash "/root/mohsen/tum_testbed_setup/greenquic_prepare_selected_branch_host.sh" "$TAG" "$TARGET_SHA"
done

IDEX_SHA="$(remote idex 'git -C /root/mohsen rev-parse HEAD')"
TINY_SHA="$(remote tinyman 'git -C /root/mohsen rev-parse HEAD')"
[[ "$IDEX_SHA" == "$TARGET_SHA" && "$TINY_SHA" == "$TARGET_SHA" ]] || fail "node SHA mismatch"
remote idex 'ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman true'

remote idex bash -s <<'LAUNCHERS'
set -Eeuo pipefail
cat > /root/run_p5.sh <<'P5EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
P5=/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads
cd "$P5"
exec ./run_matrix_with_sheet.sh --client-host tinyman --client-dir "$P5" --client-bin /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop "$@"
P5EOF
cat > /root/run_p7.sh <<'P7EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
P7=/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline
cd "$P7"
exec ./run_matrix_with_report.sh --client-host tinyman --client-dir "$P7" "$@"
P7EOF
chmod 700 /root/run_p5.sh /root/run_p7.sh
/root/run_p5.sh --help >/dev/null
/root/run_p7.sh --help >/dev/null
LAUNCHERS

echo "######################################################################"
echo "### BRANCH READY ON BOTH TUM NODES"
echo "### branch: $TARGET_BRANCH"
echo "### commit: $TARGET_SHA"
echo "### P5 + isolated P7: READY; NICs DPDK-bound"
echo "######################################################################"
printf '\nMAC COMMAND — FINAL 4 TESTS, 6 RUNS x 5 DOWNLOADS:\n\n'
printf 'REPO=%q; TAG="$(date +%%Y%%m%%d_%%H%%M%%S)"; LOG="$HOME/Downloads/GreenQUIC_FINAL_%s_${TAG}.log"; PIDFILE="$HOME/Downloads/GreenQUIC_FINAL_%s_${TAG}.pid"; if cd "$REPO"; then nohup caffeinate -dimsu bash tum_testbed_setup/mac_run_final_selected_branch.sh %q --runs 6 --downloads 5 >"$LOG" 2>&1 < /dev/null & PID=$!; echo "$PID" >"$PIDFILE"; disown "$PID" 2>/dev/null || true; echo "STARTED PID=$PID"; echo "LOG=$LOG"; echo "PIDFILE=$PIDFILE"; echo "You can close this Terminal."; else echo "ERROR: cannot cd to $REPO" >&2; fi\n' "$REPO_ROOT" "$TAG" "$TAG" "$INPUT"
