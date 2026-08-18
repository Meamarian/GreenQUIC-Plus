#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
BASE="$HERE/mac_launch_p5_onecore_research.sh"
SUITE="$HERE/run_p5_11g_target_suite.sh"

for f in "$BASE" "$SUITE"; do
    [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 2; }
done

# Guard the exact current-environment requirements before launching anything.
grep -Fq 'GQ_CLAIM_RECORDER_CPU="$RECORDER_CPU"' "$SUITE"
grep -Fq 'P5_11G_ACTIVE_RECORDERS:-1' "$SUITE"
grep -Fq -- '--between-tests-seconds 5' "$SUITE"
grep -Fq -- '--server-cooldown-seconds 5' "$SUITE"
grep -Fq -- '--gap-seconds 5' "$SUITE"
grep -Fq -- '--env SERVER_DPDK_LCORES=19' "$SUITE"
grep -Fq -- '--env SERVER_QUIC_CPUS=21,22,23,24' "$SUITE"
grep -Fq 'add_screen s7_p2d5_e10k_active2' "$SUITE"

# Run only the existing 11G target stage. Candidate definitions, D2+ scoring,
# 11.0-Gbit/s threshold, CPU topology, timings and measurement setup are kept.
# Relative to the current fair P5 measurement, the requested repetition count is
# two and the download count remains five for both screen and paired validation.
export P5_ONECORE_STAGES=11g
export P5_11G_SCREEN_RUNS=2
export P5_11G_SCREEN_DOWNLOADS=5
export P5_11G_VALIDATE_RUNS=2
export P5_11G_VALIDATE_DOWNLOADS=5
export P5_11G_TARGET_GBPS=11.0

cat <<'EOF'
======================================================================
P5 11G TARGET — CURRENT OPTIMIZED/PINNED CONFIG
screen:     2 runs x 5 downloads per candidate
validation: 2 alternating pairs x 5 downloads per case
target:     11.0 Gbit/s, steady D2+ scoring
DPDK:       CPU19
QUIC:       CPUs21-24
recorders:  enabled, auto-pinned outside DPDK/QUIC CPUs + SMT siblings
timing:     5s gap, 5s edge cooldown, 5s between tests
NOTE: n=2 is exploratory; robust validation still requires >=6 runs.
======================================================================
EOF

exec bash "$BASE"
