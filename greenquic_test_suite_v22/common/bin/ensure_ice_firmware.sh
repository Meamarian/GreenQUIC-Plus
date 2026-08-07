#!/usr/bin/env bash
set -Eeuo pipefail

PCI="${1:-}"
PACKAGE="firmware-intel-misc"

normalize_pci() {
    local pci="$1"
    if [[ "$pci" =~ ^[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]]; then
        printf '0000:%s\n' "$pci"
    else
        printf '%s\n' "$pci"
    fi
}

find_ice_pkg() {
    local f
    for f in \
        /lib/firmware/intel/ice/ddp/ice.pkg \
        /usr/lib/firmware/intel/ice/ddp/ice.pkg; do
        if [[ -e "$f" ]]; then
            readlink -f "$f"
            return 0
        fi
    done
    return 1
}

uses_intel_ice() {
    local info pci_full

    command -v lspci >/dev/null 2>&1 || return 1

    if [[ -n "$PCI" ]]; then
        pci_full="$(normalize_pci "$PCI")"
        [[ -e "/sys/bus/pci/devices/$pci_full" ]] || return 1
        info="$(lspci -Dk -s "$pci_full" 2>/dev/null || true)"
        grep -Eqi 'E810|Kernel driver in use:[[:space:]]*ice|Kernel modules:[[:space:]].*\bice\b' <<< "$info"
        return $?
    fi

    lspci -Dk 2>/dev/null | grep -Eqi 'E810|Kernel driver in use:[[:space:]]*ice|Kernel modules:[[:space:]].*\bice\b'
}

first_primary_uri() {
    local value=""

    value="$(
        {
            grep -RhsE '^URIs:[[:space:]]+' /etc/apt/sources.list.d 2>/dev/null || true
        } |
        awk '{for (i=2; i<=NF; i++) if ($i !~ /security/) {print $i; exit}}'
    )"

    if [[ -z "$value" ]]; then
        value="$(
            {
                grep -RhsE '^[[:space:]]*deb[[:space:]]+' \
                    /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true
            } |
            awk '$2 !~ /security/ {print $2; exit}'
        )"
    fi

    printf '%s\n' "${value:-http://deb.debian.org/debian}"
}

first_security_uri() {
    local value=""

    value="$(
        {
            grep -RhsE '^URIs:[[:space:]]+' /etc/apt/sources.list.d 2>/dev/null || true
        } |
        awk '{for (i=2; i<=NF; i++) if ($i ~ /security/) {print $i; exit}}'
    )"

    if [[ -z "$value" ]]; then
        value="$(
            {
                grep -RhsE '^[[:space:]]*deb[[:space:]]+' \
                    /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true
            } |
            awk '$2 ~ /security/ {print $2; exit}'
        )"
    fi

    printf '%s\n' "${value:-http://security.debian.org/debian-security}"
}

if ! uses_intel_ice; then
    echo "Intel ICE/E810 device not detected; ICE DDP firmware preparation not needed."
    exit 0
fi

if firmware="$(find_ice_pkg)"; then
    echo "Intel ICE DDP firmware already present: $firmware"
    exit 0
fi

((EUID == 0)) || {
    echo "ERROR: Intel ICE DDP firmware is missing and installation requires root." >&2
    exit 1
}

[[ -r /etc/os-release ]] || {
    echo "ERROR: cannot identify Linux distribution for ICE firmware setup" >&2
    exit 1
}

# shellcheck disable=SC1091
. /etc/os-release

[[ "${ID:-}" == "debian" && -n "${VERSION_CODENAME:-}" ]] || {
    echo "ERROR: automatic ICE DDP firmware repair is supported here only on Debian." >&2
    exit 1
}

codename="$VERSION_CODENAME"
candidate="$(apt-cache policy "$PACKAGE" 2>/dev/null | awk '/Candidate:/ {print $2; exit}' || true)"

if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
    primary_uri="$(first_primary_uri)"
    security_uri="$(first_security_uri)"
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
    echo "  primary:  $primary_uri"
    echo "  security: $security_uri"

    apt-get update
    candidate="$(apt-cache policy "$PACKAGE" 2>/dev/null | awk '/Candidate:/ {print $2; exit}' || true)"
fi

[[ -n "$candidate" && "$candidate" != "(none)" ]] || {
    echo "ERROR: $PACKAGE is unavailable even after enabling non-free-firmware." >&2
    apt-cache policy "$PACKAGE" >&2 || true
    exit 1
}

export DEBIAN_FRONTEND=noninteractive
apt-get -y --no-remove --no-upgrade install "$PACKAGE"

firmware="$(find_ice_pkg || true)"
[[ -n "$firmware" && -e "$firmware" ]] || {
    echo "ERROR: $PACKAGE installed but intel/ice/ddp/ice.pkg is still missing." >&2
    dpkg -L "$PACKAGE" | grep -E '/intel/ice/ddp/.*\.pkg$' >&2 || true
    exit 1
}

echo "Intel ICE DDP firmware ready: $firmware"
