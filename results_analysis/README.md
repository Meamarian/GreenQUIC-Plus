# GreenQUIC+ results, analysis, and paper reproduction

This directory is the evaluation/reproduction reference for **“Sleep Tight, QUIC Fast: Energy-Efficient QUIC with DPDK.”** It contains the final paper configuration, the original tuning workbooks and SVG/chart material, host-role documentation, result helpers, and the supported reproduction workflow.

---

# 1. Roles, management names, and SSH

The words **CONTROL HOST**, **SERVER**, **CLIENT**, and **BASTION** are roles, not fixed machine names.

| Role | Responsibility | Paper-testbed default |
|---|---|---|
| CONTROL HOST | Holds the private checkout; starts setup/build/test; downloads results | Mac |
| SERVER | Runs `quicinteropserver` and the experiment controller | `idex` |
| CLIENT | Runs `quicinterop`; started by SERVER over SSH | `tinyman` |
| BASTION | Optional SSH jump/bootstrap host | `mohsen@coinbase` |

Paper defaults are centralized in `paper_testbed_defaults.sh`:

```text
SERVER as seen from CONTROL: idex
CLIENT as seen from CONTROL: tinyman
CLIENT as seen from SERVER:  tinyman
BASTION:                     mohsen@coinbase
CONTROL SSH key:             $HOME/.ssh/id_ed25519
remote user:                 root
remote repository root:      /root/mohsen
branch:                      main
paper test NIC PCI:          0000:18:00.0
```

The high-level setup, rebuild, run, and live-monitor wrappers accept management switches. On our paper testbed zero arguments are required. On another deployment, use switches rather than editing source files.

Fresh setup/deployment requires:

```text
CONTROL -> BASTION        only when a bastion is used
BASTION -> SERVER         fresh-node public-key bootstrap
BASTION -> CLIENT         fresh-node public-key bootstrap
CONTROL -> SERVER         required
CONTROL -> CLIENT         required
SERVER  -> CLIENT         required
CLIENT  -> SERVER         not required
```

Final paper run after setup requires:

```text
CONTROL -> SERVER         required
SERVER  -> CLIENT         required
CONTROL -> CLIENT         not required by the final launcher
CLIENT  -> SERVER         not required
```

Only the CONTROL HOST needs credentials for the private GitHub repository. SERVER and CLIENT receive the exact `origin/main` commit through a Git bundle. The CONTROL private SSH key is never copied to the endpoints; setup installs only its public half and creates a separate SERVER key for SERVER -> CLIENT.

Management SSH names are separate from the QUIC/DPDK data-plane addresses (`192.168.100.1/24` and `192.168.100.2/24`).

---

# 2. What P5 and P7 mean

`P5` and `P7` are internal experiment names, not QUIC protocol versions.

## P5 — optimized DPDK MsQuic comparison

P5 is the repeated 8-GiB QUIC download experiment over the optimized DPDK MsQuic path. The same **Performance2 V2** datapath is used for OFF / MsQuic-DPDK, BASIC / GreenQUIC, and PLUS / GreenQUIC+.

On both SERVER and CLIENT:

```text
Experiment directory:
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads

Build script:
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/build_p5_performance2.sh

Build directory:
/root/mohsen/msquic/build-greenquic-p5

CLIENT binary:
/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop

SERVER binary:
/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinteropserver

DPDK install:
/root/mohsen/msquic/deps/dpdk-install
```

Required final marker:

```text
GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0
```

Final TOP3 policy/runtime values include:

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

## P7 — isolated normal-Linux MsQuic baseline

P7 is the matching repeated 8-GiB experiment using an isolated normal-Linux MsQuic UDP build.

On both SERVER and CLIENT:

```text
Experiment directory:
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline

Build script:
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline/build_p7_linux.sh

Isolated source:
/root/mohsen/msquic-p7-linux-source

Build directory:
/root/mohsen/msquic/build-linux-p7

CLIENT binary:
/root/mohsen/msquic/build-linux-p7/bin/Release/quicinterop

SERVER binary:
/root/mohsen/msquic/build-linux-p7/bin/Release/quicinteropserver
```

P7 is compiled with DPDK and XDP disabled and the builder verifies that the P7 binaries do not link DPDK. Final P7 settings include MTU 1500, UDP rmem/wmem `6815744`, one combined channel, RPS disabled, the test-NIC RDMA auxiliary child disabled during measurement, and the `paper` offload profile.

## Common final workload

```text
6 independent repetitions
5 sequential 8-GiB downloads per repetition
5 s inter-download gap
5 s pre/post edge cooldown
5 s between workloads/runs
seed 20260806
```

Machine-readable definitions:

```text
configuration/p5_paper_evaluation.json
configuration/p7_paper_evaluation.json
configuration/experiment_paths.json
```

---

# 3. Original analysis artifacts

The supplied analysis files are committed in the private repository:

```text
results_analysis/
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

The chart set contains **41 SVG files**. `artifact_files.sha256.json` stores the expected sizes/SHA-256 hashes for the supplied workbook/chart artifacts. `SOURCE_REFERENCE.txt` intentionally preserves the original archive names, including earlier intermediate runs; those names are provenance, not the definition of the final 6×5 paper experiment.

---

# 4. Choose the correct starting state

## State 0 — new CONTROL HOST / another Mac or Linux machine

Use this when SERVER/CLIENT may already exist but a new person or machine will launch the experiment.

**RUN ON: CONTROL HOST:** clone the private repository with that collaborator's normal GitHub authentication and enter the checkout. A local clone does not start a remote experiment, so there is no live test log to monitor.

```bash
git clone git@github.com:Meamarian/GreenQUIC-Plus.git && \
cd GreenQUIC-Plus
```

The CONTROL HOST needs `git`, `ssh`, `scp`, Python 3, private-repository access, access to the selected bastion when used, and the selected node SSH key. Do not copy the CONTROL private key to SERVER or CLIENT.

---

## State A — allocate/reimage fresh Debian nodes

Use this when the experiment nodes were reset, run another OS, or you want a clean live environment.

### A1. POS allocation/image/reset

**RUN ON: Coinbase/POS shell**, not on CONTROL, SERVER, or CLIENT.

Set the physical POS node names for the deployment. For our paper testbed:

```bash
SERVER_NODE=idex
CLIENT_NODE=tinyman
pos nodes list | grep -E "$SERVER_NODE|$CLIENT_NODE"
```

Allocate only nodes that are actually unallocated and according to the local POS policy. Do not free or replace another user's allocation.

After allocation, **RUN ON: Coinbase/POS shell:**

```bash
SERVER_NODE=idex
CLIENT_NODE=tinyman
pos nodes image "$SERVER_NODE" debian-trixie
pos nodes image "$CLIENT_NODE" debian-trixie
pos nodes reset "$SERVER_NODE" &
pos nodes reset "$CLIENT_NODE" &
wait
```

Immediately monitor from **another Coinbase/POS shell:**

```bash
SERVER_NODE=idex
CLIENT_NODE=tinyman
while true; do
  clear
  date
  pos nodes list | grep -E "$SERVER_NODE|$CLIENT_NODE"
  sleep 5
done
```

A POS reset destroys the live node filesystem. Treat `/root/mohsen`, build trees, generated payloads, and local experiment outputs on those nodes as gone.

When POS reports both nodes up, still **RUN ON: Coinbase/POS shell** to verify Debian/SSH readiness. This command is itself a live readiness monitor:

```bash
SERVER_NODE=idex
CLIENT_NODE=tinyman
for h in "$SERVER_NODE" "$CLIENT_NODE"; do
  until ssh -o ConnectTimeout=5 root@"$h" 'hostname; . /etc/os-release; echo "$ID $VERSION_CODENAME"'; do
    echo "waiting for $h ..."
    sleep 5
  done
done
```

### A2. Deploy, provision, and build

After both endpoints answer SSH as Debian Trixie:

**RUN ON: CONTROL HOST:**

```bash
bash results_analysis/setup_paper_testbed.sh
```

Immediately in **a second CONTROL-HOST terminal:**

```bash
bash results_analysis/live_monitor_setup.sh
```

Successful completion prints `GREENQUIC+ MAIN READY`.

---

## State B — Debian is installed; deploy current code and build everything

Use this when Debian Trixie and management SSH are already ready, but `/root/mohsen` is absent/stale or you want the newest exact `main` checkout and fresh P5/P7 builds.

Do **not** manually clone the private repository on SERVER or CLIENT. The supported setup keeps private GitHub credentials on CONTROL and deploys exact `origin/main` to both endpoints by Git bundle.

**RUN ON: CONTROL HOST:**

```bash
bash results_analysis/setup_paper_testbed.sh
```

Immediately in **a second CONTROL-HOST terminal:**

```bash
bash results_analysis/live_monitor_setup.sh
```

This is the supported “fresh clone/deploy + build” workflow for already-installed Debian nodes.

---

## State C — remote source/DPDK/host preparation are already exact; rebuild only P5/P7

Use this only if `/root/mohsen` on both endpoints is already the intended current `main` SHA and the host dependencies, hugepages and DPDK install are correct.

**RUN ON: CONTROL HOST:**

```bash
bash results_analysis/rebuild_paper_binaries.sh
```

Immediately in **a second CONTROL-HOST terminal:**

```bash
bash results_analysis/live_monitor_setup.sh
```

The rebuild helper refuses stale/different remote source. If code changed or remote state is uncertain, use State B instead.

---

## State D — everything is ready; run the final paper evaluation

The authoritative low-level implementation is:

```text
greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_p7_fair_repro_6x5.sh
```

The `_v2.sh` and `_v3.sh` names are compatibility wrappers only. For normal reproduction use the high-level wrapper:

**RUN ON: CONTROL HOST:**

```bash
bash results_analysis/run_paper_evaluation.sh
```

Immediately in **a second CONTROL-HOST terminal:**

```bash
bash results_analysis/live_monitor_run.sh
```

The launcher synchronizes exact `main`, rebuilds/verifies P5 and P7 before measured traffic, injects the final TOP3/P7 settings, runs P5 then P7, validates recorder evidence, writes `config.env`, and packages both result sets.

---

# 5. Another deployment / different management names

The high-level wrappers themselves accept switches; there is no need to edit scripts.

Example setup where CONTROL sees the client as `client-via-gateway` but SERVER reaches it as `10.0.0.22`:

**RUN ON: CONTROL HOST:**

```bash
bash results_analysis/setup_paper_testbed.sh \
  --server-host server01 \
  --client-host client-via-gateway \
  --server-to-client-host 10.0.0.22 \
  --bastion user@gateway \
  --ssh-key "$HOME/.ssh/lab_key"
```

Immediately in **a second CONTROL-HOST terminal:**

```bash
bash results_analysis/live_monitor_setup.sh \
  --server-host server01 \
  --client-host client-via-gateway \
  --bastion user@gateway \
  --ssh-key "$HOME/.ssh/lab_key"
```

After setup, the final run uses the CLIENT address as seen from SERVER:

**RUN ON: CONTROL HOST:**

```bash
bash results_analysis/run_paper_evaluation.sh \
  --server-host server01 \
  --client-host 10.0.0.22 \
  --bastion user@gateway \
  --ssh-key "$HOME/.ssh/lab_key"
```

Immediately in **a second CONTROL-HOST terminal:**

```bash
bash results_analysis/live_monitor_run.sh \
  --server-host server01 \
  --bastion user@gateway \
  --ssh-key "$HOME/.ssh/lab_key"
```

Changing management names does **not** automatically make different hardware equivalent to the paper testbed. The current paper configuration intentionally assumes root remote operation, `/root/mohsen`, E810 PCI `0000:18:00.0`, the recorded data-plane IP/MAC pair, CPU19/21-24 placement, and the paper hugepage configuration. Different hardware must adapt and revalidate those values explicitly.

---

# 6. Result locations and download

The SERVER role stores controller artifacts. For tag `<TAG>`:

```text
/root/GQ_FAIR_REPRO_<TAG>.log
/root/GQ_FAIR_REPRO_<TAG>/config.env
/root/GQ_FAIR_REPRO_<TAG>/RESULT_ZIPS.txt
/root/GQ_FAIR_REPRO_<TAG>/DONE
/root/GQ_FAIR_REPRO_<TAG>/FAILED

/root/P5_FAIR_OPT_PINNED_6r_5d_<TAG>.zip
/root/P7_FAIR_PAPER_PINNED_6r_5d_<TAG>.zip
```

`config.env` records the exact Git SHA, selected role endpoints, run shape, TOP3 values, and critical P7 settings.

**RUN ON: CONTROL HOST** after the run is `DONE`:

```bash
bash results_analysis/download_paper_results.sh
```

This is a short post-run transfer, not a running experiment. There is no live workload log after the run is already complete. While the experiment is still active, use `live_monitor_run.sh` from the second CONTROL-HOST terminal.

---

# 7. Static final checks

These checks run locally on CONTROL and do not launch remote processes, so no live experiment monitor applies.

Configuration consistency:

```bash
python3 results_analysis/verify_paper_configuration.py
```

Full repository/reproduction audit:

```bash
bash results_analysis/final_repository_check.sh
```

The full audit checks shell syntax for current P5/P7/setup/helper entrypoints, machine-readable JSON, the single TUM setup layout, absence of obsolete folders/temp files, host-role switches, README monitor pairing, safe CONTROL `main` synchronization, both XLSX files, `chart_v2.py`, all 41 SVGs, and the exact P5/P7 paper anchors.

See `HOST_ROLE_AUDIT.md` for the host-name/SSH dependency audit.
