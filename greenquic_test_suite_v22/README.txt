GREENQUIC+ V22 SUITE — CURRENT OPERATING NOTE
=============================================

The authoritative current paper workflow is role-based. Do not infer roles from
historical host names or old file names.

Roles:
  CONTROL HOST  private GreenQUIC+ checkout; launches setup/final reproduction
  SERVER        QUIC server + experiment controller
  CLIENT        QUIC client started by SERVER over SSH

Paper-testbed defaults only:
  SERVER=idex
  CLIENT=tinyman
  BASTION=mohsen@coinbase

Current guides:
  ../README.md
  ../results_analysis/README.md
  ../tum_testbed_setup/README.md
  test_cases/pretests/P5_repeated_8GiB_downloads/README.md
  test_cases/pretests/P7_linux_udp_baseline/README.md

Final paper experiments:
  P5 = optimized DPDK MsQuic OFF/BASIC/PLUS repeated 8-GiB downloads
  P7 = isolated normal-Linux MsQuic UDP baseline

The supported control-host launcher accepts --server-host and --client-host.
The setup additionally accepts --server-to-client-host when the CLIENT has a
different name/address from the SERVER network view.

SERVER -> CLIENT passwordless/root SSH is required for matrix orchestration.
CLIENT -> SERVER SSH is not required. Only the CONTROL HOST needs credentials
for the private GitHub repository; exact commits are transferred to the nodes
by Git bundle.

Historical V18/V21/V22 diagnostic/pretest material remains in this tree and in
Git history. Files/scripts containing names such as *_from_idex* or comments
about idex/tinyman reflect the original testbed and are not the current host
selection interface. For final-paper operation follow the guides listed above.
