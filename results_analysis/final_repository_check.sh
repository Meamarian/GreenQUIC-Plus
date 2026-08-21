#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$HERE/.." && pwd)"
cd "$ROOT"

P5="greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
P7="greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline"

fail(){ echo "FINAL REPOSITORY CHECK: FAIL: $*" >&2; exit 1; }

# 1) Machine-readable paper configuration must agree with the supported setup,
# launcher, role defaults, TOP3 policy, P7 network profile, durable recorder
# validation, automatic result download, and compatibility wrappers.
python3 results_analysis/verify_paper_configuration.py

# 2) Syntax-check every current top-level shell entrypoint/helper in the supported
# reproduction areas. Use portable shell globs so this works on macOS and Linux.
for dir in results_analysis tum_testbed_setup "$P5" "$P7"; do
  for f in "$dir"/*.sh; do
    [[ -e "$f" ]] || continue
    bash -n "$f" || fail "bash syntax error in $f"
  done
done

python3 -m py_compile \
  results_analysis/verify_paper_configuration.py \
  results_analysis/import_attached_artifacts.py \
  "$P5/validate_p5_recorder_evidence.py" \
  "$P5/apply_p5_performance2.py" \
  "$P5/apply_p5_performance2_v2.py" \
  "$P7/build_p7_report.py"

# Regression self-test for the exact bug seen on 2026-08-21: a fully complete P5
# matrix must validate from durable per-run log evidence even when zero
# *_affinity.txt sidecars survive bundling.
python3 "$P5/validate_p5_recorder_evidence.py" --self-test >/dev/null || fail "P5 recorder evidence self-test failed"

for f in \
  results_analysis/configuration/dependencies.json \
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
[[ ! -e results_analysis/.final-audit-lock ]] || fail "temporary final-audit marker remains"

tum_listing="$(for f in tum_testbed_setup/*; do [[ -f "$f" ]] && basename "$f"; done | sort)"
expected_tum_listing="$(printf '%s\n' README.md greenquic_fresh_setup.sh | sort)"
[[ "$tum_listing" == "$expected_tum_listing" ]] || fail "tum_testbed_setup/ should contain only README.md and greenquic_fresh_setup.sh; found: $(printf '%s' "$tum_listing" | tr '\n' ' ')"

# 4) Original analysis artifacts must really be committed.
[[ -f results_analysis/tuning/GreenQUIC_DPDK_Path_Perf_Tunning_v2.xlsx ]] || fail "DPDK tuning workbook missing"
[[ -f results_analysis/tuning/GreenQUIC_Power_Mng_Tuning_v1.xlsx ]] || fail "power tuning workbook missing"
[[ -f results_analysis/charts/chart_v2.py ]] || fail "chart_v2.py missing"
svg_count="$(find results_analysis/charts/svg -type f -name '*.svg' | wc -l | tr -d ' ')"
[[ "$svg_count" == 41 ]] || fail "expected 41 supplied SVG files, found $svg_count"

for f in results_analysis/*.tmp results_analysis/.*tmp*; do
  [[ -e "$f" ]] || continue
  echo "$f" >&2
  fail "temporary audit files remain"
done

# 5) Dependency/source-version invariants.
[[ -f results_analysis/configuration/dependencies.json ]] || fail "dependencies.json missing"
[[ -f results_analysis/print_dependency_versions.sh ]] || fail "dependency-version reporter missing"
[[ "$(tr -d '[:space:]' < msquic/deps/dpdk/VERSION)" == "21.11.9" ]] || fail "vendored DPDK is not 21.11.9"
grep -Eq 'set\(QUIC_FULL_VERSION[[:space:]]+2\.4\.8\)' msquic/CMakeLists.txt || fail "MsQuic source version 2.4.8 anchor missing"
grep -Fq 'cmake_minimum_required(VERSION 3.20)' msquic/CMakeLists.txt || fail "CMake >=3.20 static-build requirement anchor missing"
grep -Fq '"version": "2.4.8"' results_analysis/configuration/dependencies.json || fail "dependencies.json MsQuic version mismatch"
grep -Fq '"version": "21.11.9"' results_analysis/configuration/dependencies.json || fail "dependencies.json DPDK version mismatch"
grep -Fq '"required_codename": "trixie"' results_analysis/configuration/dependencies.json || fail "dependencies.json Debian Trixie requirement missing"

# 6) Paper routing defaults are centralized, while runtime role checks stay portable.
grep -Fq 'GQ_SERVER_HOST="${GQ_SERVER_HOST:-idex}"' results_analysis/paper_testbed_defaults.sh || fail "SERVER paper default missing"
grep -Fq 'GQ_CLIENT_HOST="${GQ_CLIENT_HOST:-tinyman}"' results_analysis/paper_testbed_defaults.sh || fail "CLIENT paper default missing"
grep -Fq 'GQ_SERVER_TO_CLIENT_HOST="${GQ_SERVER_TO_CLIENT_HOST:-$GQ_CLIENT_HOST}"' results_analysis/paper_testbed_defaults.sh || fail "SERVER->CLIENT paper default missing"
grep -Fq 'GQ_BASTION="${GQ_BASTION:-mohsen@coinbase}"' results_analysis/paper_testbed_defaults.sh || fail "BASTION paper default missing"
grep -Fq 'GQ_SSH_KEY="${GQ_SSH_KEY:-$HOME/.ssh/id_ed25519}"' results_analysis/paper_testbed_defaults.sh || fail "SSH-key paper default missing"

grep -Fq 'SERVER_NAME="${SERVER_NAME:-$GQ_LOCAL_SHORT_HOST}"' greenquic_test_suite_v22/suite.env || fail "portable SERVER runtime hostname guard missing"
grep -Fq 'CLIENT_NAME="${CLIENT_NAME:-$GQ_LOCAL_SHORT_HOST}"' greenquic_test_suite_v22/suite.env || fail "portable CLIENT runtime hostname guard missing"
! grep -Fq 'SERVER_NAME="${SERVER_NAME:-idex}"' greenquic_test_suite_v22/suite.env || fail "idex was reintroduced as runtime SERVER hostname requirement"
! grep -Fq 'CLIENT_NAME="${CLIENT_NAME:-tinyman}"' greenquic_test_suite_v22/suite.env || fail "tinyman was reintroduced as runtime CLIENT hostname requirement"

# 7) CONTROL main synchronization must be safe: clean, main-only and fast-forward-only.
for f in results_analysis/setup_paper_testbed.sh results_analysis/run_paper_evaluation.sh results_analysis/rebuild_paper_binaries.sh; do
  grep -Fq 'control_main_sync.sh' "$f" || fail "$f does not use safe CONTROL main synchronization"
done
grep -Fq "git fetch origin '+refs/heads/main:refs/remotes/origin/main'" results_analysis/control_main_sync.sh || fail "control sync explicit main refspec missing"
grep -Fq 'git merge-base --is-ancestor' results_analysis/control_main_sync.sh || fail "control sync ahead/divergence protection missing"
grep -Fq 'git status --porcelain=v1 --untracked-files=all' results_analysis/control_main_sync.sh || fail "control sync dirty-tree protection missing"

# 8) High-level wrappers and monitors must expose role-oriented management switches.
for token in '--server-host' '--client-host' '--server-to-client-host' '--bastion' '--ssh-key'; do
  grep -Fq -- "$token" results_analysis/setup_paper_testbed.sh || fail "setup wrapper missing $token"
done
for token in '--server-host' '--client-host' '--bastion' '--ssh-key'; do
  grep -Fq -- "$token" results_analysis/run_paper_evaluation.sh || fail "paper-run wrapper missing $token"
  grep -Fq -- "$token" results_analysis/rebuild_paper_binaries.sh || fail "rebuild wrapper missing $token"
done
for token in '--download-dest' '--no-auto-download'; do
  grep -Fq -- "$token" results_analysis/run_paper_evaluation.sh || fail "paper-run wrapper missing $token"
done
for token in '--server-host' '--client-host' '--bastion' '--ssh-key'; do
  grep -Fq -- "$token" results_analysis/live_monitor_setup.sh || fail "setup monitor missing $token"
done
for token in '--server-host' '--bastion' '--ssh-key'; do
  grep -Fq -- "$token" results_analysis/live_monitor_run.sh || fail "run monitor missing $token"
done
for token in '--server-host' '--client-host' '--bastion' '--ssh-key'; do
  grep -Fq -- "$token" results_analysis/print_dependency_versions.sh || fail "dependency reporter missing $token"
done

# 9) Supported setup/final launcher must remain role/switch based; no literal SSH to paper names.
for token in '--server-host' '--client-host' '--bastion' '--ssh-key'; do
  grep -Fq -- "$token" tum_testbed_setup/greenquic_fresh_setup.sh || fail "TUM setup missing $token"
  grep -Fq -- "$token" "$P5/mac_run_p5_p7_fair_repro_6x5.sh" || fail "paper launcher missing $token"
done
grep -Fq -- '--server-to-client-host' tum_testbed_setup/greenquic_fresh_setup.sh || fail "TUM setup missing separate SERVER->CLIENT endpoint switch"
grep -Fq 'SERVER -> CLIENT: required' tum_testbed_setup/greenquic_fresh_setup.sh || fail "TUM setup missing SERVER->CLIENT SSH requirement"

for f in \
  results_analysis/setup_paper_testbed.sh \
  results_analysis/run_paper_evaluation.sh \
  results_analysis/rebuild_paper_binaries.sh \
  results_analysis/live_monitor_setup.sh \
  results_analysis/live_monitor_run.sh \
  tum_testbed_setup/greenquic_fresh_setup.sh \
  "$P5/mac_run_p5_p7_fair_repro_6x5.sh"; do
  ! grep -Eq 'root@(idex|tinyman)([^A-Za-z0-9_.-]|$)' "$f" || fail "$f contains a literal SSH target for a paper host name"
done

# Operational high-level scripts must not fall back to the old paper branch.
if grep -nF 'performance2/p5-multicore' \
  results_analysis/*.sh tum_testbed_setup/greenquic_fresh_setup.sh "$P5/mac_run_p5_p7_fair_repro_6x5.sh"; then
  fail "old paper branch name appears in a supported operational script"
fi

# 10) Current READMEs must label command location, include dependency guidance,
# use the paper-default CONTROL checkout, pair long-running work with monitors,
# and document automatic result transfer.
for f in README.md results_analysis/README.md tum_testbed_setup/README.md "$P5/README.md" "$P7/README.md"; do
  grep -Fq 'RUN ON:' "$f" || fail "$f does not label command location"
done
for f in README.md results_analysis/README.md tum_testbed_setup/README.md; do
  grep -Fq 'Dependencies' "$f" || fail "$f missing Dependencies section"
  grep -Fq 'git clone git@github.com:Meamarian/GreenQUIC-Plus.git' "$f" || fail "$f missing clone-if-needed CONTROL bootstrap"
  grep -Fq '$HOME/Downloads/GreenQUIC-Plus' "$f" || fail "$f missing paper-default Mac checkout path"
  grep -Fq 'bash results_analysis/setup_paper_testbed.sh' "$f" || fail "$f missing supported setup command"
  grep -Fq 'bash results_analysis/live_monitor_setup.sh' "$f" || fail "$f missing setup monitor"
  grep -Fq 'bash results_analysis/run_paper_evaluation.sh' "$f" || fail "$f missing final-run command"
  grep -Fq 'bash results_analysis/live_monitor_run.sh' "$f" || fail "$f missing final-run monitor"
done
for f in README.md results_analysis/README.md; do
  grep -Fiq 'automatic scp' "$f" || fail "$f missing automatic SCP behavior"
  grep -Fiq 'before scp' "$f" || fail "$f missing final-path-before-SCP behavior"
done
for f in "$P5/README.md" "$P7/README.md"; do
  grep -Fq 'bash results_analysis/run_paper_evaluation.sh' "$f" || fail "$f missing high-level final-run command"
  grep -Fq 'bash results_analysis/live_monitor_run.sh' "$f" || fail "$f missing final-run monitor"
  grep -Fq 'bash results_analysis/rebuild_paper_binaries.sh' "$f" || fail "$f missing rebuild command"
  grep -Fq 'bash results_analysis/live_monitor_setup.sh' "$f" || fail "$f missing rebuild monitor"
done

# 11) Exact paper build/run anchors and post-run robustness.
MARKER='GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0'
grep -Fq "$MARKER" "$P5/mac_run_p5_p7_fair_repro_6x5.sh" || fail "final P5 marker missing from authoritative launcher"
for token in '--env PRESSURE_UP=450' '--env RX_QUEUE_HIGH=48' '--env ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16' '--env FREQ_PERIOD_US=10000'; do
  grep -Fq -- "$token" "$P5/mac_run_p5_p7_fair_repro_6x5.sh" || fail "paper P5 launcher missing $token"
done
for token in '--nic-offloads paper' '--udp-rmem 6815744' '--udp-wmem 6815744' '--combined-channels 1' '--dataplane-cpu 19' '--quic-cpus 21,22,23,24'; do
  grep -Fq -- "$token" "$P5/mac_run_p5_p7_fair_repro_6x5.sh" || fail "paper P7 launcher missing $token"
done
for token in 'validate_p5_recorder_evidence.py' 'P5_recorder_validation=durable_per_run_log_evidence' 'RESULT_DIRS.env' 'RESULT_ZIPS.sha256' 'download_latest_reproduction.sh'; do
  grep -Fq -- "$token" "$P5/mac_run_p5_p7_fair_repro_6x5.sh" || fail "final launcher missing post-run robustness token: $token"
done
! grep -Fq 'p5_affinity_files.txt' "$P5/mac_run_p5_p7_fair_repro_6x5.sh" || fail "obsolete P5 affinity sidecar requirement returned"
for token in 'FINAL RESULT PATHS — BEFORE SCP' 'STARTING AUTOMATIC SCP...' 'RESULT_ZIPS.sha256' '--expect-runs' '--expect-downloads'; do
  grep -Fq -- "$token" results_analysis/download_latest_reproduction.sh || fail "result downloader missing: $token"
done

echo "FINAL REPOSITORY CHECK: PASS"
echo "Repository layout: PASS"
echo "TUM setup: one implementation"
echo "Host roles/SSH switches: PASS"
echo "High-level wrappers/monitors: parameterized"
echo "CONTROL main synchronization safety: PASS"
echo "Dependencies: MsQuic 2.4.8 source, DPDK 21.11.9, Debian Trixie policy recorded"
echo "Paper defaults: Mac CONTROL checkout under \$HOME/Downloads, idex/tinyman via mohsen@coinbase"
echo "Artifacts: 2 XLSX + chart_v2.py + 41 SVG"
echo "P5 recorder validation: durable per-run logs; zero affinity sidecars is allowed"
echo "Result handling: paths printed before automatic SCP; ZIP SHA-256 verified"
echo "P5/P7 configuration, launcher and guide consistency: PASS"
