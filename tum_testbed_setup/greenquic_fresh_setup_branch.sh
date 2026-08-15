#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$HERE/.." rev-parse --show-toplevel 2>/dev/null || true)"
BASE="$HERE/greenquic_fresh_setup_p4_p5_p6_p7.sh"
FINAL_RUNNER="$HERE/mac_run_final_selected_branch.sh"
BASTION="mohsen@coinbase"
REMOTE_BUNDLE="/tmp/GreenQUIC_branch_ready.bundle"
SSH_OPTS=(-o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o StrictHostKeyChecking=accept-new)

fail(){ echo "ERROR: $*" >&2; exit 1; }
remote(){ local host="$1"; shift; ssh "${SSH_OPTS[@]}" -J "$BASTION" root@"$host" "$@"; }

usage() {
    cat <<'USAGE'
Usage:
  bash tum_testbed_setup/greenquic_fresh_setup_branch.sh main
  bash tum_testbed_setup/greenquic_fresh_setup_branch.sh performance
  bash tum_testbed_setup/greenquic_fresh_setup_branch.sh performance2

Accepted aliases:
  main         -> main
  performance  -> performance/p5-max-goodput
  performance2 -> performance2/p5-max-goodput

The established TUM setup scripts are not modified. This wrapper first runs the
existing complete setup, then switches both nodes to the selected branch and
rebuilds/verifies the branch-specific P5 plus isolated P7 binaries.
USAGE
}

[[ $# -eq 1 ]] || { usage >&2; exit 2; }
INPUT="$1"
case "$INPUT" in
    main) TARGET_BRANCH="main"; BRANCH_TAG="main" ;;
    performance|performance/p5-max-goodput)
        TARGET_BRANCH="performance/p5-max-goodput"; BRANCH_TAG="performance" ;;
    performance2|performance2/p5-max-goodput)
        TARGET_BRANCH="performance2/p5-max-goodput"; BRANCH_TAG="performance2" ;;
    *) fail "branch must be main, performance, or performance2" ;;
esac

[[ -n "$REPO_ROOT" && -d "$REPO_ROOT/.git" ]] || fail "run this from a GreenQUIC Git clone"
[[ -f "$BASE" ]] || fail "missing preserved TUM setup: $BASE"
[[ -f "$FINAL_RUNNER" ]] || fail "missing final branch runner: $FINAL_RUNNER"
command -v git >/dev/null || fail "git is required on the Mac"
command -v ssh >/dev/null || fail "ssh is required on the Mac"
command -v scp >/dev/null || fail "scp is required on the Mac"

cd "$REPO_ROOT"
echo "======================================================================"
echo "GREENQUIC TUM BRANCH-AWARE FRESH SETUP"
echo "requested=$INPUT"
echo "target=$TARGET_BRANCH"
echo "The existing TUM setup scripts remain unchanged."
echo "======================================================================"

git fetch origin "$TARGET_BRANCH"
TARGET_SHA="$(git rev-parse "origin/$TARGET_BRANCH")"
[[ "$TARGET_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "cannot resolve origin/$TARGET_BRANCH"
echo "TARGET SHA=$TARGET_SHA"

echo
echo "======================================================================"
echo "PHASE A — RUN ESTABLISHED COMPLETE TUM SETUP"
echo "======================================================================"
bash "$BASE"

echo
echo "======================================================================"
echo "PHASE B — DISTRIBUTE SELECTED BRANCH WITHOUT REQUIRING NODE GITHUB KEYS"
echo "======================================================================"
STAMP="$(date +%Y%m%d_%H%M%S)"
BUNDLE="/tmp/GreenQUIC_${BRANCH_TAG}_${STAMP}.bundle"
TMP_REF="refs/heads/__greenquic_branch_setup_${STAMP}_$$"
cleanup() {
    git -C "$REPO_ROOT" update-ref -d "$TMP_REF" >/dev/null 2>&1 || true
    rm -f "$BUNDLE"
}
trap cleanup EXIT

git update-ref "$TMP_REF" "$TARGET_SHA"
git bundle create "$BUNDLE" "$TMP_REF"
git bundle verify "$BUNDLE" >/dev/null
ls -lh "$BUNDLE"
scp "${SSH_OPTS[@]}" -o ProxyJump="$BASTION" "$BUNDLE" root@idex:"$REMOTE_BUNDLE"
scp "${SSH_OPTS[@]}" -o ProxyJump="$BASTION" "$BUNDLE" root@tinyman:"$REMOTE_BUNDLE"

checkout_target() {
    local host="$1"
    echo "=== CHECKOUT $TARGET_BRANCH on $host ==="
    remote "$host" bash -s -- "$TARGET_BRANCH" "$TARGET_SHA" "$REMOTE_BUNDLE" "$TMP_REF" <<'REMOTE_CHECKOUT'
set -Eeuo pipefail
TARGET_BRANCH="$1"
TARGET_SHA="$2"
BUNDLE="$3"
TMP_REF="$4"
ROOT=/root/mohsen
cd "$ROOT"
git reset --hard
git fetch "$BUNDLE" "$TMP_REF"
git checkout -B "$TARGET_BRANCH" FETCH_HEAD
ACTUAL="$(git rev-parse HEAD)"
[[ "$ACTUAL" == "$TARGET_SHA" ]] || { echo "ERROR: target SHA mismatch" >&2; exit 2; }
echo "HOST=$(hostname) BRANCH=$(git branch --show-current) HEAD=$ACTUAL"
REMOTE_CHECKOUT
}
checkout_target idex
checkout_target tinyman

build_selected() {
    local host="$1"
    echo
echo "======================================================================"
    echo "BRANCH BUILD + VERIFY: $host ($BRANCH_TAG)"
    echo "======================================================================"
    remote "$host" bash -s -- "$BRANCH_TAG" "$TARGET_SHA" <<'REMOTE_BUILD'
set -Eeuo pipefail
KIND="$1"
TARGET_SHA="$2"
ROOT=/root/mohsen
P5="$ROOT/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
P7="$ROOT/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline"
P5_BUILD="$ROOT/msquic/build-greenquic-p5"
P5_CLIENT="$P5_BUILD/bin/Release/quicinterop"
P5_SERVER="$P5_BUILD/bin/Release/quicinteropserver"
P7_BUILD="$ROOT/msquic/build-linux-p7"
P7_CLIENT="$P7_BUILD/bin/Release/quicinterop"
P7_SERVER="$P7_BUILD/bin/Release/quicinteropserver"
PCI=0000:18:00.0
cd "$ROOT"
[[ "$(git rev-parse HEAD)" == "$TARGET_SHA" ]]
[[ -d "$P5" && -d "$P7" ]]
chmod 0755 "$P5"/*.sh "$P7"/*.sh 2>/dev/null || true

case "$KIND" in
    main)
        echo "Building stock/main P5"
        bash "$P5/build_p5_client.sh"
        grep -aFq -- 'GreenQUIC-P5-SEQUENCE-V2' "$P5_CLIENT"
        if grep -aFq -- 'GREENQUIC-P5-SUPER-PERF-V2' "$P5_CLIENT"; then
            echo "ERROR: performance marker contaminated main P5 binary" >&2
            exit 3
        fi
        ;;
    performance)
        echo "Building measured performance P5 defaults"
        bash "$P5/build_p5_super_performance.sh"
        grep -aFq -- 'GREENQUIC-P5-SUPER-PERF-V2' "$P5_CLIENT"
        if grep -aFq -- 'GREENQUIC-P5-PERFORMANCE2-V1' "$P5_CLIENT"; then
            echo "ERROR: performance2 marker contaminated performance binary" >&2
            exit 3
        fi
        ;;
    performance2)
        echo "Building performance2 baseline (all new P2 switches default OFF)"
        env \
            P5_P2_DIAG_INTERVAL_US=0 \
            P5_P2_TX_HANDOFF=shared \
            P5_P2_RX_PREFETCH=0 \
            P5_P2_UDP_SEG=0 \
            bash "$P5/build_p5_performance2.sh"
        grep -aFq -- 'GREENQUIC-P5-SUPER-PERF-V2' "$P5_CLIENT"
        grep -aFq -- 'GREENQUIC-P5-PERFORMANCE2-V1' "$P5_CLIENT"
        ;;
    *) echo "ERROR: unknown branch kind: $KIND" >&2; exit 2 ;;
esac

test -x "$P5_CLIENT"
test -x "$P5_SERVER"
grep -aFq -- 'GreenQUIC-P5-SEQUENCE-V2' "$P5_CLIENT"
grep -aFq -- 'GreenQUIC PACKETS source=datapath_totals' "$P5_CLIENT"
grep -aFq -- 'GreenQUIC PACKETS source=datapath_totals' "$P5_SERVER"
P5_CLIENT_SHA="$(sha256sum "$P5_CLIENT" | awk '{print $1}')"
P5_SERVER_SHA="$(sha256sum "$P5_SERVER" | awk '{print $1}')"

echo "Building isolated normal-Linux P7 from selected branch"
bash "$P7/build_p7_linux.sh"
test -x "$P7_CLIENT"
test -x "$P7_SERVER"
if ldd "$P7_CLIENT" 2>/dev/null | grep -qi dpdk || ldd "$P7_SERVER" 2>/dev/null | grep -qi dpdk; then
    echo "ERROR: P7 Linux binaries unexpectedly link DPDK" >&2
    exit 4
fi
[[ "$(sha256sum "$P5_CLIENT" | awk '{print $1}')" == "$P5_CLIENT_SHA" ]]
[[ "$(sha256sum "$P5_SERVER" | awk '{print $1}')" == "$P5_SERVER_SHA" ]]

DRIVER="$(basename "$(readlink -f "/sys/bus/pci/devices/$PCI/driver" 2>/dev/null || true)")"
case "$DRIVER" in igb_uio|vfio-pci) ;; *) echo "ERROR: test NIC not left on a DPDK driver: ${DRIVER:-none}" >&2; exit 5;; esac
command -v zip >/dev/null
python3 -c 'import matplotlib, numpy'
echo "READY HOST=$(hostname) KIND=$KIND HEAD=$(git rev-parse HEAD) DPDK_DRIVER=$DRIVER"
sha256sum "$P5_CLIENT" "$P5_SERVER" "$P7_CLIENT" "$P7_SERVER"
REMOTE_BUILD
}

build_selected idex
build_selected tinyman

IDEX_SHA="$(remote idex 'git -C /root/mohsen rev-parse HEAD')"
TINYMAN_SHA="$(remote tinyman 'git -C /root/mohsen rev-parse HEAD')"
[[ "$IDEX_SHA" == "$TARGET_SHA" ]] || fail "IDEX is not at selected branch SHA"
[[ "$TINYMAN_SHA" == "$TARGET_SHA" ]] || fail "Tinyman is not at selected branch SHA"
remote idex 'ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman true'

remote idex bash -s <<'INSTALL_LAUNCHERS'
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
exec ./run_matrix_with_report.sh \
    --client-host tinyman \
    --client-dir /root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline \
    "$@"
P7EOF
chmod 700 /root/run_p5.sh /root/run_p7.sh
/root/run_p5.sh --help >/dev/null
/root/run_p7.sh --help >/dev/null
echo "IDEX launchers installed: /root/run_p5.sh /root/run_p7.sh"
INSTALL_LAUNCHERS

echo
echo "#########################################################################"
echo "### BRANCH READY ON BOTH TUM NODES"
echo "### input:  $INPUT"
echo "### branch: $TARGET_BRANCH"
echo "### commit: $TARGET_SHA"
echo "### P5 branch-specific binary: READY"
echo "### P7 isolated Linux binary: READY"
echo "### NICs: DPDK-bound and ready for P5"
echo "######################################################################"
echo
printf 'MAC COMMAND — FINAL 4 TESTS, 6 RUNS x 5 DOWNLOADS:\n\n'
printf 'cd %q || exit 1; TAG="$(date +%%Y%%m%%d_%%H%%M%%S)"; LOG="$HOME/Downloads/GreenQUIC_FINAL_%s_${TAG}.log"; PIDFILE="$HOME/Downloads/GreenQUIC_FINAL_%s_${TAG}.pid"; nohup caffeinate -dimsu bash tum_testbed_setup/mac_run_final_selected_branch.sh %q --runs 6 --downloads 5 >"$LOG" 2>&1 < /dev/null & PID=$!; echo "$PID" >"$PIDFILE"; disown "$PID" 2>/dev/null || true; echo "STARTED PID=$PID"; echo "LOG=$LOG"; echo "PIDFILE=$PIDFILE"; echo "You can close this Terminal."\n' \
    "$REPO_ROOT" "$BRANCH_TAG" "$BRANCH_TAG" "$INPUT"
echo
