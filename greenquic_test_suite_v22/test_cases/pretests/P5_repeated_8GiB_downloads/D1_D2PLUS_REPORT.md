# D1 vs D2+ measurement/report variant

This variant preserves the existing P5/P7 reports and adds `the_sheet_rules_all/d1_d2plus/`.

## Semantics

- **D1**: first 8-GiB download on the fresh QUIC connection.
- **D2+**: all later downloads on the **same QUIC connection**.
- Additive metrics (energy, idle residency, packet/hint totals) are normalized per download so D1 and D2+ are comparable.
- Rate metrics (goodput, power, frequency) are computed from timestamped windows, not from already-rounded chart values.
- **G1** is the gap after D1; **G2+** are later gaps.
- Position-cycle comparisons use D1+G1 versus later downloads that have a following gap. The final download is excluded from cycle comparison because it has no following inter-download gap.

## P5 V2 measurement rules

The ordinary Performance2 binary and the ordinary 62-chart report remain unchanged. The D1/D2+ build is an isolated disposable-source variant with marker `GREENQUIC-P5-D1D2PLUS-SNAPSHOT-V2`.

Boundary snapshot work is kept outside the client goodput timing interval: the start snapshot is taken before `StartUs`, and the completion timestamp is taken before the end snapshot. Snapshot output is buffered in memory and printed only at process exit, so there is no request-boundary `printf` in the measured transfer.

The V2 snapshot reuses only counters that are already safe to read concurrently:

- existing atomic DPDK transfer-window RX/TX packet counters;
- GreenQUIC+ hint counters via their getter.

It intentionally **does not** read worker-owned EPOLL/DVFS policy counters concurrently and does not add new per-poll/per-policy counter operations. D1/D2+ chart slots that require those counters are therefore explicitly unavailable instead of being populated with unsafe or performance-perturbing data. Timestamped frequency samples still provide actual frequency behavior and frequency-change metrics.

The C RAPL sampler stores `sample_monotonic_ns` at the **end** of each measured interval. V2 attributes each energy delta to `[sample_monotonic_ns - actual_interval, sample_monotonic_ns]`. This fixes the earlier forward shift at active/gap boundaries.

Build:

```bash
P5_BUILD_REUSE=1 bash ./build_p5_performance2_d1d2plus.sh
```

Matrix:

```bash
bash ./run_matrix_with_sheet_d1d2plus.sh ... --output-dir <matrix-dir>
```

## P7 V2

P7 uses its normal Linux binary and normal timestamped measurement files. No Linux transport instrumentation is added. The V2 D1/D2+ reporter applies the same corrected RAPL interval-end semantics and produces the D1/D2+ report after the ordinary P7 report.

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
