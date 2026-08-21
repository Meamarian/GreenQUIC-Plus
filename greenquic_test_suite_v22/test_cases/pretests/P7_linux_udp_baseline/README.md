# P7 — isolated Linux UDP baseline

`P7` is the internal experiment name for the normal-Linux MsQuic UDP comparison used by the GreenQUIC+ paper. It is not a QUIC version.

## Roles

- **CONTROL HOST** launches the exact combined paper evaluation.
- **SERVER** runs the Linux `quicinteropserver` and the P7 matrix controller.
- **CLIENT** runs `quicinterop`, started by SERVER over SSH.

Our paper defaults are SERVER=`idex`, CLIENT=`tinyman`, BASTION=`mohsen@coinbase`, CONTROL checkout=`$HOME/Downloads/GreenQUIC-Plus`, and CONTROL SSH key=`$HOME/.ssh/id_ed25519`; see `results_analysis/paper_testbed_defaults.sh`. These are defaults, not semantic host-name requirements.

SERVER -> CLIENT root SSH is required. CLIENT -> SERVER SSH is not required. The high-level setup/run/monitor wrappers accept explicit management host switches for another deployment.

Dependencies and exact source versions are documented in the repository root README, `results_analysis/README.md`, and `results_analysis/configuration/dependencies.json`.

---

## Datapath and build

`build_p7_linux.sh` creates an isolated source tree and builds with:

```text
QUIC_LINUX_DPDK_ENABLED=OFF
QUIC_LINUX_XDP_ENABLED=OFF
```

P7 therefore uses the normal Linux UDP socket datapath (`datapath_linux.c` + `datapath_epoll.c`). The build checks that neither P7 executable links DPDK.

On both endpoints:

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

---

## Final paper P7 configuration

Workload:

```text
6 independent runs
5 sequential 8-GiB downloads per run
5 s gaps
5 s pre/post cooldown
5 s between runs
```

CPU/recording mapping:

```text
Linux IRQ/NAPI/softirq target CPU=19
MsQuic worker CPUs=21,22,23,24
IRQ pinning=on
QUIC pinning=on
RPS=off
irqbalance stopped during measurement
RAPL cadence=6 ms
frequency cadence=1 ms
CPU19 is the main frequency/C-state comparison CPU
```

Network profile:

```text
MTU=1500
UDP rmem default/max=6815744
UDP wmem default/max=6815744
combined channels=1
RDMA auxiliary child disabled during test
NIC offload profile=paper
```

The `paper` profile requires TSO, GSO, TX checksum and GRO ON. UDP segmentation, RX checksum and hardware GRO are enabled best-effort when supported. The runner restores the pre-P7 DPDK driver after the Linux matrix.

---

## Exact paper execution

Do not launch standalone P7 for the final paper comparison. Use the combined high-level runner so exact Git SHA, P5 TOP3, P5→P7 NIC transition, P7 tuning, recording, validation, packaging and result transfer are controlled together.

**RUN ON: CONTROL HOST.** This block also clones the private repository if the normal Mac checkout does not yet exist:

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

For another management topology, `run_paper_evaluation.sh` accepts `--server-host`, `--client-host`, `--bastion`, `--ssh-key`, and `--download-dest`; here `--client-host` is the CLIENT endpoint as seen from SERVER. The run monitor accepts the corresponding SERVER/bastion/key switches.

By default the first CONTROL-HOST terminal waits for the combined run to become `DONE`. It prints final P5/P7 matrix/archive paths and the final local destination before SCP, then automatically SCPs both ZIPs and metadata to `reproduced_results/<TAG>/` and verifies ZIP SHA-256.

---

## Rebuild P7/P5 without redeploying source

Use this only when the remote checkout and host/DPDK preparation are already correct.

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

**LIVE MONITOR — RUN ON: second CONTROL-HOST terminal immediately after rebuild starts:**

```bash
cd "$HOME/Downloads/GreenQUIC-Plus" && \
bash results_analysis/live_monitor_setup.sh
```

If code changed or `/root/mohsen` may be stale, use `results_analysis/setup_paper_testbed.sh` instead. Rebuild/setup monitors accept explicit role-host switches for other management names.

---

## Historical filenames and lower-level defaults

`run_matrix_from_idex.sh` retains its historical filename from the original testbed. The current combined runner supplies the CLIENT endpoint explicitly; the filename does not require the SERVER OS hostname to be `idex`.

Some standalone diagnostic wrappers still keep `tinyman` or IDEX/Tinyman wording as convenience defaults/history. They expose `--client-host`, and the authoritative combined paper workflow does not use those names to select roles.

Standalone lower-level P7 commands remain useful for diagnostics, but they are not the authoritative paper reproduction interface.

---

## Results

Each run contains local application logs, timeline data, RAPL, frequency/C-state traces, NIC statistics and effective offload state. Aggregate P7 reports/charts are generated under the P7 matrix output directory.

For tag `<TAG>`, the final P7 matrix path is:

```text
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline/matrix_results/P7_FAIR_PAPER_PINNED_6r_5d_<TAG>
```

The final P7 ZIP is:

```text
/root/P7_FAIR_PAPER_PINNED_6r_5d_<TAG>.zip
```

The exact final machine-readable configuration is:

```text
results_analysis/configuration/p7_paper_evaluation.json
```

For combined result metadata, automatic/manual download behavior, result-path printing, and all start-state workflows, see `results_analysis/README.md`.
