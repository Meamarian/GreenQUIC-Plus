# GreenQUIC+

## Sleep Tight, QUIC Fast: Energy-Efficient QUIC with DPDK

**Mohsen Memarian\*, Andreas Kassler\*†, Johannes Späth‡, Marcel Kempf‡, Stefan Lachnit‡, Johannes Zirngibl§, Georg Carle‡**

\* Karlstad University, Sweden  
† Deggendorf Institute of Technology, Germany  
‡ Technical University of Munich, Germany  
§ Max Planck Institute for Informatics, Germany

**Contact:** mohsen.memarian@kau.se, andreas.kassler@kau.se, spaethj@net.in.tum.de, kempfm@net.in.tum.de, lachnit@net.in.tum.de, jzirngib@mpi-inf.mpg.de, carle@net.in.tum.de

This private repository contains the implementation and reproducibility tooling accompanying the paper **“Sleep Tight, QUIC Fast: Energy-Efficient QUIC with DPDK.”** It is the active development repository for GreenQUIC+.

QUIC is commonly implemented in user space. DPDK provides a high-speed kernel-bypass datapath, but polling-oriented execution can consume unnecessary power when workload demand changes. GreenQUIC+ studies adaptive CPU power management for a DPDK-based MsQuic implementation by controlling CPU frequency and idle behavior while maintaining high QUIC goodput.

The implementation exposes three runtime modes on the same DPDK/MsQuic datapath: `OFF` is the DPDK reference without GreenQUIC power-management decisions, `BASIC` / GreenQUIC uses physical datapath activity, and `PLUS` / GreenQUIC+ extends the same physical policy with short-lived QUIC transport information. This allows transport-unaware and transport-aware policies to be evaluated without changing the underlying datapath implementation between those modes.

The DPDK/MsQuic context is closely related to the TUM kernel-bypass work documented in the public [`tumi8/quic-bypass-paper`](https://github.com/tumi8/quic-bypass-paper) artifact repository. GreenQUIC+ adds the adaptive power-management mechanism, its QUIC-aware extension, and the corresponding power/performance measurement workflow.

> Publication metadata and a final BibTeX entry can be added once the venue/DOI information is finalized.

---

## Repository status and provenance

```text
Repository: Meamarian/GreenQUIC-Plus
Visibility: private
Default branch: main
```

`GreenQUIC-Plus/main` was created from the final paper/reproduction line of the original repository:

```text
old repository: Meamarian/GreenQUIC
old branch:     performance2/p5-multicore
import SHA:     58d00a39270f512b6e9586704797dff6285e73b2
new repository: Meamarian/GreenQUIC-Plus
new branch:     main
```

The old repository remains separate. The imported snapshot is also preserved as `paper/original-p5-multicore`. Current GreenQUIC+ work should use `main` or a branch created from `main`.

---

## Current repository layout

The `main` branch intentionally keeps only the current paper/development path at the repository root:

| Area | Purpose |
|---|---|
| `msquic/` | MsQuic + DPDK source used by GreenQUIC+ |
| `greenquic_test_suite_v22/` | authoritative experiment, build, recorder, report, and validation suite |
| `results_analysis/` | paper-evaluation configurations, tuning summaries, chart provenance, and analysis material |
| `tum_testbed_setup/` | one fresh-Debian TUM/LRZ setup entrypoint and its guide |
| `acpi.sh` | ACPI/platform power helper retained at repository root |
| `msr.py` | MSR helper retained at repository root |

The older `greenquic_test_suite/` tree, historical root bootstrap/autopatch scripts, root patch bundles, and versioned TUM setup wrappers were removed from `main` after verifying that the final paper path uses `greenquic_test_suite_v22/`. They remain recoverable from Git history and the preserved historical branches.

The former top-level `power_mng_tunning/` folder has also been removed. Its useful reviewed information is consolidated under `results_analysis/tuning/`, while the exact final paper-evaluation configuration is under `results_analysis/configuration/`.

Generated runtime results, payloads, build trees, and logs are excluded from new commits by `.gitignore`.

---

## Runtime modes

| Mode | Role |
|---|---|
| `OFF` | DPDK baseline without GreenQUIC power-management decisions |
| `BASIC` / GreenQUIC | datapath-aware CPU frequency and idle control using physical DPDK signals |
| `PLUS` / GreenQUIC+ | BASIC plus short-lived QUIC transport hints and PLUS-specific guards |

The physical policy observes signals such as RX/TX burst occupancy, RX NIC queue backlog, TX software-ring backlog, recent activity, and persistent empty polling. GreenQUIC+ keeps that physical policy and adds transport information including ACK readiness and CUBIC state.

Main implementation locations:

| Area | Location |
|---|---|
| GreenQUIC datapath tracking, pressure, DVFS, and idle policy | `msquic/src/platform/datapath_raw_dpdk.c` |
| GreenQUIC+ hint API | `msquic/src/inc/greenquic_plus.h` |
| GreenQUIC+ hint storage/runtime mapping | `msquic/src/platform/greenquic_plus.c` |
| ACK-ready hook | `msquic/src/core/ack_tracker.c` |
| CUBIC recovery/ramping/blocked hooks | `msquic/src/core/cubic.c` |

Runtime mode is selected through configuration as `off`, `basic`, or `plus`.

---

## Final paper datapath and configuration

Although the historical source branch was named `performance2/p5-multicore`, the final paper configuration is **single-DPDK-owner** and uses the optimized Performance2 V2 datapath.

The P5 build is verified with this exact marker:

```text
GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0
```

The final focused paper power-policy configuration is **TOP3**:

```text
PRESSURE_UP=450
RX_QUEUE_HIGH=48
ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16
```

The paper evaluation uses CPU19 as the single DPDK owner and CPUs21-24 as MsQuic workers. OFF, BASIC, and PLUS run on the same optimized datapath. BASIC consumes only the physical policy; PLUS adds QUIC semantic hints and PLUS-specific guards. `ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16` is PLUS-only; the two physical TOP3 settings apply to BASIC and PLUS.

The Linux comparison is the isolated P7 normal-Linux MsQuic path with the final paper network/CPU settings.

**Authoritative machine-readable paper configuration:**

```text
results_analysis/configuration/p5_paper_evaluation.json
results_analysis/configuration/p7_paper_evaluation.json
```

A readable explanation is in `results_analysis/configuration/README.md`. These files describe the paper evaluation, **not** TUM fresh-node provisioning.

---

## Paper results and analysis

`results_analysis/` is organized as:

```text
results_analysis/
├── README.md
├── configuration/
│   ├── README.md
│   ├── p5_paper_evaluation.json
│   └── p7_paper_evaluation.json
├── tuning/
│   ├── README.md
│   └── summary.json
└── charts/
    ├── README.md
    ├── SOURCE_REFERENCE.txt
    └── manifest.json
```

The tuning summaries are derived from the reviewed power-management and DPDK-path tuning workbooks. `charts/SOURCE_REFERENCE.txt` preserves the source mapping from the attached paper chart bundle. Some chart references intentionally retain older archive names; the `configuration/` JSON files are the final 6×5 configuration reference.

---

## Mac checkout

Keep the original and new repositories separate:

```text
~/Downloads/GreenQUIC       # preserved original repository
~/Downloads/GreenQUIC-Plus  # active private GreenQUIC+ repository
```

Update GreenQUIC+ `main`:

```bash
cd ~/Downloads/GreenQUIC-Plus && \
git fetch origin main && \
git checkout main && \
git reset --hard origin/main
```

Expected remote and branch:

```text
git@github.com:Meamarian/GreenQUIC-Plus.git
main
```

---

## Fresh TUM Debian setup

The setup guide is:

```text
tum_testbed_setup/README.md
```

After IDEX and Tinyman are reimaged with **Debian Trixie** and are reachable through Coinbase, run exactly one setup script from the Mac:

```bash
cd ~/Downloads/GreenQUIC-Plus && \
git fetch origin main && \
git checkout main && \
git reset --hard origin/main && \
bash tum_testbed_setup/greenquic_fresh_setup.sh
```

The setup resolves the exact `origin/main` SHA, synchronizes that exact commit to both nodes with a Git bundle, installs/checks dependencies, prepares ICE/E810 firmware, MSR/P-state support, hugepages and the DPDK build, verifies the physical direct link before DPDK binding, builds the final P5 Performance2 V2 binaries and isolated P7 Linux binaries on both nodes, and installs `/root/run_p5.sh` and `/root/run_p7.sh` on IDEX.

Successful setup ends with:

```text
GREENQUIC+ MAIN READY ON BOTH TUM NODES
```

The setup is machine provisioning. It is deliberately separate from the paper-evaluation configuration recorded in `results_analysis/configuration/`.

### Live setup monitor from another Mac terminal

```bash
while true; do
  clear
  date
  echo
  ssh -J mohsen@coinbase root@idex \
    'echo "===== IDEX ====="; hostname; git -C /root/mohsen branch --show-current 2>/dev/null || true; git -C /root/mohsen rev-parse --short HEAD 2>/dev/null || true'
  echo
  ssh -J mohsen@coinbase root@tinyman \
    'echo "===== TINYMAN ====="; hostname; git -C /root/mohsen branch --show-current 2>/dev/null || true; git -C /root/mohsen rev-parse --short HEAD 2>/dev/null || true'
  sleep 10
done
```

---

## Final fair P5/P7 reproduction

After setup succeeds, launch the fair reproduction from the Mac:

```bash
cd ~/Downloads/GreenQUIC-Plus && \
git fetch origin main && \
git checkout main && \
git reset --hard origin/main && \
bash greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_p7_fair_repro_6x5_v3.sh
```

The default experiment is **6 runs × 5 downloads**. The launcher synchronizes the exact main SHA to both nodes, rebuilds/verifies the final P5 and P7 binaries, runs P5 OFF/BASIC/PLUS and the isolated P7 Linux comparison, and records the exact tag, commit, logs, and result paths.

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

Prefer the exact `REMOTE_LOG` path printed by the launcher for the current run.

---

## Measurement and evaluation infrastructure

The v22 experiment framework records and organizes active/gap timing, QUIC goodput, RAPL package/DRAM energy, ACPI/platform power where available, CPU-frequency traces, CPU-idle residency, GreenQUIC policy telemetry, client/server metadata, validation artifacts, spreadsheets, and charts.

The repository does not currently publish a separate public raw-data archive. If a public artifact package or Zenodo dataset is prepared later, add its DOI and evaluation instructions here.

---

## Branch model and collaboration

`main` is the stable GreenQUIC+ paper/development baseline. Historical branches retain older experimental lines without cluttering `main`.

```text
main                         current paper/development baseline
paper/original-p5-multicore exact imported paper snapshot
development                  integration work before main
research/power-management    power-policy experiments
research/dpdk-performance    datapath/performance experiments
performance2/p5-max-goodput  preserved Performance2 tuning line
performance2/p5-multicore    preserved original paper branch name
feature/<name>               focused implementation work
fix/<name>                   bug fixes
```

For collaboration, invite collaborators to this private repository and use branches/pull requests.

---

## Contact

For questions about GreenQUIC+, the paper, or the experiment artifacts:

**Mohsen Memarian** — mohsen.memarian@kau.se

Additional author contacts are listed at the top of this README.

---

## Scope

GreenQUIC+ is a research prototype, not a production power-management framework. It studies the performance/power tradeoff of QUIC over DPDK and how transport-aware information can improve CPU frequency and idle decisions without unnecessarily reducing responsiveness.
