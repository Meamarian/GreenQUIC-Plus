# P7 — isolated Linux UDP baseline

> **Role terminology:** `SERVER` and `CLIENT` are roles, not host names. In the
> paper testbed the SERVER was `idex` and the CLIENT was `tinyman`; another
> deployment may use different names. The authoritative combined reproduction is
> documented in `results_analysis/README.md` and is launched from the control host.

P7 measures the normal MsQuic Linux kernel UDP datapath against the P5 DPDK
experiment without mixing the two dataplanes in one binary. `P7` is an internal
experiment name, not a QUIC version.

## Where commands run

- **Build-only command:** run on each endpoint whose P7 binary you want to rebuild.
- **Standalone P7 matrix:** run on the **SERVER role**, because the server-side
  matrix controller starts the CLIENT over SSH.
- **Final P5/P7 paper reproduction:** run on the **control host** using the
  repository's `mac_run_p5_p7_fair_repro_6x5.sh`; do not start the standalone P7
  command for the final comparison.

The SERVER role must be able to SSH as root to the CLIENT role. The CLIENT does
not need to SSH back to the SERVER for this workflow.

## Datapath and binaries

`build_p7_linux.sh` copies the tracked `msquic` source into an isolated source
tree and builds with:

```text
QUIC_LINUX_DPDK_ENABLED=OFF
QUIC_LINUX_XDP_ENABLED=OFF
```

Linux therefore uses `datapath_linux.c` + `datapath_epoll.c` and the kernel UDP
stack.

On each endpoint:

```text
Experiment directory:
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline

Build command location:
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline/build_p7_linux.sh

Isolated source tree:
/root/mohsen/msquic-p7-linux-source

Client executable:
/root/mohsen/msquic/build-linux-p7/bin/Release/quicinterop

Server executable:
/root/mohsen/msquic/build-linux-p7/bin/Release/quicinteropserver
```

The build script verifies that neither executable links DPDK.

## CPU and measurement mapping

The paper comparison keeps MsQuic workers on CPUs `21,22,23,24`. When
`--pin-irq 1` is used, E810 MSI interrupts are directed to CPU19 so CPU19 is the
Linux NIC IRQ/NAPI/softirq target. `--pin-quic 1` also constrains the P7
client/server process to the selected worker CPU list.

The final paper configuration records package+DRAM RAPL at 6 ms, frequency at
1 ms, and CPU19 C-state/frequency behavior. Transfer boundaries come from the
QUIC applications rather than wall-clock matching.

## Final paper Linux network profile

The GreenQUIC+ paper evaluation uses:

```text
MTU                         1500
UDP rmem default/max        6815744 bytes
UDP wmem default/max        6815744 bytes
combined channels           1
RPS                         disabled
RDMA auxiliary child        disabled during the test
IRQ/NAPI CPU                19
MsQuic worker CPUs          21,22,23,24
NIC offload profile         paper
```

The `paper` offload profile requires TSO, GSO, TX checksum and GRO on, with
supported UDP segmentation/RX checksum/hardware GRO enabled best-effort. Do not
use the older `native` example when reproducing the final GreenQUIC+ paper.

## Standalone P7 run for debugging

**RUN ON: SERVER role.** Substitute a client hostname/address that the SERVER
can SSH to. Example for the paper testbed:

```bash
CLIENT_HOST=tinyman

/root/run_p7.sh \
  --client-host "$CLIENT_HOST" \
  --downloads 5 \
  --gap-seconds 5 \
  --runs 6 \
  --pre-cooldown-seconds 5 \
  --post-cooldown-seconds 5 \
  --between-runs-seconds 5 \
  --dataplane-cpu 19 \
  --quic-cpus 21,22,23,24 \
  --pin-irq 1 \
  --pin-quic 1 \
  --disable-rps 1 \
  --disable-rdma 1 \
  --nic-offloads paper \
  --udp-rmem 6815744 \
  --udp-wmem 6815744 \
  --combined-channels 1 \
  --record-quic-cpus 0 \
  --rapl-interval-ms 6 \
  --freq-interval-ms 1 \
  --restore-dpdk 1 \
  --mtu 1500
```

Before running that standalone command, verify from the SERVER role:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 root@"$CLIENT_HOST" 'echo SERVER_TO_CLIENT_SSH_OK; hostname'
```

For the final paper comparison use the control-host launcher instead, because it
also fixes the exact Git SHA, rebuilds/verifies P5 and P7, applies the P5 TOP3
profile, controls the P5→P7 NIC transition, validates recorder evidence, and
packages both result sets.

## Results

Each repetition contains local application logs, timeline data, RAPL,
frequency/C-state traces, NIC statistics, and effective offload state. The
matrix root contains the aggregate P7 CSV/JSON statistics and generated charts.
The exact final configuration is also recorded under
`results_analysis/configuration/p7_paper_evaluation.json`.
