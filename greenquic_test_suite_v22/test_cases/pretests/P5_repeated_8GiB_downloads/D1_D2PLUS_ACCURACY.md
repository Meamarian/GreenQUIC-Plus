# D1/D2+ timing and alignment accuracy

The D1/D2+ report separates the first transfer (`D1`) from later transfers (`D2+`) without changing the legacy report.

## Clock and edge semantics

- **Goodput**: request start/completion are `std::chrono::steady_clock` timestamps serialized in microseconds. Snapshot instrumentation is outside the timed interval.
- **P5 cross-host alignment**: `clock_sync.py` v2 directly estimates `tinyman CLOCK_MONOTONIC - idex CLOCK_MONOTONIC` with a minimum-RTT SSH midpoint estimator. The reported uncertainty is half the selected RTT. No zero-offset fallback is permitted.
- **RAPL**: each row is an energy delta over `[sample_monotonic_ns - actual_interval, sample_monotonic_ns]`. Integration clips fractional overlap at every D1/D2+/gap edge. Plot points use the midpoint of the clipped overlap.
- **Frequency**: each sysfs read is bracketed with MONOTONIC timestamps; the midpoint is stored as `monotonic_ns`, with `read_span_ns` and `read_uncertainty_ns`. Scalar means are time-weighted with midpoint cells rather than sample-count averages.
- **C-state**: kernel `cpu_idle` intervals use MONOTONIC_RAW and are mapped into MONOTONIC with start/end bridge calibrations. Idle intervals are clipped exactly at phase boundaries.
- **Counter/hint snapshots**: client snapshots bracket the timed request externally; server completion uses `QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE`. Snapshot-vs-goodput edge residuals are measured and reported.

## Recorder coverage

P5 and P7 start RAPL/frequency/C-state recorders before the transfer workload and stop them after the transfer/post-cooldown. The V3 report verifies that the first and last active edges are covered by RAPL and frequency traces. Missing/truncated coverage makes the D1/D2+ wrapper fail instead of silently drawing charts.

## Accuracy number

`alignment_quality.json` reports the measured value for each smoke/main run.

The reported `temporal_alignment_accuracy_pct` is a conservative window-alignment score:

`100 * (1 - 2 * worst_edge_uncertainty / median_active_download_duration)`

It is **not** a claim about Intel RAPL's absolute electrical/model accuracy.

For a representative 6.5-second 8-GiB transfer, the configured 6-ms RAPL cadence alone gives a conservative temporal score of about **99.815%**. A 1-ms frequency cadence corresponds to about **99.985%** under the same two-edge calculation. P5 server/combined accuracy additionally includes the measured cross-host clock uncertainty and request-edge residual spread, so its final number must come from the smoke test.

Quality gates used by V3:

- server CLOCK_MONOTONIC sync uncertainty <= 5 ms;
- mapped server GET-edge residual spread <= 5 ms;
- RAPL p95 sample interval <= 15 ms;
- frequency p95 sampling gap <= 5 ms;
- snapshot edge p95 <= 5 ms;
- complete RAPL/frequency coverage of D1..Dn;
- complete start/end snapshot pairs for P5.
