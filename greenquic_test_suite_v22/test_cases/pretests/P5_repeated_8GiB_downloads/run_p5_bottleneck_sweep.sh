#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
BUILD="$HERE/build_p5_multicore_performance2.sh"
CASE_RUNNER="$HERE/run_p5_parallel_off_case.sh"
SUMMARY="$HERE/summarize_p5_bottleneck_sweep.py"
CLEANER="$HERE/safe_cleanup_p5_bottleneck_processes.py"

RUNS="${P5_BOTTLENECK_RUNS:-2}"
CONNECTIONS="${P5_BOTTLENECK_CONNECTIONS:-4}"
TAG="${P5_BOTTLENECK_TAG:-$(date +%Y%m%d_%H%M%S)}"
OUTPUT_ROOT="${P5_BOTTLENECK_OUTPUT_ROOT:-$HERE/matrix_results/P5_BOTTLENECK_SWEEP_${CONNECTIONS}c_${RUNS}r_${TAG}}"

[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: P5_BOTTLENECK_RUNS must be positive" >&2; exit 2; }
[[ "$CONNECTIONS" =~ ^[2-9][0-9]*$ ]] || { echo "ERROR: P5_BOTTLENECK_CONNECTIONS must be >=2" >&2; exit 2; }
for f in "$BUILD" "$CASE_RUNNER" "$SUMMARY" "$CLEANER"; do [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 2; }; done
python3 -m py_compile "$SUMMARY" "$CLEANER"
bash -n "$CASE_RUNNER"
mkdir -p "$OUTPUT_ROOT/build_logs"
STATUS="$OUTPUT_ROOT/CASE_STATUS.tsv"
printf 'case\treference\tbuild_profile\tbuild_rc\ttraffic_analysis_rc\n' > "$STATUS"

COMMON_PROFILE=(
  P5_BUILD_REUSE=1
  P5_SUPER_MTU=1500
  P5_SUPER_CACHE=128
  P5_SUPER_RX_BURST=32
  P5_SUPER_TX_BURST=16
  P5_SUPER_RING_SIZE=4096
  P5_SUPER_RING_SYNC=legacy
  P5_SUPER_DRAIN_BURSTS=2
  P5_SUPER_DRAIN_THRESHOLD=0
  P5_SUPER_TX_LOCK_MODE=single_owner
  P5_P2_TX_HANDOFF=shared
  P5_P2_TX_PRODUCER_RING_SIZE=1024
  P5_P2_RX_PREFETCH=0
  P5_P2_UDP_SEG=0
  P5_P2_TX_ALLOC_BATCH=8
  P5_P2_TX_ENQUEUE_COUNTER=0
  P5_P2_TX_META_ZERO=1
  P5_P2_RX_PIPE_PREFETCH=2
  P5_P2_SHARD_ACTIVE_MASK=0
)

cleanup_between_cases(){
  echo "--- safe cleanup between cases: IDEX ---"
  python3 "$CLEANER" || true
  echo "--- safe cleanup between cases: Tinyman ---"
  ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman "cd '$HERE' && python3 '$CLEANER' || true" || true
}

build_profile(){
  local profile="$1"; shift
  local args=("${COMMON_PROFILE[@]}" "$@")
  local q=""
  printf '======================================================================\n'
  printf 'BUILD PROFILE %s\n' "$profile"
  printf '  %s\n' "${args[@]}"
  printf '======================================================================\n'
  set +e
  env "${args[@]}" bash "$BUILD" 2>&1 | tee "$OUTPUT_ROOT/build_logs/${profile}_idex.log"
  local rc1=${PIPESTATUS[0]}
  printf -v q '%q ' "${args[@]}"
  ssh -o BatchMode=yes -o ConnectTimeout=20 root@tinyman \
    "cd '$HERE' && env $q bash ./build_p5_multicore_performance2.sh" 2>&1 | tee "$OUTPUT_ROOT/build_logs/${profile}_tinyman.log"
  local rc2=${PIPESTATUS[0]}
  set -e
  if (( rc1 != 0 || rc2 != 0 )); then
    echo "BUILD PROFILE FAIL profile=$profile idex_rc=$rc1 tinyman_rc=$rc2" >&2
    return 1
  fi
  echo "BUILD PROFILE PASS profile=$profile"
  return 0
}

write_profile(){
  local case_dir="$1" profile="$2" reference="$3"; shift 3
  mkdir -p "$case_dir"
  {
    echo "build_profile=$profile"
    echo "comparison_reference=$reference"
    printf '%s\n' "${COMMON_PROFILE[@]}"
    printf '%s\n' "$@"
  } > "$case_dir/BUILD_PROFILE.env"
}

run_case(){
  local name="$1" lcores="$2" reference="$3" profile="$4" build_rc="$5"; shift 5
  local case_dir="$OUTPUT_ROOT/$name"
  write_profile "$case_dir" "$profile" "$reference" "$@"
  echo
  echo "######################################################################"
  echo "BOTTLENECK CASE $name"
  echo "  reference=$reference profile=$profile dpdk_lcores=$lcores runs=$RUNS connections=$CONNECTIONS"
  echo "  workload=OFF, ${CONNECTIONS} simultaneous x 8GiB"
  echo "######################################################################"
  if (( build_rc != 0 )); then
    echo "SKIP $name because build profile $profile failed" >&2
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$reference" "$profile" "$build_rc" 125 >> "$STATUS"
    return 0
  fi
  cleanup_between_cases
  set +e
  bash "$CASE_RUNNER" \
    --case-name "$name" \
    --runs "$RUNS" \
    --connections "$CONNECTIONS" \
    --dpdk-lcores "$lcores" \
    --output-dir "$case_dir"
  local rc=$?
  set -e
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$reference" "$profile" "$build_rc" "$rc" >> "$STATUS"
  if (( rc != 0 )); then
    echo "WARN: case $name failed rc=$rc; sweep CONTINUES" >&2
  else
    echo "CASE PASS $name"
  fi
  return 0
}

cat > "$OUTPUT_ROOT/SWEEP_DESIGN.txt" <<EOF
P5 bottleneck isolation sweep
=============================
All traffic cases use OFF mode, $CONNECTIONS simultaneous QUIC connections,
8 GiB per connection, $RUNS repetitions, MTU 1500, QUIC CPU set 21-24,
max-throughput execution profile and identical measurement instrumentation.

A_1c_baseline      : one DPDK lcore (19), current measured Performance2 design
B_2c_baseline      : A + only DPDK lcore 20 / second RX+TX queue
C_1c_ring_mp       : A + producer ring synchronization legacy-HTS -> classic MP
D_1c_ring_rts      : A + producer ring synchronization legacy-HTS -> RTS
E_2c_txalloc1      : B + TX mbuf allocation batch 8 -> 1
F_2c_txalloc32     : B + TX mbuf allocation batch 8 -> 32
G_2c_rxpipe0       : B + RX pipeline prefetch 2 -> 0
H_2c_rxpipe4       : B + RX pipeline prefetch 2 -> 4
I_2c_txburst32     : B + hardware TX burst 16 -> 32
J_2c_drain4        : B + TX drain bursts per poll 2 -> 4
K_2c_rxburst64     : B + hardware RX burst 32 -> 64
L_2c_txmetazero0   : B + remove full TX metadata struct zeroing

Reference rules:
  A -> B isolates DPDK core-count scaling using the exact same binary bits.
  C,D compare with A because they alter the shared producer ring before one TX consumer.
  E-L compare with B because they alter one datapath dimension with two active DPDK owners.

The existing Performance2 sharded-producer experiment is intentionally excluded:
its SPSC producer rings are designed around a single consumer cursor, so using it
unchanged with two TX consumers would not be a clean bottleneck experiment.
EOF

# Exact current baseline build. A and B use identical binaries; only runtime
# topology changes, making A->B the clean core-count experiment.
BUILD_RC=0
build_profile baseline || BUILD_RC=$?
run_case A_1c_baseline 19 self baseline "$BUILD_RC"
run_case B_2c_baseline 19,20 A_1c_baseline baseline "$BUILD_RC"

# Producer-ring synchronization is tested with one consumer so the selected
# synchronization primitive is the only material change from A.
BUILD_RC=0
build_profile ring_mp P5_SUPER_RING_SYNC=mp || BUILD_RC=$?
run_case C_1c_ring_mp 19 A_1c_baseline ring_mp "$BUILD_RC" P5_SUPER_RING_SYNC=mp

BUILD_RC=0
build_profile ring_rts P5_SUPER_RING_SYNC=rts || BUILD_RC=$?
run_case D_1c_ring_rts 19 A_1c_baseline ring_rts "$BUILD_RC" P5_SUPER_RING_SYNC=rts

# Two-core datapath perturbations: one build variable at a time relative to B.
BUILD_RC=0
build_profile txalloc1 P5_P2_TX_ALLOC_BATCH=1 || BUILD_RC=$?
run_case E_2c_txalloc1 19,20 B_2c_baseline txalloc1 "$BUILD_RC" P5_P2_TX_ALLOC_BATCH=1

BUILD_RC=0
build_profile txalloc32 P5_P2_TX_ALLOC_BATCH=32 || BUILD_RC=$?
run_case F_2c_txalloc32 19,20 B_2c_baseline txalloc32 "$BUILD_RC" P5_P2_TX_ALLOC_BATCH=32

BUILD_RC=0
build_profile rxpipe0 P5_P2_RX_PIPE_PREFETCH=0 || BUILD_RC=$?
run_case G_2c_rxpipe0 19,20 B_2c_baseline rxpipe0 "$BUILD_RC" P5_P2_RX_PIPE_PREFETCH=0

BUILD_RC=0
build_profile rxpipe4 P5_P2_RX_PIPE_PREFETCH=4 || BUILD_RC=$?
run_case H_2c_rxpipe4 19,20 B_2c_baseline rxpipe4 "$BUILD_RC" P5_P2_RX_PIPE_PREFETCH=4

BUILD_RC=0
build_profile txburst32 P5_SUPER_TX_BURST=32 || BUILD_RC=$?
run_case I_2c_txburst32 19,20 B_2c_baseline txburst32 "$BUILD_RC" P5_SUPER_TX_BURST=32

BUILD_RC=0
build_profile drain4 P5_SUPER_DRAIN_BURSTS=4 || BUILD_RC=$?
run_case J_2c_drain4 19,20 B_2c_baseline drain4 "$BUILD_RC" P5_SUPER_DRAIN_BURSTS=4

BUILD_RC=0
build_profile rxburst64 P5_SUPER_RX_BURST=64 || BUILD_RC=$?
run_case K_2c_rxburst64 19,20 B_2c_baseline rxburst64 "$BUILD_RC" P5_SUPER_RX_BURST=64

BUILD_RC=0
build_profile txmetazero0 P5_P2_TX_META_ZERO=0 || BUILD_RC=$?
run_case L_2c_txmetazero0 19,20 B_2c_baseline txmetazero0 "$BUILD_RC" P5_P2_TX_META_ZERO=0

cleanup_between_cases
python3 "$SUMMARY" --root "$OUTPUT_ROOT"

echo "======================================================================"
echo "P5 BOTTLENECK SWEEP COMPLETE"
echo "RESULTS=$OUTPUT_ROOT"
echo "SUMMARY=$OUTPUT_ROOT/BOTTLENECK_SWEEP_SUMMARY.txt"
echo "CSV=$OUTPUT_ROOT/BOTTLENECK_SWEEP_SUMMARY.csv"
echo "STATUS=$STATUS"
echo "======================================================================"
# Case failures are data. Do not fail the top-level sweep after other cases ran.
exit 0
