# P5 Performance2: Remaining Goodput Experiments

`performance2/p5-max-goodput` is an isolated research branch created from the measured `performance/p5-max-goodput` base. The stable performance branch is not modified by this work.

The branch keeps the measured P5 base unchanged unless an experiment explicitly overrides it:

- mbuf cache 128
- RX burst 32
- TX burst 16
- software TX ring 4096
- bounded TX drain 2
- TX/RX metadata in mbuf private storage
- one designated TX owner with measured lock elision
- existing transfer-window and packet-total instrumentation enabled

No GreenQUIC/GreenQUIC+ pressure thresholds, hint rules, DVFS rules, sleep rules, idle semantics, or OFF/BASIC/PLUS semantics are changed by the Performance2 goodput experiments.

## Why a second branch

The remaining ideas are more architectural than the already measured cache/burst/metadata/drain changes. Every new feature is independently switchable and defaults to the existing Performance2 baseline. This lets the screen attribute a gain or regression to one change instead of hiding it inside an all-at-once configuration.

## Performance2 V1 switches

`build_p5_performance2.sh` keeps the original Performance2 controls:

- `P5_P2_DIAG_INTERVAL_US=0|N` — startup diagnostic interval; `0` disables it.
- `P5_P2_DIAG_DURATION_MS=N` — maximum startup diagnostic duration; default 3000 ms.
- `P5_P2_TX_HANDOFF=shared|sharded` — original shared MP software ring or per-producer SPSC rings.
- `P5_P2_TX_PRODUCER_RING_SIZE=256|512|1024|2048|4096` — size of each SPSC producer ring.
- `P5_P2_RX_PREFETCH=0|1` — whole-burst RX prefetch before the parse loop.
- `P5_P2_UDP_SEG=0|1` — experimental UDP segmentation path; default OFF.
- `P5_P2_UDP_SEG_MAX=2|4|8` — maximum logical UDP datagrams grouped by that experimental path.

The first idle/power screen showed that none of the V1 sharding/prefetch variants beat the baseline for PLUS goodput, so the V2 screen keeps only `sharded_1024` as a control for the new active-ring optimization and moves the main effort to remaining per-packet hot-path costs.

## Performance2 V2 switches

The second-stage transform `apply_p5_performance2_v2.py` adds independently measurable experiments:

- `P5_P2_TX_ALLOC_BATCH=1|8|16|32`
- `P5_P2_TX_ENQUEUE_COUNTER=0|1`
- `P5_P2_TX_META_ZERO=0|1`
- `P5_P2_RX_PIPE_PREFETCH=0|2|4`
- `P5_P2_SHARD_ACTIVE_MASK=0|1`

### TX allocation bulk refill

`P5_P2_TX_ALLOC_BATCH>1` uses `rte_pktmbuf_alloc_bulk()` to refill a small thread-local stash and then returns one mbuf immediately for each `CxPlatDpRawTxAlloc()` call.

This is allocation batching only. It does **not** wait for multiple QUIC packets, coalesce QUIC packets, or change packet ordering/timing. If a bulk refill cannot be satisfied, the path falls back to the original single `rte_pktmbuf_alloc()` behavior.

### Remove only the unused producer counter

`P5_P2_TX_ENQUEUE_COUNTER=0` removes the per-packet `TxEnqueueCounter` producer-side write while deliberately preserving the packet totals required by the P5 validator:

- `RxCounter += BuffersCount`
- `TxCounter += TxCount`

### Reduced TX metadata zeroing

`P5_P2_TX_META_ZERO=0` does **not** leave the send object uninitialized. It still clears the full `CXPLAT_SEND_DATA` portion so MsQuic/common send state remains deterministic. It only avoids clearing trailing DPDK-private fields that are explicitly assigned immediately afterward.

This experiment is intentionally disabled with the experimental UDP-segmentation path.

### Pipelined RX prefetch

`P5_P2_RX_PIPE_PREFETCH=2|4` prefetches mbuf metadata and packet data a small distance ahead inside the existing parse loop instead of prefetching the whole burst first.

It is mutually exclusive with the older `P5_P2_RX_PREFETCH=1` experiment so the result measures one prefetch strategy at a time.

### Sharded active-ring mask

`P5_P2_SHARD_ACTIVE_MASK=1` is valid only with `P5_P2_TX_HANDOFF=sharded`. Producers set their active bit after a successful enqueue. The TX owner skips inactive producer rings and clears a bit only after the ring becomes empty, with a re-check to close the producer enqueue / consumer clear race.

## V2 goodput screen

`run_p5_performance2_goodput_screen.sh` tests both requested workload profiles for every candidate:

- `idle_monitor_normal`
- `power_friendly`

It records OFF, BASIC, and PLUS aggregate active goodput and writes both the raw summary and the delta versus baseline.

The current profiles are:

1. `baseline`
2. `txalloc_8`
3. `txalloc_16`
4. `txalloc_32`
5. `no_tx_enqueue_counter`
6. `no_tx_meta_zero`
7. `rxpipe_2`
8. `rxpipe_4`
9. `sharded_1024`
10. `sharded_1024_mask`
11. `txalloc16_no_counter`
12. `txalloc16_no_zero`
13. `lean_tx`
14. `lean_tx_rxpipe4`
15. `lean_tx_sharded1024_mask`

The first screen should use one independent repetition and three downloads. It is a directional screen only; `sd=0` with `n=1` does not demonstrate stability. Promote a candidate only after a multi-run follow-up.

## Recommended Mac command

From the GreenQUIC repository on the Mac:

```bash
git fetch origin performance2/p5-max-goodput && \
git checkout performance2/p5-max-goodput && \
git reset --hard origin/performance2/p5-max-goodput && \
P5_P2_RUNS=1 P5_P2_DOWNLOADS=3 \
bash greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p2_goodput_screen_v4.sh --detach
```

The V4 runner:

- verifies both hosts are clean;
- transfers the exact branch SHA to idex and tinyman;
- runs shell/Python transform preflight on both hosts;
- starts the long experiment on idex with `nohup setsid`, so a temporary Mac-to-idex SSH failure cannot kill the remote job;
- distinguishes SSH transport failure from a real remote command failure;
- creates the export only after the screen finishes;
- builds `SHA256SUMS` using `find -print0 | sort -z | xargs -0`;
- waits for remote `DONE`;
- copies each result through a `.part` file and verifies SHA256 before rename;
- creates local `SCP_DONE` only after the complete export verifies.

A mid-test idex-to-tinyman control-link failure can still make that workload fail; detaching the idex wrapper cannot repair a broken testbed control connection. The wrapper will survive and export the resulting return codes for diagnosis.

## Live check command

This automatically selects the newest P2 goodput run and shows the Mac orchestrator plus remote progress when the remote job has started:

```bash
PIDFILE="$(ls -t "$HOME"/Downloads/P5_P2_GOODPUT_*.mac.pid 2>/dev/null | head -1)"
LOG="${PIDFILE%.mac.pid}.mac.log"

echo "=== MAC RUNNER ==="
echo "PIDFILE=$PIDFILE"
PID="$(cat "$PIDFILE")"
ps -p "$PID" -o pid=,ppid=,stat=,etime=,args=

echo
echo "=== LATEST MAC LOG ==="
tail -40 "$LOG"

echo
echo "=== REMOTE P2 PROGRESS ==="
ssh idex '
LOG=$(ls -t /root/P5_P2_GOODPUT_*.log 2>/dev/null | head -1)
if [ -n "$LOG" ] && [ -f "$LOG" ]; then
    echo "REMOTE_LOG=$LOG"
    grep -E "PROFILE=|IDLE|POWER|BUILD FAILED|SUCCESS:|FAILURES=|ERROR:|PERFORMANCE2 V2 GOODPUT|DELTA VS BASELINE" "$LOG" | tail -80
else
    echo "Remote experiment has not started yet."
fi
'
```

## Results-so-far command

This shows completed rows while the screen is still running:

```bash
ssh idex '
R=$(ls -td /tmp/P5_P2_GOODPUT_SCREEN_* 2>/dev/null | head -1)

echo "=== RESULT ROOT ==="
echo "$R"

echo
echo "=== STATUS ==="
cat "$R/status.env" 2>/dev/null || true

echo
echo "=== GOODPUT RESULTS SO FAR ==="
column -t -s "$(printf "\t")" "$R/goodput_screen_summary.tsv" 2>/dev/null \
    || cat "$R/goodput_screen_summary.tsv" 2>/dev/null \
    || true

echo
echo "=== DELTA VS BASELINE ==="
column -t -s "$(printf "\t")" "$R/goodput_screen_vs_baseline.tsv" 2>/dev/null \
    || cat "$R/goodput_screen_vs_baseline.tsv" 2>/dev/null \
    || true
'
```

`goodput_screen_vs_baseline.tsv` is written after the screen can calculate the baseline comparison. During an active run, `goodput_screen_summary.tsv` is the primary results-so-far file.

## Completion check

For a completed Mac export, `SCP_DONE` is the definitive success marker because it is created only after the downloaded files pass SHA256 verification:

```bash
ls -lh "$HOME"/Downloads/P5_P2_GOODPUT_EXPORT_*/SCP_DONE
```

The final export contains the summary TSVs, status/return-code files, remote log, analysis archive, matrix archive, `SHA256SUMS`, and `SCP_DONE`.

## Static regression checks

`test_p5_performance2_transform.py` validates the original Performance2 transform anchors and feature combinations.

`test_p5_performance2_v2_transform.py` independently checks:

- bulk-refill allocation insertion;
- removal of only `TxEnqueueCounter`;
- preservation of required RX/TX packet totals;
- safe reduced TX send-data zeroing;
- pipelined RX prefetch;
- sharded active-mask insertion and clear/enqueue race protection;
- illegal feature combinations.

`build_p5_performance2.sh` runs both self-test layers before compiling the real P5 binaries.

## Scope

Performance2 targets remaining datapath hot-path and startup costs while keeping GreenQUIC/GreenQUIC+ policy semantics unchanged. A true multi-packet MsQuic raw-send batch is deliberately not faked by holding packets in the datapath: the current raw send contract hands one send object down at a time, and waiting for a batch could delay or strand the tail packet. Any future true send-batch API must first preserve MsQuic send-object ownership, completion, ordering, and latency semantics.
