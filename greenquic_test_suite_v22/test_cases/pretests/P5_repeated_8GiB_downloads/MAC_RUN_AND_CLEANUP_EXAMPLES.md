# Historical Mac run / cleanup examples

> **Historical note — not the current GreenQUIC+ operating guide.**
>
> The old content in this file documented many intermediate P4/P5/P6/P7 and
> tuning commands that assumed the paper-testbed aliases `idex` and `tinyman`.
> Keeping those commands as current copy/paste examples would conflict with the
> role-based `GreenQUIC-Plus/main` workflow. Their original text remains in Git
> history and the preserved historical branches.

Use the current guides instead:

```text
results_analysis/README.md
tum_testbed_setup/README.md
greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/README.md
greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline/README.md
```

Current roles:

```text
CONTROL HOST  machine with the private repository checkout
SERVER        QUIC server + experiment controller
CLIENT        QUIC client
```

Paper-testbed defaults are SERVER=`idex`, CLIENT=`tinyman`, and optional
BASTION=`mohsen@coinbase`; these names are not required by the supported
entrypoints.

The authoritative final paper launcher is **RUN ON: CONTROL HOST** and accepts:

```text
--server-host HOST
--client-host HOST
--bastion USER@HOST|none
--ssh-key PATH
```

Fresh provisioning is also **RUN ON: CONTROL HOST** after any POS allocation /
Debian reset and additionally supports `--server-to-client-host` when the client
has a different address from the SERVER's network view.

Do not use broad historical `pkill -f` cleanup snippets from old logs/notes.
Current final-run cleanup is performed by the supported controller and its safe
P5 cleanup helper.
