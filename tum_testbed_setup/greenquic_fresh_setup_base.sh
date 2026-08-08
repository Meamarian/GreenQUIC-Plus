#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# GreenQUIC fresh Debian live-boot setup for TUM/LRZ IDEX + Tinyman
# RUN THIS SCRIPT ON THE MAC.
#
# Final success requires:
#   Mac -> IDEX SSH
#   Mac -> Tinyman SSH
#   IDEX -> Tinyman SSH
#   latest GreenQUIC/main on both
#   ICE DDP firmware on both
#   GreenQUIC test/report Python dependencies on both
#   MSR/P-state readiness
#   normal GreenQUIC + isolated P4 builds
#   16384 x 2 MiB hugepages = 32 GiB
#   both physical E810 links UP before userspace detach
#   DPDK driver = igb_uio OR vfio-pci only
#   P0 real 1 MiB QUIC/DPDK client/server smoke test PASS
#   P4 launcher created on IDEX
#
# IMPORTANT:
# - Never reboot a test node as part of this script. These nodes are live-boot
#   and non-persistent.
# - The Mac private key is never copied to a node.
# =============================================================================

BASTION="mohsen@coinbase"
REPO="git@github.com:Meamarian/GreenQUIC.git"
BRANCH="main"
MAC_KEY="$HOME/.ssh/id_ed25519"
ROOT="/root/mohsen"
PCI="0000:18:00.0"
LCORES="19,20"
HUGEPAGES_2M="16384"
IDEX_IP="192.168.100.1"
TINYMAN_IP="192.168.100.2"
IDEX_MAC="6c:fe:54:59:98:b0"
TINYMAN_MAC="6c:fe:54:59:99:38"
P0_REL="greenquic_test_suite_v22/test_cases/pretests/P0_smoke_1MiB"
P4_REL="greenquic_test_suite_v22/test_cases/pretests/P4_repeated_8GiB_downloads"

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

###############################################################################
# 1. MAC KEY + GITHUB
###############################################################################

echo
echo "================================================================"
echo " STEP 1 — MAC SSH KEY + GITHUB"
echo "================================================================"

if [[ ! -f "$MAC_KEY" ]]; then
    ssh-keygen -q -t ed25519 -f "$MAC_KEY" -N ""
fi
[[ -f "$MAC_KEY.pub" ]] || fail "Missing $MAC_KEY.pub"

ssh-add "$MAC_KEY" >/dev/null 2>&1 || {
    eval "$(ssh-agent -s)" >/dev/null
    ssh-add "$MAC_KEY"
}

GH_RESULT="$(ssh -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 || true)"
echo "$GH_RESULT"
echo "$GH_RESULT" | grep -qi "successfully authenticated" ||
    fail "Mac SSH key is not authenticated to GitHub"

EXPECTED_SHA="$(
    GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new' \
        git ls-remote "$REPO" "refs/heads/$BRANCH" | awk '{print $1}'
)"
[[ "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$ ]] ||
    fail "Cannot resolve latest GreenQUIC main commit"

echo
echo "LATEST MAIN:"
echo "$EXPECTED_SHA"

###############################################################################
# 2. CLEAR OLD HOST KEYS
###############################################################################

echo
echo "================================================================"
echo " STEP 2 — CLEAR STALE HOST KEYS"
echo "================================================================"

for h in idex tinyman 172.16.136.1 172.16.139.1; do
    ssh-keygen -R "$h" >/dev/null 2>&1 || true
done

###############################################################################
# 3. MAC -> IDEX/TINYMAN
###############################################################################

echo
echo "================================================================"
echo " STEP 3 — RESTORE MAC -> IDEX/TINYMAN SSH"
echo "================================================================"

PUB64="$(base64 < "$MAC_KEY.pub" | tr -d '\n')"

ssh "${SSH_OPTS[@]}" "$BASTION" bash -s -- "$PUB64" <<'COINBASE'
set -Eeuo pipefail
PUB64="$1"
for h in idex tinyman 172.16.136.1 172.16.139.1; do
    ssh-keygen -R "$h" >/dev/null 2>&1 || true
done
for host in idex tinyman; do
    echo "Installing Mac public key on $host..."
    printf '%s' "$PUB64" | base64 -d |
        ssh -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new root@"$host" '
            set -Eeuo pipefail
            mkdir -p /root/.ssh
            chmod 700 /root/.ssh
            KEY="$(cat)"
            touch /root/.ssh/authorized_keys
            chmod 600 /root/.ssh/authorized_keys
            grep -qxF "$KEY" /root/.ssh/authorized_keys ||
                printf "%s\n" "$KEY" >> /root/.ssh/authorized_keys
        '
done
COINBASE

remote idex 'echo "MAC -> IDEX: PASS"'
remote tinyman 'echo "MAC -> TINYMAN: PASS"'

###############################################################################
# 4. IDEX -> TINYMAN SSH
###############################################################################

echo
echo "================================================================"
echo " STEP 4 — RESTORE IDEX -> TINYMAN SSH"
echo "================================================================"

IDEX_PUB="$(
    remote idex '
        set -Eeuo pipefail
        mkdir -p /root/.ssh
        chmod 700 /root/.ssh
        if [[ ! -f /root/.ssh/id_ed25519 ]]; then
            ssh-keygen -q -t ed25519 -f /root/.ssh/id_ed25519 -N ""
        fi
        chmod 600 /root/.ssh/id_ed25519
        cat /root/.ssh/id_ed25519.pub
    ' | awk '/^ssh-ed25519 / {print; exit}'
)"
[[ "$IDEX_PUB" == ssh-ed25519\ * ]] || fail "Could not obtain IDEX SSH public key"

IDEX_PUB64="$(printf '%s\n' "$IDEX_PUB" | base64 | tr -d '\n')"
remote tinyman bash -s -- "$IDEX_PUB64" <<'TINYKEY'
set -Eeuo pipefail
KEY="$(printf '%s' "$1" | base64 -d)"
mkdir -p /root/.ssh
chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
grep -qxF "$KEY" /root/.ssh/authorized_keys ||
    printf '%s\n' "$KEY" >> /root/.ssh/authorized_keys
TINYKEY

remote idex '
    set -Eeuo pipefail
    ssh-keygen -R tinyman >/dev/null 2>&1 || true
    ssh-keygen -R 172.16.139.1 >/dev/null 2>&1 || true
    RESULT="$(ssh -o BatchMode=yes -o ConnectTimeout=15 \
        -o StrictHostKeyChecking=accept-new root@tinyman hostname)"
    [[ "$RESULT" == tinyman ]]
    echo "IDEX -> TINYMAN: PASS"
'

###############################################################################
# 5. CLONE/UPDATE + BOOTSTRAP BOTH
###############################################################################

echo
echo "================================================================"
echo " STEP 5 — LATEST MAIN + FULL BUILD"
echo "================================================================"

setup_host() {
    local host="$1" local_ip peer_mac role
    case "$host" in
        idex)
            local_ip="$IDEX_IP"
            peer_mac="$TINYMAN_MAC"
            role="server"
            ;;
        tinyman)
            local_ip="$TINYMAN_IP"
            peer_mac="$IDEX_MAC"
            role="client"
            ;;
        *) fail "Unknown host $host" ;;
    esac

    echo
echo "================================================================"
    echo " BUILDING $host"
    echo "================================================================"

    ssh "${SSH_OPTS[@]}" -A -J "$BASTION" root@"$host" bash -s -- \
        "$EXPECTED_SHA" "$local_ip" "$peer_mac" "$role" <<'REMOTESETUP'
set -Eeuo pipefail
EXPECTED_SHA="$1"
LOCAL_IP="$2"
PEER_MAC="$3"
ROLE="$4"
ROOT="/root/mohsen"
REPO="git@github.com:Meamarian/GreenQUIC.git"
PCI="0000:18:00.0"
LCORES="19,20"
HUGEPAGES_2M="16384"
export GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new'

echo "===== HOST ====="
hostname
grep '^PRETTY_NAME=' /etc/os-release || true

echo "===== CHECKOUT ====="
if [[ -d "$ROOT/.git" ]]; then
    cd "$ROOT"
    git remote set-url origin "$REPO"
    git fetch --prune origin main
else
    if [[ -e "$ROOT" ]]; then
        BACKUP="/root/mohsen.before-greenquic-$(date +%Y%m%d_%H%M%S)"
        echo "Backing up old $ROOT -> $BACKUP"
        mv "$ROOT" "$BACKUP"
    fi
    git clone --branch main --single-branch "$REPO" "$ROOT"
    cd "$ROOT"
fi

git checkout -f main
git reset --hard "$EXPECTED_SHA"
ACTUAL_SHA="$(git rev-parse HEAD)"
[[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] || {
    echo "ERROR: commit mismatch: expected=$EXPECTED_SHA actual=$ACTUAL_SHA" >&2
    exit 1
}
echo "Commit: $ACTUAL_SHA"
chmod +x bootstrap_greenquic.sh bootstrap_greenquic_core.sh

# Build/configure/hugepages here, but deliberately do NOT detach the NIC yet.
# Both E810 ports are verified together under the kernel ICE driver later.
./bootstrap_greenquic.sh \
    --rebuild \
    --pci "$PCI" \
    --local-ip "$LOCAL_IP" \
    --peer-mac "$PEER_MAC" \
    --lcores "$LCORES" \
    --hugepages "$HUGEPAGES_2M"

COMMON="$ROOT/greenquic_test_suite_v22/common"
# P4 manifest validation needs the 8-GiB reference on both hosts. The asset
# helper creates it sparsely, so this does not write 8 GiB of physical data.
python3 "$COMMON/bin/prepare_assets.py" --common "$COMMON" --create-8g

SERVER_BIN="$ROOT/msquic/build-greenquic/bin/Release/quicinteropserver"
CLIENT_BIN="$ROOT/msquic/build-greenquic/bin/Release/quicinterop"
P4_BIN="$ROOT/msquic/build-greenquic-p4/bin/Release/quicinterop"
SECNET="$ROOT/msquic/build-greenquic/bin/Release/secnetperf"
test -x "$SERVER_BIN"
test -x "$CLIENT_BIN"
test -x "$P4_BIN"
test -x "$SECNET"
grep -aFq 'GreenQUIC-P4-SEQUENCE-V2' "$P4_BIN"
grep -aFq 'ready_for_start_gate_us=' "$P4_BIN"
python3 -c 'import matplotlib'

echo "NORMAL SERVER: PASS"
echo "NORMAL CLIENT: PASS"
echo "P4 V2 CLIENT:  PASS"
echo "SECNETPERF:    PASS"
echo "MATPLOTLIB:    PASS"

ICE=""
for f in /lib/firmware/intel/ice/ddp/ice.pkg /usr/lib/firmware/intel/ice/ddp/ice.pkg; do
    if [[ -e "$f" ]]; then ICE="$(readlink -f "$f")"; break; fi
done
[[ -n "$ICE" ]] || { echo "ERROR: ICE DDP firmware missing" >&2; exit 1; }
echo "ICE firmware: $ICE"

lsmod | grep -q '^msr '
test -e /dev/cpu/19/msr
rdmsr -p 19 0xCE >/dev/null
echo "MSR CPU19: PASS"

NUMA="$(cat "/sys/bus/pci/devices/$PCI/numa_node")"
[[ "$NUMA" != -1 ]] || NUMA=0
HP="$(cat "/sys/devices/system/node/node${NUMA}/hugepages/hugepages-2048kB/nr_hugepages")"
[[ "$HP" == 16384 ]] || { echo "ERROR: expected 16384 hugepages, got $HP" >&2; exit 1; }
findmnt -n -t hugetlbfs /mnt/huge >/dev/null
echo "16384 x 2 MiB = 32 GiB: PASS"
REMOTESETUP
}

setup_host idex
setup_host tinyman

###############################################################################
# 6. PUT BOTH PORTS ON ICE AND CHECK PHYSICAL LINK
###############################################################################

echo
echo "================================================================"
echo " STEP 6 — VERIFY BOTH PHYSICAL E810 LINKS"
echo "================================================================"

restore_and_check_link() {
    local host="$1"
    remote "$host" bash -s <<'LINKCHECK'
set -Eeuo pipefail
PCI="0000:18:00.0"
DEVBIND="/root/mohsen/msquic/deps/dpdk/usertools/dpdk-devbind.py"
test -e "/sys/bus/pci/devices/$PCI"
test -f "$DEVBIND"
modprobe ice
CURRENT="$(basename "$(readlink -f "/sys/bus/pci/devices/$PCI/driver" 2>/dev/null || true)")"
if [[ -n "$CURRENT" && "$CURRENT" != ice ]]; then
    python3 "$DEVBIND" --unbind "$PCI"
    sleep 1
fi
CURRENT="$(basename "$(readlink -f "/sys/bus/pci/devices/$PCI/driver" 2>/dev/null || true)")"
if [[ "$CURRENT" != ice ]]; then
    python3 "$DEVBIND" --bind=ice "$PCI"
fi
sleep 2
ACTUAL="$(basename "$(readlink -f "/sys/bus/pci/devices/$PCI/driver")")"
[[ "$ACTUAL" == ice ]] || { echo "ERROR: expected ice, got $ACTUAL" >&2; exit 1; }
IFACE="$(find "/sys/bus/pci/devices/$PCI/net" -mindepth 1 -maxdepth 1 -printf '%f\n' | head -n1)"
[[ -n "$IFACE" ]] || { echo "ERROR: no Linux netdev for $PCI" >&2; exit 1; }
DEFAULT_IF="$(ip route show default | awk 'NR==1 {print $5}')"
[[ "$IFACE" != "$DEFAULT_IF" ]] || { echo "ERROR: test port is default-route interface" >&2; exit 1; }
SSH_LOCAL_IP=""
if [[ -n "${SSH_CONNECTION:-}" ]]; then read -r _ _ SSH_LOCAL_IP _ <<< "$SSH_CONNECTION"; fi
if [[ -n "$SSH_LOCAL_IP" ]]; then
    while read -r addr; do
        [[ "${addr%/*}" != "$SSH_LOCAL_IP" ]] || {
            echo "ERROR: test interface carries this SSH connection" >&2
            exit 1
        }
    done < <(ip -o -4 addr show dev "$IFACE" | awk '{print $4}')
fi
ip link set dev "$IFACE" up
CARRIER=0
OPERSTATE=unknown
for _ in $(seq 1 20); do
    CARRIER="$(cat "/sys/class/net/$IFACE/carrier" 2>/dev/null || echo 0)"
    OPERSTATE="$(cat "/sys/class/net/$IFACE/operstate" 2>/dev/null || echo unknown)"
    [[ "$CARRIER" == 1 && "$OPERSTATE" == up ]] && break
    sleep 1
done
ETHTOOL_LINK="$(ethtool "$IFACE" 2>/dev/null | awk -F': ' '/Link detected:/ {print $2; exit}')"
echo "HOST=$(hostname) PCI=$PCI IFACE=$IFACE DRIVER=$ACTUAL carrier=$CARRIER operstate=$OPERSTATE ethtool=${ETHTOOL_LINK:-unknown}"
[[ "$CARRIER" == 1 ]]
[[ "$OPERSTATE" == up ]]
[[ "$ETHTOOL_LINK" == yes ]]
echo "PHYSICAL LINK: PASS on $(hostname)"
LINKCHECK
}

# Both sides remain kernel/ICE-managed until both checks have passed.
restore_and_check_link idex
restore_and_check_link tinyman

###############################################################################
# 7. BIND BOTH TO APPROVED DPDK DRIVER
###############################################################################

echo
echo "================================================================"
echo " STEP 7 — BIND BOTH PORTS TO DPDK"
echo "================================================================"

bind_dpdk() {
    local host="$1"
    remote "$host" bash -s <<'BIND'
set -Eeuo pipefail
PCI="0000:18:00.0"
DEVBIND="/root/mohsen/msquic/deps/dpdk/usertools/dpdk-devbind.py"
IFACE="$(find "/sys/bus/pci/devices/$PCI/net" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | head -n1)"
[[ -z "$IFACE" ]] || ip link set dev "$IFACE" down
TARGET=""
modprobe uio 2>/dev/null || true
if [[ -d /sys/module/igb_uio ]] || modprobe igb_uio 2>/dev/null; then
    if python3 "$DEVBIND" --bind=igb_uio "$PCI"; then TARGET=igb_uio; fi
fi
if [[ -z "$TARGET" ]]; then
    modprobe vfio-pci
    python3 "$DEVBIND" --bind=vfio-pci "$PCI"
    TARGET=vfio-pci
fi
ACTUAL="$(basename "$(readlink -f "/sys/bus/pci/devices/$PCI/driver" 2>/dev/null || true)")"
case "$ACTUAL" in igb_uio|vfio-pci) ;; *) echo "ERROR: unacceptable driver ${ACTUAL:-none}" >&2; exit 1 ;; esac
[[ "$ACTUAL" == "$TARGET" ]]
echo "DPDK BINDING: PASS on $(hostname): $PCI -> $ACTUAL"
BIND
}

bind_dpdk idex
bind_dpdk tinyman

###############################################################################
# 8. VERIFY MANAGEMENT SSH STILL WORKS
###############################################################################

echo
echo "================================================================"
echo " STEP 8 — VERIFY SSH AFTER DPDK BINDING"
echo "================================================================"
remote idex 'echo "Mac -> IDEX after DPDK bind: PASS"'
remote tinyman 'echo "Mac -> TINYMAN after DPDK bind: PASS"'
remote idex 'ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman true && echo "IDEX -> TINYMAN after DPDK bind: PASS"'

###############################################################################
# 9. REAL P0 CLIENT/SERVER QUIC/DPDK SMOKE TEST
###############################################################################

echo
echo "================================================================"
echo " STEP 9 — REAL P0 1 MiB QUIC/DPDK SMOKE TEST"
echo "================================================================"

P0="$ROOT/$P0_REL"
remote idex "set -Eeuo pipefail; cd '$P0'; ./run_preflight.sh server"
remote tinyman "set -Eeuo pipefail; cd '$P0'; ./run_preflight.sh client"

remote idex bash -s <<'STARTP0'
set -Eeuo pipefail
P0="/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P0_smoke_1MiB"
rm -f /tmp/greenquic_p0_server.log /tmp/greenquic_p0_server.pid
cd "$P0"
setsid env ENABLE_RECORD=1 GQ_LOG_LEVEL=0 ./run_server.sh \
    >/tmp/greenquic_p0_server.log 2>&1 &
PID=$!
echo "$PID" >/tmp/greenquic_p0_server.pid
echo "P0 server process group: $PID"
STARTP0

# Do not wait for "Port 0 Link up" before starting Tinyman. With both E810
# ports userspace-bound, IDEX may remain inside DPDK's link check until the
# Tinyman DPDK application starts its own port.
sleep 3
SERVER_ALIVE="$(remote idex '
    PID="$(cat /tmp/greenquic_p0_server.pid 2>/dev/null || true)"
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then echo yes; else echo no; fi
')"
if [[ "$SERVER_ALIVE" != yes ]]; then
    remote idex 'cat /tmp/greenquic_p0_server.log 2>/dev/null || true'
    fail "P0 server exited before Tinyman client startup"
fi
echo "P0 server process alive: PASS; starting Tinyman client"

set +e
P0_CLIENT_OUTPUT="$(remote tinyman "set -Eeuo pipefail; cd '$P0'; ENABLE_RECORD=1 GQ_LOG_LEVEL=0 ./run_client.sh" 2>&1)"
P0_CLIENT_RC=$?
set -e
printf '%s\n' "$P0_CLIENT_OUTPUT"

IDEX_P0_LOG="$(remote idex 'cat /tmp/greenquic_p0_server.log 2>/dev/null || true')"

remote idex '
    set +e
    PID="$(cat /tmp/greenquic_p0_server.pid 2>/dev/null || true)"
    if [[ -n "$PID" ]]; then
        kill -INT -- "-$PID" 2>/dev/null || true
        for _ in $(seq 1 100); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
        kill -0 "$PID" 2>/dev/null && kill -TERM -- "-$PID" 2>/dev/null || true
        sleep 1
        kill -0 "$PID" 2>/dev/null && kill -KILL -- "-$PID" 2>/dev/null || true
    fi
'

[[ "$P0_CLIENT_RC" == 0 ]] || {
    printf '%s\n' "$IDEX_P0_LOG"
    fail "P0 client returned rc=$P0_CLIENT_RC"
}
printf '%s\n' "$P0_CLIENT_OUTPUT" | grep -q 'P0 PASS: client/server QUIC download works' ||
    fail "P0 client did not print its size/SHA-256 PASS marker"
printf '%s\n' "$IDEX_P0_LOG" | grep -q 'Port 0 Link up' ||
    fail "IDEX DPDK port never reported Link up during P0"
printf '%s\n' "$IDEX_P0_LOG" | grep -q "GET '/small/file_1M.bin'" ||
    fail "IDEX did not receive the P0 1 MiB request"
echo "P0 REAL CLIENT/SERVER QUIC/DPDK TEST: PASS"

###############################################################################
# 10. FINAL P4 READINESS + LAUNCHER
###############################################################################

echo
echo "================================================================"
echo " STEP 10 — FINAL P4 READINESS"
echo "================================================================"

verify_host() {
    local host="$1"
    remote "$host" bash -s <<'VERIFY'
set -Eeuo pipefail
ROOT="/root/mohsen"
PCI="0000:18:00.0"
DRIVER="$(basename "$(readlink -f "/sys/bus/pci/devices/$PCI/driver" 2>/dev/null || true)")"
case "$DRIVER" in igb_uio|vfio-pci) ;; *) echo "ERROR: bad DPDK driver ${DRIVER:-none}" >&2; exit 1 ;; esac
NUMA="$(cat "/sys/bus/pci/devices/$PCI/numa_node")"
[[ "$NUMA" != -1 ]] || NUMA=0
HP="$(cat "/sys/devices/system/node/node${NUMA}/hugepages/hugepages-2048kB/nr_hugepages")"
[[ "$HP" == 16384 ]]
test -x "$ROOT/msquic/build-greenquic/bin/Release/quicinteropserver"
test -x "$ROOT/msquic/build-greenquic/bin/Release/quicinterop"
test -x "$ROOT/msquic/build-greenquic/bin/Release/secnetperf"
P4BIN="$ROOT/msquic/build-greenquic-p4/bin/Release/quicinterop"
test -x "$P4BIN"
grep -aFq 'GreenQUIC-P4-SEQUENCE-V2' "$P4BIN"
grep -aFq 'ready_for_start_gate_us=' "$P4BIN"
python3 -c 'import matplotlib'
echo "HOST=$(hostname) GIT=$(git -C "$ROOT" rev-parse HEAD) DRIVER=$DRIVER HUGEPAGES=$HP P4=V2 MATPLOTLIB=PASS"
VERIFY
}
verify_host idex
verify_host tinyman

remote idex 'bash -s' <<'P4LAUNCHER'
set -Eeuo pipefail
cat > /root/run_p4.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
P4="/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P4_repeated_8GiB_downloads"
cd "$P4"
export CLIENT_HOST="tinyman"
export CLIENT_DIR="/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P4_repeated_8GiB_downloads"
export P4_CLIENT_BIN="/root/mohsen/msquic/build-greenquic-p4/bin/Release/quicinterop"
exec ./run_matrix_from_idex.sh "$@"
EOF
chmod 700 /root/run_p4.sh
/root/run_p4.sh --help >/dev/null
echo "/root/run_p4.sh: PASS"
P4LAUNCHER

IDEX_SHA="$(remote idex 'git -C /root/mohsen rev-parse HEAD')"
TINYMAN_SHA="$(remote tinyman 'git -C /root/mohsen rev-parse HEAD')"
[[ "$IDEX_SHA" == "$EXPECTED_SHA" ]] || fail "IDEX commit differs from selected main"
[[ "$TINYMAN_SHA" == "$EXPECTED_SHA" ]] || fail "Tinyman commit differs from selected main"

echo
echo "################################################################"
echo "### GREENQUIC TUM TESTBED: FULL SUCCESS"
echo "################################################################"
echo "Commit: $EXPECTED_SHA"
echo "Mac -> IDEX: PASS"
echo "Mac -> Tinyman: PASS"
echo "IDEX -> Tinyman: PASS"
echo "E810 physical link: PASS on both before DPDK detach"
echo "Hugepages: 16384 x 2 MiB = 32 GiB on each"
echo "DPDK driver: igb_uio or vfio-pci only"
echo "ICE DDP firmware: PASS"
echo "Matplotlib/report dependencies: PASS"
echo "MSR/P-state: PASS"
echo "GreenQUIC build: PASS"
echo "P4 V2 build: PASS"
echo "P0 1 MiB real QUIC/DPDK transfer + SHA-256: PASS"
echo "P4 READY. Later on IDEX run: /root/run_p4.sh"
echo "################################################################"
