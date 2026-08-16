# D1 vs D2+ measurement/report variant

This variant preserves the existing P5/P7 reports and adds `the_sheet_rules_all/d1_d2plus/`.

## Semantics

- **D1**: first 8-GiB download on the fresh QUIC connection.
- **D2+**: all later downloads on the **same QUIC connection**.
- Additive metrics (energy, idle residency, counter/action totals) are normalized per download so D1 and D2+ are comparable.
- Rate metrics (goodput, power, frequency) are computed from the timestamped windows, not by averaging already-rounded chart values.
- **G1** is the gap after D1; **G2+** are later gaps.
- Position-cycle comparisons use D1+G1 versus later downloads that have a following gap. The final download is excluded from the cycle comparison because it has no following inter-download gap.

## P5

The original 62-chart report remains unchanged. The D1/D2+ report reproduces all 62 chart slots in both `without_variance` and `with_variance` (±1 SD), and adds charts 63-70 for C-state residency, package/DRAM energy, duration, and goodput ratio.

Several original chart families are based on process-end cumulative counters and cannot be split truthfully from an old archive. The D1/D2+ build therefore adds low-overhead **boundary snapshots** at request start/completion. It does not add packet/poll-loop logging. The report requires these snapshots for exact D1/D2+ attribution of EPOLL counters, policy-action counts, QUIC hint counters, and DPDK packet counters. Old archives show those charts as explicitly unavailable rather than copying whole-run totals into both positions.

Build:

```bash
P5_BUILD_REUSE=1 bash ./build_p5_performance2_d1d2plus.sh
```

Matrix:

```bash
bash ./run_matrix_with_sheet_d1d2plus.sh ... --output-dir <matrix-dir>
```

## P7

P7 already records exact per-download active windows plus timestamped RAPL/frequency/C-state data. No Linux transport instrumentation is added. The wrapper runs the normal P7 matrix/report and then creates 18 D1/D2+ counterparts plus 6 C-state extras.

```bash
bash ./run_p7_d1d2plus.sh ... --output-dir <matrix-dir>
```

## Final Performance2 + P7 PAPER run

From the GreenQUIC repository on the Mac:

```bash
P5_FINAL_RUNS=6 P5_FINAL_DOWNLOADS=6 \
bash greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p2_final_6x6_d1d2plus_p7_paper_v1.sh --detach
```

The P7 settings remain the PAPER configuration: 5-s gaps, 5-s pre/post cooldown, 10-s between repetitions, CPU19, QUIC CPUs 21-24, IRQ/QUIC pinning, RPS/RDMA disabled, paper offloads, UDP rmem/wmem 6815744, one combined channel, RAPL 6 ms, frequency 1 ms, MTU 1500.
