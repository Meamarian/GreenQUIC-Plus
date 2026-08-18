# P5 one-core claim proof and fast bottleneck localization

This document defines the experiments used to separate three questions that were previously mixed together:

1. Is the measured one-DPDK-owner GreenQUIC+ goodput advantage real when compared with strict-OFF MsQuic-DPDK using the **same optimized binary**?
2. Do the measurement/recording processes materially perturb active-transfer goodput or alter the GreenQUIC runtime configuration?
3. If PLUS improves goodput indirectly, is the gain caused by QUIC-to-DPDK pacing/micro-batching, reduced producer-consumer interference, scheduler donation, or a frequency/package-power effect?

The tests deliberately make a narrower claim than “GreenQUIC+ is always faster than MsQuic.” Strict OFF is the GreenQUIC policy-bypass mode of the same P5 raw-DPDK binary. A valid result therefore supports a same-binary P5 comparison only.

## 1. Historical one-core reference that this suite reproduces

The claim suite is anchored to the promoted **P5 Super Performance** one-owner configuration, not to the later multicore/parallel architecture harness.

The exact build settings are pinned in the runner rather than inherited from defaults:

- one DPDK owner at runtime (`ENABLE_MULTICORE=0`, lcore 19);
- four configured MsQuic CPUs 21,22,23,24, kept disjoint from the DPDK lcore;
- `max_throughput` MsQuic execution profile;
- mbuf cache 128;
- RX burst 32;
- TX burst 16;
- software TX ring 4096;
- legacy measured MP producer path;
- bounded TX drain of 2 bursts per worker-loop visit;
- drain threshold 0;
- MTU override disabled, matching the historical Super run;
- TX/RX metadata in mbuf private storage;
- single designated TX-owner lock elision;
- transfer-window and packet-total instrumentation enabled;
- `monitor` idle mode with `short` fallback for the full GreenQUIC policy case.

The completed 2026-08-15 refinement reported, for this promoted profile:

| mode | aggregate goodput | steady D2+ goodput |
|---|---:|---:|
| OFF | 9.179253 Gbit/s | 9.423551 Gbit/s |
| BASIC | 8.776885 Gbit/s | 9.312310 Gbit/s |
| PLUS | 9.881019 Gbit/s | **10.486178 Gbit/s** |

The user-facing shorthand “about 10.43 Gbit/s” refers to this one-core family of results. New experiments must report their newly measured values; they must not force or assume 10.486178 Gbit/s.

## 2. Claims and non-claims

A successful claim-proof run may support the following statement:

> Under the captured one-DPDK-owner P5 configuration, GreenQUIC+ and strict-OFF use the same optimized MsQuic-DPDK binary and the same repeated-download workload. The comparison is not explained by different binary bytes, a different DPDK topology, or different runtime policy files. Disabling only the asynchronous/high-frequency recording processes changes active-transfer goodput by no more than the predeclared equivalence bound.

It does **not** by itself support any of these statements:

- every upstream MsQuic-DPDK version is slower than GreenQUIC+;
- Linux MsQuic is slower than DPDK;
- configured QUIC CPUs prove actual worker execution or hard pinning;
- a one-DPDK-owner result is evidence of multicore scaling;
- an observed correlation between sleep/frequency and goodput proves the causal mechanism without the isolation tests below.

The paper should use “strict-OFF MsQuic-DPDK in the same P5 binary” when that is the actual comparator. A broader “MsQuic-DPDK” claim requires a separately version-pinned upstream/clean implementation comparison.

## 3. Recording-invariance control: disable recorders without changing the experiment

The normal P5 `ENABLE_RECORD=0` switch is **not** a clean recorder-only control. It changes more than sampler processes: it also changes the normal recording/bundling path and post-transfer behavior. Therefore the claim suite always keeps `ENABLE_RECORD=1`.

`enable_p5_claim_recording_gate.py` adds a test-only variable:

```text
GQ_CLAIM_DISABLE_ACTIVE_RECORDERS=1
```

It disables only the asynchronous/high-frequency time-series recorders:

- ACPI/board-power recorder;
- high-rate RAPL/MSR recorder;
- C-state recorder;
- CPU-frequency recorder.

It does **not** disable `ENABLE_RECORD`, does not change the workload, does not change `GQ_POST_TRANSFER_WAIT_S`, does not change mode selection, does not change `dpdk.ini`/`powermng.ini`, and does not change the compiled binary. The controller, start gate, boundary RAPL window, result bundling, and exact client timing markers remain present.

The analyzer fails the recording-invariance claim unless all of the following are true:

- client/server executable SHA-256 values remain identical at every checkpoint;
- linked `libmsquic` SHA-256 remains identical where dynamically linked;
- every captured runtime `dpdk.ini` proves one DPDK lcore 19, `GreenQuicEnableMultiCore=0`, TX owner 19, and QUIC CPUs 21,22,23,24;
- paired recorder-ON/OFF `dpdk.ini` files are exactly equal;
- paired recorder-ON/OFF `powermng.ini` files are exactly equal;
- both **aggregate active goodput** and **steady D2+ goodput** stay within the predeclared equivalence bound.

The default equivalence bound is **±2%**. Set it before running; do not choose it after seeing results. The analyzer also reports a publication criterion: at least six paired repetitions and a two-sided 90% confidence interval for the recorder-OFF versus recorder-ON percentage difference fully inside the ±2% bound.

## 4. One-core claim-proof suite

The exact Super Performance binary is built once on IDEX and Tinyman before traffic. The same bytes are used by OFF/BASIC/PLUS and by every policy ablation.

| Case | Active recorders | Frequency policy | Idle/sleep policy | Purpose |
|---|---:|---:|---:|---|
| `full_recorders_on` | ON | ON | ON, monitor | reproduce the one-core high-goodput GreenQUIC+ family |
| `full_recorders_off` | OFF | ON | ON, monitor | recorder perturbation control |
| `nopwr_recorders_on` | ON | OFF | OFF | hooks/mode comparison with no GreenQUIC DVFS or idle action |
| `nopwr_recorders_off` | OFF | OFF | OFF | second recorder perturbation control |
| `freq_only_recorders_on` | ON | ON | OFF | isolate frequency-side contribution |
| `sleep_only_recorders_on` | ON | OFF | ON, monitor | isolate idle/pacing-side contribution |

The useful interpretation is the **PLUS-minus-OFF** delta across the ablations, and the partial-policy cases must be interpreted relative to `nopwr`, not just relative to OFF:

- if the PLUS advantage survives `nopwr`, there is a mode-specific non-power/timing component;
- if `freq_only` adds a further >threshold increment beyond the `nopwr` PLUS-minus-OFF delta, frequency/package-power behavior is a supported contributor;
- if `sleep_only` adds a further >threshold increment beyond `nopwr`, idle/pacing/scheduler behavior is a supported contributor;
- if both partial ablations add material incremental gain, report a mixed effect instead of assigning one mechanism.

Quick directional run:

```bash
P5_CLAIM_RUNS=2 P5_CLAIM_DOWNLOADS=3 \
  bash ./run_p5_claim_proof_suite.sh
```

Publication-strength repetition:

```bash
P5_CLAIM_RUNS=6 P5_CLAIM_DOWNLOADS=6 \
P5_CLAIM_RECORDING_EQ_PCT=2.0 \
  bash ./run_p5_claim_proof_suite.sh
```

The quick run is screening evidence only. The publication claim should be based on multiple independent repetitions and should report variance.

## 5. Working bottleneck hypothesis

The one-core raw-DPDK transmit path still has a per-datagram producer-side boundary:

```text
MsQuic packet generation
    -> CxPlatDpRawTxAlloc()
    -> one mbuf/send object
    -> rte_ring_mp_enqueue()
    -> shared software TX ring
    -> rte_ring_sc_dequeue_burst()
    -> rte_eth_tx_burst()
    -> NIC
```

The Super Performance work already made many individual handoffs cheaper: mbuf-local metadata, bounded TX drain, single-owner lock elision, cache/burst/ring tuning, and preserved instrumentation. Those optimizations do not remove the fact that each QUIC datagram crosses the QUIC-to-DPDK producer boundary individually before the DPDK consumer can batch packets for NIC transmission.

Linux MsQuic has a structurally different userspace-to-kernel send path: a send object can contain multiple buffers/messages, `sendmmsg()` can submit multiple messages, and UDP segmentation can amortize work further when supported. This makes “early amortization before the final NIC burst” a plausible explanation for part of Linux's higher ceiling. It remains a hypothesis until a controlled Linux batching/offload ablation is measured.

## 6. Fast one-core TX-pacing causal probe

The fast probe uses the **same single-connection repeated-download workload and the same one-owner Super Performance build family**. It does not use the four-parallel-connection multicore architecture harness.

`apply_p5_tx_pacing_probe.py` adds identical lightweight dequeue counters to every probe build and optionally changes only what strict OFF does **after an empty TX-ring dequeue**. It never waits for a packet before enqueue, never changes packet ordering, and never changes a non-empty packet's send-object lifetime.

All probe binaries are built and cached **before the first traffic case**. During the traffic phase the runner only activates immutable cached bytes; compiler invocation is forbidden.

The client always runs the zero-backoff probe binary. Only the IDEX/server binary changes, which isolates the bulk-download server TX-consumer behavior.

| Case | Server empty-dequeue action | Scheduler yield? | Main question |
|---|---|---:|---|
| `p0_no_backoff` | none | no | instrumented Super/OFF baseline |
| `p1_busy_250ns` | ~250 ns TSC busy backoff | no | can tiny producer/consumer spacing help? |
| `p2_busy_500ns` | ~500 ns TSC busy backoff | no | same |
| `p3_busy_1000ns` | ~1 us TSC busy backoff | no | same |
| `p4_sleep_1us` | `rte_delay_us_sleep(1)` | may | is there an extra scheduler/package effect? |

At process shutdown the probe emits role-local counters:

```text
[P5-TX-PACING] backoff_ns=... sleep_us=... empty_dequeues=... nonempty_dequeues=... dequeued_packets=... bin1=... bin2_4=... bin5_8=... bin9_16=... bin17plus=...
```

The principal mechanism metric is the **server** value:

```text
server_packets_per_nonempty_dequeue = server_dequeued_packets / server_nonempty_dequeues
```

Interpretation rules are deliberately conservative:

- busy-wait goodput > baseline by >2% **and** server packets/non-empty-dequeue > baseline by >2%: supports an implicit batching / producer-consumer pacing mechanism;
- busy-wait goodput >2% but batch size does not increase: timing matters, but micro-batching is not established;
- empty-dequeue count falls sharply while goodput rises: supports removal of wasteful consumer polling/coherence activity;
- 1-us server sleep beats the best busy-wait case by >2 percentage points: supports an additional scheduler-donation and/or package-frequency effect because the busy-wait cases do not voluntarily yield the CPU;
- no >2% signal: promote no causal mechanism claim from this quick probe.

Run:

```bash
P5_PACING_RUNS=1 P5_PACING_DOWNLOADS=3 \
  bash ./run_p5_tx_pacing_probe_suite.sh
```

If a case wins, repeat **baseline + winner only** with at least six independent runs before using it as causal evidence.

## 7. How this can explain PLUS improving goodput indirectly

A GreenQUIC+ policy can improve goodput even when its purpose is power management if it changes the timing of the producer-consumer system:

1. **Implicit micro-batching.** A short consumer pause lets the QUIC producer place multiple datagrams into the software ring before the DPDK consumer returns, increasing packets per dequeue/TX burst and amortizing per-burst work.
2. **Reduced cache-line/coherence pressure.** A continuously polling consumer repeatedly touches shared ring state. Short backoff can give the producer an uncontended interval to update producer state.
3. **Scheduler donation.** A blocking/sleeping DPDK thread can give Linux an opportunity to schedule runnable MsQuic work. This explanation is credible only if runtime thread evidence shows the QUIC work can actually use that CPU; configured CPU lists alone are insufficient.
4. **Package power/turbo redistribution.** Reducing useless DPDK polling can free package power/thermal headroom that raises effective frequency on QUIC/crypto work. This must be checked with measured frequency behavior rather than assumed.

The busy-backoff cases separate (1)/(2) from scheduler donation because they keep the DPDK thread runnable. The 1-us sleep case then tests whether a yielding mechanism adds something beyond pure timing.

## 8. Architecture sweep hygiene fix

The A-P architecture sweep is retained as a separate structural study. Its runner now follows two rules:

- baseline, MP, RTS, sharded, and UDP-segmentation binaries are all built and SHA-256 cached before A starts; there is no compilation between A and P;
- F/N may use the multicore-instrumented source path with exactly one DPDK owner as a **single-owner control**, but the validator explicitly warns that this is not evidence of multicore scaling.

P reuses the exact cached baseline bytes used by B, so B-versus-P is a drift/thermal control instead of a rebuild comparison.

## 9. What would identify the remaining Linux-vs-DPDK bottleneck

After the one-core claim is reproduced and the pacing probe is complete, the highest-value next control is a Linux MsQuic batching/offload ablation:

- Linux normal GSO/GRO/send batching;
- Linux with UDP GSO/GRO disabled while keeping the same QUIC workload and CPU placement;
- compare goodput, packets/syscall (or messages/syscall), CPU time, and effective frequency.

If Linux falls materially toward the raw-DPDK ceiling when early batching/offload is removed, that quantifies the structural advantage of the Linux send boundary. If it does not, the next step is function-level profiling of QUIC packet production/crypto and the DPDK handoff rather than more ring-size tuning.

## 10. Publication rule

Do not write “GreenQUIC+ is faster because sleeping improves batching” unless the causal probe actually shows the expected mechanism metrics. The valid progression is:

1. reproduce the one-core PLUS > strict-OFF result with variance;
2. pass recorder invariance and exact-config/binary checks;
3. run power-policy ablations;
4. run the fast OFF pacing intervention;
5. promote only the mechanism whose direct metric changes with goodput;
6. repeat baseline + winning intervention with enough independent runs.
