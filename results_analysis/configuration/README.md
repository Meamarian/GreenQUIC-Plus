# GreenQUIC+ paper evaluation configuration

These files describe the **configuration used for the GreenQUIC+ paper evaluation**.

Files in this directory:

```text
p5_paper_evaluation.json   final P5 OFF/BASIC/PLUS workload, datapath and TOP3 policy
p7_paper_evaluation.json   final isolated Linux P7 workload/network/recording profile
experiment_paths.json      role, directory and binary-path definitions
dependencies.json          source versions, OS/package policy and hardware assumptions
```

## Roles versus host names

The experiment uses semantic roles SERVER and CLIENT. In our paper testbed:

```text
SERVER=idex
CLIENT=tinyman
```

Those names are provenance/defaults only. Management connectivity is centralized in `../paper_testbed_defaults.sh`. The paper data-plane IP/MAC/CPU/NIC values remain part of the evaluated configuration and are independent of SSH host names.

---

## P5: OFF, BASIC and PLUS

Final workload:

```text
6 independent runs
5 sequential 8-GiB downloads per run
5 s gaps
5 s edge cooldown
5 s between tests
balanced mode order
seed 20260806
max_throughput execution profile
```

Final topology:

```text
ENABLE_MULTICORE=0
DPDK CPU=19 on both endpoints
MsQuic worker CPUs=21,22,23,24 on both endpoints
```

Final focused power-policy configuration: **TOP3**.

| Parameter | Final value | Effective mode(s) |
|---|---:|---|
| `PRESSURE_UP` | 450 | BASIC + PLUS |
| `RX_QUEUE_HIGH` | 48 | BASIC + PLUS |
| `ACTIVE_TRANSFER_SLEEP_MIN_LEVEL` | 16 | PLUS only |
| `GQ_IDLE_MODE_OVERRIDE` | monitor | BASIC + PLUS |
| `GQ_IDLE_FALLBACK_OVERRIDE` | short | BASIC + PLUS |
| `FREQ_PERIOD_US` | 10000 | BASIC + PLUS |

The complete effective policy/runtime values are in `p5_paper_evaluation.json`.

---

## P7: Linux MsQuic baseline

P7 is an Linux MsQuic build:

```text
DPDK disabled
XDP disabled
normal Linux UDP socket datapath
Release build
OpenSSL TLS
```

It uses the same 6 × 5 workload timing. CPU19 is the Linux dataplane-side IRQ/NAPI/softirq target and CPUs21-24 are MsQuic workers.

Final network/recording settings include:

| Parameter | Final value |
|---|---|
| Server/client data-plane IP | `192.168.100.1` / `192.168.100.2` |
| Prefix | `/24` |
| Port | `4433` |
| MTU | `1500` |
| UDP rmem default/max | `6815744` bytes |
| UDP wmem default/max | `6815744` bytes |
| Combined channels | `1` |
| RPS | disabled |
| test-NIC RDMA auxiliary child | temporarily disabled |
| RAPL cadence | `6 ms` |
| frequency cadence | `1 ms` |

The `paper` offload profile requires TSO, GSO, TX checksum and GRO ON. UDP segmentation, RX checksum and hardware GRO are enabled best-effort when supported. The P7 wrapper restores the pre-P7 DPDK driver after the Linux matrix.

See `p7_paper_evaluation.json` for the full machine-readable record.

---

# Static configuration checks

**RUN ON: CONTROL HOST:**

```bash
python3 results_analysis/verify_paper_configuration.py
```

This is a local static check and does not start a remote process, so there is no live experiment log.

For the broader repository/layout/artifact/dependency check:

**RUN ON: CONTROL HOST:**

```bash
bash results_analysis/final_repository_check.sh
```

This is also local/static and has no remote live log.

