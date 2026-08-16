#!/usr/bin/env bash
set -Eeuo pipefail

# Final Performance2 validation using the exact P7 PAPER_FULL setup captured in:
#   P7_PAPER_FULL_6runs_20260814_225256
#
# Archive matrix_config.env:
#   gap=5 s, pre/post cooldown=5 s, between-runs=10 s
#   CPU19 dataplane/IRQ target, QUIC CPUs 21,22,23,24
#   pin IRQ=1, pin QUIC=1, disable RPS=1, disable RDMA=1
#   nic-offloads=paper
#   udp rmem/wmem=6815744, combined channels=1
#   network diagnostics=0
#   record QUIC CPUs=0, RAPL=6 ms, frequency=1 ms
#   require RAPL=1, stop irqbalance=1, MTU=1500
#
# RUNS/DOWNLOADS remain controlled by the final runner. Therefore the requested
# final experiment uses 6 runs x 6 downloads even though the reference archive
# itself used 6 runs x 5 downloads.

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="${GREENQUIC_REPO:-$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)}"
[[ -n "$REPO_ROOT" && -d "$REPO_ROOT/.git" ]] || {
    echo "ERROR: cannot resolve GreenQUIC repo root from $HERE" >&2
    exit 2
}
# The generated runner lives under /tmp. Export the real checkout explicitly so
# its repo-root detection does not incorrectly try `git -C /tmp`.
export GREENQUIC_REPO="$REPO_ROOT"

BASE="$HERE/mac_run_p2_final_6x6_p7_v1.sh"
[[ -f "$BASE" ]] || { echo "ERROR: missing base final runner: $BASE" >&2; exit 2; }

# Keep the generated script alive after --detach, because the base runner starts
# its foreground Mac orchestrator by invoking $0 again.
TAG="$(date +%Y%m%d_%H%M%S)_$$"
PATCHED="${TMPDIR:-/tmp}/mac_run_p2_final_6x6_p7_paper_${TAG}.sh"

python3 - "$BASE" "$PATCHED" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text(encoding="utf-8")

replacements = [
    (
        'P7OUT="$P7/matrix_results/P7_FINAL_linux_native_${RUNS}r_${DOWNLOADS}d_${TAG}"',
        'P7OUT="$P7/matrix_results/P7_FINAL_linux_paper_${RUNS}r_${DOWNLOADS}d_${TAG}"',
        'P7 output name',
    ),
    (
        "echo '=== 3/3 P7 PRIMARY LINUX UDP BASELINE ==='",
        "echo '=== 3/3 P7 PAPER-FULL LINUX UDP BASELINE ==='",
        'P7 stage label',
    ),
    (
        '        --between-runs-seconds 5 \\\n',
        '        --between-runs-seconds 10 \\\n',
        'P7 between-runs cooldown',
    ),
    (
        '        --disable-rps 1 \\\n        --nic-offloads native \\\n',
        '        --disable-rps 1 \\\n        --disable-rdma 1 \\\n        --nic-offloads paper \\\n        --udp-rmem 6815744 \\\n        --udp-wmem 6815744 \\\n        --combined-channels 1 \\\n        --network-diagnostics 0 \\\n',
        'P7 paper networking block',
    ),
    (
        'P7_config=native_offloads+IRQ_CPU19+QUIC_21_22_23_24+pinning+RPS_off',
        'P7_config=paper_offloads+disable_RDMA+rmem_6815744+wmem_6815744+combined_channels_1+IRQ_CPU19+QUIC_21_22_23_24+pinning+RPS_off+between_runs_10s',
        'P7 source-path description',
    ),
    (
        'zip_one "$P7OUT" "P7_LINUX_NATIVE_${RUNS}r_${DOWNLOADS}d_${TAG}"',
        'zip_one "$P7OUT" "P7_LINUX_PAPER_${RUNS}r_${DOWNLOADS}d_${TAG}"',
        'P7 export archive label',
    ),
]

for old, new, label in replacements:
    count = src.count(old)
    if count != 1:
        raise SystemExit(
            f"ERROR: {label}: expected exactly one anchor in base runner, found {count}"
        )
    src = src.replace(old, new, 1)

# Add an explicit configuration marker near the remote P7 stage.
anchor = "if [ \"$BP71\" -eq 0 ] && [ \"$BP72\" -eq 0 ]; then\n"
marker = (
    anchor
    + "    echo 'P7 PAPER CONFIG: offloads=paper disable_rdma=1 rmem=6815744 wmem=6815744 channels=1 between_runs=10s cpu19 quic=21,22,23,24'\n"
)
if src.count(anchor) != 1:
    raise SystemExit(f"ERROR: P7 marker anchor count={src.count(anchor)}")
src = src.replace(anchor, marker, 1)

Path(sys.argv[2]).write_text(src, encoding="utf-8")
PY

chmod 0700 "$PATCHED"
bash -n "$PATCHED"

# Do not delete PATCHED here: in --detach mode the generated runner recursively
# invokes its own path for the long-lived foreground orchestrator.
exec bash "$PATCHED" "$@"
