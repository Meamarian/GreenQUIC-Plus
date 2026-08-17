#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
BUILD="$HERE/build_p5_arch_profile.sh"
CASE="$HERE/run_p5_arch_case_diag.sh"
SUM="$HERE/summarize_p5_arch_sweep.py"
CLEAN="$HERE/safe_cleanup_p5_bottleneck_processes.py"
PATCH="$HERE/enable_p5_arch_runtime_config.py"
RUNS="${P5_ARCH_RUNS:-2}"; CONNS="${P5_ARCH_CONNECTIONS:-4}"; TAG="${P5_ARCH_TAG:-$(date +%Y%m%d_%H%M%S)}"
ROOT="${P5_ARCH_OUTPUT_ROOT:-$HERE/matrix_results/P5_ARCH_BOTTLENECK_${CONNS}c_${RUNS}r_${TAG}}"
[[ "$RUNS" =~ ^[1-9][0-9]*$ && "$CONNS" =~ ^[2-9][0-9]*$ ]] || { echo 'ERROR invalid runs/connections' >&2; exit 2; }
for f in "$BUILD" "$CASE" "$SUM" "$CLEAN" "$PATCH" "$HERE/thread_topology_sampler.py" "$HERE/run_p5_arch_off_case.sh"; do [[ -f "$f" ]] || { echo "ERROR missing $f" >&2; exit 2; }; done
for shf in "$BUILD" "$CASE" "$HERE/run_p5_arch_off_case.sh"; do bash -n "$shf"; done
python3 -m py_compile "$SUM" "$PATCH" "$HERE/thread_topology_sampler.py" "$HERE/quic_cpu_activity_sampler.py" "$HERE/analyze_p5_bottleneck_case.py" "$HERE/cpu_busy_sampler.py"
mkdir -p "$ROOT/build_logs"
STATUS="$ROOT/CASE_STATUS.tsv"
printf 'case\tbuild_profile\tbuild_rc\ttraffic_rc\tcontroller_rc\tanalysis_rc\n' >"$STATUS"

# P5 already contains parser/runtime support for GreenQuicQuicAffinitize, but its
# local dpdk.ini writer omitted the key. Enable the key in the disposable node
# checkout only; the patch is idempotent and is applied on both endpoints.
python3 "$PATCH" "$HERE/../../../common/bin/gq_common.sh"
ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman "cd '$HERE' && python3 ./enable_p5_arch_runtime_config.py ../../../common/bin/gq_common.sh"

cleanup_between(){
  echo '--- safe cleanup IDEX ---'; python3 "$CLEAN" || true
  echo '--- safe cleanup Tinyman ---'; ssh -o BatchMode=yes -o ConnectTimeout=12 root@tinyman "cd '$HERE' && python3 '$CLEAN' || true" || true
}
build_profile(){
  local name="$1"; shift; local r1=0 r2=0 q=''
  echo "===== BUILD $name $* ====="
  set +e
  env "$@" bash "$BUILD" 2>&1 | tee "$ROOT/build_logs/${name}_idex.log"; r1=${PIPESTATUS[0]}
  printf -v q '%q ' "$@"
  ssh -o BatchMode=yes -o ConnectTimeout=20 root@tinyman "cd '$HERE' && env $q bash ./build_p5_arch_profile.sh" 2>&1 | tee "$ROOT/build_logs/${name}_tinyman.log"; r2=${PIPESTATUS[0]}
  set -e
  ((r1==0 && r2==0))
}
run_case(){
  local name="$1" profile="$2" brc="$3" dpdk="$4" quic="$5" part="$6" execp="$7" aff="$8"; shift 8
  local dir="$ROOT/$name" rc=125 cr='' ar=''; mkdir -p "$dir"
  echo "===== CASE $name DPDK=$dpdk QUIC=$quic partition=$part exec=$execp aff=$aff ====="
  if ((brc!=0)); then printf '%s\t%s\t%s\t125\t\t\n' "$name" "$profile" "$brc" >>"$STATUS"; echo "SKIP $name build failed" >&2; return 0; fi
  cleanup_between
  set +e
  bash "$CASE" --case-name "$name" --runs "$RUNS" --connections "$CONNS" --dpdk-lcores "$dpdk" --quic-cpus "$quic" --partition-style "$part" --execution-profile "$execp" --affinitize "$aff" --output-dir "$dir" "$@"
  rc=$?
  set -e
  if [[ -f "$dir/ARCH_CASE_STATUS.env" ]]; then
    cr="$(awk -F= '$1=="controller_rc"{print $2}' "$dir/ARCH_CASE_STATUS.env")"
    ar="$(awk -F= '$1=="analysis_rc"{print $2}' "$dir/ARCH_CASE_STATUS.env")"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$profile" "$brc" "$rc" "$cr" "$ar" >>"$STATUS"
  ((rc==0)) || echo "WARN: $name traffic rc=$rc; continuing to next case" >&2
}

cat >"$ROOT/SWEEP_DESIGN.txt" <<EOF
P5 architectural bottleneck localization -- 16 cases A-P
All normal traffic cases: OFF, $CONNS simultaneous 8-GiB QUIC downloads, $RUNS repetitions, MTU1500.
Goal: find architectural changes large enough to move ~8.7 Gbit/s toward >=11 Gbit/s.
Traffic success is independent of diagnostics/plotting/report success.

A  2 DPDK / 4 QUIC workers, AFFINITIZE=0 -- reproduce current behavior
B  2 DPDK / 4 QUIC workers, AFFINITIZE=1 -- primary reference
C  2 DPDK / 1 QUIC worker, AFFINITIZE=1 -- QUIC serialization control
D  2 DPDK / 2 QUIC workers, AFFINITIZE=1 -- QUIC scaling step
E  2 DPDK / 8 QUIC workers, AFFINITIZE=1 -- excess QUIC execution capacity
F  1 DPDK / 4 QUIC workers, AFFINITIZE=1 -- dataplane single-core control
G  4 DPDK / 4 QUIC workers, AFFINITIZE=1 -- dataplane scaling
H  4 DPDK / 8 QUIC workers, AFFINITIZE=1 -- combined worker+dataplane scaling
I  2 DPDK / 4 QUIC, low_latency execution profile
J  2 DPDK / 4 QUIC, all QUIC partitions mapped to DPDK19 -- serialization stress control
K  2 DPDK / 4 QUIC, grouped map 0,1->19 and 2,3->20
L  2 DPDK / 4 QUIC, classic MP TX-ring synchronization
M  2 DPDK / 4 QUIC, RTS TX-ring synchronization
N  1 DPDK / 4 QUIC, optimized sharded per-producer SPSC handoff -- compare with F
O  2 DPDK / 4 QUIC, UDP-segmentation/offload capability path (fails closed if unsupported)
P  rebuild + repeat B at end -- drift/thermal control

Every case captures aggregate/per-connection goodput, all process TIDs with CPU-time/CPU-set evidence,
selected QUIC-worker activity, /proc/stat CPU busy traces, and per-DPDK-lcore packet counters when emitted.
A completed QUIC batch remains TRAFFIC PASS even if a plot/report/diagnostic fails after transfer completion.
EOF

BRC=0; build_profile baseline || BRC=$?
run_case A_2D_4Q_noaff baseline "$BRC" 19,20 21,22,23,24 balanced max_throughput 0
run_case B_2D_4Q_aff baseline "$BRC" 19,20 21,22,23,24 balanced max_throughput 1
run_case C_2D_1Q_aff baseline "$BRC" 19,20 21 balanced max_throughput 1
run_case D_2D_2Q_aff baseline "$BRC" 19,20 21,22 balanced max_throughput 1
run_case E_2D_8Q_aff baseline "$BRC" 19,20 21,22,23,24,25,26,27,28 balanced max_throughput 1
run_case F_1D_4Q_aff baseline "$BRC" 19 21,22,23,24 balanced max_throughput 1
run_case G_4D_4Q_aff baseline "$BRC" 17,18,19,20 21,22,23,24 balanced max_throughput 1
run_case H_4D_8Q_aff baseline "$BRC" 17,18,19,20 21,22,23,24,25,26,27,28 balanced max_throughput 1
run_case I_2D_4Q_lowlat baseline "$BRC" 19,20 21,22,23,24 balanced low_latency 1
run_case J_2D_4Q_allfirst baseline "$BRC" 19,20 21,22,23,24 all_first max_throughput 1
run_case K_2D_4Q_grouped baseline "$BRC" 19,20 21,22,23,24 grouped max_throughput 1

BRC_MP=0; build_profile ring_mp P5_SUPER_RING_SYNC=mp || BRC_MP=$?
run_case L_2D_4Q_ring_mp ring_mp "$BRC_MP" 19,20 21,22,23,24 balanced max_throughput 1

BRC_RTS=0; build_profile ring_rts P5_SUPER_RING_SYNC=rts || BRC_RTS=$?
run_case M_2D_4Q_ring_rts ring_rts "$BRC_RTS" 19,20 21,22,23,24 balanced max_throughput 1

BRC_SH=0; build_profile sharded P5_P2_TX_HANDOFF=sharded P5_P2_SHARD_ACTIVE_MASK=1 || BRC_SH=$?
run_case N_1D_4Q_sharded sharded "$BRC_SH" 19 21,22,23,24 balanced max_throughput 1

BRC_USO=0; build_profile udpseg P5_P2_UDP_SEG=1 P5_P2_UDP_SEG_MAX=4 || BRC_USO=$?
run_case O_2D_4Q_udpseg udpseg "$BRC_USO" 19,20 21,22,23,24 balanced max_throughput 1

BRC2=0; build_profile baseline_repeat || BRC2=$?
run_case P_2D_4Q_aff_repeat baseline_repeat "$BRC2" 19,20 21,22,23,24 balanced max_throughput 1

cleanup_between
python3 "$SUM" --root "$ROOT" || echo 'WARN: summary failed; raw cases preserved' >&2
echo "P5 ARCH BOTTLENECK SWEEP COMPLETE RESULTS=$ROOT STATUS=$STATUS"
exit 0
