# TUM testbed setup

This folder contains Mac-side setup/recovery tooling for the TUM/LRZ IDEX + Tinyman GreenQUIC testbed.

## Main script

`greenquic_fresh_setup.sh`

Run it on the Mac, not on IDEX or Tinyman. It restores SSH access through `mohsen@coinbase`, checks GitHub access, checks out the current `main` branch on both live-boot nodes, runs the GreenQUIC bootstrap, prepares hugepages/firmware/test dependencies, verifies the physical E810 link while both ports are still kernel-managed, binds the test NICs to an approved DPDK driver, and runs the P0 1 MiB QUIC/DPDK smoke test before declaring P4 ready.

The script never copies the Mac private SSH key to either test node. IDEX receives its own generated key for IDEX -> Tinyman SSH.

Because IDEX and Tinyman are live-boot/non-persistent machines, rerun this script after a fresh boot when the node state has been lost.

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
