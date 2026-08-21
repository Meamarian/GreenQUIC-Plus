# P5 — GreenQUIC+ DPDK repeated-download experiment

`P5` is the internal name for the repeated 8-GiB QUIC download experiment over the optimized DPDK MsQuic datapath. It is not a QUIC protocol version.

## Roles

- **CONTROL HOST**: holds the private checkout and launches the exact paper workflow.
- **SERVER**: runs `quicinteropserver` and the matrix controller.
- **CLIENT**: runs `quicinterop`, started by SERVER over SSH.

Our paper defaults are SERVER=`idex`, CLIENT=`tinyman`, BASTION=`mohsen@coinbase`, and CONTROL SSH key=`$HOME/.ssh/id_ed25519`. They are centralized in `results_analysis/paper_testbed_defaults.sh`; they are not role semantics.

SERVER -> CLIENT root SSH is required. CLIENT -> SERVER SSH is not required. The high-level setup/run/monitor wrappers accept explicit host/bastion/key switches for another deployment.

---

## Final paper workload

```text
6 independent runs
5 sequential 8-GiB downloads per run
one QUIC connection per run
5 s gaps
5 s edge cooldown
5 s between workloads
balanced OFF/BASIC/PLUS order
seed 20260806
```

Modes:

```text
OFF    MsQuic-DPDK; GreenQUIC power policy bypassed
BASIC  GreenQUIC physical DPDK policy
PLUS   GreenQUIC+ physical policy + QUIC semantic hints/guards
```

All three modes use the same optimized Performance2 V2 datapath.

Required binary marker:

```text
GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0
```

Final TOP3 policy settings:

```text
PRESSURE_UP=450
RX_QUEUE_HIGH=48
ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16
FREQ_PERIOD_US=10000
GQ_IDLE_MODE_OVERRIDE=monitor
GQ_IDLE_FALLBACK_OVERRIDE=short
```

Final CPU topology:

```text
ENABLE_MULTICORE=0
DPDK owner CPU=19
MsQuic worker CPUs=21,22,23,24
```

---

## Exact remote paths

On both SERVER and CLIENT:

```text
Experiment directory:
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads

Build script:
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/build_p5_performance2.sh

Build directory:
/root/mohsen/msquic/build-greenquic-p5

CLIENT executable:
/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop

SERVER executable:
/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinteropserver
```

---

## Exact paper execution

Do not manually start the P5 server/client for the paper comparison. Use the high-level combined P5/P7 runner.

**RUN ON: CONTROL HOST:**

```bash
bash results_analysis/run_paper_evaluation.sh
```

Immediately in **a second CONTROL-HOST terminal:**

```bash
bash results_analysis/live_monitor_run.sh
```

For another management topology, `run_paper_evaluation.sh` accepts `--server-host`, `--client-host`, `--bastion`, and `--ssh-key`; `--client-host` is the CLIENT endpoint as seen from SERVER. Pass the same SERVER/bastion/key values to `live_monitor_run.sh`.

The runner fixes exact `main`, transfers the SHA by Git bundle, rebuilds/verifies P5 and P7, injects TOP3 and recorder settings, runs the P5 matrix, transitions to P7, validates evidence, and packages both results.

The low-level authoritative implementation is:

```text
mac_run_p5_p7_fair_repro_6x5.sh
```

`_v2.sh` and `_v3.sh` are compatibility wrappers only.

---

## Rebuild P5/P7 without redeploying source

Use this only when `/root/mohsen`, dependencies, hugepages and DPDK are already correct and current.

**RUN ON: CONTROL HOST:**

```bash
bash results_analysis/rebuild_paper_binaries.sh
```

Immediately in **a second CONTROL-HOST terminal:**

```bash
bash results_analysis/live_monitor_setup.sh
```

If source changed or the remote checkout may be stale, use `results_analysis/setup_paper_testbed.sh` instead. Rebuild/setup monitors accept explicit role-host switches for non-paper management names.

---

## Historical filenames

Files such as `run_matrix_from_idex.sh` and `run_matrix_from_idex_core.sh` retain historical names from the original testbed. The filename does not force SERVER to be named `idex`; current high-level orchestration supplies the selected CLIENT endpoint explicitly. Some lower-level diagnostic messages/defaults also preserve the old paper names, but they are not used to select roles in the authoritative combined workflow.

Older tuning/bottleneck documents in this directory are research history, not the current paper operating guide.

Current guides are:

```text
README.md at repository root
results_analysis/README.md
tum_testbed_setup/README.md
this README
```

---

## Output

P5 matrix outputs are stored under:

```text
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/matrix_results/
```

The combined paper runner additionally creates `/root/GQ_FAIR_REPRO_<TAG>/`, a controller log, `config.env`, and final P5/P7 ZIP paths on the SERVER role. See `results_analysis/README.md`.
