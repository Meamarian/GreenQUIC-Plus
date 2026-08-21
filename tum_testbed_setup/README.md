# GreenQUIC+ TUM testbed setup

`tum_testbed_setup/greenquic_fresh_setup.sh` is the **single provisioning/build implementation**. For normal use, launch it through the high-level CONTROL-HOST wrapper `results_analysis/setup_paper_testbed.sh`.

# 1. Roles and routing

```text
CONTROL HOST  machine with the private GreenQUIC+ checkout
SERVER        QUIC server + experiment controller
CLIENT        QUIC client
BASTION       optional SSH jump/bootstrap host
```

Paper-testbed defaults:

```text
CONTROL checkout:       $HOME/Downloads/GreenQUIC-Plus
SERVER:                 idex
CLIENT from CONTROL:    tinyman
CLIENT from SERVER:     tinyman
BASTION:                mohsen@coinbase
CONTROL SSH key:        $HOME/.ssh/id_ed25519
remote repository root: /root/mohsen
```

These host names are defaults, not role semantics. Another deployment uses the same wrappers with explicit switches.

Fresh setup needs CONTROL→SERVER, CONTROL→CLIENT, and SERVER→CLIENT. When a bastion is used, CONTROL must reach the bastion and the bastion must reach both nodes for fresh public-key bootstrap. CLIENT→SERVER is not required.

# 2. Dependencies

SERVER and CLIENT must run Debian Trixie. The setup installs the compiler/build/network/measurement packages defined by the current setup and recorded in `results_analysis/configuration/dependencies.json`.

Source/tool anchors for the paper path include:

```text
modified MsQuic source version: 2.4.8
vendored DPDK:                 21.11.9
TLS:                           OpenSSL
build type:                    Release
paper test NIC PCI:            0000:18:00.0
hugepages:                      16384 x 2 MiB
DPDK/Linux dataplane CPU:       19
MsQuic CPUs:                    21,22,23,24
```

Exact Debian package revisions and kernel patch level are resolved from the configured Debian Trixie repositories at setup time and are not individually pinned.

# 3. Case A — allocate/reimage fresh Debian nodes

## 3.1 Allocate/image/reset

**RUN ON: COINBASE/POS SHELL.** Do not run POS commands on the CONTROL HOST, SERVER shell, or CLIENT shell.

Paper-testbed example:

```bash
SERVER_NODE=idex
CLIENT_NODE=tinyman
pos nodes list | grep -E "$SERVER_NODE|$CLIENT_NODE"
```

Allocate only nodes that are genuinely unallocated and according to local POS policy. Do not free/replace another user's allocation.

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

## 3.2 Deploy/provision/build GreenQUIC+

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

# 4. Case B — Debian already exists; deploy current code and rebuild everything

Use this when Debian Trixie is already installed and SSH works, but `/root/mohsen` is absent/stale or you want a new exact `main` deployment/build.

Do not manually clone the private repository on SERVER or CLIENT. The supported setup keeps private GitHub credentials on CONTROL and transfers exact `origin/main` by Git bundle.

**RUN ON: CONTROL HOST:** use the same `bash results_analysis/setup_paper_testbed.sh` command from Case 3.2.

**LIVE MONITOR — RUN ON: second CONTROL-HOST terminal:** use `bash results_analysis/live_monitor_setup.sh` from Case 3.2.

# 5. Case C — different management host names/topology

The setup wrapper accepts:

```text
--server-host HOST
--client-host HOST
--server-to-client-host HOST
--bastion USER@HOST|none
--ssh-key PATH
```

`--client-host` is the CLIENT name/address visible from CONTROL/bastion during setup. `--server-to-client-host` is the CLIENT name/address visible from SERVER. They may differ.

Example **RUN ON: CONTROL HOST:**

```bash
REPO="$HOME/Downloads/GreenQUIC-Plus"
if [ ! -d "$REPO/.git" ]; then
  git clone git@github.com:Meamarian/GreenQUIC-Plus.git "$REPO"
fi
cd "$REPO" && \
git checkout main && \
bash results_analysis/setup_paper_testbed.sh \
  --server-host server01 \
  --client-host client-via-gateway \
  --server-to-client-host 10.0.0.22 \
  --bastion user@gateway \
  --ssh-key "$HOME/.ssh/lab_key"
```

**LIVE MONITOR — RUN ON: second CONTROL-HOST terminal:**

```bash
cd "$HOME/Downloads/GreenQUIC-Plus" && \
bash results_analysis/live_monitor_setup.sh \
  --server-host server01 \
  --client-host client-via-gateway \
  --bastion user@gateway \
  --ssh-key "$HOME/.ssh/lab_key"
```

Changing management names does not make the hardware configuration generic. CPU placement, E810 PCI/data-plane settings, hugepages, root privilege, and `/root/mohsen` are part of the current paper setup and require explicit revalidation on different hardware.

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

# 7. Final build outputs

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

# 8. After setup — run final paper evaluation

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

**LIVE MONITOR — RUN ON: second CONTROL-HOST terminal immediately after launch:**

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

# 9. Safety notes

- root SSH is required because setup installs packages, changes hugepages/MSR/PCI drivers, and writes under `/root`;
- `uio_pci_generic` is not accepted as the final P5 DPDK driver;
- the CONTROL private key is never copied to SERVER or CLIENT;
- private GitHub credentials remain on CONTROL;
- SERVER gets a dedicated key for SERVER→CLIENT;
- the original `Meamarian/GreenQUIC` repository is not modified.
