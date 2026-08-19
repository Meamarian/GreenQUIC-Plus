# Power-management tuning

This folder is the reproducibility record for the GreenQUIC P5 power-management sweep and the final focused tests.

## Files

- `power_mng_tunning.txt` — exact focused-test commands, common P5 arguments, the Mac full-run command, live monitor command, and the full power-management configuration table.
- `GreenQUIC_P5_50_Config_Sweep_Results_and_Parameters.xlsx` — reviewed workbook for all 50 sweep configurations, parameter defaults, measured outcomes, source anchors, final focused tests, and the complete baseline/focused power configuration.

## Final focused tests

| Test | Modes | Override/config | Matrix folder | Reason |
|---|---|---|---|---|
| T29 | OFF + BASIC + PLUS | RX_QUEUE_HIGH=48 | T29_<timestamp> | Best valid sweep mean |
| T41 | OFF + BASIC + PLUS | ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16 | T41_<timestamp> | Near-tied best; low variability |
| TOP3 | OFF + BASIC + PLUS | PRESSURE_UP=450; RX_QUEUE_HIGH=48; ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16 | TOP3_<timestamp> | Combination of T07 + T29 + T41 |
| P7 | Linux | Paper Linux P7 network/CPU settings | P7_<timestamp> | Linux baseline |

For every P5 focused test, OFF, BASIC, and PLUS use the same P5 datapath/test pipeline. OFF bypasses GreenQUIC policy, BASIC uses physical policy signals, and PLUS adds QUIC semantic hints. `ACTIVE_TRANSFER_SLEEP_MIN_LEVEL` is PLUS-only; `RX_QUEUE_HIGH` and `PRESSURE_UP` affect the physical policy used by BASIC and PLUS.

## Mac command: run all four again

```bash
cd ~/Downloads/GreenQUIC && \
git fetch origin performance2/p5-multicore && \
git checkout performance2/p5-multicore && \
git merge --ff-only origin/performance2/p5-multicore && \
bash greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_t29_t41_top3_p7_auto.sh
```

The full-run order is:

```text
T29 -> T41 -> TOP3 -> P7
```

### Live monitor from another Mac terminal

```bash
ssh idex '
log=$(find /root -maxdepth 1 -type f -name "T29_T41_TOP3_P7_*.log" -printf "%T@ %p\n" 2>/dev/null |
    sort -nr | sed -n "1p" | cut -d" " -f2-)
echo "FOLLOWING: $log"
echo
[ -n "$log" ] || { echo "No T29/T41/TOP3/P7 log found"; exit 1; }
tail -n +1 -F "$log"
'
```

`Ctrl+C` stops only the local monitor.

## 50-configuration sweep: top comparison

The sweep metric is mean active-download goodput across 5 independent P5 runs, with each run containing 5 sequential 8-GiB downloads and 5-second gaps. The gaps are excluded from the active-goodput metric.

| Test | Configuration | Status | Mean Gb/s | SD | CV % | Delta vs baseline |
|---|---|---|---|---|---|---|
| T01 | baseline | OK | 9.9981 | 0.1448 | 1.45 | +0.00% |
| T29 | rxQueueHigh48 | OK | 10.2730 | 0.1473 | 1.43 | +2.75% |
| T41 | activeSleep16 | OK | 10.2720 | 0.0718 | 0.70 | +2.74% |
| T07 | up450 | OK | 10.2546 | 0.0886 | 0.86 | +2.57% |
| T50 | allAggressive | OK | 10.2278 | 0.1223 | 1.20 | +2.30% |
| T18 | downPeriod20000 | OK | 10.2218 | 0.1949 | 1.91 | +2.24% |
| T06 | up500 | OK | 10.2052 | 0.1390 | 1.36 | +2.07% |
| T49 | strongBacklogIdle | OK | 10.2035 | 0.0800 | 0.78 | +2.05% |
| T30 | rxQueueHigh32 | OK | 10.2024 | 0.2161 | 2.12 | +2.04% |
| T19 | minIdle30ms | OK | 10.2009 | 0.1552 | 1.52 | +2.03% |
| T36 | fullBurst800 | OK | 10.2006 | 0.1955 | 1.92 | +2.03% |

Key observations:

- T29 (`RX_QUEUE_HIGH=48`) had the best valid mean: **10.2730 Gbit/s**, +2.75% versus baseline.
- T41 (`ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16`) was essentially tied at **10.2720 Gbit/s**, with CV 0.70%.
- T07 (`PRESSURE_UP=450`) reached **10.2546 Gbit/s**, +2.57%.
- T50 (`allAggressive`) did not beat the best single settings, so globally making every control more aggressive was not optimal.
- The strongest cases mainly improved startup/first-download behavior; later downloads were already near the high-throughput steady state.

## 50-configuration sweep: complete final table

| Test | Configuration | Status | Mean Gb/s | SD | CV % | Delta vs baseline |
|---|---|---|---|---|---|---|
| T01 | baseline | OK | 9.9981 | 0.1448 | 1.45 | +0.00% |
| T02 | max850 | OK | 10.0476 | 0.1217 | 1.21 | +0.49% |
| T03 | max800 | OK | 10.1251 | 0.1912 | 1.89 | +1.27% |
| T04 | max750 | OK | 10.0875 | 0.1140 | 1.13 | +0.89% |
| T05 | max700 | OK | 10.0766 | 0.2033 | 2.02 | +0.78% |
| T06 | up500 | OK | 10.2052 | 0.1390 | 1.36 | +2.07% |
| T07 | up450 | OK | 10.2546 | 0.0886 | 0.86 | +2.57% |
| T08 | up350 | OK | 10.0682 | 0.2097 | 2.08 | +0.70% |
| T09 | up250 | OK | 9.9638 | 0.1816 | 1.82 | -0.34% |
| T10 | keep200 | OK | 10.0899 | 0.2910 | 2.88 | +0.92% |
| T11 | keep150 | OK | 9.9935 | 0.1670 | 1.67 | -0.05% |
| T12 | keep100 | OK | 10.1595 | 0.0687 | 0.68 | +1.61% |
| T13 | upPeriod400 | OK | 10.0952 | 0.0814 | 0.81 | +0.97% |
| T14 | upPeriod250 | OK | 10.1300 | 0.2412 | 2.38 | +1.32% |
| T15 | upPeriod125 | OK | 10.0705 | 0.1552 | 1.54 | +0.72% |
| T16 | downPeriod7500 | OK | 10.0565 | 0.2127 | 2.12 | +0.58% |
| T17 | downPeriod10000 | OK | 10.0973 | 0.1425 | 1.41 | +0.99% |
| T18 | downPeriod20000 | OK | 10.2218 | 0.1949 | 1.91 | +2.24% |
| T19 | minIdle30ms | OK | 10.2009 | 0.1552 | 1.52 | +2.03% |
| T20 | minIdle50ms | OK | 10.0918 | 0.2066 | 2.05 | +0.94% |
| T21 | minIdle100ms | OK | 9.9856 | 0.2731 | 2.73 | -0.12% |
| T22 | burstRise625 | OK | 10.0255 | 0.1469 | 1.46 | +0.27% |
| T23 | burstRise750 | OK | 10.0818 | 0.2658 | 2.64 | +0.84% |
| T24 | burstRise1000 | OK | 10.1628 | 0.1749 | 1.72 | +1.65% |
| T25 | burstFall375 | FAIL | — | — | — | — |
| T26 | burstFall250 | OK | 10.0823 | 0.1888 | 1.87 | +0.84% |
| T27 | burstFall125 | FAIL | — | — | — | — |
| T28 | backlogFall125 | OK | 10.1804 | 0.2288 | 2.25 | +1.82% |
| T29 | rxQueueHigh48 | OK | 10.2730 | 0.1473 | 1.43 | +2.75% |
| T30 | rxQueueHigh32 | OK | 10.2024 | 0.2161 | 2.12 | +2.04% |
| T31 | txRingHigh48 | FAIL | — | — | — | — |
| T32 | txRingHigh32 | OK | 10.1178 | 0.2311 | 2.28 | +1.20% |
| T33 | rxQueueSample32 | OK | 10.1185 | 0.1601 | 1.58 | +1.20% |
| T34 | rxQueueSample16 | OK | 10.0652 | 0.2160 | 2.15 | +0.67% |
| T35 | fullBurst600 | OK | 10.1671 | 0.0646 | 0.63 | +1.69% |
| T36 | fullBurst800 | OK | 10.2006 | 0.1955 | 1.92 | +2.03% |
| T37 | empty75k | OK | 10.1578 | 0.0724 | 0.71 | +1.60% |
| T38 | empty100k | FAIL | — | — | — | — |
| T39 | empty200k | OK | 9.9895 | 0.3000 | 3.00 | -0.09% |
| T40 | activeSleep8 | FAIL | — | — | — | — |
| T41 | activeSleep16 | OK | 10.2720 | 0.0718 | 0.70 | +2.74% |
| T42 | sleepLevelsHigher | FAIL | — | — | — | — |
| T43 | zeroBoundedSleep | OK | 10.0238 | 0.1553 | 1.55 | +0.26% |
| T44 | ackAggressive | FAIL | — | — | — | — |
| T45 | cwndAggressive | FAIL | — | — | — | — |
| T46 | recoveryAggressive | OK | 10.1271 | 0.2566 | 2.53 | +1.29% |
| T47 | blockedAggressive | FAIL | — | — | — | — |
| T48 | previousStrong | OK | 10.1458 | 0.1873 | 1.85 | +1.48% |
| T49 | strongBacklogIdle | OK | 10.2035 | 0.0800 | 0.78 | +2.05% |
| T50 | allAggressive | OK | 10.2278 | 0.1223 | 1.20 | +2.30% |

Nine configurations are intentionally kept as `FAIL`: T25, T27, T31, T38, T40, T42, T44, T45, and T47. Their sweep repetitions were incomplete because of the later-identified client post-run SIGPIPE/bundling-path failure (`rc=141`), so no performance number is invented for them.

## Focused configuration comparison

| Parameter | Default/fair | T29 | T41 | TOP3 | Applies to |
|---|---|---|---|---|---|
| PRESSURE_UP | 600 | 600 | 600 | 450 | BASIC + PLUS |
| RX_QUEUE_HIGH | 64 | 48 | 64 | 48 | BASIC + PLUS |
| ACTIVE_TRANSFER_SLEEP_MIN_LEVEL | 4 | 4 | 16 | 16 | PLUS only |
| IDLE_MODE | epoll default; monitor in fair runs | monitor | monitor | monitor | BASIC + PLUS |
| IDLE_FALLBACK | short | short | short | short | BASIC + PLUS |

The complete power-manager table, including all physical, DVFS, EWMA, sleep, and QUIC-semantic parameters, is in `power_mng_tunning.txt` and in the workbook sheet `Full Power Config`.

## Current follow-up run history

- `T29_20260819_044527` completed all 18/18 OFF/BASIC/PLUS workloads and passed chart/workbook validation.
- A subsequent T41 attempt was interrupted after the first PLUS workload by loss of SSH reachability from IDEX to Tinyman (`No route to host`). That incomplete T41 attempt should not be treated as a complete 6-run result.
- The separate resume launcher `mac_resume_p5_top3_t41_p7_auto.sh` exists for continuing with TOP3 -> T41 -> P7 without rerunning the completed T29 matrix.

## Source anchors

- P5 defaults: `greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/config.env`
- P5 runtime mapping: `greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/gq_common_p5.sh`
- 50-case sweep definition: `greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/p5_plus_sweep50_5x5.py`
- Main policy implementation in the patched MsQuic tree: `src/platform/datapath_raw_dpdk.c`
- QUIC semantic hint sources: `src/core/ack_tracker.c`, `src/core/cubic.c`, and GreenQUIC+ support files.
