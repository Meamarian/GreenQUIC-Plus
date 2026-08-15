#!/usr/bin/env bash
set -Eeuo pipefail

p7_rdma_log(){ printf '\n[%s][P7-rdma] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S.%3N%z')" "$*" >&2; }
p7_rdma_warn(){ printf '\n[%s][P7-rdma:WARN] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S.%3N%z')" "$*" >&2; }
p7_rdma_die(){ printf '\n[%s][P7-rdma:ERROR] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S.%3N%z')" "$*" >&2; exit 2; }

p7_rdma_validate() {
    case "${P7_DISABLE_RDMA:-0}" in
        0|1) ;;
        *) p7_rdma_die "P7_DISABLE_RDMA must be 0 or 1" ;;
    esac
}

p7_rdma_iface_device() {
    local iface="$1" target
    target="$(readlink -f "/sys/class/net/$iface/device" 2>/dev/null || true)"
    [[ -n "$target" ]] || return 1
    basename "$target"
}

p7_rdma_find_bound_aux() {
    local device="$1" a real driver name found=""
    for a in /sys/bus/auxiliary/devices/*; do
        [[ -e "$a" ]] || continue
        real="$(readlink -f "$a" 2>/dev/null || true)"
        [[ "$real" == *"/$device/"* ]] || continue
        driver="$(basename "$(readlink -f "$a/driver" 2>/dev/null)" 2>/dev/null || true)"
        [[ "$driver" == irdma ]] || continue
        name="$(basename "$a")"
        if [[ -n "$found" ]]; then
            p7_rdma_die "multiple irdma auxiliary children found for PCI $device: $found and $name"
        fi
        found="$name"
    done
    printf '%s\n' "$found"
}

p7_rdma_driver_name() {
    local aux="$1"
    basename "$(readlink -f "/sys/bus/auxiliary/devices/$aux/driver" 2>/dev/null)" 2>/dev/null || true
}

p7_rdma_prepare() {
    local role="$1" state_dir="$2" iface device aux
    p7_rdma_validate
    [[ "${P7_DISABLE_RDMA:-0}" == 1 ]] || return 0

    iface="$(cat "$state_dir/iface" 2>/dev/null || true)"
    [[ -n "$iface" && -e "/sys/class/net/$iface" ]] ||
        p7_rdma_die "$role RDMA setup cannot find prepared Linux interface from $state_dir/iface"

    device="$(p7_rdma_iface_device "$iface" || true)"
    [[ "$device" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]] ||
        p7_rdma_die "$role cannot determine PCI device for interface $iface"

    printf '%s\n' "$device" > "$state_dir/rdma_pci_device"
    aux="$(p7_rdma_find_bound_aux "$device")"

    if [[ -z "$aux" ]]; then
        printf '0\n' > "$state_dir/rdma_was_bound"
        : > "$state_dir/rdma_aux_name"
        p7_rdma_log "$role no bound irdma auxiliary child found for $device; nothing to disable"
        return 0
    fi

    [[ -w /sys/bus/auxiliary/drivers/irdma/unbind ]] ||
        p7_rdma_die "$role cannot write /sys/bus/auxiliary/drivers/irdma/unbind"

    printf '%s\n' "$aux" > "$state_dir/rdma_aux_name"
    printf '1\n' > "$state_dir/rdma_was_bound"

    printf '%s\n' "$aux" > /sys/bus/auxiliary/drivers/irdma/unbind ||
        p7_rdma_die "$role failed to unbind RDMA auxiliary child $aux"

    if [[ "$(p7_rdma_driver_name "$aux")" == irdma ]]; then
        p7_rdma_die "$role RDMA auxiliary child $aux is still bound to irdma after unbind"
    fi
    [[ -e "/sys/class/net/$iface" ]] ||
        p7_rdma_die "$role Ethernet interface $iface disappeared after unbinding $aux"

    p7_rdma_log "$role unbound $aux from irdma for PCI $device; Ethernet interface $iface remains present"
}

p7_rdma_restore() {
    local role="$1" state_dir="$2" aux was_bound driver
    p7_rdma_validate
    [[ "${P7_DISABLE_RDMA:-0}" == 1 ]] || return 0

    was_bound="$(cat "$state_dir/rdma_was_bound" 2>/dev/null || echo 0)"
    [[ "$was_bound" == 1 ]] || return 0
    aux="$(cat "$state_dir/rdma_aux_name" 2>/dev/null || true)"
    [[ -n "$aux" ]] || { p7_rdma_warn "$role saved RDMA state says bound but auxiliary name is missing"; return 1; }

    driver="$(p7_rdma_driver_name "$aux")"
    if [[ "$driver" == irdma ]]; then
        p7_rdma_log "$role RDMA auxiliary child $aux already rebound to irdma"
        return 0
    fi

    [[ -e "/sys/bus/auxiliary/devices/$aux" ]] ||
        { p7_rdma_warn "$role RDMA auxiliary child $aux no longer exists"; return 1; }
    [[ -w /sys/bus/auxiliary/drivers/irdma/bind ]] ||
        { p7_rdma_warn "$role cannot write /sys/bus/auxiliary/drivers/irdma/bind"; return 1; }

    printf '%s\n' "$aux" > /sys/bus/auxiliary/drivers/irdma/bind ||
        { p7_rdma_warn "$role failed to rebind RDMA auxiliary child $aux"; return 1; }

    driver="$(p7_rdma_driver_name "$aux")"
    [[ "$driver" == irdma ]] ||
        { p7_rdma_warn "$role RDMA auxiliary child $aux did not rebind to irdma (driver=${driver:-none})"; return 1; }

    p7_rdma_log "$role rebound $aux to irdma"
}

case "${1:-}" in
    prepare) shift; p7_rdma_prepare "$@" ;;
    restore) shift; p7_rdma_restore "$@" ;;
    validate) p7_rdma_validate ;;
    "") ;;
    *) p7_rdma_die "usage: $0 {prepare ROLE STATE_DIR|restore ROLE STATE_DIR|validate}" ;;
esac
