#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
BASE="$HERE/run_matrix_from_idex.sh"
REPORTER="$HERE/build_p7_report.py"
CLIENT_HOST="tinyman"
CLIENT_DIR="$HERE"
CHART_STYLE="both"
LOG_LEVEL="0"
OUTPUT_DIR=""
ARGS=()

usage() {
    cat <<'USAGE'
P7 Linux UDP matrix with P5-style report generation.

P7-only wrapper options:
  --chart-style new|old|both   default both; new/both generate the P7 report tree
  --log-level 0|1              1 prints stored request/UDP-feature diagnostics after each repetition

All normal P7 matrix options are accepted and forwarded. The wrapper forces
--restore-dpdk 1 and restores the exact DPDK driver that was present before P7,
so P5 remains ready after P7 (including on failure).
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
[[ -x "$BASE" && -x "$REPORTER" ]] || { echo "ERROR: P7 runner/reporter missing" >&2; exit 2; }
python3 -c 'import matplotlib, numpy' >/dev/null

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$HERE/matrix_results/P7_linux_$(date +%Y%m%d_%H%M%S)"
    ARGS+=("--output-dir" "$OUTPUT_DIR")
fi
ARGS+=("--restore-dpdk" "1")

PCI="0000:18:00.0"
DEVBIND="/root/mohsen/msquic/deps/dpdk/usertools/dpdk-devbind.py"
remote(){ ssh -o BatchMode=yes -o ConnectTimeout=20 root@"$CLIENT_HOST" "$@"; }
driver_local(){ basename "$(readlink -f "/sys/bus/pci/devices/$PCI/driver" 2>/dev/null || true)"; }
driver_remote(){ remote "basename \"\$(readlink -f '/sys/bus/pci/devices/$PCI/driver' 2>/dev/null || true)\""; }

ORIG_SERVER="$(driver_local)"
ORIG_CLIENT="$(driver_remote)"
case "$ORIG_SERVER" in vfio-pci|igb_uio) ;; *) echo "ERROR: P7 expected P5-ready DPDK driver on IDEX, found '$ORIG_SERVER'" >&2; exit 2 ;; esac
case "$ORIG_CLIENT" in vfio-pci|igb_uio) ;; *) echo "ERROR: P7 expected P5-ready DPDK driver on Tinyman, found '$ORIG_CLIENT'" >&2; exit 2 ;; esac

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
    remote "set -e; PCI='$PCI'; DEVBIND='$DEVBIND'; current=\$(basename \"\$(readlink -f /sys/bus/pci/devices/\$PCI/driver 2>/dev/null || true)\"); if [[ \"\$current\" != '$target' ]]; then case '$target' in vfio-pci) modprobe vfio-pci;; igb_uio) modprobe uio 2>/dev/null || true; modprobe igb_uio 2>/dev/null || true;; esac; python3 \"\$DEVBIND\" -b '$target' \"\$PCI\"; fi; [[ \$(basename \"\$(readlink -f /sys/bus/pci/devices/\$PCI/driver)\") == '$target' ]]"
}
restore_exact() {
    set +e
    bind_driver_local "$ORIG_SERVER"
    bind_driver_remote "$ORIG_CLIENT"
    set -e
}
cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    restore_exact || true
    exit "$rc"
}
trap cleanup EXIT INT TERM

echo "[P7-isolation] pre-run drivers: IDEX=$ORIG_SERVER Tinyman=$ORIG_CLIENT"
"$BASE" "${ARGS[@]}"
restore_exact
trap - EXIT INT TERM

echo "[P7-isolation] post-run drivers: IDEX=$(driver_local) Tinyman=$(driver_remote)"
[[ "$(driver_local)" == "$ORIG_SERVER" ]] || { echo "ERROR: IDEX driver restore mismatch" >&2; exit 1; }
[[ "$(driver_remote)" == "$ORIG_CLIENT" ]] || { echo "ERROR: Tinyman driver restore mismatch" >&2; exit 1; }

python3 - "$OUTPUT_DIR" "$LOG_LEVEL" <<'PY'
from pathlib import Path
import json, math, sys
root=Path(sys.argv[1]); log_level=int(sys.argv[2])
def get(d,*ks):
    for k in ks:
        if not isinstance(d,dict): return None
        d=d.get(k)
    return d if isinstance(d,(int,float)) and math.isfinite(float(d)) else None
def f(v,u): return 'N/A' if v is None else f'{v:.3f} {u}'
reps=sorted((root/'runs'/'client').glob('rep*'))
for cdir in reps:
    sdir=root/'runs'/'server'/cdir.name
    if not (cdir/'summary.json').is_file() or not (sdir/'summary.json').is_file(): continue
    c=json.loads((cdir/'summary.json').read_text()); s=json.loads((sdir/'summary.json').read_text())
    se=get(s,'scopes','active','rapl','total_j'); ce=get(c,'scopes','active','rapl','total_j')
    sp=get(s,'scopes','active','rapl','total_w'); cp=get(c,'scopes','active','rapl','total_w')
    ee=se+ce if se is not None and ce is not None else None; pp=sp+cp if sp is not None and cp is not None else None
    gbit=(c.get('useful_bytes') or 0)*8/1e9; cost=ee/gbit if ee is not None and gbit else None
    print(f'\n=== P7 {cdir.name} summary ===')
    print('Active goodput:',f(get(c,'goodput_gbps'),'Gbit/s'))
    print('Gap-inclusive goodput:',f(get(c,'gap_inclusive_goodput_gbps'),'Gbit/s'))
    print('Active RAPL energy: server',f(se,'J'),'| client',f(ce,'J'),'| combined',f(ee,'J'))
    print('Active RAPL power:  server',f(sp,'W'),'| client',f(cp,'W'),'| combined',f(pp,'W'))
    print('Combined active energy cost:',f(cost,'J/Gbit'))
    if log_level:
        print('--- diagnostic markers ---')
        for p in (sdir/'server.log',cdir/'client.log'):
            if not p.is_file(): continue
            for line in p.read_text(errors='replace').splitlines():
                if 'linux_udp_features' in line or '[GreenQUIC-P7]' in line or '[GreenQUIC-P5]' in line:
                    print(f'{p.name}: {line}')
PY

python3 - "$OUTPUT_DIR/p7_statistics.json" <<'PY'
import json, sys
s=json.load(open(sys.argv[1]))
def line(key,label,unit):
    v=s.get(key,{}) or {}; n=v.get('n',0); mu=v.get('mean'); sd=v.get('sd')
    if mu is None: return f'{label}: N/A (n={n})'
    if sd is None: return f'{label}: {mu:.3f} {unit} (n={n}; SD N/A)'
    return f'{label}: {mu:.3f} ± {sd:.3f} {unit} (n={n})'
print('\n=== P7 Linux UDP Matrix Summary ===')
for args in [
 ('goodput_gbps','Active goodput','Gbit/s'),
 ('gap_inclusive_goodput_gbps','Gap-inclusive goodput','Gbit/s'),
 ('combined_active_energy_j','Combined active RAPL energy','J'),
 ('combined_active_power_w','Combined active RAPL power','W'),
 ('combined_active_j_per_useful_gbit','Combined active energy cost','J/Gbit'),
 ('combined_gap_energy_j','Combined gap RAPL energy','J'),
 ('combined_combined_energy_j','Combined D1→Dn RAPL energy','J'),
 ('combined_combined_j_per_useful_gbit','Combined D1→Dn energy cost','J/Gbit')]:
    print(line(*args))
PY

if [[ "$CHART_STYLE" == old ]]; then
    echo "[P7-report] chart-style=old: numeric output only"
else
    python3 "$REPORTER" --matrix-dir "$OUTPUT_DIR" --output "$OUTPUT_DIR/the_sheet_rules_all"
    echo "[P7-report] chart-style=$CHART_STYLE"
    echo "[P7-report] report: $OUTPUT_DIR/the_sheet_rules_all"
fi

printf '\nP7 ISOLATED MATRIX + REPORT PASS\nRESULTS: %s\n' "$OUTPUT_DIR"
[[ "$CHART_STYLE" == old ]] || printf 'REPORT: %s\n' "$OUTPUT_DIR/the_sheet_rules_all"
