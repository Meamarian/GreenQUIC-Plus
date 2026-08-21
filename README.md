# GreenQUIC+

## Sleep Tight, QUIC Fast: Energy-Efficient QUIC with DPDK

**Mohsen Memarian\*, Andreas Kassler\*†, Johannes Späth‡, Marcel Kempf‡, Stefan Lachnit‡, Johannes Zirngibl§, Georg Carle‡**

\* Karlstad University, Sweden  
† Deggendorf Institute of Technology, Germany  
‡ Technical University of Munich, Germany  
§ Max Planck Institute for Informatics, Germany

**Contact:** mohsen.memarian@kau.se, andreas.kassler@kau.se, spaethj@net.in.tum.de, kempfm@net.in.tum.de, lachnit@net.in.tum.de, jzirngib@mpi-inf.mpg.de, carle@net.in.tum.de

GreenQUIC+ repository is the implementation of the **“Sleep Tight, QUIC Fast: Energy-Efficient QUIC with DPDK”** paper.

High-performance QUIC implementations can leverage DPDK to bypass the kernel network stack and achieve high packet-processing rates. However, DPDK's polling-based execution model can consume substantial CPU resources and energy even during periods of low traffic. In this paper, we present an adaptive power-management mechanism for a DPDK-based MsQuic implementation that dynamically adjusts CPU frequency and idle behavior based on both datapath activity and QUIC transport information. We evaluate the implementation using repeated QUIC file transfers under different operating configurations. The results show that the proposed mechanism lowers power consumption at both the QUIC client and server while achieving high goodput across the evaluated workloads.

The same optimized DPDK datapath is used for three runtime modes:

- **OFF / MsQuic-DPDK:** GreenQUIC power-management decisions are bypassed.
- **BASIC / GreenQUIC:** power decisions use DPDK activity.
- **PLUS / GreenQUIC+:** the BASIC policy is extended with short-lived QUIC transport information.

We also evaluate the Linux datapath using a MsQuic UDP build with DPDK and XDP disabled.

---

## Repository layout

| Path | Purpose |
|---|---|
| `msquic/` | MsQuic + DPDK source used by GreenQUIC+ |
| `greenquic_test_suite_v22/` | P5/P7 build, execution, recording, report, and validation suite |
| `results_analysis/` | paper configuration, dependency records, original tuning XLSX files, chart code, high-level reproduction helpers and final audit |
| `tum_testbed_setup/` | single TUM testbed provisioning/build entrypoint and guide |
| `acpi.sh` | ACPI/platform power helper |
| `msr.py` | MSR energy helper |

---

# Roles and paper-testbed defaults

Roles are semantic; host names are not.

```text
CONTROL HOST  machine holding the private checkout and launching setup/tests
SERVER        QUIC server + experiment controller
CLIENT        QUIC client
BASTION       optional SSH jump/bootstrap host
```

Our paper-testbed defaults are centralized in:

```text
results_analysis/paper_testbed_defaults.sh
```

Default values:

```text
CONTROL checkout:       $HOME/Downloads/GreenQUIC-Plus on our Mac
SERVER:                 idex
CLIENT from CONTROL:    tinyman
CLIENT from SERVER:     tinyman
BASTION:                mohsen@coinbase
CONTROL SSH key:        $HOME/.ssh/id_ed25519
remote user:            root
remote repository root: /root/mohsen
branch:                 main
paper test NIC PCI:     0000:18:00.0
```

On our paper testbed, the high-level commands need no host arguments. On another deployment, the same high-level setup, rebuild, run and monitor wrappers accept explicit `--server-host`, `--client-host`, `--bastion`, and `--ssh-key` switches. Setup additionally accepts `--server-to-client-host` when SERVER reaches CLIENT under a different name/address. Change host names with switches, not by editing scripts.

`idex` and `tinyman` are only our paper-testbed defaults.

### Required SSH topology

Fresh deployment:

```text
CONTROL -> BASTION        required only when a bastion is used
BASTION -> SERVER         required for fresh-node public-key bootstrap
BASTION -> CLIENT         required for fresh-node public-key bootstrap
CONTROL -> SERVER         required
CONTROL -> CLIENT         required
SERVER  -> CLIENT         required
CLIENT  -> SERVER         not required
```

Final paper run after provisioning:

```text
CONTROL -> SERVER         required
SERVER  -> CLIENT         required
CONTROL -> CLIENT         not required by the final launcher
CLIENT  -> SERVER         not required
```

Only the CONTROL HOST needs private-GitHub credentials. Exact source commits are transferred to the experiment nodes with Git bundles. The CONTROL private SSH key is never copied to SERVER or CLIENT; setup installs only its public half and creates a separate SERVER key for SERVER -> CLIENT.

---

# What P5 and P7 mean

`P5` and `P7` are experiment names.

**P5** is the repeated 8-GiB download experiment over the optimized DPDK MsQuic path. It compares OFF, BASIC and PLUS on the same datapath.

**P7** is the matching repeated 8-GiB experiment over Linux MsQuic/UDP.

Final workload:

```text
6 independent repetitions
5 sequential 8-GiB downloads per repetition
5 s inter-download gap
5 s edge cooldown
5 s between workloads/runs
seed 20260806
```

Test CPU topology:

```text
ENABLE_MULTICORE=0
DPDK / Linux dataplane CPU=19
MsQuic worker CPUs=21,22,23,24
```

Machine-readable configuration is under `results_analysis/configuration/`.

---

# Run binaries

On both SERVER and CLIENT, after the supported setup:

```text
P5 client: /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop
P5 server: /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinteropserver

P7 client: /root/mohsen/msquic/build-linux-p7/bin/Release/quicinterop
P7 server: /root/mohsen/msquic/build-linux-p7/bin/Release/quicinteropserver
```

P7 is built with `QUIC_LINUX_DPDK_ENABLED=OFF` and `QUIC_LINUX_XDP_ENABLED=OFF`.

---

# Dependencies

The current reproduction path has two kinds of dependencies: repository-pinned source versions and Debian packages resolved from the Debian Trixie repositories at setup time.

| Component | Version | Reproducibility note |
|---|---|---|
| Modified MsQuic source | `2.4.8` source version | use the exact GreenQUIC+ Git SHA; stock upstream 2.4.8 is not equivalent |
| DPDK | `21.11.9` | vendored under `msquic/deps/dpdk/` |
| CMake | `>= 3.20` for the static build used here | enforced by the MsQuic CMake configuration |
| TLS backend | OpenSSL | P5/P7 configure `QUIC_TLS=openssl` |
| Build type | Release | used by both paper builds |
| Endpoint OS | Debian Trixie | setup rejects a different distribution/codename |
| Python | Python 3 + NumPy + Matplotlib | report/analysis dependency |
| NIC tools | `ethtool`, `iproute2`, PCI/kernel modules | setup/network transition dependency |
| Power tools | RAPL access, `msr-tools`, `lm-sensors`, `acpi.sh`, `msr.py` | measurement dependency |

The exact Debian package revisions and kernel patch version are not individually pinned by the setup script. They are installed from the configured Debian Trixie repositories. The full package list and pinning policy are machine-readable in:

```text
results_analysis/configuration/dependencies.json
```

After provisioning, **RUN ON: CONTROL HOST** to record/inspect the actual versions on CONTROL, SERVER and CLIENT:

```bash
bash results_analysis/print_dependency_versions.sh
```

Paper hardware assumptions remain: Intel E810 test NIC at PCI `0000:18:00.0`, Linux `ice` for link/P7 operation, `igb_uio` or `vfio-pci` for DPDK, `16384 × 2 MiB` hugepages on the test-NIC NUMA node, CPU19 for dataplane work and CPUs21-24 for MsQuic.

---

# Reproduction quick start

The blocks below are intended to be pasteable on the CONTROL HOST. For our paper testbed they default to the Mac checkout `$HOME/Downloads/GreenQUIC-Plus`, SERVER `idex`, CLIENT `tinyman`, BASTION `mohsen@coinbase`, and SSH key `$HOME/.ssh/id_ed25519`.

The clone logic is included: if the private repository is not already present on the CONTROL HOST, it is cloned first. SERVER and CLIENT are **not** cloned from GitHub directly; setup transfers the exact `main` SHA by Git bundle.

For POS allocation/reimage/reset, use `tum_testbed_setup/README.md`; every long-running operation there states where it must run and is followed by its live monitor/readiness loop.

## 1. Debian Trixie exists; deploy current `main`, prepare hosts and build everything

**RUN ON: CONTROL HOST:**

```bash
REPO="$HOME/Downloads/GreenQUIC-Plus"
if [ ! -d "$REPO/.git" ]; then
  git clone git@github.com:Meamarian/GreenQUIC-Plus.git "$REPO"
fi
cd "$REPO" && \
git checkout main && \
bash results_analysis/setup_paper_testbed.sh
```

**LIVE MONITOR — RUN ON: second CONTROL-HOST terminal after starting setup:**

```bash
cd "$HOME/Downloads/GreenQUIC-Plus" && \
bash results_analysis/live_monitor_setup.sh
```

This is also the supported path when Debian is already installed but `/root/mohsen` is absent, stale, or you want a fresh exact deployment/build. Do not manually clone the private repository on SERVER or CLIENT.

## 2. Hosts/repository/DPDK are already correct; rebuild only P5 and P7

**RUN ON: CONTROL HOST:**

```bash
REPO="$HOME/Downloads/GreenQUIC-Plus"
if [ ! -d "$REPO/.git" ]; then
  git clone git@github.com:Meamarian/GreenQUIC-Plus.git "$REPO"
fi
cd "$REPO" && \
git checkout main && \
bash results_analysis/rebuild_paper_binaries.sh
```

**LIVE MONITOR — RUN ON: second CONTROL-HOST terminal after starting rebuild:**

```bash
cd "$HOME/Downloads/GreenQUIC-Plus" && \
bash results_analysis/live_monitor_setup.sh
```

## 3. Everything is ready; run the final paper evaluation

**RUN ON: CONTROL HOST:**

```bash
REPO="$HOME/Downloads/GreenQUIC-Plus"
if [ ! -d "$REPO/.git" ]; then
  git clone git@github.com:Meamarian/GreenQUIC-Plus.git "$REPO"
fi
cd "$REPO" && \
git checkout main && \
bash results_analysis/run_paper_evaluation.sh
```

**LIVE MONITOR — RUN ON: second CONTROL-HOST terminal after launch:**

```bash
cd "$HOME/Downloads/GreenQUIC-Plus" && \
bash results_analysis/live_monitor_run.sh
```

## 4. Manual re-download of the last finished result

Step 3 performs automatic SCP. Use this only to re-download the exact recorded run.

**RUN ON: CONTROL HOST:**

```bash
cd "$HOME/Downloads/GreenQUIC-Plus" && \
bash results_analysis/download_paper_results.sh
```
```

## 5. Local final repository/reproduction audit

**RUN ON: CONTROL HOST:**

```bash
cd "$HOME/Downloads/GreenQUIC-Plus" && \
bash results_analysis/final_repository_check.sh
```

---

## Another deployment: management switches

The high-level wrappers support explicit management routing. For setup:

```text
--server-host HOST
--client-host HOST
--server-to-client-host HOST
--bastion USER@HOST|none
--ssh-key PATH
```

Example setup:

**RUN ON: CONTROL HOST:**

```bash
cd "$HOME/Downloads/GreenQUIC-Plus" && \
bash results_analysis/setup_paper_testbed.sh \
  --server-host server01 \
  --client-host client-via-gateway \
  --server-to-client-host 10.0.0.22 \
  --bastion user@gateway \
  --ssh-key "$HOME/.ssh/lab_key"
```

**LIVE MONITOR — RUN ON: second CONTROL-HOST terminal:**

```bash
cd "$HOME/Downloads/GreenQUIC-Plus" && \
bash results_analysis/live_monitor_setup.sh \
  --server-host server01 \
  --client-host client-via-gateway \
  --bastion user@gateway \
  --ssh-key "$HOME/.ssh/lab_key"
```

For the final run, `--client-host` means the CLIENT endpoint as seen from SERVER. Setup separates the CONTROL view and SERVER view of CLIENT so a different lab topology does not require aliases matching our paper testbed.

Changing these management names does not change the recorded paper hardware assumptions: root remote operation, `/root/mohsen`, E810 PCI `0000:18:00.0`, the paper data-plane IP/MAC pair, CPU19/21-24 placement, and the hugepage configuration remain part of the paper testbed and must be intentionally revalidated on different hardware.

---

## Results recording

For tag `<TAG>` (tag is test timestamp), SERVER stores the final matrix trees at:

```text
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/matrix_results/P5_FAIR_OPT_PINNED_6r_5d_<TAG>
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline/matrix_results/P7_FAIR_PAPER_PINNED_6r_5d_<TAG>
```

Controller metadata is under `/root/GQ_FAIR_REPRO_<TAG>/`, and the two final ZIPs are `/root/P5_FAIR_OPT_PINNED_6r_5d_<TAG>.zip` and `/root/P7_FAIR_PAPER_PINNED_6r_5d_<TAG>.zip`. `RESULT_DIRS.env` records these exact paths. Main generated charts are in each matrix result's `the_sheet_rules_all/` report tree.

## Analysis artifacts

`results_analysis/` contains the original supplied tuning workbooks and chart artifacts, including:

```text
results_analysis/tuning/GreenQUIC_DPDK_Path_Perf_Tunning_v2.xlsx
results_analysis/tuning/GreenQUIC_Power_Mng_Tuning_v1.xlsx
results_analysis/charts/...
```

`artifact_files.sha256.json` records expected sizes/SHA-256 values for the imported artifacts.

## Contact

If you have any questions regarding the repository, contact mohsen.memarian@kau.se.
