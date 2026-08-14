#!/usr/bin/env bash
set -Eeuo pipefail

P7_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SUITE_ROOT="$(cd -- "$P7_DIR/../../.." && pwd)"
REPO_ROOT="$(cd -- "$SUITE_ROOT/.." && pwd)"
source "$SUITE_ROOT/suite.env"
source "$P7_DIR/config.env"

P7_BUILD="${P7_BUILD:-$REPO_ROOT/msquic/build-linux-p7}"
P7_CLIENT_BIN="${P7_CLIENT_BIN:-$P7_BUILD/bin/Release/quicinterop}"
P7_SERVER_BIN="${P7_SERVER_BIN:-$P7_BUILD/bin/Release/quicinteropserver}"
P7_P5_DIR="$SUITE_ROOT/test_cases/pretests/P5_repeated_8GiB_downloads"
P7_COMMON_BIN="$SUITE_ROOT/common/bin"
P7_SERVER_ROOT="$SUITE_ROOT/common/files/server_root"
P7_CERT="$SUITE_ROOT/common/certs/server.crt"
P7_KEY="$SUITE_ROOT/common/certs/server.key"
P7_DEVBIND="$REPO_ROOT/msquic/deps/dpdk/usertools/dpdk-devbind.py"

p7_now(){ date '+%Y-%m-%dT%H:%M:%S.%3N%z'; }
p7_log(){ printf '\n[%s][P7-Linux] %s\n' "$(p7_now)" "$*" >&2; }
p7_warn(){ printf '\n[%s][P7-Linux:WARN] %s\n' "$(p7_now)" "$*" >&2; }
p7_die(){ printf '\n[%s][P7-Linux:ERROR] %s\n' "$(p7_now)" "$*" >&2; exit 2; }

p7_bool() {
    case "${1,,}" in
        1|true|yes|on) printf '1\n' ;;
        0|false|no|off) printf '0\n' ;;
        *) return 1 ;;
    esac
}

p7_validate_common() {
    [[ -x "$P7_CLIENT_BIN" ]] || p7_die "P7 client missing: $P7_CLIENT_BIN (run ./build_p7_linux.sh)"
    [[ -x "$P7_SERVER_BIN" ]] || p7_die "P7 server missing: $P7_SERVER_BIN (run ./build_p7_linux.sh)"
    [[ -x "$P7_COMMON_BIN/gq_rapl_msr_sampler" ]] || p7_die "RAPL sampler missing: $P7_COMMON_BIN/gq_rapl_msr_sampler"
    [[ -x "$P7_COMMON_BIN/gq_cstate_trace" ]] || p7_die "C-state recorder missing: $P7_COMMON_BIN/gq_cstate_trace"
    [[ -x "$P7_DIR/p7_frequency_sampler.py" ]] || p7_die "P7 frequency sampler missing"
    [[ -x "$P7_DIR/p7_mark.py" ]] || p7_die "P7 marker helper missing"
    [[ -f "$P7_P5_DIR/timestamp_tee_p5.py" ]] || p7_die "P5 timestamp tee missing"
    [[ -f "$P7_CERT" && -f "$P7_KEY" ]] || p7_die "server certificate/key missing"
    [[ "$DOWNLOADS_PER_RUN" =~ ^[1-9][0-9]*$ ]] || p7_die "DOWNLOADS_PER_RUN must be positive"
    [[ "$GAP_US" =~ ^[0-9]+$ ]] || p7_die "GAP_US must be non-negative"
    [[ "$PAYLOAD_BYTES" =~ ^[1-9][0-9]*$ ]] || p7_die "PAYLOAD_BYTES must be positive"
    case "$P7_NIC_OFFLOAD_PROFILE" in native|on|off) ;; *) p7_die "P7_NIC_OFFLOAD_PROFILE must be native|on|off" ;; esac
    p7_bool "${P7_SAVE_NETWORK_DIAGNOSTICS:-0}" >/dev/null || p7_die "P7_SAVE_NETWORK_DIAGNOSTICS must be 0 or 1"
}

p7_role_device() { case "$1" in server) printf '%s\n' "$SERVER_DPDK_DEVICE" ;; client) printf '%s\n' "$CLIENT_DPDK_DEVICE" ;; *) p7_die "invalid role $1" ;; esac; }
p7_role_ip() { case "$1" in server) printf '%s\n' "$P7_SERVER_IP" ;; client) printf '%s\n' "$P7_CLIENT_IP" ;; *) p7_die "invalid role $1" ;; esac; }
p7_role_expected_host() { case "$1" in server) printf '%s\n' "$SERVER_NAME" ;; client) printf '%s\n' "$CLIENT_NAME" ;; *) p7_die "invalid role $1" ;; esac; }
p7_check_host_role() { local role="$1" expected actual; expected="$(p7_role_expected_host "$role")"; actual="$(hostname -s)"; [[ "$actual" == "$expected" ]] || p7_die "role=$role requires host=$expected, current host=$actual"; }

p7_driver_for_device() {
    local device="$1"
    if [[ -L "/sys/bus/pci/devices/$device/driver" ]]; then basename "$(readlink -f "/sys/bus/pci/devices/$device/driver")"; else printf 'none\n'; fi
}

p7_bind_linux() {
    local role="$1" device iface ip
    device="$(p7_role_device "$role")"; ip="$(p7_role_ip "$role")"
    [[ -e "/sys/bus/pci/devices/$device" ]] || p7_die "PCI device not found: $device"
    command -v ip >/dev/null || p7_die "ip command missing"; command -v ethtool >/dev/null || p7_die "ethtool missing"
    modprobe ice
    if [[ "$(p7_driver_for_device "$device")" != ice ]]; then [[ -f "$P7_DEVBIND" ]] || p7_die "dpdk-devbind.py missing: $P7_DEVBIND"; python3 "$P7_DEVBIND" -b ice "$device"; fi
    for _ in $(seq 1 50); do iface="$(find "/sys/bus/pci/devices/$device/net" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | head -n1 || true)"; [[ -n "$iface" ]] && break; sleep 0.1; done
    [[ -n "${iface:-}" ]] || p7_die "kernel netdev did not appear for $device"
    ip link set dev "$iface" down || true; ip addr flush dev "$iface" || true; ip link set dev "$iface" mtu "$P7_MTU"; ip addr add "$ip/$P7_PREFIX_LEN" dev "$iface"; ip link set dev "$iface" up
    p7_log "$role Linux NIC ready: device=$device driver=$(p7_driver_for_device "$device") iface=$iface ip=$ip/$P7_PREFIX_LEN mtu=$P7_MTU"
    printf '%s\n' "$iface"
}

p7_get_iface() { local role="$1" device iface; device="$(p7_role_device "$role")"; iface="$(find "/sys/bus/pci/devices/$device/net" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | head -n1 || true)"; [[ -n "$iface" ]] || p7_die "no Linux netdev for $device; run prepare first"; printf '%s\n' "$iface"; }

p7_offload_query_name() { case "$1" in rx) echo rx-checksumming ;; tx) echo tx-checksumming ;; gro) echo generic-receive-offload ;; gso) echo generic-segmentation-offload ;; tso) echo tcp-segmentation-offload ;; rx-gro-hw) echo rx-gro-hw ;; tx-udp-segmentation) echo tx-udp-segmentation ;; rx-udp-gro-forwarding) echo rx-udp-gro-forwarding ;; *) echo "$1" ;; esac; }

# These tiny state files are restoration metadata only; they are not sampled/traced.
p7_save_offloads() { local iface="$1" out="$2" cmd q state; : > "$out"; for cmd in rx tx gro gso tso rx-gro-hw tx-udp-segmentation rx-udp-gro-forwarding; do q="$(p7_offload_query_name "$cmd")"; state="$(ethtool -k "$iface" 2>/dev/null | awk -v k="$q" '$1==k":" {print $2; exit}')"; [[ "$state" == on || "$state" == off ]] && printf '%s=%s\n' "$cmd" "$state" >> "$out"; done; }
p7_apply_offloads() { local iface="$1" profile="$2" target cmd; [[ "$profile" == native ]] && return 0; target="$profile"; for cmd in rx tx gro gso tso rx-gro-hw tx-udp-segmentation rx-udp-gro-forwarding; do ethtool -K "$iface" "$cmd" "$target" >/dev/null 2>&1 || true; done; }
p7_restore_offloads() { local iface="$1" state_file="$2" cmd state; [[ -f "$state_file" ]] || return 0; while IFS='=' read -r cmd state; do [[ -n "$cmd" && ( "$state" == on || "$state" == off ) ]] || continue; ethtool -K "$iface" "$cmd" "$state" >/dev/null 2>&1 || true; done < "$state_file"; }

p7_save_irq_state() { local iface="$1" out="$2" irq; : > "$out"; if [[ -d "/sys/class/net/$iface/device/msi_irqs" ]]; then for p in /sys/class/net/"$iface"/device/msi_irqs/*; do [[ -e "$p" ]] || continue; irq="${p##*/}"; [[ -r "/proc/irq/$irq/smp_affinity_list" ]] || continue; printf '%s=%s\n' "$irq" "$(cat "/proc/irq/$irq/smp_affinity_list")" >> "$out"; done; fi; }
p7_pin_irqs() { local iface="$1" cpu="$2" irq; [[ "$(p7_bool "$P7_PIN_IRQ")" == 1 ]] || return 0; if [[ -d "/sys/class/net/$iface/device/msi_irqs" ]]; then for p in /sys/class/net/"$iface"/device/msi_irqs/*; do [[ -e "$p" ]] || continue; irq="${p##*/}"; [[ -w "/proc/irq/$irq/smp_affinity_list" ]] || continue; printf '%s\n' "$cpu" > "/proc/irq/$irq/smp_affinity_list"; done; fi; }
p7_restore_irqs() { local f="$1" irq affinity; [[ -f "$f" ]] || return 0; while IFS='=' read -r irq affinity; do [[ -w "/proc/irq/$irq/smp_affinity_list" ]] || continue; printf '%s\n' "$affinity" > "/proc/irq/$irq/smp_affinity_list" || true; done < "$f"; }

p7_save_rps() { local iface="$1" out="$2" q; : > "$out"; for q in /sys/class/net/"$iface"/queues/rx-*/rps_cpus; do [[ -r "$q" ]] || continue; printf '%s=%s\n' "$q" "$(cat "$q")" >> "$out"; done; }
p7_disable_rps() { local iface="$1" q; [[ "$(p7_bool "$P7_DISABLE_RPS")" == 1 ]] || return 0; for q in /sys/class/net/"$iface"/queues/rx-*/rps_cpus; do [[ -w "$q" ]] || continue; printf '0\n' > "$q"; done; }
p7_restore_rps() { local f="$1" path value; [[ -f "$f" ]] || return 0; while IFS='=' read -r path value; do [[ -w "$path" ]] || continue; printf '%s\n' "$value" > "$path" || true; done < "$f"; }

p7_prepare_host() {
    local role="$1" state_dir="$2" iface was_irqbalance=0
    p7_validate_common; p7_check_host_role "$role"; mkdir -p "$state_dir"
    if systemctl is-active --quiet irqbalance 2>/dev/null; then was_irqbalance=1; fi
    printf '%s\n' "$was_irqbalance" > "$state_dir/irqbalance_was_active"
    iface="$(p7_bind_linux "$role")"; printf '%s\n' "$iface" > "$state_dir/iface"
    p7_save_offloads "$iface" "$state_dir/offloads.before"; p7_save_irq_state "$iface" "$state_dir/irq_affinity.before"; p7_save_rps "$iface" "$state_dir/rps.before"
    if [[ "$(p7_bool "$P7_STOP_IRQBALANCE")" == 1 ]]; then systemctl stop irqbalance >/dev/null 2>&1 || true; fi
    p7_apply_offloads "$iface" "$P7_NIC_OFFLOAD_PROFILE"; p7_pin_irqs "$iface" "$P7_DATAPLANE_CPU"; p7_disable_rps "$iface"
    if [[ "$(p7_bool "${P7_SAVE_NETWORK_DIAGNOSTICS:-0}")" == 1 ]]; then
        ethtool -k "$iface" > "$state_dir/offloads.effective.txt" 2>&1 || true
        ethtool -l "$iface" > "$state_dir/channels.txt" 2>&1 || true
        ethtool "$iface" > "$state_dir/link.txt" 2>&1 || true
        cat /proc/interrupts > "$state_dir/interrupts.after_prepare.txt" 2>/dev/null || true
    fi
    p7_log "$role prepared: iface=$iface IRQ-pin=$P7_PIN_IRQ cpu=$P7_DATAPLANE_CPU QUIC-cpus=$P7_QUIC_CPUS NIC-offloads=$P7_NIC_OFFLOAD_PROFILE network-diagnostics=${P7_SAVE_NETWORK_DIAGNOSTICS:-0}"
}

p7_restore_host() {
    local role="$1" state_dir="$2" iface device restore_dpdk
    iface="$(cat "$state_dir/iface" 2>/dev/null || true)"; device="$(p7_role_device "$role")"; restore_dpdk="$(p7_bool "$P7_RESTORE_DPDK_AFTER_RUN")"
    if [[ -n "$iface" && -e "/sys/class/net/$iface" ]]; then p7_restore_irqs "$state_dir/irq_affinity.before"; p7_restore_rps "$state_dir/rps.before"; p7_restore_offloads "$iface" "$state_dir/offloads.before"; fi
    if [[ "$(cat "$state_dir/irqbalance_was_active" 2>/dev/null || echo 0)" == 1 ]]; then systemctl start irqbalance >/dev/null 2>&1 || true; fi
    if [[ "$restore_dpdk" == 1 ]]; then
        if [[ -n "$iface" && -e "/sys/class/net/$iface" ]]; then ip link set dev "$iface" down 2>/dev/null || true; ip addr flush dev "$iface" 2>/dev/null || true; fi
        modprobe vfio-pci; [[ -f "$P7_DEVBIND" ]] || p7_die "dpdk-devbind.py missing while restoring DPDK"; python3 "$P7_DEVBIND" -b vfio-pci "$device"; p7_log "$role restored to driver=$(p7_driver_for_device "$device")"
    fi
}

p7_write_execution_config() {
    local role run_dir cfg
    role="$1"
    run_dir="$2"
    cfg="$run_dir/linux_msquic.ini"
    mkdir -p "$run_dir"
    cat > "$cfg" <<CFG
# P7 Linux baseline. These are tool-level MsQuic execution settings only.
# No DPDK datapath configuration is present.
GreenQuicQuicProfile=$MSQUIC_EXECUTION_PROFILE
GreenQuicQuicWorkerCpus=$P7_QUIC_CPUS
GreenQuicQuicAffinitize=$P7_PIN_QUIC
CFG
    printf '%s\n' "$cfg"
}

p7_effective_record_cpus() {
    local cpus="$P7_RECORD_CPUS"; if [[ "$(p7_bool "$P7_RECORD_QUIC_CPUS")" == 1 ]]; then cpus="$cpus,$P7_QUIC_CPUS"; fi
    python3 - "$cpus" <<'PY'
import sys
out=set()
for tok in sys.argv[1].replace(' ','').split(','):
    if not tok: continue
    if '-' in tok:
        a,b=map(int,tok.split('-',1)); out.update(range(a,b+1))
    else: out.add(int(tok))
print(','.join(map(str,sorted(out))))
PY
}

p7_choose_reader_cpu() {
    local measured="$1"
    python3 - "$measured" "$P7_QUIC_CPUS" <<'PY'
from pathlib import Path
import sys
def parse(s):
    out=set()
    for t in s.replace(' ','').split(','):
        if not t: continue
        if '-' in t:
            a,b=map(int,t.split('-',1)); out.update(range(a,b+1))
        else: out.add(int(t))
    return out
online=parse(Path('/sys/devices/system/cpu/online').read_text().strip())
used=parse(sys.argv[1]) | parse(sys.argv[2])
for cpu in list(used):
    p=Path(f'/sys/devices/system/cpu/cpu{cpu}/topology/thread_siblings_list')
    if p.exists(): used |= parse(p.read_text().strip())
left=sorted(online-used)
if not left: raise SystemExit('no housekeeping CPU available for C-state recorder')
print(left[0])
PY
}

p7_write_cstate_mapping() {
    local cpus="$1" out="$2" cpu s first=1
    {
        printf '{"schema":"greenquic-p7-cstate-map-v1","cpus":{'
        IFS=',' read -ra arr <<< "$cpus"
        for cpu in "${arr[@]}"; do
            [[ "$first" == 1 ]] || printf ','; first=0; printf '"%s":[' "$cpu"; local sf=1
            for s in /sys/devices/system/cpu/cpu"$cpu"/cpuidle/state*; do
                [[ -d "$s" ]] || continue; [[ "$sf" == 1 ]] || printf ','; sf=0
                python3 - "$s" <<'PY'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1])
row={'index':int(p.name.replace('state','')),'name':(p/'name').read_text().strip() if (p/'name').exists() else '','desc':(p/'desc').read_text().strip() if (p/'desc').exists() else '','latency_us':int((p/'latency').read_text()) if (p/'latency').exists() else None,'target_residency_us':int((p/'residency').read_text()) if (p/'residency').exists() else None}
print(json.dumps(row,separators=(',',':')), end='')
PY
            done
            printf ']'
        done
        printf '}}\n'
    } > "$out"
}

p7_capture_net_snapshot() {
    local role="$1" run_dir="$2" tag="$3" iface
    [[ "$(p7_bool "${P7_SAVE_NETWORK_DIAGNOSTICS:-0}")" == 1 ]] || return 0
    iface="$(p7_get_iface "$role")"
    ip -s link show "$iface" > "$run_dir/net_${tag}_ip_link.txt" 2>&1 || true
    ethtool -S "$iface" > "$run_dir/net_${tag}_ethtool_stats.txt" 2>&1 || true
    ethtool -k "$iface" > "$run_dir/net_${tag}_offloads.txt" 2>&1 || true
    cat /proc/softirqs > "$run_dir/net_${tag}_softirqs.txt" 2>/dev/null || true
    cat /proc/interrupts > "$run_dir/net_${tag}_interrupts.txt" 2>/dev/null || true
    cat /proc/net/softnet_stat > "$run_dir/net_${tag}_softnet_stat.txt" 2>/dev/null || true
}

P7_RAPL_PID=""; P7_FREQ_PID=""; P7_CSTATE_PID=""
p7_start_recorders() {
    local role="$1" run_dir="$2" cpus reader
    [[ "$(p7_bool "$ENABLE_RECORD")" == 1 ]] || return 0
    cpus="$(p7_effective_record_cpus)"; reader="$(p7_choose_reader_cpu "$cpus")"; p7_write_cstate_mapping "$cpus" "$run_dir/cstate_mapping.json"
    "$P7_COMMON_BIN/gq_rapl_msr_sampler" --output "$run_dir/rapl.csv" --interval-ms "$P7_RAPL_INTERVAL_MS" --smooth-samples "$P7_RAPL_SMOOTH_SAMPLES" > "$run_dir/rapl_sampler.log" 2>&1 & P7_RAPL_PID=$!
    python3 "$P7_DIR/p7_frequency_sampler.py" --cpus "$cpus" --output "$run_dir/frequency.jsonl" --interval-ms "$P7_FREQ_INTERVAL_MS" > "$run_dir/frequency_sampler.log" 2>&1 & P7_FREQ_PID=$!
    taskset -c "$reader" "$P7_COMMON_BIN/gq_cstate_trace" --cpus "$cpus" --output "$run_dir/cstate.csv" --summary "$run_dir/cstate.json" > "$run_dir/cstate_sampler.log" 2>&1 & P7_CSTATE_PID=$!
    sleep 0.12
    if [[ "$(p7_bool "$P7_REQUIRE_RAPL")" == 1 ]] && ! kill -0 "$P7_RAPL_PID" 2>/dev/null; then cat "$run_dir/rapl_sampler.log" >&2 || true; p7_die "required RAPL sampler failed to start"; fi
    p7_log "$role recorders started: RAPL=$P7_RAPL_PID frequency=$P7_FREQ_PID cstate=$P7_CSTATE_PID cpus=$cpus reader=$reader"
}

p7_stop_pid() { local pid="${1:-}" sig="${2:-TERM}"; [[ -n "$pid" ]] || return 0; if kill -0 "$pid" 2>/dev/null; then kill -s "$sig" "$pid" 2>/dev/null || true; fi; wait "$pid" 2>/dev/null || true; }
p7_stop_recorders() { p7_stop_pid "$P7_CSTATE_PID" TERM; p7_stop_pid "$P7_FREQ_PID" TERM; p7_stop_pid "$P7_RAPL_PID" TERM; }
p7_run_with_quic_affinity() { if [[ "$(p7_bool "$P7_PIN_QUIC")" == 1 ]]; then exec taskset -c "$P7_QUIC_CPUS" "$@"; else exec "$@"; fi; }
