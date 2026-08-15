# P5 Super Performance Experiments

This directory contains a build-time-only performance experiment framework for the P5 DPDK datapath. It does not change GreenQUIC or GreenQUIC+ power-policy logic.

## Measured defaults

The default super-performance build uses only settings that already won in the completed 2026-08-15 measurements:

- mbuf cache: 128
- RX burst: 32
- TX burst: 16
- software TX ring: 4096
- producer behavior: legacy explicit MP enqueue
- bounded extra drain: disabled
- MTU override: disabled
- OFF ring-count optimization: disabled
- producer-side enqueue counter: preserved until independently measured
- transfer-window hot-path instrumentation: preserved until independently measured
- trace-only ring counts: preserved until independently measured
- RX/TX metadata: original `AdditionalInfoPool`

In the cache128 ring sweep, TX burst 16 had the highest three-mode average and highest worst-mode result:

| profile | OFF | BASIC | PLUS | 3-mode avg | worst |
|---|---:|---:|---:|---:|---:|
| control | 9.110494 | 8.641395 | 8.454125 | 8.735338 | 8.454125 |
| txburst16 | 9.118058 | 8.724396 | 9.237178 | 9.026544 | 8.724396 |
| mp_classic | 9.064712 | 8.537628 | 9.433802 | 9.012047 | 8.537628 |
| txburst64 | 8.904870 | 8.585006 | 9.540167 | 9.010014 | 8.585006 |

The earlier static sweep found cache128 to be the strongest common static configuration: OFF 8.956036, BASIC 8.813568, PLUS 9.743661 Gbit/s.

NUMA is not the current problem: both endpoints, the selected CPUs, and the 18:00.0 E810 are on NUMA node 0.

## Linux-path findings

P7 uses the normal MsQuic Linux UDP datapath. That datapath can amortize per-packet work before entering the kernel: it probes UDP segmentation and receive coalescing, can send a large segmented buffer through one `sendmsg`, falls back to `sendmmsg` batching, and can split a GRO-coalesced receive into multiple QUIC datagrams.

The current raw DPDK path instead allocates one DPDK metadata object plus one mbuf for a QUIC packet, enqueues that mbuf individually to a shared software TX ring, and the DPDK worker normally drains one burst per worker-loop visit. Previous diagnostics showed server TX-ring high-water of 2226 in PLUS while NIC partial TX bursts and drops were zero. The bottleneck is therefore plausibly the userspace handoff and per-packet overhead before the NIC rather than `rte_eth_tx_burst` capacity.

A true Linux-style UDP GSO implementation in the raw DPDK path is deliberately not forced into this experiment framework: it would change the raw packetization contract and needs separate correctness work. The current framework first tests safer improvements that address the same sources of overhead.

## Additional hot-path problems found

The tracked raw DPDK source contains `RxCounter`, `TxCounter`, and `TxEnqueueCounter`. The P5 datapath fix uses `RxCounter` and `TxCounter` at teardown to emit validated packet totals, so those two updates must remain. `TxEnqueueCounter`, however, has no reader and is written by the QUIC producer path for every packet. With multiple producers this creates an unnecessary shared cache-line write. For compatibility, the existing `P5_SUPER_DEBUG_COUNTERS=0` switch now removes only `TxEnqueueCounter`; a build guard restores and verifies the required `RxCounter`/`TxCounter` updates before compilation.

BASIC and PLUS also call the P5 transfer-window tracker for each non-empty RX/TX burst. That tracker calls `clock_gettime(CLOCK_MONOTONIC)` and relaxed atomics. OFF already bypasses the tracker. `P5_SUPER_TRANSFER_WINDOW=0` removes only this transfer-window measurement hot path; the external RAPL, C-state and frequency samplers remain enabled. Transfer-window-specific RAPL plots will naturally be unavailable for that diagnostic profile.

The original raw DPDK path also allocates a separate `DPDK_TX_PACKET`/`DPDK_RX_PACKET` metadata object from `AdditionalInfoPool` in addition to the mbuf. DPDK mbuf private storage has the same required packet lifetime, so `P5_SUPER_TX_META=mbuf` and `P5_SUPER_RX_META=mbuf` independently place this metadata in mbuf-private storage and eliminate the corresponding extra allocation/free pair. These are experimental and remain disabled in the measured default until tested.

## Build-time options

`build_p5_super_performance.sh` accepts these environment variables:

- `P5_SUPER_CACHE=128|256|512`
- `P5_SUPER_RX_BURST=16|32|64|128`
- `P5_SUPER_TX_BURST=16|32|64|128`
- `P5_SUPER_RING_SIZE=1024|2048|4096|8192`
- `P5_SUPER_RING_SYNC=legacy|mp|hts|rts`
- `P5_SUPER_DRAIN_BURSTS=1|2|4|8`
- `P5_SUPER_DRAIN_THRESHOLD=N`
- `P5_SUPER_MTU=0|1500`
- `P5_SUPER_SKIP_OFF_RINGCOUNT=0|1`
- `P5_SUPER_DEBUG_COUNTERS=0|1` (`0` means remove only unused `TxEnqueueCounter` in P5)
- `P5_SUPER_TRANSFER_WINDOW=0|1`
- `P5_SUPER_TRACE_RINGCOUNT=0|1`
- `P5_SUPER_TX_META=pool|mbuf`
- `P5_SUPER_RX_META=pool|mbuf`
- `P5_SUPER_CAP_DIAG=0|1`

Every build first restores the disposable P5 datapath from tracked MsQuic, then applies exactly the requested configuration. The switches are compile/build-time experiments, not new per-packet runtime environment branches.

### Ring synchronization

- `legacy`: preserves the currently measured `RING_F_MP_HTS_ENQ` creation flag plus explicit `rte_ring_mp_enqueue`.
- `mp`: removes HTS creation and uses classic MP behavior.
- `hts`: keeps the HTS creation flag and switches to generic `rte_ring_enqueue`, which dispatches through configured HTS mode.
- `rts`: creates an RTS producer ring and uses generic enqueue.

### Bounded drain

When `P5_SUPER_DRAIN_BURSTS > 1`, the DPDK TX worker may drain more than one ring burst before returning to the worker loop. It continues only when the previous NIC TX burst accepted every dequeued packet. `P5_SUPER_DRAIN_THRESHOLD` can require a minimum remaining backlog before another drain. `GreenQuicOnTxPoll` still observes every drained burst; `GreenQuicApplyPolicy` remains in the unchanged outer worker loop.

## V2 test plan

`run_p5_super_performance_sweep_v2.sh` supports:

- `P5_SUPER_PLAN=screen`: recommended next run; every row differs from `measured_default` in one property only.
- `P5_SUPER_PLAN=combo`: measured baseline plus predefined combinations for a later run.
- `P5_SUPER_PLAN=all`: screen and combination profiles together.
- `P5_SUPER_TESTS=a,b,c`: explicit profile list, overriding the plan.

The default screen plan is:

1. `measured_default`
2. `classic_mp`
3. `drain2`
4. `drain4`
5. `drain8`
6. `adaptive64`
7. `mtu1500`
8. `skipoffcount`
9. `no_debug_counters` — P5-safe producer-counter removal only
10. `no_transfer_window`
11. `no_trace_ringcount`
12. `txmeta_mbuf`
13. `rxmeta_mbuf`

The combination plan is present but intentionally separate. It includes `classic_mp_drain4`, `clean_hotpath`, `meta_both`, drain+metadata variants, and a final `super_combo`. Run it only after the screen table tells us which individual changes are actually beneficial.

## Mac orchestration

From any location inside a normal Mac clone, invoke the committed script after checking out the performance branch. The script fetches the performance branch, creates an incremental git bundle when possible, updates idex and tinyman, preflights the V2 code, runs the selected plan, copies the summary/logs to `~/Downloads`, and restores native P5 binaries at the end.

From the P5 directory:

```bash
bash ./mac_run_p5_super_performance.sh
```

Examples:

```bash
bash ./mac_run_p5_super_performance.sh --plan combo
bash ./mac_run_p5_super_performance.sh --plan all
bash ./mac_run_p5_super_performance.sh --tests measured_default,no_debug_counters,txmeta_mbuf
```
