# Host-role / SSH dependency audit

This note records the current `main` audit for host-name assumptions in the supported GreenQUIC+ paper workflow.

## Result

The supported setup and paper runner **do not require the physical machines to be named `idex` and `tinyman`**. Those are our paper-testbed defaults only.

The high-level paper defaults are centralized in:

```text
results_analysis/paper_testbed_defaults.sh
```

Our defaults are:

```text
SERVER as seen from CONTROL: idex
CLIENT as seen from CONTROL: tinyman
CLIENT as seen from SERVER:  tinyman
BASTION:                     mohsen@coinbase
CONTROL SSH key:             $HOME/.ssh/id_ed25519
```

That lets our paper testbed use zero-argument high-level commands:

```text
setup:    results_analysis/setup_paper_testbed.sh
rebuild:  results_analysis/rebuild_paper_binaries.sh
run:      results_analysis/run_paper_evaluation.sh
download: results_analysis/download_paper_results.sh
```

Another deployment can override the management `GQ_*` values or use the lower-level host switches.

## Roles

```text
CONTROL HOST  holds the private checkout and starts setup/build/test
SERVER        QUIC server + experiment controller
CLIENT        QUIC client
BASTION       optional SSH jump/bootstrap host
```

`SERVER` and `CLIENT` are semantic experiment roles. `idex` and `tinyman` are merely the physical host names used for those roles in our paper measurements.

## Lower-level management switches

Fresh setup:

```text
--server-host HOST
--client-host HOST
--server-to-client-host HOST
--bastion USER@HOST|none
--ssh-key PATH
```

Final paper launcher:

```text
--server-host HOST
--client-host HOST
--bastion USER@HOST|none
--ssh-key PATH
```

Result downloader:

```text
--server-host HOST
--bastion USER@HOST|none
--ssh-key PATH
```

## Required connectivity

Fresh setup/deployment:

```text
CONTROL -> BASTION        required only when a bastion is used
BASTION -> SERVER         required for fresh-node key bootstrap
BASTION -> CLIENT         required for fresh-node key bootstrap
CONTROL -> SERVER         required
CONTROL -> CLIENT         required
SERVER  -> CLIENT         required
CLIENT  -> SERVER         not required
```

Final paper run:

```text
CONTROL -> SERVER         required
SERVER  -> CLIENT         required
CONTROL -> CLIENT         not required by the final launcher
CLIENT  -> SERVER         not required
```

Only CONTROL needs private-GitHub credentials. Exact code is synchronized to the experiment nodes with a Git bundle.

## What was genuinely name-dependent and was fixed

The inherited workflow contained real operational assumptions:

- TUM setup used literal `idex`, `tinyman`, `mohsen@coinbase`, and `root@tinyman` paths;
- the fair launcher used literal `ssh idex` and `root@tinyman`;
- generated convenience launchers embedded `tinyman`;
- result download assumed `ssh idex` without an explicit route/key interface;
- old guides mixed role names and paper-testbed host names;
- V2/V3 fair-runner layers carried extra host-specific transformation logic;
- `greenquic_test_suite_v22/suite.env` previously defaulted runtime hostname guards to `SERVER_NAME=idex` and `CLIENT_NAME=tinyman`.

The supported path is now role-based. `suite.env` defaults its legacy runtime guard variables to the local machine's own short hostname, so changing SSH endpoints does not require renaming the OS host. The verifier fails if literal `idex`/`tinyman` runtime hostname requirements are reintroduced.

The fair runner now has one authoritative implementation; `_v2.sh` and `_v3.sh` are compatibility wrappers only.

## Three different kinds of address/name

Do not mix these:

1. **Role** — SERVER or CLIENT.
2. **Management/SSH endpoint** — selected by the defaults or host switches. It may be a hostname, SSH alias, or management IP.
3. **QUIC/DPDK data-plane address** — the paper uses `192.168.100.1` and `192.168.100.2` plus recorded MAC/PCI values. These are independent of management SSH names.

The CONTROL HOST itself has no required hostname. A Mac was used for our paper testbed, but another Unix control machine is supported if it has the private checkout and required SSH route.

## Remaining `idex` / `tinyman` occurrences

Not every textual occurrence should be deleted:

1. `p5_paper_evaluation.json` and `p7_paper_evaluation.json` retain the actual paper-testbed host names as provenance.
2. Current guides show the paper defaults while clearly labeling them as defaults.
3. Historical filenames such as `run_matrix_from_idex.sh` / `run_matrix_from_idex_core.sh` remain for compatibility. Their filenames do not select the current SERVER.
4. Historical tuning/research notes describe the original testbed and are retained for provenance.
5. Old result/chart source names must not be rewritten because that would falsify provenance.
6. Some lower-level standalone scripts keep `tinyman` as a convenience default but expose `--client-host`; the supported high-level paper runner passes the selected endpoint explicitly.

## Paper-specific non-host assumptions

Host-name parameterization does not make the experiment hardware-agnostic. The final paper configuration intentionally retains:

```text
remote user/root paths: root, /root/mohsen
E810 PCI address:        0000:18:00.0
P5/P7 data-plane IPs:    192.168.100.1 / 192.168.100.2
DPDK/IRQ CPU:            19
MsQuic CPUs:             21,22,23,24
hugepages:               16384 x 2 MiB
```

These are evaluated testbed/configuration values, not accidental SSH host-name dependencies. A different hardware platform must intentionally adapt and revalidate them.

## Different CONTROL HOST / different Mac

A different CONTROL HOST works if it:

- can clone/fetch the private `Meamarian/GreenQUIC-Plus` repository;
- has `git`, `ssh`, `scp`, Python 3, and the required local utilities;
- can authenticate to the configured bastion when one is used;
- has the selected node SSH key;
- can reach the configured SERVER/CLIENT management route.

The setup installs only the CONTROL key's **public** half on experiment nodes. It never copies the CONTROL private key to SERVER or CLIENT.

If the CLIENT management endpoint differs between CONTROL and SERVER views, set `GQ_CLIENT_HOST` and `GQ_SERVER_TO_CLIENT_HOST` separately.

## Command-location rule

Current operational guides label commands as:

```text
RUN ON: CONTROL HOST
RUN ON: COINBASE/POS SHELL
RUN ON: SERVER ROLE
RUN ON: CLIENT ROLE
```

Long-running setup/build/test commands are immediately paired with the matching live-monitor command. Historical documents may retain old examples but are not the current reproduction interface.
