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
--restore-dpdk 1 and restores the exact DPDK driver that was present before P7.
If a previous interrupted P7 left one test NIC on the Linux ice driver, startup
repairs that stale state using the peer's DPDK driver before starting the run.
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
driver_local(){ basename "$(readlink -f "/sys/bus/pci/devices/$PCI/driver" 2>/dev/null || true)"; }
driver_remote(){ remote "basename \"\$(readlink -f '/sys/bus/pci/devices/$PCI/driver' 2>/dev/null || true)\""; }

bind_driver_local() {
    local target="$1" current="$(driver_local)"
    [[ "$current" == "$target" ]] && return 0
    case "$target" in
        vfio-pci) modprobe vfio-pci ;;
        igb_uio) modprobe uio 2>/dev/null || true; modprobe igb_uio 2>/dev/null || true ;;
        *) echo "ERROR: unsupported saved driver '$target'" >&2; return 1 ;;
    esac
    python3 "$DEVBIND" -b "$target" "$PCI"
    [[ "$(driver_local)" == "$target" ]]
}
bind_driver_remote() {
    local target="$1"
    remote "set -e; PCI='$PCI'; DEVBIND='$DEVBIND'; current=\$(basename \"\$(readlink -f /sys/bus/pci/devices/\$PCI/driver 2>/dev/null || true)\"); if [[ \"\$current\" != '$target' ]]; then case '$target' in vfio-pci) modprobe vfio-pci;; igb_uio) modprobe uio 2>/dev/null || true; modprobe igb_uio 2>/dev/null || true;; *) echo \"ERROR: unsupported recovery driver '$target'\" >&2; exit 2;; esac; python3 \"\$DEVBIND\" -b '$target' \"\$PCI\"; fi; [[ \$(basename \"\$(readlink -f /sys/bus/pci/devices/\$PCI/driver)\") == '$target' ]]"
}

INITIAL_SERVER="$(driver_local)"
INITIAL_CLIENT="$(driver_remote)"
case "$INITIAL_SERVER" in vfio-pci|igb_uio|ice) ;; *) echo "ERROR: unsupported initial IDEX test-NIC driver '$INITIAL_SERVER'" >&2; exit 2 ;; esac
case "$INITIAL_CLIENT" in vfio-pci|igb_uio|ice) ;; *) echo "ERROR: unsupported initial Tinyman test-NIC driver '$INITIAL_CLIENT'" >&2; exit 2 ;; esac

stage "startup driver state: IDEX=$INITIAL_SERVER Tinyman=$INITIAL_CLIENT"
if [[ "$INITIAL_SERVER" == ice && "$INITIAL_CLIENT" == ice ]]; then
    case "$P7_RECOVERY_DPDK_DRIVER" in vfio-pci|igb_uio) ;; *) echo "ERROR: P7_RECOVERY_DPDK_DRIVER must be vfio-pci or igb_uio" >&2; exit 2 ;; esac
    stage "both NICs are stale on ice; recovering both to $P7_RECOVERY_DPDK_DRIVER before P7"
    bind_driver_local "$P7_RECOVERY_DPDK_DRIVER"
    bind_driver_remote "$P7_RECOVERY_DPDK_DRIVER"
elif [[ "$INITIAL_SERVER" == ice ]]; then
    case "$INITIAL_CLIENT" in vfio-pci|igb_uio)
        stage "IDEX is stale on ice; recovering IDEX to Tinyman DPDK driver $INITIAL_CLIENT"
        bind_driver_local "$INITIAL_CLIENT"
        ;;
    esac
elif [[ "$INITIAL_CLIENT" == ice ]]; then
    case "$INITIAL_SERVER" in vfio-pci|igb_uio)
        stage "Tinyman is stale on ice; recovering Tinyman to IDEX DPDK driver $INITIAL_SERVER"
        bind_driver_remote "$INITIAL_SERVER"
        ;;
    esac
fi

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
