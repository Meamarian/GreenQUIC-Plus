# GreenQUIC+ TUM/LRZ paper-testbed setup

This directory intentionally contains only:

```text
README.md
greenquic_fresh_setup.sh
```

`greenquic_fresh_setup.sh` is the **single supported provisioning/build implementation**. There is no longer a chain of base/P4/P5/P6/P7/branch-specific setup scripts.

For normal operation use the high-level wrapper:

```text
results_analysis/setup_paper_testbed.sh
```

It supplies the paper defaults, safely synchronizes CONTROL `main`, verifies the paper configuration, and calls the single setup implementation. It also accepts explicit management switches for another deployment.

---

# 1. Roles and paper defaults

```text
CONTROL HOST  machine with the private GreenQUIC+ checkout; starts setup
SERVER        QUIC server + experiment controller
CLIENT        QUIC client
BASTION       optional SSH jump/bootstrap host
```

Paper defaults are centralized in `results_analysis/paper_testbed_defaults.sh`:

```text
CONTROL checkout:             $HOME/Downloads/GreenQUIC-Plus on our Mac
SERVER as seen from CONTROL:  idex
CLIENT as seen from CONTROL:  tinyman
CLIENT as seen from SERVER:   tinyman
BASTION:                      mohsen@coinbase
CONTROL SSH key:              $HOME/.ssh/id_ed25519
remote user:                  root
remote repository root:       /root/mohsen
branch:                       main
paper test NIC PCI:           0000:18:00.0
```

`idex` and `tinyman` are the host names used in our measurements; they are not role definitions. Another deployment may use other SSH names or addresses.

---

# 2. Required SSH topology

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

The setup installs the CONTROL **public** key on both nodes when needed. The CONTROL private key stays on CONTROL. Setup also creates a dedicated SERVER key for SERVER -> CLIENT.

Only CONTROL needs private-GitHub credentials. The exact `origin/main` commit is sent to SERVER and CLIENT by Git bundle.

If CONTROL and SERVER use different names/addresses for CLIENT, use separate `--client-host` and `--server-to-client-host` values during setup.

---

# 3. Dependencies and versions

The setup is intentionally strict about the endpoint OS and source versions.

| Component | Version / requirement |
|---|---|
| SERVER/CLIENT OS | Debian Trixie |
| Modified MsQuic source | source version `2.4.8`, exact code fixed by GreenQUIC+ Git SHA |
| DPDK | `21.11.9` from the vendored tree |
| CMake | `>= 3.20` for the static MsQuic build used by P5/P7 |
| TLS backend | OpenSSL |
| Build type | Release |
| Python | Python 3 with NumPy and Matplotlib |
| Measurement | RAPL access, MSR support, `msr-tools`, `lm-sensors`, `acpi.sh`, `msr.py` |
| Network tooling | `ethtool`, `iproute2`, PCI/kernel-module tooling |

The setup installs the required compiler/build/network/measurement packages from the configured Debian Trixie repositories. **Exact Debian package revisions and the kernel patch version are not individually pinned by the script.** The complete package list and version-pinning policy are recorded in:

```text
results_analysis/configuration/dependencies.json
```

The source versions are repository-backed: `msquic/CMakeLists.txt` declares MsQuic `2.4.8`, and `msquic/deps/dpdk/VERSION` is `21.11.9`. Because GreenQUIC+ modifies MsQuic, a clean upstream MsQuic 2.4.8 checkout is not equivalent; use the exact GreenQUIC+ commit transferred by the setup.

After setup, **RUN ON: CONTROL HOST** to print the actual CONTROL/SERVER/CLIENT kernel/tool/package versions:

```bash
bash results_analysis/print_dependency_versions.sh
```

This is inspection only and starts no traffic; no live workload monitor applies.

---

# 4. Case A — allocate/reimage fresh Debian nodes

## A1. POS allocation/image/reset

**RUN ON: Coinbase/POS shell.** Do not run these node-management commands on CONTROL, SERVER, or CLIENT.

Set the physical POS node names. For our paper testbed:

```bash
SERVER_NODE=idex
CLIENT_NODE=tinyman
pos nodes list | grep -E "$SERVER_NODE|$CLIENT_NODE"
```

Allocate only nodes that are actually unallocated and according to the local POS policy. Do not free or replace another user's allocation.

After allocation, **RUN ON: Coinbase/POS shell:**

```bash
SERVER_NODE=idex
CLIENT_NODE=tinyman
pos nodes image "$SERVER_NODE" debian-trixie
pos nodes image "$CLIENT_NODE" debian-trixie
pos nodes reset "$SERVER_NODE" &
pos nodes reset "$CLIENT_NODE" &
wait
```

Immediately monitor from **another Coinbase/POS shell:**

```bash
SERVER_NODE=idex
CLIENT_NODE=tinyman
while true; do
  clear
  date
  pos nodes list | grep -E "$SERVER_NODE|$CLIENT_NODE"
  sleep 5
done
```

A POS reset destroys the live node filesystem. Treat `/root/mohsen`, build trees, generated payloads, and local experiment outputs as gone.

When POS reports both nodes up, still **RUN ON: Coinbase/POS shell** to verify Debian/SSH readiness. This loop is itself the live readiness monitor:

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

## A2. Deploy/provision/build GreenQUIC+

After both endpoints answer SSH as Debian Trixie, this is the **paper-default one-paste command for our Mac/CONTROL HOST**. It clones the private repository only if it is not already present.

**RUN ON: CONTROL HOST:**

```bash
REPO="$HOME/Downloads/GreenQUIC-Plus"
if [ ! -d "$REPO/.git" ]; then
  git clone git@github.com:Meamarian/GreenQUIC-Plus.git "$REPO"
fi
cd "$REPO" && \
git checkout main && \
bash results_analysis/setup_paper_testbed.sh
```

Immediately in **a second CONTROL-HOST terminal:**

```bash
cd "$HOME/Downloads/GreenQUIC-Plus" && \
bash results_analysis/live_monitor_setup.sh
```

Successful completion prints `GREENQUIC+ MAIN READY` and the selected SERVER, CLIENT and SERVER->CLIENT endpoints.

---

# 5. Case B — Debian already exists; deploy current code and rebuild everything

Use this when Debian Trixie is already installed and SSH works, but `/root/mohsen` is absent/stale or you want the newest exact `main` source and fresh P5/P7 builds.

Do not manually clone the private repository on SERVER or CLIENT. The supported setup keeps private GitHub credentials on CONTROL and deploys exact `origin/main` by Git bundle.

**RUN ON: CONTROL HOST:** use the same one-paste command from Case A2.

Immediately in **a second CONTROL-HOST terminal:** use the same `live_monitor_setup.sh` command from Case A2.

This is the recommended “fresh clone/deploy + build” workflow for already-installed Debian nodes.

---

# 6. Another management topology

The paper defaults need no switches. Another deployment can override management routing without editing source:

```text
--server-host HOST
--client-host HOST
--server-to-client-host HOST
--bastion USER@HOST|none
--ssh-key PATH
```

Example where CONTROL sees CLIENT as `client-via-gateway`, while SERVER reaches it as `10.0.0.22`:

**RUN ON: CONTROL HOST:**

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

Immediately in **a second CONTROL-HOST terminal:**

```bash
cd "$HOME/Downloads/GreenQUIC-Plus" && \
bash results_analysis/live_monitor_setup.sh \
  --server-host server01 \
  --client-host client-via-gateway \
  --bastion user@gateway \
  --ssh-key "$HOME/.ssh/lab_key"
```

Changing management names does not change the recorded paper hardware/data-plane configuration. CPU placement, E810 PCI address, data-plane IP/MAC values, hugepages, root privilege, and `/root/mohsen` remain part of the current paper setup and require explicit revalidation on different hardware.

---

# 7. What the single setup implementation does

From CONTROL, `greenquic_fresh_setup.sh`:

1. resolves exact `origin/main` with an explicit refspec;
2. validates/bootstraps CONTROL SSH to SERVER and CLIENT;
3. creates and verifies SERVER -> CLIENT SSH;
4. installs the exact SHA on both endpoints with a Git bundle;
5. verifies Debian Trixie;
6. installs build/measurement dependencies;
7. prepares Intel E810/ICE firmware;
8. loads/checks MSR and Intel P-state access on CPU19;
9. creates `16384 × 2 MiB` hugepages on the test-NIC NUMA node;
10. builds/installs DPDK 21.11.9 under `/root/mohsen/msquic/deps/dpdk-install`;
11. creates the 8-GiB payload;
12. builds/verifies P5 Performance2 V2 on both endpoints;
13. builds/verifies isolated P7 normal-Linux binaries on both endpoints;
14. checks that P7 does not link DPDK;
15. puts both E810 peers on ICE and UP before physical-carrier validation;
16. binds both test NICs back to an approved DPDK driver (`igb_uio` or `vfio-pci`);
17. installs `/root/run_p5.sh` and `/root/run_p7.sh` on the SERVER role;
18. verifies exact Git SHA, binaries, P5 marker, hugepages, helpers and final NIC driver.

The setup itself does **not** allocate POS nodes, reimage them, or reboot them.

---

# 8. Final build outputs

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

P7 is an isolated normal-Linux MsQuic build with DPDK and XDP disabled. The setup prepares binaries and host state; the final TOP3 power-policy values are injected by the paper evaluation launcher.

---

# 9. After setup — final paper evaluation

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

Immediately in **a second CONTROL-HOST terminal:**

```bash
cd "$HOME/Downloads/GreenQUIC-Plus" && \
bash results_analysis/live_monitor_run.sh
```

For exact P5/P7 configuration, result paths, download helpers, another-host run switches, dependency reporting, and static validation, see `results_analysis/README.md`.

---

# 10. Safety notes

- root SSH is required because setup installs packages, changes hugepages/MSR/PCI drivers and writes under `/root`;
- `uio_pci_generic` is not accepted as the final P5 DPDK driver;
- the CONTROL private key is never copied to SERVER/CLIENT;
- private GitHub credentials remain on CONTROL;
- CLIENT -> SERVER SSH is not required;
- the original `Meamarian/GreenQUIC` repository is not modified by this workflow.
