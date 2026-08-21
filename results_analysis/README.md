# GreenQUIC+ results, analysis, and paper reproduction

This directory is the evaluation and reproduction reference for **“Sleep Tight, QUIC Fast: Energy-Efficient QUIC with DPDK.”** It contains the final paper configuration, supplied tuning workbooks and SVG/chart material, dependency/version records, result helpers, and the supported P5/P7 reproduction workflow.

## 1. Roles and command locations

The words below are experiment roles, not fixed host names:

| Role | Responsibility | Paper-testbed value |
|---|---|---|
| **CONTROL HOST** | Holds the private GreenQUIC+ checkout; starts setup/final run; downloads results | Mac |
| **SERVER** | Runs `quicinteropserver` and the experiment controller | `idex` |
| **CLIENT** | Runs `quicinterop` | `tinyman` |
| **BASTION** | Optional SSH jump/bootstrap host | `mohsen@coinbase` |

`idex` does not mean SERVER in the code and `tinyman` does not mean CLIENT. They are only the paper-testbed host names. The supported setup and final launcher accept role endpoints through switches.

Every operational block in this guide is labelled **RUN ON**. In particular, paths beginning with `/root/...` live on an experiment node, not on the CONTROL HOST.

### SSH topology

Fresh setup/deployment requires:

```text
CONTROL HOST -> BASTION        only when a bastion is used
BASTION      -> SERVER         fresh-node key bootstrap when bastion is used
BASTION      -> CLIENT         fresh-node key bootstrap when bastion is used
CONTROL HOST -> SERVER         required
CONTROL HOST -> CLIENT         required
SERVER       -> CLIENT         required; setup creates/tests this path
CLIENT       -> SERVER         not required
```

The final paper launcher, after setup, requires only:

```text
CONTROL HOST -> SERVER         required
SERVER       -> CLIENT         required
CONTROL HOST -> CLIENT         not required by the final launcher
CLIENT       -> SERVER         not required
```

Only the CONTROL HOST needs credentials for the private GitHub repository. The exact `origin/main` SHA is sent to SERVER and CLIENT by Git bundle.

If the CLIENT has one address from the CONTROL HOST/bastion and another address from SERVER, setup uses both:

```text
--client-host <CONTROL/bastion view>
--server-to-client-host <SERVER view>
```

The final launcher uses `--client-host` for the CLIENT address reachable from SERVER.

## 2. What P5 and P7 mean

`P5` and `P7` are internal experiment names, not QUIC versions.

**P5** is the repeated 8-GiB QUIC download experiment over the optimized DPDK MsQuic datapath. It compares the three runtime modes on the same Performance2 V2 datapath:

- `OFF` / MsQuic-DPDK: GreenQUIC power policy bypassed.
- `BASIC` / GreenQUIC: physical DPDK activity only.
- `PLUS` / GreenQUIC+: the same physical policy plus QUIC semantic hints/guards.

**P7** is the matching repeated 8-GiB experiment using an isolated normal-Linux MsQuic UDP build with DPDK and XDP disabled.

Final paper workload: **6 independent repetitions × 5 sequential 8-GiB downloads**, with 5-second gaps/cooldowns.

### Exact remote paths

On SERVER and CLIENT:

```text
Repository root:
/root/mohsen

P5 experiment directory:
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads

P5 build script:
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/build_p5_performance2.sh

P5 client binary:
/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop

P5 server binary:
/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinteropserver

P7 experiment directory:
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline

P7 build script:
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline/build_p7_linux.sh

P7 isolated source:
/root/mohsen/msquic-p7-linux-source

P7 client binary:
/root/mohsen/msquic/build-linux-p7/bin/Release/quicinterop

P7 server binary:
/root/mohsen/msquic/build-linux-p7/bin/Release/quicinteropserver
```

P5 must contain the final marker:

```text
GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0
```

Final P5 TOP3 values are:

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

P7 is built Release/OpenSSL with `QUIC_LINUX_DPDK_ENABLED=OFF` and `QUIC_LINUX_XDP_ENABLED=OFF`; its builder verifies that the final P7 executables do not link DPDK.

Machine-readable configuration is in `configuration/p5_paper_evaluation.json`, `configuration/p7_paper_evaluation.json`, and `configuration/experiment_paths.json`.

## 3. Dependencies and versions

The exact modified MsQuic/DPDK source is fixed by the GreenQUIC+ Git SHA. The current source tree records MsQuic source version `2.4.8` and vendored DPDK `21.11.9`. P5/P7 use OpenSSL and Release builds.

The supported setup requires Debian Trixie on SERVER and CLIENT. Exact Debian package revisions and kernel patch version are resolved from the configured Trixie repositories at setup time and are not individually pinned by this repository.

Paper hardware assumptions include Intel E810 at PCI `0000:18:00.0`, Linux `ice` for link/P7 operation, `igb_uio` or `vfio-pci` for DPDK binding, `16384 × 2 MiB` hugepages on the test-NIC NUMA node, CPU19 for DPDK/Linux dataplane work, and CPUs21-24 for MsQuic workers.

See `configuration/dependencies.json` for the machine-readable dependency policy.

## 4. Supplied analysis artifacts

The private repository stores the supplied analysis material directly:

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

`artifact_files.sha256.json` stores expected sizes/SHA-256 values for the originally supplied workbook/chart files. `SOURCE_REFERENCE.txt` intentionally preserves earlier archive names as provenance; those names do not redefine the final 6×5 experiment.

# 5. Reproduction workflow: choose the current machine state

## State A — allocate/reimage fresh Debian nodes

### A1. Allocate/image/reset

**RUN ON: COINBASE/POS SHELL.** Do not run these commands on the CONTROL HOST, SERVER, or CLIENT shell.

Paper-testbed example:

```bash
SERVER_NODE=idex
CLIENT_NODE=tinyman

pos nodes list | grep -E "$SERVER_NODE|$CLIENT_NODE"

# Allocate only if the node is actually unallocated and local policy permits it.
pos allocations allocate "$SERVER_NODE"
pos allocations allocate "$CLIENT_NODE"

pos nodes image "$SERVER_NODE" debian-trixie
pos nodes image "$CLIENT_NODE" debian-trixie

pos nodes reset "$SERVER_NODE" &
pos nodes reset "$CLIENT_NODE" &
wait
```

**LIVE MONITOR — RUN ON: COINBASE/POS SHELL in another terminal:**

```bash
SERVER_NODE=idex
CLIENT_NODE=tinyman
while true; do
  clear; date
  pos nodes list | grep -E "$SERVER_NODE|$CLIENT_NODE"
  sleep 5
done
```

A POS reset destroys the live node filesystem. Treat `/root/mohsen`, old builds, generated payloads, and local results as gone.

After the reset, verify SSH from the POS environment:

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

**LIVE MONITOR — RUN ON: COINBASE/POS SHELL in another terminal:** use the same loop; it prints the first successful OS response for each node.

### A2. Provision, deploy exact `main`, and build P5/P7

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

**LIVE MONITOR — RUN ON: second CONTROL-HOST terminal:**

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
      'hostname; git -C /root/mohsen rev-parse --short HEAD 2>/dev/null || echo repo-not-ready; pgrep -af "meson|ninja|cmake|build_p5|build_p7" || true'
  done
  sleep 10
done
```

Successful setup prints `GREENQUIC+ MAIN READY` and the selected role hosts/binary paths.

## State B — Debian Trixie is already installed; deploy current code and rebuild everything

Do not reimage. **RUN ON: CONTROL HOST** and use the exact State A2 setup command with the appropriate `--server-host`, `--client-host`, `--server-to-client-host`, `--bastion`, and `--ssh-key` values.

**LIVE MONITOR:** use the State A2 second CONTROL-HOST terminal monitor.

This is the supported equivalent of “fresh clone + build” on the nodes. SERVER/CLIENT do not need private-GitHub credentials; the setup transfers the exact CONTROL-HOST `origin/main` SHA by Git bundle and installs it at `/root/mohsen`.

## State C — code/host provisioning/DPDK are already correct; rebuild only P5/P7

Use this only when `/root/mohsen`, dependencies, hugepages, DPDK install, NIC support, and SERVER→CLIENT SSH are already valid. If source code changed, use State B instead so both endpoints are synchronized to the exact same SHA.

**RUN ON: CONTROL HOST:**

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

**LIVE MONITOR — RUN ON: second CONTROL-HOST terminal:**

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

## State D — everything is prepared; run the final paper evaluation

The authoritative launcher is:

```text
greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_p7_fair_repro_6x5.sh
```

`_v2.sh` and `_v3.sh` are compatibility wrappers only.

**RUN ON: CONTROL HOST:**

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

**LIVE MONITOR — RUN ON: second CONTROL-HOST terminal immediately after launch:**

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

The final launcher deliberately rebuilds/verifies P5 and P7 before measured traffic so stale binaries cannot silently change the result.

# 6. Result locations, packaging, and download

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

The P5 and P7 ZIPs contain the full result trees, including the per-run recorder/affinity evidence generated inside those trees. Do **not** create extra `P5_AFFINITY_SERVER_*.tar.gz`, `P5_AFFINITY_CLIENT_*.tar.gz`, or manually repack `/root/...` from the CONTROL HOST. A shell prompt on the CONTROL HOST cannot access SERVER paths such as `/root/GQ_FAIR_REPRO_*` or `/root/mohsen/...` directly.

Use the repository downloader instead.

**RUN ON: CONTROL HOST after the run is DONE:**

```bash
cd ~/Downloads/GreenQUIC-Plus && \
bash results_analysis/download_latest_reproduction.sh \
  --server-host idex \
  --bastion mohsen@coinbase \
  --ssh-key "$HOME/.ssh/id_ed25519"
```

This command is synchronous and prints each copied file plus final configuration verification. If you want a live SERVER-side view while it runs, use a second CONTROL-HOST terminal:

```bash
SERVER_HOST=idex
BASTION=mohsen@coinbase
KEY="$HOME/.ssh/id_ed25519"
ssh -i "$KEY" -J "$BASTION" root@"$SERVER_HOST" '
while true; do
  clear; date
  find /root -maxdepth 1 \( -name "GQ_FAIR_REPRO_*" -o -name "P5_FAIR_OPT_PINNED_*.zip" -o -name "P7_FAIR_PAPER_PINNED_*.zip" \) -printf "%TY-%Tm-%Td %TH:%TM:%TS %s %p\n" 2>/dev/null | sort
  sleep 5
done
'
```

The downloader requires the latest artifact to contain `DONE`, `RESULT_ZIPS.txt`, and `config.env`, copies the two result ZIPs and controller metadata, then checks the saved paper configuration.

# 7. Static preflight

Before setup or a final run, `results_analysis/verify_paper_configuration.py` checks that the final P5/P7 JSON records, role-based `suite.env`, TUM setup interface, authoritative launcher, compatibility wrappers, and P7 offload implementation still agree.

**RUN ON: CONTROL HOST:**

```bash
python3 results_analysis/verify_paper_configuration.py
```

This is an immediate local/static check; it does not launch remote work and therefore has no remote live log.

# 8. TUM provisioning details

For the provisioning implementation and TUM/POS-specific notes, see `../tum_testbed_setup/README.md`. There is one supported setup entrypoint:

```text
tum_testbed_setup/greenquic_fresh_setup.sh
```

The setup script itself does not allocate/reimage POS nodes and does not reboot them. It starts only after Debian Trixie is reachable.
