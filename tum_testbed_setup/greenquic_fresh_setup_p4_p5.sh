#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# GreenQUIC TUM/LRZ fresh setup: normal + P4 + P5
# RUN THIS SCRIPT ON THE MAC.
#
# This wrapper deliberately preserves the established TUM setup sequence in
# greenquic_fresh_setup_base.sh (SSH restoration, clone/pin, host bootstrap,
# E810 link checks, DPDK binding, real P0 smoke test, and P4 verification).
# Only after that full setup passes do we build and verify the isolated P5 tree
# on both idex and tinyman.
#
# Generated P4/P5 source/build directories remain untracked and are recreated
# from committed source on every fresh setup.
# =============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE="$HERE/greenquic_fresh_setup_base.sh"
BASTION="mohsen@coinbase"
ROOT="/root/mohsen"
P5_REL="greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
P5="$ROOT/$P5_REL"
P5_BUILD="$ROOT/msquic/build-greenquic-p5"
P5_SOURCE="$ROOT/msquic-p5-source"
PLOTTER="$ROOT/greenquic_test_suite_v22/common/bin/plot_greenquic_single_run_charts.py"

SSH_OPTS=(
    -o ConnectTimeout=20
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=4
    -o StrictHostKeyChecking=accept-new
)

fail() {
    echo
    echo "################################################################"
    echo "### ERROR: $*"
    echo "################################################################"
    exit 1
}

remote() {
    local host="$1"
    shift
    ssh "${SSH_OPTS[@]}" -J "$BASTION" root@"$host" "$@"
}

[[ -f "$BASE" ]] || fail "Missing preserved base TUM setup: $BASE"

printf '\n################################################################\n'
printf '### PHASE 1 — EXISTING TUM SETUP: NORMAL + P4 + P0\n'
printf '################################################################\n\n'

# Run the preserved proven implementation directly. This avoids any dispatcher
# recursion and keeps the established SSH/link/DPDK/P0/P4 behavior unchanged.
bash "$BASE" "$@"

printf '\n################################################################\n'
printf '### PHASE 2 — BUILD + VERIFY P5 ON BOTH NODES\n'
printf '################################################################\n\n'

build_and_verify_p5() {
    local host="$1"
    echo
    echo "================================================================"
    echo " P5 BUILD + VERIFY: $host"
    echo "================================================================"

    remote "$host" bash -s <<'P5BUILD'
set -Eeuo pipefail
ROOT="/root/mohsen"
P5="$ROOT/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
P5_BUILD="$ROOT/msquic/build-greenquic-p5"
P5_SOURCE="$ROOT/msquic-p5-source"
P5_CLIENT="$P5_BUILD/bin/Release/quicinterop"
P5_SERVER="$P5_BUILD/bin/Release/quicinteropserver"
PLOTTER="$ROOT/greenquic_test_suite_v22/common/bin/plot_greenquic_single_run_charts.py"

cd "$ROOT"

echo "Git commit: $(git rev-parse HEAD)"
[[ -f "$P5/build_p5_client.sh" ]] || {
    echo "ERROR: missing P5 build script: $P5/build_p5_client.sh" >&2
    exit 1
}

# build_p5_client.sh intentionally deletes/recreates both generated trees:
#   /root/mohsen/msquic-p5-source
#   /root/mohsen/msquic/build-greenquic-p5
chmod 0755 "$P5/build_p5_client.sh"
cd "$P5"
./build_p5_client.sh

[[ -d "$P5_SOURCE" ]] || {
    echo "ERROR: P5 source tree was not generated: $P5_SOURCE" >&2
    exit 1
}
[[ -x "$P5_CLIENT" ]] || {
    echo "ERROR: P5 client binary missing: $P5_CLIENT" >&2
    exit 1
}
[[ -x "$P5_SERVER" ]] || {
    echo "ERROR: P5 server binary missing: $P5_SERVER" >&2
    exit 1
}

# Exact corrected sequential P5 behavior used in the last successful run.
grep -aFq -- 'GreenQUIC-P5-SEQUENCE-V2' "$P5_CLIENT"
grep -aFq -- 'ready_for_start_gate_us=' "$P5_CLIENT"

# Final counters must be compiled into both endpoints even with GQ_LOG_LEVEL=0.
grep -aFq -- 'GreenQUIC COUNTERS schema=greenquic-counters-v1' "$P5_CLIENT"
grep -aFq -- 'GreenQUIC COUNTERS schema=greenquic-counters-v1' "$P5_SERVER"

# Process-end DPDK packet totals are emitted for OFF/BASIC/PLUS without adding
# any new hot-path work; the counters already exist in the datapath.
grep -aFq -- 'GreenQUIC PACKETS source=datapath_totals' "$P5_CLIENT"
grep -aFq -- 'GreenQUIC PACKETS source=datapath_totals' "$P5_SERVER"
grep -Fq -- 'GREENQUIC-P5-DATAPATH-PACKET-TOTALS-V1' \
    "$P5_SOURCE/src/platform/datapath_raw_dpdk_linux.c"

# Last successful graceful-cleanup and CUBIC-counter fixes must survive the
# isolated P5 source regeneration.
grep -Fq -- 'GREENQUIC-P5-ASYNC-SIGNAL-SAFE-EXIT-V1' \
    "$P5_SOURCE/src/tools/interopserver/InteropServer.cpp"
grep -Fq -- 'GREENQUIC-COUNTERS-RECOVERY-END-SUCCESS-V1' \
    "$P5_SOURCE/src/platform/greenquic_plus.c"
grep -Fq -- 'GREENQUIC-P5-GRACEFUL-SERVER-EXIT-V1' \
    "$P5/gq_common_p5.sh"
grep -Fq -- '-exitonsig' "$P5/gq_common_p5.sh"

# EPOLL RX-eventfd fix and telemetry used to prove wake==drain/no drain errors.
grep -Fq -- 'GREENQUIC-EPOLL-RXFD-ACK-V1' \
    "$P5_SOURCE/src/platform/datapath_raw_dpdk_linux.c"
grep -aFq -- 'epoll_rx_fd_drain=' "$P5_CLIENT"
grep -aFq -- 'epoll_rx_fd_drain_error=' "$P5_CLIENT"
grep -aFq -- 'hint_cubic_ramping=' "$P5_SERVER"

# New additive single-run chart set. The legacy CUBIC-only plotter remains in
# Git history/source but is intentionally not invoked for new matrices.
[[ -f "$PLOTTER" ]]
grep -Fq -- 'GREENQUIC-SINGLE-RUN-CHARTS-V1' "$PLOTTER"
grep -Fq -- 'GREENQUIC-SINGLE-RUN-CHARTS-HOOK-V1' "$P5/p5_finalize_matrix.py"
python3 -c 'import matplotlib'
python3 "$PLOTTER" --self-test

echo
echo "P5 CLIENT: $(readlink -f "$P5_CLIENT")"
sha256sum "$P5_CLIENT"
echo "P5 SERVER: $(readlink -f "$P5_SERVER")"
sha256sum "$P5_SERVER"
echo
echo "P5 BUILD + LAST-SUCCESSFUL FIX VERIFICATION: PASS on $(hostname)"
P5BUILD
}

build_and_verify_p5 idex
build_and_verify_p5 tinyman

printf '\n################################################################\n'
printf '### PHASE 3 — CROSS-HOST P5 READINESS\n'
printf '################################################################\n\n'

IDEX_SHA="$(remote idex 'git -C /root/mohsen rev-parse HEAD')"
TINYMAN_SHA="$(remote tinyman 'git -C /root/mohsen rev-parse HEAD')"
[[ "$IDEX_SHA" == "$TINYMAN_SHA" ]] ||
    fail "IDEX and Tinyman Git commits differ: idex=$IDEX_SHA tinyman=$TINYMAN_SHA"

remote idex 'ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman true'

# Create a convenience P5 launcher on IDEX. It does not hard-code a tuning
# profile; pass the desired matrix arguments exactly as usual.
remote idex 'bash -s' <<'P5LAUNCHER'
set -Eeuo pipefail
cat > /root/run_p5.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
P5="/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
cd "$P5"
exec ./run_matrix_from_idex.sh \
    --client-host tinyman \
    --client-dir "$P5" \
    --client-bin /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop \
    "$@"
EOF
chmod 700 /root/run_p5.sh
/root/run_p5.sh --help >/dev/null
echo "/root/run_p5.sh: PASS"
P5LAUNCHER

printf '\n################################################################\n'
printf '### GREENQUIC TUM TESTBED: NORMAL + P4 + P5 FULL SUCCESS\n'
printf '################################################################\n'
printf 'Commit on both nodes: %s\n' "$IDEX_SHA"
printf 'Existing TUM SSH/link/DPDK/P0/P4 setup: PASS\n'
printf 'P5 isolated source recreation: PASS on both\n'
printf 'P5 client build: PASS on both\n'
printf 'P5 server build: PASS on both\n'
printf 'P5 sequence V2 + start gate: PASS\n'
printf 'P5 final counters: PASS\n'
printf 'P5 graceful cleanup: PASS\n'
printf 'P5 corrected CUBIC recovery-end counter: PASS\n'
printf 'P5 EPOLL RX-eventfd drain fix: PASS\n'
printf 'P5 DPDK packet totals for OFF/BASIC/PLUS: PASS\n'
printf 'Single-run charts with values: PASS\n'
printf 'Single-run charts without values: PASS\n'
printf 'P4 launcher: /root/run_p4.sh\n'
printf 'P5 launcher: /root/run_p5.sh\n'
printf '################################################################\n'
