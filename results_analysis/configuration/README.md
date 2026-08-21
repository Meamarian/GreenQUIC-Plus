# GreenQUIC+ paper evaluation configuration

These files describe the **configuration used for the GreenQUIC+ paper evaluation**.

Files in this directory:

```text
p5_paper_evaluation.json   final P5 OFF/BASIC/PLUS workload, datapath and TOP3 policy
p7_paper_evaluation.json   final isolated Linux P7 workload/network/recording profile
experiment_paths.json      role, SSH, directory, binary and result-path definitions
dependencies.json          source versions, OS/package policy and hardware assumptions
```

## Roles versus host names

The experiment uses semantic roles SERVER and CLIENT. In our paper testbed:

```text
SERVER=idex
CLIENT=tinyman
```

Those names are provenance/defaults only. Management connectivity is centralized in `../paper_testbed_defaults.sh`. The paper data-plane IP/MAC/CPU/NIC values remain part of the evaluated configuration and are independent of SSH host names.

---

## P5: OFF, BASIC and PLUS

Final workload:

```text
6 independent runs
5 sequential 8-GiB downloads per run
5 s gaps
5 s edge cooldown
5 s between tests
balanced mode order
seed 20260806
max_throughput execution profile
```

Final topology:

```text
ENABLE_MULTICORE=0
DPDK CPU=19 on both endpoints
MsQuic worker CPUs=21,22,23,24 on both endpoints
```

Required Performance2 V2 binary marker:

```text
GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0
```

Final focused power-policy configuration: **TOP3**.

| Parameter | Final value | Effective mode(s) |
|---|---:|---|
| `PRESSURE_UP` | 450 | BASIC + PLUS |
| `RX_QUEUE_HIGH` | 48 | BASIC + PLUS |
| `ACTIVE_TRANSFER_SLEEP_MIN_LEVEL` | 16 | PLUS only |
| `GQ_IDLE_MODE_OVERRIDE` | monitor | BASIC + PLUS |
| `GQ_IDLE_FALLBACK_OVERRIDE` | short | BASIC + PLUS |
| `FREQ_PERIOD_US` | 10000 | BASIC + PLUS |

The complete effective policy/runtime values are in `p5_paper_evaluation.json`.

### P5 recorder validation

The final runner uses `GQ_CLAIM_RECORDER_CPU=auto` and validates recorder placement from evidence that survives normal result bundling. It requires a complete `matrix_integrity.json` and checks every canonical server/client OFF/BASIC/PLUS run log for the selected CPU of the whole-system power, C RAPL, Linux C-state, and CPU-frequency recorders.

Validator:

```text
greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/validate_p5_recorder_evidence.py
```

The durable result is saved as:

```text
/root/GQ_FAIR_REPRO_<TAG>/p5_recorder_evidence.json
```

`*_affinity.txt` sidecars are optional evidence. Their absence after bundling is **not** a final-run failure condition.

---

## P7: Linux MsQuic baseline

P7 is a Linux MsQuic build with:

```text
DPDK disabled
XDP disabled
normal Linux UDP socket datapath
Release build
OpenSSL TLS
```

It uses the same 6 × 5 workload timing. CPU19 is the Linux dataplane-side IRQ/NAPI/softirq target and CPUs21-24 are MsQuic workers.

Final network/recording settings include:

| Parameter | Final value |
|---|---|
| Server/client data-plane IP | `192.168.100.1` / `192.168.100.2` |
| Prefix | `/24` |
| Port | `4433` |
| MTU | `1500` |
| UDP rmem default/max | `6815744` bytes |
| UDP wmem default/max | `6815744` bytes |
| Combined channels | `1` |
| RPS | disabled |
| test-NIC RDMA auxiliary child | temporarily disabled |
| RAPL cadence | `6 ms` |
| frequency cadence | `1 ms` |

The `paper` offload profile requires TSO, GSO, TX checksum and GRO ON. UDP segmentation, RX checksum and hardware GRO are enabled best-effort when supported. The P7 wrapper restores the pre-P7 DPDK driver after the Linux matrix.

See `p7_paper_evaluation.json` for the full machine-readable record.

---

## Final result handling

The default final run is launched from the CONTROL HOST with `results_analysis/run_paper_evaluation.sh`. The first CONTROL-HOST terminal waits for remote `DONE`; a second CONTROL-HOST terminal follows the exact run log with `results_analysis/live_monitor_run.sh`.

Before any result SCP begins, the final workflow prints:

```text
remote controller artifact directory
remote P5 matrix directory
remote P7 matrix directory
remote P5 ZIP
remote P7 ZIP
final CONTROL-HOST destination
```

It then performs automatic SCP by default into:

```text
$HOME/Downloads/GreenQUIC-Plus/reproduced_results/<TAG>/
```

SERVER creates `RESULT_DIRS.env`, `RESULT_ZIPS.txt`, and `RESULT_ZIPS.sha256`; CONTROL verifies the downloaded ZIP SHA-256 values and the critical paper configuration before success is reported. `--no-auto-download` is an explicit opt-out.

---

# Static configuration checks

**RUN ON: CONTROL HOST:**

```bash
python3 results_analysis/verify_paper_configuration.py
```

**LIVE MONITOR:** not applicable; this is a local synchronous static check and does not start a remote process.

For the broader repository/layout/artifact/dependency check:

**RUN ON: CONTROL HOST:**

```bash
bash results_analysis/final_repository_check.sh
```

**LIVE MONITOR:** not applicable; this is also local and synchronous.
