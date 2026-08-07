#!/usr/bin/env bash
set -Eeuo pipefail

CPU="${1:-19}"

[[ "$CPU" =~ ^[0-9]+$ ]] || {
    echo "ERROR: MSR/P-state check CPU must be a non-negative integer: $CPU" >&2
    exit 2
}

if ((EUID == 0)); then
    PRIV=()
elif command -v sudo >/dev/null 2>&1; then
    PRIV=(sudo)
else
    echo "ERROR: MSR/P-state readiness check requires root or sudo" >&2
    exit 1
fi

echo
echo "=================================================="
echo "LOCAL MSR/PSTATE CHECK: $(hostname)"
echo "CHECK CPU: $CPU"
echo "=================================================="

echo
echo "===== CPU ====="
lscpu | grep -E 'Model name|Vendor ID|CPU\(s\)|Thread|Core' || true

[[ -d "/sys/devices/system/cpu/cpu${CPU}" ]] || {
    echo "ERROR: CPU $CPU does not exist on $(hostname)" >&2
    exit 1
}

echo
echo "===== MSR KERNEL MODULE ====="
if ! lsmod | grep -q '^msr '; then
    echo "Loading msr module..."
    "${PRIV[@]}" modprobe msr
fi

lsmod | grep '^msr ' || {
    echo "ERROR: msr module not loaded" >&2
    exit 1
}

echo
echo "===== /dev/cpu/${CPU}/msr ====="
MSR_DEV="/dev/cpu/${CPU}/msr"
[[ -e "$MSR_DEV" ]] || {
    echo "ERROR: $MSR_DEV missing after loading msr module" >&2
    exit 1
}
ls -l "$MSR_DEV"

echo
echo "===== RDMSR TOOL ====="
command -v rdmsr >/dev/null 2>&1 || {
    echo "ERROR: rdmsr is missing; install Debian package msr-tools" >&2
    exit 1
}
command -v rdmsr

echo
echo "===== PLATFORM INFO MSR 0xCE ====="
MSR_RAW="$("${PRIV[@]}" rdmsr -p "$CPU" 0xCE)"
[[ "$MSR_RAW" =~ ^[0-9a-fA-F]+$ ]] || {
    echo "ERROR: invalid rdmsr value for MSR 0xCE: $MSR_RAW" >&2
    exit 1
}
MAX_NON_TURBO_RATIO=$(( (0x${MSR_RAW} >> 8) & 0xff ))
((MAX_NON_TURBO_RATIO > 0)) || {
    echo "ERROR: invalid max non-turbo ratio decoded from MSR 0xCE" >&2
    exit 1
}
echo "MSR 0xCE raw: $MSR_RAW"
echo "Max non-turbo ratio: $MAX_NON_TURBO_RATIO"
echo "MSR READ: OK"

echo
echo "===== CPUFREQ CPU${CPU} ====="
CPUFREQ="/sys/devices/system/cpu/cpu${CPU}/cpufreq"
[[ -d "$CPUFREQ" ]] || {
    echo "ERROR: $CPUFREQ is missing" >&2
    exit 1
}

for item in \
    scaling_driver \
    scaling_governor \
    scaling_available_governors \
    cpuinfo_min_freq \
    cpuinfo_max_freq \
    scaling_min_freq \
    scaling_max_freq \
    scaling_cur_freq; do
    path="$CPUFREQ/$item"
    if [[ -r "$path" ]]; then
        printf '%-31s: %s\n' "$item" "$(cat "$path")"
    else
        printf '%-31s: %s\n' "$item" "unavailable"
    fi
done

[[ -r "$CPUFREQ/scaling_driver" ]] || {
    echo "ERROR: cpufreq scaling driver is unavailable for CPU $CPU" >&2
    exit 1
}

echo
echo "===== INTEL_PSTATE ====="
PSTATE="/sys/devices/system/cpu/intel_pstate"
[[ -d "$PSTATE" ]] || {
    echo "ERROR: Intel P-state sysfs directory is missing: $PSTATE" >&2
    exit 1
}

for item in status no_turbo min_perf_pct max_perf_pct turbo_pct; do
    path="$PSTATE/$item"
    if [[ -r "$path" ]]; then
        printf '%-20s: %s\n' "$item" "$(cat "$path")"
    else
        printf '%-20s: %s\n' "$item" "unavailable"
    fi
done

[[ -r "$PSTATE/status" ]] || {
    echo "ERROR: Intel P-state status is unavailable" >&2
    exit 1
}

echo
echo "===== CPU IDLE / WAITPKG ====="
CPU_FEATURE="$(grep -m1 '^flags' /proc/cpuinfo | tr ' ' '\n' | grep -E '^(waitpkg|monitor)$' | paste -sd ',' - || true)"
if [[ -n "$CPU_FEATURE" ]]; then
    echo "$CPU_FEATURE"
else
    echo "No waitpkg/monitor CPU flag reported"
fi

echo
echo "MSR/PSTATE CHECK: OK on $(hostname) (CPU $CPU)"
