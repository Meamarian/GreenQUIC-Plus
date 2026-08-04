GreenQUIC V22 pretests
======================

P0_smoke_1MiB
  Purpose: prove that the V22 DPDK/MsQuic server on idex and client on tinyman
  start correctly and complete one QUIC download. The client stores the 1 MiB
  result and verifies both byte count and SHA-256. GreenQUIC mode is OFF.

P1_goodput_off_10GiB
  Purpose: high-goodput baseline with GreenQuicMode=off. Both GreenQUIC
  frequency scaling and GreenQUIC sleeping are explicitly disabled. One QUIC
  connection, one stream, one 10 GiB payload.

P2_goodput_basic_10GiB
  Purpose: identical 10 GiB workload with GreenQuicMode=basic. BASIC uses DPDK
  physical RX/TX pressure only; it enables both frequency scaling and the V22
  short-sleep path. It does not use ACK/CUBIC/application semantic hints.
  Defaults: GreenQuicEnableFreq=1, GreenQuicEnableSleep=1,
  GreenQuicIdleMode=short, ACK/Data/Max sleep = 1/2/2 us.

Goodput scope
-------------
Payload bits are divided by the client measurement interval. The interval
includes DPDK/MsQuic startup, handshake, transfer and shutdown. For 10 GiB the
startup fraction is normally small, but these remain pretests rather than the
final externally synchronized energy campaign.

Recommended order
-----------------
1. Deploy this same suite to /root/mohsen/greenquic_test_suite_v22 on idex and tinyman.
2. Run ./check_v22_install.sh on both hosts.
3. Run ./test_cases/pretests/prepare_10g_on_idex.sh on idex.
4. Run P0, then P1, then P2. Stop each matching server before starting the next.
5. Or run all three from idex with ./run_pretests_from_idex.sh.
