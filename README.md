# GreenQUIC+

**GreenQUIC+ is a research prototype for energy-aware CPU power management in DPDK-accelerated MsQuic.**

This repository is the independent continuation of the GreenQUIC paper code. Its `main` branch starts from the final paper/reproduction line that previously lived on `performance2/p5-multicore` in the original `Meamarian/GreenQUIC` repository.

The original repository is preserved separately. New GreenQUIC+ development should happen here.

## Repository status

```text
Repository: Meamarian/GreenQUIC-Plus
Visibility: private
Default branch: main
```

Historical import point from the old GreenQUIC paper branch:

```text
58d00a39270f512b6e9586704797dff6285e73b2
```

That SHA is provenance only. The authoritative current code is always the current `main` of this repository.

---

## What GreenQUIC+ contains

The implementation exposes three runtime behaviors of the same DPDK/MsQuic datapath:

| Mode | Role |
|---|---|
| `OFF` | DPDK baseline without GreenQUIC power-management decisions |
| `BASIC` / GreenQUIC | datapath-aware CPU frequency and idle control using physical DPDK signals |
| `PLUS` / GreenQUIC+ | BASIC plus short-lived QUIC transport hints and locality information |

The physical GreenQUIC policy observes signals such as RX/TX burst occupancy, RX NIC queue backlog, TX software-ring backlog, recent activity and persistent empty polling. GreenQUIC+ keeps that physical policy and adds semantic transport information such as ACK readiness and CUBIC state so that a temporarily quiet datapath is not automatically treated as unimportant work.

The main implementation locations are:

| Area | Location |
|---|---|
| GreenQUIC datapath tracking, pressure calculation, DVFS and idle policy | `msquic/src/platform/datapath_raw_dpdk.c` |
| GreenQUIC+ hint API | `msquic/src/inc/greenquic_plus.h` |
| GreenQUIC+ hint storage/runtime mapping | `msquic/src/platform/greenquic_plus.c` |
| ACK-ready hook | `msquic/src/core/ack_tracker.c` |
| CUBIC recovery/ramping/blocked hooks | `msquic/src/core/cubic.c` |
| Experiment suite | `greenquic_test_suite_v22/` |
| TUM/LRZ fresh-node recovery | `tum_testbed_setup/` |

---

## Final paper datapath now used by `main`

Although the historical branch name contained `multicore`, the final fair paper configuration uses one DPDK owner core and the optimized Performance2 V2 datapath.

The build is verified with this exact marker:

```text
GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0
```

The fair P5 launcher uses:

```text
ENABLE_MULTICORE=0
DPDK CPU: 19
QUIC CPUs: 21,22,23,24
```

The corresponding Linux comparison is the isolated P7 normal-Linux MsQuic path.

---

## Mac checkout

The preserved old repository and the new repository should remain separate local directories:

```text
~/Downloads/GreenQUIC       # old repository, preserved
~/Downloads/GreenQUIC-Plus  # new development repository
```

For GreenQUIC+ work:

```bash
cd ~/Downloads/GreenQUIC-Plus && \
git fetch origin main && \
git checkout main && \
git reset --hard origin/main
```

Verify before making changes:

```bash
git remote -v
git branch --show-current
git rev-parse HEAD
```

Expected remote:

```text
git@github.com:Meamarian/GreenQUIC-Plus.git
```

Expected branch:

```text
main
```

---

## Fresh TUM Debian setup

The authoritative setup guide is:

```text
tum_testbed_setup/README.md
```

If IDEX and Tinyman have been reimaged with fresh Debian Trixie, first complete the POS/Coinbase image/reset step and wait until both nodes are reachable by SSH. Then run this from the Mac:

```bash
cd ~/Downloads/GreenQUIC-Plus && \
git fetch origin main && \
git checkout main && \
git reset --hard origin/main && \
bash tum_testbed_setup/greenquic_fresh_setup_branch.sh main
```

`paper` is an alias for the same GreenQUIC+ `main` setup:

```bash
bash tum_testbed_setup/greenquic_fresh_setup_branch.sh paper
```

The supported setup path intentionally goes through the hardened public setup entrypoint. It prepares the private repository checkout, SSH path, ICE/E810 firmware, hugepages, MSR/P-state support, direct-link verification, DPDK binding, P0/P4/P5/P7 environment, and finally installs the exact current `main` SHA on both endpoints using a Git bundle.

Do **not** run `tum_testbed_setup/greenquic_fresh_setup_base.sh` directly. It is preserved internal setup code; the public wrapper applies the current GreenQUIC+ repository URL and fresh-boot safety fixes before executing it.

### Setup monitor from another Mac terminal

```bash
while true; do
  clear
  date
  echo
  ssh -J mohsen@coinbase root@idex \
    'echo "===== IDEX ====="; hostname; git -C /root/mohsen branch --show-current 2>/dev/null || true; git -C /root/mohsen rev-parse --short HEAD 2>/dev/null || true'
  echo
  ssh -J mohsen@coinbase root@tinyman \
    'echo "===== TINYMAN ====="; hostname; git -C /root/mohsen branch --show-current 2>/dev/null || true; git -C /root/mohsen rev-parse --short HEAD 2>/dev/null || true'
  sleep 10
done
```

Successful setup ends with:

```text
GREENQUIC+ MAIN READY ON BOTH TUM NODES
```

---

## Final fair P5/P7 reproduction

After the TUM setup is ready, run the paper/fair reproduction from the Mac:

```bash
cd ~/Downloads/GreenQUIC-Plus && \
git fetch origin main && \
git checkout main && \
git reset --hard origin/main && \
bash greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_p7_fair_repro_6x5_v3.sh
```

The default experiment is 6 runs x 5 downloads. The launcher:

1. resolves the exact current `origin/main` SHA on the Mac,
2. creates a Git bundle for that exact commit,
3. sends the bundle to IDEX,
4. synchronizes Tinyman from the same bundle,
5. rebuilds and checks the final P5 Performance2 V2 marker,
6. runs the fair P5 experiment and isolated P7 Linux baseline,
7. records the exact run tag, commit and output paths.

The remote nodes do not need their own GitHub credentials for the detached final run.

Immediately monitor from another Mac terminal:

```bash
ssh idex '
log=$(find /root -maxdepth 1 -type f \
    -name "GQ_FAIR_REPRO_*.log" \
    -printf "%T@ %p\n" 2>/dev/null | \
    sort -nr | sed -n "1p" | cut -d" " -f2-)

echo "FOLLOWING: $log"
echo

if [ -z "$log" ]; then
    echo "No GQ_FAIR_REPRO log found yet"
else
    tail -n +1 -F "$log"
fi
'
```

Always prefer the exact `REMOTE_LOG` path printed by the launcher for the current run.

---

## Runtime modes

The runtime GreenQUIC mode is selected through configuration:

```ini
GreenQuicMode=off
```

```ini
GreenQuicMode=basic
```

```ini
GreenQuicMode=plus
```

`BASIC` and `PLUS` share the physical datapath policy. `PLUS` additionally consumes QUIC semantic information and PLUS-only protection logic.

---

## Measurement infrastructure

The experiment framework can collect and organize:

- transfer timing and goodput,
- RAPL package/DRAM energy,
- CPU-frequency traces,
- CPU-idle residency,
- GreenQUIC policy telemetry,
- client/server run metadata,
- validation artifacts and generated charts.

Generated experiment results, runtime logs, archives and payloads should not be committed for new work. `.gitignore` excludes new `matrix_results`, logs, runtime output, build trees and generated payloads. Older large artifacts remain in inherited Git history for provenance; this repository intentionally does not rewrite that history.

---

## Collaboration

The repository is private and can be shared with collaborators through GitHub repository access. For normal development, keep `main` as the stable paper/development baseline and create short-lived branches such as:

```text
feature/<name>
experiment/<name>
fix/<name>
```

Merge reviewed changes back into `main` rather than changing the preserved old `Meamarian/GreenQUIC` repository.

---

## Scope

GreenQUIC+ is a research prototype, not a production power-management framework. It is intended to study the performance/power tradeoff of QUIC over DPDK and how transport-aware information can improve CPU frequency and idle decisions without unnecessarily reducing responsiveness.
