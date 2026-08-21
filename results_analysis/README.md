# Results and analysis

This directory collects the GreenQUIC+ paper-evaluation artifacts in one place. It is deliberately separate from `tum_testbed_setup/`: the files here describe the experiment configurations, tuning/evaluation material, and chart provenance used for the paper, not fresh-machine provisioning.

## Layout

| Directory | Contents |
|---|---|
| `configuration/` | Exact final paper-evaluation configuration for P5 OFF/BASIC/PLUS and the P7 Linux baseline, stored as JSON plus a readable explanation. |
| `tuning/` | Power-management and DPDK-path tuning summaries reconstructed from the attached tuning workbooks. |
| `charts/` | Chart/source-provenance material corresponding to the attached chart bundle. |

## Final paper comparison represented here

The final focused P5 paper configuration is the **TOP3** configuration: `PRESSURE_UP=450`, `RX_QUEUE_HIGH=48`, and `ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16`, on the optimized Performance2 V2 DPDK datapath. OFF, BASIC, and PLUS use the same optimized datapath and the same workload; only the GreenQUIC policy behavior differs by mode. `ACTIVE_TRANSFER_SLEEP_MIN_LEVEL` is PLUS-only, while `PRESSURE_UP` and `RX_QUEUE_HIGH` affect BASIC and PLUS.

The P7 comparison is the isolated normal-Linux MsQuic path with the paper Linux network profile: CPU19 for IRQ/NAPI/softirq processing, MsQuic worker CPUs21-24, IRQ and QUIC pinning enabled, RPS disabled, the test NIC's RDMA auxiliary child disabled during the run, paper-style GSO/GRO offload setup, 6,815,744-byte UDP receive/send buffers, one combined channel, MTU 1500, and the same 6-run × 5-download / 5-second-gap workload.

See `configuration/README.md`, `configuration/p5_paper_evaluation.json`, and `configuration/p7_paper_evaluation.json` for the complete values.

## Provenance note

The attached chart bundle is kept as analysis/provenance material and retains its original source names. Some chart source references point to earlier result archives (including an earlier P7 6×6 archive). The JSON files under `configuration/` intentionally record the **later/final 6×5 paper-evaluation configuration** and should be used when documenting the final experimental setup.

The former top-level `power_mng_tunning/` directory is obsolete after this reorganization; its useful tuning information is consolidated under `results_analysis/tuning/` and the exact final configuration is under `results_analysis/configuration/`.
