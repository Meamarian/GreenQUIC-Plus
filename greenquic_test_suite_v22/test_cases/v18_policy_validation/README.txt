Final V18 focused policy validation
===================================

Run normal diagnostic traffic with:
    GreenQuicLogLevel=2
    GreenQuicStatsPeriodUs=<nonzero>

Then validate and parse the resulting log:
    python3 common/bin/validate_v18_log.py <log> --require-all
    python3 common/bin/parse_v18_stats.py <log> --out <stats.csv>

Required behavioral checks
--------------------------
1. RX burst isolation:
   rxburstp/rxbursta rise while rxqueuep/rxqueuea remain low when no backlog exists.
2. RX queue persistence:
   rxqueuea remains elevated after rxbursta decays when descriptors remain queued.
3. TX burst isolation:
   txburstp/txbursta rise without forcing txringa when the software ring is empty.
4. TX ring persistence:
   txringa remains elevated after txbursta decays while backlog remains.
5. ACK floor isolation:
   txfloor raises txctrl; txbursta and txringa do not jump because of the hint.
6. Recovery:
   directional floor appears; hardmax requires the configured physical threshold.
7. Cwnd growth:
   no-work and work floors are selected according to physical TX evidence.
8. Direction ownership:
   unowned direction averages stay zero and do not block idle.
9. Final combination:
   control equals max of owned rxctrl and txctrl; it is not a sum or another EWMA.
10. Configuration precedence:
   a powermng.ini value overrides the same legacy value in dpdk.ini.
