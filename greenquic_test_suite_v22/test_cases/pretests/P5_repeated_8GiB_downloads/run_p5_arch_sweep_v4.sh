#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
BUILD="$HERE/build_p5_bottleneck_profile.sh"
CASE="$HERE/run_p5_arch_off_case_v4.sh"
SUMMARY="$HERE/summarize_p5_arch_v4.py"
CLEANER="$HERE/safe_cleanup_p5_bottleneck_processes.py"
OVERLAY="$HERE/apply_p5_arch_runtime_overlay_v4.py"
RUNS="${P5_ARCH4_RUNS:-2}"; CONNECTIONS="${P5_ARCH4_CONNECTIONS:-4}"; TAG="${P5_ARCH4_TAG:-$(date +%Y%m%d_%H%M%S)}"
OUT="${P5_ARCH4_OUTPUT_ROOT:-$HERE/matrix_results/P5_ARCH_V4_${CONNECTIONS}c_${RUNS}r_${TAG}}"
[[ "$RUNS" =~ ^[1-9][0-9]*$ && "$CONNECTIONS" == 4 ]] || { echo 'ERROR: P5_ARCH4_RUNS positive and P5_ARCH4_CONNECTIONS=4 required' >&2; exit 2; }
for f in "$BUILD" "$CASE" "$SUMMARY" "$CLEANER" "$OVERLAY";do [[ -f "$f" ]]||{ echo "ERROR missing $f" >&2;exit 2;};done
bash -n "$BUILD";bash -n "$CASE";python3 -m py_compile "$SUMMARY" "$OVERLAY"
mkdir -p "$OUT/build_logs"
STATUS="$OUT/CASE_STATUS.tsv"
printf 'case\tgroup\tdpdk_lcores\tquic_cpus\tquic_affinitize\texecution_profile\tpartition_map\tbuild_profile\tbuild_rc\tcase_rc\ttraffic_rc\tcontroller_rc\tanalysis_rc\n' >"$STATUS"

# Make AFFINITIZE explicit on both endpoints. This modifies only the disposable remote checkout.
python3 "$OVERLAY" "$HERE/gq_common_p5.sh"
ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman "cd '$HERE' && python3 '$OVERLAY' '$HERE/gq_common_p5.sh'"

afe_cleanup(){
  python3 "$CLEANER" || true
  ssh -o BatchMode=yes -o ConnectTimeout=15 root@tinyman "cd '$HERE' && python3 '$CLEANER' || true" || true
}

COMMON=(P5_BUILD_REUSE=1 P5_SUPER_MTU=1500 P5_SUPER_CACHE=128 P5_SUPER_RX_BURST=32 P5_SUPER_TX_BURST=16 P5_SUPER_RING_SIZE=4096 P5_SUPER_RING_SYNC=legacy P5_SUPER_DRAIN_BURSTS=2 P5_SUPER_DRAIN_THRESHOLD=0 P5_SUPER_SKIP_OFF_RINGCOUNT=0 P5_SUPER_DEBUG_COUNTERS=1 P5_SUPER_TRACE_RINGCOUNT=1 P5_SUPER_TX_LOCK_MODE=single_owner P5_P2_TX_HANDOFF=shared P5_P2_TX_PRODUCER_RING_SIZE=1024 P5_P2_RX_PREFETCH=0 P5_P2_UDP_SEG=0 P5_P2_TX_ALLOC_BATCH=8 P5_P2_TX_ENQUEUE_COUNTER=0 P5_P2_TX_META_ZERO=1 P5_P2_RX_PIPE_PREFETCH=2 P5_P2_SHARD_ACTIVE_MASK=0)

build_profile(){
  local name="$1";shift;local q r1 r2
  echo "==== BUILD $name ===="
  set +e;env "${COMMON[@]}" "$@" bash "$BUILD" 2>&1|tee "$OUT/build_logs/${name}_idex.log";r1=${PIPESTATUS[0]}
  printf -v q '%q ' "${COMMON[@]}" "$@"
  ssh -o BatchMode=yes -o ConnectTimeout=20 root@tinyman "cd '$HERE' && env $q bash '$BUILD'" 2>&1|tee "$OUT/build_logs/${name}_tinyman.log";r2=${PIPESTATUS[0]};set -e
  ((r1==0&&r2==0))||{ echo "WARN build $name failed idex=$r1 tiny=$r2" >&2;return 1;}
}

run_case(){
  local name="$1" group="$2" dpdk="$3" quic="$4" aff="$5" profile="$6" pmap="$7" bprof="$8" brc="$9";shift 9
  local dir="$OUT/$name" rc=0 tr='?' cr='?' ar='?'
  mkdir -p "$dir"
  echo "==== CASE $name group=$group DPDK=$dpdk QUIC=$quic aff=$aff profile=$profile map=$pmap ===="
  if ((brc!=0));then rc=125;else
    afe_cleanup
    set +e
    bash "$CASE" --case-name "$name" --output-dir "$dir" --runs "$RUNS" --connections "$CONNECTIONS" --dpdk-lcores "$dpdk" --quic-cpus "$quic" --quic-affinitize "$aff" --execution-profile "$profile" --partition-map "$pmap"
    rc=$?;set -e
  fi
  if [[ -f "$dir/ARCH_CASE_STATUS.env" ]];then
    tr="$(awk -F= '$1=="traffic_rc"{print $2}' "$dir/ARCH_CASE_STATUS.env"|tail -1)"
    cr="$(awk -F= '$1=="controller_rc"{print $2}' "$dir/ARCH_CASE_STATUS.env"|tail -1)"
    ar="$(awk -F= '$1=="analysis_rc"{print $2}' "$dir/ARCH_CASE_STATUS.env"|tail -1)"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$group" "$dpdk" "$quic" "$aff" "$profile" "$pmap" "$bprof" "$brc" "$rc" "$tr" "$cr" "$ar" >>"$STATUS"
  ((rc==0))&&echo "CASE TRAFFIC PASS $name"||echo "WARN case $name rc=$rc; continuing" >&2
}

cat >"$OUT/SWEEP_DESIGN.txt" <<EOF
P5 ARCHITECTURAL BOTTLENECK SWEEP V4
====================================
Goal: find a large (~20-30%+) ceiling, not tune small buffers.
Traffic: OFF mode, 4 simultaneous QUIC connections, 8 GiB each, $RUNS repetitions, MTU 1500.
Traffic completion is authoritative and independent of controller/plot/analyzer failures.

A0  2 DPDK / 4 QUIC, AFFINITIZE=0: reproduces previous implicit behavior.
A1  2 DPDK / 4 QUIC, AFFINITIZE=1: main reference.
B1  2 DPDK / 1 QUIC worker: worker-count lower bound.
B2  2 DPDK / 2 QUIC workers.
B8  2 DPDK / 8 QUIC workers: test whether more MsQuic workers unlock production.
C1  1 DPDK / 4 QUIC workers on CPUs25-28.
C2  2 DPDK / same QUIC CPUs25-28.
C4  4 DPDK / same QUIC CPUs25-28: direct dataplane scaling.
Dg  2 DPDK / 4 QUIC with grouped partition map 0,1->19 and 2,3->20.
Do  2 DPDK / 4 QUIC with all partitions mapped to DPDK19: intentional serialization control.
E   low_latency MsQuic execution profile vs A1 max_throughput.
Fm  classic MP producer-ring synchronization.
Fr  RTS producer-ring synchronization.
Z   rebuild/repeat A1 at end to detect thermal/time drift.

Every case records exact-process QUIC CPU activity over CPUs0-63 plus configured CPU busy traces and per-DPDK-lcore packet counters.
EOF

# Baseline binary used for all runtime-topology/profile cases.
BRC=0;build_profile baseline||BRC=$?
run_case A0_2d4q_noaff worker_affinity 19,20 21,22,23,24 0 max_throughput '0:19,1:20,2:19,3:20' baseline "$BRC"
run_case A1_2d4q_aff worker_affinity 19,20 21,22,23,24 1 max_throughput '0:19,1:20,2:19,3:20' baseline "$BRC"
run_case B1_2d1q worker_count 19,20 21 1 max_throughput '0:19,1:20,2:19,3:20' baseline "$BRC"
run_case B2_2d2q worker_count 19,20 21,22 1 max_throughput '0:19,1:20,2:19,3:20' baseline "$BRC"
run_case B8_2d8q worker_count 19,20 21,22,23,24,25,26,27,28 1 max_throughput '0:19,1:20,2:19,3:20' baseline "$BRC"
run_case C1_1d4q dataplane_scaling 19 25,26,27,28 1 max_throughput '0:19,1:19,2:19,3:19' baseline "$BRC"
run_case C2_2d4q dataplane_scaling 19,20 25,26,27,28 1 max_throughput '0:19,1:20,2:19,3:20' baseline "$BRC"
run_case C4_4d4q dataplane_scaling 19,20,21,22 25,26,27,28 1 max_throughput '0:19,1:20,2:21,3:22' baseline "$BRC"
run_case Dg_grouped partition_map 19,20 21,22,23,24 1 max_throughput '0:19,1:19,2:20,3:20' baseline "$BRC"
run_case Do_allone partition_map 19,20 21,22,23,24 1 max_throughput '0:19,1:19,2:19,3:19' baseline "$BRC"
run_case E_lowlat execution_profile 19,20 21,22,23,24 1 low_latency '0:19,1:20,2:19,3:20' baseline "$BRC"

BRC=0;build_profile ring_mp P5_SUPER_RING_SYNC=mp||BRC=$?
run_case Fm_ring_mp producer_sync 19,20 21,22,23,24 1 max_throughput '0:19,1:20,2:19,3:20' ring_mp "$BRC"
BRC=0;build_profile ring_rts P5_SUPER_RING_SYNC=rts||BRC=$?
run_case Fr_ring_rts producer_sync 19,20 21,22,23,24 1 max_throughput '0:19,1:20,2:19,3:20' ring_rts "$BRC"

# Rebuild baseline before final drift control.
BRC=0;build_profile baseline_repeat||BRC=$?
run_case Z_repeat drift_control 19,20 21,22,23,24 1 max_throughput '0:19,1:20,2:19,3:20' baseline_repeat "$BRC"

afe_cleanup
python3 "$SUMMARY" --root "$OUT" || echo 'WARN summary failed; raw case data preserved' >&2
echo "P5 ARCH V4 COMPLETE RESULTS=$OUT STATUS=$STATUS"
exit 0
