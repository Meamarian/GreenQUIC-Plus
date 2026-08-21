# GreenQUIC+ results, analysis, and paper reproduction

This directory is the evaluation and reproduction reference for **“Sleep Tight, QUIC Fast: Energy-Efficient QUIC with DPDK.”** It contains the final paper configuration, supplied tuning workbooks and SVG/chart material, dependency/version records, high-level setup/run/download helpers, and the final repository audit.

# Roles and command locations

Roles are semantic; host names are not.

```text
CONTROL HOST  machine holding the private GreenQUIC+ checkout and launching work
SERVER        QUIC server + experiment controller
CLIENT        QUIC client
BASTION       optional SSH jump/bootstrap host
```

Our paper-testbed defaults are centralized in `results_analysis/paper_testbed_defaults.sh`:

```text
CONTROL checkout:       $HOME/Downloads/GreenQUIC-Plus on our Mac
SERVER:                 idex
CLIENT from CONTROL:    tinyman
CLIENT from SERVER:     tinyman
BASTION:                mohsen@coinbase
CONTROL SSH key:        $HOME/.ssh/id_ed25519
remote user:            root
remote repository root: /root/mohsen
```

`idex` does not mean SERVER in the code and `tinyman` does not mean CLIENT. Another deployment supplies its own values through `--server-host`, `--client-host`, `--server-to-client-host`, `--bastion`, and `--ssh-key` as applicable.

Every operational command below says **RUN ON**. A path beginning with `/root/...` belongs to an experiment node. Do not execute a block that expects `/root/...` directly from a CONTROL-HOST shell.

## SSH topology

Fresh setup/deployment:

```text
CONTROL -> BASTION        only when a bastion is used
BASTION -> SERVER         fresh-node public-key bootstrap
BASTION -> CLIENT         fresh-node public-key bootstrap
CONTROL -> SERVER         required
CONTROL -> CLIENT         required
SERVER  -> CLIENT         required
CLIENT  -> SERVER         not required
```

Final paper run after provisioning:

```text
CONTROL -> SERVER         required
SERVER  -> CLIENT         required
CONTROL -> CLIENT         not required by final launcher
CLIENT  -> SERVER         not required
```

Only CONTROL needs private-GitHub credentials. The exact `origin/main` source is transferred to SERVER and CLIENT by Git bundle.

# What P5 and P7 mean

`P5` and `P7` are experiment names, not QUIC protocol versions.

**P5** is the repeated 8-GiB QUIC download experiment over the optimized DPDK MsQuic path. OFF, BASIC/GreenQUIC, and PLUS/GreenQUIC+ use the same Performance2 V2 datapath.

**P7** is the matching repeated 8-GiB experiment over an isolated normal-Linux MsQuic UDP build with DPDK and XDP disabled.

Final workload:

```text
6 independent repetitions
5 sequential 8-GiB downloads per repetition
5 s inter-download gap
5 s edge cooldown
5 s between workloads/runs
seed 20260806
```

Final P5 marker:

```text
GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0
```

Final TOP3 values:

```text
PRESSURE_UP=450
RX_QUEUE_HIGH=48
ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16
FREQ_PERIOD_US=10000
GQ_IDLE_MODE_OVERRIDE=monitor
GQ_IDLE_FALLBACK_OVERRIDE=short
ENABLE_MULTICORE=0
DPDK CPU=19
MsQuic CPUs=21,22,23,24
```

# Exact remote paths and binaries

On SERVER and CLIENT after setup:

```text
Repository root:
/root/mohsen

P5 directory:
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads

P5 build script:
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/build_p5_performance2.sh

P5 client:
/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop

P5 server:
/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinteropserver

P7 directory:
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline

P7 build script:
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline/build_p7_linux.sh

P7 isolated source:
/root/mohsen/msquic-p7-linux-source

P7 client:
/root/mohsen/msquic/build-linux-p7/bin/Release/quicinterop

P7 server:
/root/mohsen/msquic/build-linux-p7/bin/Release/quicinteropserver
```

# Dependencies

The exact modified source is fixed by the GreenQUIC+ Git SHA. The current tree records MsQuic source version `2.4.8` and vendored DPDK `21.11.9`. P5/P7 use OpenSSL and Release builds.

SERVER and CLIENT must run Debian Trixie. Exact Debian package revisions and the kernel patch level are resolved from the configured Trixie repositories at setup time and are not individually pinned.

Paper hardware assumptions include Intel E810 at PCI `0000:18:00.0`, Linux `ice` for link/P7 operation, `igb_uio` or `vfio-pci` for DPDK, `16384 × 2 MiB` hugepages, CPU19 for dataplane work, and CPUs21-24 for MsQuic workers.

Machine-readable dependency policy: `results_analysis/configuration/dependencies.json`.

# Original analysis artifacts

The private repository contains the supplied artifacts directly:

```text
results_analysis/
├── configuration/
├── tuning/
│   ├── GreenQUIC_DPDK_Path_Perf_Tunning_v2.xlsx
│   ├── GreenQUIC_Power_Mng_Tuning_v1.xlsx
│   ├── README.md
│   └── summary.json
├── charts/
│   ├── chart_v2.py
│   ├── SOURCE_REFERENCE.txt
│   ├── manifest.json
│   └── svg/
│       ├── timeseries/
│       ├── with_values/
│       └── without_values/
└── artifact_files.sha256.json
```

The expected supplied set is two XLSX workbooks, `chart_v2.py`, and 41 SVG files. `artifact_files.sha256.json` records expected sizes/SHA-256 values. `SOURCE_REFERENCE.txt` preserves original archive names as provenance and does not redefine the final 6×5 experiment.

# Reproduction workflow

## Case A — physical nodes need fresh Debian Trixie

POS allocation/reimage/reset is separate from GreenQUIC+ setup. Follow `tum_testbed_setup/README.md` first. POS commands are **RUN ON: COINBASE/POS SHELL** and have their own live readiness/status monitor.

After both nodes answer SSH as Debian Trixie, continue with Case B.

## Case B — Debian is ready; deploy exact current `main`, prepare hosts, and build everything

This is also the supported “fresh clone/deploy + build” case when `/root/mohsen` is absent or stale.

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

**LIVE MONITOR — RUN ON: second CONTROL-HOST terminal immediately after starting setup:**

```bash
cd "$HOME/Downloads/GreenQUIC-Plus" && \
bash results_analysis/live_monitor_setup.sh
```

The high-level setup wrapper safely synchronizes a clean CONTROL `main`, statically verifies paper configuration, records a CONTROL-side setup log, runs the single TUM provisioning implementation, and records effective dependency versions. It transfers exact `origin/main` to SERVER/CLIENT by Git bundle; do not manually clone the private repository on experiment nodes.

For another management topology, `setup_paper_testbed.sh` accepts:

```text
--server-host HOST
--client-host HOST
--server-to-client-host HOST
--bastion USER@HOST|none
--ssh-key PATH
```

Use matching route values with `live_monitor_setup.sh` when desired.

## Case C — remote source/DPDK/host state is already correct; rebuild only P5/P7

Use this only when `/root/mohsen`, dependencies, hugepages, DPDK, NIC support, and SSH are already correct and current. If source may be stale, use Case B.

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

**LIVE MONITOR — RUN ON: second CONTROL-HOST terminal:**

```bash
cd "$HOME/Downloads/GreenQUIC-Plus" && \
bash results_analysis/live_monitor_setup.sh
```

## Case D — everything is ready; run the final paper evaluation

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

**LIVE MONITOR — RUN ON: second CONTROL-HOST terminal immediately after launch:**

```bash
cd "$HOME/Downloads/GreenQUIC-Plus" && \
bash results_analysis/live_monitor_run.sh
```

`run_paper_evaluation.sh` safely synchronizes CONTROL `main`, records the exact tag, and calls the single authoritative combined launcher. The monitor follows that exact tag instead of guessing the newest log.

For another deployment, the run wrapper accepts `--server-host`, `--client-host`, `--bastion`, and `--ssh-key`. Here `--client-host` is the CLIENT endpoint as seen from SERVER.

The authoritative low-level implementation is:

```text
greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_p7_fair_repro_6x5.sh
```

The `_v2.sh` and `_v3.sh` names are compatibility wrappers only.

# Results: do not manually package `/root` from the CONTROL HOST

The SERVER role stores controller/result artifacts. For tag `<TAG>`:

```text
/root/GQ_FAIR_REPRO_<TAG>.log
/root/GQ_FAIR_REPRO_<TAG>/config.env
/root/GQ_FAIR_REPRO_<TAG>/RESULT_ZIPS.txt
/root/GQ_FAIR_REPRO_<TAG>/DONE
/root/GQ_FAIR_REPRO_<TAG>/FAILED

/root/P5_FAIR_OPT_PINNED_6r_5d_<TAG>.zip
/root/P7_FAIR_PAPER_PINNED_6r_5d_<TAG>.zip
```

The P5/P7 ZIPs contain the complete matrix result trees, including recorder/affinity evidence saved under those trees. Separate `P5_AFFINITY_SERVER_*.tar.gz` or `P5_AFFINITY_CLIENT_*.tar.gz` packaging is not part of the supported final workflow.

A CONTROL-HOST prompt such as `... GreenQUIC-Plus %` cannot directly access `/root/GQ_FAIR_REPRO_*`, `/root/mohsen/...`, or `/root/...tar.gz`; those are SERVER paths. If you see `ls: /root/... No such file or directory` together with a CONTROL-HOST prompt, the command was run on the wrong machine.

After the final run is marked DONE, use the downloader.

**RUN ON: CONTROL HOST:**

```bash
cd "$HOME/Downloads/GreenQUIC-Plus" && \
bash results_analysis/download_paper_results.sh
```

This is synchronous and prints each copied artifact plus paper-configuration verification. If you want a live view while copying, **RUN ON: second CONTROL-HOST terminal:**

```bash
cd "$HOME/Downloads/GreenQUIC-Plus" && \
bash results_analysis/live_monitor_run.sh
```

The downloader copies `config.env`, `RESULT_ZIPS.txt`, `DONE`, the two result ZIPs, and the controller log into `reproduced_results/<TAG>/` and verifies the critical P5/P7 settings.

# Static final repository check

Before a release/reproduction handoff, use the repository audit.

**RUN ON: CONTROL HOST:**

```bash
cd "$HOME/Downloads/GreenQUIC-Plus" && \
bash results_analysis/final_repository_check.sh
```

This is an immediate local/static check; it starts no experiment, so no remote live log applies. It validates shell/Python/JSON syntax, repository cleanup/layout, committed analysis artifacts, source/dependency anchors, role-based routing, safe CONTROL-main synchronization, setup/run wrappers/monitors, current README requirements, and final P5/P7 configuration anchors.

For TUM/POS provisioning details, see `tum_testbed_setup/README.md`.
