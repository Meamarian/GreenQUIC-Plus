# P6 — CUBIC CWND-blocked + recovery

P6 is an isolated extension of P5. P5 and `common/` are not modified.

Purpose: produce real CUBIC congestion-control pressure during a completed large download so GreenQUIC+ can exercise `CUBIC_CWND_BLOCKED` and `CUBIC_RECOVERY` hints while OFF/BASIC/PLUS all experience the same network impairment.

Default experimental workload:

- 5 sequential 16 GiB downloads in one QUIC connection
- 5 s inter-download gaps
- Normal GreenQUIC thresholds
- EPOLL with SHORT fallback
- deterministic server-download TX loss after handshake protection
- default run launcher: drop every 100,000 eligible server TX mbufs after the first 10,000

The loss injector is P6-only and is applied to `msquic-p6-source/src/platform/datapath_raw_dpdk.c` at build time. It drops at the final raw-DPDK TX boundary, after MsQuic has accounted the packet as sent, so normal QUIC loss detection and CUBIC recovery handle the loss.

Build:

```bash
cd /root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P6_cubic_block_recovery
chmod +x build_p6_client.sh run_p6_matrix.sh
./build_p6_client.sh
```

Run from idex after the same P6 build exists on tinyman:

```bash
cd /root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P6_cubic_block_recovery
./run_p6_matrix.sh
```

Tune loss without rebuilding by appending an overriding env option, for example `--env GQ_P6_DROP_EVERY_N=50000`. Set it to `0` for a no-loss P6 control.
