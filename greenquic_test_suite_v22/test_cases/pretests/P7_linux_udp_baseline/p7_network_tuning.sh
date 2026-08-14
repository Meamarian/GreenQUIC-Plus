#!/usr/bin/env bash
set -Eeuo pipefail

p7_tune_log(){ printf '\n[%s][P7-net] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S.%3N%z')" "$*" >&2; }
p7_tune_warn(){ printf '\n[%s][P7-net:WARN] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S.%3N%z')" "$*" >&2; }
p7_tune_die(){ printf '\n[%s][P7-net:ERROR] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S.%3N%z')" "$*" >&2; exit 2; }

p7_tune_nonneg_int(){ [[ "${1:-}" =~ ^[0-9]+$ ]]; }

p7_tune_validate() {
    p7_tune_nonneg_int "${P7_UDP_RMEM_BYTES:-0}" || p7_tune_die "P7_UDP_RMEM_BYTES must be a non-negative integer"
    p7_tune_nonneg_int "${P7_UDP_WMEM_BYTES:-0}" || p7_tune_die "P7_UDP_WMEM_BYTES must be a non-negative integer"
    p7_tune_nonneg_int "${P7_COMBINED_CHANNELS:-0}" || p7_tune_die "P7_COMBINED_CHANNELS must be a non-negative integer"
    case "${P7_PAPER_OFFLOADS:-0}" in 0|1) ;; *) p7_tune_die "P7_PAPER_OFFLOADS must be 0 or 1" ;; esac
    command -v ethtool >/dev/null || p7_tune_die "ethtool is required"
    command -v sysctl >/dev/null || p7_tune_die "sysctl is required"
}

p7_tune_sysctl_get(){ sysctl -n "$1" 2>/dev/null; }

p7_tune_set_exact_pair() {
    local default_key="$1" max_key="$2" target_default="$3" target_max="$4" cur_default
    cur_default="$(p7_tune_sysctl_get "$default_key")" || p7_tune_die "cannot read $default_key"
    if (( target_max < cur_default )); then
        sysctl -q -w "$default_key=$target_default" || p7_tune_die "failed to set $default_key=$target_default"
        sysctl -q -w "$max_key=$target_max" || p7_tune_die "failed to set $max_key=$target_max"
    else
        sysctl -q -w "$max_key=$target_max" || p7_tune_die "failed to set $max_key=$target_max"
        sysctl -q -w "$default_key=$target_default" || p7_tune_die "failed to set $default_key=$target_default"
    fi
    [[ "$(p7_tune_sysctl_get "$default_key")" == "$target_default" ]] || p7_tune_die "$default_key did not take requested value $target_default"
    [[ "$(p7_tune_sysctl_get "$max_key")" == "$target_max" ]] || p7_tune_die "$max_key did not take requested value $target_max"
}

p7_tune_set_pair() {
    p7_tune_set_exact_pair "$1" "$2" "$3" "$3"
}

p7_tune_save_socket_buffers() {
    local out="$1" key value
    : > "$out"
    for key in net.core.rmem_default net.core.rmem_max net.core.wmem_default net.core.wmem_max; do
        value="$(p7_tune_sysctl_get "$key")" || p7_tune_die "cannot save $key"
        [[ "$value" =~ ^[0-9]+$ ]] || p7_tune_die "non-numeric value while saving $key: ${value:-empty}"
        printf '%s=%s\n' "$key" "$value" >> "$out" || p7_tune_die "cannot save $key"
    done
}

p7_tune_restore_socket_buffers() {
    local file="$1" rdef rmax wdef wmax
    [[ -s "$file" ]] || return 0
    rdef="$(awk -F= '$1=="net.core.rmem_default" {print $2}' "$file")"
    rmax="$(awk -F= '$1=="net.core.rmem_max" {print $2}' "$file")"
    wdef="$(awk -F= '$1=="net.core.wmem_default" {print $2}' "$file")"
    wmax="$(awk -F= '$1=="net.core.wmem_max" {print $2}' "$file")"
    if (( ${P7_UDP_RMEM_BYTES:-0} > 0 )); then
        if [[ "$rdef" =~ ^[0-9]+$ && "$rmax" =~ ^[0-9]+$ ]]; then
            p7_tune_set_exact_pair net.core.rmem_default net.core.rmem_max "$rdef" "$rmax"
        else
            p7_tune_warn "saved receive socket-buffer state is invalid; not restoring it"
        fi
    fi
    if (( ${P7_UDP_WMEM_BYTES:-0} > 0 )); then
        if [[ "$wdef" =~ ^[0-9]+$ && "$wmax" =~ ^[0-9]+$ ]]; then
            p7_tune_set_exact_pair net.core.wmem_default net.core.wmem_max "$wdef" "$wmax"
        else
            p7_tune_warn "saved send socket-buffer state is invalid; not restoring it"
        fi
    fi
}

p7_tune_current_combined() {
    ethtool -l "$1" 2>/dev/null | awk '
        /^Current hardware settings:/ {current=1; next}
        current && $1=="Combined:" {print $2; exit}'
}

p7_tune_max_combined() {
    ethtool -l "$1" 2>/dev/null | awk '
        /^Pre-set maximums:/ {maximum=1; next}
        /^Current hardware settings:/ {maximum=0}
        maximum && $1=="Combined:" {print $2; exit}'
}

p7_tune_save_channels() {
    local iface="$1" out="$2" cur
    cur="$(p7_tune_current_combined "$iface" || true)"
    if [[ "$cur" =~ ^[1-9][0-9]*$ ]]; then printf '%s\n' "$cur" > "$out"; else printf 'unsupported\n' > "$out"; fi
}

p7_tune_apply_channels() {
    local iface="$1" requested="${P7_COMBINED_CHANNELS:-0}" cur max
    (( requested > 0 )) || return 0
    cur="$(p7_tune_current_combined "$iface" || true)"
    [[ "$cur" =~ ^[1-9][0-9]*$ ]] || p7_tune_die "$iface does not expose a tunable Combined channel count via ethtool -l"
    [[ "$cur" == "$requested" ]] && { p7_tune_log "$iface combined channels already $requested"; return 0; }
    max="$(p7_tune_max_combined "$iface" || true)"
    [[ "$max" =~ ^[1-9][0-9]*$ ]] || p7_tune_die "$iface does not report a numeric maximum Combined channel count"
    (( requested <= max )) || p7_tune_die "$iface requested combined=$requested exceeds NIC maximum=$max"
    ethtool -L "$iface" combined "$requested" >/dev/null 2>&1 || p7_tune_die "$iface rejected ethtool -L combined $requested"
    cur="$(p7_tune_current_combined "$iface" || true)"
    [[ "$cur" == "$requested" ]] || p7_tune_die "$iface combined channel verification failed: requested=$requested effective=${cur:-unknown}"
    p7_tune_log "$iface combined channels set to $requested (max=$max)"
}

p7_tune_restore_channels() {
    local iface="$1" file="$2" saved cur max
    (( ${P7_COMBINED_CHANNELS:-0} > 0 )) || return 0
    [[ -s "$file" ]] || return 0
    saved="$(cat "$file")"
    [[ "$saved" =~ ^[1-9][0-9]*$ ]] || return 0
    cur="$(p7_tune_current_combined "$iface" || true)"
    [[ "$cur" == "$saved" ]] && return 0
    max="$(p7_tune_max_combined "$iface" || true)"
    if [[ ! "$max" =~ ^[1-9][0-9]*$ || "$saved" -gt "$max" ]]; then
        p7_tune_warn "$iface cannot restore combined channels to $saved (max=${max:-unknown})"
        return 1
    fi
    ethtool -L "$iface" combined "$saved" >/dev/null 2>&1 || { p7_tune_warn "$iface failed to restore combined channels=$saved"; return 1; }
}

p7_tune_offload_query_name() {
    case "$1" in
        rx) echo rx-checksumming ;;
        tx) echo tx-checksumming ;;
        gro) echo generic-receive-offload ;;
        gso) echo generic-segmentation-offload ;;
        tso) echo tcp-segmentation-offload ;;
        rx-gro-hw) echo rx-gro-hw ;;
        tx-udp-segmentation) echo tx-udp-segmentation ;;
        *) echo "$1" ;;
    esac
}

p7_tune_offload_state() {
    local iface="$1" cmd="$2" q
    q="$(p7_tune_offload_query_name "$cmd")"
    ethtool -k "$iface" 2>/dev/null | awk -v k="$q" '$1==k":" {print $2; exit}'
}

p7_tune_set_offload() {
    local iface="$1" cmd="$2" target="$3" required="$4" state rc=0
    ethtool -K "$iface" "$cmd" "$target" >/dev/null 2>&1 || rc=$?
    state="$(p7_tune_offload_state "$iface" "$cmd" || true)"
    if [[ "$state" == "$target" ]]; then
        (( rc == 0 )) || p7_tune_log "$iface $cmd already/effectively $target despite ethtool rc=$rc"
        return 0
    fi
    if [[ "$required" == 1 ]]; then
        p7_tune_die "$iface required offload '$cmd' could not be set to $target (effective=${state:-unsupported}, rc=$rc)"
    fi
    p7_tune_warn "$iface optional offload '$cmd' unavailable/not-$target (effective=${state:-unsupported}, rc=$rc)"
}

p7_tune_apply_paper_offloads() {
    local iface="$1"
    [[ "${P7_PAPER_OFFLOADS:-0}" == 1 ]] || return 0
    # Matches the paper artifact: TSO/GSO/TX checksum/GRO are mandatory;
    # UDP segmentation, RX checksum and hardware GRO are best effort.
    p7_tune_set_offload "$iface" tso on 1
    p7_tune_set_offload "$iface" gso on 1
    p7_tune_set_offload "$iface" tx on 1
    p7_tune_set_offload "$iface" tx-udp-segmentation on 0
    p7_tune_set_offload "$iface" gro on 1
    p7_tune_set_offload "$iface" rx on 0
    p7_tune_set_offload "$iface" rx-gro-hw on 0
    p7_tune_log "$iface paper-style GSO/GRO profile verified"
}

p7_tune_prepare() {
    local role="$1" state_dir="$2" iface
    p7_tune_validate
    iface="$(cat "$state_dir/iface" 2>/dev/null || true)"
    [[ -n "$iface" && -e "/sys/class/net/$iface" ]] || p7_tune_die "$role tuning cannot find prepared Linux interface from $state_dir/iface"
    p7_tune_save_socket_buffers "$state_dir/socket_buffers.before"
    p7_tune_save_channels "$iface" "$state_dir/channels.before"
    (( ${P7_UDP_RMEM_BYTES:-0} > 0 )) && p7_tune_set_pair net.core.rmem_default net.core.rmem_max "$P7_UDP_RMEM_BYTES"
    (( ${P7_UDP_WMEM_BYTES:-0} > 0 )) && p7_tune_set_pair net.core.wmem_default net.core.wmem_max "$P7_UDP_WMEM_BYTES"
    p7_tune_apply_channels "$iface"
    p7_tune_apply_paper_offloads "$iface"
    if [[ "${P7_SAVE_NETWORK_DIAGNOSTICS:-0}" == 1 ]]; then
        sysctl net.core.rmem_default net.core.rmem_max net.core.wmem_default net.core.wmem_max > "$state_dir/socket_buffers.effective.txt" 2>&1 || true
        ethtool -l "$iface" > "$state_dir/channels.txt" 2>&1 || true
        ethtool -k "$iface" > "$state_dir/offloads.effective.txt" 2>&1 || true
        cp "$state_dir/channels.txt" "$state_dir/channels.after_tuning.txt" 2>/dev/null || true
        cp "$state_dir/offloads.effective.txt" "$state_dir/offloads.after_tuning.txt" 2>/dev/null || true
    fi
    p7_tune_log "$role tuning applied: iface=$iface rmem=${P7_UDP_RMEM_BYTES:-0} wmem=${P7_UDP_WMEM_BYTES:-0} combined=${P7_COMBINED_CHANNELS:-0} paper_offloads=${P7_PAPER_OFFLOADS:-0}"
}

p7_tune_restore() {
    local role="$1" state_dir="$2" iface
    iface="$(cat "$state_dir/iface" 2>/dev/null || true)"
    [[ -n "$iface" && -e "/sys/class/net/$iface" ]] || return 0
    # Restore channel topology before p7_common restores saved IRQ/RPS state.
    p7_tune_restore_channels "$iface" "$state_dir/channels.before" || true
    p7_tune_restore_socket_buffers "$state_dir/socket_buffers.before" || true
    p7_tune_log "$role tuning state restored"
}

case "${1:-}" in
    prepare) shift; p7_tune_prepare "$@" ;;
    restore) shift; p7_tune_restore "$@" ;;
    validate) p7_tune_validate ;;
    "") ;;
    *) p7_tune_die "usage: $0 {prepare ROLE STATE_DIR|restore ROLE STATE_DIR|validate}" ;;
esac
