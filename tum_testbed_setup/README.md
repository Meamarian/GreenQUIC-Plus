# TUM testbed setup

This folder contains Mac-side setup/recovery tooling for the TUM/LRZ IDEX + Tinyman GreenQUIC testbed.

## Main script

`greenquic_fresh_setup.sh`

Run it on the Mac, not on IDEX or Tinyman. It restores SSH access through `mohsen@coinbase`, checks GitHub access, checks out the current `main` branch on both live-boot nodes, runs the GreenQUIC bootstrap, prepares hugepages/firmware/test dependencies, verifies the physical E810 link while both ports are still kernel-managed, binds the test NICs to an approved DPDK driver, and runs the P0 1 MiB QUIC/DPDK smoke test before declaring P4 ready.

The script never copies the Mac private SSH key to either test node. IDEX receives its own generated key for IDEX -> Tinyman SSH.

Because IDEX and Tinyman are live-boot/non-persistent machines, rerun this script after a fresh boot when the node state has been lost.
