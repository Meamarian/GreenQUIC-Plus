#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="${GREENQUIC_REPO:-$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)}"
[[ -n "$REPO_ROOT" && -d "$REPO_ROOT/.git" ]] || { echo "ERROR: cannot resolve GreenQUIC repo root" >&2; exit 2; }
export GREENQUIC_REPO="$REPO_ROOT"
BASE="$HERE/mac_run_p2_final_6x6_p7_v1.sh"
[[ -f "$BASE" ]] || { echo "ERROR: missing base runner: $BASE" >&2; exit 2; }
python3 -m py_compile \
  "$HERE/apply_p5_d1d2plus_snapshot.py" \
  "$HERE/apply_p5_d1d2plus_snapshot_v3.py" \
  "$HERE/build_d1_d2plus_report_v3.py" \
  "$HERE/clock_sync.py" \
  "$HERE/../P7_linux_udp_baseline/build_p7_d1_d2plus_report_v3.py" \
  "$HERE/../P7_linux_udp_baseline/p7_frequency_sampler.py"
bash -n "$HERE/run_matrix_with_sheet_d1d2plus.sh" "$HERE/../P7_linux_udp_baseline/run_p7_d1d2plus.sh"

# D1/D2+ measurements are sensitive to orphaned high-rate samplers. Previous
# interrupted runs can leave 1 ms frequency, 6 ms RAPL, or C-state recorders
# alive after the transport has gone away. Remove only those recorder processes,
# and refuse to do any cleanup if a real GreenQUIC/P7 workload is still active.
CLEAN_SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3)
cleanup_measurement_host() {
  local host="$1"
  local rc=0
  if [[ "$host" == idex ]]; then
    ssh "${CLEAN_SSH_OPTS[@]}" idex 'bash -s' <<'CLEAN' || rc=$?
set -euo pipefail
active_pids=()
recorder_pids=()
for proc in /proc/[0-9]*; do
  pid="${proc##*/}"
  [[ "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
  cmd="$(tr '\0' ' ' <"$proc/cmdline" 2>/dev/null || true)"
  [[ -n "$cmd" ]] || continue
  case "$cmd" in
    *quicinterop*|*run_matrix_with_sheet*|*run_matrix_with_report*|*run_matrix_from_idex*|*run_p7_d1d2plus.sh*|*P5_P2_FINAL_REMOTE*)
      active_pids+=("$pid")
      ;;
  esac
  case "$cmd" in
    *gq_rapl_msr_sampler*|*frequency_sampler.py*|*gq_cstate_trace*|*power_trace.py*)
      recorder_pids+=("$pid")
      ;;
  esac
done
if ((${#active_pids[@]})); then
  echo "ERROR: active test workload on $(hostname -s); refusing sampler cleanup: ${active_pids[*]}" >&2
  for pid in "${active_pids[@]}"; do
    tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true
    echo
  done >&2
  exit 70
fi
if ((${#recorder_pids[@]} == 0)); then
  echo "STALE_RECORDER_CLEANUP host=$(hostname -s) removed=0"
  exit 0
fi
printf 'STALE_RECORDER_CLEANUP host=%s term_pids=%s\n' "$(hostname -s)" "${recorder_pids[*]}"
kill -TERM "${recorder_pids[@]}" 2>/dev/null || true
sleep 0.5
for pid in "${recorder_pids[@]}"; do
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
done
sleep 0.1
remaining=()
for proc in /proc/[0-9]*; do
  pid="${proc##*/}"
  [[ "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
  cmd="$(tr '\0' ' ' <"$proc/cmdline" 2>/dev/null || true)"
  case "$cmd" in
    *gq_rapl_msr_sampler*|*frequency_sampler.py*|*gq_cstate_trace*|*power_trace.py*) remaining+=("$pid") ;;
  esac
done
if ((${#remaining[@]})); then
  echo "ERROR: stale measurement recorders remain on $(hostname -s): ${remaining[*]}" >&2
  exit 72
fi
echo "STALE_RECORDER_CLEANUP host=$(hostname -s) removed=${#recorder_pids[@]} verified=1"
CLEAN
  else
    ssh "${CLEAN_SSH_OPTS[@]}" idex \
      "ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3 root@tinyman 'bash -s'" <<'CLEAN' || rc=$?
set -euo pipefail
active_pids=()
recorder_pids=()
for proc in /proc/[0-9]*; do
  pid="${proc##*/}"
  [[ "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
  cmd="$(tr '\0' ' ' <"$proc/cmdline" 2>/dev/null || true)"
  [[ -n "$cmd" ]] || continue
  case "$cmd" in
    *quicinterop*|*run_matrix_with_sheet*|*run_matrix_with_report*|*run_matrix_from_idex*|*run_p7_d1d2plus.sh*|*P5_P2_FINAL_REMOTE*)
      active_pids+=("$pid")
      ;;
  esac
  case "$cmd" in
    *gq_rapl_msr_sampler*|*frequency_sampler.py*|*gq_cstate_trace*|*power_trace.py*)
      recorder_pids+=("$pid")
      ;;
  esac
done
if ((${#active_pids[@]})); then
  echo "ERROR: active test workload on $(hostname -s); refusing sampler cleanup: ${active_pids[*]}" >&2
  for pid in "${active_pids[@]}"; do
    tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true
    echo
  done >&2
  exit 70
fi
if ((${#recorder_pids[@]} == 0)); then
  echo "STALE_RECORDER_CLEANUP host=$(hostname -s) removed=0"
  exit 0
fi
printf 'STALE_RECORDER_CLEANUP host=%s term_pids=%s\n' "$(hostname -s)" "${recorder_pids[*]}"
kill -TERM "${recorder_pids[@]}" 2>/dev/null || true
sleep 0.5
for pid in "${recorder_pids[@]}"; do
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
done
sleep 0.1
remaining=()
for proc in /proc/[0-9]*; do
  pid="${proc##*/}"
  [[ "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
  cmd="$(tr '\0' ' ' <"$proc/cmdline" 2>/dev/null || true)"
  case "$cmd" in
    *gq_rapl_msr_sampler*|*frequency_sampler.py*|*gq_cstate_trace*|*power_trace.py*) remaining+=("$pid") ;;
  esac
done
if ((${#remaining[@]})); then
  echo "ERROR: stale measurement recorders remain on $(hostname -s): ${remaining[*]}" >&2
  exit 72
fi
echo "STALE_RECORDER_CLEANUP host=$(hostname -s) removed=${#recorder_pids[@]} verified=1"
CLEAN
  fi
  return "$rc"
}

cleanup_measurement_host idex
cleanup_measurement_host tinyman

TAG="$(date +%Y%m%d_%H%M%S)_$$"
PATCHED="${TMPDIR:-/tmp}/mac_run_p2_d1d2plus_paper_${TAG}.sh"
python3 - "$BASE" "$PATCHED" <<'PY'
from pathlib import Path
import os,sys
src=Path(sys.argv[1]).read_text()
repls=[
('P7OUT="$P7/matrix_results/P7_FINAL_linux_native_${RUNS}r_${DOWNLOADS}d_${TAG}"','P7OUT="$P7/matrix_results/P7_FINAL_D1D2PLUS_linux_paper_${RUNS}r_${DOWNLOADS}d_${TAG}"','P7 output'),
('bash ./build_p5_performance2.sh','bash ./build_p5_performance2_d1d2plus.sh','P5 build'),
("P5_MARKER='GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0'","P5_MARKER='GREENQUIC-P5-D1D2PLUS-SNAPSHOT-V3'",'P5 marker'),
('bash ./run_matrix_with_sheet.sh','bash ./run_matrix_with_sheet_d1d2plus.sh','P5 runner'),
("echo '=== 3/3 P7 PRIMARY LINUX UDP BASELINE ==='","echo '=== 3/3 P7 PAPER + D1/D2+ LINUX UDP BASELINE ==='",'P7 label'),
('bash ./run_matrix_with_report.sh','bash ./run_p7_d1d2plus.sh','P7 runner'),
('        --between-runs-seconds 5 \\\n','        --between-runs-seconds 10 \\\n','P7 cooldown'),
('        --disable-rps 1 \\\n        --nic-offloads native \\\n','        --disable-rps 1 \\\n        --disable-rdma 1 \\\n        --nic-offloads paper \\\n        --udp-rmem 6815744 \\\n        --udp-wmem 6815744 \\\n        --combined-channels 1 \\\n        --network-diagnostics 0 \\\n','P7 paper block'),
('P5_default=txalloc8+no_TxEnqueueCounter+RXpipe2+safe_TX_zero','P5_default=txalloc8+no_TxEnqueueCounter+RXpipe2+safe_TX_zero+D1D2plus_boundary_snapshots_v3+alignment_v3','source desc'),
('P7_config=native_offloads+IRQ_CPU19+QUIC_21_22_23_24+pinning+RPS_off','P7_config=paper_offloads+disable_RDMA+rmem_6815744+wmem_6815744+combined_channels_1+IRQ_CPU19+QUIC_21_22_23_24+pinning+RPS_off+D1D2plus_alignment_v3','P7 desc'),
('zip_one "$MON" "P5_IDLE_MONITOR_${RUNS}r_${DOWNLOADS}d_${TAG}"','zip_one "$MON" "P5_D1D2PLUS_IDLE_MONITOR_${RUNS}r_${DOWNLOADS}d_${TAG}"','idle zip'),
('zip_one "$PWR" "P5_POWER_FRIENDLY_${RUNS}r_${DOWNLOADS}d_${TAG}"','zip_one "$PWR" "P5_D1D2PLUS_POWER_FRIENDLY_${RUNS}r_${DOWNLOADS}d_${TAG}"','power zip'),
('zip_one "$P7OUT" "P7_LINUX_NATIVE_${RUNS}r_${DOWNLOADS}d_${TAG}"','zip_one "$P7OUT" "P7_D1D2PLUS_LINUX_PAPER_${RUNS}r_${DOWNLOADS}d_${TAG}"','P7 zip'),
]
for old,new,label in repls:
    n=src.count(old)
    if label in ('P5 build','P5 runner'):
        if n<1: raise SystemExit(f'ERROR: {label}: anchor missing')
        src=src.replace(old,new)
    else:
        if n!=1: raise SystemExit(f'ERROR: {label}: expected 1 anchor, got {n}')
        src=src.replace(old,new,1)
anchor='if [ "$BP71" -eq 0 ] && [ "$BP72" -eq 0 ]; then\n'
if src.count(anchor)!=1: raise SystemExit('ERROR: P7 marker anchor')
src=src.replace(anchor,anchor+"    echo 'P7 PAPER D1/D2+ CONFIG: offloads=paper disable_rdma=1 rmem=6815744 wmem=6815744 channels=1 between_runs=10s cpu19 quic=21,22,23,24 alignment=v3'\n",1)

if os.environ.get('P5_D1D2PLUS_SMOKE_IDLE_P7_ONLY','0').lower() in ('1','true','yes','on'):
    old='''    echo '=== 2/3 P5 POWER_FRIENDLY — OFF/BASIC/PLUS ==='\n    run_p5 "$PWR" \\\n        --env ENABLE_FREQ=1 \\\n        --env ENABLE_SLEEP=1 \\\n        --env GQ_IDLE_MODE_OVERRIDE=epoll \\\n        --env GQ_IDLE_FALLBACK_OVERRIDE=short\n    RC2=$?\n    echo "P5 POWER_FRIENDLY RC=$RC2"\n'''
    new='''    echo '=== 2/3 P5 POWER_FRIENDLY — SKIPPED (D1/D2+ smoke: Idle Monitor + Linux only) ==='\n    RC2=0\n    echo "P5 POWER_FRIENDLY RC=$RC2 (SKIPPED_SMOKE)"\n'''
    if src.count(old)!=1:raise SystemExit(f'ERROR: smoke power block expected once, got {src.count(old)}')
    src=src.replace(old,new,1)
    src=src.replace('P2 FINAL startup tag=', 'P2 D1D2+ SMOKE startup tag=',1)
Path(sys.argv[2]).write_text(src)
PY
chmod 0700 "$PATCHED"
bash -n "$PATCHED"
exec bash "$PATCHED" "$@"
