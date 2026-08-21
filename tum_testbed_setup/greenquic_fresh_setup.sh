#!/usr/bin/env bash
set -Eeuo pipefail

# GreenQUIC+ final-paper TUM/LRZ provisioning/build setup.
# RUN ON: control host (Mac in our paper setup; another Unix control host is OK).
# The host names idex/tinyman are paper-testbed defaults only. The semantic roles
# are SERVER (QUIC server + experiment controller) and CLIENT (QUIC client).

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$HERE/.." rev-parse --show-toplevel 2>/dev/null || true)"
REPO_SSH="git@github.com:Meamarian/GreenQUIC-Plus.git"
ROOT=/root/mohsen
PCI=0000:18:00.0
HUGEPAGES_2M=16384
P5_REL="greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
P7_REL="greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline"
PAPER_MARKER='GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0'

# Paper-testbed defaults. Change them with switches; do not edit the script.
SERVER_HOST="${GQ_SERVER_HOST:-idex}"
CLIENT_HOST="${GQ_CLIENT_HOST:-tinyman}"
SERVER_TO_CLIENT_HOST="${GQ_SERVER_TO_CLIENT_HOST:-}"
BASTION="${GQ_BASTION:-mohsen@coinbase}"
CONTROL_KEY="${GQ_SSH_KEY:-$HOME/.ssh/id_ed25519}"

usage() {
    cat <<'USAGE'
GreenQUIC+ fresh-node / fresh-deployment setup

RUN ON: control host (Mac in our paper setup)

Required roles:
  SERVER = QUIC server and experiment controller
  CLIENT = QUIC client

Host/SSH switches:
  --server-host HOST              server endpoint as seen from control/bastion
                                  (paper default: idex)
  --client-host HOST              client endpoint as seen from control/bastion
                                  (paper default: tinyman)
  --server-to-client-host HOST    client endpoint/name as seen from SERVER;
                                  defaults to --client-host
  --bastion USER@HOST             ProxyJump/bootstrap bastion
                                  (paper default: mohsen@coinbase)
  --bastion none                  direct control-host -> nodes SSH
  --ssh-key PATH                  control-host private key installed/used on nodes
                                  (default: ~/.ssh/id_ed25519)
  -h, --help

SSH topology for setup:
  control host -> bastion: required only when --bastion is used
  bastion -> SERVER and CLIENT: required during fresh-node bootstrap
  control host -> SERVER and CLIENT: required after key bootstrap (direct or via bastion)
  SERVER -> CLIENT: required; this script installs/tests a dedicated server key
  CLIENT -> SERVER: not required

GitHub access:
  Only the control host needs access to the private GreenQUIC-Plus repository.
  SERVER and CLIENT receive the exact origin/main SHA by Git bundle and do not
  need GitHub credentials.

The setup requires root SSH on both experiment nodes because it installs packages,
configures hugepages/MSR/PCI drivers, and writes under /root.
USAGE
}

fail(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }
section(){ printf '\n======================================================================\n%s\n======================================================================\n' "$*"; }
need_arg(){ [[ $# -ge 2 && -n "$2" ]] || fail "$1 needs a value"; }
while (($#)); do
    case "$1" in
        --server-host) need_arg "$@"; SERVER_HOST="$2"; shift 2 ;;
        --client-host) need_arg "$@"; CLIENT_HOST="$2"; shift 2 ;;
        --server-to-client-host) need_arg "$@"; SERVER_TO_CLIENT_HOST="$2"; shift 2 ;;
        --bastion) need_arg "$@"; BASTION="$2"; shift 2 ;;
        --ssh-key) need_arg "$@"; CONTROL_KEY="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) fail "unknown argument: $1 (use --help)" ;;
    esac
done
SERVER_TO_CLIENT_HOST="${SERVER_TO_CLIENT_HOST:-$CLIENT_HOST}"
[[ "$SERVER_HOST" != "$CLIENT_HOST" ]] || fail "server and client hosts must differ"

[[ -n "$REPO_ROOT" && -d "$REPO_ROOT/.git" ]] || fail "run this from a GreenQUIC-Plus Git clone on the control host"
cd "$REPO_ROOT"
ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
case "$ORIGIN_URL" in
    git@github.com:Meamarian/GreenQUIC-Plus.git|https://github.com/Meamarian/GreenQUIC-Plus.git) ;;
    *) fail "origin must be Meamarian/GreenQUIC-Plus, got: ${ORIGIN_URL:-none}" ;;
esac
for c in git ssh scp base64 ssh-keygen; do command -v "$c" >/dev/null || fail "$c is required on the control host"; done

mkdir -p "$(dirname "$CONTROL_KEY")"
if [[ ! -f "$CONTROL_KEY" ]]; then
    echo "Creating control-host node key: $CONTROL_KEY"
    ssh-keygen -q -t ed25519 -f "$CONTROL_KEY" -N ""
fi
[[ -f "$CONTROL_KEY.pub" ]] || fail "missing public key: $CONTROL_KEY.pub"
chmod 600 "$CONTROL_KEY" 2>/dev/null || true

SSH_OPTS=(-o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o StrictHostKeyChecking=accept-new -i "$CONTROL_KEY")
JUMP_OPTS=()
if [[ -n "$BASTION" && "$BASTION" != none ]]; then JUMP_OPTS=(-J "$BASTION"); fi
remote(){ local host="$1"; shift; ssh "${SSH_OPTS[@]}" "${JUMP_OPTS[@]}" root@"$host" "$@"; }
copy_to(){ local src="$1" host="$2" dst="$3"; scp "${SSH_OPTS[@]}" "${JUMP_OPTS[@]}" "$src" root@"$host":"$dst"; }

section "STEP 1/10 — RESOLVE EXACT GREENQUIC+ main SHA ON CONTROL HOST"
# Explicit refspec works even when this clone was originally --single-branch.
git fetch origin '+refs/heads/main:refs/remotes/origin/main'
EXPECTED_SHA="$(git rev-parse refs/remotes/origin/main)"
[[ "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "cannot resolve origin/main"
printf 'RUN ON: control host\nRepository: Meamarian/GreenQUIC-Plus (private)\nBranch: main\nSHA: %s\nSERVER role: %s\nCLIENT role: %s\nSERVER->CLIENT name: %s\nBastion: %s\n' \
    "$EXPECTED_SHA" "$SERVER_HOST" "$CLIENT_HOST" "$SERVER_TO_CLIENT_HOST" "${BASTION:-none}"

section "STEP 2/10 — ESTABLISH CONTROL-HOST SSH TO SERVER + CLIENT"
PUB64="$(base64 < "$CONTROL_KEY.pub" | tr -d '\n')"
ssh-keygen -R "$SERVER_HOST" >/dev/null 2>&1 || true
ssh-keygen -R "$CLIENT_HOST" >/dev/null 2>&1 || true

if [[ -n "$BASTION" && "$BASTION" != none ]]; then
    echo "Bootstrap path: control host -> $BASTION -> SERVER/CLIENT"
    # The control host must already be able to authenticate to the bastion.
    ssh -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new "$BASTION" bash -s -- \
        "$PUB64" "$SERVER_HOST" "$CLIENT_HOST" <<'BOOTSTRAP'
set -Eeuo pipefail
PUB64="$1"; SERVER_HOST="$2"; CLIENT_HOST="$3"
for host in "$SERVER_HOST" "$CLIENT_HOST"; do
    ssh-keygen -R "$host" >/dev/null 2>&1 || true
    printf 'Installing control-host public key on %s...\n' "$host"
    printf '%s' "$PUB64" | base64 -d | ssh -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new root@"$host" '
        set -Eeuo pipefail
        mkdir -p /root/.ssh; chmod 700 /root/.ssh
        KEY="$(cat)"
        touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys
        grep -qxF "$KEY" /root/.ssh/authorized_keys || printf "%s\n" "$KEY" >> /root/.ssh/authorized_keys
    '
done
BOOTSTRAP
else
    echo "Direct mode: control host must already be authorized as root on both nodes."
fi

for host in "$SERVER_HOST" "$CLIENT_HOST"; do
    remote "$host" 'hostname; . /etc/os-release; printf "OS=%s %s\n" "$ID" "$VERSION_CODENAME"'
    OS_ID="$(remote "$host" '. /etc/os-release; printf "%s" "$ID"')"
    OS_CODENAME="$(remote "$host" '. /etc/os-release; printf "%s" "$VERSION_CODENAME"')"
    [[ "$OS_ID" == debian && "$OS_CODENAME" == trixie ]] || fail "$host must run Debian Trixie; found $OS_ID/$OS_CODENAME"
done

section "STEP 3/10 — ESTABLISH SERVER-ROLE -> CLIENT-ROLE SSH"
SERVER_PUB="$(remote "$SERVER_HOST" '
    set -Eeuo pipefail
    mkdir -p /root/.ssh; chmod 700 /root/.ssh
    if [[ ! -f /root/.ssh/id_ed25519 ]]; then ssh-keygen -q -t ed25519 -f /root/.ssh/id_ed25519 -N ""; fi
    chmod 600 /root/.ssh/id_ed25519
    cat /root/.ssh/id_ed25519.pub
' | awk '/^ssh-ed25519 / {print; exit}')"
[[ "$SERVER_PUB" == ssh-ed25519\ * ]] || fail "could not obtain SERVER public key"
SERVER_PUB64="$(printf '%s\n' "$SERVER_PUB" | base64 | tr -d '\n')"
remote "$CLIENT_HOST" bash -s -- "$SERVER_PUB64" <<'CLIENTKEY'
set -Eeuo pipefail
KEY="$(printf '%s' "$1" | base64 -d)"
mkdir -p /root/.ssh; chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys
grep -qxF "$KEY" /root/.ssh/authorized_keys || printf '%s\n' "$KEY" >> /root/.ssh/authorized_keys
CLIENTKEY
remote "$SERVER_HOST" bash -s -- "$SERVER_TO_CLIENT_HOST" <<'SERVERSSH'
set -Eeuo pipefail
CLIENT="$1"
ssh-keygen -R "$CLIENT" >/dev/null 2>&1 || true
ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new root@"$CLIENT" 'echo SERVER_TO_CLIENT_SSH_PASS; hostname'
SERVERSSH

section "STEP 4/10 — INSTALL EXACT main SHA ON BOTH NODES WITHOUT GITHUB CREDENTIALS"
for host in "$SERVER_HOST" "$CLIENT_HOST"; do
    remote "$host" '
        set -Eeuo pipefail
        if ! command -v git >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get -y --no-install-recommends --no-remove --no-upgrade install git ca-certificates
        fi
    '
done
STAMP="$(date +%Y%m%d_%H%M%S)_$$"
LOCAL_BUNDLE="${TMPDIR:-/tmp}/GreenQUIC-Plus-main-${STAMP}.bundle"
REMOTE_BUNDLE=/tmp/GreenQUIC-Plus-main.bundle
BUNDLE_REF="refs/heads/__gqplus_setup_${STAMP}"
cleanup(){ git update-ref -d "$BUNDLE_REF" >/dev/null 2>&1 || true; rm -f "$LOCAL_BUNDLE"; }
trap cleanup EXIT HUP INT TERM
git update-ref "$BUNDLE_REF" "$EXPECTED_SHA"
git bundle create "$LOCAL_BUNDLE" "$BUNDLE_REF"
git update-ref -d "$BUNDLE_REF"
git bundle verify "$LOCAL_BUNDLE" >/dev/null
copy_to "$LOCAL_BUNDLE" "$SERVER_HOST" "$REMOTE_BUNDLE"
copy_to "$LOCAL_BUNDLE" "$CLIENT_HOST" "$REMOTE_BUNDLE"
for host in "$SERVER_HOST" "$CLIENT_HOST"; do
    remote "$host" bash -s -- "$EXPECTED_SHA" "$REMOTE_BUNDLE" "$BUNDLE_REF" "$REPO_SSH" <<'CHECKOUT'
set -Eeuo pipefail
SHA="$1"; BUNDLE="$2"; REF="$3"; REPO="$4"; ROOT=/root/mohsen
if [[ -e "$ROOT" && ! -d "$ROOT/.git" ]]; then
    BACKUP="/root/mohsen.before-greenquic-plus-$(date +%Y%m%d_%H%M%S)"
    mv "$ROOT" "$BACKUP"
    echo "Preserved non-Git $ROOT as $BACKUP"
fi
if [[ ! -d "$ROOT/.git" ]]; then mkdir -p "$ROOT"; git -C "$ROOT" init; fi
cd "$ROOT"
git reset --hard >/dev/null 2>&1 || true
if git remote get-url origin >/dev/null 2>&1; then git remote set-url origin "$REPO"; else git remote add origin "$REPO"; fi
git fetch "$BUNDLE" "$REF"
git checkout -B main FETCH_HEAD
git reset --hard "$SHA"
[[ "$(git rev-parse HEAD)" == "$SHA" && "$(git branch --show-current)" == main ]]
printf 'CHECKOUT READY host=%s branch=main head=%s\n' "$(hostname)" "$(git rev-parse HEAD)"
CHECKOUT
done

section "STEP 5/10 — DEPENDENCIES, ICE FIRMWARE, MSR/P-STATE, HUGEPAGES, DPDK"
prepare_host(){
    local host="$1"
    echo "----- PREPARING ROLE HOST $host -----"
    remote "$host" bash -s -- "$PCI" "$HUGEPAGES_2M" <<'HOSTPREP'
set -Eeuo pipefail
PCI="$1"; HUGEPAGES_2M="$2"; ROOT=/root/mohsen
COMMON="$ROOT/greenquic_test_suite_v22/common"
DPDK_SRC="$ROOT/msquic/deps/dpdk"; DPDK_BUILD="$DPDK_SRC/build-greenquic"; DPDK_INSTALL="$ROOT/msquic/deps/dpdk-install"
. /etc/os-release
[[ "$ID" == debian && "$VERSION_CODENAME" == trixie ]]
export DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none
apt-get update
apt-get -y --no-install-recommends --no-remove --no-upgrade install \
    ca-certificates openssh-client git curl wget file unzip xz-utils tar patch zip \
    build-essential gcc g++ make cmake meson ninja-build pkg-config \
    python3 python3-dev python3-pyelftools python3-setuptools python3-wheel \
    python3-matplotlib python3-numpy perl m4 nasm autoconf automake libtool flex bison \
    libnuma-dev libssl-dev libelf-dev libpcap-dev libarchive-dev \
    libnl-3-dev libnl-route-3-dev libnl-genl-3-dev zlib1g-dev libzstd-dev \
    libbsd-dev libudev-dev pciutils ethtool numactl hwloc rsync iproute2 \
    kmod procps util-linux msr-tools lm-sensors irqbalance
bash "$COMMON/bin/ensure_test_python_deps.sh"
bash "$COMMON/bin/ensure_ice_firmware.sh" "$PCI"
modprobe msr
bash "$COMMON/bin/check_msr_pstate.sh" 19

test -e "/sys/bus/pci/devices/$PCI"
NUMA="$(cat "/sys/bus/pci/devices/$PCI/numa_node")"; [[ "$NUMA" != -1 ]] || NUMA=0
HPDIR="/sys/devices/system/node/node${NUMA}/hugepages/hugepages-2048kB"
[[ -d "$HPDIR" ]]
for node in /sys/devices/system/node/node*; do
    f="$node/hugepages/hugepages-1048576kB/nr_hugepages"; [[ -e "$f" ]] && echo 0 > "$f"
    f="$node/hugepages/hugepages-2048kB/nr_hugepages"; [[ -e "$f" ]] && echo 0 > "$f"
done
echo "$HUGEPAGES_2M" > "$HPDIR/nr_hugepages"
[[ "$(cat "$HPDIR/nr_hugepages")" == "$HUGEPAGES_2M" ]]
mkdir -p /mnt/huge
if mountpoint -q /mnt/huge; then
    FSTYPE="$(findmnt -n -o FSTYPE --target /mnt/huge 2>/dev/null || true)"
    OPTS="$(findmnt -n -o OPTIONS --target /mnt/huge 2>/dev/null || true)"
    if [[ "$FSTYPE" != hugetlbfs || "$OPTS" != *pagesize=2M* ]]; then umount /mnt/huge; mount -t hugetlbfs -o pagesize=2M none /mnt/huge; fi
else
    mount -t hugetlbfs -o pagesize=2M none /mnt/huge
fi
findmnt -n -t hugetlbfs /mnt/huge >/dev/null

test -f "$DPDK_SRC/meson.build"
rm -rf "$DPDK_BUILD" "$DPDK_INSTALL"; mkdir -p "$DPDK_BUILD" "$DPDK_INSTALL"
meson setup "$DPDK_BUILD" "$DPDK_SRC" --prefix "$DPDK_INSTALL" --libdir lib -Dbuildtype=release -Ddefault_library=static
meson compile -C "$DPDK_BUILD" -j "$(nproc)"
meson install -C "$DPDK_BUILD"
DPDK_PC="$(find "$DPDK_INSTALL" -type f -name libdpdk.pc -print -quit)"
[[ -n "$DPDK_PC" ]]
PKG_CONFIG_PATH="$(dirname "$DPDK_PC")" pkg-config --exists libdpdk
python3 "$COMMON/bin/prepare_assets.py" --common "$COMMON" --create-8g
printf 'HOST PREP PASS host=%s numa=%s hugepages=%s dpdk_pc=%s\n' "$(hostname)" "$NUMA" "$(cat "$HPDIR/nr_hugepages")" "$DPDK_PC"
HOSTPREP
}
prepare_host "$SERVER_HOST"
prepare_host "$CLIENT_HOST"

section "STEP 6/10 — BUILD + VERIFY P5 PERFORMANCE2 V2 AND ISOLATED P7"
build_paper_binaries(){
    local host="$1"
    echo "----- BUILDING PAPER BINARIES ON $host -----"
    remote "$host" bash -s -- "$EXPECTED_SHA" "$P5_REL" "$P7_REL" "$PAPER_MARKER" <<'BUILD'
set -Eeuo pipefail
EXPECTED="$1"; P5_REL="$2"; P7_REL="$3"; PAPER_MARKER="$4"; ROOT=/root/mohsen
P5="$ROOT/$P5_REL"; P7="$ROOT/$P7_REL"
[[ "$(git -C "$ROOT" rev-parse HEAD)" == "$EXPECTED" && "$(git -C "$ROOT" branch --show-current)" == main ]]
chmod 0755 "$P5"/*.sh "$P7"/*.sh 2>/dev/null || true
P5_BUILD_REUSE=1 bash "$P5/build_p5_performance2.sh"
P5C="$ROOT/msquic/build-greenquic-p5/bin/Release/quicinterop"; P5S="$ROOT/msquic/build-greenquic-p5/bin/Release/quicinteropserver"
test -x "$P5C"; test -x "$P5S"
for marker in 'GreenQUIC-P5-SEQUENCE-V2' 'GREENQUIC-P5-SUPER-PERF-V2' 'GREENQUIC-P5-PERFORMANCE2-V1' 'GREENQUIC-P5-PERFORMANCE2-V2'; do grep -aFq -- "$marker" "$P5C"; done
grep -aFq -- "$PAPER_MARKER" "$P5C"; grep -aFq -- "$PAPER_MARKER" "$P5S"
P5C_SHA="$(sha256sum "$P5C" | awk '{print $1}')"; P5S_SHA="$(sha256sum "$P5S" | awk '{print $1}')"
bash "$P7/build_p7_linux.sh"
P7C="$ROOT/msquic/build-linux-p7/bin/Release/quicinterop"; P7S="$ROOT/msquic/build-linux-p7/bin/Release/quicinteropserver"
test -x "$P7C"; test -x "$P7S"
if ldd "$P7C" 2>/dev/null | grep -qi dpdk || ldd "$P7S" 2>/dev/null | grep -qi dpdk; then echo "ERROR: P7 unexpectedly links DPDK" >&2; exit 5; fi
[[ "$(sha256sum "$P5C" | awk '{print $1}')" == "$P5C_SHA" && "$(sha256sum "$P5S" | awk '{print $1}')" == "$P5S_SHA" ]]
python3 -c 'import matplotlib, numpy'
test -x "$ROOT/acpi.sh"; test -f "$ROOT/msr.py"
printf 'PAPER BUILD PASS host=%s head=%s\nP5 marker: %s\n' "$(hostname)" "$(git -C "$ROOT" rev-parse HEAD)" "$PAPER_MARKER"
sha256sum "$P5C" "$P5S" "$P7C" "$P7S"
BUILD
}
build_paper_binaries "$SERVER_HOST"
build_paper_binaries "$CLIENT_HOST"

section "STEP 7/10 — BRING BOTH E810 PEERS UP ON ICE AND VERIFY CARRIER"
prepare_link_peer(){
    local host="$1"
    remote "$host" bash -s -- "$PCI" <<'LINKPREP'
set -Eeuo pipefail
PCI="$1"; DEVBIND=/root/mohsen/msquic/deps/dpdk/usertools/dpdk-devbind.py
modprobe ice; test -f "$DEVBIND"
CURRENT="$(basename "$(readlink -f "/sys/bus/pci/devices/$PCI/driver" 2>/dev/null || true)")"
if [[ -n "$CURRENT" && "$CURRENT" != ice ]]; then python3 "$DEVBIND" --unbind "$PCI"; sleep 1; fi
CURRENT="$(basename "$(readlink -f "/sys/bus/pci/devices/$PCI/driver" 2>/dev/null || true)")"
if [[ "$CURRENT" != ice ]]; then python3 "$DEVBIND" --bind=ice "$PCI"; fi
IFACE="$(find "/sys/bus/pci/devices/$PCI/net" -mindepth 1 -maxdepth 1 -printf '%f\n' | head -n1)"
[[ -n "$IFACE" ]]
DEFAULT_IF="$(ip route show default | awk 'NR==1 {print $5}')"
[[ "$IFACE" != "$DEFAULT_IF" ]] || { echo "ERROR: test NIC is default-route interface" >&2; exit 1; }
ip link set dev "$IFACE" up
printf 'LINK PEER PREPARED host=%s iface=%s driver=ice\n' "$(hostname)" "$IFACE"
LINKPREP
}
verify_link(){
    local host="$1"
    remote "$host" bash -s -- "$PCI" <<'LINKVERIFY'
set -Eeuo pipefail
PCI="$1"; IFACE="$(find "/sys/bus/pci/devices/$PCI/net" -mindepth 1 -maxdepth 1 -printf '%f\n' | head -n1)"; [[ -n "$IFACE" ]]
CARRIER=0; OPERSTATE=unknown; ETHTOOL_LINK=unknown
for _ in $(seq 1 20); do
    CARRIER="$(cat "/sys/class/net/$IFACE/carrier" 2>/dev/null || echo 0)"
    OPERSTATE="$(cat "/sys/class/net/$IFACE/operstate" 2>/dev/null || echo unknown)"
    ETHTOOL_LINK="$(ethtool "$IFACE" 2>/dev/null | awk -F': ' '/Link detected:/ {print $2; exit}')"
    [[ "$CARRIER" == 1 && "$OPERSTATE" == up && "$ETHTOOL_LINK" == yes ]] && break
    sleep 1
done
printf 'LINK host=%s iface=%s carrier=%s operstate=%s ethtool=%s\n' "$(hostname)" "$IFACE" "$CARRIER" "$OPERSTATE" "$ETHTOOL_LINK"
[[ "$CARRIER" == 1 && "$OPERSTATE" == up && "$ETHTOOL_LINK" == yes ]]
LINKVERIFY
}
prepare_link_peer "$SERVER_HOST"
prepare_link_peer "$CLIENT_HOST"
sleep 2
verify_link "$SERVER_HOST"
verify_link "$CLIENT_HOST"

section "STEP 8/10 — BIND BOTH TEST PORTS TO APPROVED DPDK DRIVER"
bind_dpdk(){
    local host="$1"
    remote "$host" bash -s -- "$PCI" <<'BIND'
set -Eeuo pipefail
PCI="$1"; DEVBIND=/root/mohsen/msquic/deps/dpdk/usertools/dpdk-devbind.py
IFACE="$(find "/sys/bus/pci/devices/$PCI/net" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | head -n1 || true)"; [[ -z "$IFACE" ]] || ip link set dev "$IFACE" down
TARGET=""; modprobe uio 2>/dev/null || true
if [[ -d /sys/module/igb_uio ]] || modprobe igb_uio 2>/dev/null; then if python3 "$DEVBIND" --bind=igb_uio "$PCI"; then TARGET=igb_uio; fi; fi
if [[ -z "$TARGET" ]]; then modprobe vfio-pci; python3 "$DEVBIND" --bind=vfio-pci "$PCI"; TARGET=vfio-pci; fi
ACTUAL="$(basename "$(readlink -f "/sys/bus/pci/devices/$PCI/driver" 2>/dev/null || true)")"
case "$ACTUAL" in igb_uio|vfio-pci) ;; *) echo "ERROR: unacceptable DPDK driver ${ACTUAL:-none}" >&2; exit 1;; esac
[[ "$ACTUAL" == "$TARGET" ]]
printf 'DPDK BIND PASS host=%s pci=%s driver=%s\n' "$(hostname)" "$PCI" "$ACTUAL"
BIND
}
bind_dpdk "$SERVER_HOST"
bind_dpdk "$CLIENT_HOST"
remote "$SERVER_HOST" bash -s -- "$SERVER_TO_CLIENT_HOST" <<'SSHCHECK'
set -Eeuo pipefail
ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new root@"$1" true
SSHCHECK

section "STEP 9/10 — INSTALL SERVER-ROLE CONVENIENCE LAUNCHERS + FINAL VERIFY"
remote "$SERVER_HOST" bash -s -- "$P5_REL" "$P7_REL" "$SERVER_TO_CLIENT_HOST" <<'LAUNCHERS'
set -Eeuo pipefail
P5_REL="$1"; P7_REL="$2"; CLIENT_HOST="$3"
cat > /root/run_p5.sh <<EOF_P5
#!/usr/bin/env bash
set -Eeuo pipefail
P5=/root/mohsen/$P5_REL
cd "\$P5"
exec ./run_matrix_with_sheet.sh --client-host "$CLIENT_HOST" --client-dir "\$P5" --client-bin /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop "\$@"
EOF_P5
cat > /root/run_p7.sh <<EOF_P7
#!/usr/bin/env bash
set -Eeuo pipefail
P7=/root/mohsen/$P7_REL
cd "\$P7"
exec ./run_matrix_with_report.sh --client-host "$CLIENT_HOST" --client-dir "\$P7" "\$@"
EOF_P7
chmod 700 /root/run_p5.sh /root/run_p7.sh
/root/run_p5.sh --help >/dev/null; /root/run_p7.sh --help >/dev/null
LAUNCHERS

for host in "$SERVER_HOST" "$CLIENT_HOST"; do
    remote "$host" bash -s -- "$EXPECTED_SHA" "$PCI" "$HUGEPAGES_2M" "$PAPER_MARKER" <<'FINALVERIFY'
set -Eeuo pipefail
EXPECTED="$1"; PCI="$2"; HUGEPAGES_2M="$3"; PAPER_MARKER="$4"; ROOT=/root/mohsen
[[ "$(git -C "$ROOT" rev-parse HEAD)" == "$EXPECTED" && "$(git -C "$ROOT" branch --show-current)" == main ]]
DRIVER="$(basename "$(readlink -f "/sys/bus/pci/devices/$PCI/driver" 2>/dev/null || true)")"; case "$DRIVER" in igb_uio|vfio-pci) ;; *) exit 1;; esac
NUMA="$(cat "/sys/bus/pci/devices/$PCI/numa_node")"; [[ "$NUMA" != -1 ]] || NUMA=0
HP="$(cat "/sys/devices/system/node/node${NUMA}/hugepages/hugepages-2048kB/nr_hugepages")"; [[ "$HP" == "$HUGEPAGES_2M" ]]
P5C="$ROOT/msquic/build-greenquic-p5/bin/Release/quicinterop"; P5S="$ROOT/msquic/build-greenquic-p5/bin/Release/quicinteropserver"
P7C="$ROOT/msquic/build-linux-p7/bin/Release/quicinterop"; P7S="$ROOT/msquic/build-linux-p7/bin/Release/quicinteropserver"
for f in "$P5C" "$P5S" "$P7C" "$P7S"; do test -x "$f"; done
grep -aFq -- "$PAPER_MARKER" "$P5C"; grep -aFq -- "$PAPER_MARKER" "$P5S"
if ldd "$P7C" 2>/dev/null | grep -qi dpdk || ldd "$P7S" 2>/dev/null | grep -qi dpdk; then exit 2; fi
command -v sensors >/dev/null; python3 -c 'import matplotlib, numpy'; test -x "$ROOT/acpi.sh"; test -f "$ROOT/msr.py"
printf 'FINAL VERIFY PASS host=%s head=%s driver=%s hugepages=%s\n' "$(hostname)" "$(git -C "$ROOT" rev-parse HEAD)" "$DRIVER" "$HP"
FINALVERIFY
done
SERVER_SHA="$(remote "$SERVER_HOST" 'git -C /root/mohsen rev-parse HEAD')"
CLIENT_SHA="$(remote "$CLIENT_HOST" 'git -C /root/mohsen rev-parse HEAD')"
[[ "$SERVER_SHA" == "$EXPECTED_SHA" && "$CLIENT_SHA" == "$EXPECTED_SHA" ]] || fail "final node SHA mismatch"

section "STEP 10/10 — GREENQUIC+ PAPER TESTBED READY"
printf 'GREENQUIC+ MAIN READY\nrepository: Meamarian/GreenQUIC-Plus (private)\nbranch: main\ncommit: %s\n' "$EXPECTED_SHA"
printf 'SERVER role host: %s\nCLIENT role host: %s\nSERVER->CLIENT host: %s\n' "$SERVER_HOST" "$CLIENT_HOST" "$SERVER_TO_CLIENT_HOST"
printf 'P5 binaries: /root/mohsen/msquic/build-greenquic-p5/bin/Release/{quicinterop,quicinteropserver}\n'
printf 'P7 binaries: /root/mohsen/msquic/build-linux-p7/bin/Release/{quicinterop,quicinteropserver}\n'
printf 'P5: Performance2 V2; ENABLE_MULTICORE=0; DPDK CPU19; QUIC CPUs21-24\n'
printf 'P7: isolated normal-Linux MsQuic baseline\n'
printf 'SSH verified: control->SERVER, control->CLIENT, SERVER->CLIENT. CLIENT->SERVER is not required.\n'

cat <<NEXT

NEXT STEP — RUN ON THE CONTROL HOST:

bash greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_p7_fair_repro_6x5.sh \\
  --server-host '$SERVER_HOST' \\
  --client-host '$SERVER_TO_CLIENT_HOST' \\
  --bastion '${BASTION:-none}' \\
  --ssh-key '$CONTROL_KEY'

RUN THE LIVE MONITOR FROM A SECOND CONTROL-HOST TERMINAL using the same SSH route.
See results_analysis/README.md for the exact monitor command and all start-state workflows.
NEXT
