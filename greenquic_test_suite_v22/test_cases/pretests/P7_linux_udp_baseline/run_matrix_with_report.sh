#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
BASE="$HERE/run_matrix_from_idex.sh"
REPORTER="$HERE/build_p7_report.py"
SUMMARY="$HERE/p7_print_summary.py"
CLIENT_HOST="tinyman"
CLIENT_DIR="$HERE"
CHART_STYLE="both"
LOG_LEVEL="0"
OUTPUT_DIR=""
ARGS=()

now(){ date '+%Y-%m-%dT%H:%M:%S.%3N%z'; }
stage(){ printf '\n[%s][P7-report] %s\n' "$(now)" "$*"; }

usage() {
    cat <<'USAGE'
P7 Linux UDP matrix with P5-style report generation.

P7-only wrapper options:
  --chart-style new|old|both   default both; new/both generate the P7 report tree
  --log-level 0|1              1 also prints stored request/UDP-feature diagnostics

All normal P7 matrix options are accepted and forwarded. The wrapper forces
--restore-dpdk 1 and restores the exact P5-ready DPDK state established before
P7. Interrupted P7 runs may leave a test NIC on ice or temporarily unbound;
startup repairs those states before beginning a new Linux run.
USAGE
    echo
    "$BASE" --help
}

while (($#)); do
    case "$1" in
        --chart-style|--chart_style)
            CHART_STYLE="${2:?missing value for $1}"; shift 2 ;;
        --log-level)
            LOG_LEVEL="${2:?missing value for --log-level}"; shift 2 ;;
        --output-dir)
            OUTPUT_DIR="${2:?missing value for --output-dir}"; ARGS+=("$1" "$2"); shift 2 ;;
        --client-host)
            CLIENT_HOST="${2:?missing value for --client-host}"; ARGS+=("$1" "$2"); shift 2 ;;
        --client-dir)
            CLIENT_DIR="${2:?missing value for --client-dir}"; ARGS+=("$1" "$2"); shift 2 ;;
        --restore-dpdk)
            [[ "${2:?missing value for --restore-dpdk}" == 1 ]] || {
                echo "ERROR: isolated P7 wrapper requires --restore-dpdk 1. Run run_matrix_from_idex.sh directly only for deliberate Linux-state experiments." >&2
                exit 2
            }
            shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
case "$CHART_STYLE" in new|old|both) ;; *) echo "ERROR: --chart-style must be new, old, or both" >&2; exit 2 ;; esac
case "$LOG_LEVEL" in 0|1) ;; *) echo "ERROR: --log-level must be 0 or 1" >&2; exit 2 ;; esac
[[ -x "$BASE" && -x "$REPORTER" && -f "$SUMMARY" ]] || { echo "ERROR: P7 runner/reporter/summary helper missing" >&2; exit 2; }
python3 -c 'import matplotlib, numpy' >/dev/null

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$HERE/matrix_results/P7_linux_$(date +%Y%m%d_%H%M%S)"
    ARGS+=("--output-dir" "$OUTPUT_DIR")
fi
ARGS+=("--restore-dpdk" "1")

PCI="0000:18:00.0"
DEVBIND="/root/mohsen/msquic/deps/dpdk/usertools/dpdk-devbind.py"
P7_RECOVERY_DPDK_DRIVER="${P7_RECOVERY_DPDK_DRIVER:-vfio-pci}"
remote(){ ssh -o BatchMode=yes -o ConnectTimeout=20 root@"$CLIENT_HOST" "$@"; }

driver_local() {
    local link="/sys/bus/pci/devices/$PCI/driver" target
    if [[ ! -L "$link" ]]; then
        printf 'none\n'
        return 0
    fi
    target="$(readlink "$link" 2>/dev/null || true)"
    if [[ -n "$target" ]]; then basename "$target"; else printf 'none\n'; fi
}

driver_remote() {
    remote "link='/sys/bus/pci/devices/$PCI/driver'; if [[ -L \"\$link\" ]]; then target=\$(readlink \"\$link\" 2>/dev/null || true); if [[ -n \"\$target\" ]]; then basename \"\$target\"; else echo none; fi; else echo none; fi"
}

quiesce_linux_iface_local() {
    local iface
    iface="$(find "/sys/bus/pci/devices/$PCI/net" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | head -n1 || true)"
    [[ -n "$iface" ]] || return 0
    stage "quiescing stale IDEX Linux test interface $iface before DPDK bind"
    ip addr flush dev "$iface" 2>/dev/null || true
    ip -6 addr flush dev "$iface" 2>/dev/null || true
    ip route flush dev "$iface" 2>/dev/null || true
    ip -6 route flush dev "$iface" 2>/dev/null || true
    ip link set dev "$iface" down 2>/dev/null || true
}

quiesce_linux_iface_remote() {
    remote "set -e; PCI='$PCI'; iface=\$(find /sys/bus/pci/devices/\$PCI/net -mindepth 1 -maxdepth 1 -printf '%f\\n' 2>/dev/null | head -n1 || true); if [[ -n \"\$iface\" ]]; then echo \"[P7-recovery] quiescing stale Tinyman Linux test interface \$iface before DPDK bind\"; ip addr flush dev \"\$iface\" 2>/dev/null || true; ip -6 addr flush dev \"\$iface\" 2>/dev/null || true; ip route flush dev \"\$iface\" 2>/dev/null || true; ip -6 route flush dev \"\$iface\" 2>/dev/null || true; ip link set dev \"\$iface\" down 2>/dev/null || true; fi"
}

bind_driver_local() {
    local target="$1" current
    current="$(driver_local)"
    [[ "$current" == "$target" ]] && return 0
    case "$target" in
        vfio-pci) modprobe vfio-pci ;;
        igb_uio) modprobe uio 2>/dev/null || true; modprobe igb_uio 2>/dev/null || true ;;
        *) echo "ERROR: unsupported saved driver '$target'" >&2; return 1 ;;
    esac
    [[ "$current" == ice ]] && quiesce_linux_iface_local
    python3 "$DEVBIND" -b "$target" "$PCI"
    current="$(driver_local)"
    [[ "$current" == "$target" ]] || {
        echo "ERROR: IDEX bind to $target failed; current=$current" >&2
        return 1
    }
}

bind_driver_remote() {
    local target="$1" current
    current="$(driver_remote)"
    [[ "$current" == "$target" ]] && return 0
    case "$target" in
        vfio-pci|igb_uio) ;;
        *) echo "ERROR: unsupported recovery driver '$target'" >&2; return 1 ;;
    esac
    [[ "$current" == ice ]] && quiesce_linux_iface_remote
    remote "set -e; PCI='$PCI'; DEVBIND='$DEVBIND'; target='$target'; case \"\$target\" in vfio-pci) modprobe vfio-pci;; igb_uio) modprobe uio 2>/dev/null || true; modprobe igb_uio 2>/dev/null || true;; esac; python3 \"\$DEVBIND\" -b \"\$target\" \"\$PCI\"; link=/sys/bus/pci/devices/\$PCI/driver; [[ -L \"\$link\" ]] || { echo \"ERROR: Tinyman bind to \$target left NIC unbound\" >&2; exit 1; }; current=\$(basename \"\$(readlink \"\$link\")\"); [[ \"\$current\" == \"\$target\" ]] || { echo \"ERROR: Tinyman bind to \$target failed; current=\$current\" >&2; exit 1; }"
}

INITIAL_SERVER="$(driver_local)"
INITIAL_CLIENT="$(driver_remote)"
case "$INITIAL_SERVER" in vfio-pci|igb_uio|ice|none) ;; *) echo "ERROR: unsupported initial IDEX test-NIC driver '$INITIAL_SERVER'" >&2; exit 2 ;; esac
case "$INITIAL_CLIENT" in vfio-pci|igb_uio|ice|none) ;; *) echo "ERROR: unsupported initial Tinyman test-NIC driver '$INITIAL_CLIENT'" >&2; exit 2 ;; esac
case "$P7_RECOVERY_DPDK_DRIVER" in vfio-pci|igb_uio) ;; *) echo "ERROR: P7_RECOVERY_DPDK_DRIVER must be vfio-pci or igb_uio" >&2; exit 2 ;; esac

stage "startup driver state: IDEX=$INITIAL_SERVER Tinyman=$INITIAL_CLIENT"

# Recover only stale/non-DPDK states. If one peer is already P5-ready, use its
# DPDK driver; otherwise use the configured recovery default (vfio-pci).
RECOVERY_TARGET="$P7_RECOVERY_DPDK_DRIVER"
case "$INITIAL_SERVER" in vfio-pci|igb_uio) RECOVERY_TARGET="$INITIAL_SERVER" ;; esac
if [[ "$INITIAL_SERVER" != vfio-pci && "$INITIAL_SERVER" != igb_uio ]]; then
    case "$INITIAL_CLIENT" in vfio-pci|igb_uio) RECOVERY_TARGET="$INITIAL_CLIENT" ;; esac
fi

case "$INITIAL_SERVER" in
    ice)  stage "IDEX is stale on ice; recovering IDEX to $RECOVERY_TARGET"; bind_driver_local "$RECOVERY_TARGET" ;;
    none) stage "IDEX test NIC is unbound; recovering IDEX to $RECOVERY_TARGET"; bind_driver_local "$RECOVERY_TARGET" ;;
esac
case "$INITIAL_CLIENT" in
    ice)  stage "Tinyman is stale on ice; recovering Tinyman to $RECOVERY_TARGET"; bind_driver_remote "$RECOVERY_TARGET" ;;
    none) stage "Tinyman test NIC is unbound; recovering Tinyman to $RECOVERY_TARGET"; bind_driver_remote "$RECOVERY_TARGET" ;;
esac

ORIG_SERVER="$(driver_local)"
ORIG_CLIENT="$(driver_remote)"
case "$ORIG_SERVER" in vfio-pci|igb_uio) ;; *) echo "ERROR: failed to recover P5-ready DPDK driver on IDEX; found '$ORIG_SERVER'" >&2; exit 2 ;; esac
case "$ORIG_CLIENT" in vfio-pci|igb_uio) ;; *) echo "ERROR: failed to recover P5-ready DPDK driver on Tinyman; found '$ORIG_CLIENT'" >&2; exit 2 ;; esac
stage "P5-ready startup state confirmed: IDEX=$ORIG_SERVER Tinyman=$ORIG_CLIENT"

restore_exact() {
    set +e
    bind_driver_local "$ORIG_SERVER"
    bind_driver_remote "$ORIG_CLIENT"
    set -e
}
cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    stage "cleanup: restoring exact P5-ready pre-P7 DPDK drivers"
    restore_exact || true
    exit "$rc"
}
trap cleanup EXIT INT TERM

stage "STARTING P7 WORKLOAD MATRIX — chart generation is NOT running yet"
"$BASE" "${ARGS[@]}"
stage "workload matrix and per-run summaries complete; restoring exact DPDK drivers"
restore_exact
trap - EXIT INT TERM

stage "post-run drivers: IDEX=$(driver_local) Tinyman=$(driver_remote)"
[[ "$(driver_local)" == "$ORIG_SERVER" ]] || { echo "ERROR: IDEX driver restore mismatch" >&2; exit 1; }
[[ "$(driver_remote)" == "$ORIG_CLIENT" ]] || { echo "ERROR: Tinyman driver restore mismatch" >&2; exit 1; }

stage "FINAL NUMERIC SUMMARY BEFORE CHART GENERATION"
python3 "$SUMMARY" --matrix-dir "$OUTPUT_DIR" --matrix

if [[ "$LOG_LEVEL" == 1 ]]; then
    stage "stored request/UDP-feature diagnostics"
    python3 - "$OUTPUT_DIR" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
for p in sorted((root/'runs').glob('**/*.log')):
    for line in p.read_text(errors='replace').splitlines():
        if 'linux_udp_features' in line or '[GreenQUIC-P7]' in line or '[GreenQUIC-P5]' in line:
            print(f'{p.relative_to(root)}: {line}')
PY
fi

if [[ "$CHART_STYLE" == old ]]; then
    stage "chart-style=old: numeric output only; chart generation skipped"
else
    stage "STARTING CHART/REPORT GENERATION"
    python3 "$REPORTER" --matrix-dir "$OUTPUT_DIR" --output "$OUTPUT_DIR/the_sheet_rules_all"
    stage "CHART/REPORT GENERATION COMPLETE"
    echo "[P7-report] chart-style=$CHART_STYLE"
    echo "[P7-report] report: $OUTPUT_DIR/the_sheet_rules_all"
fi

printf '\nP7 ISOLATED MATRIX + REPORT PASS\nRESULTS: %s\n' "$OUTPUT_DIR"
[[ "$CHART_STYLE" == old ]] || printf 'REPORT: %s\n' "$OUTPUT_DIR/the_sheet_rules_all"
