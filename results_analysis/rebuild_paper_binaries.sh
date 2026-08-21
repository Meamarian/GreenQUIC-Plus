#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/paper_testbed_defaults.sh"

# Keep the CONTROL-HOST helper itself current. This wrapper intentionally does
# not refresh /root/mohsen on the experiment nodes; use setup_paper_testbed.sh
# when remote source may be stale.
sync_rc=0
bash "$HERE/control_main_sync.sh" || sync_rc=$?
case "$sync_rc" in
  0) ;;
  10) exec bash "$GQ_CONTROL_REPO/results_analysis/rebuild_paper_binaries.sh" "$@" ;;
  *) exit "$sync_rc" ;;
esac

cd "$GQ_CONTROL_REPO"
EXPECTED_SHA="$(git rev-parse refs/remotes/origin/main)"

SSH_OPTS=(-o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o StrictHostKeyChecking=accept-new -i "$GQ_SSH_KEY" -o IdentitiesOnly=yes)
if [[ -n "$GQ_BASTION" && "$GQ_BASTION" != none ]]; then SSH_OPTS+=(-J "$GQ_BASTION"); fi
remote(){ local host="$1"; shift; ssh "${SSH_OPTS[@]}" "$GQ_REMOTE_USER@$host" "$@"; }

SERVER_SHA="$(remote "$GQ_SERVER_HOST" 'git -C /root/mohsen rev-parse HEAD 2>/dev/null || true')"
CLIENT_SHA="$(remote "$GQ_CLIENT_HOST" 'git -C /root/mohsen rev-parse HEAD 2>/dev/null || true')"
SERVER_BRANCH="$(remote "$GQ_SERVER_HOST" 'git -C /root/mohsen branch --show-current 2>/dev/null || true')"
CLIENT_BRANCH="$(remote "$GQ_CLIENT_HOST" 'git -C /root/mohsen branch --show-current 2>/dev/null || true')"

if [[ "$SERVER_BRANCH" != main || "$CLIENT_BRANCH" != main || "$SERVER_SHA" != "$EXPECTED_SHA" || "$CLIENT_SHA" != "$EXPECTED_SHA" ]]; then
  cat >&2 <<EOF
ERROR: rebuild-only mode refuses stale/different remote source.
CONTROL origin/main: $EXPECTED_SHA
SERVER: branch=${SERVER_BRANCH:-none} sha=${SERVER_SHA:-none}
CLIENT: branch=${CLIENT_BRANCH:-none} sha=${CLIENT_SHA:-none}
Use the full deployment instead:
  bash results_analysis/setup_paper_testbed.sh
EOF
  exit 2
fi

remote_build() {
  local role="$1" host="$2"
  echo "===== BUILD $role ($host) SHA=$EXPECTED_SHA ====="
  ssh "${SSH_OPTS[@]}" "$GQ_REMOTE_USER@$host" bash -s -- "$EXPECTED_SHA" <<'REMOTE'
set -Eeuo pipefail
EXPECTED_SHA="$1"
ROOT=/root/mohsen
P5="$ROOT/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
P7="$ROOT/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline"
[[ "$(git -C "$ROOT" branch --show-current)" == main ]]
[[ "$(git -C "$ROOT" rev-parse HEAD)" == "$EXPECTED_SHA" ]]
test -d "$ROOT/msquic/deps/dpdk-install"
P5_BUILD_REUSE=1 bash "$P5/build_p5_performance2.sh"
bash "$P7/build_p7_linux.sh"
P5C="$ROOT/msquic/build-greenquic-p5/bin/Release/quicinterop"
P5S="$ROOT/msquic/build-greenquic-p5/bin/Release/quicinteropserver"
P7C="$ROOT/msquic/build-linux-p7/bin/Release/quicinterop"
P7S="$ROOT/msquic/build-linux-p7/bin/Release/quicinteropserver"
for f in "$P5C" "$P5S" "$P7C" "$P7S"; do test -x "$f"; done
MARKER='GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0'
grep -aFq -- "$MARKER" "$P5C"
grep -aFq -- "$MARKER" "$P5S"
if ldd "$P7C" 2>/dev/null | grep -qi dpdk || ldd "$P7S" 2>/dev/null | grep -qi dpdk; then
  echo "ERROR: P7 unexpectedly links DPDK" >&2
  exit 2
fi
echo "REBUILD PASS host=$(hostname) head=$(git -C "$ROOT" rev-parse HEAD)"
sha256sum "$P5C" "$P5S" "$P7C" "$P7S"
REMOTE
}

remote_build SERVER "$GQ_SERVER_HOST" & p1=$!
remote_build CLIENT "$GQ_CLIENT_HOST" & p2=$!
rc=0
wait "$p1" || rc=1
wait "$p2" || rc=1
(( rc == 0 )) || { echo "ERROR: one or both endpoint builds failed" >&2; exit 1; }

echo "P5/P7 REBUILD PASS ON BOTH ENDPOINTS AT $EXPECTED_SHA"
