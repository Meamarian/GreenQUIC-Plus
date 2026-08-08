#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE="$HERE/greenquic_fresh_setup_p4_p5.sh"
BASTION="mohsen@coinbase"
SSH_OPTS=(-o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o StrictHostKeyChecking=accept-new)

fail(){ echo "ERROR: $*" >&2; exit 1; }
remote(){ local host="$1"; shift; ssh "${SSH_OPTS[@]}" -J "$BASTION" root@"$host" "$@"; }

[[ -f "$BASE" ]] || fail "missing existing P4/P5 setup: $BASE"

# Preserve the already proven normal/P4/P5 setup exactly as-is.
bash "$BASE" "$@"

printf '\n################################################################\n'
printf '### PHASE 4 — BUILD + VERIFY ISOLATED P6 ON BOTH NODES\n'
printf '################################################################\n\n'

build_p6(){
    local host="$1"
    echo "=== P6 BUILD: $host ==="
    remote "$host" bash -s <<'P6BUILD'
set -Eeuo pipefail
ROOT=/root/mohsen
P6="$ROOT/greenquic_test_suite_v22/test_cases/pretests/P6_cubic_block_recovery"
BUILD="$ROOT/msquic/build-greenquic-p6"
SOURCE="$ROOT/msquic-p6-source"
CLIENT="$BUILD/bin/Release/quicinterop"
SERVER="$BUILD/bin/Release/quicinteropserver"
cd "$ROOT"
chmod 0755 "$P6/build_p6_client.sh" "$P6/run_p6_matrix.sh"
"$P6/build_p6_client.sh"
[[ -d "$SOURCE" && -x "$CLIENT" && -x "$SERVER" ]]
grep -Fq -- 'GREENQUIC-P6-DETERMINISTIC-LOSS-V1' "$SOURCE/src/platform/datapath_raw_dpdk.c"
grep -aFq -- 'GREENQUIC-P6-DETERMINISTIC-LOSS-V1' "$CLIENT"
grep -aFq -- 'GREENQUIC-P6-DETERMINISTIC-LOSS-V1' "$SERVER"
grep -aFq -- 'hint_cubic_cwnd_blocked=' "$SERVER"
grep -aFq -- 'hint_cubic_recovery=' "$SERVER"
echo "P6 BUILD+VERIFY PASS on $(hostname)"
P6BUILD
}

build_p6 idex
build_p6 tinyman

IDEX_SHA="$(remote idex 'git -C /root/mohsen rev-parse HEAD')"
TINYMAN_SHA="$(remote tinyman 'git -C /root/mohsen rev-parse HEAD')"
[[ "$IDEX_SHA" == "$TINYMAN_SHA" ]] || fail "IDEX/Tinyman commits differ: $IDEX_SHA vs $TINYMAN_SHA"

remote idex bash -s <<'P6LAUNCH'
set -Eeuo pipefail
cat > /root/run_p6.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
P6=/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P6_cubic_block_recovery
cd "$P6"
exec ./run_p6_matrix.sh "$@"
EOF
chmod 700 /root/run_p6.sh
/root/run_p6.sh --help >/dev/null 2>&1 || true
echo "/root/run_p6.sh installed"
P6LAUNCH

printf '\n################################################################\n'
printf '### GREENQUIC TUM TESTBED: NORMAL + P4 + P5 + P6 READY\n'
printf '### P6 launcher on idex: /root/run_p6.sh\n'
printf '################################################################\n'
