GreenQUIC+ test suite V22
=========================

This file is a short suite overview. The final paper reproduction instructions
are maintained in results_analysis/README.md.

Roles
-----
  CONTROL HOST  launches setup/final paper evaluation
  SERVER        QUIC server + experiment controller
  CLIENT        QUIC client

Paper-testbed host names were SERVER=idex and CLIENT=tinyman. They are defaults,
not required names. Current supported entrypoints take host switches.

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

Final launcher
--------------
RUN ON: CONTROL HOST

  greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/
    mac_run_p5_p7_fair_repro_6x5.sh

Host options:
  --server-host HOST
  --client-host HOST
  --bastion USER@HOST|none
  --ssh-key PATH

Fresh provisioning/build setup
------------------------------
RUN ON: CONTROL HOST after Debian Trixie is installed/reachable.

  tum_testbed_setup/greenquic_fresh_setup.sh

It additionally supports --server-to-client-host HOST.

SSH requirement
---------------
SERVER must be able to SSH as root to CLIENT. CLIENT does not need to SSH back.
During fresh setup the CONTROL HOST must reach both endpoints directly or through
the configured bastion. Only the CONTROL HOST needs private-GitHub access.

Historical material
-------------------
The V22 tree still contains old P0/P1/P2 and V18/V21 diagnostic/research paths.
Some historical filenames/comments mention idex/tinyman. They are retained for
provenance and old-experiment recovery; do not use them as the host-selection
interface for the current P5/P7 paper reproduction.
