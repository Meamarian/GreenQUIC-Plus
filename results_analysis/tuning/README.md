# Tuning results

This directory consolidates the useful information from the two attached tuning workbooks:

- `GreenQUIC_Power_Mng_Tuning_v1.xlsx`
- `GreenQUIC_DPDK_Path_Perf_Tunning_v2.xlsx`

The original workbook data were reviewed before creating the machine-readable summaries in this folder. The old top-level `power_mng_tunning/` directory is no longer the configuration reference.

## Power-management selection

The 50-case PLUS sweep used 5 runs × 5 sequential 8-GiB downloads per case. Baseline T01 was 9.9981 Gbit/s. The strongest valid single settings were T29 (`RX_QUEUE_HIGH=48`, 10.2730 Gbit/s), T41 (`ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16`, 10.2720 Gbit/s), and T07 (`PRESSURE_UP=450`, 10.2546 Gbit/s).

The final focused combined configuration was **TOP3**:

```text
PRESSURE_UP=450
RX_QUEUE_HIGH=48
ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16
```

`PRESSURE_UP` and `RX_QUEUE_HIGH` affect BASIC and PLUS. `ACTIVE_TRANSFER_SLEEP_MIN_LEVEL` is PLUS-only. The focused runs use `monitor` idle mode, `short` fallback, and an effective `FREQ_PERIOD_US=10000`.

Nine sweep cases are kept invalid because their repetitions were incomplete after the later-identified rc=141 post-run/bundling SIGPIPE path: T25, T27, T31, T38, T40, T42, T44, T45, and T47. No performance value should be inferred for those incomplete cases.

## Final optimized DPDK path

The final paper P5 datapath is the safe Performance2 V2 selection, not the highest one-shot `lean_tx_rxpipe4` screen result. Its exact binary marker is:

```text
GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0
```

The final path keeps cache128, RX burst32, TX burst16, ring4096, two-burst draining, metadata in mbuf private areas, single-owner TX lock elision, shared TX handoff, UDP segmentation disabled, TX allocation batch8, producer `TxEnqueueCounter` disabled, full safe TX metadata zeroing enabled, RX pipeline prefetch distance2, and sharded active-mask disabled.

The exact paper-evaluation configuration that combines this datapath with the final power policy is in `../configuration/p5_paper_evaluation.json`.
