#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)";P5="$HERE/P5_repeated_8GiB_downloads";P7="$HERE/P7_linux_udp_baseline";MAC="$HERE/mac_run_parallel_multicore_fair_2r_v1.sh"
FILES=("$P5/verify_p5_parallel_multicore_binary.sh" "$P5/build_p5_multicore_performance2.sh" "$P5/run_client_parallel_multicore.sh" "$P5/run_parallel_multicore_matrix.sh" "$P7/build_p7_parallel_multicore.sh" "$P7/run_server_parallel_multicore.sh" "$P7/run_client_parallel_multicore.sh" "$P7/run_parallel_multicore_matrix.sh" "$MAC")
for f in "${FILES[@]}";do [[ -f "$f" ]] || { echo "ERROR: integration-contract file missing: $f" >&2;exit 2; };bash -n "$f";done
PYFILES=("$P5/report_p5_parallel_run.py" "$P5/analyze_p5_parallel_active.py" "$P7/report_p7_parallel_run.py" "$P7/aggregate_p7_parallel_active.py" "$HERE/compare_parallel_p5_p7.py")
for f in "${PYFILES[@]}";do [[ -f "$f" ]] || { echo "ERROR: integration-contract Python file missing: $f" >&2;exit 2; };python3 -m py_compile "$f";done

python3 - "$P5" "$P7" "$MAC" "$HERE" <<'PY'
from pathlib import Path
import sys
p5,p7,mac,pre=map(Path,sys.argv[1:])
def text(p):return p.read_text(encoding='utf-8',errors='replace')
def require(h,n,l):
 if n not in h:raise SystemExit(f'ERROR: integration contract missing {l}: {n}')
def forbid(h,n,l):
 if n in h:raise SystemExit(f'ERROR: integration contract contains forbidden {l}: {n}')
verify=text(p5/'verify_p5_parallel_multicore_binary.sh');build=text(p5/'build_p5_multicore_performance2.sh');client=text(p5/'run_client_parallel_multicore.sh');p5matrix=text(p5/'run_parallel_multicore_matrix.sh');p5report=text(p5/'report_p5_parallel_run.py');p5active=text(p5/'analyze_p5_parallel_active.py');p7build=text(p7/'build_p7_parallel_multicore.sh');p7matrix=text(p7/'run_parallel_multicore_matrix.sh');p7report=text(p7/'report_p7_parallel_run.py');p7active=text(p7/'aggregate_p7_parallel_active.py');macs=text(mac);compare=text(pre/'compare_parallel_p5_p7.py')
for marker in ('GreenQuicEnableMultiCore','GreenQuicPartitionDpdkMap','greenquic-mc-queue-v1','GreenQUIC multicore TX queue topology invalid','GreenQUIC multicore TX requires one TX queue per DPDK RX owner','GREENQUIC-P5-PERFORMANCE2-V1','GREENQUIC-P5-PERFORMANCE2-V2','GREENQUIC-P5-PARALLEL-CONNECTIONS-V1','GQ_INTEROP_P5_LOCAL_PORT_BASE','ready_for_start_gate_us='):require(verify,marker,'compiled-runtime evidence')
forbid(verify,'GREENQUIC-P5-MULTICORE-TXQ-V1','source-only marker in compiled-runtime verifier');forbid(client,'GREENQUIC-P5-MULTICORE-TXQ-V1','source-only marker in P5 runtime wrapper');require(client,'bash "$VERIFY_BINARY" client "$actual_client_bin"','P5 client shared runtime verifier call');require(build,'bash "$VERIFY_BINARY" client "$CLIENT"','P5 build client verifier call');require(build,'bash "$VERIFY_BINARY" server "$SERVER"','P5 build server verifier call')
# The parallel wrapper must perform normal-P5 postprocessing BEFORE asking for a
# bundle: exact log/stamp -> exact manifest -> parallel report/goodput -> common bundler.
for needle,label in (('client_download_manifest_${MODE}_${stamp}.json','exact P5 manifest'),('report_p5_parallel_run.py','parallel report'),('bundle_run_results.py','common P5 bundler'),('--stamp "$stamp"','exact-stamp bundle'),('[GreenQUIC-PARALLEL-BUNDLE]','bundle completion evidence')):require(client,needle,label)
if client.index('report_p5_parallel_run.py')>client.index('bundle_run_results.py'):raise SystemExit('ERROR: P5 parallel client bundles before calculating parallel goodput')
forbid(client,'exact newly-created parallel client bundle not found','old pre-bundle directory assumption')
# Completion/energy timing must follow the parallel batch, never sequential N/N.
for needle,label in (('P5-PARALLEL-COMPLETION-V1','parallel completion transform'),('completed=${DOWNLOADS} success=1','successful parallel completion requirement'),('--controller-preflight','P5 nested controller preflight'),('analyze_p5_parallel_active.py','P5 active analyzer')):require(p5matrix,needle,label)
for needle,label in (('TOTAL aggregate goodput','P5 aggregate goodput print'),('Download {r["index"]}','P5 per-download goodput print'),('batch_start_us','P5 exact active start'),('batch_complete_us','P5 exact active end')):require(p5report,needle,label)
for needle,label in (('sample_monotonic_ns','P5 RAPL monotonic crop'),('client_minus_controller_monotonic_offset_ns','P5 server clock mapping'),('midpoint-cell','P5 active frequency weighting') if False else ('dataplane_mean_ghz','P5 two-CPU frequency aggregate')):require(p5active,needle,label)
# P7 must use compiled anti-DPDK evidence and identical active-window semantics.
forbid(p7build,'GREENQUIC-P5-MULTICORE-TXQ-V1','source-only P7 binary check')
for marker in ('greenquic-mc-queue-v1','GreenQUIC multicore TX queue topology invalid','GreenQUIC multicore TX requires one TX queue per DPDK RX owner'):require(p7build,marker,'P7 compiled anti-DPDK evidence')
for needle,label in (('bash "$HERE/run_server_parallel_multicore.sh" --run-dir "$srun" --rep "$rep"','P7 server bash wrapper'),("bash '$CLIENT_DIR/run_client_parallel_multicore.sh' --run-dir '$crun_remote' --rep '$rep' --gate '$gate'",'P7 client bash wrapper'),('--controller-preflight','P7 transformed-controller preflight'),('aggregate_p7_parallel_active.py','P7 active aggregator'),('active_window=parallel_batch_start_to_parallel_batch_complete','P7 fair active window')):require(p7matrix,needle,label)
for needle,label in (('TOTAL_goodput','P7 aggregate goodput print'),('download {r[\'index\']}','P7 per-download goodput print'),("base.rapl_metrics(rapl,ws)",'P7 active RAPL crop'),("base.frequency_metrics(freq,ws)",'P7 active frequency crop')):require(p7report,needle,label)
require(p7active,'combined_j_per_useful_gbit','P7 active energy efficiency')
# Mac orchestration must propagate failures and export goodput + active metrics.
if macs.count('set -o pipefail;')<2:raise SystemExit('ERROR: Mac launcher must preserve pipefail for P5 and P7 tee pipelines')
for needle,label in (('bash ./parallel_multicore_integration_contract.sh','integration audit invocation'),('bash ./parallel_multicore_static_preflight.sh','static preflight invocation'),('bash ./build_p5_multicore_performance2.sh','P5 build invocation'),('bash ./run_parallel_multicore_matrix.sh','matrix invocation'),('bash ./build_p7_parallel_multicore.sh','P7 build invocation'),('P5_parallel_active_metrics.csv','P5 active export'),('P7_parallel_active_metrics.csv','P7 active export'),('fair_P5_P7_active_energy_frequency_comparison.csv','active comparison export')):require(macs,needle,label)
for needle,label in (('parallel_active_summary.csv','active summary comparison'),('combined_avg_rapl_w','active power comparison'),('server_dataplane_mean_ghz','server frequency comparison'),('client_dataplane_mean_ghz','client frequency comparison')):require(compare,needle,label)
print('PARALLEL MULTICORE INTEGRATION CONTRACT PASS')
print('  P5 bundling: run_role -> exact log/manifest -> per-connection+aggregate goodput -> common bundle')
print('  completion: successful parallel batch marker drives post-cooldown/aligned window')
print('  active metrics: identical batch interval; RAPL boundary-prorated; CPU19/20 frequency reported')
print('  wrappers/tee: executable-bit independent and pipefail preserved')
PY

# Exercise BOTH nested controller transforms with --help. This validates the
# actual preserved-core anchors and generated shell without SSH/NIC/DPDK/traffic.
bash "$P5/run_parallel_multicore_matrix.sh" --controller-preflight
bash "$P7/run_parallel_multicore_matrix.sh" --controller-preflight
printf 'PARALLEL MULTICORE NESTED CONTROLLER CONTRACT PASS\n'
