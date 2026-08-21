# GreenQUIC+ TUM/LRZ setup

This directory contains the **single supported provisioning/build entrypoint**:

```text
tum_testbed_setup/greenquic_fresh_setup.sh
```

It prepares the P5/P7 paper testbed from a CONTROL HOST. Physical host names are configurable.

## Roles, not host names

```text
CONTROL HOST  machine with the private GreenQUIC+ checkout; starts setup
SERVER        QUIC server + experiment controller
CLIENT        QUIC client
BASTION       optional SSH jump/bootstrap host
```

For our paper testbed only:

```text
SERVER=idex
CLIENT=tinyman
BASTION=mohsen@coinbase
```

Those strings are defaults, not code semantics. Another deployment may use different host names or IP addresses. The setup requires root SSH on SERVER and CLIENT because it installs packages, configures hugepages/MSR/PCI drivers, and writes under `/root`.

## SSH topology

Before/during fresh setup:

```text
CONTROL HOST -> BASTION       required if --bastion is used
BASTION -> SERVER             required for fresh-node public-key bootstrap
BASTION -> CLIENT             required for fresh-node public-key bootstrap
CONTROL HOST -> SERVER        required
CONTROL HOST -> CLIENT        required
SERVER -> CLIENT              required; setup creates/tests this SSH path
CLIENT -> SERVER              not required
```

Only the CONTROL HOST needs private-GitHub credentials. The exact `origin/main` commit is transferred to both experiment nodes using a Git bundle.

A different Mac/control machine works as long as it can fetch this private repository and reach the configured SSH path. Pass its node key with `--ssh-key`. With `--bastion none`, that key must already be authorized on both nodes.

If the CLIENT is reached under a different address from SERVER than from CONTROL HOST, use:

```text
--client-host <control/bastion view>
--server-to-client-host <server view>
```

## Setup switches

**RUN ON: CONTROL HOST** to see the exact interface:

```bash
bash tum_testbed_setup/greenquic_fresh_setup.sh --help
```

Supported switches:

```text
--server-host HOST
--client-host HOST
--server-to-client-host HOST
--bastion USER@HOST|none
--ssh-key PATH
```

Paper-testbed defaults are `idex`, `tinyman`, `tinyman`, `mohsen@coinbase`, and `~/.ssh/id_ed25519` respectively.

---

## Case 1 — nodes need a fresh Debian installation

### 1A. Allocate/image/reset

**RUN ON: Coinbase/POS shell.** Do not run these POS commands on SERVER, CLIENT, or the CONTROL HOST.

For our paper node names:

```bash
SERVER_NODE=idex
CLIENT_NODE=tinyman

pos nodes list | grep -E "$SERVER_NODE|$CLIENT_NODE"
```

Allocate only nodes that are actually unallocated and according to the local POS policy:

```bash
pos allocations allocate "$SERVER_NODE"
pos allocations allocate "$CLIENT_NODE"
```

Then:

```bash
pos nodes image "$SERVER_NODE" debian-trixie
pos nodes image "$CLIENT_NODE" debian-trixie

pos nodes reset "$SERVER_NODE" &
pos nodes reset "$CLIENT_NODE" &
wait

pos nodes list | grep -E "$SERVER_NODE|$CLIENT_NODE"
```

A reset destroys the live node filesystem. Treat `/root/mohsen`, previous builds, generated payloads, and local results as gone.

Still **RUN ON: Coinbase/POS shell**, wait for SSH:

```bash
for h in "$SERVER_NODE" "$CLIENT_NODE"; do
  until ssh -o ConnectTimeout=5 root@"$h" 'hostname; . /etc/os-release; echo "$ID $VERSION_CODENAME"'; do
    echo "waiting for $h ..."
    sleep 5
  done
done
```

### 1B. Provision and build

**RUN ON: CONTROL HOST.** Paper-testbed example:

```bash
cd ~/Downloads/GreenQUIC-Plus && \
git fetch origin '+refs/heads/main:refs/remotes/origin/main' && \
git checkout main && \
git reset --hard refs/remotes/origin/main && \
python3 results_analysis/verify_paper_configuration.py && \
bash tum_testbed_setup/greenquic_fresh_setup.sh \
  --server-host idex \
  --client-host tinyman \
  --server-to-client-host tinyman \
  --bastion mohsen@coinbase \
  --ssh-key "$HOME/.ssh/id_ed25519"
```

The explicit Git refspec also works when the local clone was originally created with `--single-branch` and lacks a normal `origin/main` tracking ref.

Immediately use **a second CONTROL-HOST terminal** to monitor:

```bash
SERVER_HOST=idex
CLIENT_HOST=tinyman
BASTION=mohsen@coinbase
KEY="$HOME/.ssh/id_ed25519"
while true; do
  clear; date
  for h in "$SERVER_HOST" "$CLIENT_HOST"; do
    echo "===== $h ====="
    ssh -i "$KEY" -J "$BASTION" root@"$h" \
      'hostname; git -C /root/mohsen rev-parse --short HEAD 2>/dev/null || echo repo-not-ready; pgrep -af "meson|ninja|cmake|build_p5|build_p7" || true'
  done
  sleep 10
done
```

---

## Case 2 — Debian Trixie already exists; deploy current code and rebuild everything

Do not reimage. **RUN ON: CONTROL HOST** and use exactly the provisioning/build command from Case 1B.

This is the recommended equivalent of “fresh clone + build” on the remote nodes. Do not manually clone the private repository on SERVER/CLIENT: the setup bundles the exact CONTROL-HOST `origin/main` SHA and installs it under `/root/mohsen`, so the nodes do not need GitHub credentials.

Use the same second-terminal monitor from Case 1B.

---

## What the single setup script does

From the CONTROL HOST it:

1. resolves exact `origin/main` using an explicit fetch refspec;
2. validates/bootstraps CONTROL-HOST SSH to SERVER and CLIENT;
3. creates and verifies SERVER -> CLIENT SSH;
4. transfers the exact Git SHA to both nodes by bundle;
5. verifies Debian Trixie;
6. installs build/measurement dependencies;
7. prepares Intel E810/ICE firmware;
8. verifies MSR and Intel P-state access on CPU19;
9. creates `16384 × 2 MiB` hugepages on the test-NIC NUMA node;
10. builds DPDK under `/root/mohsen/msquic/deps/dpdk-install`;
11. creates the 8-GiB payload;
12. builds/verifies P5 Performance2 V2 on both endpoints;
13. builds/verifies isolated P7 Linux binaries on both endpoints and checks that P7 does not link DPDK;
14. brings both direct E810 peers onto `ice` and UP before carrier validation;
15. binds the test NIC to `igb_uio` or `vfio-pci`;
16. installs `/root/run_p5.sh` and `/root/run_p7.sh` on the SERVER role, configured for the selected CLIENT address;
17. performs final SHA/binary/hugepage/driver/helper verification.

Successful completion prints `GREENQUIC+ MAIN READY` and the chosen SERVER, CLIENT, and SERVER->CLIENT host names.

## Final binaries

On both SERVER and CLIENT:

```text
P5 client:  /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop
P5 server:  /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinteropserver
P7 client:  /root/mohsen/msquic/build-linux-p7/bin/Release/quicinterop
P7 server:  /root/mohsen/msquic/build-linux-p7/bin/Release/quicinteropserver
```

P5 must contain:

```text
GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0
```

The setup builds binaries and prepares machines. The final TOP3 experiment settings are defined by `results_analysis/configuration/` and explicitly injected by the paper launcher.

---

## Case 3 — machines are already prepared; run the final paper evaluation

**RUN ON: CONTROL HOST**, not directly on SERVER/CLIENT:

```bash
cd ~/Downloads/GreenQUIC-Plus && \
python3 results_analysis/verify_paper_configuration.py && \
bash greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_p7_fair_repro_6x5.sh \
  --server-host idex \
  --client-host tinyman \
  --bastion mohsen@coinbase \
  --ssh-key "$HOME/.ssh/id_ed25519"
```

`--client-host` here is the CLIENT name/address reachable **from SERVER**. The final launcher requires CONTROL HOST -> SERVER and SERVER -> CLIENT; it does not require CLIENT -> SERVER.

Immediately monitor from **another CONTROL-HOST terminal**:

```bash
SERVER_HOST=idex
BASTION=mohsen@coinbase
KEY="$HOME/.ssh/id_ed25519"
ssh -i "$KEY" -J "$BASTION" root@"$SERVER_HOST" '
log=$(find /root -maxdepth 1 -type f -name "GQ_FAIR_REPRO_*.log" -printf "%T@ %p\n" 2>/dev/null | sort -nr | sed -n "1p" | cut -d" " -f2-)
echo "FOLLOWING: $log"; echo
if [ -z "$log" ]; then echo "No GQ_FAIR_REPRO log found yet"; else tail -n +1 -F "$log"; fi
'
```

For full paper configuration, build-only workflow, result paths, and downloading, see `results_analysis/README.md`.

## Safety notes

- The setup itself does not perform POS allocation or reimage/reset nodes.
- The setup does not reboot the nodes.
- The control-host private key is never copied to SERVER or CLIENT; only its public key is installed.
- SERVER gets its own SSH key for SERVER -> CLIENT.
- Private GitHub credentials are never copied to SERVER/CLIENT.
- `uio_pci_generic` is not accepted as the final DPDK driver.
- The original `Meamarian/GreenQUIC` repository is not modified.
