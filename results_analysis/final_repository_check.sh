#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"
cd "$ROOT"

fail(){ echo "FINAL REPOSITORY CHECK: FAIL: $*" >&2; exit 1; }

python3 results_analysis/verify_paper_configuration.py

for f in \
  tum_testbed_setup/greenquic_fresh_setup.sh \
  results_analysis/paper_testbed_defaults.sh \
  results_analysis/setup_paper_testbed.sh \
  results_analysis/rebuild_paper_binaries.sh \
  results_analysis/run_paper_evaluation.sh \
  results_analysis/live_monitor_setup.sh \
  results_analysis/live_monitor_run.sh \
  results_analysis/download_paper_results.sh \
  results_analysis/download_latest_reproduction.sh \
  greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_p7_fair_repro_6x5.sh \
  greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/build_p5_performance2.sh \
  greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline/build_p7_linux.sh; do
  [[ -f "$f" ]] || fail "missing $f"
  bash -n "$f" || fail "bash syntax error in $f"
done

[[ ! -e greenquic_test_suite ]] || fail "legacy greenquic_test_suite/ still exists"
[[ ! -e power_mng_tunning ]] || fail "obsolete power_mng_tunning/ still exists"
[[ -d greenquic_test_suite_v22 ]] || fail "greenquic_test_suite_v22/ missing"

mapfile -t tum_files < <(find tum_testbed_setup -maxdepth 1 -type f -printf '%f\n' | sort)
[[ "${#tum_files[@]}" -eq 2 ]] || fail "tum_testbed_setup/ should contain only README.md and greenquic_fresh_setup.sh"
[[ "${tum_files[0]}" == README.md && "${tum_files[1]}" == greenquic_fresh_setup.sh ]] || fail "unexpected TUM setup files: ${tum_files[*]}"

[[ -f results_analysis/tuning/GreenQUIC_DPDK_Path_Perf_Tunning_v2.xlsx ]] || fail "DPDK tuning workbook missing"
[[ -f results_analysis/tuning/GreenQUIC_Power_Mng_Tuning_v1.xlsx ]] || fail "power tuning workbook missing"
[[ -f results_analysis/charts/chart_v2.py ]] || fail "chart_v2.py missing"
svg_count="$(find results_analysis/charts/svg -type f -name '*.svg' | wc -l | tr -d ' ')"
[[ "$svg_count" == 41 ]] || fail "expected 41 supplied SVG files, found $svg_count"

if find results_analysis -maxdepth 1 -type f \( -name '*.tmp' -o -name '.*tmp*' \) | grep -q .; then
  find results_analysis -maxdepth 1 -type f \( -name '*.tmp' -o -name '.*tmp*' \) -print >&2
  fail "temporary audit files remain"
fi

grep -Fq 'GQ_SERVER_HOST="${GQ_SERVER_HOST:-idex}"' results_analysis/paper_testbed_defaults.sh || fail "SERVER default missing"
grep -Fq 'GQ_CLIENT_HOST="${GQ_CLIENT_HOST:-tinyman}"' results_analysis/paper_testbed_defaults.sh || fail "CLIENT default missing"
grep -Fq 'GQ_BASTION="${GQ_BASTION:-mohsen@coinbase}"' results_analysis/paper_testbed_defaults.sh || fail "BASTION default missing"
grep -Fq 'GQ_SSH_KEY="${GQ_SSH_KEY:-$HOME/.ssh/id_ed25519}"' results_analysis/paper_testbed_defaults.sh || fail "SSH-key default missing"

grep -Fq 'bash results_analysis/setup_paper_testbed.sh' README.md || fail "root README missing zero-argument setup command"
grep -Fq 'bash results_analysis/live_monitor_setup.sh' README.md || fail "root README missing setup monitor"
grep -Fq 'bash results_analysis/run_paper_evaluation.sh' README.md || fail "root README missing zero-argument final-run command"
grep -Fq 'bash results_analysis/live_monitor_run.sh' README.md || fail "root README missing final-run monitor"

echo "FINAL REPOSITORY CHECK: PASS"
echo "TUM setup: one implementation"
echo "Paper defaults: idex/tinyman via mohsen@coinbase with \$HOME/.ssh/id_ed25519"
echo "Artifacts: 2 XLSX + chart_v2.py + 41 SVG"
echo "P5/P7 configuration and launcher consistency: PASS"
