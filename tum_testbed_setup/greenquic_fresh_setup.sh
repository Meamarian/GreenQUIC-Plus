#!/usr/bin/env bash
set -Eeuo pipefail

# GreenQUIC+ final-paper TUM/LRZ fresh-node setup.
# Run this script on the Mac after IDEX and Tinyman have been reimaged with
# Debian Trixie and are reachable through mohsen@coinbase.
#
# This is the only supported TUM setup entrypoint on GreenQUIC-Plus/main.
# It prepares the exact origin/main SHA, both hosts, DPDK, the final P5
# Performance2 V2 build, and the isolated P7 Linux baseline.

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$HERE/.." rev-parse --show-toplevel 2>/dev/null || true)"
BASTION="mohsen@coinbase"
REPO_SSH="git@github.com:Meamarian/GreenQUIC-Plus.git"
ROOT="/root/mohsen"
PCI="0000:18:00.0"
HUGEPAGES_2M="16384"
MAC_KEY="$HOME/.ssh/id_ed25519"
P5_REL="greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
P7_REL="greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline"
PAPER_MARKER='GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0'
SSH_OPTS=(-o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o StrictHostKeyChecking=accept-new)

fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
remote() { local host="$1"; shift; ssh "${SSH_OPTS[@]}" -J "$BASTION" root@"$host" "$@"; }
section() { printf '\n======================================================================\n%s\n======================================================================\n' "$*"; }

[[ -n "$REPO_ROOT" && -d "$REPO_ROOT/.git" ]] || fail "run this script from a GreenQUIC-Plus Git clone"
cd "$REPO_ROOT"
ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
case "$ORIGIN_URL" in
    git@github.com:Meamarian/GreenQUIC-Plus.git|https://github.com/Meamarian/GreenQUIC-Plus.git) ;;
    *) fail "origin must be Meamarian/GreenQUIC-Plus, got: ${ORIGIN_URL:-none}" ;;
esac
for c in git ssh scp base64; do command -v "$c" >/dev/null || fail "$c is required on the Mac"; done

section "STEP 1/10 — RESOLVE EXACT GREENQUIC+ MAIN SHA"
git fetch origin main
EXPECTED_SHA="$(git rev-parse origin/main)"
[[ "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "cannot resolve origin/main"
printf 'Repository: Meamarian/GreenQUIC-Plus (private)\nBranch: main\nSHA: %s\n' "$EXPECTED_SHA"

section "STEP 2/10 — RESTORE MAC SSH ACCESS TO IDEX + TINYMAN"
if [[ ! -f "$MAC_KEY" ]]; then ssh-keygen -q -t ed25519 -f "$MAC_KEY" -N ""; fi
[[ -f "$MAC_KEY.pub" ]] || fail "missing $MAC_KEY.pub"
ssh-add "$MAC_KEY" >/dev/null 2>&1 || { eval "$(ssh-agent -s)" >/dev/null; ssh-add "$MAC_KEY"; }
for h in idex tinyman 172.16.136.1 172.16.139.1; do ssh-keygen -R "$h" >/dev/null 2>&1 || true; done
PUB64="$(base64 < "$MAC_KEY.pub" | tr -d '\n')"
ssh "${SSH_OPTS[@]}" "$BASTION" bash -s -- "$PUB64" <<'COINBASE'
set -Eeuo pipefail
PUB64="$1"
for h in idex tinyman 172.16.136.1 172.16.139.1; do ssh-keygen -R "$h" >/dev/null 2>&1 || true; done
for host in idex tinyman; do
    printf 'Installing Mac public key on %s...\n' "$host"
    printf '%s' "$PUB64" | base64 -d | ssh -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new root@"$host" '
        set -Eeuo pipefail
        mkdir -p /root/.ssh; chmod 700 /root/.ssh
        KEY="$(cat)"; touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys
        grep -qxF "$KEY" /root/.ssh/authorized_keys || printf "%s\n" "$KEY" >> /root/.ssh/authorized_keys
    '
done
COINBASE
for host in idex tinyman; do
    OS_ID="$(remote "$host" '. /etc/os-release; printf "%s" "$ID"')"
    OS_CODENAME="$(remote "$host" '. /etc/os-release; printf "%s" "$VERSION_CODENAME"')"
    [[ "$OS_ID" == debian && "$OS_CODENAME" == trixie ]] || fail "$host must run Debian Trixie; detected ID=$OS_ID VERSION_CODENAME=$OS_CODENAME"
done

section "STEP 3/10 — RESTORE IDEX -> TINYMAN SSH"
IDEX_PUB="$(remote idex '
    set -Eeuo pipefail
    mkdir -p /root/.ssh; chmod 700 /root/.ssh
    if [[ ! -f /root/.ssh/id_ed25519 ]]; then ssh-keygen -q -t ed25519 -f /root/.ssh/id_ed25519 -N ""; fi
    chmod 600 /root/.ssh/id_ed25519; cat /root/.ssh/id_ed25519.pub
' | awk '/^ssh-ed25519 / {print; exit}')"
[[ "$IDEX_PUB" == ssh-ed25519\ * ]] || fail "could not obtain IDEX SSH public key"
IDEX_PUB64="$(printf '%s\n' "$IDEX_PUB" | base64 | tr -d '\n')"
remote tinyman bash -s -- "$IDEX_PUB64" <<'TINYKEY'
set -Eeuo pipefail
KEY="$(printf '%s' "$1" | base64 -d)"
mkdir -p /root/.ssh; chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys
grep -qxF "$KEY" /root/.ssh/authorized_keys || printf '%s\n' "$KEY" >> /root/.ssh/authorized_keys
TINYKEY
remote idex 'ssh-keygen -R tinyman >/dev/null 2>&1 || true; ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new root@tinyman hostname'

section "STEP 4/10 — INSTALL EXACT origin/main ON BOTH NODES WITHOUT REMOTE GITHUB CREDENTIALS"
for host in idex tinyman; do
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
REMOTE_BUNDLE="/tmp/GreenQUIC-Plus-main.bundle"
BUNDLE_REF="refs/heads/__gqplus_setup_${STAMP}"
cleanup() { git update-ref -d "$BUNDLE_REF" >/dev/null 2>&1 || true; rm -f "$LOCAL_BUNDLE"; }
trap cleanup EXIT HUP INT TERM
git update-ref "$BUNDLE_REF" "$EXPECTED_SHA"
git bundle create "$LOCAL_BUNDLE" "$BUNDLE_REF"
git update-ref -d "$BUNDLE_REF"
git bundle verify "$LOCAL_BUNDLE" >/dev/null
scp "${SSH_OPTS[@]}" -o ProxyJump="$BASTION" "$LOCAL_BUNDLE" root@idex:"$REMOTE_BUNDLE"
scp "${SSH_OPTS[@]}" -o ProxyJump="$BASTION" "$LOCAL_BUNDLE" root@tinyman:"$REMOTE_BUNDLE"
for host in idex tinyman; do
    remote "$host" bash -s -- "$EXPECTED_SHA" "$REMOTE_BUNDLE" "$BUNDLE_REF" "$REPO_SSH" <<'CHECKOUT'
set -Eeuo pipefail
SHA="$1"; BUNDLE="$2"; REF="$3"; REPO="$4"; ROOT=/root/mohsen
if [[ -e "$ROOT" && ! -d "$ROOT/.git" ]]; then
    BACKUP="/root/mohsen.before-greenquic-plus-$(date +%Y%m%d_%H%M%S)"; mv "$ROOT" "$BACKUP"; echo "Preserved non-Git $ROOT as $BACKUP"
fi
if [[ ! -d "$ROOT/.git" ]]; then mkdir -p "$ROOT"; git -C "$ROOT" init; fi
cd "$ROOT"; git reset --hard >/dev/null 2>&1 || true
if git remote get-url origin >/dev/null 2>&1; then git remote set-url origin "$REPO"; else git remote add origin "$REPO"; fi
git fetch "$BUNDLE" "$REF"
git checkout -B main FETCH_HEAD
git reset --hard "$SHA"
[[ "$(git rev-parse HEAD)" == "$SHA" && "$(git branch --show-current)" == main ]]
printf 'CHECKOUT READY host=%s branch=main head=%s\n' "$(hostname)" "$(git rev-parse HEAD)"
CHECKOUT
done

section "STEP 5/10 — DEPENDENCIES, ICE FIRMWARE, MSR/P-STATE, HUGEPAGES, DPDK BUILD"
prepare_host() {
    local host="$1"; echo "----- PREPARING $host -----"
    remote "$host" bash -s -- "$PCI" "$HUGEPAGES_2M" <<'HOSTPREP'
set -Eeuo pipefail
PCI="$1"; HUGEPAGES_2M="$2"; ROOT=/root/mohsen
COMMON="$ROOT/greenquic_test_suite_v22/common"
DPDK_SRC="$ROOT/msquic/deps/dpdk"; DPDK_BUILD="$DPDK_SRC/build-greenquic"; DPDK_INSTALL="$ROOT/msquic/deps/dpdk-install"
. /etc/os-release
[[ "$ID" == debian && "$VERSION_CODENAME" == trixie ]] || { echo "ERROR: expected Debian Trixie" >&2; exit 2; }
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
[[ -d "$HPDIR" ]] || { echo "ERROR: 2 MiB hugepages unavailable on NUMA node $NUMA" >&2; exit 3; }
for node in /sys/devices/system/node/node*; do
    f="$node/hugepages/hugepages-1048576kB/nr_hugepages"; [[ -e "$f" ]] && echo 0 > "$f"
    f="$node/hugepages/hugepages-2048kB/nr_hugepages"; [[ -e "$f" ]] && echo 0 > "$f"
done
echo "$HUGEPAGES_2M" > "$HPDIR/nr_hugepages"
[[ "$(cat "$HPDIR/nr_hugepages")" == "$HUGEPAGES_2M" ]] || { echo "ERROR: hugepage allocation failed" >&2; exit 3; }
mkdir -p /mnt/huge
if mountpoint -q /mnt/huge; then
    FSTYPE="$(findmnt -n -o FSTYPE --target /mnt/huge 2>/dev/null || true)"; OPTS="$(findmnt -n -o OPTIONS --target /mnt/huge 2>/dev/null || true)"
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
[[ -n "$DPDK_PC" ]] || { echo "ERROR: DPDK install did not produce libdpdk.pc" >&2; exit 4; }
PKG_CONFIG_PATH="$(dirname "$DPDK_PC")" pkg-config --exists libdpdk
python3 "$COMMON/bin/prepare_assets.py" --common "$COMMON" --create-8g
printf 'HOST PREP PASS host=%s numa=%s hugepages=%s dpdk_pc=%s\n' "$(hostname)" "$NUMA" "$(cat "$HPDIR/nr_hugepages")" "$DPDK_PC"
HOSTPREP
}
prepare_host idex
prepare_host tinyman

section "STEP 6/10 — BUILD + VERIFY FINAL P5 PERFORMANCE2 V2 AND ISOLATED P7"
build_paper_binaries() {
    local host="$1"; echo "----- BUILDING PAPER BINARIES ON $host -----"
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
build_paper_binaries idex
build_paper_binaries tinyman

section "STEP 7/10 — BRING BOTH E810 PEERS UP ON ICE, THEN VERIFY CARRIER"
prepare_link_peer() {
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
[[ -n "$IFACE" ]] || { echo "ERROR: no Linux netdev for $PCI" >&2; exit 1; }
DEFAULT_IF="$(ip route show default | awk 'NR==1 {print $5}')"
[[ "$IFACE" != "$DEFAULT_IF" ]] || { echo "ERROR: test NIC is the default-route interface" >&2; exit 1; }
ip link set dev "$IFACE" up
printf 'LINK PEER PREPARED host=%s iface=%s driver=ice\n' "$(hostname)" "$IFACE"
LINKPREP
}
prepare_link_peer idex
prepare_link_peer tinyman
sleep 2
verify_link() {
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
verify_link idex
verify_link tinyman

section "STEP 8/10 — BIND BOTH TEST PORTS TO APPROVED DPDK DRIVER"
bind_dpdk() {
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
bind_dpdk idex
bind_dpdk tinyman
remote idex 'ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman true'

section "STEP 9/10 — INSTALL SIMPLE P5/P7 LAUNCHERS AND FINAL VERIFY"
remote idex bash -s -- "$P5_REL" "$P7_REL" <<'LAUNCHERS'
set -Eeuo pipefail
P5_REL="$1"; P7_REL="$2"
cat > /root/run_p5.sh <<EOF_P5
#!/usr/bin/env bash
set -Eeuo pipefail
P5=/root/mohsen/$P5_REL
cd "\$P5"
exec ./run_matrix_with_sheet.sh --client-host tinyman --client-dir "\$P5" --client-bin /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop "\$@"
EOF_P5
cat > /root/run_p7.sh <<EOF_P7
#!/usr/bin/env bash
set -Eeuo pipefail
P7=/root/mohsen/$P7_REL
cd "\$P7"
exec ./run_matrix_with_report.sh --client-host tinyman --client-dir "\$P7" "\$@"
EOF_P7
chmod 700 /root/run_p5.sh /root/run_p7.sh
/root/run_p5.sh --help >/dev/null; /root/run_p7.sh --help >/dev/null
LAUNCHERS
for host in idex tinyman; do
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
IDEX_SHA="$(remote idex 'git -C /root/mohsen rev-parse HEAD')"; TINYMAN_SHA="$(remote tinyman 'git -C /root/mohsen rev-parse HEAD')"
[[ "$IDEX_SHA" == "$EXPECTED_SHA" && "$TINYMAN_SHA" == "$EXPECTED_SHA" ]] || fail "final node SHA mismatch"

section "STEP 10/10 — GREENQUIC+ PAPER TESTBED READY"
printf 'GREENQUIC+ MAIN READY ON BOTH TUM NODES\nrepository: Meamarian/GreenQUIC-Plus (private)\nbranch: main\ncommit: %s\n' "$EXPECTED_SHA"
printf 'P5: Performance2 V2, txalloc=8, txenqcounter=0, txmetazero=1, rxpipe=2, shardmask=0\n'
printf 'paper runtime: ENABLE_MULTICORE=0; DPDK owner CPU19; QUIC CPUs21-24\n'
printf 'P7: isolated normal-Linux MsQuic baseline\nE810: link verified before DPDK binding; final driver igb_uio or vfio-pci\n'
printf 'hugepages: 16384 x 2 MiB on the E810 NUMA node\nacpi.sh + msr.py: present\n'

cat <<'NEXT'

FINAL PAPER FAIR REPRODUCTION FROM THE MAC:

cd ~/Downloads/GreenQUIC-Plus && \
git fetch origin main && \
git checkout main && \
git reset --hard origin/main && \
bash greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_p7_fair_repro_6x5_v3.sh

LIVE MONITOR FROM ANOTHER MAC TERMINAL:

ssh idex '
log=$(find /root -maxdepth 1 -type f -name "GQ_FAIR_REPRO_*.log" -printf "%T@ %p\n" 2>/dev/null | sort -nr | sed -n "1p" | cut -d" " -f2-)
echo "FOLLOWING: $log"; echo
if [ -z "$log" ]; then echo "No GQ_FAIR_REPRO log found yet"; else tail -n +1 -F "$log"; fi
'
NEXT
