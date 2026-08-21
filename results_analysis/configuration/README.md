# Final paper evaluation configuration

These files describe the **last/final GreenQUIC+ paper-evaluation configuration**. They are not TUM fresh-node setup defaults.

## P5: OFF, BASIC and PLUS

P5 uses one common optimized DPDK/MsQuic datapath for all three modes. The final datapath is Performance2 V2 and is identified by:

```text
GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0
```

The common paper workload is 6 independent runs, 5 sequential 8-GiB downloads per run in one QUIC connection, 5-second gaps, 5-second server cooldown, 5 seconds between tests, balanced mode order, seed `20260806`, and `max_throughput` execution. The final topology is single-DPDK-owner: CPU19 for DPDK on both endpoints and CPUs21-24 for MsQuic workers.

The final focused power-policy configuration is **TOP3**, the combination selected from T07, T29 and T41:

| Parameter | Final value | Effective mode(s) |
|---|---:|---|
| `PRESSURE_UP` | 450 | BASIC + PLUS |
| `RX_QUEUE_HIGH` | 48 | BASIC + PLUS |
| `ACTIVE_TRANSFER_SLEEP_MIN_LEVEL` | 16 | PLUS only |
| `GQ_IDLE_MODE_OVERRIDE` | monitor | BASIC + PLUS |
| `GQ_IDLE_FALLBACK_OVERRIDE` | short | BASIC + PLUS |
| `FREQ_PERIOD_US` | 10000 | BASIC + PLUS |

The three modes differ only in policy behavior on top of the same optimized DPDK datapath:

- **OFF / MsQuic-DPDK:** GreenQUIC power-management decisions are bypassed. The common runtime/power variables may exist in the environment, but they do not drive GreenQUIC policy actions.
- **BASIC / GreenQUIC:** uses only physical DPDK activity. The TOP3 physical changes `PRESSURE_UP=450` and `RX_QUEUE_HIGH=48` apply. The PLUS-only active-transfer sleep guard does not affect BASIC.
- **PLUS / GreenQUIC+:** uses the same physical policy as BASIC plus QUIC semantic hints and PLUS-specific guards. All three TOP3 changes apply, including `ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16`.

The complete effective physical, EWMA, DVFS, idle/sleep, recorder and QUIC-hint parameters are stored in `p5_paper_evaluation.json`.

### Exact reproduction-runner consistency

The supported final launcher is:

```text
greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_p7_fair_repro_6x5_v3.sh
```

It now fails closed unless the internal generated runner explicitly contains the final TOP3 settings. The generated P5 command injects, rather than merely inherits, the critical final values:

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

The run artifact `config.env` also records the TOP3 identity and these critical settings. This removes the previous ambiguity where the generic fair launcher could fall back to the ordinary P5 defaults.

## P7: normal Linux MsQuic baseline

P7 is an isolated normal-Linux MsQuic build: DPDK disabled, XDP disabled, normal Linux UDP socket datapath, Release build, OpenSSL TLS.

For the final paper comparison it uses the same 6 × 5 workload timing. CPU19 is the Linux dataplane-side CPU (IRQ/NAPI/softirq target), CPUs21-24 are MsQuic workers, IRQ pinning and QUIC pinning are enabled, RPS is disabled, irqbalance is stopped for the measured run, and only CPU19 is used for the apples-to-apples frequency/C-state trace.

The Linux network settings are:

| Parameter | Final value |
|---|---|
| Server / client IP | `192.168.100.1` / `192.168.100.2` |
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

The `paper` offload profile requires TSO, GSO, TX checksum offload and GRO to be ON. UDP segmentation, RX checksum and hardware GRO are enabled on a best-effort basis when supported. The runner restores the exact pre-P7 DPDK driver after the Linux matrix.

See `p7_paper_evaluation.json` for the complete machine-readable configuration.

## Configuration verification

From the repository root, run:

```bash
python3 results_analysis/verify_paper_configuration.py
```

The verifier checks the machine-readable configuration and the supported launcher for the critical final P5/P7 values before a measurement is started.

## Important distinction from the chart bundle

The attached chart artifact retains its original `SOURCE_REFERENCE.txt`, and some of those source references point to earlier result archive names, including an earlier Linux 6×6 result archive. That provenance is intentionally not rewritten. The JSON files in this directory record the later/final **6×5** paper-evaluation configuration and are the configuration reference to use in the paper/reproduction documentation.
