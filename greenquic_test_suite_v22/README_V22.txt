GreenQUIC test suite V22
========================

Target build
------------
  MsQuic repository: /root/mohsen/msquic
  GreenQUIC manifest: autopatcher version 22-private-split-linux-dpdk
  Active backend: src/platform/datapath_raw_dpdk_linux.c
  DPDK: 21.11.9
  Server host: idex
  Client host: tinyman
  Server binaries: build-greenquic/bin/Release/quicinteropserver
  Client binary: build-greenquic/bin/Release/quicinterop

What is included
----------------
  * All original core, recommended-extra and selectable-idle cases.
  * P0: verified 1 MiB client/server smoke download.
  * P1: one-connection, one-stream 10 GiB OFF goodput baseline.
  * P2: identical 10 GiB BASIC run with both DVFS and short sleep enabled.
  * Strict V22 source/build/runtime verification before every real run.
  * Strict validation of all 72 server/client static endpoint configurations.
  * idex/tinyman role protection and corrected V22 paths.

First commands on each host
---------------------------
  cd /root/mohsen/greenquic_test_suite_v22
  ./run_all_v22_static_checks.sh
  ./check_v22_install.sh

Automated pretests
------------------
Run on idex after passwordless SSH to root@tinyman works:

  cd /root/mohsen/greenquic_test_suite_v22
  ./run_pretests_from_idex.sh

Manual pretests
---------------
On idex:
  ./test_cases/pretests/prepare_10g_on_idex.sh
  ./test_cases/pretests/P0_smoke_1MiB/run_server.sh

On tinyman:
  ./test_cases/pretests/P0_smoke_1MiB/run_client.sh

Stop the idex server with Ctrl+C. Repeat with P1, then P2.

Important test semantics
------------------------
  OFF: policy returns before GreenQUIC DVFS and idle actions.
  BASIC: physical DPDK RX/TX pressure controls both DVFS and sleeping; semantic
         ACK/CUBIC/application hints are excluded.
  PLUS: BASIC physical policy plus partition-mapped semantic QUIC hints.

Cases requiring INPROCESS_CLIENT_BIN, external loss injection, hardware monitor,
epoll, or pause support remain guarded and fail or warn explicitly during
preflight rather than silently producing invalid results.
