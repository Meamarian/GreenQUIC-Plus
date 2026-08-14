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
printf '### PHASE 4 — P6 BUILD TEMPORARILY SKIPPED\n'
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
grep -Fq -- 'GREENQUIC-P6-DETERMINISTIC-LOSS-V2' "$SOURCE/src/platform/datapath_raw_dpdk_linux.c"
grep -aFq -- 'GREENQUIC-P6-DETERMINISTIC-LOSS-V2' "$CLIENT"
grep -aFq -- 'GREENQUIC-P6-DETERMINISTIC-LOSS-V2' "$SERVER"
grep -aFq -- 'hint_cubic_cwnd_blocked=' "$SERVER"
grep -aFq -- 'hint_cubic_recovery=' "$SERVER"
echo "P6 BUILD+VERIFY PASS on $(hostname)"
P6BUILD
}

# TEMPORARY P6 SKIP (2026-08-14):
# Keep the complete P6 build/verification function above intact for later use,
# but do not invoke it during the fresh TUM setup right now. This lets the
# outer P4+P5+P6+P7 wrapper continue directly to the P7 Linux build after P5.
# To re-enable P6 later, uncomment these two lines only:
# build_p6 idex
# build_p6 tinyman
printf 'P6 build/verification: TEMPORARILY SKIPPED; continuing to P7.\n'

IDEX_SHA="$(remote idex 'git -C /root/mohsen rev-parse HEAD')"
TINYMAN_SHA="$(remote tinyman 'git -C /root/mohsen rev-parse HEAD')"
[[ "$IDEX_SHA" == "$TINYMAN_SHA" ]] || fail "IDEX/Tinyman commits differ: $IDEX_SHA vs $TINYMAN_SHA"

# Keep the P6 launcher code in place. It is installed for convenience, but the
# P6 binary is intentionally not built by this temporary setup path.
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
echo "/root/run_p6.sh installed (P6 build currently skipped)"
P6LAUNCH

printf '\n################################################################\n'
printf '### GREENQUIC TUM TESTBED: NORMAL + P4 + P5 READY\n'
printf '### P6 build: TEMPORARILY SKIPPED (code retained/commented calls only)\n'
printf '### Continuing to P7 in the outer setup wrapper.\n'
printf '################################################################\n'
