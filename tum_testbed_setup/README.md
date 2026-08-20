# TUM testbed setup

This folder contains Mac-side setup/recovery tooling for the TUM/LRZ IDEX + Tinyman GreenQUIC testbed.

## Final paper branch and fresh-Debian recovery

The final paper/reproduction branch is:

```text
performance2/p5-multicore
```

The final fair paper launcher on that branch is:

```text
greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_p7_fair_repro_6x5_v3.sh
```

Despite the branch name, that final fair P5 experiment runs the single-DPDK-owner Performance2 V2 datapath (`ENABLE_MULTICORE=0`) with DPDK CPU 19 and QUIC CPUs 21-24. The verified Performance2 V2 binary marker is:

```text
GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0
```

If IDEX and Tinyman have been reimaged/reinstalled with fresh Debian Trixie and all previous live-boot state is gone, the Debian image/reset step is done first through POS/Coinbase. **After both fresh nodes are reachable by SSH, the complete GreenQUIC/DPDK recovery is launched from the Mac with one branch-aware setup command.** The setup script does not itself select/reset the POS Debian image.

On the Mac:

```bash
cd ~/Downloads/GreenQUIC && \
git fetch origin performance2/p5-multicore && \
git checkout performance2/p5-multicore && \
git reset --hard origin/performance2/p5-multicore && \
bash tum_testbed_setup/greenquic_fresh_setup_branch.sh paper
```

The setup runs in the foreground and prints each phase. It first executes the preserved full TUM bootstrap, then transfers the exact `performance2/p5-multicore` SHA from the Mac to both nodes, rebuilds/verifies the final paper P5 Performance2 V2 binary on both endpoints, builds/verifies the isolated normal-Linux P7 binary, verifies IDEX -> Tinyman SSH, verifies the E810 test NIC is DPDK-bound, verifies `lm-sensors`/`sensors`, and installs `/root/run_p5.sh` and `/root/run_p7.sh`. It prints `BRANCH READY` only after those checks pass.

A second Mac terminal can be used to watch the node state while setup is running:

```bash
while true; do
  date
  ssh -J mohsen@coinbase root@idex 'printf "IDEX: "; hostname; git -C /root/mohsen branch --show-current 2>/dev/null || true; git -C /root/mohsen rev-parse --short HEAD 2>/dev/null || true'
  ssh -J mohsen@coinbase root@tinyman 'printf "TINYMAN: "; hostname; git -C /root/mohsen branch --show-current 2>/dev/null || true; git -C /root/mohsen rev-parse --short HEAD 2>/dev/null || true'
  sleep 10
done
```

After the setup prints `BRANCH READY`, launch the final fair P5/P7 reproduction from the Mac:

```bash
cd ~/Downloads/GreenQUIC && \
git fetch origin performance2/p5-multicore && \
git checkout performance2/p5-multicore && \
git reset --hard origin/performance2/p5-multicore && \
bash greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_p7_fair_repro_6x5_v3.sh
```

Immediately monitor the detached experiment from another Mac terminal:

```bash
ssh idex '
log=$(find /root -maxdepth 1 -type f \
    -name "GQ_FAIR_REPRO_*.log" \
    -printf "%T@ %p\n" 2>/dev/null | \
    sort -nr | sed -n "1p" | cut -d" " -f2-)
echo "FOLLOWING: $log"; echo
[ -n "$log" ] || { echo "No GQ_FAIR_REPRO log found yet"; return 0 2>/dev/null || true; }
tail -n +1 -F "$log"
'
```

The fair launcher itself re-fetches the exact paper-branch SHA on the Mac and transfers that exact commit to the two remote nodes using a Git bundle, so the remote nodes do not need GitHub credentials for the final run.

## Recommended branch-aware setup

Use `greenquic_fresh_setup_branch.sh` when you want the fresh TUM setup to end on a specific GreenQUIC branch.

Run it on the Mac from the GreenQUIC repository. The supported aliases are:

```bash
bash tum_testbed_setup/greenquic_fresh_setup_branch.sh paper
bash tum_testbed_setup/greenquic_fresh_setup_branch.sh main
bash tum_testbed_setup/greenquic_fresh_setup_branch.sh performance
bash tum_testbed_setup/greenquic_fresh_setup_branch.sh performance2
```

The aliases resolve to:

- `paper` or `multicore` -> `performance2/p5-multicore` (final paper branch)
- `main` -> `main`
- `performance` -> `performance/p5-max-goodput`
- `performance2` -> `performance2/p5-max-goodput`

The selector first runs the preserved complete TUM setup, then bundles the exact selected branch SHA from the Mac, installs that exact SHA on both IDEX and Tinyman, rebuilds/verifies the selected P5 binary on both hosts, builds/verifies the isolated normal-Linux P7 binary, confirms IDEX -> Tinyman SSH, confirms the E810 test NIC is DPDK-bound, installs `/root/run_p5.sh` and `/root/run_p7.sh`, and only then prints `BRANCH READY`.

For the `paper` target, readiness additionally verifies the exact final Performance2 V2 marker shown above. For the older `performance2` target, readiness requires the SUPER-PERF, Performance2 V1 and Performance2 V2 markers but intentionally uses that older branch's baseline V2 build settings.

## Base fresh setup

`greenquic_fresh_setup.sh` is the original main-branch fresh setup entry point.

Run it on the Mac, not on IDEX or Tinyman. It restores SSH access through `mohsen@coinbase`, checks GitHub access, checks out the current `main` branch on both live-boot nodes, runs the GreenQUIC bootstrap, prepares hugepages/firmware/test dependencies, verifies the physical E810 link while both ports are still kernel-managed, binds the test NICs to an approved DPDK driver, and runs the P0 1 MiB QUIC/DPDK smoke test before declaring P4 ready. The complete setup also builds and verifies the isolated P5/P6 and normal-Linux P7 binaries on both nodes and installs `/root/run_p7.sh` on IDEX.

The script never copies the Mac private SSH key to either test node. IDEX receives its own generated key for IDEX -> Tinyman SSH.

Because IDEX and Tinyman are live-boot/non-persistent machines, rerun the setup after a fresh boot when node state has been lost.

## Dependencies installed by the bootstrap

The bootstrap automatically checks/installs its Debian test/report dependencies. In addition to the Python plotting dependencies, it requires Debian package `lm-sensors` because the repository root `acpi.sh` calls the `sensors` command to sample the `power1` reading.

Manual equivalent if needed:

```bash
sudo apt-get update
sudo apt-get install -y lm-sensors
```

Verify it with:

```bash
command -v sensors
sensors
```

The branch-aware host verifier also checks that `acpi.sh` is executable and that `sensors` exists before it declares a node ready.

## Coinbase: allocate/reset IDEX and Tinyman with correct SSH

Run the following **on Coinbase** before running the Mac-side GreenQUIC setup when you need fresh IDEX and Tinyman nodes.

> **Important:** IDEX and Tinyman are live-booted. Resetting/rebooting them loses non-persistent data.
>
> Keep the terminal that runs the reset commands open. Do **not** press `Ctrl+C` in that terminal while the resets are running. If you want to monitor progress, open a **second shell**, SSH to Coinbase there, and run the `watch` command shown below. `Ctrl+C` is safe in the second monitoring shell.

```bash
echo "=================================================="
echo " POS SETUP: idex + tinyman"
echo " WARNING: nodes are live-booted; reboot loses data"
echo "=================================================="

echo
echo "[1/6] Freeing old allocations..."
pos allocations free -k tinyman
pos allocations free -k idex

echo
echo "[2/6] Allocating idex + tinyman..."
pos allocations allocate tinyman idex

echo
echo "[3/6] Current allocation:"
pos nodes list | grep -E 'idex|tinyman'

echo
echo "[4/6] Setting Debian Trixie image..."
pos nodes image tinyman debian-trixie
pos nodes image idex debian-trixie

echo
echo "=================================================="
echo "RESETS STARTING"
echo
echo "DO NOT PRESS CTRL+C IN THIS TERMINAL."
echo
echo "If you want to monitor progress, open a SECOND"
echo "terminal, ssh to coinbase, and run:"
echo
echo "  watch -n 2 \"pos nodes list | grep -E 'idex|tinyman'\""
echo
echo "Ctrl+C is safe ONLY in that second watch terminal."
echo "=================================================="

echo
echo "[5/6] Resetting idex..."
pos nodes reset idex

echo
echo "idex reset command finished."
echo "Resetting tinyman..."
pos nodes reset tinyman

echo
echo "tinyman reset command finished."
echo
echo "Current node status:"
pos nodes list | grep -E 'idex|tinyman'

echo
echo "[6/6] Waiting for SSH..."
until ssh -o ConnectTimeout=3 -o BatchMode=yes idex 'echo "IDEX READY"' 2>/dev/null; do
    echo "Waiting for idex SSH..."
    sleep 5
done
until ssh -o ConnectTimeout=3 -o BatchMode=yes tinyman 'echo "TINYMAN READY"' 2>/dev/null; do
    echo "Waiting for tinyman SSH..."
    sleep 5
done

echo
echo "=================================================="
echo " BOTH SERVERS ARE READY"
echo "=================================================="
pos nodes list | grep -E 'idex|tinyman'
echo
echo "Connect with:"
echo "  ssh idex"
echo "  ssh tinyman"
echo "=================================================="
```

### Monitoring from a second Coinbase shell

While the reset commands are running in the first Coinbase shell, open another local terminal and connect to Coinbase. Then run:

```bash
watch -n 2 "pos nodes list | grep -E 'idex|tinyman'"
```

Use `Ctrl+C` only to stop this `watch` command in the second shell. Leave the first reset/setup shell running until it finishes.

## P7 Linux UDP baseline

The complete setup builds an isolated non-DPDK MsQuic binary on both IDEX and Tinyman and installs `/root/run_p7.sh` on IDEX. P7 uses the normal Linux `datapath_linux.c` + `datapath_epoll.c` path while reusing the P5 sequential-download application timing logic.

The controlled paper mapping is CPU19 for E810 IRQ/NAPI work and CPUs21-24 for the MsQuic worker processor list/process affinity, corresponding as closely as Linux permits to the final P5 single-core DPDK mapping CPU19 + QUIC workers21-24. P7 temporarily switches the test NIC from the DPDK driver to `ice` and restores DPDK after the matrix.

The final fair reproduction does not use the older generic `/root/run_p7.sh` example as its authoritative configuration; it invokes `run_matrix_with_report.sh` with the paper Linux settings from `mac_run_p5_p7_fair_repro_6x5_v3.sh`, including `--nic-offloads paper`, `--disable-rdma 1`, UDP buffers `6815744`, combined channels `1`, MTU `1500`, RAPL sampling at `6 ms`, frequency sampling at `1 ms`, and the same 5-second gap/edge/between timing used for the P5 fair run.

## Performance2 V2 monitoring

For the older Performance2 V2 goodput screen, see:

```text
greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/P5_PERFORMANCE2.md
```

That document contains the V4 detached Mac command, live-check command, results-so-far command, and `SCP_DONE` completion check. For the final paper reproduction, use the `paper` instructions at the top of this README instead.
