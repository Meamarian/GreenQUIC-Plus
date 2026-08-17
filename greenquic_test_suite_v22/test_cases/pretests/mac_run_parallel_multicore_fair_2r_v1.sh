#!/usr/bin/env bash
set -Eeuo pipefail
REPO="${GREENQUIC_REPO:-$(pwd)}";BRANCH="performance2/p5-multicore";BASE_BRANCH="performance2/p5-max-goodput";BASE_SHA="045d7375c6af5810a9ce30a2db63231989ab3f12";RUNS="${PARALLEL_MC_RUNS:-2}";CONNECTIONS="${PARALLEL_MC_CONNECTIONS:-4}";PREFLIGHT_ONLY="${PARALLEL_MC_PREFLIGHT_ONLY:-0}";TAG="${PARALLEL_MC_TAG:-$(date +%Y%m%d_%H%M%S)}"
[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: PARALLEL_MC_RUNS must be positive" >&2;exit 2; };[[ "$CONNECTIONS" =~ ^[2-9][0-9]*$ ]] || { echo "ERROR: PARALLEL_MC_CONNECTIONS must be >=2" >&2;exit 2; };case "$PREFLIGHT_ONLY" in 0|1);;*) echo "ERROR: PARALLEL_MC_PREFLIGHT_ONLY must be 0 or 1" >&2;exit 2;;esac;[[ -d "$REPO/.git" ]] || { echo "ERROR: GREENQUIC_REPO is not a Git checkout: $REPO" >&2;exit 2; };cd "$REPO"
P5REL="greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads";P7REL="greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline";PREREL="greenquic_test_suite_v22/test_cases/pretests";REMOTE_ROOT="/root/mohsen";P5DIR="$REMOTE_ROOT/$P5REL";P7DIR="$REMOTE_ROOT/$P7REL";P5OUT="$P5DIR/matrix_results/P5_PARALLEL_MC_${CONNECTIONS}c_${RUNS}r_${TAG}";P7OUT="$P7DIR/matrix_results/P7_PARALLEL_MC_${CONNECTIONS}c_${RUNS}r_${TAG}";P5LOG="/root/P5_PARALLEL_MC_${TAG}.log";P7LOG="/root/P7_PARALLEL_MC_${TAG}.log";COMPARE="$REMOTE_ROOT/PARALLEL_MC_COMPARE_${TAG}.csv";COMPARE_ACTIVE="$REMOTE_ROOT/PARALLEL_MC_COMPARE_${TAG}_active.csv";LOCAL_EXPORT="$HOME/Downloads/PARALLEL_MC_FAIR_${TAG}";mkdir -p "$LOCAL_EXPORT"
cleanup_local(){ rm -f "/tmp/greenquic_parallel_mc_${TAG}.bundle"; };trap cleanup_local EXIT

printf '\n=== 1. FETCH BRANCH ON MAC ===\n';git fetch origin "refs/heads/$BASE_BRANCH:refs/remotes/origin/$BASE_BRANCH" "refs/heads/$BRANCH:refs/remotes/origin/$BRANCH";HEAD="$(git rev-parse "refs/remotes/origin/$BRANCH")";MERGE_BASE="$(git merge-base "refs/remotes/origin/$BASE_BRANCH" "refs/remotes/origin/$BRANCH")";[[ "$MERGE_BASE" == "$BASE_SHA" ]] || { echo "ERROR: branch merge-base changed: $MERGE_BASE expected $BASE_SHA" >&2;exit 2; }
if [[ -n "$(git diff --name-only "refs/remotes/origin/$BASE_BRANCH..refs/remotes/origin/$BRANCH" --diff-filter=MDRTUXB)" ]];then echo "ERROR: multicore branch modifies/deletes base files; expected additive isolation only" >&2;git diff --name-status "refs/remotes/origin/$BASE_BRANCH..refs/remotes/origin/$BRANCH" >&2;exit 2;fi
printf 'branch=%s\nhead=%s\nbase=%s\n' "$BRANCH" "$HEAD" "$MERGE_BASE"

printf '\n=== 2. CREATE SMALL INCREMENTAL BUNDLE ===\n';BUNDLE="/tmp/greenquic_parallel_mc_${TAG}.bundle";git bundle create "$BUNDLE" "refs/remotes/origin/$BRANCH" "^$BASE_SHA";git bundle verify "$BUNDLE";BUNDLE_REF="$(git bundle list-heads "$BUNDLE" | awk -v h="$HEAD" '$1==h {print $2; exit}')";[[ -n "$BUNDLE_REF" ]] || { echo "ERROR: cannot determine branch ref in incremental bundle" >&2;exit 2; };echo "bundle_ref=$BUNDLE_REF size=$(du -h "$BUNDLE" | awk '{print $1}')"

printf '\n=== 3. STOP STALE TEST PROCESSES AND SYNC BOTH HOSTS ===\n'
for H in idex tinyman;do
 echo "----- $H -----";ssh "$H" 'bash -s' <<'CLEAN'
set +e
pkill -TERM -f '[q]uicinterop(server)?' 2>/dev/null || true
pkill -TERM -f '[r]un_matrix_(from_idex|with_report|with_sheet|parallel)' 2>/dev/null || true
pkill -TERM -f '[g]q_rapl_msr_sampler|[g]q_cstate_trace|[f]requency_sampler.py|[p]7_frequency_sampler.py' 2>/dev/null || true
sleep 3
pkill -KILL -f '[q]uicinterop(server)?' 2>/dev/null || true
pkill -KILL -f '[r]un_matrix_(from_idex|with_report|with_sheet|parallel)' 2>/dev/null || true
pkill -KILL -f '[g]q_rapl_msr_sampler|[g]q_cstate_trace|[f]requency_sampler.py|[p]7_frequency_sampler.py' 2>/dev/null || true
if ! fuser /var/run/dpdk/rte/config >/dev/null 2>&1;then rm -rf /var/run/dpdk/rte 2>/dev/null || true;fi
CLEAN
 scp -q "$BUNDLE" "$H:/tmp/greenquic_parallel_mc_${TAG}.bundle";ssh "$H" bash -s -- "$HEAD" "$BUNDLE_REF" "$TAG" <<'SYNC'
set -Eeuo pipefail
HEAD="$1";BUNDLE_REF="$2";TAG="$3";cd /root/mohsen
if ! git diff --quiet || ! git diff --cached --quiet;then echo "ERROR: tracked modifications exist on $(hostname); refusing branch switch" >&2;git status --short --untracked-files=no >&2;exit 70;fi
git cat-file -e 045d7375c6af5810a9ce30a2db63231989ab3f12^{commit} || { echo "ERROR: prerequisite base commit missing on $(hostname)" >&2;exit 71; }
git fetch "/tmp/greenquic_parallel_mc_${TAG}.bundle" "$BUNDLE_REF:refs/remotes/origin/performance2/p5-multicore";git checkout -B performance2/p5-multicore refs/remotes/origin/performance2/p5-multicore;git reset --hard "$HEAD";[[ "$(git rev-parse HEAD)" == "$HEAD" ]] || { echo "ERROR: HEAD mismatch" >&2;exit 72; };rm -f "/tmp/greenquic_parallel_mc_${TAG}.bundle";echo "$(hostname): synced HEAD=$(git rev-parse HEAD)"
SYNC
done

printf '\n=== 4. ZERO-TRAFFIC INTEGRATION + STATIC PREFLIGHT ON BOTH HOSTS ===\n';for H in idex tinyman;do echo "----- $H -----";ssh "$H" "cd '$REMOTE_ROOT/$PREREL' && bash ./parallel_multicore_integration_contract.sh && bash ./parallel_multicore_static_preflight.sh";done
if [[ "$PREFLIGHT_ONLY" == 1 ]];then printf '\n======================================================================\nPARALLEL MULTICORE PREFLIGHT-ONLY PASS\nBranch commit: %s\nNo P5/P7 build or traffic was started.\n======================================================================\n' "$HEAD";exit 0;fi

printf '\n=== 5. PREPARE DPDK NIC AND BUILD P5 ON BOTH HOSTS ===\n'
for H in idex tinyman;do echo "----- P5 build $H -----";ssh "$H" 'bash -s' <<'P5BUILD'
set -Eeuo pipefail
cd /root/mohsen;DEV=0000:18:00.0;DEVBIND=/root/mohsen/msquic/deps/dpdk/usertools/dpdk-devbind.py;DRIVER="$(basename "$(readlink -f "/sys/bus/pci/devices/$DEV/driver" 2>/dev/null || true)")"
if [[ "$DRIVER" != vfio-pci ]];then modprobe vfio-pci;python3 "$DEVBIND" -b vfio-pci "$DEV";fi
DRIVER="$(basename "$(readlink -f "/sys/bus/pci/devices/$DEV/driver" 2>/dev/null || true)")";[[ "$DRIVER" == vfio-pci ]] || { echo "ERROR: $DEV driver=$DRIVER, expected vfio-pci" >&2;exit 73; };cd greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads;bash ./build_p5_multicore_performance2.sh
P5BUILD
done
printf '\n=== 5B. VERIFY EXACT P5 RUNTIME BINARIES BEFORE STARTING TRAFFIC ===\n';for H in idex tinyman;do echo "----- P5 runtime contract $H -----";ssh "$H" "cd '$P5DIR' && bash ./verify_p5_parallel_multicore_binary.sh client /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop && bash ./verify_p5_parallel_multicore_binary.sh server /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinteropserver";done

printf '\n=== 6. RUN P5: OFF/BASIC/PLUS, %s REPETITIONS, %s PARALLEL CONNECTIONS ===\n' "$RUNS" "$CONNECTIONS";ssh -tt idex "set -o pipefail; cd '$P5DIR' && bash ./run_parallel_multicore_matrix.sh --runs '$RUNS' --connections '$CONNECTIONS' --output-dir '$P5OUT' 2>&1 | tee '$P5LOG'"
printf '\n=== P5 TOTAL GOODPUT + VARIANCE ===\n';ssh idex "cat '$P5OUT/parallel_tables/parallel_goodput_summary.csv'"
printf '\n=== P5 ACTIVE ENERGY + POWER + FREQUENCY ===\n';ssh idex "cat '$P5OUT/parallel_tables/parallel_active_summary.csv'"

printf '\n=== 7. BUILD IDENTICAL PARALLEL WORKLOAD FOR P7 LINUX ON BOTH HOSTS ===\n';for H in idex tinyman;do echo "----- P7 build $H -----";ssh "$H" "cd '$P7DIR' && bash ./build_p7_parallel_multicore.sh";done
printf '\n=== 8. RUN FAIR P7 LINUX: %s REPETITIONS, %s PARALLEL CONNECTIONS ===\n' "$RUNS" "$CONNECTIONS";ssh -tt idex "set -o pipefail; cd '$P7DIR' && bash ./run_parallel_multicore_matrix.sh --runs '$RUNS' --connections '$CONNECTIONS' --output-dir '$P7OUT' 2>&1 | tee '$P7LOG'"
printf '\n=== P7 TOTAL GOODPUT + VARIANCE ===\n';ssh idex "cat '$P7OUT/parallel_tables/parallel_goodput_summary.csv'"
printf '\n=== P7 ACTIVE ENERGY + POWER + FREQUENCY ===\n';ssh idex "cat '$P7OUT/parallel_tables/parallel_active_summary.csv'"

printf '\n=== 9. FAIR P5 VS P7 COMPARISON ===\n';ssh idex "python3 '$REMOTE_ROOT/$PREREL/compare_parallel_p5_p7.py' --p5 '$P5OUT' --p7 '$P7OUT' --out '$COMPARE'"
printf '\n=== 10. COPY SMALL SUMMARY/AUDIT FILES TO MAC ===\n'
scp -q "idex:$P5OUT/parallel_tables/parallel_goodput_all_runs.csv" "$LOCAL_EXPORT/P5_parallel_goodput_all_runs.csv";scp -q "idex:$P5OUT/parallel_tables/parallel_goodput_summary.csv" "$LOCAL_EXPORT/P5_parallel_goodput_summary.csv";scp -q "idex:$P5OUT/parallel_tables/parallel_active_metrics.csv" "$LOCAL_EXPORT/P5_parallel_active_metrics.csv";scp -q "idex:$P5OUT/parallel_tables/parallel_active_summary.csv" "$LOCAL_EXPORT/P5_parallel_active_summary.csv";scp -q "idex:$P5OUT/parallel_queue_activity.json" "$LOCAL_EXPORT/P5_parallel_queue_activity.json";scp -q "idex:$P5OUT/multicore_validation.json" "$LOCAL_EXPORT/P5_multicore_validation.json";scp -q "idex:$P5OUT/PARALLEL_MULTICORE_CONFIG.txt" "$LOCAL_EXPORT/P5_config.txt"
scp -q "idex:$P7OUT/parallel_tables/parallel_goodput_all_runs.csv" "$LOCAL_EXPORT/P7_parallel_goodput_all_runs.csv";scp -q "idex:$P7OUT/parallel_tables/parallel_goodput_summary.csv" "$LOCAL_EXPORT/P7_parallel_goodput_summary.csv";scp -q "idex:$P7OUT/parallel_tables/parallel_active_metrics.csv" "$LOCAL_EXPORT/P7_parallel_active_metrics.csv";scp -q "idex:$P7OUT/parallel_tables/parallel_active_summary.csv" "$LOCAL_EXPORT/P7_parallel_active_summary.csv";scp -q "idex:$P7OUT/parallel_irq_activity_validation.json" "$LOCAL_EXPORT/P7_parallel_irq_activity_validation.json";scp -q "idex:$P7OUT/multicore_validation.json" "$LOCAL_EXPORT/P7_multicore_validation.json";scp -q "idex:$P7OUT/PARALLEL_MULTICORE_CONFIG.txt" "$LOCAL_EXPORT/P7_config.txt"
scp -q "idex:$COMPARE" "$LOCAL_EXPORT/fair_P5_P7_total_goodput_comparison.csv";scp -q "idex:$COMPARE_ACTIVE" "$LOCAL_EXPORT/fair_P5_P7_active_energy_frequency_comparison.csv"
printf 'branch=%s\ncommit=%s\nP5_REMOTE=%s\nP7_REMOTE=%s\nP5_LOG=%s\nP7_LOG=%s\n' "$BRANCH" "$HEAD" "$P5OUT" "$P7OUT" "$P5LOG" "$P7LOG" > "$LOCAL_EXPORT/REMOTE_PATHS.txt"
printf '\n======================================================================\nPARALLEL MULTICORE FAIR TEST PASS\nBranch commit: %s\nSmall results on Mac: %s\nFull P5 matrix: %s:%s\nFull P7 matrix: %s:%s\n======================================================================\n' "$HEAD" "$LOCAL_EXPORT" idex "$P5OUT" idex "$P7OUT"
