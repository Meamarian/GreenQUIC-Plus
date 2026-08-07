#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "\nERROR: bootstrap failed at line %s.\n" "$LINENO" >&2' ERR

INSTALL_DEPS=1
REBUILD=0
JOBS="$(nproc 2>/dev/null || echo 1)"
DPDK_PCI=""
LOCAL_IP=""
PEER_MAC=""
LCORES=""
BIND_DPDK=0
DPDK_BIND_DRIVER="auto"
HUGEPAGES_2M=""
HUGEPAGE_MOUNT="/mnt/huge"
BOUND_DPDK_DRIVER=""
HUGEPAGE_NUMA_NODE=""
ICE_FIRMWARE=1
ICE_FIRMWARE_PACKAGE="firmware-intel-misc"
ICE_FIRMWARE_PATH=""
ICE_FIRMWARE_STATUS="pending"

usage() {
    cat <<'EOF_USAGE'
Usage:
  ./bootstrap_greenquic.sh [options]

Options:
  --install-deps       Install missing Debian build packages (default; kept for compatibility)
  --skip-deps          Skip apt dependency installation/check only when intentionally requested
  --rebuild            Delete only generated build/install directories and rebuild them
  --jobs N             Parallel build jobs (default: nproc)
  --pci BDF            DPDK PCI device, for example 0000:18:00.0
  --local-ip IPv4      Logical local DPDK IPv4 address, for example 192.168.100.1
  --peer-mac MAC       Peer DPDK-port MAC address
  --lcores LIST        DPDK EAL lcore list, for example 8 or 8,9
  --hugepages N        Allocate N x 2 MiB hugepages on the DPDK PCI NUMA node
                       (example: 16384 = 32 GiB); also mounts /mnt/huge as 2 MiB hugetlbfs
  --bind-dpdk          Bind --pci to a DPDK userspace driver after all builds finish
  --dpdk-driver NAME   Driver for --bind-dpdk: auto, igb_uio, uio_pci_generic, or vfio-pci
                       (default: auto; prefer igb_uio, fall back to uio_pci_generic)
  --ice-firmware       Ensure Intel ICE/E810 DDP firmware is installed (default)
  --skip-ice-firmware  Do not check/install Intel ICE DDP firmware
  -h, --help           Show this help

For machine-specific dpdk.ini generation, provide --pci, --local-ip,
--peer-mac and --lcores together.

Intel ICE DDP firmware setup is enabled by default. On Debian ICE/E810 hosts,
the bootstrap verifies intel/ice/ddp/ice.pkg and installs firmware-intel-misc
from non-free-firmware when it is missing.

Host hugepage/NIC preparation is opt-in. For example, 32 GiB of 2 MiB
hugepages plus DPDK NIC binding can be requested with:
  --pci 0000:18:00.0 --hugepages 16384 --bind-dpdk
EOF_USAGE
}

while (($#)); do
    case "$1" in
        --install-deps)
            INSTALL_DEPS=1
            shift
            ;;
        --skip-deps)
            INSTALL_DEPS=0
            shift
            ;;
        --rebuild)
            REBUILD=1
            shift
            ;;
        --jobs)
            [[ $# -ge 2 ]] || { echo "ERROR: --jobs needs a value" >&2; exit 2; }
            JOBS="$2"
            shift 2
            ;;
        --pci)
            [[ $# -ge 2 ]] || { echo "ERROR: --pci needs a value" >&2; exit 2; }
            DPDK_PCI="$2"
            shift 2
            ;;
        --local-ip)
            [[ $# -ge 2 ]] || { echo "ERROR: --local-ip needs a value" >&2; exit 2; }
            LOCAL_IP="$2"
            shift 2
            ;;
        --peer-mac)
            [[ $# -ge 2 ]] || { echo "ERROR: --peer-mac needs a value" >&2; exit 2; }
            PEER_MAC="$2"
            shift 2
            ;;
        --lcores)
            [[ $# -ge 2 ]] || { echo "ERROR: --lcores needs a value" >&2; exit 2; }
            LCORES="$2"
            shift 2
            ;;
        --hugepages)
            [[ $# -ge 2 ]] || { echo "ERROR: --hugepages needs a value" >&2; exit 2; }
            HUGEPAGES_2M="$2"
            shift 2
            ;;
        --bind-dpdk)
            BIND_DPDK=1
            shift
            ;;
        --dpdk-driver)
            [[ $# -ge 2 ]] || { echo "ERROR: --dpdk-driver needs a value" >&2; exit 2; }
            DPDK_BIND_DRIVER="$2"
            BIND_DPDK=1
            shift 2
            ;;
        --ice-firmware)
            ICE_FIRMWARE=1
            shift
            ;;
        --skip-ice-firmware)
            ICE_FIRMWARE=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --jobs must be a positive integer" >&2; exit 2; }
if [[ -n "$HUGEPAGES_2M" ]]; then
    [[ "$HUGEPAGES_2M" =~ ^[1-9][0-9]*$ ]] || {
        echo "ERROR: --hugepages must be a positive number of 2 MiB pages" >&2
        exit 2
    }
fi
case "$DPDK_BIND_DRIVER" in
    auto|igb_uio|uio_pci_generic|vfio-pci) ;;
    *)
        echo "ERROR: --dpdk-driver must be auto, igb_uio, uio_pci_generic, or vfio-pci" >&2
        exit 2
        ;;
esac
if ((BIND_DPDK)) || [[ -n "$HUGEPAGES_2M" ]]; then
    [[ -n "$DPDK_PCI" ]] || {
        echo "ERROR: --bind-dpdk and --hugepages require --pci" >&2
        exit 2
    }
    ((EUID == 0)) || {
        echo "ERROR: --bind-dpdk and --hugepages require running the bootstrap as root" >&2
        exit 1
    }
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
MSQUIC_SRC="$ROOT_DIR/msquic"
DPDK_SRC="$MSQUIC_SRC/deps/dpdk"
DPDK_BUILD="$DPDK_SRC/build-greenquic"
DPDK_INSTALL="$MSQUIC_SRC/deps/dpdk-install"
MSQUIC_BUILD="$MSQUIC_SRC/build-greenquic"
ENV_FILE="$ROOT_DIR/greenquic-env.sh"
DPDK_INI="$MSQUIC_SRC/dpdk.ini"
POWER_INI="$MSQUIC_SRC/powermng.ini"
P4_TEST_DIR="$ROOT_DIR/greenquic_test_suite_v22/test_cases/pretests/P4_repeated_8GiB_downloads"
P4_BUILD_SCRIPT="$P4_TEST_DIR/build_p4_client.sh"
P4_BUILD="$MSQUIC_SRC/build-greenquic-p4"
DPDK_DEVBIND="$DPDK_SRC/usertools/dpdk-devbind.py"

printf 'GreenQUIC root: %s\n' "$ROOT_DIR"
printf 'Build jobs:      %s\n' "$JOBS"

[[ "$(uname -s)" == "Linux" ]] || { echo "ERROR: this bootstrap supports Linux only" >&2; exit 1; }
[[ -f "$MSQUIC_SRC/CMakeLists.txt" ]] || { echo "ERROR: missing $MSQUIC_SRC/CMakeLists.txt" >&2; exit 1; }
[[ -f "$DPDK_SRC/meson.build" ]] || { echo "ERROR: missing bundled DPDK source at $DPDK_SRC" >&2; exit 1; }
[[ -d "$DPDK_SRC/drivers" && -d "$DPDK_SRC/lib" ]] || { echo "ERROR: incomplete DPDK source tree" >&2; exit 1; }
[[ -f "$MSQUIC_SRC/submodules/CMakeLists.txt" ]] || { echo "ERROR: missing MsQuic dependency build file" >&2; exit 1; }
[[ -f "$P4_BUILD_SCRIPT" ]] || { echo "ERROR: missing P4 build script: $P4_BUILD_SCRIPT" >&2; exit 1; }
[[ -f "$DPDK_DEVBIND" ]] || { echo "ERROR: missing DPDK device-binding tool: $DPDK_DEVBIND" >&2; exit 1; }

if [[ ! -f "$MSQUIC_SRC/submodules/openssl/Configure" ]]; then
    echo "ERROR: bundled OpenSSL source is missing." >&2
    echo "The GitHub snapshot is incomplete; do not try to repair this by downloading a different version." >&2
    exit 1
fi

DEBIAN_PACKAGES=(
    ca-certificates
    openssh-client
    git
    curl
    wget
    file
    unzip
    xz-utils
    tar
    patch
    build-essential
    gcc
    g++
    make
    cmake
    meson
    ninja-build
    pkg-config
    python3
    python3-dev
    python3-pyelftools
    python3-setuptools
    python3-wheel
    perl
    m4
    nasm
    autoconf
    automake
    libtool
    flex
    bison
    libnuma-dev
    libssl-dev
    libelf-dev
    libpcap-dev
    libarchive-dev
    libnl-3-dev
    libnl-route-3-dev
    libnl-genl-3-dev
    zlib1g-dev
    libzstd-dev
    libbsd-dev
    libudev-dev
    pciutils
    ethtool
    numactl
    hwloc
    rsync
    iproute2
    kmod
    procps
    util-linux
)

missing_packages=()
if command -v dpkg-query >/dev/null 2>&1; then
    for package in "${DEBIAN_PACKAGES[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
            missing_packages+=("$package")
        fi
    done
else
    echo "ERROR: this script expects a Debian/Ubuntu-style system with dpkg-query" >&2
    exit 1
fi

if ((${#missing_packages[@]})); then
    printf 'Missing packages: %s\n' "${missing_packages[*]}"
    if ((INSTALL_DEPS)); then
        echo "Installing required build dependencies before starting the build..."
        if ((EUID == 0)); then
            APT=(apt-get)
        elif command -v sudo >/dev/null 2>&1; then
            APT=(sudo apt-get)
        else
            echo "ERROR: root or sudo is required for --install-deps" >&2
            exit 1
        fi

        export DEBIAN_FRONTEND=noninteractive
        export APT_LISTCHANGES_FRONTEND=none
        "${APT[@]}" update
        "${APT[@]}" -y --no-install-recommends --no-remove --no-upgrade \
            install "${missing_packages[@]}"
    else
        echo "Dependency installation was skipped by --skip-deps."
        echo "The build cannot continue while required packages are missing."
        exit 3
    fi
else
    echo "All required Debian build packages are already installed."
fi

for command_name in gcc g++ cmake meson ninja pkg-config python3 perl make tar patch ip modprobe mount mountpoint findmnt pgrep lspci apt-get apt-cache; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "ERROR: required command is unavailable after dependency check: $command_name" >&2
        exit 1
    }
done

normalize_pci() {
    local pci="$1"
    if [[ "$pci" =~ ^[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]]; then
        printf '0000:%s\n' "$pci"
    else
        printf '%s\n' "$pci"
    fi
}

find_ice_firmware() {
    local candidate
    for candidate in \
        /lib/firmware/intel/ice/ddp/ice.pkg \
        /usr/lib/firmware/intel/ice/ddp/ice.pkg; do
        if [[ -e "$candidate" ]]; then
            readlink -f "$candidate"
            return 0
        fi
    done
    return 1
}

host_uses_intel_ice() {
    local pci_full info

    if [[ -n "$DPDK_PCI" ]]; then
        pci_full="$(normalize_pci "$DPDK_PCI")"
        [[ -e "/sys/bus/pci/devices/$pci_full" ]] || return 1
        info="$(lspci -Dk -s "$pci_full" 2>/dev/null || true)"
        grep -Eqi 'E810|Kernel driver in use:[[:space:]]*ice|Kernel modules:[[:space:]].*\bice\b' <<< "$info"
        return $?
    fi

    lspci -Dk 2>/dev/null | grep -Eqi 'E810|Kernel driver in use:[[:space:]]*ice|Kernel modules:[[:space:]].*\bice\b'
}

debian_non_free_firmware_source() {
    local os_id codename primary_uri security_uri source_file

    [[ -r /etc/os-release ]] || {
        echo "ERROR: cannot identify Linux distribution for ICE firmware setup" >&2
        exit 1
    }

    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-}"
    codename="${VERSION_CODENAME:-}"

    [[ "$os_id" == "debian" && -n "$codename" ]] || {
        echo "ERROR: automatic ICE firmware repository repair is implemented only for Debian." >&2
        echo "Disable it with --skip-ice-firmware or install intel/ice/ddp/ice.pkg manually." >&2
        exit 1
    }

    primary_uri="$(
        grep -RhsE '^URIs:[[:space:]]+' /etc/apt/sources.list.d 2>/dev/null |
            awk '{for (i=2; i<=NF; i++) if ($i !~ /security/) {print $i; exit}}'
    )"
    if [[ -z "$primary_uri" ]]; then
        primary_uri="$(
            grep -RhsE '^[[:space:]]*deb[[:space:]]+' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null |
                awk '$2 !~ /security/ {print $2; exit}'
        )"
    fi
    [[ -n "$primary_uri" ]] || primary_uri="http://deb.debian.org/debian"

    security_uri="$(
        grep -RhsE '^URIs:[[:space:]]+' /etc/apt/sources.list.d 2>/dev/null |
            awk '{for (i=2; i<=NF; i++) if ($i ~ /security/) {print $i; exit}}'
    )"
    if [[ -z "$security_uri" ]]; then
        security_uri="$(
            grep -RhsE '^[[:space:]]*deb[[:space:]]+' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null |
                awk '$2 ~ /security/ {print $2; exit}'
        )"
    fi
    [[ -n "$security_uri" ]] || security_uri="http://security.debian.org/debian-security"

    source_file="/etc/apt/sources.list.d/greenquic-non-free-firmware.sources"
    cat > "$source_file" <<EOF_APT
Types: deb
URIs: $primary_uri
Suites: $codename ${codename}-updates
Components: non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: $security_uri
Suites: ${codename}-security
Components: non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF_APT

    echo "Enabled Debian non-free-firmware source: $source_file"
}

ensure_ice_firmware() {
    if ((ICE_FIRMWARE == 0)); then
        ICE_FIRMWARE_STATUS="disabled"
        echo "Intel ICE DDP firmware check disabled by --skip-ice-firmware."
        return 0
    fi

    if ! host_uses_intel_ice; then
        ICE_FIRMWARE_STATUS="not-needed"
        echo "Intel ICE/E810 device not detected; ICE DDP firmware repair not needed."
        return 0
    fi

    if ICE_FIRMWARE_PATH="$(find_ice_firmware)"; then
        ICE_FIRMWARE_STATUS="ready"
        echo "Intel ICE DDP firmware already present: $ICE_FIRMWARE_PATH"
        return 0
    fi

    ((EUID == 0)) || {
        echo "ERROR: Intel ICE DDP firmware is missing and installing it requires root." >&2
        echo "Rerun as root or use --skip-ice-firmware only if you intentionally manage firmware yourself." >&2
        exit 1
    }

    echo
    echo "Intel ICE/E810 detected but intel/ice/ddp/ice.pkg is missing."
    echo "Installing $ICE_FIRMWARE_PACKAGE..."

    candidate="$(apt-cache policy "$ICE_FIRMWARE_PACKAGE" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
    if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
        debian_non_free_firmware_source
        apt-get update
        candidate="$(apt-cache policy "$ICE_FIRMWARE_PACKAGE" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
    fi

    [[ -n "$candidate" && "$candidate" != "(none)" ]] || {
        echo "ERROR: $ICE_FIRMWARE_PACKAGE is still unavailable after enabling non-free-firmware" >&2
        exit 1
    }

    export DEBIAN_FRONTEND=noninteractive
    if dpkg-query -W -f='${Status}' "$ICE_FIRMWARE_PACKAGE" 2>/dev/null | grep -q 'install ok installed'; then
        apt-get -y --no-remove --no-upgrade --reinstall install "$ICE_FIRMWARE_PACKAGE"
    else
        apt-get -y --no-remove --no-upgrade install "$ICE_FIRMWARE_PACKAGE"
    fi

    ICE_FIRMWARE_PATH="$(find_ice_firmware || true)"
    [[ -n "$ICE_FIRMWARE_PATH" && -e "$ICE_FIRMWARE_PATH" ]] || {
        echo "ERROR: $ICE_FIRMWARE_PACKAGE installed but intel/ice/ddp/ice.pkg is still missing" >&2
        dpkg -L "$ICE_FIRMWARE_PACKAGE" | grep -E '/intel/ice/ddp/.*\.pkg$' >&2 || true
        exit 1
    }

    ICE_FIRMWARE_STATUS="ready"
    echo "Intel ICE DDP firmware ready: $ICE_FIRMWARE_PATH"
}

ensure_no_greenquic_processes() {
    if pgrep -af 'quicinteropserver|quicinterop|secnetperf' >/dev/null 2>&1; then
        echo "ERROR: a GreenQUIC/DPDK application is running; host preparation is unsafe:" >&2
        pgrep -af 'quicinteropserver|quicinterop|secnetperf' >&2 || true
        exit 1
    fi
}

pci_numa_node() {
    local pci_full
    pci_full="$(normalize_pci "$DPDK_PCI")"
    [[ -e "/sys/bus/pci/devices/$pci_full" ]] || {
        echo "ERROR: PCI device $pci_full does not exist" >&2
        exit 1
    }
    local numa
    numa="$(cat "/sys/bus/pci/devices/$pci_full/numa_node")"
    [[ "$numa" != "-1" ]] || numa=0
    printf '%s\n' "$numa"
}

configure_2m_hugepages() {
    [[ -n "$HUGEPAGES_2M" ]] || return 0

    ensure_no_greenquic_processes

    local numa hpdir allocated total_2m node f value mount_fstype mount_opts
    numa="$(pci_numa_node)"
    HUGEPAGE_NUMA_NODE="$numa"
    hpdir="/sys/devices/system/node/node${numa}/hugepages/hugepages-2048kB"

    [[ -d "$hpdir" ]] || {
        echo "ERROR: 2 MiB hugepages are not available on NUMA node $numa" >&2
        exit 1
    }

    echo
    echo "Configuring $HUGEPAGES_2M x 2 MiB hugepages on NUMA node $numa..."

    for node in /sys/devices/system/node/node*; do
        f="$node/hugepages/hugepages-1048576kB/nr_hugepages"
        if [[ -e "$f" ]]; then
            echo 0 > "$f"
            value="$(cat "$f")"
            [[ "$value" == "0" ]] || {
                echo "ERROR: could not clear 1 GiB hugepages at $f (still $value)" >&2
                exit 1
            }
        fi
    done

    for node in /sys/devices/system/node/node*; do
        f="$node/hugepages/hugepages-2048kB/nr_hugepages"
        if [[ -e "$f" ]]; then
            echo 0 > "$f"
        fi
    done

    echo "$HUGEPAGES_2M" > "$hpdir/nr_hugepages"
    allocated="$(cat "$hpdir/nr_hugepages")"
    [[ "$allocated" == "$HUGEPAGES_2M" ]] || {
        echo "ERROR: requested $HUGEPAGES_2M x 2 MiB hugepages, but only $allocated were allocated" >&2
        free -h >&2 || true
        exit 1
    }

    total_2m=0
    for node in /sys/devices/system/node/node*; do
        f="$node/hugepages/hugepages-2048kB/nr_hugepages"
        [[ -e "$f" ]] || continue
        value="$(cat "$f")"
        total_2m=$((total_2m + value))
    done
    [[ "$total_2m" == "$HUGEPAGES_2M" ]] || {
        echo "ERROR: total 2 MiB hugepages are $total_2m, expected $HUGEPAGES_2M" >&2
        exit 1
    }

    mkdir -p "$HUGEPAGE_MOUNT"
    if mountpoint -q "$HUGEPAGE_MOUNT"; then
        mount_fstype="$(findmnt -n -o FSTYPE --target "$HUGEPAGE_MOUNT" 2>/dev/null || true)"
        mount_opts="$(findmnt -n -o OPTIONS --target "$HUGEPAGE_MOUNT" 2>/dev/null || true)"
        if [[ "$mount_fstype" != "hugetlbfs" || "$mount_opts" != *"pagesize=2M"* ]]; then
            echo "ERROR: $HUGEPAGE_MOUNT is already mounted with incompatible settings:" >&2
            findmnt "$HUGEPAGE_MOUNT" >&2 || true
            exit 1
        fi
    else
        mount -t hugetlbfs -o pagesize=2M none "$HUGEPAGE_MOUNT"
    fi

    mountpoint -q "$HUGEPAGE_MOUNT" || {
        echo "ERROR: failed to mount 2 MiB hugetlbfs at $HUGEPAGE_MOUNT" >&2
        exit 1
    }

    echo "Hugepages ready: $HUGEPAGES_2M x 2 MiB on NUMA node $numa"
    echo "Hugepage memory: $((HUGEPAGES_2M * 2)) MiB"
    findmnt "$HUGEPAGE_MOUNT"
}

select_dpdk_driver() {
    local requested="$1"

    case "$requested" in
        auto)
            modprobe uio
            if [[ -d /sys/module/igb_uio ]] || modprobe igb_uio 2>/dev/null; then
                printf 'igb_uio\n'
            else
                modprobe uio_pci_generic
                printf 'uio_pci_generic\n'
            fi
            ;;
        igb_uio)
            modprobe uio
            if [[ ! -d /sys/module/igb_uio ]]; then
                modprobe igb_uio
            fi
            printf 'igb_uio\n'
            ;;
        uio_pci_generic)
            modprobe uio
            modprobe uio_pci_generic
            printf 'uio_pci_generic\n'
            ;;
        vfio-pci)
            modprobe vfio-pci
            printf 'vfio-pci\n'
            ;;
    esac
}

bind_dpdk_pci() {
    ((BIND_DPDK)) || return 0

    ensure_no_greenquic_processes

    local pci_full iface default_iface ssh_local_ip addr target_driver actual_driver
    pci_full="$(normalize_pci "$DPDK_PCI")"
    [[ -e "/sys/bus/pci/devices/$pci_full" ]] || {
        echo "ERROR: PCI device $pci_full does not exist" >&2
        exit 1
    }

    iface="$(find "/sys/bus/pci/devices/$pci_full/net" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | head -n1 || true)"
    if [[ -n "$iface" ]]; then
        default_iface="$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}')"
        if [[ -n "$default_iface" && "$iface" == "$default_iface" ]]; then
            echo "ERROR: refusing to bind $pci_full because interface $iface carries the default route" >&2
            exit 1
        fi

        ssh_local_ip=""
        if [[ -n "${SSH_CONNECTION:-}" ]]; then
            read -r _ _ ssh_local_ip _ <<< "$SSH_CONNECTION"
        fi
        if [[ -n "$ssh_local_ip" ]]; then
            while read -r addr; do
                if [[ "${addr%/*}" == "$ssh_local_ip" ]]; then
                    echo "ERROR: refusing to bind $pci_full because $iface owns this SSH session's local IP $ssh_local_ip" >&2
                    exit 1
                fi
            done < <(ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4}')
        fi

        echo "DPDK PCI $pci_full currently maps to Linux interface: $iface"
        ip link set "$iface" down
    else
        echo "DPDK PCI $pci_full has no Linux netdev (it may already be userspace-bound)."
    fi

    target_driver="$(select_dpdk_driver "$DPDK_BIND_DRIVER")"
    echo "Binding $pci_full to DPDK driver: $target_driver"
    python3 "$DPDK_DEVBIND" --bind="$target_driver" "$pci_full"

    actual_driver="$(basename "$(readlink -f "/sys/bus/pci/devices/$pci_full/driver" 2>/dev/null || true)")"
    [[ "$actual_driver" == "$target_driver" ]] || {
        echo "ERROR: expected $pci_full on $target_driver, actual driver is '${actual_driver:-none}'" >&2
        python3 "$DPDK_DEVBIND" --status-dev net >&2 || true
        exit 1
    }

    BOUND_DPDK_DRIVER="$actual_driver"
    echo "DPDK binding ready: $pci_full -> $BOUND_DPDK_DRIVER"
}

ensure_ice_firmware

if ((REBUILD)); then
    echo "Removing generated build/install directories only:"
    printf '  %s\n' "$DPDK_BUILD" "$DPDK_INSTALL" "$MSQUIC_BUILD" "$P4_BUILD"
    rm -rf -- "$DPDK_BUILD" "$DPDK_INSTALL" "$MSQUIC_BUILD" "$P4_BUILD" "$ROOT_DIR/msquic-p4-source"
fi

mkdir -p "$DPDK_BUILD" "$DPDK_INSTALL"

DPDK_MESON_ARGS=(
    --prefix "$DPDK_INSTALL"
    --libdir lib
    -Dbuildtype=release
    -Ddefault_library=static
)

if [[ -f "$DPDK_BUILD/build.ninja" ]]; then
    echo "Reconfiguring DPDK..."
    meson setup --reconfigure "$DPDK_BUILD" "$DPDK_SRC" "${DPDK_MESON_ARGS[@]}"
else
    echo "Configuring DPDK..."
    meson setup "$DPDK_BUILD" "$DPDK_SRC" "${DPDK_MESON_ARGS[@]}"
fi

meson compile -C "$DPDK_BUILD" -j "$JOBS"
meson install -C "$DPDK_BUILD"

DPDK_PC="$(find "$DPDK_INSTALL" -type f -name libdpdk.pc -print -quit)"
[[ -n "$DPDK_PC" ]] || { echo "ERROR: DPDK installation did not produce libdpdk.pc" >&2; exit 1; }
DPDK_PC_DIR="$(dirname "$DPDK_PC")"

DPDK_LIB_DIR="$(find "$DPDK_INSTALL" -type f -name 'librte_eal.a' -printf '%h\n' | head -n 1)"
if [[ -z "$DPDK_LIB_DIR" ]]; then
    DPDK_LIB_DIR="$(find "$DPDK_INSTALL" -type f \( -name 'libdpdk.a' -o -name 'libdpdk.so' -o -name 'libdpdk.so.*' \) -printf '%h\n' | head -n 1)"
fi
[[ -n "$DPDK_LIB_DIR" ]] || DPDK_LIB_DIR="$DPDK_INSTALL/lib"
[[ -f "$DPDK_LIB_DIR/librte_eal.a" ]] || {
    echo "ERROR: static DPDK libraries were not found under $DPDK_INSTALL" >&2
    exit 1
}

export PKG_CONFIG_PATH="$DPDK_PC_DIR${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="$DPDK_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LIBRARY_PATH="$DPDK_LIB_DIR${LIBRARY_PATH:+:$LIBRARY_PATH}"
export CMAKE_PREFIX_PATH="$DPDK_INSTALL${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export CMAKE_LIBRARY_PATH="$DPDK_LIB_DIR${CMAKE_LIBRARY_PATH:+:$CMAKE_LIBRARY_PATH}"
export PATH="$DPDK_INSTALL/bin:$DPDK_SRC/usertools:$PATH"

pkg-config --exists libdpdk || { echo "ERROR: pkg-config cannot find the locally built libdpdk" >&2; exit 1; }
echo "DPDK pkg-config version: $(pkg-config --modversion libdpdk)"

mkdir -p "$MSQUIC_BUILD"

echo "Configuring MsQuic/GreenQUIC..."
cmake -S "$MSQUIC_SRC" -B "$MSQUIC_BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_PREFIX_PATH="$DPDK_INSTALL" \
    -DQUIC_TLS=openssl \
    -DQUIC_USE_SYSTEM_LIBCRYPTO=OFF \
    -DQUIC_LINUX_DPDK_ENABLED=ON \
    -DQUIC_LINUX_XDP_ENABLED=OFF \
    -DQUIC_BUILD_SHARED=OFF \
    -DQUIC_BUILD_TOOLS=ON \
    -DQUIC_BUILD_PERF=ON \
    -DQUIC_BUILD_TEST=OFF \
    -DQUIC_ENABLE_LOGGING=OFF

if ! grep -qx 'QUIC_ENABLE_LOGGING:BOOL=OFF' "$MSQUIC_BUILD/CMakeCache.txt"; then
    echo "ERROR: MsQuic logging was not disabled by CMake." >&2
    grep '^QUIC_ENABLE_LOGGING:' "$MSQUIC_BUILD/CMakeCache.txt" >&2 || true
    exit 1
fi

echo "MsQuic packet tracing: disabled"

cmake --build "$MSQUIC_BUILD" \
    --target secnetperf quicinteropserver quicinterop \
    --parallel "$JOBS"

SECNETPERF_BIN="$(find "$MSQUIC_BUILD" -type f -name secnetperf -perm -111 -print -quit)"
INTEROP_SERVER_BIN="$(find "$MSQUIC_BUILD" -type f -name quicinteropserver -perm -111 -print -quit)"
INTEROP_CLIENT_BIN="$(find "$MSQUIC_BUILD" -type f -name quicinterop -perm -111 -print -quit)"
[[ -n "$SECNETPERF_BIN" ]] || { echo "ERROR: secnetperf was not produced" >&2; exit 1; }
[[ -n "$INTEROP_SERVER_BIN" ]] || { echo "ERROR: quicinteropserver was not produced" >&2; exit 1; }
[[ -n "$INTEROP_CLIENT_BIN" ]] || { echo "ERROR: quicinterop was not produced" >&2; exit 1; }

echo "Building isolated P4 pretest client..."
chmod 0755 "$P4_BUILD_SCRIPT"
"$P4_BUILD_SCRIPT"
P4_CLIENT_BIN="$P4_BUILD/bin/Release/quicinterop"
[[ -x "$P4_CLIENT_BIN" ]] || { echo "ERROR: P4 quicinterop was not produced: $P4_CLIENT_BIN" >&2; exit 1; }
grep -aFq -- 'GreenQUIC-P4-SEQUENCE-V1' "$P4_CLIENT_BIN" || {
    echo "ERROR: P4 quicinterop is missing the expected P4 sequence marker" >&2
    exit 1
}

cat > "$ENV_FILE" <<'EOF_ENV'
#!/usr/bin/env bash

_GREENQUIC_ENV_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export GREENQUIC_ROOT="$_GREENQUIC_ENV_DIR"
export MSQUIC_ROOT="$GREENQUIC_ROOT/msquic"
export DPDK_ROOT="$MSQUIC_ROOT/deps/dpdk"
export DPDK_BUILD="$DPDK_ROOT/build-greenquic"
export DPDK_INSTALL="$MSQUIC_ROOT/deps/dpdk-install"
export MSQUIC_BUILD="$MSQUIC_ROOT/build-greenquic"
export P4_BUILD="$MSQUIC_ROOT/build-greenquic-p4"

_DPDK_PC="$(find "$DPDK_INSTALL" -type f -name libdpdk.pc -print -quit 2>/dev/null)"
if [[ -n "$_DPDK_PC" ]]; then
    _DPDK_PC_DIR="$(dirname "$_DPDK_PC")"
    export PKG_CONFIG_PATH="$_DPDK_PC_DIR${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
fi

_DPDK_LIB_DIR="$(find "$DPDK_INSTALL" -type f \( -name 'libdpdk.a' -o -name 'libdpdk.so' -o -name 'libdpdk.so.*' \) -printf '%h\n' 2>/dev/null | head -n 1)"
if [[ -n "$_DPDK_LIB_DIR" ]]; then
    export LD_LIBRARY_PATH="$_DPDK_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export LIBRARY_PATH="$_DPDK_LIB_DIR${LIBRARY_PATH:+:$LIBRARY_PATH}"
fi

export CMAKE_PREFIX_PATH="$DPDK_INSTALL${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export PATH="$DPDK_INSTALL/bin:$DPDK_ROOT/usertools:$PATH"

export SECNETPERF_BIN="$(find "$MSQUIC_BUILD" -type f -name secnetperf -perm -111 -print -quit 2>/dev/null)"
export INTEROP_SERVER_BIN="$(find "$MSQUIC_BUILD" -type f -name quicinteropserver -perm -111 -print -quit 2>/dev/null)"
export INTEROP_CLIENT_BIN="$(find "$MSQUIC_BUILD" -type f -name quicinterop -perm -111 -print -quit 2>/dev/null)"
export P4_CLIENT_BIN="$P4_BUILD/bin/Release/quicinterop"

unset _GREENQUIC_ENV_DIR _DPDK_PC _DPDK_PC_DIR _DPDK_LIB_DIR
EOF_ENV
chmod 0755 "$ENV_FILE"

set_ini_value() {
    local file="$1"
    local key="$2"
    local value="$3"
    local temporary
    temporary="$(mktemp)"

    awk -F= -v key="$key" -v value="$value" '
        BEGIN { replaced = 0 }
        $1 == key {
            if (!replaced) {
                print key "=" value
                replaced = 1
            }
            next
        }
        { print }
        END {
            if (!replaced) {
                print key "=" value
            }
        }
    ' "$file" > "$temporary"

    cat "$temporary" > "$file"
    rm -f "$temporary"
}

machine_config_count=0
[[ -n "$LOCAL_IP" ]] && ((machine_config_count += 1))
[[ -n "$PEER_MAC" ]] && ((machine_config_count += 1))
[[ -n "$LCORES" ]] && ((machine_config_count += 1))

if ((machine_config_count != 0 && machine_config_count != 3)); then
    echo "ERROR: provide --local-ip, --peer-mac and --lcores together (with --pci)" >&2
    exit 2
fi
if ((machine_config_count == 3)) && [[ -z "$DPDK_PCI" ]]; then
    echo "ERROR: machine-specific DPDK configuration also requires --pci" >&2
    exit 2
fi

if ((machine_config_count == 3)); then
    [[ "$DPDK_PCI" =~ ^([0-9a-fA-F]{4}:)?[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]] || {
        echo "ERROR: invalid PCI BDF: $DPDK_PCI" >&2
        exit 2
    }
    [[ "$LOCAL_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
        echo "ERROR: invalid IPv4 form: $LOCAL_IP" >&2
        exit 2
    }
    [[ "$PEER_MAC" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] || {
        echo "ERROR: invalid MAC address: $PEER_MAC" >&2
        exit 2
    }
    [[ "$LCORES" =~ ^[0-9]+([,-][0-9]+)*$ ]] || {
        echo "ERROR: invalid lcore list: $LCORES" >&2
        exit 2
    }

    if [[ ! -f "$DPDK_INI" ]]; then
        if [[ -f "$MSQUIC_SRC/dpdk.greenquic.example.ini" ]]; then
            cp "$MSQUIC_SRC/dpdk.greenquic.example.ini" "$DPDK_INI"
        else
            : > "$DPDK_INI"
        fi
    fi

    set_ini_value "$DPDK_INI" DeviceName "$DPDK_PCI"
    set_ini_value "$DPDK_INI" LocalIp "$LOCAL_IP"
    set_ini_value "$DPDK_INI" PeerMac "$PEER_MAC"
    set_ini_value "$DPDK_INI" DpdkInitArgs "secnetperf -l $LCORES -a $DPDK_PCI"
    chmod 0600 "$DPDK_INI"
    echo "Configured $DPDK_INI"
else
    echo "No complete machine-specific DPDK values were supplied."
    if [[ -f "$DPDK_INI" ]]; then
        echo "Preserving existing $DPDK_INI"
    else
        echo "You must create $DPDK_INI before running the server, or rerun bootstrap with --pci, --local-ip, --peer-mac and --lcores."
    fi
fi

if [[ ! -f "$POWER_INI" && -f "$MSQUIC_SRC/powermng.example.ini" ]]; then
    cp "$MSQUIC_SRC/powermng.example.ini" "$POWER_INI"
    chmod 0600 "$POWER_INI"
    echo "Created $POWER_INI from the repository example."
fi

configure_2m_hugepages
bind_dpdk_pci

if [[ ! -f "$ROOT_DIR/run_server.sh" ]]; then
    cat > "$ROOT_DIR/run_server.sh" <<'EOF_SERVER'
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/greenquic-env.sh"

if ((EUID != 0)); then
    echo "ERROR: DPDK server must be run as root on this test node." >&2
    exit 1
fi

[[ -n "${SECNETPERF_BIN:-}" && -x "$SECNETPERF_BIN" ]] || {
    echo "ERROR: secnetperf is missing. Run ./bootstrap_greenquic.sh first." >&2
    exit 1
}

DPDK_INI="$MSQUIC_ROOT/dpdk.ini"
[[ -f "$DPDK_INI" ]] || {
    echo "ERROR: missing $DPDK_INI" >&2
    echo "Rerun bootstrap with --pci, --local-ip, --peer-mac and --lcores." >&2
    exit 1
}

for key in DeviceName LocalIp PeerMac DpdkInitArgs; do
    grep -q "^${key}=" "$DPDK_INI" || {
        echo "ERROR: $key is missing from $DPDK_INI" >&2
        exit 1
    }
done

PCI="$(awk -F= '$1 == "DeviceName" {print $2; exit}' "$DPDK_INI")"
PEER_MAC="$(awk -F= '$1 == "PeerMac" {print $2; exit}' "$DPDK_INI")"

[[ "$PEER_MAC" != "00:00:00:00:00:00" ]] || {
    echo "ERROR: PeerMac is still zero in $DPDK_INI" >&2
    exit 1
}

PCI_FULL="$PCI"
[[ "$PCI_FULL" =~ ^[0-9a-fA-F]{2}: ]] && PCI_FULL="0000:$PCI_FULL"

[[ -e "/sys/bus/pci/devices/$PCI_FULL" ]] || {
    echo "ERROR: PCI device $PCI_FULL does not exist on this server" >&2
    exit 1
}

DRIVER="$(basename "$(readlink -f "/sys/bus/pci/devices/$PCI_FULL/driver" 2>/dev/null || true)")"
case "$DRIVER" in
    igb_uio|vfio-pci|uio_pci_generic)
        ;;
    *)
        echo "ERROR: $PCI_FULL is bound to '${DRIVER:-no driver}', not a DPDK userspace driver." >&2
        echo "Use bootstrap --bind-dpdk or bind the NIC manually before starting the server." >&2
        exit 1
        ;;
esac

HUGEPAGES_TOTAL="$(awk '/^HugePages_Total:/ {print $2}' /proc/meminfo)"
if [[ -z "$HUGEPAGES_TOTAL" || "$HUGEPAGES_TOTAL" == "0" ]]; then
    echo "ERROR: no hugepages are configured." >&2
    echo "Use bootstrap --hugepages N or configure hugepages manually before starting the server." >&2
    exit 1
fi

ulimit -l unlimited 2>/dev/null || true
cd "$MSQUIC_ROOT"

exec "$SECNETPERF_BIN" -exec:maxtput "$@"
EOF_SERVER
    chmod 0755 "$ROOT_DIR/run_server.sh"
    echo "Created $ROOT_DIR/run_server.sh"
else
    chmod 0755 "$ROOT_DIR/run_server.sh"
    echo "Preserving existing $ROOT_DIR/run_server.sh"
fi

cat <<EOF_SUMMARY

Build completed successfully.
All required Debian/Ubuntu build dependencies were checked and installed automatically.

Environment file:
  $ENV_FILE

Secnetperf:
  $SECNETPERF_BIN

Interop server:
  $INTEROP_SERVER_BIN

Interop client:
  $INTEROP_CLIENT_BIN

P4 pretest client:
  $P4_CLIENT_BIN
EOF_SUMMARY

cat <<EOF_ICE

Intel ICE DDP firmware:
  status: $ICE_FIRMWARE_STATUS
  path: ${ICE_FIRMWARE_PATH:-n/a}
EOF_ICE

if [[ -n "$HUGEPAGES_2M" ]]; then
    cat <<EOF_HUGE

2 MiB hugepages:
  count: $HUGEPAGES_2M
  memory: $((HUGEPAGES_2M * 2)) MiB
  NUMA node: $HUGEPAGE_NUMA_NODE
  mount: $HUGEPAGE_MOUNT
EOF_HUGE
fi

if ((BIND_DPDK)); then
    cat <<EOF_BIND

DPDK NIC binding:
  PCI: $(normalize_pci "$DPDK_PCI")
  driver: $BOUND_DPDK_DRIVER
EOF_BIND
fi

cat <<'EOF_DONE'

To use this shell interactively:
  source ./greenquic-env.sh

To start the server after DPDK NIC binding and hugepages are ready:
  ./run_server.sh
EOF_DONE
