# GreenQUIC+

## Sleep Tight, QUIC Fast: Energy-Efficient QUIC with DPDK

**Mohsen Memarian\*, Andreas Kassler\*†, Johannes Späth‡, Marcel Kempf‡, Stefan Lachnit‡, Johannes Zirngibl§, Georg Carle‡**

\* Karlstad University, Sweden  
† Deggendorf Institute of Technology, Germany  
‡ Technical University of Munich, Germany  
§ Max Planck Institute for Informatics, Germany

**Contact:** mohsen.memarian@kau.se, andreas.kassler@kau.se, spaethj@net.in.tum.de, kempfm@net.in.tum.de, lachnit@net.in.tum.de, jzirngib@mpi-inf.mpg.de, carle@net.in.tum.de

This private repository contains the GreenQUIC+ implementation and reproducibility tooling accompanying the paper **“Sleep Tight, QUIC Fast: Energy-Efficient QUIC with DPDK.”**

QUIC is commonly implemented in user space. DPDK provides a high-speed kernel-bypass datapath, but polling-oriented execution can consume unnecessary power as workload demand changes. GreenQUIC+ studies adaptive CPU power management for a DPDK-based MsQuic implementation by controlling CPU frequency and idle behavior while maintaining high QUIC goodput.

The implementation exposes three runtime modes on the same optimized DPDK/MsQuic datapath: `OFF` is the MsQuic-DPDK reference without GreenQUIC power-management decisions, `BASIC` / GreenQUIC uses physical datapath activity, and `PLUS` / GreenQUIC+ extends that policy with short-lived QUIC transport information.

The DPDK/MsQuic context is closely related to the public TUM kernel-bypass artifact repository `tumi8/quic-bypass-paper`. GreenQUIC+ adds the adaptive power-management mechanism, its QUIC-aware extension, and the corresponding power/performance evaluation workflow.

---

## Repository status and provenance

```text
Repository: Meamarian/GreenQUIC-Plus
Visibility: private
Default branch: main
```

`main` was created from the final paper/reproduction line of the original repository:

```text
old repository: Meamarian/GreenQUIC
old branch:     performance2/p5-multicore
import SHA:     58d00a39270f512b6e9586704797dff6285e73b2
```

The exact imported snapshot is also preserved as `paper/original-p5-multicore`. Current GreenQUIC+ work uses `main` or branches created from it.

---

## Repository layout

| Area | Purpose |
|---|---|
| `msquic/` | MsQuic + DPDK source used by GreenQUIC+ |
| `greenquic_test_suite_v22/` | authoritative P5/P7 build, run, recorder, report, and validation suite |
| `results_analysis/` | exact paper configurations, original XLSX tuning records, chart code/SVGs, reproduction guide |
| `tum_testbed_setup/` | one supported provisioning/build setup script plus its guide |
| `acpi.sh` | ACPI/platform power helper |
| `msr.py` | MSR helper |

The old `greenquic_test_suite/`, obsolete root patch/bootstrap files, and the old top-level `power_mng_tunning/` were removed from `main` after the current paper path was verified. They remain recoverable from Git history/backups.

---

## Important: roles are not host names

All supported guides now use these roles:

```text
CONTROL HOST  machine that has the private GitHub checkout and launches setup/tests
SERVER        QUIC server + experiment controller
CLIENT        QUIC client
BASTION       optional SSH jump/bootstrap host
```

Our paper testbed used:

```text
CONTROL HOST = Mac
SERVER       = idex
CLIENT       = tinyman
BASTION      = mohsen@coinbase
```

`idex` is not hard-coded to mean SERVER and `tinyman` is not hard-coded to mean CLIENT in the supported entrypoints. Change connectivity with switches rather than editing scripts.

### SSH topology

Fresh setup needs CONTROL HOST -> SERVER and CLIENT, plus SERVER -> CLIENT. If a bastion is used, CONTROL HOST must reach the bastion and the bastion must reach both nodes during public-key bootstrap. CLIENT -> SERVER is not required.

The final paper launcher only needs CONTROL HOST -> SERVER and SERVER -> CLIENT. Only the CONTROL HOST needs private-GitHub credentials; exact source commits are transferred to the experiment nodes by Git bundle.

A different Mac/control host is supported if it can fetch this private repository and has the required SSH route. Use `--bastion` and `--ssh-key` explicitly so the workflow does not depend on one person's `~/.ssh/config`.

The complete role/SSH description is in:

```text
results_analysis/README.md
tum_testbed_setup/README.md
results_analysis/configuration/experiment_paths.json
```

---

## Final paper configuration

P5 uses the optimized Performance2 V2 datapath with the exact marker:

```text
GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0
```

The final focused power-policy configuration is TOP3:

```text
PRESSURE_UP=450
RX_QUEUE_HIGH=48
ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16
FREQ_PERIOD_US=10000
```

The paper topology is single-DPDK-owner:

```text
ENABLE_MULTICORE=0
DPDK CPU=19
MsQuic worker CPUs=21,22,23,24
```

P5 OFF, BASIC and PLUS share the same optimized datapath. BASIC uses physical DPDK signals; PLUS adds QUIC semantic hints/guards. The Linux comparison is P7: an isolated normal-Linux MsQuic UDP build with DPDK/XDP disabled.

Machine-readable configuration:

```text
results_analysis/configuration/p5_paper_evaluation.json
results_analysis/configuration/p7_paper_evaluation.json
results_analysis/configuration/experiment_paths.json
```

---

## P5 and P7 binaries

On both experiment endpoints the repository is installed at `/root/mohsen`.

```text
P5 client: /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop
P5 server: /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinteropserver

P7 client: /root/mohsen/msquic/build-linux-p7/bin/Release/quicinterop
P7 server: /root/mohsen/msquic/build-linux-p7/bin/Release/quicinteropserver
```

`P5` and `P7` are internal experiment names, not QUIC versions. See `results_analysis/README.md` for the exact meaning, directories, build scripts, and start-state workflows.

---

# Quick reproduction entrypoints

## Fresh Debian nodes or Debian already installed but code/builds need provisioning

For POS allocation/image/reset, first follow `tum_testbed_setup/README.md`. POS commands are explicitly marked **RUN ON: Coinbase/POS shell**.

After Debian Trixie is reachable:

**RUN ON: CONTROL HOST** (paper-testbed example):

```bash
cd ~/Downloads/GreenQUIC-Plus && \
git fetch origin '+refs/heads/main:refs/remotes/origin/main' && \
git checkout main && \
git reset --hard refs/remotes/origin/main && \
python3 results_analysis/verify_paper_configuration.py && \
bash tum_testbed_setup/greenquic_fresh_setup.sh \
  --server-host idex \
  --client-host tinyman \
  --server-to-client-host tinyman \
  --bastion mohsen@coinbase \
  --ssh-key "$HOME/.ssh/id_ed25519"
```

Immediately use **a second CONTROL-HOST terminal** to monitor as shown in `tum_testbed_setup/README.md`.

If another deployment uses different host names, replace the switch values. If the CLIENT has a different name from the SERVER's network view, set `--server-to-client-host` separately.

## Machines already provisioned: run final paper evaluation

The authoritative launcher is:

```text
greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_p7_fair_repro_6x5.sh
```

The `_v2.sh` and `_v3.sh` files are compatibility wrappers only; they call the same authoritative implementation.

**RUN ON: CONTROL HOST** (paper-testbed example):

```bash
cd ~/Downloads/GreenQUIC-Plus && \
git fetch origin '+refs/heads/main:refs/remotes/origin/main' && \
git checkout main && \
git reset --hard refs/remotes/origin/main && \
python3 results_analysis/verify_paper_configuration.py && \
bash greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_p7_fair_repro_6x5.sh \
  --server-host idex \
  --client-host tinyman \
  --bastion mohsen@coinbase \
  --ssh-key "$HOME/.ssh/id_ed25519"
```

Immediately use **a second CONTROL-HOST terminal** for the live monitor in `results_analysis/README.md`.

The final launcher itself records the exact Git SHA, server/client role hosts, effective TOP3/P7 configuration, logs, and result ZIP paths.

---

## Results and supplied analysis material

`results_analysis/` contains the actual supplied tuning workbooks, `chart_v2.py`, SVG charts, their SHA-256 manifest/provenance, exact P5/P7 JSON configurations, result downloader, and reproducibility preflight.

**RUN ON: CONTROL HOST** to validate the repository's final configuration without contacting the testbed:

```bash
python3 results_analysis/verify_paper_configuration.py
```

**RUN ON: CONTROL HOST** to download the latest finished paper run from the selected SERVER role:

```bash
bash results_analysis/download_latest_reproduction.sh \
  --server-host idex \
  --bastion mohsen@coinbase \
  --ssh-key "$HOME/.ssh/id_ed25519"
```

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

Additional historical branches are kept for provenance. For collaborative work, use feature/fix branches and pull requests rather than changing the preserved historical branches.

---

## Scope

GreenQUIC+ is a research prototype for studying the performance/power tradeoff of QUIC over DPDK and the value of transport-aware information in CPU frequency/idle decisions. It is not a production power-management framework.
