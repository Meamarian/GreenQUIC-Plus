#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$HERE/.." rev-parse --show-toplevel 2>/dev/null || true)"
BASE="$HERE/greenquic_fresh_setup.sh"
PAPER_RUNNER_REL="greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_p7_fair_repro_6x5_v3.sh"
PAPER_RUNNER="$REPO_ROOT/$PAPER_RUNNER_REL"
BASTION="mohsen@coinbase"
SSH_OPTS=(-o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o StrictHostKeyChecking=accept-new)

fail(){ echo "ERROR: $*" >&2; exit 1; }
remote(){ local h="$1"; shift; ssh "${SSH_OPTS[@]}" -J "$BASTION" root@"$h" "$@"; }

usage(){ cat <<'USAGE'
Usage:
  bash tum_testbed_setup/greenquic_fresh_setup_branch.sh main
  bash tum_testbed_setup/greenquic_fresh_setup_branch.sh paper

In GreenQUIC-Plus, `main` is the final paper/reproduction code line.
`paper` is only a convenience alias for `main`.
USAGE
}

[[ $# -eq 1 ]] || { usage >&2; exit 2; }
INPUT="$1"
case "$INPUT" in
  main|paper)
    TARGET_BRANCH=main
    TAG=paper
    ;;
  *) fail "target must be main or paper" ;;
esac

[[ -n "$REPO_ROOT" && -d "$REPO_ROOT/.git" ]] || fail "run from a GreenQUIC-Plus Git clone"
[[ -f "$BASE" ]] || fail "missing hardened TUM setup entrypoint: $BASE"
[[ -f "$PAPER_RUNNER" ]] || fail "missing final paper runner: $PAPER_RUNNER"
command -v git >/dev/null || fail "git is required"
command -v ssh >/dev/null || fail "ssh is required"
command -v scp >/dev/null || fail "scp is required"

cd "$REPO_ROOT"
ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
case "$ORIGIN_URL" in
  git@github.com:Meamarian/GreenQUIC-Plus.git|https://github.com/Meamarian/GreenQUIC-Plus.git)
    ;;
  *)
    fail "origin must be Meamarian/GreenQUIC-Plus, got: ${ORIGIN_URL:-none}"
    ;;
esac

git fetch origin main
TARGET_SHA="$(git rev-parse origin/main)"
[[ "$TARGET_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "cannot resolve origin/main"

printf 'Selected repository: Meamarian/GreenQUIC-Plus\n'
printf 'Selected branch:     main\n'
printf 'Selected SHA:        %s\n' "$TARGET_SHA"
printf 'Selected role:       FINAL PAPER / CURRENT DEVELOPMENT BASE\n'

echo "=== RUNNING HARDENED COMPLETE TUM SETUP ==="
# This public entrypoint patches the preserved base setup so fresh nodes clone
# the private GreenQUIC-Plus/main repository, hardens the MSR check, and brings
# both E810 cable peers up before carrier verification.
bash "$BASE"

echo "=== DISTRIBUTING EXACT GREENQUIC-PLUS MAIN SHA TO BOTH NODES ==="
STAMP="$(date +%Y%m%d_%H%M%S)"
BUNDLE="/tmp/GreenQUIC_Plus_main_${STAMP}.bundle"
REMOTE_BUNDLE="/tmp/GreenQUIC_Plus_selected.bundle"
TMP_REF="refs/heads/__greenquic_plus_setup_${STAMP}_$$"
cleanup(){ git update-ref -d "$TMP_REF" >/dev/null 2>&1 || true; rm -f "$BUNDLE"; }
trap cleanup EXIT

git update-ref "$TMP_REF" "$TARGET_SHA"
git bundle create "$BUNDLE" "$TMP_REF"
git bundle verify "$BUNDLE" >/dev/null

scp "${SSH_OPTS[@]}" -o ProxyJump="$BASTION" "$BUNDLE" root@idex:"$REMOTE_BUNDLE"
scp "${SSH_OPTS[@]}" -o ProxyJump="$BASTION" "$BUNDLE" root@tinyman:"$REMOTE_BUNDLE"

for HOST in idex tinyman; do
  remote "$HOST" bash -s -- "$TARGET_SHA" "$REMOTE_BUNDLE" "$TMP_REF" <<'CHECKOUT'
set -Eeuo pipefail
SHA="$1"; BUNDLE="$2"; REF="$3"
cd /root/mohsen
git reset --hard
git fetch "$BUNDLE" "$REF"
git checkout -B main FETCH_HEAD
[[ "$(git rev-parse HEAD)" == "$SHA" ]]
printf 'CHECKOUT READY host=%s branch=%s head=%s\n' "$(hostname)" "$(git branch --show-current)" "$(git rev-parse HEAD)"
CHECKOUT

  remote "$HOST" bash "/root/mohsen/tum_testbed_setup/greenquic_prepare_selected_branch_host.sh" paper "$TARGET_SHA"
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
exec ./run_matrix_with_sheet.sh \
  --client-host tinyman \
  --client-dir "$P5" \
  --client-bin /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop \
  "$@"
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
echo "### GREENQUIC+ MAIN READY ON BOTH TUM NODES"
echo "### repository: Meamarian/GreenQUIC-Plus (private)"
echo "### branch: main"
echo "### commit: $TARGET_SHA"
echo "### P5: Performance2 V2, txalloc=8, txenqcounter=0, txmetazero=1, rxpipe=2, shardmask=0"
echo "### paper runtime: single DPDK owner CPU19; QUIC CPUs21-24"
echo "### P7 isolated Linux baseline: READY"
echo "### E810 test NICs: DPDK-bound"
echo "### acpi.sh dependency: sensors/lm-sensors READY"
echo "######################################################################"

printf '\nMAC COMMAND — FINAL PAPER FAIR REPRODUCTION, P5 + P7, 6 RUNS x 5 DOWNLOADS:\n\n'
printf 'cd %q && git fetch origin main && git checkout main && git reset --hard origin/main && bash %q\n' "$REPO_ROOT" "$PAPER_RUNNER_REL"

printf '\nLIVE MONITOR FROM ANOTHER MAC TERMINAL:\n\n'
cat <<'MONITOR'
ssh idex '
log=$(find /root -maxdepth 1 -type f -name "GQ_FAIR_REPRO_*.log" -printf "%T@ %p\n" 2>/dev/null | sort -nr | sed -n "1p" | cut -d" " -f2-)
echo "FOLLOWING: $log"; echo
if [ -z "$log" ]; then
    echo "No GQ_FAIR_REPRO log found yet"
else
    tail -n +1 -F "$log"
fi
'
MONITOR
