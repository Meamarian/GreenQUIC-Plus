# P5 one-core claim, bottleneck, and 11 Gbit/s research plan

## Reference result

The reference is the promoted one-DPDK-owner Super Performance configuration: DPDK lcore 19, QUIC CPUs 21--24, cache 128, RX burst 32, TX burst 16, software TX ring 4096, drain 2, mbuf-local TX/RX metadata, and single-TX-owner lock elision. The completed three-download result reported OFF steady D2+ 9.423551 Gbit/s and PLUS steady D2+ 10.486178 Gbit/s. This suite always treats 11 Gbit/s as a measurement target, never as an assumed result.

## Stage 1: claim proof and recorder invariance

`run_p5_claim_proof_suite.sh` builds the exact Super binary once and reuses the same bytes for OFF/BASIC/PLUS and the policy ablations. `GQ_CLAIM_DISABLE_ACTIVE_RECORDERS=1` disables only asynchronous ACPI, high-rate RAPL/MSR, C-state, and frequency samplers while leaving `ENABLE_RECORD=1`, workload timing, runtime INI generation, boundary RAPL, result bundling, and the binary unchanged.

The analyzer requires stable executable/libmsquic hashes, the same one-core runtime topology, equal recorder-ON/OFF runtime configs, and a predeclared goodput-equivalence bound. A quick 2-run screen is directional. A publication recorder-invariance claim requires at least six paired repetitions and the two-sided 90% CI to remain inside the predeclared bound.

Valid claim wording is narrow: **under the evaluated one-DPDK-owner P5 configuration, GreenQUIC+ PLUS can achieve higher steady goodput than strict OFF using the same optimized MsQuic-DPDK binary and topology.** This is not a universal claim that GreenQUIC+ is faster than every MsQuic-DPDK version.

## Stage 2: gap causality

The historical three-download table contains a strong clue. Solving `3/aggregate = 1/D1 + 2/D2+` gives approximately 8.727 Gbit/s OFF and 8.859 Gbit/s PLUS for D1, only about +1.5%, while D2+ is about +11.3% for PLUS. Therefore the suite directly varies the inter-download gap: 0 s, 1 s, and 5 s, with OFF and PLUS using the same binary.

`run_p5_gap_causality_suite.sh` records normal power/frequency/C-state evidence and reports D1 and D2+ separately. If PLUS-minus-OFF grows materially with the gap, that supports a gap-conditioned carry-over mechanism. This is consistent with reduced idle polling power, thermal recovery, package/turbo headroom, or frequency-state carry-over; the traces are required to distinguish those explanations.

## Stage 3: producer/consumer pacing probe

`run_p5_tx_pacing_probe_suite.sh` keeps the normal one-connection one-DPDK-owner workload and modifies strict OFF only after an empty server TX-ring dequeue. Non-yielding 250/500/1000 ns backoffs test producer/consumer timing without scheduler donation; a separate 1-us sleep case may yield the CPU.

The direct mechanism metric is server packets per non-empty dequeue plus the dequeue-size histogram. A goodput increase accompanied by larger batches supports implicit micro-batching. A gain with sharply fewer empty dequeues supports removal of wasteful polling/coherence traffic. An extra gain only in the yielding sleep case supports an additional scheduler/package-frequency contribution.

## Stage 4: evidence-driven 11 Gbit/s target

The remaining gap from the historical 10.486178 Gbit/s PLUS steady result to 11 Gbit/s is about 4.9%. The target screen is intentionally small and composes only changes that already have evidence or directly test the newly identified timing mechanism.

All three binary profiles are compiled and SHA-cached before traffic:

- `super_d2`: historical Super baseline, drain 2;
- `p2_d2`: Super baseline plus the previously positive Performance2 hot-path combination (TX allocation batch 8, remove unused producer enqueue counter, RX pipeline prefetch 2), drain 2;
- `p2_d5`: the same Performance2 combination with drain 5, included because a previous incomplete Super run observed 10.500011 Gbit/s at drain 5 and needs a valid retry.

The screen then varies only existing PLUS policy timing knobs on the one-core setup: RX/TX empty-poll thresholds 50k, 25k, 10k, or 5k and active-transfer sleep minimum level 4 or 2. The monitor work-wait path remains guarded during an active file transfer; these cases primarily test whether making the existing shallow 1--2 us idle/pacing path eligible earlier improves the producer/consumer interaction.

A one-run screen crossing 11 Gbit/s is **not** accepted as the result. `analyze_p5_11g_target.py` selects the best measured screen candidate, then the suite reruns both the historical Super reference and the winner with repeated downloads. It prints `11G PASS` only when the repeated winner mean is at least 11 Gbit/s. With at least six validation repetitions it separately prints `11G ROBUST PASS` only if the two-sided 90% CI lower bound is also at least 11 Gbit/s.

## Linux-vs-DPDK structural hypothesis

Linux MsQuic can amortize work earlier at the send boundary through multi-message submission and UDP segmentation/coalescing when supported. The raw DPDK path still pays a producer-side per-datagram allocation/enqueue handoff before the DPDK consumer can form a NIC burst. The tests above first determine whether power-policy timing is hiding part of that cost. If the 11G target remains out of reach, the next high-value experiment is a Linux batching/offload ablation plus function-level profiling of packet production/crypto and the QUIC-to-DPDK enqueue boundary, rather than another broad ring-size sweep.

## Master runner

`run_p5_onecore_research_suite.sh` runs `claim,gap,pacing,11g` in that order. Builds may occur between scientific stages, but each stage forbids build changes during its measured comparisons. `mac_launch_p5_onecore_research.sh` syncs the exact Mac commit to IDEX and Tinyman, performs static self-tests on both, and starts the complete suite detached on IDEX.
