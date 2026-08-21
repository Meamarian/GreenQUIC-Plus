# GreenQUIC+ TUM/LRZ setup guide

This directory has one supported setup entrypoint for the current GreenQUIC+ paper testbed:

```text
tum_testbed_setup/greenquic_fresh_setup.sh
```

It is run **from the Mac**, not from IDEX or Tinyman.

```text
Private repository: Meamarian/GreenQUIC-Plus
Branch: main
OS: Debian Trixie
Server/controller: idex
Client: tinyman
Test NIC on both nodes: 0000:18:00.0 (Intel E810)
Remote repository root: /root/mohsen
```

The setup installs the exact Mac-side `origin/main` commit on both nodes with a Git bundle, so IDEX and Tinyman do not need GitHub credentials.

## What the setup builds

### P5

P5 is the DPDK-based repeated-8-GiB experiment used for OFF / GreenQUIC / GreenQUIC+.

```text
P5 directory:
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads

P5 build script:
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/build_p5_performance2.sh

P5 client:
/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop

P5 server:
/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinteropserver
```

Required final binary marker:

```text
GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0
```

### P7

P7 is the isolated normal-Linux MsQuic UDP comparison. DPDK and XDP are disabled in this build.

```text
P7 directory:
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline

P7 build script:
/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline/build_p7_linux.sh

P7 isolated source:
/root/mohsen/msquic-p7-linux-source

P7 client:
/root/mohsen/msquic/build-linux-p7/bin/Release/quicinterop

P7 server:
/root/mohsen/msquic/build-linux-p7/bin/Release/quicinteropserver
```

The setup verifies that the P7 executables do not link DPDK.

## What the complete setup prepares

The script verifies Debian Trixie, restores Mac→IDEX/Tinyman and IDEX→Tinyman SSH, installs the exact `main` SHA, installs build/measurement dependencies, prepares Intel ICE/E810 DDP firmware, verifies MSR and Intel P-state access on CPU19, allocates `16384 × 2 MiB` hugepages and mounts `/mnt/huge`, builds the bundled DPDK into `/root/mohsen/msquic/deps/dpdk-install`, prepares the 8-GiB payload, builds P5 and P7 on both endpoints, checks the direct E810 link while both ports are ICE-managed and UP, then binds the test NIC to an accepted DPDK driver and performs final binary/state checks.

The setup creates `/root/run_p5.sh` and `/root/run_p7.sh` on IDEX as generic debugging conveniences. The authoritative final paper reproduction is the Mac-side V3 launcher documented in `results_analysis/README.md`.

---

## Case 1 — allocate/reimage fresh nodes with POS

Use this when you want new Debian installations.

On Coinbase, first inspect the nodes:

```bash
pos nodes list | grep -E 'idex|tinyman'
```

If a node's allocation is `None`, allocate each node separately:

```bash
pos allocations allocate idex
pos allocations allocate tinyman
```

If the nodes are already allocated to your experiment, skip allocation. Do not reallocate or free someone else's nodes.

Select the image and reset both:

```bash
pos nodes image idex debian-trixie
pos nodes image tinyman debian-trixie

pos nodes reset idex &
pos nodes reset tinyman &
wait

pos nodes list | grep -E 'idex|tinyman'
```

A POS reset erases the node RAM disks. Treat `/root/mohsen`, previous builds, payloads, and local result directories as gone.

Wait for SSH from Coinbase:

```bash
for h in idex tinyman; do
  until ssh -o ConnectTimeout=5 root@"$h" 'hostname; . /etc/os-release; echo "$ID $VERSION_CODENAME"'; do
    echo "waiting for $h ..."
    sleep 5
  done
done
```

Then return to the Mac and run the complete setup below.

---

## Case 2 — Debian Trixie is already installed, but you need a fresh/current GreenQUIC+ tree and builds

Skip POS entirely. Do not manually clone the private repository onto the nodes.

The setup installs the exact `origin/main` commit into `/root/mohsen` with a bundle and prepares/builds everything needed for the P5/P7 paper path.

From the Mac:

```bash
cd ~/Downloads/GreenQUIC-Plus && \
git fetch origin main && \
git checkout main && \
git reset --hard origin/main && \
python3 results_analysis/verify_paper_configuration.py && \
bash tum_testbed_setup/greenquic_fresh_setup.sh
```

Immediately monitor from another Mac terminal:

```bash
while true; do
  clear
  date
  echo
  ssh -J mohsen@coinbase root@idex \
    'echo "===== IDEX ====="; git -C /root/mohsen rev-parse --short HEAD 2>/dev/null || echo "repo not installed yet"; pgrep -af "meson|ninja|cmake|build_p5|build_p7" || true'
  echo
  ssh -J mohsen@coinbase root@tinyman \
    'echo "===== TINYMAN ====="; git -C /root/mohsen rev-parse --short HEAD 2>/dev/null || echo "repo not installed yet"; pgrep -af "meson|ninja|cmake|build_p5|build_p7" || true'
  sleep 10
done
```

Successful completion ends with:

```text
GREENQUIC+ MAIN READY ON BOTH TUM NODES
```

This command is also the correct operation immediately after Case 1.

---

## Case 3 — repository/DPDK environment exists and only P5/P7 applications need rebuilding

You do not need to rerun POS. If the DPDK installation, hugepages, dependencies, and node state are known-good, the applications can be rebuilt directly.

The exact build-only commands and live monitor are in:

```text
results_analysis/README.md
```

P5 builds into `/root/mohsen/msquic/build-greenquic-p5`; P7 builds into `/root/mohsen/msquic/build-linux-p7` from the disposable isolated source `/root/mohsen/msquic-p7-linux-source`.

If DPDK/hugepage/NIC preparation is uncertain, use the complete setup instead of this shortcut.

---

## Case 4 — everything is ready and you only want to run the final paper evaluation

Do not invoke the binaries manually. Run the supported V3 launcher from the Mac. It synchronizes the exact `main` SHA, rebuilds/verifies both P5 and P7 immediately before measured traffic, injects the final P5 TOP3 policy, applies the P7 Linux paper profile, validates recorders/results, and creates result ZIPs.

```bash
cd ~/Downloads/GreenQUIC-Plus && \
git fetch origin main && \
git checkout main && \
git reset --hard origin/main && \
python3 results_analysis/verify_paper_configuration.py && \
bash greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_p7_fair_repro_6x5_v3.sh
```

Immediately monitor from another Mac terminal:

```bash
ssh idex '
log=$(find /root -maxdepth 1 -type f -name "GQ_FAIR_REPRO_*.log" -printf "%T@ %p\n" 2>/dev/null | sort -nr | sed -n "1p" | cut -d" " -f2-)
echo "FOLLOWING: $log"
echo
if [ -z "$log" ]; then
    echo "No GQ_FAIR_REPRO log found yet"
else
    tail -n +1 -F "$log"
fi
'
```

The exact TOP3/P7 evaluation values, result paths, status command, and download command are documented in `results_analysis/README.md`.

## Important safety/reproducibility properties

- The setup script itself does not select/reset the POS image; POS is a separate prerequisite only when a new OS is required.
- The setup never reboots the nodes.
- The Mac private key is not copied to either experiment node; only public keys are installed.
- Remote nodes do not need GitHub credentials; the exact `origin/main` SHA is transferred by Git bundle.
- The test NIC carrier is checked while both direct-cable endpoints are kernel/ICE-managed and UP, before DPDK binding.
- The final accepted DPDK driver is `igb_uio` or `vfio-pci`; `uio_pci_generic` is not accepted by the final verifier.
- The final paper launcher intentionally rebuilds/verifies P5 and P7 even if binaries already exist. There is no supported no-build paper mode.
