#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "\nERROR: bootstrap failed at line %s.\n" "$LINENO" >&2' ERR

INSTALL_DEPS=0
REBUILD=0
JOBS="$(nproc 2>/dev/null || echo 1)"
DPDK_PCI=""
LOCAL_IP=""
PEER_MAC=""
LCORES=""

usage() {
    cat <<'EOF'
Usage:
  ./bootstrap_greenquic.sh [options]

Options:
  --install-deps       Install missing Debian build packages without upgrading/removing packages
  --rebuild            Delete only generated build/install directories and rebuild them
  --jobs N             Parallel build jobs (default: nproc)
  --pci BDF            DPDK PCI device, for example 0000:18:00.0
  --local-ip IPv4      Logical local DPDK IPv4 address, for example 192.168.100.1
  --peer-mac MAC       Peer DPDK-port MAC address
  --lcores LIST        DPDK EAL lcore list, for example 8 or 8,9
  -h, --help           Show this help

For a completely ready server configuration, provide --pci, --local-ip,
--peer-mac and --lcores together.
EOF
}

while (($#)); do
    case "$1" in
        --install-deps)
            INSTALL_DEPS=1
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

printf 'GreenQUIC root: %s\n' "$ROOT_DIR"
printf 'Build jobs:      %s\n' "$JOBS"

[[ "$(uname -s)" == "Linux" ]] || { echo "ERROR: this bootstrap supports Linux only" >&2; exit 1; }
[[ -f "$MSQUIC_SRC/CMakeLists.txt" ]] || { echo "ERROR: missing $MSQUIC_SRC/CMakeLists.txt" >&2; exit 1; }
[[ -f "$DPDK_SRC/meson.build" ]] || { echo "ERROR: missing bundled DPDK source at $DPDK_SRC" >&2; exit 1; }
[[ -d "$DPDK_SRC/drivers" && -d "$DPDK_SRC/lib" ]] || { echo "ERROR: incomplete DPDK source tree" >&2; exit 1; }
[[ -f "$MSQUIC_SRC/submodules/CMakeLists.txt" ]] || { echo "ERROR: missing MsQuic dependency build file" >&2; exit 1; }

# A fresh flattened snapshot must contain the OpenSSL source itself.
if [[ ! -f "$MSQUIC_SRC/submodules/openssl/Configure" ]]; then
    echo "ERROR: bundled OpenSSL source is missing." >&2
    echo "The GitHub snapshot is incomplete; do not try to repair this by downloading a different version." >&2
    exit 1
fi

DEBIAN_PACKAGES=(
    git
    build-essential
    cmake
    meson
    ninja-build
    pkg-config
    python3
    python3-pyelftools
    perl
    m4
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
        if ((EUID == 0)); then
            APT=(apt-get)
        elif command -v sudo >/dev/null 2>&1; then
            APT=(sudo apt-get)
        else
            echo "ERROR: root or sudo is required for --install-deps" >&2
            exit 1
        fi

        "${APT[@]}" update
        "${APT[@]}" -y --no-install-recommends --no-remove --no-upgrade \
            install "${missing_packages[@]}"
    else
        echo "No system packages were changed."
        echo "Rerun with --install-deps to install only the missing packages."
        exit 3
    fi
else
    echo "All required Debian build packages are already installed."
fi

for command_name in gcc g++ cmake meson ninja pkg-config python3 perl make; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "ERROR: required command is unavailable after dependency check: $command_name" >&2
        exit 1
    }
done

if ((REBUILD)); then
    echo "Removing generated build/install directories only:"
    printf '  %s\n' "$DPDK_BUILD" "$DPDK_INSTALL" "$MSQUIC_BUILD"
    rm -rf -- "$DPDK_BUILD" "$DPDK_INSTALL" "$MSQUIC_BUILD"
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

DPDK_LIB_DIR="$(find "$DPDK_INSTALL" -type f \( -name 'libdpdk.a' -o -name 'libdpdk.so' -o -name 'libdpdk.so.*' \) -printf '%h\n' | head -n 1)"
[[ -n "$DPDK_LIB_DIR" ]] || DPDK_LIB_DIR="$DPDK_INSTALL/lib"

export PKG_CONFIG_PATH="$DPDK_PC_DIR${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="$DPDK_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LIBRARY_PATH="$DPDK_LIB_DIR${LIBRARY_PATH:+:$LIBRARY_PATH}"
export CMAKE_PREFIX_PATH="$DPDK_INSTALL${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
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
    -DQUIC_ENABLE_LOGGING=ON \
    -DQUIC_LOGGING_TYPE=stdout

cmake --build "$MSQUIC_BUILD" --target secnetperf --parallel "$JOBS"

SECNETPERF_BIN="$(find "$MSQUIC_BUILD" -type f -name secnetperf -perm -111 -print -quit)"
[[ -n "$SECNETPERF_BIN" ]] || { echo "ERROR: secnetperf was not produced" >&2; exit 1; }

cat > "$ENV_FILE" <<'EOF'
#!/usr/bin/env bash

_GREENQUIC_ENV_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export GREENQUIC_ROOT="$_GREENQUIC_ENV_DIR"
export MSQUIC_ROOT="$GREENQUIC_ROOT/msquic"
export DPDK_ROOT="$MSQUIC_ROOT/deps/dpdk"
export DPDK_BUILD="$DPDK_ROOT/build-greenquic"
export DPDK_INSTALL="$MSQUIC_ROOT/deps/dpdk-install"
export MSQUIC_BUILD="$MSQUIC_ROOT/build-greenquic"

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

unset _GREENQUIC_ENV_DIR _DPDK_PC _DPDK_PC_DIR _DPDK_LIB_DIR
EOF
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

provided_config_count=0
[[ -n "$DPDK_PCI" ]] && ((provided_config_count += 1))
[[ -n "$LOCAL_IP" ]] && ((provided_config_count += 1))
[[ -n "$PEER_MAC" ]] && ((provided_config_count += 1))
[[ -n "$LCORES" ]] && ((provided_config_count += 1))

if ((provided_config_count != 0 && provided_config_count != 4)); then
    echo "ERROR: provide --pci, --local-ip, --peer-mac and --lcores together" >&2
    exit 2
fi

if ((provided_config_count == 4)); then
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
    echo "No machine-specific DPDK values were supplied."
    if [[ -f "$DPDK_INI" ]]; then
        echo "Preserving existing $DPDK_INI"
    else
        echo "You must create $DPDK_INI before running the server."
    fi
fi

if [[ ! -f "$POWER_INI" && -f "$MSQUIC_SRC/powermng.example.ini" ]]; then
    cp "$MSQUIC_SRC/powermng.example.ini" "$POWER_INI"
    chmod 0600 "$POWER_INI"
    echo "Created $POWER_INI from the repository example."
fi

if [[ ! -f "$ROOT_DIR/run_server.sh" ]]; then
    cat > "$ROOT_DIR/run_server.sh" <<'EOF'
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
        echo "The wrapper will not rebind a NIC automatically." >&2
        exit 1
        ;;
esac

HUGEPAGES_TOTAL="$(awk '/^HugePages_Total:/ {print $2}' /proc/meminfo)"
if [[ -z "$HUGEPAGES_TOTAL" || "$HUGEPAGES_TOTAL" == "0" ]]; then
    echo "ERROR: no hugepages are configured. The wrapper will not change system memory settings." >&2
    exit 1
fi

ulimit -l unlimited 2>/dev/null || true
cd "$MSQUIC_ROOT"

exec "$SECNETPERF_BIN" -exec:maxtput "$@"
EOF
    chmod 0755 "$ROOT_DIR/run_server.sh"
    echo "Created $ROOT_DIR/run_server.sh"
else
    chmod 0755 "$ROOT_DIR/run_server.sh"
    echo "Preserving existing $ROOT_DIR/run_server.sh"
fi

cat <<EOF

Build completed successfully.

Environment file:
  $ENV_FILE

Secnetperf:
  $SECNETPERF_BIN

To use this shell interactively:
  source ./greenquic-env.sh

To start the server after DPDK NIC binding and hugepages are ready:
  ./run_server.sh
EOF
