# GreenQUIC+ TUM/LRZ paper-testbed setup

This directory intentionally contains only:

```text
README.md
greenquic_fresh_setup.sh
```

`greenquic_fresh_setup.sh` is the **single supported provisioning/build implementation**. There is no longer a chain of `base`, `p4_p5`, `p6`, `p7`, or branch-specific setup scripts.

For our paper testbed, use the higher-level zero-argument wrapper:

```text
results_analysis/setup_paper_testbed.sh
```

It supplies the paper host/bastion/key defaults and calls this setup implementation.

---

# Roles and paper defaults

```text
CONTROL HOST  machine with the private GreenQUIC+ checkout; starts setup
SERVER        QUIC server + experiment controller
CLIENT        QUIC client
BASTION       optional SSH jump/bootstrap host
```

Paper-testbed defaults are centralized in `results_analysis/paper_testbed_defaults.sh`:

```text
SERVER as seen from CONTROL: idex
CLIENT as seen from CONTROL: tinyman
CLIENT as seen from SERVER:  tinyman
BASTION:                     mohsen@coinbase
CONTROL SSH key:             $HOME/.ssh/id_ed25519
remote user:                 root
remote repository root:      /root/mohsen
branch:                      main
paper test NIC PCI:          0000:18:00.0
```

`idex` and `tinyman` are defaults from our measurements; they are not semantic role names. A different deployment may use other host names or addresses.

---

# SSH requirements

Fresh setup requires:

```text
CONTROL -> BASTION        only when a bastion is used
BASTION -> SERVER         fresh-node public-key bootstrap
BASTION -> CLIENT         fresh-node public-key bootstrap
CONTROL -> SERVER         required
CONTROL -> CLIENT         required
SERVER  -> CLIENT         required
CLIENT  -> SERVER         not required
```

The setup installs the CONTROL public key on both nodes when needed and creates a dedicated SERVER key for SERVER -> CLIENT. It never copies the CONTROL private key to either endpoint.

Only the CONTROL HOST needs private-GitHub credentials. The exact `origin/main` commit is sent to SERVER and CLIENT by Git bundle.

If CONTROL and SERVER use different names/addresses for the CLIENT, use separate values for `GQ_CLIENT_HOST` and `GQ_SERVER_TO_CLIENT_HOST`.

---

# Case A — allocate/reimage fresh Debian nodes

## A1. POS allocation/image/reset

**RUN ON: Coinbase/POS shell.** Do not run these commands on CONTROL, SERVER, or CLIENT.

For our paper nodes:

```bash
SERVER_NODE=idex
CLIENT_NODE=tinyman
pos nodes list | grep -E "$SERVER_NODE|$CLIENT_NODE"
```

Allocate only a node that is actually unallocated and only according to the local POS policy. Do not free or replace another user's allocation.

After allocation, **RUN ON: Coinbase/POS shell**:

```bash
pos nodes image "$SERVER_NODE" debian-trixie
pos nodes image "$CLIENT_NODE" debian-trixie
pos nodes reset "$SERVER_NODE" &
pos nodes reset "$CLIENT_NODE" &
wait
```

Immediately monitor node state from **another Coinbase/POS shell**:

```bash
while true; do
  clear
  date
  pos nodes list | grep -E 'idex|tinyman'
  sleep 5
done
```

A POS reset destroys the live node filesystem. `/root/mohsen`, build trees, generated payloads and local experiment outputs should be treated as gone.

Still **RUN ON: Coinbase/POS shell**, wait for Debian/SSH readiness:

```bash
for h in "$SERVER_NODE" "$CLIENT_NODE"; do
  until ssh -o ConnectTimeout=5 root@"$h" 'hostname; . /etc/os-release; echo "$ID $VERSION_CODENAME"'; do
    echo "waiting for $h ..."
    sleep 5
  done
done
```

This loop is itself the live readiness monitor.

## A2. Provision/build GreenQUIC+

After both nodes answer SSH as Debian Trixie:

**RUN ON: CONTROL HOST**, from the GreenQUIC+ checkout:

```bash
bash results_analysis/setup_paper_testbed.sh
```

Immediately in **a second CONTROL-HOST terminal**:

```bash
bash results_analysis/live_monitor_setup.sh
```

Successful completion prints `GREENQUIC+ MAIN READY` and the selected SERVER, CLIENT and SERVER->CLIENT endpoints.

---

# Case B — Debian is already installed; deploy fresh current code and build

Use this when the OS is already correct and reachable but `/root/mohsen` is absent/stale, or when you want the newest exact `main` source and rebuilt P5/P7 applications.

Do **not** manually clone the private repository on SERVER or CLIENT. The supported setup deploys exact `origin/main` by Git bundle so private GitHub credentials remain only on CONTROL.

**RUN ON: CONTROL HOST:**

```bash
bash results_analysis/setup_paper_testbed.sh
```

Immediately in **a second CONTROL-HOST terminal**:

```bash
bash results_analysis/live_monitor_setup.sh
```

This is the recommended “fresh clone/deploy + build” workflow for already-installed Debian nodes.

---

# What the single setup script does

From CONTROL, `greenquic_fresh_setup.sh`:

1. resolves exact `origin/main` with an explicit refspec;
2. validates/bootstrap CONTROL SSH to SERVER and CLIENT;
3. creates and verifies SERVER -> CLIENT SSH;
4. installs the exact SHA on both nodes using a Git bundle;
5. verifies Debian Trixie;
6. installs build and measurement dependencies;
7. prepares Intel E810/ICE firmware;
8. loads/checks MSR and Intel P-state access on CPU19;
9. creates `16384 × 2 MiB` hugepages on the test-NIC NUMA node;
10. builds/install DPDK under `/root/mohsen/msquic/deps/dpdk-install`;
11. creates the 8-GiB payload;
12. builds/verifies P5 Performance2 V2 on both endpoints;
13. builds/verifies isolated P7 normal-Linux binaries on both endpoints;
14. checks that P7 does not link DPDK;
15. puts both E810 peers on ICE and UP before checking physical carrier;
16. binds both test NICs back to an approved DPDK driver (`igb_uio` or `vfio-pci`);
17. installs `/root/run_p5.sh` and `/root/run_p7.sh` on the SERVER role;
18. verifies exact Git SHA, binaries, P5 marker, hugepages, helpers and final NIC driver.

The setup itself does **not** allocate POS nodes, reimage them, or reboot them.

---

# Final build outputs

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

P5 build/profile:

```text
Performance2 V2
ENABLE_MULTICORE=0
DPDK CPU=19
MsQuic CPUs=21,22,23,24
```

P7 is an isolated normal-Linux MsQuic build with DPDK and XDP disabled.

The setup prepares the binaries and host state. The final TOP3 policy values are injected by the final paper runner, not by TUM provisioning defaults.

---

# After setup — final paper evaluation

**RUN ON: CONTROL HOST:**

```bash
bash results_analysis/run_paper_evaluation.sh
```

Immediately in **a second CONTROL-HOST terminal:**

```bash
bash results_analysis/live_monitor_run.sh
```

For the exact P5/P7 configuration, analysis artifacts, result paths, download helper, and all other start states, see `results_analysis/README.md`.

---

# Lower-level setup switches for another deployment

The high-level wrapper is zero-argument for our paper testbed. The underlying setup still supports explicit overrides:

```text
--server-host HOST
--client-host HOST
--server-to-client-host HOST
--bastion USER@HOST|none
--ssh-key PATH
```

Use these only when deploying to a different management topology. Changing host names does not change the paper's hardware/data-plane assumptions such as CPU placement, E810 PCI address, data-plane IP/MAC values or hugepage count.

---

# Safety notes

- root SSH is required because setup installs packages, changes hugepages/MSR/PCI drivers and writes under `/root`;
- `uio_pci_generic` is not accepted as the final P5 DPDK driver;
- the CONTROL private key is never copied to SERVER/CLIENT;
- private GitHub credentials remain on CONTROL;
- CLIENT -> SERVER SSH is not required;
- the original `Meamarian/GreenQUIC` repository is never modified by this setup.
