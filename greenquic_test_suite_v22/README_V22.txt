GreenQUIC+ test suite V22
=========================

This is the authoritative test-suite tree used by the final GreenQUIC+ paper
workflow. Full reproduction instructions are maintained in:

  ../results_analysis/README.md
  ../tum_testbed_setup/README.md

Roles
-----
  CONTROL HOST  launches setup/build/final paper evaluation
  SERVER        QUIC server + experiment controller
  CLIENT        QUIC client

Paper-testbed defaults
----------------------
Defaults are centralized in ../results_analysis/paper_testbed_defaults.sh:

  SERVER=idex
  CLIENT=tinyman
  BASTION=mohsen@coinbase
  SSH key=$HOME/.ssh/id_ed25519

These are conveniences for our testbed, not required host names.

Current paper paths
-------------------
  P5 directory:
    /root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads
  P5 build:
    /root/mohsen/msquic/build-greenquic-p5

  P7 directory:
    /root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline
  P7 build:
    /root/mohsen/msquic/build-linux-p7

Fresh deploy/build
------------------
RUN ON: CONTROL HOST

  bash results_analysis/setup_paper_testbed.sh

LIVE MONITOR — RUN ON: SECOND CONTROL-HOST TERMINAL

  bash results_analysis/live_monitor_setup.sh

Final paper evaluation
----------------------
RUN ON: CONTROL HOST

  bash results_analysis/run_paper_evaluation.sh

LIVE MONITOR — RUN ON: SECOND CONTROL-HOST TERMINAL

  bash results_analysis/live_monitor_run.sh

The low-level authoritative launcher remains:

  greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/
    mac_run_p5_p7_fair_repro_6x5.sh

The _v2.sh and _v3.sh names are compatibility wrappers only.

SSH requirements
----------------
SERVER must be able to SSH as root to CLIENT. CLIENT does not need to SSH back.
During fresh setup CONTROL must reach both endpoints directly or through the
configured bastion. Only CONTROL needs private-GitHub access.

Historical material
-------------------
The V22 tree still contains older diagnostic/research paths and historical
filenames such as run_matrix_from_idex.sh. Those names are retained for
provenance/compatibility and do not select the current physical hosts.
