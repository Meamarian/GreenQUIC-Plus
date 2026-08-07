#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CORE_BOOTSTRAP="$ROOT_DIR/bootstrap_greenquic_core.sh"
MSR_CHECK="$ROOT_DIR/greenquic_test_suite_v22/common/bin/check_msr_pstate.sh"
ICE_HELPER="$ROOT_DIR/greenquic_test_suite_v22/common/bin/ensure_ice_firmware.sh"
TEST_DEPS_HELPER="$ROOT_DIR/greenquic_test_suite_v22/common/bin/ensure_test_python_deps.sh"
DPDK_DEVBIND="$ROOT_DIR/msquic/deps/dpdk/usertools/dpdk-devbind.py"

MSR_PSTATE_CHECK=1
MSR_CHECK_CPU=19
ICE_FIRMWARE_CHECK=1
BIND_DPDK_REQUESTED=0
DPDK_DRIVER_REQUEST="auto"
DPDK_PCI=""
FORWARD_ARGS=()

normalize_pci() {
    local pci="$1"
    if [[ "$pci" =~ ^[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]]; then
        printf '0000:%s\n' "$pci"
    else
        printf '%s\n' "$pci"
    fi
}

show_help() {
    cat <<'EOF'
Additional GreenQUIC host-readiness options:
  --msr-pstate-check       Run local MSR/P-state readiness check (default)
  --skip-msr-pstate-check  Skip the local MSR/P-state readiness check
  --ice-firmware           Ensure Intel ICE/E810 DDP firmware is installed (default)
  --skip-ice-firmware      Skip Intel ICE DDP firmware preparation

Safe DPDK binding policy:
  --bind-dpdk              Bind --pci after all builds and host setup finish
  --dpdk-driver NAME       auto, igb_uio, or vfio-pci only
                           default: auto; prefer igb_uio, otherwise vfio-pci

Before a Linux-managed NIC is detached, bootstrap brings its interface UP and
requires both carrier=1 and operstate=up. uio_pci_generic is never accepted.

The MSR/P-state, ICE firmware and NIC checks run only on the current server.
EOF
    echo
    "$CORE_BOOTSTRAP" --help | sed \
        -e 's/auto, igb_uio, uio_pci_generic, or vfio-pci/auto, igb_uio, or vfio-pci/g' \
        -e 's/prefer igb_uio, fall back to uio_pci_generic/prefer igb_uio, otherwise vfio-pci/g'
}

select_safe_dpdk_driver() {
    local requested="$1"

    case "$requested" in
        auto)
            modprobe uio 2>/dev/null || true
            if [[ -d /sys/module/igb_uio ]] || modprobe igb_uio 2>/dev/null; then
                printf 'igb_uio\n'
                return 0
            fi
            modprobe vfio-pci
            printf 'vfio-pci\n'
            ;;
        igb_uio)
            modprobe uio
            if [[ ! -d /sys/module/igb_uio ]]; then
                modprobe igb_uio
            fi
            printf 'igb_uio\n'
            ;;
        vfio-pci)
            modprobe vfio-pci
            printf 'vfio-pci\n'
            ;;
        *)
            echo "ERROR: unsafe/unsupported DPDK driver '$requested'." >&2
            echo "Only igb_uio or vfio-pci are accepted." >&2
            exit 2
            ;;
    esac
}

check_link_before_bind() {
    local pci_full="$1"
    local iface default_iface ssh_local_ip addr carrier operstate ethtool_link current_driver

    iface="$(find "/sys/bus/pci/devices/$pci_full/net" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | head -n1 || true)"

    if [[ -z "$iface" ]]; then
        current_driver="$(basename "$(readlink -f "/sys/bus/pci/devices/$pci_full/driver" 2>/dev/null || true)")"
        case "$current_driver" in
            igb_uio|vfio-pci)
                echo "PCI $pci_full is already bound to acceptable DPDK driver $current_driver."
                echo "Linux link/carrier check is not available after userspace binding; preserving the existing binding."
                printf '%s\n' "$current_driver"
                return 10
                ;;
            *)
                echo "ERROR: PCI $pci_full has no Linux netdev, so link-up cannot be verified." >&2
                echo "Current driver: ${current_driver:-none}" >&2
                exit 1
                ;;
        esac
    fi

    default_iface="$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}')"
    if [[ -n "$default_iface" && "$iface" == "$default_iface" ]]; then
        echo "ERROR: refusing to bind $pci_full because $iface carries the default route" >&2
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

    echo
    echo "===== DPDK PORT LINK CHECK ====="
    echo "PCI:       $pci_full"
    echo "Interface: $iface"

    ip link set dev "$iface" up
    sleep 1

    carrier="$(cat "/sys/class/net/$iface/carrier" 2>/dev/null || echo 0)"
    operstate="$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo unknown)"

    echo "carrier:   $carrier"
    echo "operstate: $operstate"
    ip -br link show dev "$iface" || true

    ethtool_link="unknown"
    if command -v ethtool >/dev/null 2>&1; then
        ethtool_link="$(ethtool "$iface" 2>/dev/null | awk -F': ' '/Link detected:/ {print $2; exit}')"
        echo "ethtool Link detected: ${ethtool_link:-unknown}"
    fi

    [[ "$carrier" == "1" ]] || {
        echo "ERROR: physical link is DOWN on $iface ($pci_full): carrier=$carrier" >&2
        exit 1
    }
    [[ "$operstate" == "up" ]] || {
        echo "ERROR: link is not operationally UP on $iface ($pci_full): operstate=$operstate" >&2
        exit 1
    }
    if [[ "$ethtool_link" != "unknown" && "$ethtool_link" != "yes" ]]; then
        echo "ERROR: ethtool does not report Link detected: yes on $iface" >&2
        exit 1
    fi

    echo "LINK CHECK: PASS — $iface is UP with carrier"
    printf '%s\n' "$iface"
}

bind_dpdk_safely() {
    local pci_full="$1"
    local requested_driver="$2"
    local link_result link_rc target_driver actual_driver iface

    [[ -e "/sys/bus/pci/devices/$pci_full" ]] || {
        echo "ERROR: PCI device $pci_full does not exist" >&2
        exit 1
    }
    [[ -f "$DPDK_DEVBIND" ]] || {
        echo "ERROR: missing DPDK device-binding tool: $DPDK_DEVBIND" >&2
        exit 1
    }

    set +e
    link_result="$(check_link_before_bind "$pci_full")"
    link_rc=$?
    set -e

    if ((link_rc == 10)); then
        actual_driver="$(printf '%s\n' "$link_result" | tail -n1)"
        echo "$link_result" | sed '$d'
        echo
        echo "DPDK BINDING: PASS — $pci_full already uses $actual_driver"
        return 0
    elif ((link_rc != 0)); then
        printf '%s\n' "$link_result" >&2
        exit "$link_rc"
    fi

    printf '%s\n' "$link_result"
    iface="$(printf '%s\n' "$link_result" | tail -n1)"

    target_driver="$(select_safe_dpdk_driver "$requested_driver")"
    case "$target_driver" in
        igb_uio|vfio-pci) ;;
        *)
            echo "ERROR: internal safety failure: selected unacceptable driver $target_driver" >&2
            exit 1
            ;;
    esac

    echo
    echo "Bringing $iface down immediately before DPDK detach..."
    ip link set dev "$iface" down

    echo "Binding $pci_full to $target_driver..."
    python3 "$DPDK_DEVBIND" --bind="$target_driver" "$pci_full"

    actual_driver="$(basename "$(readlink -f "/sys/bus/pci/devices/$pci_full/driver" 2>/dev/null || true)")"
    case "$actual_driver" in
        igb_uio|vfio-pci) ;;
        *)
            echo "ERROR: $pci_full ended on unacceptable driver '${actual_driver:-none}'" >&2
            python3 "$DPDK_DEVBIND" --status-dev net >&2 || true
            exit 1
            ;;
    esac
    [[ "$actual_driver" == "$target_driver" ]] || {
        echo "ERROR: requested $target_driver but actual driver is $actual_driver" >&2
        exit 1
    }

    echo "DPDK BINDING: PASS — $pci_full -> $actual_driver"
}

while (($#)); do
    case "$1" in
        --skip-msr-pstate-check)
            MSR_PSTATE_CHECK=0
            shift
            ;;
        --msr-pstate-check)
            MSR_PSTATE_CHECK=1
            shift
            ;;
        --ice-firmware)
            ICE_FIRMWARE_CHECK=1
            shift
            ;;
        --skip-ice-firmware)
            ICE_FIRMWARE_CHECK=0
            shift
            ;;
        --lcores)
            [[ $# -ge 2 ]] || { echo "ERROR: --lcores needs a value" >&2; exit 2; }
            LCORE_VALUE="$2"
            FIRST_LCORE="${LCORE_VALUE%%[,-]*}"
            if [[ "$FIRST_LCORE" =~ ^[0-9]+$ ]]; then
                MSR_CHECK_CPU="$FIRST_LCORE"
            fi
            FORWARD_ARGS+=("$1" "$2")
            shift 2
            ;;
        --pci)
            [[ $# -ge 2 ]] || { echo "ERROR: --pci needs a value" >&2; exit 2; }
            DPDK_PCI="$2"
            FORWARD_ARGS+=("$1" "$2")
            shift 2
            ;;
        --bind-dpdk)
            BIND_DPDK_REQUESTED=1
            shift
            ;;
        --dpdk-driver)
            [[ $# -ge 2 ]] || { echo "ERROR: --dpdk-driver needs a value" >&2; exit 2; }
            DPDK_DRIVER_REQUEST="$2"
            BIND_DPDK_REQUESTED=1
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            FORWARD_ARGS+=("$1")
            shift
            ;;
    esac
done

case "$DPDK_DRIVER_REQUEST" in
    auto|igb_uio|vfio-pci) ;;
    *)
        echo "ERROR: --dpdk-driver '$DPDK_DRIVER_REQUEST' is not allowed." >&2
        echo "Only auto, igb_uio, or vfio-pci may be requested; auto resolves only to igb_uio or vfio-pci." >&2
        exit 2
        ;;
esac

if ((BIND_DPDK_REQUESTED)); then
    [[ -n "$DPDK_PCI" ]] || {
        echo "ERROR: --bind-dpdk/--dpdk-driver requires --pci" >&2
        exit 2
    }
    ((EUID == 0)) || {
        echo "ERROR: DPDK NIC binding requires running bootstrap as root" >&2
        exit 1
    }
fi

[[ -x "$CORE_BOOTSTRAP" ]] || {
    echo "ERROR: missing executable core bootstrap: $CORE_BOOTSTRAP" >&2
    exit 1
}

if ((MSR_PSTATE_CHECK)); then
    [[ -f "$MSR_CHECK" ]] || {
        echo "ERROR: missing MSR/P-state check helper: $MSR_CHECK" >&2
        exit 1
    }

    if ! command -v rdmsr >/dev/null 2>&1; then
        ((EUID == 0)) || {
            echo "ERROR: rdmsr is missing and msr-tools installation requires root" >&2
            exit 1
        }
        echo "Installing msr-tools for local MSR/P-state readiness check..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get -y --no-install-recommends --no-remove --no-upgrade install msr-tools
    fi

    bash "$MSR_CHECK" "$MSR_CHECK_CPU"
else
    echo "Local MSR/P-state readiness check disabled by --skip-msr-pstate-check."
fi

if ((ICE_FIRMWARE_CHECK)); then
    [[ -f "$ICE_HELPER" ]] || {
        echo "ERROR: missing ICE firmware helper: $ICE_HELPER" >&2
        exit 1
    }
    bash "$ICE_HELPER" "$DPDK_PCI"
else
    echo "Intel ICE DDP firmware preparation disabled by --skip-ice-firmware."
fi

[[ -f "$TEST_DEPS_HELPER" ]] || {
    echo "ERROR: missing GreenQUIC test dependency helper: $TEST_DEPS_HELPER" >&2
    exit 1
}
bash "$TEST_DEPS_HELPER"

# The public wrapper performs ICE firmware preparation and safe NIC binding.
# Disable both legacy core actions here so the old fallback code cannot select
# uio_pci_generic and the old firmware source discovery cannot trip pipefail.
"$CORE_BOOTSTRAP" "${FORWARD_ARGS[@]}" --skip-ice-firmware

# Tighten the generated runtime guard as well. The public bootstrap never
# accepts uio_pci_generic, and run_server.sh should not accept it either.
if [[ -f "$ROOT_DIR/run_server.sh" ]]; then
    sed -i 's/igb_uio|vfio-pci|uio_pci_generic/igb_uio|vfio-pci/g' "$ROOT_DIR/run_server.sh"
fi

if ((BIND_DPDK_REQUESTED)); then
    bind_dpdk_safely "$(normalize_pci "$DPDK_PCI")" "$DPDK_DRIVER_REQUEST"
fi

echo
echo "============================================================"
echo "GREENQUIC BOOTSTRAP: SUCCESS on $(hostname)"
if ((BIND_DPDK_REQUESTED)); then
    FINAL_DRIVER="$(basename "$(readlink -f "/sys/bus/pci/devices/$(normalize_pci "$DPDK_PCI")/driver" 2>/dev/null || true)")"
    echo "DPDK PCI:    $(normalize_pci "$DPDK_PCI")"
    echo "DPDK driver: $FINAL_DRIVER"
    case "$FINAL_DRIVER" in
        igb_uio|vfio-pci) ;;
        *) echo "ERROR: final DPDK driver is unacceptable: ${FINAL_DRIVER:-none}" >&2; exit 1 ;;
    esac
fi
echo "============================================================"
