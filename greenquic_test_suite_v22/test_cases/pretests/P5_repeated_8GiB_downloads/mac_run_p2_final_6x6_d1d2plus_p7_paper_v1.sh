#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="${GREENQUIC_REPO:-$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)}"
[[ -n "$REPO_ROOT" && -d "$REPO_ROOT/.git" ]] || { echo "ERROR: cannot resolve GreenQUIC repo root" >&2; exit 2; }
export GREENQUIC_REPO="$REPO_ROOT"
BASE="$HERE/mac_run_p2_final_6x6_p7_v1.sh"
[[ -f "$BASE" ]] || { echo "ERROR: missing base runner: $BASE" >&2; exit 2; }
TAG="$(date +%Y%m%d_%H%M%S)_$$"
PATCHED="${TMPDIR:-/tmp}/mac_run_p2_d1d2plus_paper_${TAG}.sh"
python3 - "$BASE" "$PATCHED" <<'PY'
from pathlib import Path
import sys
src=Path(sys.argv[1]).read_text()
repls=[
('P7OUT="$P7/matrix_results/P7_FINAL_linux_native_${RUNS}r_${DOWNLOADS}d_${TAG}"','P7OUT="$P7/matrix_results/P7_FINAL_D1D2PLUS_linux_paper_${RUNS}r_${DOWNLOADS}d_${TAG}"','P7 output'),
('bash ./build_p5_performance2.sh','bash ./build_p5_performance2_d1d2plus.sh','P5 build'),
("P5_MARKER='GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0'","P5_MARKER='GREENQUIC-P5-D1D2PLUS-SNAPSHOT-V1'",'P5 marker'),
('bash ./run_matrix_with_sheet.sh','bash ./run_matrix_with_sheet_d1d2plus.sh','P5 runner'),
("echo '=== 3/3 P7 PRIMARY LINUX UDP BASELINE ==='","echo '=== 3/3 P7 PAPER + D1/D2+ LINUX UDP BASELINE ==='",'P7 label'),
('bash ./run_matrix_with_report.sh','bash ./run_p7_d1d2plus.sh','P7 runner'),
('        --between-runs-seconds 5 \\\n','        --between-runs-seconds 10 \\\n','P7 cooldown'),
('        --disable-rps 1 \\\n        --nic-offloads native \\\n','        --disable-rps 1 \\\n        --disable-rdma 1 \\\n        --nic-offloads paper \\\n        --udp-rmem 6815744 \\\n        --udp-wmem 6815744 \\\n        --combined-channels 1 \\\n        --network-diagnostics 0 \\\n','P7 paper block'),
('P5_default=txalloc8+no_TxEnqueueCounter+RXpipe2+safe_TX_zero','P5_default=txalloc8+no_TxEnqueueCounter+RXpipe2+safe_TX_zero+D1D2plus_boundary_snapshots','source desc'),
('P7_config=native_offloads+IRQ_CPU19+QUIC_21_22_23_24+pinning+RPS_off','P7_config=paper_offloads+disable_RDMA+rmem_6815744+wmem_6815744+combined_channels_1+IRQ_CPU19+QUIC_21_22_23_24+pinning+RPS_off+D1D2plus_report','P7 desc'),
('zip_one "$MON" "P5_IDLE_MONITOR_${RUNS}r_${DOWNLOADS}d_${TAG}"','zip_one "$MON" "P5_D1D2PLUS_IDLE_MONITOR_${RUNS}r_${DOWNLOADS}d_${TAG}"','idle zip'),
('zip_one "$PWR" "P5_POWER_FRIENDLY_${RUNS}r_${DOWNLOADS}d_${TAG}"','zip_one "$PWR" "P5_D1D2PLUS_POWER_FRIENDLY_${RUNS}r_${DOWNLOADS}d_${TAG}"','power zip'),
('zip_one "$P7OUT" "P7_LINUX_NATIVE_${RUNS}r_${DOWNLOADS}d_${TAG}"','zip_one "$P7OUT" "P7_D1D2PLUS_LINUX_PAPER_${RUNS}r_${DOWNLOADS}d_${TAG}"','P7 zip'),
]
for old,new,label in repls:
    n=src.count(old)
    # P5 build and runner occur twice or once depending on helper string; replace all, but require at least one.
    if label in ('P5 build','P5 runner'):
        if n<1: raise SystemExit(f'ERROR: {label}: anchor missing')
        src=src.replace(old,new)
    else:
        if n!=1: raise SystemExit(f'ERROR: {label}: expected 1 anchor, got {n}')
        src=src.replace(old,new,1)
# Preserve explicit paper configuration marker in remote log.
anchor='if [ "$BP71" -eq 0 ] && [ "$BP72" -eq 0 ]; then\n'
if src.count(anchor)!=1: raise SystemExit('ERROR: P7 marker anchor')
src=src.replace(anchor,anchor+"    echo 'P7 PAPER D1/D2+ CONFIG: offloads=paper disable_rdma=1 rmem=6815744 wmem=6815744 channels=1 between_runs=10s cpu19 quic=21,22,23,24'\n",1)
Path(sys.argv[2]).write_text(src)
PY
chmod 0700 "$PATCHED"
bash -n "$PATCHED"
exec bash "$PATCHED" "$@"
