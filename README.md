# GreenQUIC+

## Sleep Tight, QUIC Fast: Energy-Efficient QUIC with DPDK

**Mohsen Memarian\*, Andreas Kassler\*†, Johannes Späth‡, Marcel Kempf‡, Stefan Lachnit‡, Johannes Zirngibl§, Georg Carle‡**

\* Karlstad University, Sweden  
† Deggendorf Institute of Technology, Germany  
‡ Technical University of Munich, Germany  
§ Max Planck Institute for Informatics, Germany

**Contact:** mohsen.memarian@kau.se, andreas.kassler@kau.se, spaethj@net.in.tum.de, kempfm@net.in.tum.de, lachnit@net.in.tum.de, jzirngib@mpi-inf.mpg.de, carle@net.in.tum.de

GreenQUIC+ is the implementation and reproducibility repository for **“Sleep Tight, QUIC Fast: Energy-Efficient QUIC with DPDK.”** The project studies adaptive CPU power management for a DPDK-based MsQuic datapath by controlling CPU frequency and idle behavior while keeping high QUIC goodput.

The same optimized DPDK/MsQuic datapath is used for three runtime modes:

- **OFF / MsQuic-DPDK:** GreenQUIC power-management decisions are bypassed.
- **BASIC / GreenQUIC:** power decisions use physical DPDK activity.
- **PLUS / GreenQUIC+:** the BASIC policy is extended with short-lived QUIC transport information.

The Linux comparison is **P7**, an isolated normal-Linux MsQuic UDP build with DPDK and XDP disabled.

---

## Repository status and provenance

```text
Repository:     Meamarian/GreenQUIC-Plus
Visibility:     private
Default branch: main
```

`main` originated from the final paper/reproduction branch of the original repository:

```text
old repository: Meamarian/GreenQUIC
old branch:     performance2/p5-multicore
import SHA:     58d00a39270f512b6e9586704797dff6285e73b2
```

The exact imported state is preserved as `paper/original-p5-multicore`. Current work and reproduction use `main`.

---

## Repository layout

| Path | Purpose |
|---|---|
| `msquic/` | MsQuic + DPDK source used by GreenQUIC+ |
| `greenquic_test_suite_v22/` | authoritative P5/P7 build, execution, recording, report and validation suite |
| `results_analysis/` | exact paper configuration, original tuning XLSX files, chart code/SVGs, high-level reproduction helpers and final audit |
| `tum_testbed_setup/` | single supported TUM/LRZ provisioning/build implementation and guide |
| `acpi.sh` | ACPI/platform power helper |
| `msr.py` | MSR helper |

The obsolete `greenquic_test_suite/`, old root bootstrap/patch helpers and old `power_mng_tunning/` directory were removed from `main`. Historical states remain in Git history/backups.

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
CONTROL checkout:       current GreenQUIC-Plus clone
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

On our paper testbed the high-level commands need no host arguments. On another deployment, the **same high-level setup, rebuild, run and monitor wrappers accept explicit `--server-host`, `--client-host`, `--bastion`, and `--ssh-key` switches**. Setup additionally accepts `--server-to-client-host` when SERVER reaches CLIENT under a different name/address. Host names should be changed with switches, not by editing scripts.

`idex` does not mean SERVER in the code and `tinyman` does not mean CLIENT in the code. They are only our paper-testbed defaults.

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

`P5` and `P7` are experiment names, not QUIC versions.

**P5** is the repeated 8-GiB download experiment over the optimized DPDK MsQuic path. It compares OFF, BASIC and PLUS on the same Performance2 V2 datapath.

**P7** is the matching repeated 8-GiB experiment over isolated normal-Linux MsQuic/UDP.

Final workload:

```text
6 independent repetitions
5 sequential 8-GiB downloads per repetition
5 s inter-download gap
5 s edge cooldown
5 s between workloads/runs
seed 20260806
```

Final P5 datapath marker:

```text
GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0
```

Final TOP3 power-policy overrides:

```text
PRESSURE_UP=450
RX_QUEUE_HIGH=48
ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16
FREQ_PERIOD_US=10000
GQ_IDLE_MODE_OVERRIDE=monitor
GQ_IDLE_FALLBACK_OVERRIDE=short
```

Paper CPU topology:

```text
ENABLE_MULTICORE=0
DPDK / Linux dataplane CPU=19
MsQuic worker CPUs=21,22,23,24
```

Machine-readable configuration is under `results_analysis/configuration/`.

---

# Exact binaries

On both SERVER and CLIENT, after supported setup:

```text
P5 client: /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop
P5 server: /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinteropserver

P7 client: /root/mohsen/msquic/build-linux-p7/bin/Release/quicinterop
P7 server: /root/mohsen/msquic/build-linux-p7/bin/Release/quicinteropserver
```

P7 is built with `QUIC_LINUX_DPDK_ENABLED=OFF` and `QUIC_LINUX_XDP_ENABLED=OFF`, and the build verifies that P7 does not link DPDK.

---

# Reproduction quick start

For POS allocation/reimage/reset, use `tum_testbed_setup/README.md`; every long-running operation there states where it must run and is followed by its live monitor/readiness loop.

## 1. Debian Trixie exists; deploy current `main`, prepare hosts and build everything

**RUN ON: CONTROL HOST** from the GreenQUIC+ checkout:

```bash
bash results_analysis/setup_paper_testbed.sh
```

Immediately in **a second CONTROL-HOST terminal**, use the live setup/build monitor:

```bash
bash results_analysis/live_monitor_setup.sh
```

This is also the supported path when Debian is already installed but `/root/mohsen` is absent, stale, or you want a fresh exact deployment/build. Do not manually clone the private repository on SERVER or CLIENT.

## 2. Hosts/repository/DPDK are already correct; rebuild only P5 and P7

**RUN ON: CONTROL HOST:**

```bash
bash results_analysis/rebuild_paper_binaries.sh
```

Immediately in **a second CONTROL-HOST terminal:**

```bash
bash results_analysis/live_monitor_setup.sh
```

If source code also changed or the remote checkout may be stale, use the full setup in step 1 instead.

## 3. Everything is ready; run the final paper evaluation

**RUN ON: CONTROL HOST:**

```bash
bash results_analysis/run_paper_evaluation.sh
```

Immediately in **a second CONTROL-HOST terminal:**

```bash
bash results_analysis/live_monitor_run.sh
```

The final launcher deliberately rebuilds/verifies P5 and P7 before measured traffic, records the exact Git SHA and effective configuration, runs P5 then P7, and packages results on the SERVER role.

## 4. Download the latest finished result

**RUN ON: CONTROL HOST:**

```bash
bash results_analysis/download_paper_results.sh
```

This operates only after a run is marked `DONE`; there is no live experiment log to follow during this short post-run download. Use `live_monitor_run.sh` while the experiment itself is still running.

## 5. Local final repository/reproduction audit

**RUN ON: CONTROL HOST:**

```bash
bash results_analysis/final_repository_check.sh
```

This is a local static audit; it launches no remote workload, so there is no live experiment log. It checks current shell syntax, JSON/configuration consistency, TUM layout, host-role switches, README/monitor pairing, imported artifacts, and the exact P5/P7 paper anchors.

---

## Another deployment: management switches

The high-level wrappers support explicit management routing. For setup, the relevant interface is:

```text
--server-host HOST
--client-host HOST
--server-to-client-host HOST
--bastion USER@HOST|none
--ssh-key PATH
```

For the final run, `--client-host` means the CLIENT endpoint **as seen from SERVER**. Setup separates the CONTROL view and SERVER view of CLIENT so a different lab topology does not require aliases matching our paper testbed.

Changing these management names does not change the recorded paper hardware assumptions: root remote operation, `/root/mohsen`, E810 PCI `0000:18:00.0`, the paper data-plane IP/MAC pair, CPU19/21-24 placement, and the hugepage configuration remain part of the paper testbed and must be intentionally revalidated on different hardware.

---

## Analysis artifacts

`results_analysis/` contains the original supplied tuning workbooks and chart artifacts, including:

```text
results_analysis/tuning/GreenQUIC_DPDK_Path_Perf_Tunning_v2.xlsx
results_analysis/tuning/GreenQUIC_Power_Mng_Tuning_v1.xlsx
results_analysis/charts/chart_v2.py
results_analysis/charts/svg/...
```

`artifact_files.sha256.json` records expected sizes/SHA-256 values for the imported artifacts.

---

## Branch model

```text
main                         current GreenQUIC+ paper/development baseline
paper/original-p5-multicore exact imported paper snapshot
development                  integration work
research/power-management    power-policy experiments
research/dpdk-performance    datapath/performance experiments
performance2/p5-max-goodput  preserved Performance2 tuning line
performance2/p5-multicore    preserved original paper branch name
```

Additional historical branches are retained for provenance. Use feature/fix branches and pull requests for collaborative development rather than modifying preserved historical branches.

---

## Detailed guides

- `results_analysis/README.md` — full start-state decision tree, exact configurations, result locations and analysis artifacts.
- `tum_testbed_setup/README.md` — POS/Debian provisioning and the single TUM setup implementation.
- `results_analysis/HOST_ROLE_AUDIT.md` — host-name/SSH dependency audit.
