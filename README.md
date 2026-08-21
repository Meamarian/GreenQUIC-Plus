# GreenQUIC+

## Sleep Tight, QUIC Fast: Energy-Efficient QUIC with DPDK

**Mohsen Memarian\*, Andreas Kassler\*†, Johannes Späth‡, Marcel Kempf‡, Stefan Lachnit‡, Johannes Zirngibl§, Georg Carle‡**

\* Karlstad University, Sweden  
† Deggendorf Institute of Technology, Germany  
‡ Technical University of Munich, Germany  
§ Max Planck Institute for Informatics, Germany

**Contact:** mohsen.memarian@kau.se, andreas.kassler@kau.se, spaethj@net.in.tum.de, kempfm@net.in.tum.de, lachnit@net.in.tum.de, jzirngib@mpi-inf.mpg.de, carle@net.in.tum.de

This private repository contains the implementation and reproducibility tooling accompanying the paper **“Sleep Tight, QUIC Fast: Energy-Efficient QUIC with DPDK.”** It is the independent continuation of the GreenQUIC paper code and is intended to be the active development repository for GreenQUIC+.

QUIC is commonly implemented in user space, which makes rapid protocol evolution possible but also places substantial packet-processing work on general-purpose CPU cores. DPDK can bypass the kernel networking stack and provide a high-speed userspace datapath, but its polling-oriented execution can consume unnecessary power when communication demand changes. GreenQUIC+ studies how a DPDK-based MsQuic implementation can adapt CPU frequency and idle behavior while retaining high QUIC goodput.

The implementation combines physical datapath information with QUIC transport information. The same DPDK/MsQuic datapath supports three runtime modes: `OFF` provides the reference datapath without GreenQUIC power decisions, `BASIC` uses only physical DPDK activity for power management, and `PLUS` extends the same physical policy with short-lived QUIC semantic hints. This makes the repository suitable both for evaluating the power-management mechanism itself and for comparing transport-unaware and transport-aware decisions under the same datapath implementation.

The DPDK/MsQuic context is closely related to the TUM kernel-bypass work documented in the public [`tumi8/quic-bypass-paper`](https://github.com/tumi8/quic-bypass-paper) artifact repository. That repository emphasizes reproducible QUIC kernel-bypass experiments, implementation/build scripts, data processing, measurement data, and evaluation scripts. GreenQUIC+ adds the adaptive power-management mechanism, its QUIC-aware extension, and the corresponding power/performance measurement workflow.

> Publication metadata and a final BibTeX entry can be added here once the paper venue/DOI information is finalized.

---

## Repository status and provenance

```text
Repository: Meamarian/GreenQUIC-Plus
Visibility: private
Default branch: main
```

The new repository was created from the final paper/reproduction branch of the original `Meamarian/GreenQUIC` repository:

```text
old repository: Meamarian/GreenQUIC
old branch:     performance2/p5-multicore
import SHA:     58d00a39270f512b6e9586704797dff6285e73b2
new repository: Meamarian/GreenQUIC-Plus
new branch:     main
```

So, **yes: `GreenQUIC-Plus/main` starts from the old `GreenQUIC/performance2/p5-multicore` paper line.** The import SHA above is kept as provenance. Subsequent commits on `GreenQUIC-Plus/main` update repository naming, documentation, setup safety, and GreenQUIC+ reproducibility paths without modifying the preserved old repository.

---

## Repository content

| Area | Purpose |
|---|---|
| `msquic/` | MsQuic + DPDK implementation used by GreenQUIC |
| `greenquic_test_suite_v22/` | repeatable P5/P7 experiments, recorders, reports, charts and validation |
| `tum_testbed_setup/` | fresh-Debian recovery and two-node TUM/LRZ setup for IDEX + Tinyman |
| `power_mng_tunning/` | power-management tuning/reproducibility material |
| `bootstrap_greenquic.sh` | host bootstrap and DPDK/NIC preparation |
| `acpi.sh` | ACPI/platform power sampling helper |
| `bind_nic.sh` | explicit NIC binding helper |

Generated experiment results, payloads, build trees and runtime logs are excluded from new commits by `.gitignore`.

---

## Runtime modes

The implementation exposes three runtime behaviors of the same DPDK/MsQuic datapath:

| Mode | Role |
|---|---|
| `OFF` | DPDK baseline without GreenQUIC power-management decisions |
| `BASIC` / GreenQUIC | datapath-aware CPU frequency and idle control using physical DPDK signals |
| `PLUS` / GreenQUIC+ | BASIC plus short-lived QUIC transport hints and locality information |

The physical policy observes signals such as RX/TX burst occupancy, RX NIC queue backlog, TX software-ring backlog, recent activity and persistent empty polling. GreenQUIC+ keeps this physical policy and adds transport information such as ACK readiness and CUBIC state so that a temporarily quiet datapath is not automatically treated as unimportant work.

Main implementation locations:

| Area | Location |
|---|---|
| GreenQUIC datapath tracking, pressure calculation, DVFS and idle policy | `msquic/src/platform/datapath_raw_dpdk.c` |
| GreenQUIC+ hint API | `msquic/src/inc/greenquic_plus.h` |
| GreenQUIC+ hint storage/runtime mapping | `msquic/src/platform/greenquic_plus.c` |
| ACK-ready hook | `msquic/src/core/ack_tracker.c` |
| CUBIC recovery/ramping/blocked hooks | `msquic/src/core/cubic.c` |

The mode is selected through configuration:

```ini
GreenQuicMode=off
```

```ini
GreenQuicMode=basic
```

```ini
GreenQuicMode=plus
```

`BASIC` and `PLUS` share the physical datapath policy. `PLUS` additionally consumes QUIC semantic information and PLUS-only protection logic.

---

## Final paper datapath used by `main`

Although the historical source branch was named `performance2/p5-multicore`, the final fair paper configuration uses **one DPDK owner core** and the optimized Performance2 V2 datapath.

The build is verified with this exact marker:

```text
GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0
```

The fair P5 launcher uses:

```text
ENABLE_MULTICORE=0
DPDK CPU: 19
QUIC CPUs: 21,22,23,24
```

The corresponding comparison is the isolated P7 normal-Linux MsQuic path.

---

## Mac checkout

Keep the preserved original repository and the new repository in separate directories:

```text
~/Downloads/GreenQUIC       # old repository, preserved
~/Downloads/GreenQUIC-Plus  # new private GreenQUIC+ repository
```

For GreenQUIC+ work:

```bash
cd ~/Downloads/GreenQUIC-Plus && \
git fetch origin main && \
git checkout main && \
git reset --hard origin/main
```

Verify before making changes:

```bash
git remote -v
git branch --show-current
git rev-parse HEAD
```

Expected remote:

```text
git@github.com:Meamarian/GreenQUIC-Plus.git
```

Expected branch:

```text
main
```

---

## Fresh TUM Debian setup

The authoritative setup guide is:

```text
tum_testbed_setup/README.md
```

If IDEX and Tinyman have been reimaged with fresh Debian Trixie, first complete the POS/Coinbase image/reset step and wait until both nodes are reachable by SSH. Then run from the Mac:

```bash
cd ~/Downloads/GreenQUIC-Plus && \
git fetch origin main && \
git checkout main && \
git reset --hard origin/main && \
bash tum_testbed_setup/greenquic_fresh_setup_branch.sh main
```

`paper` is an alias for the same GreenQUIC+ `main` setup:

```bash
bash tum_testbed_setup/greenquic_fresh_setup_branch.sh paper
```

The supported setup path prepares the private repository checkout, Mac → IDEX/Tinyman SSH, IDEX → Tinyman SSH, ICE/E810 firmware, hugepages, MSR/P-state support, the direct physical link, DPDK binding, P0/P4/P5/P7 dependencies and binaries, and finally installs the exact current `origin/main` SHA on both endpoints using a Git bundle.

Do **not** run `tum_testbed_setup/greenquic_fresh_setup_base.sh` directly. It is preserved internal setup code. The public wrapper applies the GreenQUIC+ private-repository path and fresh-boot safety fixes before executing it.

### Setup monitor from another Mac terminal

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

Successful setup ends with:

```text
GREENQUIC+ MAIN READY ON BOTH TUM NODES
```

---

## Final fair P5/P7 reproduction

After the TUM setup is ready, run the final fair reproduction from the Mac:

```bash
cd ~/Downloads/GreenQUIC-Plus && \
git fetch origin main && \
git checkout main && \
git reset --hard origin/main && \
bash greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_p7_fair_repro_6x5_v3.sh
```

The default experiment is **6 runs × 5 downloads**. The launcher resolves the exact `origin/main` SHA, creates an exact-SHA Git bundle, synchronizes both remote hosts, rebuilds and verifies the final P5 Performance2 V2 configuration, runs the fair P5 test and isolated P7 Linux baseline, and records the exact tag, commit and result paths.

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

Always prefer the exact `REMOTE_LOG` path printed by the launcher for the current run.

---

## Measurement and evaluation infrastructure

The experiment framework can collect and organize:

- active-transfer and gap timing,
- QUIC goodput,
- RAPL package/DRAM energy,
- ACPI/platform power where available,
- CPU-frequency traces,
- CPU-idle residency,
- GreenQUIC frequency/sleep/policy telemetry,
- client/server metadata and validation artifacts,
- generated spreadsheets and charts.

Unlike the public TUM kernel-bypass artifact repository, this private GreenQUIC+ repository does not currently publish a separate raw-data archive or a one-command public artifact download. The focus here is the implementation and the controlled TUM testbed reproduction workflow. If a public artifact package or Zenodo dataset is prepared later, its DOI and evaluation instructions should be added here.

---

## Branch model and collaboration

`main` is the stable GreenQUIC+ paper/development baseline. The original `GreenQUIC` repository remains untouched.

Recommended branch classes:

```text
main                         stable GreenQUIC+ paper/development baseline
paper/original-p5-multicore exact imported old paper snapshot
 development                 integration work before main
research/power-management    power-policy experiments
research/dpdk-performance    datapath/performance experiments
feature/<name>               focused implementation changes
fix/<name>                   bug fixes
```

For collaboration, invite collaborators to the private repository and use branches/pull requests rather than giving everyone a separate copy of the old GreenQUIC repository.

---

## Contact

For questions about GreenQUIC+, the paper, or the experiment artifacts, contact:

**Mohsen Memarian** — mohsen.memarian@kau.se

Additional author contacts are listed at the top of this README.

---

## Scope

GreenQUIC+ is a research prototype, not a production power-management framework. It studies the performance/power tradeoff of QUIC over DPDK and how transport-aware information can improve CPU frequency and idle decisions without unnecessarily reducing responsiveness.
