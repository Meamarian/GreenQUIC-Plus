# Host-role / SSH dependency audit

This note records the current `main` audit for host-name assumptions in the supported GreenQUIC+ paper workflow.

## Result

The **supported final setup and final paper launcher no longer require the physical machines to be named `idex` and `tinyman`**.

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

The paper-testbed names remain as defaults only:

```text
SERVER=idex
CLIENT=tinyman
BASTION=mohsen@coinbase
```

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

The previous current path had these operational assumptions:

- TUM setup hard-coded `idex`, `tinyman`, `mohsen@coinbase`, and `root@tinyman` in remote calls.
- the final fair launcher installed/launched only through literal `ssh idex` and used literal `root@tinyman` internally;
- generated `/root/run_p5.sh` and `/root/run_p7.sh` embedded `tinyman`;
- result download defaulted to `ssh idex` without an explicit bastion/key interface;
- current guides mixed role names and paper-testbed host names;
- V2/V3 launcher layers carried additional host-specific transformation logic.

These are now replaced by role variables/switches in the supported setup/final launcher/downloader. The final fair runner has one authoritative implementation; `_v2.sh` and `_v3.sh` are compatibility wrappers only.

## Remaining occurrences that are intentional or historical

Not every textual occurrence of `idex` / `tinyman` should be deleted:

1. **Paper provenance/configuration.** `p5_paper_evaluation.json` and `p7_paper_evaluation.json` describe the actual testbed used for the paper, so retaining the paper host names there is correct.
2. **Paper examples in guides.** Examples explicitly say that `idex`/`tinyman` are paper-testbed defaults and show where to substitute another host.
3. **Historical implementation filenames.** Files such as `run_matrix_from_idex.sh` and `run_matrix_from_idex_core.sh` are retained for compatibility/history. The active matrix interface accepts `--client-host`; the filename itself does not select a host.
4. **Historical tuning/research notes.** Old Performance1/Performance2 diagnostic documents may describe the original IDEX/Tinyman testbed. They are marked historical and are not the current operating guide.
5. **Generated/result provenance.** Old result/chart source names must not be rewritten because that would falsify provenance.

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
- can authenticate to the configured bastion (when used);
- has a node SSH key selected with `--ssh-key`;
- can reach SERVER/CLIENT through the chosen route.

The setup installs only that key's **public** half on the nodes. It never copies the CONTROL HOST private key to SERVER or CLIENT.

If the CLIENT name/address differs between the CONTROL HOST view and the SERVER view, use `--server-to-client-host` during setup and pass that SERVER-reachable value as `--client-host` to the final paper launcher.
