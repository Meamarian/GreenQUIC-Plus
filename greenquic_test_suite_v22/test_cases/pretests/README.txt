GreenQUIC+ V22 pretests
=======================

This directory contains historical and current pretests. Host names are not
roles.

Roles:
  SERVER  QUIC server + controller
  CLIENT  QUIC client

Paper-testbed defaults were SERVER=idex and CLIENT=tinyman, but current P5/P7
entrypoints accept host switches.

Current paper-evaluation paths:
  P5_repeated_8GiB_downloads
    optimized DPDK MsQuic OFF/BASIC/PLUS comparison
  P7_linux_udp_baseline
    isolated normal-Linux MsQuic UDP baseline

Current operating guides:
  P5_repeated_8GiB_downloads/README.md
  P7_linux_udp_baseline/README.md
  ../../../results_analysis/README.md   (from repository root use results_analysis/README.md)

Historical P0/P1/P2 meaning:
  P0_smoke_1MiB          early one-download DPDK smoke test
  P1_goodput_off_10GiB   early OFF goodput baseline
  P2_goodput_basic_10GiB early BASIC goodput test

Those earlier paths and scripts may still contain original idex/tinyman labels or
*_from_idex* filenames. Treat them as historical testbed provenance. For the
current paper comparison, run the authoritative launcher from the CONTROL HOST
and select the real endpoint names with --server-host / --client-host.

For standalone server-side matrices, SERVER -> CLIENT root SSH is required and
the CLIENT should be passed explicitly with --client-host. CLIENT -> SERVER SSH
is not required.
