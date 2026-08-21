# P5 — GreenQUIC+ DPDK repeated-download experiment

`P5` is the internal name for the repeated 8-GiB QUIC download experiment over the optimized DPDK MsQuic datapath. It is not a QUIC protocol version.

## Roles and where commands run

- **CONTROL HOST**: has the private repository checkout and launches the authoritative combined P5/P7 paper reproduction.
- **SERVER**: runs `quicinteropserver` and the matrix controller.
- **CLIENT**: runs `quicinterop`, started remotely by SERVER over SSH.

In our paper testbed SERVER=`idex` and CLIENT=`tinyman`. Those are host names only. Another deployment may use other names or IP addresses.

The supported final launcher accepts host switches:

```text
--server-host HOST
--client-host HOST
--bastion USER@HOST|none
--ssh-key PATH
```

SERVER must be able to SSH as root to CLIENT. CLIENT does not need to SSH back to SERVER.

## Final paper P5 workload

The final paper evaluation uses:

```text
6 independent runs
5 sequential 8-GiB downloads per run
one QUIC connection per run
5-second gaps
5-second edge cooldown
5 seconds between tests/runs
balanced OFF/BASIC/PLUS order
seed 20260806
```

P5 compares:

```text
OFF    MsQuic-DPDK, GreenQUIC policy bypassed
BASIC  GreenQUIC physical datapath policy
PLUS   GreenQUIC+ physical policy + QUIC semantic hints/guards
```

All three modes use the same optimized Performance2 V2 datapath.

Final binary marker:

```text
GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0
```

Final TOP3 power-policy settings:

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

## Exact paths on SERVER and CLIENT

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

## Authoritative final paper run

**RUN ON: CONTROL HOST.** Do not manually start the SERVER and CLIENT binaries for the final paper comparison.

Paper-testbed example:

```bash
cd ~/Downloads/GreenQUIC-Plus && \
python3 results_analysis/verify_paper_configuration.py && \
bash greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_p7_fair_repro_6x5.sh \
  --server-host idex \
  --client-host tinyman \
  --bastion mohsen@coinbase \
  --ssh-key "$HOME/.ssh/id_ed25519"
```

Immediately monitor from a second CONTROL-HOST terminal using the command in `results_analysis/README.md`.

The launcher fixes the exact `main` SHA, transfers it by Git bundle, rebuilds/verifies P5 and P7, injects TOP3, starts P5 on SERVER/CLIENT, transitions the NIC state for P7, validates recorders, and packages both result sets.

The old `_v2.sh` and `_v3.sh` launcher names are compatibility wrappers around this single authoritative implementation.

## Standalone P5 matrix for debugging

**RUN ON: SERVER.** Pass the CLIENT explicitly. Example using our paper host name:

```bash
CLIENT_HOST=tinyman
P5=/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads

cd "$P5" && \
./run_matrix_with_sheet.sh \
  --client-host "$CLIENT_HOST" \
  --client-dir "$P5" \
  --client-bin /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop \
  --downloads 5 \
  --gap-seconds 5 \
  --server-cooldown-seconds 5 \
  --between-tests-seconds 5 \
  --runs 6 \
  --mode-order balanced \
  --seed 20260806
```

Before a standalone SERVER-side run:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=10 root@"$CLIENT_HOST" 'echo SERVER_TO_CLIENT_SSH_OK; hostname'
```

This standalone example is for debugging. It does not by itself inject every final paper TOP3/recording setting; use the CONTROL-HOST paper launcher for exact reproduction.

## Historical filenames and documents

Some implementation files retain names such as `run_matrix_from_idex.sh` / `run_matrix_from_idex_core.sh`. These are historical filenames from the paper testbed. The actual client endpoint is selected with `--client-host`; the filenames do not force the physical server to be named `idex`.

Older Performance1/Performance2 screening, bottleneck, and research Markdown files in this directory are historical tuning notes. For current operation use:

```text
results_analysis/README.md
tum_testbed_setup/README.md
this README
```

## Output

P5 matrix outputs are created under:

```text
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/matrix_results/
```

The authoritative combined paper launcher additionally creates a SERVER-side `/root/GQ_FAIR_REPRO_<TAG>/` metadata directory, controller log, and final ZIP. See `results_analysis/README.md` for exact output/download paths.
