# Host-role / SSH dependency audit

This note records the current `main` audit for host-name assumptions in the supported GreenQUIC+ paper workflow.

## Result

The **supported final setup and final paper launcher do not require the physical machines to be named `idex` and `tinyman`**.

Current public switches are:

```text
Fresh setup:
  --server-host HOST
  --client-host HOST
  --server-to-client-host HOST
  --bastion USER@HOST|none
  --ssh-key PATH

Final paper launcher:
  --server-host HOST
  --client-host HOST
  --bastion USER@HOST|none
  --ssh-key PATH

Result downloader:
  --server-host HOST
  --bastion USER@HOST|none
  --ssh-key PATH
```

The paper-testbed names remain defaults/examples only:

```text
SERVER=idex
CLIENT=tinyman
BASTION=mohsen@coinbase
```

`SERVER` and `CLIENT` are semantic experiment roles. `idex` and `tinyman` are merely the host names used for those roles in our paper measurements.

## Required connectivity

Fresh setup:

```text
CONTROL HOST -> SERVER       required
CONTROL HOST -> CLIENT       required
SERVER -> CLIENT             required
CLIENT -> SERVER             not required
```

When a bastion is configured, CONTROL HOST -> BASTION and BASTION -> both nodes are also required during fresh-node key bootstrap.

Final paper run:

```text
CONTROL HOST -> SERVER       required
SERVER -> CLIENT             required
CONTROL HOST -> CLIENT       not required by final launcher
CLIENT -> SERVER             not required
```

Only the CONTROL HOST needs private-GitHub credentials. The node checkout is synchronized with an exact-SHA Git bundle.

## What was genuinely name-dependent and was fixed

The audit found these operational assumptions in the inherited workflow:

- TUM setup hard-coded `idex`, `tinyman`, `mohsen@coinbase`, and `root@tinyman` in remote calls;
- the final fair launcher installed/launched only through literal `ssh idex` and used literal `root@tinyman` internally;
- generated `/root/run_p5.sh` and `/root/run_p7.sh` embedded `tinyman`;
- result download defaulted to `ssh idex` without an explicit bastion/key interface;
- current guides mixed role names and paper-testbed host names;
- V2/V3 launcher layers carried additional host-specific transformation logic;
- **a hidden runtime dependency remained in `greenquic_test_suite_v22/suite.env`: `SERVER_NAME=idex` and `CLIENT_NAME=tinyman`.** P5/P7 role checks consume those variables, so changing only the SSH switches could still reject machines whose operating-system hostnames were different.

The supported path is now role-based end to end. `suite.env` no longer defaults its runtime hostname guard to `idex`/`tinyman`; it defaults the legacy guard variables to the local machine's own short hostname. `SERVER_NAME`/`CLIENT_NAME` may still be set explicitly when someone deliberately wants strict OS-hostname validation, but they are **not SSH endpoint selectors**.

The final fair runner has one authoritative implementation; `_v2.sh` and `_v3.sh` are compatibility wrappers only. `results_analysis/verify_paper_configuration.py` now fails if the literal `idex`/`tinyman` runtime hostname defaults are reintroduced.

## Three different kinds of address/name

Do not mix these:

1. **Role** — `SERVER` or `CLIENT`. This describes what the endpoint does.
2. **SSH endpoint** — selected with `--server-host`, `--client-host`, and, during setup, `--server-to-client-host`. This may be a hostname, SSH alias, or address reachable from the relevant machine.
3. **QUIC/DPDK data-plane address** — the paper configuration uses `192.168.100.1` and `192.168.100.2` plus the recorded MAC/PCI configuration. These are independent of the management SSH names.

The control host itself also has no required hostname. A Mac was used in the paper testbed, but another Unix machine can be the CONTROL HOST.

## Remaining occurrences that are intentional or historical

Not every textual occurrence of `idex` / `tinyman` should be deleted:

1. **Paper provenance/configuration.** `p5_paper_evaluation.json` and `p7_paper_evaluation.json` describe the actual testbed used for the paper, so retaining the paper host names there is correct.
2. **Paper examples in guides.** Examples explicitly say that `idex`/`tinyman` are paper-testbed defaults and show where to substitute another host.
3. **Historical implementation filenames.** Files such as `run_matrix_from_idex.sh` and `run_matrix_from_idex_core.sh` are retained for compatibility/history. The active matrix interface accepts `--client-host`; the filename itself does not select a host.
4. **Historical tuning/research notes.** Old Performance1/Performance2 diagnostic documents may describe the original IDEX/Tinyman testbed. They are marked historical and are not the current operating guide.
5. **Generated/result provenance.** Old result/chart source names must not be rewritten because that would falsify provenance.
6. **Paper-default fallbacks.** Some lower-level historical/standalone scripts still use `tinyman` as a convenience default but expose `--client-host`. The authoritative setup and final paper launcher always pass the selected role endpoint explicitly; those defaults are not used to determine the final-run roles.

## Important non-host assumptions that remain paper-specific

Host-name parameterization does not make the experiment hardware-agnostic. The final paper configuration intentionally retains:

```text
remote user/root paths: root, /root/mohsen
E810 PCI address:        0000:18:00.0
P5/P7 data-plane IPs:    192.168.100.1 / 192.168.100.2
DPDK/IRQ CPU:            19
MsQuic CPUs:             21,22,23,24
hugepages:               16384 x 2 MiB
```

Those are part of the evaluated testbed/configuration, not accidental SSH host-name dependencies. A deployment on different hardware must intentionally adapt and revalidate those values; changing `--server-host` / `--client-host` alone is not sufficient.

## Different control host / different Mac

The workflow does not rely on a specific Mac hostname or on `ssh idex` aliases. A different CONTROL HOST can be used if it:

- can fetch the private `Meamarian/GreenQUIC-Plus` repository;
- has `git`, `ssh`, `scp`, Python 3, and the other control-side utilities required by the scripts;
- can authenticate to the configured bastion when one is used;
- has a node SSH key selected with `--ssh-key`;
- can reach the configured SERVER/CLIENT through the chosen route.

The setup installs only that key's **public** half on the nodes. It never copies the CONTROL HOST private key to SERVER or CLIENT.

If the CLIENT name/address differs between the CONTROL HOST view and the SERVER view, use `--server-to-client-host` during setup and pass that SERVER-reachable value as `--client-host` to the final paper launcher.

## Command-location rule for current guides

Every current operational command should be introduced as one of:

```text
RUN ON: CONTROL HOST
RUN ON: COINBASE/POS SHELL
RUN ON: SERVER ROLE
RUN ON: CLIENT ROLE
```

When a command uses SSH, the guide must also state which direction that SSH connection represents. Historical documents may retain old examples, but they are marked historical and must not be treated as the current reproduction interface.
