# Historical P5 / Performance2 operator commands

> **Historical tuning note — not the current reproduction guide.**
>
> This file previously contained host-specific commands for the Performance1/
> Performance2 screening phase. Those commands assumed the paper testbed names
> `idex` and `tinyman` and several old tuning branches. They are preserved in Git
> history and the pre-cleanup backup branches, but are intentionally not kept as
> copy/paste operating instructions on current `main`.

For current operation use:

```text
results_analysis/README.md
tum_testbed_setup/README.md
greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/README.md
```

Current role terminology is:

```text
CONTROL HOST  launches provisioning and final paper reproduction
SERVER        QUIC server + experiment controller
CLIENT        QUIC client started by SERVER over SSH
```

In the paper testbed SERVER=`idex` and CLIENT=`tinyman`, but these are not fixed
host names. The authoritative final launcher is run on the CONTROL HOST and
accepts `--server-host`, `--client-host`, `--bastion`, and `--ssh-key`.

For a standalone matrix, run the matrix wrapper on the SERVER role and pass the
CLIENT explicitly with `--client-host`. SERVER -> CLIENT SSH is required.

The old Performance2 screening details and branch-specific commands remain
available through Git history and the historical performance branches for audit
or old-experiment reproduction.
