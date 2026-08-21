# GreenQUIC+ TUM/LRZ fresh-node setup

This directory contains the **single supported setup entrypoint** for the GreenQUIC+ paper testbed on IDEX + Tinyman.

```text
Repository: Meamarian/GreenQUIC-Plus (private)
Branch: main
Operating system: Debian Trixie
Server: idex
Client: tinyman
Test NIC: 0000:18:00.0 (Intel E810)
```

The old chain of `greenquic_fresh_setup_base.sh`, `greenquic_fresh_setup_p4_p5*.sh`, branch wrappers, and versioned setup scripts has been consolidated into:

```text
tum_testbed_setup/greenquic_fresh_setup.sh
```

Do not look for or run a versioned setup wrapper on `main`.

## What this setup prepares

The script is intentionally limited to the current paper/reproduction path. It:

1. runs on the Mac and resolves the exact current `origin/main` SHA;
2. restores Mac → IDEX/Tinyman SSH through `mohsen@coinbase`;
3. restores IDEX → Tinyman SSH without copying the Mac private key;
4. transfers the exact `main` commit to both nodes with a Git bundle, so remote GitHub credentials are not required;
5. verifies Debian Trixie on both nodes;
6. installs the build, measurement, `lm-sensors`, `msr-tools`, NumPy, and Matplotlib dependencies;
7. prepares Intel ICE/E810 DDP firmware;
8. verifies MSR and Intel P-state access on CPU19;
9. allocates `16384 × 2 MiB` hugepages on the test-NIC NUMA node and mounts `/mnt/huge`;
10. builds the bundled DPDK source into `msquic/deps/dpdk-install`;
11. builds and verifies the final P5 Performance2 V2 client/server on both nodes;
12. builds and verifies the isolated normal-Linux P7 client/server on both nodes and verifies that P7 does not link DPDK;
13. brings **both** E810 direct-cable peers onto `ice` and administratively UP before checking carrier, avoiding the old one-sided fresh-boot link race;
14. binds the test NIC on each node only to `igb_uio` or `vfio-pci`;
15. installs `/root/run_p5.sh` and `/root/run_p7.sh` on IDEX;
16. performs a final exact-SHA, binary-marker, hugepage, driver, `acpi.sh`, and `msr.py` verification.

The final P5 build marker is:

```text
GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0
```

The final P5 experiment itself uses:

```text
ENABLE_MULTICORE=0
DPDK owner CPU: 19
QUIC CPUs: 21,22,23,24
```

## What it intentionally does not prepare

The current paper comparison is P5 vs. P7. Therefore the consolidated setup does **not** rebuild the historical P0, P4, or P6 experiment paths and does not create their launchers. Those workflows are preserved in Git history and historical branches if an old experiment must be reproduced later.

## 1. Reimage the TUM nodes

Use Coinbase/POS to put both nodes on fresh Debian Trixie. The GreenQUIC+ script does not select or reset the POS image itself.

A typical Coinbase sequence is:

```bash
pos allocations free -k tinyman || true
pos allocations free -k idex || true
pos allocations allocate tinyman idex

pos nodes image tinyman debian-trixie
pos nodes image idex debian-trixie

pos nodes reset idex
pos nodes reset tinyman

pos nodes list | grep -E 'idex|tinyman'
```

Wait until both nodes are reachable through Coinbase before continuing.

## 2. Update GreenQUIC+ on the Mac

```bash
cd ~/Downloads/GreenQUIC-Plus && \
git fetch origin main && \
git checkout main && \
git reset --hard origin/main
```

Verify:

```bash
git remote -v
git branch --show-current
git rev-parse HEAD
```

Expected repository/branch:

```text
git@github.com:Meamarian/GreenQUIC-Plus.git
main
```

## 3. Run the complete setup

From the Mac:

```bash
cd ~/Downloads/GreenQUIC-Plus && \
bash tum_testbed_setup/greenquic_fresh_setup.sh
```

Successful completion prints:

```text
GREENQUIC+ MAIN READY ON BOTH TUM NODES
```

The script also prints the exact commit and final P5/P7 configuration that it verified.

## Live setup monitor from another Mac terminal

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

Use `Ctrl+C` only in this monitoring terminal if you want to stop the display.

## 4. Run the final paper reproduction

After setup succeeds:

```bash
cd ~/Downloads/GreenQUIC-Plus && \
git fetch origin main && \
git checkout main && \
git reset --hard origin/main && \
bash greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_p7_fair_repro_6x5_v3.sh
```

The default workload is 6 runs × 5 downloads for P5 and the controlled P7 Linux comparison.

Immediately monitor the run from another Mac terminal:

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

Prefer the exact `REMOTE_LOG` path printed by the launcher for the current run.

## Safety and reproducibility notes

- The script never reboots the nodes.
- The Mac private SSH key is not copied to either node.
- The exact `origin/main` commit is transferred by bundle and verified on both nodes.
- The direct E810 cable is checked while both peer ports are kernel/ICE-managed and UP, before DPDK binding.
- `uio_pci_generic` is not accepted; the final driver must be `igb_uio` or `vfio-pci`.
- The setup does not modify the preserved original `Meamarian/GreenQUIC` repository.
- The final experiment rebuilds/verifies P5 and P7 again before measured traffic.
