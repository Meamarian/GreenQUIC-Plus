# P7 — Linux UDP baseline

P7 measures the normal MsQuic Linux kernel UDP datapath against the P5 DPDK
experiment without mixing the two dataplanes in one binary.

## Primary comparison

P5 single-core topology is `CPU19 = DPDK` and MsQuic worker processors
`21,22,23,24`.  P7 keeps the worker processor list `21,22,23,24` and, when
`--pin-irq 1` is used, maps the E810 MSI IRQs to CPU19 so CPU19 becomes the
Linux NIC IRQ/NAPI/softirq target.

This does **not** imply every userspace instruction executes only on CPUs21-24;
it specifically controls MsQuic's worker ProcessorList, and `--pin-quic 1`
also applies `taskset` to the P7 client/server process for a stronger controlled
baseline.

## Datapath

`build_p7_linux.sh` copies the same tracked `msquic` source used by GreenQUIC,
reuses the exact P5 sequential-client patch, then builds with:

```
QUIC_LINUX_DPDK_ENABLED=OFF
QUIC_LINUX_XDP_ENABLED=OFF
```

Linux therefore uses `datapath_linux.c` + `datapath_epoll.c` and the kernel UDP
stack.  MsQuic keeps its stock runtime UDP segmentation/coalescing probe unchanged, and
P7 logs the detected send-segmentation and receive-coalescing capabilities.

## Timing and measurement

The QUIC applications own the transfer boundaries:

- client: exact P5 `steady_clock` D1/D2/... start and complete markers;
- server: P7-local `CLOCK_MONOTONIC` GET start and stream-shutdown markers.

RAPL, CPU frequency and C-state recorders are started/stopped by the same P7 run
wrapper so measurement work is not injected into the QUIC hot path. RAPL and
frequency samples use endpoint-local `CLOCK_MONOTONIC`; C-state `MONOTONIC_RAW`
is bridged explicitly to that clock at recorder start/end. Phase attribution is
therefore driven by QUIC-app markers in the same host clock domain, not by wall
clock matching or client/server timestamp estimation.

Defaults mirror P5 where Linux has an equivalent: 8 GiB per download, 5 s gaps,
5 s connected pre/post cooldown, package+DRAM RAPL at 6 ms, frequency at 1 ms,
and CPU19 C-state/frequency observation.

## Primary run

After the TUM setup installs `/root/run_p7.sh`, run on IDEX:

```bash
/root/run_p7.sh \
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
  --nic-offloads native \
  --record-quic-cpus 0 \
  --restore-dpdk 1
```

`--nic-offloads native` is the primary Linux baseline. Sensitivity runs may use
`--nic-offloads on` or `--nic-offloads off`; these request common checksum, GRO/GSO,
and UDP segmentation/forwarding features where the E810/ice driver exposes them.
MsQuic itself always uses its stock capability probe, which is recorded in the log.

## Results

Each repetition contains raw local app logs, app timeline, RAPL CSV, frequency
JSONL, C-state CSV/JSON, C-state mapping, NIC statistics and effective offload
state. `summary.json` contains active/gap/combined/pre/post phase metrics.  The
matrix root additionally contains `p7_all_runs.csv`, `p7_statistics.csv` and
`p7_statistics.json` with sample SD/variance across independent repetitions.

The P7 runner temporarily binds PCI `18:00.0` back to the kernel `ice` driver,
configures the same direct `192.168.100.1/24 <-> 192.168.100.2/24` link, and by
default restores the NIC to `vfio-pci` after the complete matrix.
