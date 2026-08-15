# P5 Performance2: Remaining Goodput Experiments

`performance2/p5-max-goodput` is an isolated research branch created from the measured `performance/p5-max-goodput` head. The stable performance branch is not modified by this work.

The branch keeps the measured P5 base configuration unchanged unless explicitly overridden by the existing super-performance build:

- mbuf cache 128
- RX burst 32
- TX burst 16
- software TX ring 4096
- bounded TX drain 2
- TX/RX metadata in mbuf private storage
- one designated TX owner with the measured lock elision
- existing transfer-window and packet-total instrumentation enabled

No GreenQUIC/GreenQUIC+ pressure thresholds, hint rules, DVFS rules, sleep rules, idle semantics, or mode semantics are changed.

## Why a second branch

The remaining ideas are more architectural and therefore higher risk than the already measured cache/burst/metadata/drain changes. Every new feature is independently switchable and defaults OFF. This lets the branch reproduce the stable measured datapath and then enable one experiment at a time.

## New switches

`build_p5_performance2.sh` accepts:

- `P5_P2_DIAG_INTERVAL_US=0|N` — startup diagnostic interval; `0` disables it.
- `P5_P2_DIAG_DURATION_MS=N` — maximum startup diagnostic duration; default 3000 ms.
- `P5_P2_TX_HANDOFF=shared|sharded` — original shared MP software ring or per-producer SPSC rings.
- `P5_P2_TX_PRODUCER_RING_SIZE=256|512|1024|2048|4096` — size of each SPSC producer ring.
- `P5_P2_RX_PREFETCH=0|1` — prefetch RX mbuf metadata/data before the existing burst parse loop.
- `P5_P2_UDP_SEG=0|1` — experimental UDP segmentation offload path; default OFF.
- `P5_P2_UDP_SEG_MAX=2|4|8` — maximum logical equal-size UDP datagrams grouped into one hardware-segmentation request.

The base `P5_SUPER_*` controls remain available too, but the performance2 builder defaults them to the measured drain2 configuration.

## 1. Startup diagnostics (diagnostic only, default OFF)

The first transfer was repeatedly slower than D2+. `P5_P2_DIAG_INTERVAL_US` adds short-interval datapath snapshots during the beginning of an active TX period. It reports elapsed time, TX backlog, mode, and RX/TX packet totals. Existing external test instrumentation can be correlated with CPU frequency, C-state, power, and transfer timestamps.

This feature is intentionally disabled in performance measurements because `fprintf` itself can perturb the hot path.

## 2. Sharded producer handoff

The raw send API hands one `CXPLAT_SEND_DATA` packet to `CxPlatDpRawTxEnqueue()` at a time. Holding packets until a producer batch fills is unsafe because the final packet can be left waiting indefinitely. Instead, `P5_P2_TX_HANDOFF=sharded` removes shared multi-producer ring contention without changing the send-completion contract:

- each producer thread lazily obtains an SPSC DPDK ring;
- the producer uses `rte_ring_sp_enqueue`;
- the single DPDK TX owner scans the producer rings and dequeues a full TX burst;
- the original shared MP ring remains a fallback;
- if a producer ever falls back, it stays on the shared ring to avoid ordering a newer sharded packet ahead of an older fallback packet;
- all GreenQUIC backlog checks use the combined backlog of the fallback ring and producer rings, so power-policy thresholds and semantics are unchanged.

This targets the remaining per-packet producer synchronization/cache-line cost while preserving immediate enqueue semantics.

## 3. RX prefetch

The existing raw receive path already passes a whole RX burst to `CxPlatDpRawRxEthernet`, and that function chains contiguous packets for the same socket before calling the UDP receive handler. Therefore performance2 does not add a redundant RX batching API.

`P5_P2_RX_PREFETCH=1` instead prefetches mbuf metadata and packet data for the received burst before the existing parse loop. It is a low-risk experiment aimed at reducing cache-miss latency during per-packet Ethernet/IP/UDP parsing.

## 4. Experimental UDP segmentation offload

`P5_P2_UDP_SEG=1` is the highest-risk experiment and remains OFF by default. The code activates it only if the PMD advertises UDP segmentation, multi-segment TX, IPv4 checksum, and UDP checksum offloads.

Only contiguous, equal-size, non-segmented IPv4/UDP packets with the same Ethernet/IP/UDP flow are eligible. The path chains the payload mbufs behind the first packet, updates the super-packet IPv4/UDP lengths, sets segmentation/checksum metadata, and preserves logical packet accounting even though fewer physical mbufs are submitted to `rte_eth_tx_burst`.

Important safety properties:

- unsupported hardware automatically leaves the feature inactive;
- grouping is capped by the PMD segment limit and `P5_P2_UDP_SEG_MAX`;
- packet-total and GreenQUIC pressure accounting uses logical datagram counts;
- partial hardware TX handling uses the physical super-packet count;
- accepted mbufs are never dereferenced after ownership is transferred to the PMD;
- TX metadata must be mbuf-private, and transfer-window accounting must remain enabled for this experiment.

This path still requires real E810/ice runtime and wire-format validation before it can ever be considered a default.

## 5. Reproducible screening and statistical follow-up

`run_p5_performance2_sweep.sh` tests the stable baseline and each new idea independently, then a small number of combinations. Defaults are 1 run and 3 downloads for screening. The final table records aggregate, D1, and D2+ steady goodput and ranks by PLUS steady goodput, then three-mode steady average and worst mode. Diagnostic-only runs are excluded from performance ranking.

Profiles:

1. `baseline`
2. `diag_100ms`
3. `sharded_512`
4. `sharded_1024`
5. `sharded_2048`
6. `rx_prefetch`
7. `udp_seg2`
8. `udp_seg4`
9. `udp_seg8`
10. `sharded_rxprefetch`
11. `sharded_udp4`
12. `all_p2`

Any winner should then be repeated with multiple independent runs before promotion. A single screening run is not sufficient to establish a new default.

## Static regression checks

`test_p5_performance2_transform.py` creates a compact synthetic super-performance datapath and verifies six transform cases: baseline, diagnostics, sharded handoff, RX prefetch, UDP segmentation, and all features combined. The build helper and Mac preflight run this test automatically.

This catches transform-anchor regressions and combination bugs, but it does not substitute for compiling and running on idex/tinyman.

## Mac runner

From the P5 directory on the Mac:

```bash
bash ./mac_run_p5_performance2.sh
```

A useful first screen is:

```bash
bash ./mac_run_p5_performance2.sh --tests baseline,sharded_1024,rx_prefetch,udp_seg4,all_p2
```

Results are copied to `~/Downloads/P5_PERFORMANCE2_<timestamp>/`.

## Scope

These experiments cover the remaining high-value ideas identified from the current P5/Linux comparison: startup diagnosis, reducing producer handoff synchronization, receive-side cache prefetching on the existing batch path, and hardware UDP segmentation. They do not imply that no future optimization can exist; performance work cannot be proven exhaustive without measurement and profiling of the resulting system.
