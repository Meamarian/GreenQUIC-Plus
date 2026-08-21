GREENQUIC+ V22 SUITE — CURRENT OPERATING NOTE
=============================================

The authoritative paper workflow is role-based. Do not infer roles from old
host names or historical filenames.

Roles:
  CONTROL HOST  private GreenQUIC+ checkout; launches setup/build/final run
  SERVER        QUIC server + experiment controller
  CLIENT        QUIC client started by SERVER over SSH

Our paper-testbed defaults are centralized in:
  ../results_analysis/paper_testbed_defaults.sh

Paper defaults:
  SERVER=idex
  CLIENT=tinyman
  BASTION=mohsen@coinbase
  SSH key=$HOME/.ssh/id_ed25519

Current user guides:
  ../README.md
  ../results_analysis/README.md
  ../tum_testbed_setup/README.md
  test_cases/pretests/P5_repeated_8GiB_downloads/README.md
  test_cases/pretests/P7_linux_udp_baseline/README.md

Supported high-level commands on our paper testbed:

  RUN ON CONTROL HOST:
    bash results_analysis/setup_paper_testbed.sh

  LIVE MONITOR IN SECOND CONTROL-HOST TERMINAL:
    bash results_analysis/live_monitor_setup.sh

  RUN ON CONTROL HOST:
    bash results_analysis/run_paper_evaluation.sh

  LIVE MONITOR IN SECOND CONTROL-HOST TERMINAL:
    bash results_analysis/live_monitor_run.sh

Final paper experiments:
  P5 = optimized DPDK MsQuic OFF/BASIC/PLUS repeated 8-GiB downloads
  P7 = isolated normal-Linux MsQuic UDP baseline

SERVER -> CLIENT passwordless/root SSH is required for matrix orchestration.
CLIENT -> SERVER SSH is not required. Only CONTROL needs private GitHub access;
exact commits are transferred to the endpoints by Git bundle.

Historical V18/V21/V22 diagnostic/pretest material remains in this tree and Git
history. Files named *_from_idex* and old comments mentioning idex/tinyman
reflect the original testbed. They are not the current host-selection interface.
