# P5 Super Performance Experiments

This directory contains a build-time-only performance experiment framework for the P5 DPDK datapath. It does not change GreenQUIC or GreenQUIC+ power-policy logic.

## Measured high-performance default

The super-performance build now defaults to the strongest balanced configuration supported by the completed 2026-08-15 measurements while keeping the normal P5 measurement instrumentation enabled:

- mbuf cache: 128
- RX burst: 32
- TX burst: 16
- software TX ring: 4096
- producer behavior: legacy explicit MP enqueue
- bounded TX drain: 4 bursts per worker-loop visit
- drain threshold: 0 (continue while backlog remains and the previous NIC burst was fully accepted)
- TX metadata: mbuf private storage
- RX metadata: mbuf private storage
- MTU override: disabled
- transfer-window instrumentation: enabled
- trace ring-count instrumentation: enabled
- packet-total counters: preserved
- TX lock mode: `single_owner`

The measured `drain4_meta_both` result that motivated this default was:

| OFF | BASIC | PLUS | 3-mode avg | worst |
|---:|---:|---:|---:|---:|
| 9.145927 | 8.927281 | 10.023780 | 9.365663 | 8.927281 |

A second strong candidate, `clean_hotpath_meta_both`, achieved OFF 9.275855, BASIC 8.970720, PLUS 9.401196 Gbit/s. It is not the default because it removes measurement/debug hot-path work. Those switches remain independent experiments so measurement fidelity and performance can be evaluated separately.

Earlier measurements established the static foundation:

- `cache128` was the strongest common cache configuration.
- TX burst 16 was the strongest common TX-burst configuration in the ring sweep.
- large TX-ring backlog occurred before the NIC while NIC partial TX bursts and drops were zero.
- NUMA is not the current problem: the selected CPUs and E810 are on NUMA node 0 on both endpoints.

## Why download 1 is reported separately

P5 repeatedly showed a slower first transfer than later transfers in the same QUIC connection. V3 therefore keeps download 1 for correctness and aggregate reporting but also computes a separate steady-state metric from downloads 2..N.

The committed Mac runner defaults to **2 downloads per mode**. With that setting:

- `aggregate_gbps` includes D1 and D2.
- `d1_gbps` reports only the first transfer.
- `steady_gbps` is exactly D2.

With more than two downloads, `steady_gbps` is calculated over all downloads from D2 onward.

## Linux-path findings

P7 uses the normal MsQuic Linux UDP datapath. That path can amortize work before entering the kernel: it probes UDP segmentation and receive coalescing, can send a segmented buffer through one `sendmsg`, falls back to `sendmmsg` batching, and can process GRO-coalesced receive data.

The raw DPDK path instead handles a QUIC packet as an mbuf and hands that mbuf through a software TX ring. Earlier code also allocated a separate `DPDK_TX_PACKET`/`DPDK_RX_PACKET` from `AdditionalInfoPool` for every packet. The measured metadata-in-mbuf experiments remove that extra allocation/free pair while preserving packet ownership and lifetime.

A true Linux-style UDP GSO/batching design for the raw DPDK path remains a separate future correctness/performance project. V3 first refines the safer handoff and drain improvements already supported by measurement.

## TX capability bookkeeping correction

The tracked raw DPDK source historically treated `RTE_ETH_TX_OFFLOAD_MBUF_FAST_FREE` as if it implied `RTE_ETH_TX_OFFLOAD_MT_LOCKFREE`. They are different capabilities. The measured E810 reported `mbuf_fast_free=1` but `mt_lockfree=0`.

The super framework now exposes three compile-time TX-lock modes:

- `legacy`: reproduce the historical behavior exactly.
- `capability`: correct the MBUF_FAST_FREE bookkeeping and retain the TX lock when the PMD does not advertise MT_LOCKFREE.
- `single_owner`: correct the bookkeeping and remove the per-burst data TX lock because the configured DPDK TX-owner lcore is the only data-path caller of `rte_eth_tx_burst` in this P5 design.

`single_owner` is the measured-high-performance default. This does **not** claim that the E810 PMD supports MT-lockfree TX.

Startup diagnostics also report MT-lockfree, MBUF fast-free, checksum, multi-segment/UDP-TSO availability when exposed by the installed DPDK headers, and the device RX/TX queue limits.

## Build-time options

`build_p5_super_performance.sh` accepts:

- `P5_SUPER_CACHE=128|256|512`
- `P5_SUPER_RX_BURST=16|32|64|128`
- `P5_SUPER_TX_BURST=16|32|64|128`
- `P5_SUPER_RING_SIZE=1024|2048|4096|8192`
- `P5_SUPER_RING_SYNC=legacy|mp|hts|rts`
- `P5_SUPER_DRAIN_BURSTS=1..8`
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

Every build restores the disposable P5 datapath from tracked MsQuic and applies only the requested build-time configuration. No new per-packet runtime environment branches are introduced. GreenQUIC/GreenQUIC+ policy logic is unchanged.

`P5_SUPER_DEBUG_COUNTERS=0` removes only the unused producer-side `TxEnqueueCounter` update in P5. The P5-required `RxCounter` and `TxCounter` packet totals are restored and verified by `apply_p5_super_packet_counter_guard.py`.

## V3 refinement plan

`run_p5_super_performance_sweep_v3.sh` is now the recommended runner.

Default plan: `P5_SUPER_PLAN=refine`.

The default refinement profiles are:

1. `high_default` — measured high-performance default.
2. `old_measured_baseline` — cache128/TX16 but old one-drain, pool metadata, legacy lock behavior.
3. `drain2_meta` — only drain depth changes to 2.
4. `drain3_meta` — only drain depth changes to 3.
5. `drain5_meta` — only drain depth changes to 5.
6. `threshold64_meta` — only adds a 64-packet threshold to the drain4 policy.
7. `no_debug_meta` — only removes the unused producer debug counter.
8. `no_window_meta` — only removes the transfer-window hot path.
9. `no_trace_meta` — only removes trace-only ring-count snapshots.
10. `txmeta_pool` — only returns TX metadata to `AdditionalInfoPool`.
11. `rxmeta_pool` — only returns RX metadata to `AdditionalInfoPool`.
12. `lock_capability` — only changes TX locking from `single_owner` to PMD-capability locking.

This plan preserves one-variable-at-a-time interpretation around the measured high-performance default.

The separate `combo` plan contains only follow-up combinations such as cleaned hot path with drain2/drain3/threshold64 and an MTU-1500 check. It is not part of the default refinement run.

The final V3 table ranks configurations by three-mode **steady D2+ average**, then steady worst-mode goodput, then full aggregate goodput. The normal aggregate metric remains present for direct comparison with earlier P5 results.

## Mac orchestration

From the repository root on the Mac, the committed helper updates idex and tinyman, preflights the code, runs the V3 refinement sweep, copies the table/logs/charts to `~/Downloads`, and restores native P5 binaries after the sweep:

```bash
bash greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_super_performance.sh
```

Defaults are `--plan refine --downloads 2`.

Examples:

```bash
bash greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_super_performance.sh --plan combo
bash greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_super_performance.sh --tests high_default,drain3_meta,no_debug_meta
bash greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_super_performance.sh --downloads 5
```
