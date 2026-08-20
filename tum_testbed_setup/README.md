# GreenQUIC+ TUM testbed setup

This folder contains the Mac-side setup and recovery tooling for the TUM/LRZ IDEX + Tinyman GreenQUIC+ testbed.

## Authoritative repository and branch

GreenQUIC+ is an independent private repository:

```text
Meamarian/GreenQUIC-Plus
```

The authoritative branch is:

```text
main
```

`main` starts from the final paper/reproduction code line that previously lived on `performance2/p5-multicore` in the old GreenQUIC repository. In this repository, do **not** use that old branch name for normal setup or reproduction.

The final P5 paper configuration is the single-DPDK-owner Performance2 V2 path, verified with the binary marker:

```text
GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0
```

The fair launcher uses DPDK CPU 19, QUIC CPUs 21-24, `ENABLE_MULTICORE=0`, and the isolated P7 Linux baseline.

---

## Fresh Debian recovery: exact procedure

The GreenQUIC+ scripts do **not** select or reset the POS operating-system image. If IDEX and Tinyman have been reimaged or their live-boot state has been lost, first use Coinbase/POS to install/reset Debian Trixie and wait until both machines are reachable by SSH.

After both nodes are reachable, everything below is launched from the Mac.

### 1. Update the private GreenQUIC+ clone on the Mac

```bash
cd ~/Downloads/GreenQUIC-Plus && \
git fetch origin main && \
git checkout main && \
git reset --hard origin/main
```

Verify that this is the new repository, not the preserved old GreenQUIC checkout:

```bash
git remote -v
git branch --show-current
```

Expected remote:

```text
git@github.com:Meamarian/GreenQUIC-Plus.git
```

Expected branch:

```text
main
```

### 2. Run the complete fresh-node setup from the Mac

```bash
cd ~/Downloads/GreenQUIC-Plus && \
bash tum_testbed_setup/greenquic_fresh_setup_branch.sh main
```

`paper` is an alias for the same thing:

```bash
bash tum_testbed_setup/greenquic_fresh_setup_branch.sh paper
```

Do not run `greenquic_fresh_setup_base.sh` directly. The supported entrypoint above deliberately goes through `greenquic_fresh_setup.sh`, which applies the current GreenQUIC+ repository and fresh-boot safety fixes before the preserved setup logic executes.

### What the setup does

The supported setup path performs and verifies the following:

1. Uses the private `Meamarian/GreenQUIC-Plus` repository and branch `main`.
2. Restores Mac -> IDEX and Mac -> Tinyman SSH through `mohsen@coinbase`.
3. Creates a separate IDEX key for IDEX -> Tinyman SSH; the Mac private key is never copied to either node.
4. Uses SSH agent forwarding only while a fresh node needs to clone the private repository.
5. Installs/checks the Debian dependencies required by the test and report tooling, including `lm-sensors` for `acpi.sh`.
6. Prepares ICE/E810 firmware, MSR/P-state support, hugepages, test assets and the GreenQUIC build environment.
7. Brings both direct-cable E810 peers onto the ICE driver and administratively UP before checking carrier. This avoids the old one-sided fresh-boot carrier race.
8. Verifies the physical test link before userspace detach.
9. Binds the E810 test NIC only to an approved DPDK driver: `igb_uio` or `vfio-pci`.
10. Runs the P0 real 1 MiB QUIC/DPDK smoke test and prepares the P4/P5/P7 test environment.
11. Bundles the exact `origin/main` SHA on the Mac and installs that exact commit on both IDEX and Tinyman, so final branch synchronization does not depend on GitHub credentials on the remote nodes.
12. Rebuilds/verifies the final P5 Performance2 V2 binary on both endpoints and checks the exact paper marker shown above.
13. Builds/verifies the isolated normal-Linux P7 binary and confirms it does not link DPDK.
14. Confirms both nodes are on branch `main` at the exact same SHA.
15. Installs `/root/run_p5.sh` and `/root/run_p7.sh` on IDEX.

The setup prints:

```text
GREENQUIC+ MAIN READY ON BOTH TUM NODES
```

only after the final checks pass.

---

## Live setup monitor from a second Mac terminal

While the setup runs in the first Mac terminal, use a second Mac terminal to watch both nodes:

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

Use `Ctrl+C` only in this monitoring terminal if you want to stop the display. Leave the setup terminal running until it completes or reports a specific error.

---

## Final fair P5/P7 reproduction

After setup prints `GREENQUIC+ MAIN READY ON BOTH TUM NODES`, launch the final fair reproduction from the Mac:

```bash
cd ~/Downloads/GreenQUIC-Plus && \
git fetch origin main && \
git checkout main && \
git reset --hard origin/main && \
bash greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_p7_fair_repro_6x5_v3.sh
```

The launcher defaults to 6 runs x 5 downloads. It fetches `origin/main`, records the exact SHA, creates an exact-SHA Git bundle on the Mac, transfers it to IDEX, and then synchronizes Tinyman from that bundle. The detached remote experiment therefore does not need GitHub credentials.

Immediately monitor it from another Mac terminal:

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

The launcher also prints the exact `TAG`, `SHA`, `REMOTE_LOG` and status paths for that run. Prefer the exact path printed for the current run rather than reusing a path from an older experiment.

---

## Coinbase/POS: fresh Debian Trixie

Use Coinbase/POS only when you need to allocate or reimage the live-boot nodes. A typical sequence is:

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

Do not interrupt a reset command midway. If you want a live status display, use a second Coinbase shell:

```bash
watch -n 2 "pos nodes list | grep -E 'idex|tinyman'"
```

Once both nodes are reachable again from the Mac, return to the GreenQUIC+ setup command above.

---

## Important implementation notes

### Private repository access

`GreenQUIC-Plus` is private. The fresh setup validates GitHub SSH authentication from the Mac. During the initial clone on fresh nodes, the setup uses SSH agent forwarding; it does not copy the Mac private SSH key to the servers.

### Preserved base setup

`greenquic_fresh_setup_base.sh` is a preserved implementation file from the original testbed work. The supported public entrypoint dynamically patches its operational repository URL to `Meamarian/GreenQUIC-Plus`, hardens the MSR check and fixes the direct-link bring-up order before executing it. Treat `_base.sh` as internal implementation, not as a user entrypoint.

### P7 Linux baseline

The final fair launcher builds P7 in an isolated source/build tree and runs the controlled Linux baseline with the paper settings, including CPU19 for dataplane/IRQ work, QUIC CPUs21-24, pinned IRQ/QUIC placement, disabled RPS/RDMA helper path, paper NIC offload settings, 6 ms RAPL sampling, 1 ms frequency sampling and MTU 1500.

### Generated experiment data

Do not commit new `matrix_results`, runtime logs, archives or generated payloads to the repository. `.gitignore` blocks these for new work. Older large artifacts remain in inherited Git history for provenance; rewriting that history is intentionally avoided.
