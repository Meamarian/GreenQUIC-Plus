# P5 Super Performance Experiments

This directory contains build-time-only performance experiments for the P5 raw DPDK datapath. The performance framework does **not** change the GreenQUIC or GreenQUIC+ power-policy thresholds, QUIC hints, DVFS logic, sleep logic, or mode semantics.

## Current measured high-performance default

The current default is based on the completed 2026-08-15 three-download V3 refinement measurements:

- mbuf cache: **128**
- RX burst: **32**
- TX burst: **16**
- software TX ring: **4096**
- producer behavior: **legacy measured explicit MP enqueue path**
- bounded TX drain: **2 bursts per worker-loop visit**
- drain threshold: **0**
- MTU override: disabled
- TX metadata: **mbuf private storage**
- RX metadata: **mbuf private storage**
- TX locking: **single designated TX-owner lock elision**
- required RxCounter/TxCounter packet totals: preserved
- transfer-window instrumentation: preserved
- trace-only ring-count instrumentation: preserved

The latest complete refinement results were:

| profile | OFF aggregate | BASIC aggregate | PLUS aggregate | OFF steady D2+ | BASIC steady D2+ | PLUS steady D2+ | steady 3-mode avg |
|---|---:|---:|---:|---:|---:|---:|---:|
| previous drain4 high default | 9.059945 | 8.283908 | 9.874782 | 9.395648 | 8.714163 | 10.449825 | 9.519879 |
| **drain2 + mbuf metadata** | **9.179253** | **8.776885** | **9.881019** | **9.423551** | **9.312310** | **10.486178** | **9.740680** |
| drain3 + mbuf metadata | 9.135870 | 8.810422 | 9.814388 | 9.341173 | 9.303597 | 10.408326 | 9.684365 |
| no-trace + drain4 metadata | 9.180751 | 8.916605 | 10.022683 | 9.495428 | 9.008515 | 10.123801 | 9.542581 |

`drain2` is promoted because it was the strongest **complete** result for PLUS steady goodput and also the strongest complete three-mode steady average. The `drain5` profile reached 10.500011 Gbit/s PLUS steady but its run was incomplete because the client host temporarily became unreachable (`No route to host`), so it is not used as a verified default.

The first download is retained in aggregate results, but V3 also reports D2+ steady goodput. The committed default is again **3 downloads**, so the steady value is computed over D2+D3.

## Why these changes help

The raw DPDK path has a per-packet QUIC-to-datapath handoff: packet metadata, mbuf ownership, a shared software TX ring, and a dedicated TX consumer. Earlier diagnostics showed large server-side TX-ring backlog in PLUS while NIC partial TX bursts and TX drops were zero, pointing to userspace handoff/drain cost before the NIC rather than NIC TX capacity.

The metadata-in-mbuf option removes the separate `AdditionalInfoPool` allocation/free pair for the selected direction while preserving packet lifetime semantics. Bounded drain allows the TX owner to service a second queued burst immediately instead of returning to the outer loop after every single burst. Measurements show that two bursts are enough to remove much of the backlog penalty without larger drain budgets providing a verified common improvement.

The Linux MsQuic path can amortize work through UDP segmentation/coalescing and send batching. The P5 framework does not pretend to implement Linux-style GSO in the raw datapath; the current optimizations are narrower changes that reduce analogous per-packet handoff overhead without changing QUIC packetization.

## TX lock correctness

`RTE_ETH_TX_OFFLOAD_MBUF_FAST_FREE` and `RTE_ETH_TX_OFFLOAD_MT_LOCKFREE` are different capabilities. The performance transformer no longer treats MBUF fast-free as proof of multi-thread lock-free TX.

The measured P5 topology has one designated DPDK TX owner. `P5_SUPER_TX_LOCK_MODE=single_owner` therefore removes the data-path lock around that single-consumer TX burst path for the experiment without claiming that the NIC supports MT-lockfree TX.

## Build-time switches

`build_p5_super_performance.sh` supports:

- `P5_SUPER_CACHE=128|256|512`
- `P5_SUPER_RX_BURST=16|32|64|128`
- `P5_SUPER_TX_BURST=16|32|64|128`
- `P5_SUPER_RING_SIZE=1024|2048|4096|8192`
- `P5_SUPER_RING_SYNC=legacy|mp|hts|rts`
- `P5_SUPER_DRAIN_BURSTS=N`
- `P5_SUPER_DRAIN_THRESHOLD=N`
- `P5_SUPER_MTU=0|1500`
- `P5_SUPER_SKIP_OFF_RINGCOUNT=0|1`
- `P5_SUPER_DEBUG_COUNTERS=0|1`
- `P5_SUPER_TRANSFER_WINDOW=0|1`
- `P5_SUPER_TRACE_RINGCOUNT=0|1`
- `P5_SUPER_TX_META=pool|mbuf`
- `P5_SUPER_RX_META=pool|mbuf`
- `P5_SUPER_TX_LOCK_MODE=legacy|capability|single_owner`
- `P5_SUPER_CAP_DIAG=0|1`

Every build first restores the disposable P5 datapath from tracked MsQuic and then applies the requested build-time configuration. The options do not add per-packet runtime environment branches.

## V3 refinement runner

`run_p5_super_performance_sweep_v3.sh` defaults to **3 downloads** and ranks configurations using D2+ steady goodput before aggregate goodput. Its `high_default` row now matches the measured drain2 configuration. The surrounding refinement rows remain one-change-at-a-time tests around that default.

From the Mac clone:

```bash
bash greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_super_performance.sh
```

## Final three-profile runner

`mac_run_p5_final_three_profiles.sh` is the final measurement runner. It synchronizes the performance branch to idex and tinyman, builds the same verified high-performance datapath on both endpoints, and then runs exactly three GreenQUIC operating profiles without changing their policy internals:

1. `IDLE_MONITOR_NORMAL`: monitor + short fallback
2. `POWER_FRIENDLY`: frequency ON, sleep ON, epoll + short fallback
3. `NORMAL_SHORT_8GiB`: short + short fallback

The final runner defaults to **1 run × 3 downloads**, uses `--chart-style both`, 5-second gaps, balanced mode ordering, `ENABLE_RECORD=1`, and `GQ_LOG_LEVEL=0`.

For the third profile, the payload is explicitly consistent with the file name:

```text
REQUEST_PATH=/file_8G.bin
PAYLOAD_BYTES=8589934592
```

`8589934592` bytes is exactly 8 GiB. The previous `17179869184` value represented 16 GiB and was incorrect for `/file_8G.bin`.
