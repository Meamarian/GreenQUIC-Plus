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

The complete effective physical, EWMA, DVFS, idle/sleep and QUIC-hint parameters are stored in `p5_paper_evaluation.json`.

### Reproduction-runner consistency check

There is one important distinction in the current repository. The generic launcher `mac_run_p5_p7_fair_repro_6x5_v3.sh` currently supplies the common fair settings (monitor/short, CPU placement, recording, etc.) but **does not explicitly inject the three TOP3 overrides**. Therefore, without additional overrides, that generic launcher falls back to the P5 defaults for `PRESSURE_UP`, `RX_QUEUE_HIGH`, and `ACTIVE_TRANSFER_SLEEP_MIN_LEVEL` rather than reproducing TOP3. The JSON in this directory records the final focused paper-evaluation configuration actually selected from the tuning/focused-test workflow. The launcher should be updated separately before using it as an exact one-command TOP3 reproduction entrypoint.

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

## Important distinction from the chart bundle

The attached chart artifact retains its original `SOURCE_REFERENCE.txt`, and some of those source references point to earlier result archive names, including an earlier Linux 6×6 result archive. That provenance is intentionally not rewritten. The JSON files in this directory record the later/final **6×5** paper-evaluation configuration and are the configuration reference to use in the paper/reproduction documentation.
