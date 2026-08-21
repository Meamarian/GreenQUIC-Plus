# Tuning results and original workbooks

This directory retains both the **original tuning workbooks supplied for the GreenQUIC+ paper work** and compact machine-readable summaries derived from them.

After importing `Tunning.zip`, the directory contains:

```text
results_analysis/tuning/
├── README.md
├── summary.json
├── GreenQUIC_DPDK_Path_Perf_Tunning_v2.xlsx
└── GreenQUIC_Power_Mng_Tuning_v1.xlsx
```

The spelling `Tunning.zip` and `Perf_Tunning` is preserved where it is part of an original filename. The repository directory itself uses the normal spelling `tuning`.

The workbook bytes are verified against `results_analysis/artifact_files.sha256.json`. To import/verify them together with the chart artifact:

```bash
python3 results_analysis/import_attached_artifacts.py \
  --charts-zip "$HOME/Downloads/Charts (2).zip" \
  --tuning-zip "$HOME/Downloads/Tunning.zip"
```

## Power-management selection

The 50-case PLUS sweep used 5 runs × 5 sequential 8-GiB downloads per case. Baseline T01 was 9.9981 Gbit/s. The strongest valid single settings were T29 (`RX_QUEUE_HIGH=48`, 10.2730 Gbit/s), T41 (`ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16`, 10.2720 Gbit/s), and T07 (`PRESSURE_UP=450`, 10.2546 Gbit/s).

The final focused combined configuration used for the paper evaluation was **TOP3**:

```text
PRESSURE_UP=450
RX_QUEUE_HIGH=48
ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16
```

`PRESSURE_UP` and `RX_QUEUE_HIGH` affect BASIC and PLUS. `ACTIVE_TRANSFER_SLEEP_MIN_LEVEL` is PLUS-only. The focused run uses `monitor` idle mode, `short` fallback, and `FREQ_PERIOD_US=10000`.

Nine sweep cases remain invalid because their repetitions were incomplete after the later-identified `rc=141` post-run/bundling SIGPIPE path: T25, T27, T31, T38, T40, T42, T44, T45, and T47. No missing performance result is invented for those cases.

## Final optimized DPDK path

The final paper P5 datapath is the safe Performance2 V2 selection, not the highest one-shot `lean_tx_rxpipe4` screen result. Its exact binary marker is:

```text
GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0
```

The final path keeps cache128, RX burst32, TX burst16, ring4096, two-burst draining, metadata in mbuf private areas, single-owner TX lock elision, shared TX handoff, UDP segmentation disabled, TX allocation batch8, producer `TxEnqueueCounter` disabled, full safe TX metadata zeroing enabled, RX pipeline prefetch distance2, and sharded active-mask disabled.

The exact paper-evaluation configuration combining this datapath with the final TOP3 power policy is in `../configuration/p5_paper_evaluation.json`.
