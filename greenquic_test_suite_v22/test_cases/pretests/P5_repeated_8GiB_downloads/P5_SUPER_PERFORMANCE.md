# P5 Super Performance Experiments

This directory contains a build-time-only performance experiment framework for the P5 DPDK datapath. It does not change GreenQUIC or GreenQUIC+ policy logic.

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

In the cache128 ring sweep, TX burst 16 had the highest three-mode average and highest worst-mode result:

| profile | OFF | BASIC | PLUS | 3-mode avg | worst |
|---|---:|---:|---:|---:|---:|
| control | 9.110494 | 8.641395 | 8.454125 | 8.735338 | 8.454125 |
| txburst16 | 9.118058 | 8.724396 | 9.237178 | 9.026544 | 8.724396 |
| mp_classic | 9.064712 | 8.537628 | 9.433802 | 9.012047 | 8.537628 |
| txburst64 | 8.904870 | 8.585006 | 9.540167 | 9.010014 | 8.585006 |

The earlier static sweep found cache128 to be the strongest common static configuration: OFF 8.956036, BASIC 8.813568, PLUS 9.743661 Gbit/s.

NUMA is not the current problem: both endpoints, the selected CPUs, and the 18:00.0 E810 are on NUMA node 0.

## Why investigate batching and drain behavior

The Linux P7 path can aggregate work before crossing into the kernel. MsQuic's Linux UDP datapath probes UDP segmentation/coalescing support, uses one iovec for segmented sends when available, falls back to sendmmsg batching otherwise, and can process GRO-coalesced receives.

The current DPDK raw path instead allocates one mbuf for each QUIC packet, enqueues one mbuf at a time to a software ring, and the DPDK TX worker removes at most one configured burst per worker-loop visit. Previous diagnostics showed a server TX-ring high-water of 2226 in PLUS while NIC partial TX bursts and drops were zero. Therefore the super framework adds bounded/adaptive ring drain experiments before attempting any invasive QUIC-packet aggregation design.

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
- `P5_SUPER_CAP_DIAG=0|1`

Every build first restores the disposable P5 datapath from tracked MsQuic, then applies exactly the requested configuration. No option is implemented as a per-packet runtime environment branch.

### Ring synchronization

- `legacy`: preserves the currently measured `RING_F_MP_HTS_ENQ` creation flag plus explicit `rte_ring_mp_enqueue`.
- `mp`: removes HTS creation and uses classic MP behavior.
- `hts`: keeps the HTS creation flag and switches to generic `rte_ring_enqueue`, which dispatches through configured HTS mode.
- `rts`: creates an RTS producer ring and uses generic enqueue.

### Bounded drain

When `P5_SUPER_DRAIN_BURSTS > 1`, the DPDK TX worker may drain more than one ring burst before returning to the worker loop. It continues only when the previous NIC TX burst accepted every dequeued packet. `P5_SUPER_DRAIN_THRESHOLD` can require a minimum remaining backlog before another drain. GreenQuicOnTxPoll still observes every drained burst; GreenQuicApplyPolicy remains in the unchanged outer worker loop.

## Test plans

`run_p5_super_performance_sweep.sh` supports:

- `P5_SUPER_PLAN=screen`: measured baseline plus one new parameter/algorithm at a time. This is the recommended next run.
- `P5_SUPER_PLAN=combo`: measured baseline plus predefined combinations.
- `P5_SUPER_PLAN=all`: all screen and combination profiles.
- `P5_SUPER_TESTS=a,b,c`: explicit profile list, overriding the plan.

The screen plan contains `native_control`, `measured_default`, `classic_mp`, `drain2`, `drain4`, `drain8`, `adaptive64`, `mtu1500`, `skipoffcount`, `rx64`, `ring2048`, and `tx64`.

Combination profiles are present but intentionally not part of the default screen run. This keeps the next experiment interpretable.

## Mac orchestration

From the P5 directory on the Mac:

```bash
bash ./mac_run_p5_super_performance.sh
```

The script fetches the performance branch, creates an incremental git bundle when possible, updates idex and tinyman, runs the selected plan, copies the summary/logs to `~/Downloads`, and restores native P5 binaries at the end.

Examples:

```bash
bash ./mac_run_p5_super_performance.sh --plan combo
bash ./mac_run_p5_super_performance.sh --plan all
bash ./mac_run_p5_super_performance.sh --tests measured_default,classic_mp,drain4
```
