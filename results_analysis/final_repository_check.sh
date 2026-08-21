#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"
cd "$ROOT"

P5="greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
P7="greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline"

fail(){ echo "FINAL REPOSITORY CHECK: FAIL: $*" >&2; exit 1; }

# 1) Machine-readable paper configuration must agree with the supported setup,
# launcher, role defaults, TOP3 policy, P7 network profile, and compatibility wrappers.
python3 results_analysis/verify_paper_configuration.py

# 2) Syntax-check every current top-level shell entrypoint/helper in the supported
# reproduction areas, not only the three convenience wrappers.
while IFS= read -r -d '' f; do
  bash -n "$f" || fail "bash syntax error in $f"
done < <(find results_analysis tum_testbed_setup "$P5" "$P7" \
  -maxdepth 1 -type f -name '*.sh' -print0)

# Critical Python helpers must at least parse/compile locally.
python3 -m py_compile \
  results_analysis/verify_paper_configuration.py \
  results_analysis/import_attached_artifacts.py \
  "$P5/apply_p5_performance2.py" \
  "$P5/apply_p5_performance2_v2.py" \
  "$P7/build_p7_report.py"

# Machine-readable records/manifests must be valid JSON.
for f in \
  results_analysis/configuration/experiment_paths.json \
  results_analysis/configuration/p5_paper_evaluation.json \
  results_analysis/configuration/p7_paper_evaluation.json \
  results_analysis/tuning/summary.json \
  results_analysis/charts/manifest.json \
  results_analysis/artifact_files.sha256.json; do
  python3 -m json.tool "$f" >/dev/null || fail "invalid JSON: $f"
done

# 3) Repository cleanup/layout invariants.
[[ ! -e greenquic_test_suite ]] || fail "legacy greenquic_test_suite/ still exists"
[[ ! -e power_mng_tunning ]] || fail "obsolete power_mng_tunning/ still exists"
[[ -d greenquic_test_suite_v22 ]] || fail "greenquic_test_suite_v22/ missing"

mapfile -t tum_files < <(find tum_testbed_setup -maxdepth 1 -type f -printf '%f\n' | sort)
[[ "${#tum_files[@]}" -eq 2 ]] || fail "tum_testbed_setup/ should contain only README.md and greenquic_fresh_setup.sh"
[[ "${tum_files[0]}" == README.md && "${tum_files[1]}" == greenquic_fresh_setup.sh ]] || fail "unexpected TUM setup files: ${tum_files[*]}"

# 4) Original analysis artifacts must really be committed, not merely documented.
[[ -f results_analysis/tuning/GreenQUIC_DPDK_Path_Perf_Tunning_v2.xlsx ]] || fail "DPDK tuning workbook missing"
[[ -f results_analysis/tuning/GreenQUIC_Power_Mng_Tuning_v1.xlsx ]] || fail "power tuning workbook missing"
[[ -f results_analysis/charts/chart_v2.py ]] || fail "chart_v2.py missing"
svg_count="$(find results_analysis/charts/svg -type f -name '*.svg' | wc -l | tr -d ' ')"
[[ "$svg_count" == 41 ]] || fail "expected 41 supplied SVG files, found $svg_count"

if find results_analysis -maxdepth 1 -type f \( -name '*.tmp' -o -name '.*tmp*' \) | grep -q .; then
  find results_analysis -maxdepth 1 -type f \( -name '*.tmp' -o -name '.*tmp*' \) -print >&2
  fail "temporary audit files remain"
fi

# 5) Paper-testbed defaults are centralized, but supported runtime role checks
# must remain portable to different physical host names.
grep -Fq 'GQ_SERVER_HOST="${GQ_SERVER_HOST:-idex}"' results_analysis/paper_testbed_defaults.sh || fail "SERVER default missing"
grep -Fq 'GQ_CLIENT_HOST="${GQ_CLIENT_HOST:-tinyman}"' results_analysis/paper_testbed_defaults.sh || fail "CLIENT default missing"
grep -Fq 'GQ_SERVER_TO_CLIENT_HOST="${GQ_SERVER_TO_CLIENT_HOST:-$GQ_CLIENT_HOST}"' results_analysis/paper_testbed_defaults.sh || fail "SERVER->CLIENT default missing"
grep -Fq 'GQ_BASTION="${GQ_BASTION:-mohsen@coinbase}"' results_analysis/paper_testbed_defaults.sh || fail "BASTION default missing"
grep -Fq 'GQ_SSH_KEY="${GQ_SSH_KEY:-$HOME/.ssh/id_ed25519}"' results_analysis/paper_testbed_defaults.sh || fail "SSH-key default missing"

grep -Fq 'SERVER_NAME="${SERVER_NAME:-$GQ_LOCAL_SHORT_HOST}"' greenquic_test_suite_v22/suite.env || fail "portable SERVER runtime hostname guard missing"
grep -Fq 'CLIENT_NAME="${CLIENT_NAME:-$GQ_LOCAL_SHORT_HOST}"' greenquic_test_suite_v22/suite.env || fail "portable CLIENT runtime hostname guard missing"
! grep -Fq 'SERVER_NAME="${SERVER_NAME:-idex}"' greenquic_test_suite_v22/suite.env || fail "idex was reintroduced as runtime SERVER hostname requirement"
! grep -Fq 'CLIENT_NAME="${CLIENT_NAME:-tinyman}"' greenquic_test_suite_v22/suite.env || fail "tinyman was reintroduced as runtime CLIENT hostname requirement"

# 6) High-level paper commands must safely synchronize a clean, behind-only
# CONTROL-HOST main checkout before setup/run/rebuild. They must never blindly
# reset local work or unique commits.
for f in results_analysis/setup_paper_testbed.sh results_analysis/run_paper_evaluation.sh results_analysis/rebuild_paper_binaries.sh; do
  grep -Fq 'control_main_sync.sh' "$f" || fail "$f does not use safe CONTROL main synchronization"
done
grep -Fq "git fetch origin '+refs/heads/main:refs/remotes/origin/main'" results_analysis/control_main_sync.sh || fail "control sync explicit main refspec missing"
grep -Fq 'git merge-base --is-ancestor' results_analysis/control_main_sync.sh || fail "control sync ahead/divergence protection missing"
grep -Fq 'git status --porcelain=v1 --untracked-files=all' results_analysis/control_main_sync.sh || fail "control sync dirty-tree protection missing"

# 7) Supported setup and final launcher must remain role/switch based.
for token in '--server-host' '--client-host' '--bastion' '--ssh-key'; do
  grep -Fq -- "$token" tum_testbed_setup/greenquic_fresh_setup.sh || fail "TUM setup missing $token"
  grep -Fq -- "$token" "$P5/mac_run_p5_p7_fair_repro_6x5.sh" || fail "paper launcher missing $token"
done
grep -Fq -- '--server-to-client-host' tum_testbed_setup/greenquic_fresh_setup.sh || fail "TUM setup missing separate SERVER->CLIENT endpoint switch"
grep -Fq 'SERVER -> CLIENT: required' tum_testbed_setup/greenquic_fresh_setup.sh || fail "TUM setup missing SERVER->CLIENT SSH requirement"

# Operational high-level scripts must not fall back to the old paper branch.
if grep -nF 'performance2/p5-multicore' \
  results_analysis/*.sh tum_testbed_setup/greenquic_fresh_setup.sh "$P5/mac_run_p5_p7_fair_repro_6x5.sh"; then
  fail "old paper branch name appears in a supported operational script"
fi

# 8) README command-location/monitor pairing for long-running operations.
for f in README.md results_analysis/README.md tum_testbed_setup/README.md; do
  grep -Fq 'RUN ON:' "$f" || fail "$f does not label command location"
done

grep -Fq 'bash results_analysis/setup_paper_testbed.sh' README.md || fail "root README missing zero-argument setup command"
grep -Fq 'bash results_analysis/live_monitor_setup.sh' README.md || fail "root README missing setup monitor"
grep -Fq 'bash results_analysis/rebuild_paper_binaries.sh' README.md || fail "root README missing rebuild command"
grep -Fq 'bash results_analysis/run_paper_evaluation.sh' README.md || fail "root README missing zero-argument final-run command"
grep -Fq 'bash results_analysis/live_monitor_run.sh' README.md || fail "root README missing final-run monitor"

grep -Fq 'bash results_analysis/setup_paper_testbed.sh' results_analysis/README.md || fail "analysis README missing setup command"
grep -Fq 'bash results_analysis/live_monitor_setup.sh' results_analysis/README.md || fail "analysis README missing setup/build monitor"
grep -Fq 'bash results_analysis/run_paper_evaluation.sh' results_analysis/README.md || fail "analysis README missing final-run command"
grep -Fq 'bash results_analysis/live_monitor_run.sh' results_analysis/README.md || fail "analysis README missing final-run monitor"

grep -Fq 'bash results_analysis/setup_paper_testbed.sh' tum_testbed_setup/README.md || fail "TUM README missing supported setup command"
grep -Fq 'bash results_analysis/live_monitor_setup.sh' tum_testbed_setup/README.md || fail "TUM README missing setup monitor"
grep -Fq 'bash results_analysis/run_paper_evaluation.sh' tum_testbed_setup/README.md || fail "TUM README missing final-run command"
grep -Fq 'bash results_analysis/live_monitor_run.sh' tum_testbed_setup/README.md || fail "TUM README missing final-run monitor"

# 9) Exact paper build/run anchors.
MARKER='GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0'
grep -Fq "$MARKER" "$P5/mac_run_p5_p7_fair_repro_6x5.sh" || fail "final P5 marker missing from authoritative launcher"
for token in '--env PRESSURE_UP=450' '--env RX_QUEUE_HIGH=48' '--env ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16' '--env FREQ_PERIOD_US=10000'; do
  grep -Fq -- "$token" "$P5/mac_run_p5_p7_fair_repro_6x5.sh" || fail "paper P5 launcher missing $token"
done
for token in '--nic-offloads paper' '--udp-rmem 6815744' '--udp-wmem 6815744' '--combined-channels 1' '--dataplane-cpu 19' '--quic-cpus 21,22,23,24'; do
  grep -Fq -- "$token" "$P5/mac_run_p5_p7_fair_repro_6x5.sh" || fail "paper P7 launcher missing $token"
done

echo "FINAL REPOSITORY CHECK: PASS"
echo "Repository layout: PASS"
echo "TUM setup: one implementation"
echo "Host roles/SSH switches: PASS"
echo "CONTROL main synchronization safety: PASS"
echo "Paper defaults: idex/tinyman via mohsen@coinbase with \$HOME/.ssh/id_ed25519"
echo "Artifacts: 2 XLSX + chart_v2.py + 41 SVG"
echo "P5/P7 configuration, launcher and guide consistency: PASS"
