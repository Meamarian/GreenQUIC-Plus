#!/usr/bin/env bash
set -Eeuo pipefail

# Mac-side P7-only runner for the Linux configuration described by the NOMS 2026
# paper + its public tumi8/quic-bypass-paper artifact. This intentionally does
# NOT enable GreenQUIC-specific P7 performance tuning (IRQ/QUIC pinning, RPS
# changes, combined-channel forcing, RDMA unbind, irqbalance manipulation,
# D1/D2+ instrumentation, or RAPL/frequency/C-state recording).
#
# Deliberate workload-count deviation requested by the experimenter:
#   6 repetitions x 6 sequential 8-GiB downloads.
# The MsQuic source/version is whatever the synchronized GreenQUIC branch uses.

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
BASE="$HERE/../P5_repeated_8GiB_downloads/mac_run_p2_final_6x6_p7_v1.sh"
[[ -f "$BASE" ]] || { echo "ERROR: missing base Mac orchestrator: $BASE" >&2; exit 2; }

export P5_FINAL_RUNS="${P7_PAPER_RUNS:-6}"
export P5_FINAL_DOWNLOADS="${P7_PAPER_DOWNLOADS:-6}"
export P5_FINAL_SEED="${P7_PAPER_SEED:-20260806}"

TAG="$(date +%Y%m%d_%H%M%S)_$$"
PATCHED="${TMPDIR:-/tmp}/mac_run_p7_paper_text_github_6x6_${TAG}.sh"

python3 - "$BASE" "$PATCHED" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text(encoding='utf-8')

# Give this P7-only run its own lock/log/export namespace while preserving the
# proven bundle/sync/detach/SCP/SHA256 machinery of the base orchestrator.
src = src.replace('P5_P2_FINAL', 'P7_PAPER_TEXT_GITHUB')
src = src.replace('P2 FINAL', 'P7 PAPER TEXT+GITHUB')
src = src.replace('final P2/P7 runner', 'P7 paper-config runner')
src = src.replace('final validation runner', 'P7 paper-config runner')
src = src.replace('final 6x6 P5/P7 suite', 'P7 paper-config 6x6 suite')

# P7 result name.
src = src.replace(
    'P7OUT="$P7/matrix_results/P7_FINAL_linux_native_${RUNS}r_${DOWNLOADS}d_${TAG}"',
    'P7OUT="$P7/matrix_results/P7_PAPER_TEXT_GITHUB_${RUNS}r_${DOWNLOADS}d_${TAG}"',
    1,
)

# Skip every P5 build. P5 is unrelated to this requested Linux paper-config run.
start = src.index('# Build the promoted Performance2 default on both endpoints.')
end = src.index('# Build the isolated normal-Linux P7 binaries on both endpoints before measurement.', start)
src = src[:start] + '''# P5 deliberately skipped: this is a P7-only paper-config run.\nBP51=0; BP52=0; VP51=0; VP52=0\necho 'P5 SKIPPED (P7 paper-config-only run)'\n\n''' + src[end:]

# Skip both P5 matrices, but leave successful zero status values so the base
# export/status machinery can remain unchanged.
start = src.index('RC1=98; RC2=98; RC3=98')
end = src.index('\nclean_host_local; clean_host_remote\n\nif [ "$BP71" -eq 0 ]', start)
src = src[:start] + '''RC1=0; RC2=0; RC3=98\necho 'P5 IDLE RC=0 (SKIPPED_P7_ONLY)'\necho 'P5 POWER RC=0 (SKIPPED_P7_ONLY)'\n''' + src[end:]

old = '''    echo '=== 3/3 P7 PRIMARY LINUX UDP BASELINE ==='\n    cd "$P7" || exit 90\n    bash ./run_matrix_with_report.sh \\\n        --chart-style both \\\n        --log-level 0 \\\n        --client-host tinyman \\\n        --client-dir "$P7" \\\n        --downloads "$DOWNLOADS" \\\n        --gap-seconds 5 \\\n        --runs "$RUNS" \\\n        --pre-cooldown-seconds 5 \\\n        --post-cooldown-seconds 5 \\\n        --between-runs-seconds 5 \\\n        --dataplane-cpu 19 \\\n        --quic-cpus 21,22,23,24 \\\n        --pin-irq 1 \\\n        --pin-quic 1 \\\n        --disable-rps 1 \\\n        --nic-offloads native \\\n        --record-quic-cpus 0 \\\n        --enable-record 1 \\\n        --rapl-interval-ms 6 \\\n        --freq-interval-ms 1 \\\n        --require-rapl 1 \\\n        --stop-irqbalance 1 \\\n        --mtu 1500 \\\n        --output-dir "$P7OUT"\n'''
new = '''    echo '=== P7 NOMS PAPER TEXT + TUM GITHUB ARTIFACT CONFIG ==='\n    echo 'paper config: max_throughput, 8GiB, rmem=6815744, wmem=6815744, artifact GSO/GRO offload activation'\n    echo 'our extra tuning disabled: pin_irq=0 pin_quic=0 disable_rps=0 disable_rdma=0 combined=native stop_irqbalance=0 D1D2plus=0 recording=0'\n    cd "$P7" || exit 90\n    bash ./run_matrix_with_report.sh \\\n        --chart-style both \\\n        --log-level 1 \\\n        --client-host tinyman \\\n        --client-dir "$P7" \\\n        --downloads "$DOWNLOADS" \\\n        --gap-seconds 0 \\\n        --runs "$RUNS" \\\n        --pre-cooldown-seconds 0 \\\n        --post-cooldown-seconds 0 \\\n        --between-runs-seconds 0 \\\n        --pin-irq 0 \\\n        --pin-quic 0 \\\n        --disable-rps 0 \\\n        --disable-rdma 0 \\\n        --nic-offloads paper \\\n        --udp-rmem 6815744 \\\n        --udp-wmem 6815744 \\\n        --combined-channels native \\\n        --network-diagnostics 1 \\\n        --record-quic-cpus 0 \\\n        --enable-record 0 \\\n        --require-rapl 0 \\\n        --stop-irqbalance 0 \\\n        --mtu 1500 \\\n        --output-dir "$P7OUT"\n'''
if src.count(old) != 1:
    raise SystemExit(f'ERROR: expected one P7 invocation block, found {src.count(old)}')
src = src.replace(old, new, 1)

# Metadata: explicitly separate paper/artifact knobs from deliberate workload
# count changes, and do not claim GreenQUIC testbed tuning as paper settings.
old_meta_start = "printf 'branch=performance2/p5-max-goodput\\ncommit=%s\\nruns=%s\\ndownloads=%s\\nseed=%s\\nP5_default="
mi = src.find(old_meta_start)
if mi < 0:
    raise SystemExit('ERROR: source_paths metadata anchor missing')
me = src.index(" > \"$EX/source_paths.txt\"", mi) + len(" > \"$EX/source_paths.txt\"")
meta = '''cat > "$EX/source_paths.txt" <<META\nbranch=performance2/p5-max-goodput\ncommit=$SHA\nruns=$RUNS\ndownloads=$DOWNLOADS\nP7=$P7OUT\nprofile=PAPER_TEXT_PLUS_TUM_GITHUB_ARTIFACT\nmsquic_execution_profile=max_throughput\npayload_bytes=8589934592\nudp_rmem_bytes=6815744\nudp_wmem_bytes=6815744\nnic_offloads=paper_artifact_activation\npin_irq=0\npin_quic=0\ndisable_rps=0\ndisable_rdma=0\ncombined_channels=native\nstop_irqbalance=0\nd1d2plus=0\nrapl_freq_cstate_recording=0\ngap_seconds=0\npre_cooldown_seconds=0\npost_cooldown_seconds=0\nbetween_runs_seconds=0\nNOTE=6x6 workload count requested separately; not claimed as NOMS paper repetition structure\nMETA'''
src = src[:mi] + meta + src[me:]

# Export only the P7 result ZIP. P5 folders do not exist because they were skipped.
src = src.replace('zip_one "$MON" "P5_IDLE_MONITOR_${RUNS}r_${DOWNLOADS}d_${TAG}"\n', '', 1)
src = src.replace('zip_one "$PWR" "P5_POWER_FRIENDLY_${RUNS}r_${DOWNLOADS}d_${TAG}"\n', '', 1)
src = src.replace(
    'zip_one "$P7OUT" "P7_LINUX_NATIVE_${RUNS}r_${DOWNLOADS}d_${TAG}"',
    'zip_one "$P7OUT" "P7_PAPER_TEXT_GITHUB_${RUNS}r_${DOWNLOADS}d_${TAG}"',
    1,
)

# P7-only preflight. Avoid running P5 transformer self-tests for an unrelated run.
old1 = '''ssh_transport_retry "cd '/root/mohsen/$P5_REL' && bash -n ./build_p5_performance2.sh ./run_matrix_with_sheet.sh && python3 -m py_compile ./apply_p5_performance2.py ./test_p5_performance2_transform.py ./apply_p5_performance2_v2.py ./test_p5_performance2_v2_transform.py && python3 ./test_p5_performance2_transform.py && python3 ./test_p5_performance2_v2_transform.py && cd '/root/mohsen/$P7_REL' && bash -n ./build_p7_linux.sh ./run_matrix_with_report.sh ./run_matrix_from_idex.sh"'''
new1 = '''ssh_transport_retry "cd '/root/mohsen/$P7_REL' && bash -n ./build_p7_linux.sh ./run_matrix_with_report.sh ./run_matrix_from_idex.sh ./p7_network_tuning.sh"'''
if src.count(old1) != 1:
    raise SystemExit('ERROR: idex preflight anchor missing')
src = src.replace(old1, new1, 1)
old2 = '''ssh_transport_retry "ssh -o ConnectTimeout=15 root@tinyman 'cd /root/mohsen/$P5_REL && bash -n ./build_p5_performance2.sh ./run_matrix_with_sheet.sh && python3 -m py_compile ./apply_p5_performance2.py ./test_p5_performance2_transform.py ./apply_p5_performance2_v2.py ./test_p5_performance2_v2_transform.py && python3 ./test_p5_performance2_transform.py && python3 ./test_p5_performance2_v2_transform.py && cd /root/mohsen/$P7_REL && bash -n ./build_p7_linux.sh ./run_matrix_with_report.sh ./run_matrix_from_idex.sh'"'''
new2 = '''ssh_transport_retry "ssh -o ConnectTimeout=15 root@tinyman 'cd /root/mohsen/$P7_REL && bash -n ./build_p7_linux.sh ./run_matrix_with_report.sh ./run_matrix_from_idex.sh ./p7_network_tuning.sh'"'''
if src.count(old2) != 1:
    raise SystemExit('ERROR: tinyman preflight anchor missing')
src = src.replace(old2, new2, 1)

# Final success logic still sees RC1=RC2=0 (intentional skips) and requires P7=0.
Path(sys.argv[2]).write_text(src, encoding='utf-8')
PY

chmod 0700 "$PATCHED"
bash -n "$PATCHED"

# Keep the generated script in /tmp for detached self-reexec.
exec bash "$PATCHED" "$@"
