GreenQUIC / GreenQUIC+ final V21 test suite
===========================================

1. Put the built/patched repositories at:

       ./msquic
       ./dpdk

   or edit suite.env / export MSQUIC_DIR and DPDK_DIR.

2. Edit suite.env and set SERVER_DPDK_DEVICE and CLIENT_DPDK_DEVICE.

3. On the server machine, check only the server role:

       cd test_cases/core/T1_one_10GB_file
       ./server/run_preflight.sh

4. On the client machine, check only the client role:

       cd test_cases/core/T1_one_10GB_file
       ./client/run_preflight.sh

5. For authoritative energy results, use two physical hosts and verify package RAPL is readable on each. Run the matching mode:

       # server machine
       ./server/run.sh plus

       # client machine
       SERVER_HOST=<server-ip> ./client/run.sh plus

   common/bin/preflight.sh checks both roles and is mainly useful when both
   endpoint configurations are available on the same machine.

Stock quicinterop is sufficient for T1, T3, T0_1 and T8. The sequential and
parallel-connection families require a greenquic_test_client that keeps one
MsQuic/DPDK process alive; the suite auto-discovers that binary when present.

All 22 previous testcase folders are preserved. Eleven V21 selectable-idle cases are added under test_cases/v21_idle_modes/.

Every testcase folder contains independent server/ and client/ subfolders.
Each role has a visible dpdk.ini for topology/roles, a separate powermng.ini
for the complete final V21 policy, an MsQuic execution-config explanation,
a launcher and a role-specific preflight script. TEST_CASE.txt and TOPOLOGY.env
state the exact file requests, connection/stream/flow counts, configured workers,
partitions, MsQuic worker CPUs and DPDK lcores. Runtime copies are refreshed from
suite.env and config.env before each run. Payloads and certificates are shared
under common/ and are not duplicated.




V21 selectable-idle diagnostics
--------------------------------
The dedicated cases preserve useful work while deliberately lowering empty-poll
thresholds and enabling decision logging so the selected mechanism is observable.
They are diagnostics first; repeat representative cases with logging disabled for
final energy comparisons.

    T10  short bounded rte_delay_us_sleep evidence
    T11  bounded rte_power_pause short tier
    T12  300-us requested pause tier on an RX-only lcore
    T13  RX-only PMD descriptor monitor and watchdog timeout
    T14  monitor role mismatch with safe short fallback
    T15  epoll/eventfd watchdog timeout
    T16  epoll wake by TX publication/eventfd
    T17  auto: monitor on RX-only, epoll on TX-only
    T18  idle mode off with DVFS still active
    T19  ACK hint vetoes optimized pause
    T20  CUBIC recovery hint vetoes work-triggered waiting

Run a dedicated case exactly as documented, for example:

    cd test_cases/v21_idle_modes/T16_epoll_tx_eventfd_wakeup
    ./server/run_preflight.sh
    ./server/run.sh plus

On the client host:

    SERVER_HOST=<server-ip> ./client/run_preflight.sh
    SERVER_HOST=<server-ip> ./client/run.sh plus

Each dedicated run validates V21 log fields and mode-specific evidence. A transfer
that completes but never increments the required pause/monitor/epoll counter fails.
Use run_idle_matrix.sh inside a V21 case for exploratory comparisons; it disables
the fixed evidence gate because a case written for one mechanism cannot require the
same counters from every other mechanism.

Hardware gates:
* T11/T12/T19 require DPDK power-pause support.
* T13/T17 require CPU power-monitor and PMD monitor-address support.
* T15/T16/T17/T20 require a PMD RX interrupt fd and enable/disable support.
* T16/T17/T19 require INPROCESS_CLIENT_BIN.
* T20 requires externally configured and independently verified packet loss.


Review-fixed V18.1 notes
------------------------
* All launchers are executable after extraction; the architecture-specific gap helper is built locally during preflight.
* Static testcase INI files are no longer overwritten by preflight or execution; only runtime/ is materialized.
* With two T4 DPDK lcores, GreenQuicTxOwnerAlsoRx=1 keeps two RX/RSS queues while preserving one TX-ring consumer.
* See REVIEW_FIXES.txt for corrected defects and remaining methodological limits.

Important limitations
---------------------
* No sudo is used. Bind the NIC and configure hugepages separately.
* Automatic discovery finds libraries; it cannot repair an ABI mismatch.
* T2/T4/T5/T6/T7/T9 require one in-process client for valid two-sided DPDK energy measurements; preflight now fails when it is missing.
* --approximate is server-side orchestration only; it is not valid client-side idle/DVFS data.
* RSS flow-to-queue placement is not deterministic with the stock client because
  source ports are random. Record the observed queue mapping.
* The 10 GiB source is opt-in. Create it with common/bin/prepare_assets.py --common common --create-10g. It is sparse where the filesystem supports sparse files.
* Client download filenames are symlinks to /dev/null to avoid duplicate storage. The stock-client path verifies completion messages, not payload hashes; use an in-memory checksum in the custom client for end-to-end content proof.
* Package RAPL is required by default. Set GQ_REQUIRE_RAPL=0 only for a non-energy dry run.
* Persistent server RAPL spans startup, waiting and time until Ctrl+C. Do not compare it as transfer energy without an external synchronized start/stop protocol.
* run_local.sh puts both endpoints on one package, so its overlapping RAPL values are not independent endpoint energy.
* T8 does not configure loss automatically. Set GQ_LOSS_INJECTION_CONFIRMED=1 only after external loss is active and verified.
* Logging should remain disabled for final energy measurements. Use a separate logging-enabled diagnostic run to validate T7/T9 hints and wake-up actions.


Final V21 configuration model
-----------------------------
* dpdk.ini contains only topology and execution settings: device, mode, profile,
  DPDK lcores, RX/TX ownership, MsQuic CPUs, and partition mapping.
* powermng.ini contains every pressure, four-signal EWMA, QUIC floor, hard-max,
  DVFS, empty-poll, sleep, and logging setting.
* The runner explicitly exports GREENQUIC_CONFIG and GREENQUIC_POWER_CONFIG.
* Every run validates both files and stores timestamped copies, SHA-256 hashes,
  the actual workload executable hash, and the actually linked libmsquic hash when dynamically resolvable.
* Legacy GreenQuicEwmaRiseShift/GreenQuicEwmaFallShift are forbidden by the
  suite validator. The final suite always uses eight explicit alpha values.
* Diagnostic logs can be checked with:
      python3 common/bin/validate_v21_log.py <log> --require-all

Configuration changes do not require recompilation, but each affected client or
server process must be restarted because both INI files are read at startup.

RAW-DPDK ADDRESSING UPDATE
--------------------------
This package generates LocalIp, PeerMac, and DpdkInitArgs in runtime dpdk.ini.
Set SERVER_LOCAL_IP, CLIENT_LOCAL_IP, SERVER_LOCAL_MAC, CLIENT_LOCAL_MAC,
SERVER_PEER_MAC, and CLIENT_PEER_MAC in suite.env before running preflight.
Peer MAC values must be crossed between tinyman and idex.
