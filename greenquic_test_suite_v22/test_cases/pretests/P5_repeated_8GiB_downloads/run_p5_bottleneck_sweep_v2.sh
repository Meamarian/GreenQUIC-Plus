#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
BUILD="$HERE/build_p5_bottleneck_profile.sh"
CASE_RUNNER="$HERE/run_p5_bottleneck_case_diag.sh"
SUMMARY="$HERE/summarize_p5_bottleneck_sweep_v2.py"
CLEANER="$HERE/safe_cleanup_p5_bottleneck_processes.py"
RUNS="${P5_BOTTLENECK_RUNS:-2}"
CONNECTIONS="${P5_BOTTLENECK_CONNECTIONS:-4}"
TAG="${P5_BOTTLENECK_TAG:-$(date +%Y%m%d_%H%M%S)}"
OUTPUT_ROOT="${P5_BOTTLENECK_OUTPUT_ROOT:-$HERE/matrix_results/P5_BOTTLENECK_SWEEP_V2_${CONNECTIONS}c_${RUNS}r_${TAG}}"
Q4="21,22,23,24"
[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: runs must be positive" >&2;exit 2; }
[[ "$CONNECTIONS" =~ ^[2-9][0-9]*$ ]] || { echo "ERROR: connections must be >=2" >&2;exit 2; }
for x in "$BUILD" "$CASE_RUNNER" "$SUMMARY" "$CLEANER";do [[ -f "$x" ]]||{ echo "ERROR: missing $x" >&2;exit 2;};done
bash -n "$BUILD";bash -n "$CASE_RUNNER";python3 -m py_compile "$SUMMARY" "$CLEANER" "$HERE/cpu_busy_sampler.py" "$HERE/analyze_p5_bottleneck_case.py" "$HERE/apply_p5_bottleneck_txq.py" "$HERE/quic_cpu_activity_sampler.py"
mkdir -p "$OUTPUT_ROOT/build_logs"
STATUS="$OUTPUT_ROOT/CASE_STATUS.tsv"
printf 'case\treference\tdpdk_lcores\tquic_cpus\tbuild_profile\tbuild_rc\ttraffic_analysis_rc\n' >"$STATUS"
COMMON=(P5_BUILD_REUSE=1 P5_SUPER_MTU=1500 P5_SUPER_CACHE=128 P5_SUPER_RX_BURST=32 P5_SUPER_TX_BURST=16 P5_SUPER_RING_SIZE=4096 P5_SUPER_RING_SYNC=legacy P5_SUPER_DRAIN_BURSTS=2 P5_SUPER_DRAIN_THRESHOLD=0 P5_SUPER_SKIP_OFF_RINGCOUNT=0 P5_SUPER_DEBUG_COUNTERS=1 P5_SUPER_TRACE_RINGCOUNT=1 P5_SUPER_TX_LOCK_MODE=single_owner P5_P2_TX_HANDOFF=shared P5_P2_TX_PRODUCER_RING_SIZE=1024 P5_P2_RX_PREFETCH=0 P5_P2_UDP_SEG=0 P5_P2_TX_ALLOC_BATCH=8 P5_P2_TX_ENQUEUE_COUNTER=0 P5_P2_TX_META_ZERO=1 P5_P2_RX_PIPE_PREFETCH=2 P5_P2_SHARD_ACTIVE_MASK=0)
cleanup_between(){ echo '--- cleanup IDEX ---';python3 "$CLEANER"||true;echo '--- cleanup Tinyman ---';ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman "cd '$HERE' && python3 '$CLEANER' || true"||true; }
build_profile(){ local p="$1";shift;local a=("${COMMON[@]}" "$@");local q='';echo "======================================================================";echo "BUILD PROFILE $p";printf '  %s\n' "${a[@]}";echo "======================================================================";set +e;env "${a[@]}" bash "$BUILD" 2>&1|tee "$OUTPUT_ROOT/build_logs/${p}_idex.log";local r1=${PIPESTATUS[0]};printf -v q '%q ' "${a[@]}";ssh -o BatchMode=yes -o ConnectTimeout=20 root@tinyman "cd '$HERE' && env $q bash ./build_p5_bottleneck_profile.sh" 2>&1|tee "$OUTPUT_ROOT/build_logs/${p}_tinyman.log";local r2=${PIPESTATUS[0]};set -e;if ((r1||r2));then echo "BUILD FAIL $p idex=$r1 tiny=$r2" >&2;return 1;fi;echo "BUILD PASS $p"; }
run_case(){ local n="$1" lc="$2" qc="$3" ref="$4" p="$5" brc="$6";shift 6;local d="$OUTPUT_ROOT/$n";mkdir -p "$d";{ echo "build_profile=$p";echo "comparison_reference=$ref";echo "runtime_dpdk_lcores=$lc";echo "runtime_quic_cpus=$qc";printf '%s\n' "${COMMON[@]}";printf '%s\n' "$@";} >"$d/BUILD_PROFILE.env";echo;echo "######################################################################";echo "CASE $n reference=$ref profile=$p DPDK=$lc QUIC=$qc runs=$RUNS connections=$CONNECTIONS";echo "######################################################################";if ((brc));then echo "SKIP $n build failed" >&2;printf '%s\t%s\t%s\t%s\t%s\t%s\t125\n' "$n" "$ref" "$lc" "$qc" "$p" "$brc" >>"$STATUS";return 0;fi;cleanup_between;set +e;bash "$CASE_RUNNER" --case-name "$n" --runs "$RUNS" --connections "$CONNECTIONS" --dpdk-lcores "$lc" --quic-cpus "$qc" --output-dir "$d";local rc=$?;set -e;printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$ref" "$lc" "$qc" "$p" "$brc" "$rc" >>"$STATUS";((rc==0))&&echo "CASE PASS $n"||echo "WARN: CASE $n rc=$rc; CONTINUING" >&2;return 0; }
cat >"$OUTPUT_ROOT/SWEEP_DESIGN.txt" <<EOF
P5 bottleneck localization sweep V2
All traffic: OFF, $CONNECTIONS simultaneous downloads, 8GiB each, $RUNS reps, MTU1500.
A/B use identical binary; only DPDK runtime topology differs.
A  1c baseline: DPDK19
B  2c baseline: DPDK19,20 (reference for E-Q)
C  A + producer ring classic MP
D  A + producer ring RTS
E  B + TX allocation batch 8->1
F  B + TX allocation batch 8->32
G  B + RX pipeline prefetch 2->0
H  B + RX pipeline prefetch 2->4
I  B + TX burst 16->32
J  B + TX burst 16->64
K  B + TX drain bursts 2->4
L  B + RX burst 32->64
M  B + remove full TX metadata zeroing
N  B + skip OFF ring-count hot-path bookkeeping
O  B + disable optional debug counters
P  B + software TX ring 4096->8192
Q  B + mbuf cache 128->256
R  end-of-sweep 2c baseline repeat (drift control)
S  same binary as R, QUIC workers 21,22
T  same binary as R, QUIC worker 21 only
Sharded Performance2 handoff intentionally excluded: current helper has one consumer cursor and is not a clean two-TX-consumer perturbation.
EOF
BRC=0;build_profile baseline||BRC=$?;run_case A_1c_baseline 19 "$Q4" self baseline "$BRC";run_case B_2c_baseline 19,20 "$Q4" A_1c_baseline baseline "$BRC"
BRC=0;build_profile ring_mp P5_SUPER_RING_SYNC=mp||BRC=$?;run_case C_1c_ring_mp 19 "$Q4" A_1c_baseline ring_mp "$BRC" P5_SUPER_RING_SYNC=mp
BRC=0;build_profile ring_rts P5_SUPER_RING_SYNC=rts||BRC=$?;run_case D_1c_ring_rts 19 "$Q4" A_1c_baseline ring_rts "$BRC" P5_SUPER_RING_SYNC=rts
BRC=0;build_profile txalloc1 P5_P2_TX_ALLOC_BATCH=1||BRC=$?;run_case E_2c_txalloc1 19,20 "$Q4" B_2c_baseline txalloc1 "$BRC" P5_P2_TX_ALLOC_BATCH=1
BRC=0;build_profile txalloc32 P5_P2_TX_ALLOC_BATCH=32||BRC=$?;run_case F_2c_txalloc32 19,20 "$Q4" B_2c_baseline txalloc32 "$BRC" P5_P2_TX_ALLOC_BATCH=32
BRC=0;build_profile rxpipe0 P5_P2_RX_PIPE_PREFETCH=0||BRC=$?;run_case G_2c_rxpipe0 19,20 "$Q4" B_2c_baseline rxpipe0 "$BRC" P5_P2_RX_PIPE_PREFETCH=0
BRC=0;build_profile rxpipe4 P5_P2_RX_PIPE_PREFETCH=4||BRC=$?;run_case H_2c_rxpipe4 19,20 "$Q4" B_2c_baseline rxpipe4 "$BRC" P5_P2_RX_PIPE_PREFETCH=4
BRC=0;build_profile txburst32 P5_SUPER_TX_BURST=32||BRC=$?;run_case I_2c_txburst32 19,20 "$Q4" B_2c_baseline txburst32 "$BRC" P5_SUPER_TX_BURST=32
BRC=0;build_profile txburst64 P5_SUPER_TX_BURST=64||BRC=$?;run_case J_2c_txburst64 19,20 "$Q4" B_2c_baseline txburst64 "$BRC" P5_SUPER_TX_BURST=64
BRC=0;build_profile drain4 P5_SUPER_DRAIN_BURSTS=4||BRC=$?;run_case K_2c_drain4 19,20 "$Q4" B_2c_baseline drain4 "$BRC" P5_SUPER_DRAIN_BURSTS=4
BRC=0;build_profile rxburst64 P5_SUPER_RX_BURST=64||BRC=$?;run_case L_2c_rxburst64 19,20 "$Q4" B_2c_baseline rxburst64 "$BRC" P5_SUPER_RX_BURST=64
BRC=0;build_profile txmetazero0 P5_P2_TX_META_ZERO=0||BRC=$?;run_case M_2c_txmetazero0 19,20 "$Q4" B_2c_baseline txmetazero0 "$BRC" P5_P2_TX_META_ZERO=0
BRC=0;build_profile skipoffcount P5_SUPER_SKIP_OFF_RINGCOUNT=1||BRC=$?;run_case N_2c_skipoffcount 19,20 "$Q4" B_2c_baseline skipoffcount "$BRC" P5_SUPER_SKIP_OFF_RINGCOUNT=1
BRC=0;build_profile debug0 P5_SUPER_DEBUG_COUNTERS=0||BRC=$?;run_case O_2c_debug0 19,20 "$Q4" B_2c_baseline debug0 "$BRC" P5_SUPER_DEBUG_COUNTERS=0
BRC=0;build_profile ring8192 P5_SUPER_RING_SIZE=8192||BRC=$?;run_case P_2c_ring8192 19,20 "$Q4" B_2c_baseline ring8192 "$BRC" P5_SUPER_RING_SIZE=8192
BRC=0;build_profile cache256 P5_SUPER_CACHE=256||BRC=$?;run_case Q_2c_cache256 19,20 "$Q4" B_2c_baseline cache256 "$BRC" P5_SUPER_CACHE=256
# Rebuild baseline once at the end. R/S/T all use these identical binary bits.
BRC=0;build_profile baseline_end||BRC=$?;run_case R_2c_baseline_repeat 19,20 "$Q4" B_2c_baseline baseline_end "$BRC";run_case S_2c_quic2 19,20 21,22 R_2c_baseline_repeat baseline_end "$BRC";run_case T_2c_quic1 19,20 21 R_2c_baseline_repeat baseline_end "$BRC"
cleanup_between
python3 "$SUMMARY" --root "$OUTPUT_ROOT"||echo "WARN: final summary failed; raw data preserved" >&2
echo "======================================================================";echo "P5 BOTTLENECK SWEEP V2 COMPLETE";echo "RESULTS=$OUTPUT_ROOT";echo "SUMMARY=$OUTPUT_ROOT/BOTTLENECK_SWEEP_SUMMARY.txt";echo "CSV=$OUTPUT_ROOT/BOTTLENECK_SWEEP_SUMMARY.csv";echo "STATUS=$STATUS";echo "======================================================================"
exit 0
