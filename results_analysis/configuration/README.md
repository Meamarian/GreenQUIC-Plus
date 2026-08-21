# Final paper evaluation configuration

These files describe the **last/final GreenQUIC+ paper-evaluation configuration**. They are experiment configuration records, not host-name requirements and not TUM/POS provisioning defaults.

## Endpoint roles versus paper host names

The configuration uses the semantic roles SERVER and CLIENT. In our paper testbed the SERVER host was `idex` and the CLIENT host was `tinyman`; those names are provenance only. The supported setup/launcher select connectivity with host switches. See `experiment_paths.json` and `../README.md`.

The paper's data-plane IP/MAC/CPU/NIC values remain part of the paper configuration and should not be confused with SSH host names.

## P5: OFF, BASIC and PLUS

P5 uses one common optimized DPDK/MsQuic datapath for all three modes. The final datapath is Performance2 V2 and is identified by:

```text
GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0
```

The common paper workload is 6 independent runs, 5 sequential 8-GiB downloads per run in one QUIC connection, 5-second gaps, 5-second server cooldown, 5 seconds between tests, balanced mode order, seed `20260806`, and `max_throughput` execution. The final topology is single-DPDK-owner: CPU19 for DPDK on both endpoints and CPUs21-24 for MsQuic workers.

The final focused power-policy configuration is **TOP3**, selected from T07 + T29 + T41:

| Parameter | Final value | Effective mode(s) |
|---|---:|---|
| `PRESSURE_UP` | 450 | BASIC + PLUS |
| `RX_QUEUE_HIGH` | 48 | BASIC + PLUS |
| `ACTIVE_TRANSFER_SLEEP_MIN_LEVEL` | 16 | PLUS only |
| `GQ_IDLE_MODE_OVERRIDE` | monitor | BASIC + PLUS |
| `GQ_IDLE_FALLBACK_OVERRIDE` | short | BASIC + PLUS |
| `FREQ_PERIOD_US` | 10000 | BASIC + PLUS |

Mode behavior:

- **OFF / MsQuic-DPDK:** GreenQUIC power-management decisions are bypassed.
- **BASIC / GreenQUIC:** physical DPDK activity only; `PRESSURE_UP=450` and `RX_QUEUE_HIGH=48` apply.
- **PLUS / GreenQUIC+:** the same physical policy plus QUIC semantic hints/guards; all three TOP3 changes apply.

The complete effective physical, EWMA, DVFS, idle/sleep, recorder and QUIC-hint parameters are in `p5_paper_evaluation.json`.

## Exact reproduction-runner consistency

There is now one authoritative implementation:

```text
greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_p7_fair_repro_6x5.sh
```

The old `_v2.sh` and `_v3.sh` files are compatibility wrappers that call this same implementation.

**RUN ON: CONTROL HOST.** The launcher accepts:

```text
--server-host HOST
--client-host HOST
--bastion USER@HOST|none
--ssh-key PATH
```

It explicitly injects the final P5 values rather than inheriting generic defaults:

```text
PRESSURE_UP=450
RX_QUEUE_HIGH=48
ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16
FREQ_PERIOD_US=10000
GQ_IDLE_MODE_OVERRIDE=monitor
GQ_IDLE_FALLBACK_OVERRIDE=short
GQ_ENABLE_ACPI_POWER_TRACE=1
GQ_POWER_SAMPLE_INTERVAL_MS=1000
GQ_ENABLE_MSR_TRACE=1
GQ_MSR_SAMPLE_INTERVAL_MS=6
GQ_MSR_SMOOTH_SAMPLES=3
ENABLE_CSTATE_RECORD=1
GQ_ENABLE_FREQ_TRACE=1
GQ_FREQ_SAMPLE_INTERVAL_MS=1
```

The generated run artifact `config.env` records the exact Git commit, selected SERVER/CLIENT role hosts, TOP3 identity, and critical P5/P7 settings.

## P7: normal Linux MsQuic baseline

P7 is an isolated normal-Linux MsQuic build: DPDK disabled, XDP disabled, normal Linux UDP socket datapath, Release build, OpenSSL TLS.

For the final comparison it uses the same 6 × 5 workload timing. CPU19 is the Linux dataplane-side CPU (IRQ/NAPI/softirq target), CPUs21-24 are MsQuic workers, IRQ/QUIC pinning are enabled, RPS is disabled, irqbalance is stopped during measurement, and CPU19 is used for the apples-to-apples frequency/C-state trace.

Final network settings:

| Parameter | Final value |
|---|---|
| Server / client data-plane IP | `192.168.100.1` / `192.168.100.2` |
| Prefix | `/24` |
| Port | `4433` |
| MTU | `1500` |
| UDP rmem default/max | `6815744` bytes |
| UDP wmem default/max | `6815744` bytes |
| Combined channels | `1` |
| RPS | disabled |
| test-NIC RDMA auxiliary child | temporarily disabled |
| network diagnostics | disabled for normal measurement |
| RAPL cadence | `6 ms` |
| frequency cadence | `1 ms` |

The `paper` offload profile requires TSO, GSO, TX checksum offload and GRO ON. UDP segmentation, RX checksum and hardware GRO are enabled best-effort when supported. The runner restores the pre-P7 DPDK driver after the Linux matrix.

See `p7_paper_evaluation.json` for the complete machine-readable configuration.

## Configuration verification

**RUN ON: CONTROL HOST**, from the repository root:

```bash
python3 results_analysis/verify_paper_configuration.py
```

This static verifier does not contact SERVER/CLIENT. It checks that the JSON records, authoritative launcher, compatibility wrappers, TUM setup interface, and P7 offload implementation agree on the final paper configuration.

## Chart provenance

The supplied chart artifact retains its original `SOURCE_REFERENCE.txt`; some names refer to earlier result archives, including an earlier Linux 6×6 archive. Those names are provenance, not the final experiment definition. The JSON files in this directory and the authoritative 6×5 launcher define the final paper evaluation.
