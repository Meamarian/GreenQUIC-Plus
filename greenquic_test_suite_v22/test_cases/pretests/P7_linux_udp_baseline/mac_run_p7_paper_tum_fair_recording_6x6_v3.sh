#!/usr/bin/env bash
set -Eeuo pipefail

# Thin Mac-side wrapper around v2.
# Keeps the NOMS/TUM network profile, restores the P5-comparable CPU budget,
# and keeps 5 s connected gaps plus RAPL/frequency/C-state recording.
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
BASE="$HERE/mac_run_p7_paper_text_github_recording_6x6_v2.sh"
[[ -f "$BASE" ]] || { echo "ERROR: missing base wrapper: $BASE" >&2; exit 2; }

TAG="$(date +%Y%m%d_%H%M%S)_$$"
# Keep the intermediate V2 wrapper beside V2 so V2's relative path to the
# P5 Mac orchestrator remains valid. V2 then generates its self-contained
# detached base runner in /tmp before returning.
PATCHED="$HERE/.mac_run_p7_paper_tum_fair_recording_${TAG}.sh"
trap 'rm -f "$PATCHED"' EXIT INT TERM

python3 - "$BASE" "$PATCHED" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text(encoding='utf-8')

# Separate namespace/output from the earlier paper-recording run.
src = src.replace('P7_PAPER_TEXT_GITHUB_RECORDING', 'P7_PAPER_TUM_FAIR_RECORDING')
src = src.replace('P7 PAPER TEXT+GITHUB + RECORDING', 'P7 PAPER/TUM + FAIR CPU + RECORDING')
src = src.replace('P7 paper-config recording runner', 'P7 paper/TUM fair-CPU recording runner')
src = src.replace('P7 paper-config recording 6x6 suite', 'P7 paper/TUM fair-CPU recording 6x6 suite')

# Restore the CPU-budget controls used for apples-to-apples P5/P7 comparison.
src = src.replace(
    "echo 'extra performance tuning disabled: pin_irq=0 pin_quic=0 disable_rps=0 disable_rdma=0 combined=native stop_irqbalance=0 D1D2plus=0'",
    "echo 'fair CPU controls: CPU19 IRQ/NAPI, QUIC CPUs21-24, pin_irq=1 pin_quic=1 disable_rps=1 stop_irqbalance=1; disable_rdma=0 combined=native D1D2plus=0'",
)
src = src.replace('--gap-seconds 0 \\\n', '--gap-seconds 5 \\\n')
src = src.replace('--pre-cooldown-seconds 0 \\\n', '--pre-cooldown-seconds 5 \\\n')
src = src.replace('--post-cooldown-seconds 0 \\\n', '--post-cooldown-seconds 5 \\\n')
src = src.replace('--between-runs-seconds 0 \\\n', '--between-runs-seconds 5 \\\n')
src = src.replace('--dataplane-cpu 19 \\\n        --pin-irq 0 \\\n', '--dataplane-cpu 19 \\\n        --quic-cpus 21,22,23,24 \\\n        --pin-irq 1 \\\n')
src = src.replace('--pin-quic 0 \\\n', '--pin-quic 1 \\\n')
src = src.replace('--disable-rps 0 \\\n', '--disable-rps 1 \\\n')
src = src.replace('--stop-irqbalance 0 \\\n', '--stop-irqbalance 1 \\\n')

# Metadata must distinguish paper/TUM network knobs from our fairness controls.
src = src.replace('profile=PAPER_TEXT_PLUS_TUM_GITHUB_ARTIFACT_WITH_PASSIVE_RECORDING',
                  'profile=PAPER_TUM_NETWORK_PLUS_FAIR_CPU_CONTROLS_WITH_RECORDING')
src = src.replace('pin_irq=0', 'pin_irq=1')
src = src.replace('pin_quic=0', 'pin_quic=1')
src = src.replace('disable_rps=0', 'disable_rps=1')
src = src.replace('stop_irqbalance=0', 'stop_irqbalance=1')
src = src.replace('gap_seconds=0', 'gap_seconds=5')
src = src.replace('pre_cooldown_seconds=0', 'pre_cooldown_seconds=5')
src = src.replace('post_cooldown_seconds=0', 'post_cooldown_seconds=5')
src = src.replace('between_runs_seconds=0', 'between_runs_seconds=5')
src = src.replace(
    'NOTE=6x6 workload count and passive energy/state instrumentation are measurement additions; network/runtime tuning remains paper-artifact profile',
    'NOTE=Paper/TUM network profile is retained. CPU19/CPUs21-24 affinity, RPS/irqbalance controls, 5s gaps/cooldowns, 6x6 workload count, and energy/state instrumentation are our experimental-control/measurement additions for fair P5 comparison.',
)

# Guard against silently producing the old unfixed profile.
required = [
    '--quic-cpus 21,22,23,24', '--pin-irq 1', '--pin-quic 1',
    '--disable-rps 1', '--stop-irqbalance 1', '--disable-rdma 0',
    '--combined-channels native', '--nic-offloads paper',
    '--udp-rmem 6815744', '--udp-wmem 6815744',
    '--gap-seconds 5', '--pre-cooldown-seconds 5',
    '--post-cooldown-seconds 5', '--between-runs-seconds 5',
    '--enable-record 1', '--rapl-interval-ms 6', '--freq-interval-ms 1',
]
missing = [x for x in required if x not in src]
if missing:
    raise SystemExit('ERROR: V3 patch incomplete, missing: ' + ', '.join(missing))

Path(sys.argv[2]).write_text(src, encoding='utf-8')
PY

chmod 0700 "$PATCHED"
bash -n "$PATCHED"
bash "$PATCHED" "$@"
