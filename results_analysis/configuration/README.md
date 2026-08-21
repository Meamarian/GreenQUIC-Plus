# Final GreenQUIC+ paper evaluation configuration

These files describe the **last/final configuration used for the GreenQUIC+ paper evaluation**. They are experiment records, not TUM/POS provisioning defaults.

## Roles versus host names

The experiment uses semantic roles SERVER and CLIENT. In our paper testbed:

```text
SERVER=idex
CLIENT=tinyman
```

Those names are provenance/defaults only. Management connectivity is centralized in `../paper_testbed_defaults.sh`. The paper data-plane IP/MAC/CPU/NIC values remain part of the evaluated configuration and are independent of SSH host names.

---

## P5: OFF, BASIC and PLUS

P5 uses one common optimized DPDK/MsQuic datapath for all three modes. The final datapath is **Performance2 V2** and is identified by:

```text
GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0
```

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

Mode meaning:

- **OFF / MsQuic-DPDK:** GreenQUIC power-policy decisions bypassed.
- **BASIC / GreenQUIC:** physical DPDK activity only.
- **PLUS / GreenQUIC+:** same physical policy plus QUIC semantic hints/guards.

The complete effective policy/runtime values are in `p5_paper_evaluation.json`.

---

## P7: normal Linux MsQuic baseline

P7 is an isolated normal-Linux MsQuic build:

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

# Authoritative execution

The low-level authoritative implementation remains:

```text
greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_p7_fair_repro_6x5.sh
```

`_v2.sh` and `_v3.sh` are compatibility wrappers only.

For our paper testbed, use the zero-argument high-level wrapper so host names, bastion and SSH key do not need to be typed each time.

**RUN ON: CONTROL HOST:**

```bash
bash results_analysis/run_paper_evaluation.sh
```

Immediately in **a second CONTROL-HOST terminal:**

```bash
bash results_analysis/live_monitor_run.sh
```

The final launcher explicitly injects TOP3, monitor/short idle settings, P5 recorder settings and the P7 paper network profile. It writes the exact Git commit and effective run settings to the generated `config.env`.

---

# Static configuration checks

**RUN ON: CONTROL HOST:**

```bash
python3 results_analysis/verify_paper_configuration.py
```

This is a local static check and does not start a remote process, so there is no live experiment log.

For the broader repository/layout/artifact check:

**RUN ON: CONTROL HOST:**

```bash
bash results_analysis/final_repository_check.sh
```

This is also local/static and has no remote live log.

---

## Chart provenance

The supplied chart artifact keeps its original `SOURCE_REFERENCE.txt`. Some source names refer to earlier intermediate archives, including an older Linux 6×6 archive. Those names are provenance only. The JSON files in this directory plus the authoritative 6×5 launcher define the final paper evaluation.
