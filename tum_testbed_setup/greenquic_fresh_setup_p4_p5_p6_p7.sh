#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE="$HERE/greenquic_fresh_setup_p4_p5_p6.sh"
BASTION="mohsen@coinbase"
SSH_OPTS=(-o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o StrictHostKeyChecking=accept-new)

fail(){ echo "ERROR: $*" >&2; exit 1; }
remote(){ local host="$1"; shift; ssh "${SSH_OPTS[@]}" -J "$BASTION" root@"$host" "$@"; }

[[ -f "$BASE" ]] || fail "missing existing P4/P5/P6 setup: $BASE"

# Preserve the established GreenQUIC/DPDK setup and builds exactly as-is first.
bash "$BASE" "$@"

printf '\n################################################################\n'
printf '### PHASE 5 — BUILD + VERIFY P7 NORMAL LINUX UDP ON BOTH NODES\n'
printf '################################################################\n\n'

build_p7(){
    local host="$1"
    echo "=== P7 LINUX BUILD: $host ==="
    remote "$host" bash -s <<'P7BUILD'
set -Eeuo pipefail
ROOT=/root/mohsen
P7="$ROOT/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline"
BUILD="$ROOT/msquic/build-linux-p7"
SOURCE="$ROOT/msquic-p7-linux-source"
CLIENT="$BUILD/bin/Release/quicinterop"
SERVER="$BUILD/bin/Release/quicinteropserver"
P5_BUILD="$ROOT/msquic/build-greenquic-p5"
P5_CLIENT="$P5_BUILD/bin/Release/quicinterop"
P5_SERVER="$P5_BUILD/bin/Release/quicinteropserver"
P5_CLIENT_SHA_BEFORE="$(sha256sum "$P5_CLIENT" | awk '{print $1}')"
P5_SERVER_SHA_BEFORE="$(sha256sum "$P5_SERVER" | awk '{print $1}')"
cd "$ROOT"
[[ -d "$P7" ]] || { echo "ERROR: P7 directory missing: $P7" >&2; exit 2; }
chmod 0755 "$P7"/*.sh "$P7"/*.py
for f in "$P7"/*.sh; do bash -n "$f"; done
python3 -m py_compile "$P7"/*.py
python3 -c 'import matplotlib, numpy'
python3 "$P7/build_p7_report.py" --self-test
[[ "$SOURCE" != "$ROOT/msquic-p5-source" && "$BUILD" != "$P5_BUILD" ]]
"$P7/build_p7_linux.sh"
[[ -d "$SOURCE" && -x "$CLIENT" && -x "$SERVER" ]]
grep -Fq -- 'GREENQUIC-P7-LINUX-UDP-FEATURE-OBSERVE-V1' "$SOURCE/src/platform/datapath_epoll.c"
grep -Fq -- 'GREENQUIC-P7-NO-DPDK-HEADER-LEAK-V1' "$SOURCE/src/platform/datapath_raw.h"
grep -Fq -- 'GREENQUIC-P7-NORMAL-LINUX-SOCKET-V1' "$SOURCE/src/platform/datapath_xplat.c"
grep -Fq -- 'GREENQUIC-P7-SERVER-TIMELINE-V1' "$SOURCE/src/tools/interopserver/InteropServer.cpp"
grep -aFq -- 'GreenQUIC-P5-SEQUENCE-V2' "$CLIENT"
grep -aFq -- 'linux_udp_features' "$CLIENT"
grep -aFq -- 'GreenQUIC-P7' "$SERVER"
[[ -x "$P7/run_matrix_with_report.sh" && -x "$P7/build_p7_report.py" ]]
[[ "$(sha256sum "$P5_CLIENT" | awk '{print $1}')" == "$P5_CLIENT_SHA_BEFORE" ]]
[[ "$(sha256sum "$P5_SERVER" | awk '{print $1}')" == "$P5_SERVER_SHA_BEFORE" ]]
echo "P5 binary isolation after P7 build: PASS"
if ldd "$CLIENT" 2>/dev/null | grep -qi dpdk || ldd "$SERVER" 2>/dev/null | grep -qi dpdk; then
    echo "ERROR: P7 Linux binaries unexpectedly link DPDK" >&2
    exit 3
fi
printf 'P7 BUILD+VERIFY PASS on %s\n' "$(hostname)"
sha256sum "$CLIENT" "$SERVER"
P7BUILD
}

build_p7 idex
build_p7 tinyman

IDEX_SHA="$(remote idex 'git -C /root/mohsen rev-parse HEAD')"
TINYMAN_SHA="$(remote tinyman 'git -C /root/mohsen rev-parse HEAD')"
[[ "$IDEX_SHA" == "$TINYMAN_SHA" ]] || fail "IDEX/Tinyman commits differ: $IDEX_SHA vs $TINYMAN_SHA"

remote idex bash -s <<'P7LAUNCH'
set -Eeuo pipefail
cat > /root/run_p7.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
P7=/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline
cd "$P7"
exec ./run_matrix_with_report.sh \
    --client-host tinyman \
    --client-dir /root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline \
    "$@"
EOF
chmod 700 /root/run_p7.sh
/root/run_p7.sh --help >/dev/null
echo "/root/run_p7.sh installed"
P7LAUNCH

printf '\n################################################################\n'
printf '### GREENQUIC TUM TESTBED: NORMAL + P4 + P5 + P6 + P7 READY\n'
printf '### P7 Linux launcher on idex: /root/run_p7.sh (isolated + report wrapper)\n'
printf '### P7 changes NICs to ice only while P7 runs, then restores the exact pre-P7 DPDK driver.\n'
printf '################################################################\n'
