# GreenQUIC+ results, analysis, and paper reproduction

This directory is the evaluation/reproduction reference for **“Sleep Tight, QUIC Fast: Energy-Efficient QUIC with DPDK.”** It contains the final paper configuration, original tuning workbooks, chart-generation code/SVGs, result download helpers, host-role audit, and the supported reproduction workflow.

---

# 1. Roles and defaults

The words **CONTROL HOST**, **SERVER**, **CLIENT**, and **BASTION** are roles. They are not fixed machine names.

| Role | Responsibility | Our paper-testbed default |
|---|---|---|
| CONTROL HOST | Holds the private checkout; starts setup/build/test; downloads results | Mac |
| SERVER | QUIC server + experiment controller | `idex` |
| CLIENT | QUIC client | `tinyman` |
| BASTION | Optional SSH jump/bootstrap host | `mohsen@coinbase` |

The paper defaults are centralized in `paper_testbed_defaults.sh`:

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

On our paper testbed, the high-level wrappers therefore need **no host, bastion, key, branch, binary-path, run-count, or workload arguments**.

A different deployment can override the `GQ_*` environment variables in `paper_testbed_defaults.sh` or call the underlying setup/launcher with explicit switches. Do not edit the scripts just to change a host name.

## SSH topology

Fresh setup/deployment:

```text
CONTROL -> BASTION        required only if a bastion is used
BASTION -> SERVER         required for fresh-node public-key bootstrap
BASTION -> CLIENT         required for fresh-node public-key bootstrap
CONTROL -> SERVER         required
CONTROL -> CLIENT         required
SERVER  -> CLIENT         required
CLIENT  -> SERVER         NOT required
```

Final paper run after setup:

```text
CONTROL -> SERVER         required
SERVER  -> CLIENT         required
CONTROL -> CLIENT         not required by the final launcher
CLIENT  -> SERVER         not required
```

Only the CONTROL HOST needs private-GitHub credentials. SERVER and CLIENT receive the exact `origin/main` commit through a Git bundle.

If the CLIENT has a different management name/address from CONTROL and SERVER, set them separately:

```text
GQ_CLIENT_HOST=<client as CONTROL/BASTION sees it>
GQ_SERVER_TO_CLIENT_HOST=<client as SERVER sees it>
```

The QUIC/DPDK data-plane addresses (`192.168.100.1/24` and `192.168.100.2/24`) are separate from these SSH names.

---

# 2. What P5 and P7 mean

`P5` and `P7` are internal experiment names, not QUIC protocol versions.

## P5

P5 is the repeated 8-GiB QUIC download experiment over the optimized DPDK MsQuic path. The same **Performance2 V2** datapath is used for:

- OFF / MsQuic-DPDK
- BASIC / GreenQUIC
- PLUS / GreenQUIC+

Remote experiment directory on both endpoints:

```text
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads
```

Build script:

```text
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/build_p5_performance2.sh
```

Binaries:

```text
CLIENT: /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop
SERVER: /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinteropserver
```

Required final binary marker:

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

Paper topology:

```text
ENABLE_MULTICORE=0
DPDK CPU=19
MsQuic CPUs=21,22,23,24
```

## P7

P7 is the matching repeated 8-GiB experiment using an isolated normal-Linux MsQuic UDP build.

Remote experiment directory:

```text
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline
```

Build script:

```text
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline/build_p7_linux.sh
```

Isolated source/build:

```text
/root/mohsen/msquic-p7-linux-source
/root/mohsen/msquic/build-linux-p7
```

Binaries:

```text
CLIENT: /root/mohsen/msquic/build-linux-p7/bin/Release/quicinterop
SERVER: /root/mohsen/msquic/build-linux-p7/bin/Release/quicinteropserver
```

P7 is built with DPDK and XDP disabled. The build checks that the P7 binaries do not link DPDK.

Final P7 paper network settings include MTU 1500, UDP rmem/wmem 6815744, one combined channel, RPS disabled, test-NIC RDMA auxiliary child disabled during measurement, and the `paper` NIC offload profile.

## Common final workload

```text
6 independent repetitions
5 sequential 8-GiB downloads per repetition
5 s inter-download gap
5 s pre/post edge cooldown
5 s between workloads/runs
seed 20260806
```

Machine-readable details:

```text
configuration/p5_paper_evaluation.json
configuration/p7_paper_evaluation.json
configuration/experiment_paths.json
```

---

# 3. Original analysis artifacts stored in the repository

The original supplied files are committed under this directory.

```text
results_analysis/
├── tuning/
│   ├── GreenQUIC_DPDK_Path_Perf_Tunning_v2.xlsx
│   ├── GreenQUIC_Power_Mng_Tuning_v1.xlsx
│   ├── README.md
│   └── summary.json
│
├── charts/
│   ├── chart_v2.py
│   ├── SOURCE_REFERENCE.txt
│   ├── manifest.json
│   └── svg/
│       ├── timeseries/
│       ├── with_values/
│       └── without_values/
│
└── artifact_files.sha256.json
```

The imported chart set contains **41 SVG files**. `artifact_files.sha256.json` stores the expected sizes/SHA-256 hashes of the supplied workbook/chart files. `import_attached_artifacts.py` is retained for re-verification/import if the original ZIPs are supplied again.

The chart `SOURCE_REFERENCE.txt` intentionally preserves original archive names. Some are from earlier intermediate runs and are provenance, not the definition of the final 6×5 paper experiment.

---

# 4. Choose the correct starting state

## State 0 — new CONTROL HOST / different Mac

Use this when the experiment nodes may already be ready, but the person launching the experiment has a new Mac/Linux control machine.

**RUN ON: CONTROL HOST.** Clone the private repository using the collaborator's normal GitHub authentication, then enter the checkout. This is a local Git operation, so there is no remote experiment log to monitor.

After cloning, the default wrappers use that checkout automatically. The control host must have `git`, `ssh`, `scp`, Python 3, access to the private repository, access to the configured bastion, and the selected SSH key.

Do **not** copy the CONTROL private key to SERVER or CLIENT. The setup installs only its public half as needed.

---

## State A — allocate/reimage fresh Debian nodes

Use this when IDEX/Tinyman (or replacement nodes) were reset, are on another OS, or you want a clean live environment.

### A1. Allocate/image/reset

**RUN ON: Coinbase/POS shell.** These are POS/node-management commands, not Mac, SERVER, or CLIENT commands.

Our paper node defaults:

```bash
SERVER_NODE=idex
CLIENT_NODE=tinyman
pos nodes list | grep -E "$SERVER_NODE|$CLIENT_NODE"
```

If either node is unallocated, allocate only that node according to the local POS policy. Do not free or replace someone else's allocation.

After allocation, **RUN ON: Coinbase/POS shell**:

```bash
pos nodes image "$SERVER_NODE" debian-trixie
pos nodes image "$CLIENT_NODE" debian-trixie
pos nodes reset "$SERVER_NODE" &
pos nodes reset "$CLIENT_NODE" &
wait
```

Immediately monitor node state from **another Coinbase/POS shell**:

```bash
while true; do
  clear
  date
  pos nodes list | grep -E 'idex|tinyman'
  sleep 5
done
```

A POS reset destroys the live node filesystem. Treat `/root/mohsen`, old builds, payloads and local results on those nodes as gone.

When POS reports both nodes ready, still **RUN ON: Coinbase/POS shell** to verify Debian/SSH:

```bash
for h in "$SERVER_NODE" "$CLIENT_NODE"; do
  until ssh -o ConnectTimeout=5 root@"$h" 'hostname; . /etc/os-release; echo "$ID $VERSION_CODENAME"'; do
    echo "waiting for $h ..."
    sleep 5
  done
done
```

During this check the command itself is the live readiness monitor; it repeats until both SSH endpoints answer.

### A2. Deploy, provision and build

**RUN ON: CONTROL HOST**, from the GreenQUIC+ checkout:

```bash
bash results_analysis/setup_paper_testbed.sh
```

Immediately in **a second CONTROL-HOST terminal**:

```bash
bash results_analysis/live_monitor_setup.sh
```

The setup transfers exact `origin/main`, installs dependencies, prepares firmware/MSR/P-state/hugepages/DPDK, creates the 8-GiB payload, builds P5/P7 on both endpoints, verifies the direct E810 link, binds the test NIC for P5, creates SERVER->CLIENT SSH, and performs final binary/SHA checks.

Successful completion prints `GREENQUIC+ MAIN READY`.

---

## State B — Debian is already installed, but code/builds need a fresh deployment

Use this for the common case: Debian Trixie is already running and SSH works, but `/root/mohsen` is absent/stale or you want the newest exact `main` code and clean paper builds.

Do **not** manually `git clone` the private repository on SERVER or CLIENT. The supported deployment intentionally keeps private GitHub credentials only on the CONTROL HOST and sends an exact Git bundle to both endpoints.

**RUN ON: CONTROL HOST:**

```bash
bash results_analysis/setup_paper_testbed.sh
```

Immediately in **a second CONTROL-HOST terminal:**

```bash
bash results_analysis/live_monitor_setup.sh
```

This is the supported answer to “Debian is ready; deploy a fresh/new clone of GreenQUIC+, build the applications, and prepare the test.”

---

## State C — remote checkout, host preparation and DPDK are already correct; rebuild applications only

Use this only if `/root/mohsen` is already the intended `main` checkout and host dependencies/hugepages/DPDK are correct.

**RUN ON: CONTROL HOST:**

```bash
bash results_analysis/rebuild_paper_binaries.sh
```

Immediately in **a second CONTROL-HOST terminal:**

```bash
bash results_analysis/live_monitor_setup.sh
```

This rebuilds and verifies P5 and isolated P7 on both endpoints. It does **not** refresh stale remote source. If code changed, use State B instead.

---

## State D — everything is ready; run the final paper evaluation

The authoritative low-level launcher is:

```text
greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_p7_fair_repro_6x5.sh
```

The `_v2.sh` and `_v3.sh` names are compatibility wrappers only.

For our testbed use the zero-argument high-level wrapper.

**RUN ON: CONTROL HOST:**

```bash
bash results_analysis/run_paper_evaluation.sh
```

Immediately in **a second CONTROL-HOST terminal:**

```bash
bash results_analysis/live_monitor_run.sh
```

The final launcher deliberately rebuilds/verifies P5 and P7 before measured traffic so a stale binary cannot silently change the paper result. It then runs P5 OFF/BASIC/PLUS followed by P7, validates recorder evidence, writes the exact effective configuration and packages results.

---

# 5. Result locations

The SERVER role stores controller artifacts. For tag `<TAG>`:

```text
/root/GQ_FAIR_REPRO_<TAG>.log
/root/GQ_FAIR_REPRO_<TAG>/config.env
/root/GQ_FAIR_REPRO_<TAG>/RESULT_ZIPS.txt
/root/GQ_FAIR_REPRO_<TAG>/DONE        # successful completion
/root/GQ_FAIR_REPRO_<TAG>/FAILED      # failure details if unsuccessful

/root/P5_FAIR_OPT_PINNED_6r_5d_<TAG>.zip
/root/P7_FAIR_PAPER_PINNED_6r_5d_<TAG>.zip
```

`config.env` records the exact Git SHA, SERVER/CLIENT role hosts, run shape, TOP3 settings and critical P7 settings.

## Download latest completed result

**RUN ON: CONTROL HOST:**

```bash
bash results_analysis/download_paper_results.sh
```

This is a short post-run transfer, not a running experiment. There is no live workload log to follow after the run is already `DONE`. While a run is still active, use:

```bash
bash results_analysis/live_monitor_run.sh
```

The downloader rejects unfinished runs and checks that the saved configuration matches the final paper profile.

---

# 6. Static final checks

## Paper configuration consistency

**RUN ON: CONTROL HOST:**

```bash
python3 results_analysis/verify_paper_configuration.py
```

This is an immediate local static check; it does not launch a remote process, so there is no live log monitor.

## Full repository/reproduction-layout check

**RUN ON: CONTROL HOST:**

```bash
bash results_analysis/final_repository_check.sh
```

This is also a local static check. It validates shell syntax, P5/P7 configuration consistency, the single TUM setup layout, absence of obsolete directories/temp audit files, the paper defaults, both XLSX files, `chart_v2.py`, and all 41 SVG files. It does not contact the testbed, so there is no remote live log.

---

# 7. Changing hosts for another deployment

The high-level defaults are conveniences for our testbed, not hard dependencies. Example environment overrides on another CONTROL HOST:

```text
GQ_SERVER_HOST=server01
GQ_CLIENT_HOST=client-via-bastion
GQ_SERVER_TO_CLIENT_HOST=10.0.0.22
GQ_BASTION=user@gateway
GQ_SSH_KEY=$HOME/.ssh/lab_key
```

Then the same high-level wrappers can be used without editing source files.

Changing management host names does **not** automatically make a different hardware platform equivalent to the paper testbed. The final configuration still intentionally assumes the recorded E810 PCI address, CPU topology, data-plane IP/MAC configuration, hugepage count and other paper hardware settings. Those must be adapted and revalidated on different hardware.

See `HOST_ROLE_AUDIT.md` for the dependency audit.
