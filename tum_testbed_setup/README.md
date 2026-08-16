# TUM testbed setup

This folder contains Mac-side setup/recovery tooling for the TUM/LRZ IDEX + Tinyman GreenQUIC testbed.

## Recommended branch-aware setup

Use `greenquic_fresh_setup_branch.sh` when you want the fresh TUM setup to end on a specific GreenQUIC branch.

Run it on the Mac from the GreenQUIC repository:

```bash
bash tum_testbed_setup/greenquic_fresh_setup_branch.sh main
```

or:

```bash
bash tum_testbed_setup/greenquic_fresh_setup_branch.sh performance
```

or:

```bash
bash tum_testbed_setup/greenquic_fresh_setup_branch.sh performance2
```

The aliases resolve to:

- `main` -> `main`
- `performance` -> `performance/p5-max-goodput`
- `performance2` -> `performance2/p5-max-goodput`

The selector first runs the preserved complete TUM setup, then bundles the exact selected branch SHA from the Mac, installs that exact SHA on both IDEX and Tinyman, rebuilds/verifies the selected P5 binary on both hosts, builds/verifies the isolated normal-Linux P7 binary, confirms IDEX -> Tinyman SSH, confirms the E810 test NIC is DPDK-bound, installs `/root/run_p5.sh` and `/root/run_p7.sh`, and only then prints `BRANCH READY`.

For `performance2`, readiness requires all three binary markers:

```text
GREENQUIC-P5-SUPER-PERF-V2
GREENQUIC-P5-PERFORMANCE2-V1
GREENQUIC-P5-PERFORMANCE2-V2
```

After readiness, the selector prints a copy/paste Mac command for the final selected-branch 4-test suite. When `performance2` is selected it also prints the V4 Performance2 V2 goodput-screen command.

## Base fresh setup

`greenquic_fresh_setup.sh` is the original main-branch fresh setup entry point.

Run it on the Mac, not on IDEX or Tinyman. It restores SSH access through `mohsen@coinbase`, checks GitHub access, checks out the current `main` branch on both live-boot nodes, runs the GreenQUIC bootstrap, prepares hugepages/firmware/test dependencies, verifies the physical E810 link while both ports are still kernel-managed, binds the test NICs to an approved DPDK driver, and runs the P0 1 MiB QUIC/DPDK smoke test before declaring P4 ready. The complete setup also builds and verifies the isolated P5/P6 and normal-Linux P7 binaries on both nodes and installs `/root/run_p7.sh` on IDEX.

The script never copies the Mac private SSH key to either test node. IDEX receives its own generated key for IDEX -> Tinyman SSH.

Because IDEX and Tinyman are live-boot/non-persistent machines, rerun the setup after a fresh boot when node state has been lost.

## Dependencies installed by the bootstrap

The bootstrap automatically checks/installs its Debian test/report dependencies. In addition to the Python plotting dependencies, it now requires Debian package `lm-sensors` because the repository root `acpi.sh` calls the `sensors` command to sample the `power1` reading.

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

The complete setup builds an isolated non-DPDK MsQuic binary on both IDEX and Tinyman and installs `/root/run_p7.sh` on IDEX. P7 uses the normal Linux `datapath_linux.c` + `datapath_epoll.c` path while reusing the exact P5 sequential-download application timing logic.

The primary controlled Linux mapping is CPU19 for E810 IRQ/NAPI work and CPUs21–24 for the MsQuic worker processor list/process affinity, corresponding as closely as Linux permits to the P5 single-core DPDK mapping CPU19 + QUIC workers21–24. P7 temporarily switches the test NIC from `vfio-pci` to `ice` and restores DPDK after the matrix by default.

Primary 6-repetition run on IDEX:

```bash
/root/run_p7.sh \
  --downloads 5 \
  --gap-seconds 5 \
  --runs 6 \
  --pre-cooldown-seconds 5 \
  --post-cooldown-seconds 5 \
  --between-runs-seconds 5 \
  --dataplane-cpu 19 \
  --quic-cpus 21,22,23,24 \
  --pin-irq 1 \
  --pin-quic 1 \
  --disable-rps 1 \
  --nic-offloads native \
  --record-quic-cpus 0 \
  --enable-record 1 \
  --rapl-interval-ms 6 \
  --freq-interval-ms 1 \
  --require-rapl 1 \
  --stop-irqbalance 1 \
  --mtu 1500 \
  --restore-dpdk 1
```

Use `--nic-offloads on` or `--nic-offloads off` only as sensitivity experiments; `--nic-offloads native` is the normal Linux baseline, while MsQuic keeps its stock UDP segmentation/coalescing capability probe and P7 records the detected features.

## Performance2 V2 monitoring

After checking out `performance2/p5-max-goodput`, see:

```text
greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/P5_PERFORMANCE2.md
```

That document contains the recommended V4 detached Mac command, the live-check command, the results-so-far command, and the `SCP_DONE` completion check.
