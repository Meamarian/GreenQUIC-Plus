# GreenQUIC+ results, analysis, and paper reproduction

This directory is the reference for the evaluation in **“Sleep Tight, QUIC Fast: Energy-Efficient QUIC with DPDK.”** It contains the final experiment configuration, tuning records, supplied analysis artifacts, and the commands needed to reproduce the P5/P7 comparison.

This is intentionally separate from `tum_testbed_setup/`: the TUM setup script prepares machines; this directory defines **what was measured for our paper**.

## What P5 and P7 mean

`P5` and `P7` are internal experiment names. They are not QUIC protocol versions.

| Name | Meaning | Datapath compared | Modes |
|---|---|---|---|
| **P5** | repeated 8-GiB QUIC download experiment over the optimized DPDK MsQuic implementation | Performance2 V2 DPDK kernel-bypass datapath | OFF / MsQuic-DPDK, BASIC / GreenQUIC, PLUS / GreenQUIC+ |
| **P7** | repeated 8-GiB QUIC download experiment using an isolated normal-Linux MsQuic build | Linux UDP socket path; DPDK OFF; XDP OFF | Linux baseline |

IDEX is the QUIC **server** and experiment controller. Tinyman is the QUIC **client**.

The final paper comparison is **P5 TOP3 versus P7 Linux**, using 6 independent repetitions and 5 sequential 8-GiB downloads per repetition.

## Exact directories, build outputs, and executables

On both IDEX and Tinyman, the repository root is:

```text
/root/mohsen
```

### P5 — DPDK MsQuic + GreenQUIC/GreenQUIC+

```text
Experiment directory:
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads

Build script:
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/build_p5_performance2.sh

Build directory:
/root/mohsen/msquic/build-greenquic-p5

Client executable (Tinyman):
/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop

Server executable (IDEX):
/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinteropserver

DPDK install used by P5:
/root/mohsen/msquic/deps/dpdk-install
```

The exact final P5 binary marker is:

```text
GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0
```

The final TOP3 policy is explicitly injected by the supported paper launcher:

```text
PRESSURE_UP=450
RX_QUEUE_HIGH=48
ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16
FREQ_PERIOD_US=10000
GQ_IDLE_MODE_OVERRIDE=monitor
GQ_IDLE_FALLBACK_OVERRIDE=short
```

The final topology is single-DPDK-owner:

```text
ENABLE_MULTICORE=0
DPDK CPU on each endpoint: 19
MsQuic worker CPUs on each endpoint: 21,22,23,24
```

### P7 — isolated normal-Linux MsQuic baseline

```text
Experiment directory:
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline

Build script:
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline/build_p7_linux.sh

Disposable isolated Linux source tree:
/root/mohsen/msquic-p7-linux-source

Build directory:
/root/mohsen/msquic/build-linux-p7

Client executable (Tinyman):
/root/mohsen/msquic/build-linux-p7/bin/Release/quicinterop

Server executable (IDEX):
/root/mohsen/msquic/build-linux-p7/bin/Release/quicinteropserver
```

P7 is compiled with `QUIC_LINUX_DPDK_ENABLED=OFF` and `QUIC_LINUX_XDP_ENABLED=OFF`; the build script checks that neither executable links a DPDK library. Its final paper network profile uses CPU19 for NIC IRQ/NAPI/softirq handling, MsQuic workers on CPUs21-24, RPS disabled, one combined NIC channel, UDP rmem/wmem of 6,815,744 bytes, MTU 1500, temporary RDMA-aux disablement for the test NIC, and the paper GSO/GRO profile.

A machine-readable path map is in `configuration/experiment_paths.json`.

## Directory layout

```text
results_analysis/
├── README.md
├── artifact_files.sha256.json
├── import_attached_artifacts.py
├── verify_paper_configuration.py
├── download_latest_reproduction.sh
├── configuration/
│   ├── README.md
│   ├── experiment_paths.json
│   ├── p5_paper_evaluation.json
│   └── p7_paper_evaluation.json
├── tuning/
│   ├── README.md
│   ├── summary.json
│   ├── GreenQUIC_DPDK_Path_Perf_Tunning_v2.xlsx
│   └── GreenQUIC_Power_Mng_Tuning_v1.xlsx
└── charts/
    ├── README.md
    ├── SOURCE_REFERENCE.txt
    ├── chart_v2.py
    ├── manifest.json
    └── svg/
        ├── timeseries/
        ├── with_values/
        └── without_values/
```

The original workbooks, chart-generation script, and SVGs come from the supplied `Tunning.zip` and `Charts (2).zip`. `.DS_Store` is deliberately excluded. `artifact_files.sha256.json` records the exact expected size and SHA-256 of every imported source file.

## Import the supplied Excel/SVG artifacts

If the two original ZIP files have not yet been committed in a clone, import them byte-for-byte with the repository helper:

```bash
cd ~/Downloads/GreenQUIC-Plus && \
python3 results_analysis/import_attached_artifacts.py \
  --charts-zip "$HOME/Downloads/Charts (2).zip" \
  --tuning-zip "$HOME/Downloads/Tunning.zip"
```

The script validates all 45 source files against the checked-in SHA-256 manifest before writing anything. To import, commit, and push them to private `origin/main` in one step, start from a clean `main` worktree and run:

```bash
cd ~/Downloads/GreenQUIC-Plus && \
git fetch origin main && \
git checkout main && \
git reset --hard origin/main && \
python3 results_analysis/import_attached_artifacts.py \
  --charts-zip "$HOME/Downloads/Charts (2).zip" \
  --tuning-zip "$HOME/Downloads/Tunning.zip" \
  --commit --push
```

After the artifact import, a new clone contains the actual `.xlsx`, `chart_v2.py`, and SVG files directly under the paths shown above; no separate ZIP is required for analysis.

---

# Reproduction workflow: choose the state you are starting from

The most important distinction is whether the machines need an OS, need GreenQUIC+ provisioning/builds, or are already prepared.

## State A — IDEX/Tinyman need a new Debian installation

Use this when the nodes have been reset/lost, are on the wrong image, or you deliberately want a clean experiment environment.

### A1. On Coinbase/POS: allocate each node if necessary

First inspect state:

```bash
pos nodes list | grep -E 'idex|tinyman'
```

If a node's allocation is `None`, allocate it **individually**:

```bash
pos allocations allocate idex
pos allocations allocate tinyman
```

If the nodes are already allocated to your experiment, do not allocate them again. Do not free another user's allocation.

### A2. Select Debian Trixie and reset both nodes

```bash
pos nodes image idex debian-trixie
pos nodes image tinyman debian-trixie

pos nodes reset idex &
pos nodes reset tinyman &
wait

pos nodes list | grep -E 'idex|tinyman'
```

A POS reset destroys the node's RAM-disk contents. `/root/mohsen`, previous builds, result directories, and generated payloads on those nodes must therefore be considered gone after reset.

Wait until both nodes report `debian-trixie` and are SSH reachable from Coinbase:

```bash
for h in idex tinyman; do
  until ssh -o ConnectTimeout=5 root@"$h" 'hostname; . /etc/os-release; echo "$ID $VERSION_CODENAME"'; do
    echo "waiting for $h ..."
    sleep 5
  done
done
```

### A3. From the Mac: run the single complete GreenQUIC+ setup

Update the private repository first:

```bash
cd ~/Downloads/GreenQUIC-Plus && \
git fetch origin main && \
git checkout main && \
git reset --hard origin/main && \
python3 results_analysis/verify_paper_configuration.py && \
bash tum_testbed_setup/greenquic_fresh_setup.sh
```

Immediately monitor from another Mac terminal:

```bash
while true; do
  clear
  date
  echo
  ssh -J mohsen@coinbase root@idex \
    'echo "===== IDEX ====="; hostname; git -C /root/mohsen branch --show-current 2>/dev/null || true; git -C /root/mohsen rev-parse --short HEAD 2>/dev/null || true; pgrep -af "meson|ninja|cmake|build_p5|build_p7" || true'
  echo
  ssh -J mohsen@coinbase root@tinyman \
    'echo "===== TINYMAN ====="; hostname; git -C /root/mohsen branch --show-current 2>/dev/null || true; git -C /root/mohsen rev-parse --short HEAD 2>/dev/null || true; pgrep -af "meson|ninja|cmake|build_p5|build_p7" || true'
  sleep 10
done
```

This one setup operation installs the exact `origin/main` commit into `/root/mohsen` by Git bundle, installs dependencies, prepares E810/ICE firmware, MSR/P-state access, 16,384 × 2-MiB hugepages, builds DPDK, creates the 8-GiB payload, builds P5 and P7 on both endpoints, validates the direct E810 link, binds the DPDK test NIC, and verifies all four executables.

Successful completion ends with:

```text
GREENQUIC+ MAIN READY ON BOTH TUM NODES
```

After that, continue with **State D / Run the final paper test** below.

---

## State B — Debian Trixie is already installed and reachable, but GreenQUIC+ is absent or you want a clean new repository deployment/build

Do **not** reimage the nodes. Do **not** manually `git clone` the private repository onto IDEX/Tinyman.

Run the same complete setup from the Mac:

```bash
cd ~/Downloads/GreenQUIC-Plus && \
git fetch origin main && \
git checkout main && \
git reset --hard origin/main && \
python3 results_analysis/verify_paper_configuration.py && \
bash tum_testbed_setup/greenquic_fresh_setup.sh
```

Immediately monitor from another Mac terminal:

```bash
while true; do
  clear
  date
  echo
  ssh -J mohsen@coinbase root@idex \
    'echo "===== IDEX ====="; git -C /root/mohsen rev-parse --short HEAD 2>/dev/null || echo "repo not installed yet"; pgrep -af "meson|ninja|cmake|build_p5|build_p7" || true'
  echo
  ssh -J mohsen@coinbase root@tinyman \
    'echo "===== TINYMAN ====="; git -C /root/mohsen rev-parse --short HEAD 2>/dev/null || echo "repo not installed yet"; pgrep -af "meson|ninja|cmake|build_p5|build_p7" || true'
  sleep 10
done
```

Why use the setup instead of `git clone`? The repository is private, and the remote experiment nodes intentionally do not need GitHub credentials. The setup bundles the exact Mac-side `origin/main` SHA and installs that commit on both nodes. If `/root/mohsen` does not exist it initializes it; if it exists it resets it to the exact selected commit.

This state therefore covers the common case: **“Debian is ready; now put a fresh/current GreenQUIC+ tree on both servers, build DPDK/P5/P7, and make the testbed ready.”**

---

## State C — `/root/mohsen` and DPDK are already prepared, but you only want to rebuild P5/P7 binaries

This is a build-only maintenance path. It assumes the existing node provisioning is valid: Debian Trixie, dependencies, E810 firmware, hugepages, DPDK install, and repository are already present.

From the Mac, rebuild both applications on both hosts:

```bash
for h in idex tinyman; do
  ssh -J mohsen@coinbase root@"$h" '
    set -Eeuo pipefail
    ROOT=/root/mohsen
    P5="$ROOT/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
    P7="$ROOT/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline"

    test -d "$ROOT/msquic/deps/dpdk-install"
    cd "$P5"
    P5_BUILD_REUSE=1 bash ./build_p5_performance2.sh

    cd "$P7"
    bash ./build_p7_linux.sh

    test -x "$ROOT/msquic/build-greenquic-p5/bin/Release/quicinterop"
    test -x "$ROOT/msquic/build-greenquic-p5/bin/Release/quicinteropserver"
    test -x "$ROOT/msquic/build-linux-p7/bin/Release/quicinterop"
    test -x "$ROOT/msquic/build-linux-p7/bin/Release/quicinteropserver"
  '
done
```

Immediately monitor from another Mac terminal:

```bash
while true; do
  clear
  date
  for h in idex tinyman; do
    echo "===== $h ====="
    ssh -J mohsen@coinbase root@"$h" '
      pgrep -af "cmake|ninja|build_p5_performance2|build_p7_linux" || echo "no build process"
      ls -l /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop 2>/dev/null || true
      ls -l /root/mohsen/msquic/build-linux-p7/bin/Release/quicinterop 2>/dev/null || true
    '
  done
  sleep 10
done
```

Verify P5 identity and that P7 is not a DPDK build:

```bash
for h in idex tinyman; do
  ssh -J mohsen@coinbase root@"$h" '
    set -e
    P5C=/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop
    P5S=/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinteropserver
    P7C=/root/mohsen/msquic/build-linux-p7/bin/Release/quicinterop
    P7S=/root/mohsen/msquic/build-linux-p7/bin/Release/quicinteropserver
    MARKER="GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0"
    grep -aFq -- "$MARKER" "$P5C"
    grep -aFq -- "$MARKER" "$P5S"
    ! ldd "$P7C" 2>/dev/null | grep -qi dpdk
    ! ldd "$P7S" 2>/dev/null | grep -qi dpdk
    echo "BINARY VERIFY PASS $(hostname)"
  '
done
```

Important: this build-only path does not replace fresh provisioning if DPDK/hugepages/NIC state is unknown.

---

## State D — everything is already prepared and you just want to run the final paper test

Use the supported Mac launcher. **Do not run `quicinterop` manually for the paper comparison.** The launcher controls exact Git SHA synchronization, recorder placement, mode order, P5 TOP3 variables, P7 Linux network state, output naming, validation, and ZIP creation.

Even when binaries already exist, the authoritative paper launcher deliberately rebuilds/verifies P5 and P7 immediately before measured traffic. There is no supported `--no-build` paper mode; this is intentional so a stale binary cannot silently change a result.

Launch from the Mac:

```bash
cd ~/Downloads/GreenQUIC-Plus && \
git fetch origin main && \
git checkout main && \
git reset --hard origin/main && \
python3 results_analysis/verify_paper_configuration.py && \
bash greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_p7_fair_repro_6x5_v3.sh
```

Immediately monitor from another Mac terminal:

```bash
ssh idex '
log=$(find /root -maxdepth 1 -type f \
    -name "GQ_FAIR_REPRO_*.log" \
    -printf "%T@ %p\n" 2>/dev/null | \
    sort -nr | sed -n "1p" | cut -d" " -f2-)
echo "FOLLOWING: $log"
echo
if [ -z "$log" ]; then
    echo "No GQ_FAIR_REPRO log found yet"
else
    tail -n +1 -F "$log"
fi
'
```

The default is:

```text
P5: 6 runs × 5 sequential 8-GiB downloads, OFF/BASIC/PLUS
P7: 6 runs × 5 sequential 8-GiB downloads, Linux baseline
Gap: 5 s
Edge cooldown: 5 s
Between runs/tests: 5 s
Seed: 20260806
```

### Output locations

For launcher tag `<TAG>`:

```text
Controller log:
/root/GQ_FAIR_REPRO_<TAG>.log

Controller metadata/artifacts:
/root/GQ_FAIR_REPRO_<TAG>/
/root/GQ_FAIR_REPRO_<TAG>/config.env
/root/GQ_FAIR_REPRO_<TAG>/RESULT_ZIPS.txt

P5 result tree:
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/matrix_results/P5_FAIR_OPT_PINNED_6r_5d_<TAG>

P7 result tree:
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline/matrix_results/P7_FAIR_PAPER_PINNED_6r_5d_<TAG>

Final ZIPs:
/root/P5_FAIR_OPT_PINNED_6r_5d_<TAG>.zip
/root/P7_FAIR_PAPER_PINNED_6r_5d_<TAG>.zip
```

Check latest status from the Mac:

```bash
ssh idex '
art=$(find /root -maxdepth 1 -type d -name "GQ_FAIR_REPRO_*" -printf "%T@ %p\n" 2>/dev/null | sort -nr | sed -n "1p" | cut -d" " -f2-)
echo "ARTIFACT_DIR=$art"
if [ -z "$art" ]; then
    echo "No fair-reproduction artifact directory found"
elif [ -f "$art/DONE" ]; then
    echo "DONE"
    cat "$art/config.env"
    echo
    cat "$art/RESULT_ZIPS.txt"
elif [ -f "$art/FAILED" ]; then
    echo "FAILED"
    cat "$art/FAILED"
else
    echo "RUNNING"
fi
'
```

Download the latest completed reproduction:

```bash
cd ~/Downloads/GreenQUIC-Plus && \
bash results_analysis/download_latest_reproduction.sh
```

The downloaded `config.env` is part of the reproducibility record. For the default paper run it must contain, among other fields:

```text
branch=main
runs=6
downloads=5
P5_profile=optimized_Performance2_V2_TOP3_idle_monitor_normal
P5_power_profile=TOP3
P5_pressure_up=450
P5_rx_queue_high=48
P5_active_transfer_sleep_min_level=16
P5_freq_period_us=10000
P7_profile=paper_linux
P7_nic_offloads=paper
P7_udp_rmem=6815744
P7_udp_wmem=6815744
P7_combined_channels=1
```

The `commit=` field must equal the exact `origin/main` SHA bundled for that run.

---

## Convenience wrappers on IDEX

The fresh setup creates:

```text
/root/run_p5.sh
/root/run_p7.sh
```

These are generic convenience wrappers around `run_matrix_with_sheet.sh` and `run_matrix_with_report.sh`. They are useful for controlled debugging, but **they are not a substitute for the Mac V3 final-paper launcher**, because the complete paper launcher also fixes the exact Git SHA, injects TOP3, builds/verifies both applications, handles P5→P7 NIC state changes, validates recorder evidence, and packages results.

## Final configuration sources

Use these for paper methods/reproduction documentation:

```text
configuration/p5_paper_evaluation.json
configuration/p7_paper_evaluation.json
configuration/experiment_paths.json
```

The supplied chart bundle intentionally keeps its original source archive names in `charts/SOURCE_REFERENCE.txt`. Some of those names correspond to earlier analysis runs. They are chart provenance, not the final configuration definition.
