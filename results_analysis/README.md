# GreenQUIC+ results, analysis, and paper reproduction

This directory is the evaluation/reproduction reference for **“Sleep Tight, QUIC Fast: Energy-Efficient QUIC with DPDK.”** It contains the final paper configuration, original supplied tuning workbooks, chart-generation code/SVGs, and the commands for reproducing the P5/P7 comparison.

## 1. Roles, host names, and where commands run

The words **SERVER**, **CLIENT**, and **CONTROL HOST** below are roles. They are not fixed machine names.

| Role | Responsibility | Paper-testbed default |
|---|---|---|
| **CONTROL HOST** | Has the private GitHub checkout; launches setup/final reproduction; downloads results | a Mac |
| **SERVER** | QUIC server and experiment controller; launches the client over SSH | `idex` |
| **CLIENT** | QUIC client | `tinyman` |
| **BASTION** | Optional SSH jump/bootstrap host between CONTROL HOST and experiment nodes | `mohsen@coinbase` |

`idex` therefore does **not** mean “server” in the code. It was simply the server host name in our paper testbed. Another deployment can use `server01`, an IP address, or any other SSH-resolvable name. Likewise `tinyman` is only our paper CLIENT host name.

### SSH requirements

For **fresh setup / fresh deployment**:

```text
CONTROL HOST -> BASTION               required only when a bastion is used
BASTION      -> SERVER                required for fresh-node key bootstrap
BASTION      -> CLIENT                required for fresh-node key bootstrap
CONTROL HOST -> SERVER                required
CONTROL HOST -> CLIENT                required
SERVER       -> CLIENT                required; setup installs/tests this key
CLIENT       -> SERVER                NOT required
```

For the **final paper run after setup**:

```text
CONTROL HOST -> SERVER                required
SERVER       -> CLIENT                required
CONTROL HOST -> CLIENT                not required by the launcher
CLIENT       -> SERVER                not required
```

Only the CONTROL HOST needs GitHub credentials for the private repository. SERVER and CLIENT receive the exact `origin/main` commit by Git bundle.

### A different Mac/control host is supported

A different control machine is fine if it has:

1. a clone of `Meamarian/GreenQUIC-Plus` and permission to fetch the private repository;
2. SSH access to the bastion, if a bastion is used;
3. a local SSH key selected with `--ssh-key` (or the default `~/.ssh/id_ed25519`).

The fresh setup installs that control-host public key on both experiment nodes through the bastion. If `--bastion none` is used, the control host must already be authorized to SSH as root to both nodes.

If the CLIENT has a different name/address when reached **from the SERVER** than when reached from the CONTROL HOST, use `--server-to-client-host` during setup. Example:

```text
CONTROL HOST sees client as:       client-via-lab-gateway
SERVER can reach client as:        192.168.100.2
```

then setup can use:

```text
--client-host client-via-lab-gateway --server-to-client-host 192.168.100.2
```

The final paper launcher only needs the SERVER endpoint from the CONTROL HOST and the CLIENT endpoint as seen from SERVER.

---

## 2. What P5 and P7 mean

`P5` and `P7` are internal experiment names, not QUIC protocol versions.

| Name | Meaning |
|---|---|
| **P5** | Repeated 8-GiB QUIC download experiment over the optimized DPDK MsQuic path. It compares OFF / MsQuic-DPDK, BASIC / GreenQUIC, and PLUS / GreenQUIC+ on the same Performance2 V2 datapath. |
| **P7** | Matching repeated 8-GiB experiment using an isolated normal-Linux MsQuic UDP build, with DPDK and XDP disabled. |

The final paper workload is 6 independent repetitions × 5 sequential 8-GiB downloads per repetition with 5-second gaps/cooldowns.

### Exact remote directories and binaries

On SERVER and CLIENT the repository root is:

```text
/root/mohsen
```

P5:

```text
Experiment directory:
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads

Build script:
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/build_p5_performance2.sh

Build directory:
/root/mohsen/msquic/build-greenquic-p5

CLIENT executable:
/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop

SERVER executable:
/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinteropserver

DPDK install:
/root/mohsen/msquic/deps/dpdk-install
```

Final P5 marker:

```text
GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0
```

Final P5 TOP3 settings:

```text
PRESSURE_UP=450
RX_QUEUE_HIGH=48
ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16
FREQ_PERIOD_US=10000
GQ_IDLE_MODE_OVERRIDE=monitor
GQ_IDLE_FALLBACK_OVERRIDE=short
ENABLE_MULTICORE=0
DPDK CPU=19
QUIC CPUs=21,22,23,24
```

P7:

```text
Experiment directory:
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline

Build script:
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline/build_p7_linux.sh

Isolated source:
/root/mohsen/msquic-p7-linux-source

Build directory:
/root/mohsen/msquic/build-linux-p7

CLIENT executable:
/root/mohsen/msquic/build-linux-p7/bin/Release/quicinterop

SERVER executable:
/root/mohsen/msquic/build-linux-p7/bin/Release/quicinteropserver
```

P7 is built with `QUIC_LINUX_DPDK_ENABLED=OFF` and `QUIC_LINUX_XDP_ENABLED=OFF`; the builder verifies that the P7 binaries do not link DPDK.

Machine-readable path/role information is in `configuration/experiment_paths.json`.

---

## 3. Supplied analysis artifacts

The original supplied artifacts are stored directly in this private repository:

```text
results_analysis/
├── configuration/
│   ├── README.md
│   ├── experiment_paths.json
│   ├── p5_paper_evaluation.json
│   └── p7_paper_evaluation.json
├── tuning/
│   ├── GreenQUIC_DPDK_Path_Perf_Tunning_v2.xlsx
│   ├── GreenQUIC_Power_Mng_Tuning_v1.xlsx
│   ├── README.md
│   └── summary.json
└── charts/
    ├── chart_v2.py
    ├── SOURCE_REFERENCE.txt
    ├── manifest.json
    └── svg/
        ├── timeseries/
        ├── with_values/
        └── without_values/
```

`artifact_files.sha256.json` records the expected sizes/SHA-256 hashes of the originally supplied workbook/chart files. `import_attached_artifacts.py` remains as a reproducible importer/verifier if the original ZIPs need to be checked again.

---

# 4. Reproduction workflow — choose your starting state

## State A — allocate/reimage fresh Debian nodes

Use this when the experiment nodes are lost/reset, on another OS, or you want a clean environment.

### A1. Allocate/image/reset the physical nodes

**RUN ON: Coinbase/POS shell, not on SERVER, CLIENT, or the CONTROL HOST.**

Set the POS node names for your environment. For our paper testbed:

```bash
SERVER_NODE=idex
CLIENT_NODE=tinyman

pos nodes list | grep -E "$SERVER_NODE|$CLIENT_NODE"
```

If a node is unallocated, allocate it individually according to the local POS policy. For our testbed this was:

```bash
pos allocations allocate "$SERVER_NODE"
pos allocations allocate "$CLIENT_NODE"
```

Do not free or overwrite an allocation belonging to someone else.

Select Debian Trixie and reset:

```bash
pos nodes image "$SERVER_NODE" debian-trixie
pos nodes image "$CLIENT_NODE" debian-trixie

pos nodes reset "$SERVER_NODE" &
pos nodes reset "$CLIENT_NODE" &
wait

pos nodes list | grep -E "$SERVER_NODE|$CLIENT_NODE"
```

A POS reset destroys the node RAM-disk contents. Treat `/root/mohsen`, builds, generated payloads, and local result directories on those nodes as gone.

Still **RUN ON: Coinbase/POS shell**, wait for both nodes:

```bash
for h in "$SERVER_NODE" "$CLIENT_NODE"; do
  until ssh -o ConnectTimeout=5 root@"$h" 'hostname; . /etc/os-release; echo "$ID $VERSION_CODENAME"'; do
    echo "waiting for $h ..."
    sleep 5
  done
done
```

### A2. Provision/build GreenQUIC+

**RUN ON: CONTROL HOST.** Paper-testbed example:

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

**RUN ON: a second CONTROL-HOST terminal** to monitor that setup:

```bash
SERVER_HOST=idex
CLIENT_HOST=tinyman
BASTION=mohsen@coinbase
KEY="$HOME/.ssh/id_ed25519"

while true; do
  clear
  date
  for h in "$SERVER_HOST" "$CLIENT_HOST"; do
    echo "===== $h ====="
    ssh -i "$KEY" -J "$BASTION" root@"$h" \
      'hostname; git -C /root/mohsen rev-parse --short HEAD 2>/dev/null || echo repo-not-ready; pgrep -af "meson|ninja|cmake|build_p5|build_p7" || true'
  done
  sleep 10
done
```

Successful setup prints `GREENQUIC+ MAIN READY` and lists the selected SERVER/CLIENT roles and binary paths.

---

## State B — Debian is already installed, but you want a fresh/current GreenQUIC+ deployment and builds

Do **not** reimage. This covers the case “OS is ready, but I want the newest exact `main` tree, DPDK/P5/P7 rebuilt, and the testbed prepared.”

Do not manually clone the private repository on the nodes. The supported setup transfers the exact CONTROL-HOST `origin/main` SHA by bundle, so SERVER/CLIENT need no GitHub credentials.

**RUN ON: CONTROL HOST:** use the same setup command from State A2 with the appropriate host switches.

**RUN ON: second CONTROL-HOST terminal:** use the same monitor from State A2.

This setup is safe to use as the authoritative “deploy + prepare + build” path when Debian Trixie is already present.

---

## State C — repository/DPDK/host provisioning are already valid; rebuild only P5/P7

Use this only when Debian Trixie, dependencies, hugepages, DPDK install, NIC support, `/root/mohsen`, and SSH are already correct.

**RUN ON: CONTROL HOST.** Example for the paper testbed:

```bash
SERVER_HOST=idex
CLIENT_HOST=tinyman
BASTION=mohsen@coinbase
KEY="$HOME/.ssh/id_ed25519"

for h in "$SERVER_HOST" "$CLIENT_HOST"; do
  ssh -i "$KEY" -J "$BASTION" root@"$h" '
    set -Eeuo pipefail
    ROOT=/root/mohsen
    P5="$ROOT/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
    P7="$ROOT/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline"
    test -d "$ROOT/msquic/deps/dpdk-install"
    P5_BUILD_REUSE=1 bash "$P5/build_p5_performance2.sh"
    bash "$P7/build_p7_linux.sh"
    test -x "$ROOT/msquic/build-greenquic-p5/bin/Release/quicinterop"
    test -x "$ROOT/msquic/build-greenquic-p5/bin/Release/quicinteropserver"
    test -x "$ROOT/msquic/build-linux-p7/bin/Release/quicinterop"
    test -x "$ROOT/msquic/build-linux-p7/bin/Release/quicinteropserver"
  '
done
```

**RUN ON: second CONTROL-HOST terminal** to monitor builds:

```bash
SERVER_HOST=idex
CLIENT_HOST=tinyman
BASTION=mohsen@coinbase
KEY="$HOME/.ssh/id_ed25519"
while true; do
  clear; date
  for h in "$SERVER_HOST" "$CLIENT_HOST"; do
    echo "===== $h ====="
    ssh -i "$KEY" -J "$BASTION" root@"$h" \
      'pgrep -af "cmake|ninja|build_p5_performance2|build_p7_linux" || echo no-build-process'
  done
  sleep 10
done
```

This does not refresh an old `/root/mohsen` checkout. If code also changed, use **State B** instead.

---

## State D — everything is prepared; run the final paper evaluation

The authoritative launcher is now one implementation:

```text
greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_p7_fair_repro_6x5.sh
```

The old `_v2.sh` and `_v3.sh` names are compatibility wrappers that call this file; they contain no separate experiment logic.

**RUN ON: CONTROL HOST:** paper-testbed example:

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

Here `--server-host` is the SERVER endpoint seen from the CONTROL HOST. `--client-host` is the CLIENT name/address that the SERVER can SSH to.

**RUN ON: second CONTROL-HOST terminal immediately after launch:**

```bash
SERVER_HOST=idex
BASTION=mohsen@coinbase
KEY="$HOME/.ssh/id_ed25519"
ssh -i "$KEY" -J "$BASTION" root@"$SERVER_HOST" '
log=$(find /root -maxdepth 1 -type f -name "GQ_FAIR_REPRO_*.log" -printf "%T@ %p\n" 2>/dev/null | sort -nr | sed -n "1p" | cut -d" " -f2-)
echo "FOLLOWING: $log"; echo
if [ -z "$log" ]; then
  echo "No GQ_FAIR_REPRO log found yet"
else
  tail -n +1 -F "$log"
fi
'
```

The launcher deliberately rebuilds/verifies P5 and P7 immediately before measured traffic. There is no authoritative `--no-build` paper mode; this prevents a stale binary from silently changing the result.

Default final run:

```text
P5: 6 runs × 5 downloads, OFF/BASIC/PLUS, TOP3
P7: 6 runs × 5 downloads, isolated Linux baseline
Gap: 5 s
Edge cooldown: 5 s
Between tests/runs: 5 s
Seed: 20260806
```

---

## 5. Result locations and download

The SERVER role stores the controller artifacts. For tag `<TAG>`:

```text
/root/GQ_FAIR_REPRO_<TAG>.log
/root/GQ_FAIR_REPRO_<TAG>/config.env
/root/GQ_FAIR_REPRO_<TAG>/RESULT_ZIPS.txt

/root/P5_FAIR_OPT_PINNED_6r_5d_<TAG>.zip
/root/P7_FAIR_PAPER_PINNED_6r_5d_<TAG>.zip
```

Matrix trees are under the P5/P7 `matrix_results/` directories on the SERVER role.

**RUN ON: CONTROL HOST** to download the latest completed result with an explicit SSH route:

```bash
cd ~/Downloads/GreenQUIC-Plus && \
bash results_analysis/download_latest_reproduction.sh \
  --server-host idex \
  --bastion mohsen@coinbase \
  --ssh-key "$HOME/.ssh/id_ed25519"
```

The downloader verifies the saved `config.env` against the final TOP3/P7 paper profile.

---

## 6. Standalone SERVER-side convenience wrappers

Fresh setup creates on the **SERVER role**:

```text
/root/run_p5.sh
/root/run_p7.sh
```

They are convenient for debugging a standalone matrix. They are not the authoritative combined paper reproduction because the CONTROL-HOST launcher also fixes the exact Git SHA, rebuilds both endpoints, applies TOP3, controls P5→P7 state changes, validates recorder evidence, and packages results.

If you SSH manually to the SERVER and use a standalone wrapper, the SERVER must be able to SSH to the configured CLIENT.

---

## 7. Authoritative configuration sources

Use these for the paper methods/reproduction description:

```text
configuration/p5_paper_evaluation.json
configuration/p7_paper_evaluation.json
configuration/experiment_paths.json
```

The JSON host names in the paper configuration are provenance for the paper testbed. Host connectivity is configurable and does not change the roles or the measured P5/P7 configuration.

`charts/SOURCE_REFERENCE.txt` intentionally preserves original source-archive names from the supplied chart bundle. Some refer to earlier analysis archives; they are provenance, not the final experiment definition.
