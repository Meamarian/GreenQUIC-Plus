# P5 Performance2 V2 Goodput Experiments

This layer continues `performance2/p5-max-goodput` without changing the measured Performance1 base or any GreenQUIC/GreenQUIC+ pressure thresholds, hints, DVFS rules, sleep rules, or mode semantics.

The previous focused idle/power screen showed that the original P2 sharded-handoff and whole-burst RX-prefetch variants did not beat the shared-ring baseline for PLUS in either `idle_monitor_normal` or `power_friendly`. V2 therefore targets remaining per-packet hot-path costs and retests only the one sharded configuration needed to evaluate a cheaper active-ring consumer.

## New switches

All defaults reproduce the pre-V2 Performance2 behavior.

- `P5_P2_TX_ALLOC_BATCH=1|8|16|32`, default `1`.
  - Values above 1 refill a producer-thread TLS stash with `rte_pktmbuf_alloc_bulk()` and still return exactly one mbuf immediately for each `CxPlatDpRawTxAlloc()` call.
  - This is allocator amortization, not QUIC packet batching: it never waits for more packets and never changes wire packetization.
- `P5_P2_TX_ENQUEUE_COUNTER=0|1`, default `1`.
  - `0` removes only the unused producer-side `TxEnqueueCounter` update.
  - Required P5 `RxCounter` and `TxCounter` totals remain enabled.
- `P5_P2_TX_META_ZERO=0|1`, default `1`.
  - `0` removes the whole-struct zero of mbuf-private `DPDK_TX_PACKET` storage; the normal non-USO raw TX allocator explicitly assigns the fields it consumes.
  - It is rejected with experimental UDP segmentation because USO adds extra metadata.
- `P5_P2_RX_PIPE_PREFETCH=0|2|4`, default `0`.
  - Prefetches packet `i+2` or `i+4` while parsing packet `i`, instead of doing a complete prefetch pass before parsing.
  - It is mutually exclusive with the original `P5_P2_RX_PREFETCH=1` path.
- `P5_P2_SHARD_ACTIVE_MASK=0|1`, default `0`.
  - Valid only with `P5_P2_TX_HANDOFF=sharded`.
  - Producers set a bit after a successful SPSC enqueue; the TX owner scans only rings marked active. A clear-then-recheck sequence prevents a concurrent producer from leaving a non-empty ring permanently unmarked.

The V2 transform is applied after the measured Performance1 transform and the original Performance2 V1 transform. Binaries contain both `GREENQUIC-P5-PERFORMANCE2-V1` and `GREENQUIC-P5-PERFORMANCE2-V2` markers.

## Focused goodput screen

`run_p5_performance2_goodput_screen.sh` tests the following profiles in order:

1. `baseline`
2. `txalloc_8`
3. `txalloc_16`
4. `txalloc_32`
5. `no_tx_enqueue_counter`
6. `no_tx_meta_zero`
7. `rxpipe_2`
8. `rxpipe_4`
9. `sharded_1024` (control for the mask experiment)
10. `sharded_1024_mask`
11. `txalloc16_no_counter`
12. `txalloc16_no_zero`
13. `lean_tx` (`txalloc16 + no counter + no zero`)
14. `lean_tx_rxpipe4`
15. `lean_tx_sharded1024_mask`

Every profile runs exactly the two workloads requested for the goodput screen:

- `idle_monitor_normal`: monitor idle + short fallback.
- `power_friendly`: frequency scaling ON, sleep ON, epoll idle + short fallback.

The default is 1 repetition x 3 downloads per workload. Results include:

- `goodput_screen_summary.tsv`
- `goodput_screen_vs_baseline.tsv`
- `status.env`
- per-profile build and workload logs
- the complete matrix result tree.

The delta table compares every OFF/BASIC/PLUS result against the matching baseline workload/mode. A one-run screen is screening evidence only; validate a winning profile with multiple independent repetitions before promotion.

## V4-style detached Mac runner

Use `mac_run_p2_goodput_latest.sh`, which points to `mac_run_p2_goodput_screen_v4.sh`.

The runner reuses the resilience pattern from the P1/P2 V4 chain:

- fetch the exact `performance2/p5-max-goodput` SHA and bundle it to both hosts;
- retry Mac -> idex and idex -> tinyman transport failures;
- verify both hosts are clean and on the exact same commit;
- preflight shell syntax, Python syntax, and the V2 transform selftest on both hosts;
- launch the long screen on idex with `nohup setsid`, so a broken Mac SSH session cannot kill the experiment;
- wait for a remote `DONE` marker rather than holding the experiment under SSH;
- build the remote manifest with `find -print0` (fixing the previous nested-quoting NUL bug);
- copy every result through a `.part` file, verify SHA256, retry transport/hash failures, and create local `SCP_DONE` only after the complete manifest verifies.

Default local export:

```text
~/Downloads/P5_P2_GOODPUT_EXPORT_<TAG>/
```

A successful run ends with:

```text
~/Downloads/P5_P2_GOODPUT_EXPORT_<TAG>/SCP_DONE
```

## Deliberately not faked: tail-delaying QUIC packet batching

The current raw send contract hands the datapath one `CXPLAT_SEND_DATA` and immediately calls `CxPlatDpRawTxEnqueue()`. Holding those calls until an arbitrary packet count is reached would add latency to the tail packet and could alter packet lifetime/order. A true bulk handoff should be added only at a point where MsQuic already owns multiple ready datagrams in one send turn. V2 therefore optimizes allocation/handoff work without inventing a wait-for-N-packets mechanism.
