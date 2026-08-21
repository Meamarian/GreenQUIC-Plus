# GreenQUIC+ TUM testbed setup

`tum_testbed_setup/greenquic_fresh_setup.sh` is the **build implementation**.

# 1. Case A — allocate/reimage fresh Debian nodes

## 1.1 Allocate/image/reset

**RUN ON: COINBASE/POS SHELL.** 

Paper-testbed example:

```bash
SERVER_NODE=idex
CLIENT_NODE=tinyman
pos nodes list | grep -E "$SERVER_NODE|$CLIENT_NODE"
```

Allocate only nodes that are genuinely unallocated and according to local POS policy.
After allocation, **RUN ON: COINBASE/POS SHELL:**

```bash
SERVER_NODE=idex
CLIENT_NODE=tinyman
pos nodes image "$SERVER_NODE" debian-trixie
pos nodes image "$CLIENT_NODE" debian-trixie
pos nodes reset "$SERVER_NODE" &
pos nodes reset "$CLIENT_NODE" &
wait
```

**LIVE MONITOR — RUN ON: another COINBASE/POS SHELL:**

```bash
SERVER_NODE=idex
CLIENT_NODE=tinyman
while true; do
  clear; date
  pos nodes list | grep -E "$SERVER_NODE|$CLIENT_NODE"
  sleep 5
done
```

A POS reset destroys the live node filesystem. Treat `/root/mohsen`, old builds, generated payloads, and local results as gone.

When POS reports both nodes up, verify Debian/SSH readiness. **RUN ON: COINBASE/POS SHELL:**

```bash
SERVER_NODE=idex
CLIENT_NODE=tinyman
for h in "$SERVER_NODE" "$CLIENT_NODE"; do
  until ssh -o ConnectTimeout=5 root@"$h" 'hostname; . /etc/os-release; echo "$ID $VERSION_CODENAME"'; do
    echo "waiting for $h ..."
    sleep 5
  done
done
```

That loop is itself the live readiness monitor.

## 1.2 Deploy/provision/build GreenQUIC+

After both nodes answer SSH as Debian Trixie, **RUN ON: CONTROL HOST:**

```bash
REPO="$HOME/Downloads/GreenQUIC-Plus"
if [ ! -d "$REPO/.git" ]; then
  git clone git@github.com:Meamarian/GreenQUIC-Plus.git "$REPO"
fi
cd "$REPO" && \
git checkout main && \
bash results_analysis/setup_paper_testbed.sh
```

**LIVE MONITOR — RUN ON: second CONTROL-HOST terminal immediately after setup starts:**

```bash
cd "$HOME/Downloads/GreenQUIC-Plus" && \
bash results_analysis/live_monitor_setup.sh
```

Successful completion prints `GREENQUIC+ MAIN READY`, the selected role endpoints, and final P5/P7 binary paths.

# 6. What the single setup implementation does

From CONTROL, `greenquic_fresh_setup.sh`:

1. resolves exact `origin/main` using an explicit refspec;
2. bootstraps/verifies CONTROL SSH to SERVER and CLIENT;
3. creates/verifies SERVER→CLIENT SSH;
4. installs exact Git SHA on both nodes by bundle;
5. verifies Debian Trixie;
6. installs dependencies;
7. prepares Intel E810/ICE firmware;
8. checks MSR/P-state access on CPU19;
9. creates `16384 × 2 MiB` hugepages;
10. builds/installs DPDK 21.11.9;
11. creates the 8-GiB payload;
12. builds/verifies P5 Performance2 V2 on both nodes;
13. builds/verifies isolated P7 Linux binaries on both nodes and checks no DPDK linkage;
14. brings both E810 peers onto `ice` and UP before carrier validation;
15. binds both test NICs to an approved DPDK driver (`igb_uio` or `vfio-pci`);
16. installs `/root/run_p5.sh` and `/root/run_p7.sh` on SERVER;
17. verifies exact SHA, binaries, P5 marker, hugepages, helpers, and final NIC driver.

The setup implementation itself does **not** allocate/reimage POS nodes and does not reboot them.

# 2. Final build outputs

On both SERVER and CLIENT:

```text
P5 client: /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop
P5 server: /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinteropserver

P7 client: /root/mohsen/msquic/build-linux-p7/bin/Release/quicinterop
P7 server: /root/mohsen/msquic/build-linux-p7/bin/Release/quicinteropserver
```

Required P5 marker:

```text
GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0
```

P5 paper topology:

```text
Performance2 V2
ENABLE_MULTICORE=0
DPDK CPU=19
MsQuic CPUs=21,22,23,24
```

P7 is an isolated normal-Linux MsQuic build with DPDK and XDP disabled.

# 3. After setup — run final paper evaluation

**RUN ON: CONTROL HOST:**

```bash
REPO="$HOME/Downloads/GreenQUIC-Plus"
if [ ! -d "$REPO/.git" ]; then
  git clone git@github.com:Meamarian/GreenQUIC-Plus.git "$REPO"
fi
cd "$REPO" && \
git checkout main && \
bash results_analysis/run_paper_evaluation.sh
```

**LIVE MONITOR — RUN ON: second CONTROL-HOST terminal after launch:**

```bash
cd "$HOME/Downloads/GreenQUIC-Plus" && \
bash results_analysis/live_monitor_run.sh
```

The first CONTROL-HOST terminal now remains attached by default until the remote run is complete. On success it prints the final P5/P7 matrix paths, final remote ZIP paths, and final local destination **before SCP**, then performs **automatic SCP** of both result ZIPs plus metadata/logs into:

```text
$HOME/Downloads/GreenQUIC-Plus/reproduced_results/<TAG>/
```

Downloaded ZIP SHA-256 values are checked against hashes generated on SERVER. The final P5 recorder check uses durable per-run log evidence plus `matrix_integrity.json`; missing disposable `*_affinity.txt` sidecars do not falsely fail an otherwise complete run.

For exact P5/P7 configuration, result paths, manual re-download behavior, and final audit, see `results_analysis/README.md`.

# 4. Safety notes

- root SSH is required because setup installs packages, changes hugepages/MSR/PCI drivers, and writes under `/root`;
- `uio_pci_generic` is not accepted as the final P5 DPDK driver;
- the CONTROL private key is never copied to SERVER or CLIENT;
- private GitHub credentials remain on CONTROL;
- SERVER gets a dedicated key for SERVER→CLIENT;
