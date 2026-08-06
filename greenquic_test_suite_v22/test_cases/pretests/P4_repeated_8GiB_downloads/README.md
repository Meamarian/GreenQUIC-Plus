# P4 — repeated 8 GiB downloads with real idle gaps

P4 compares OFF, BASIC and PLUS using a download workload that naturally
contains active and idle periods.

Each independent P4 workload uses:

- one `quicinteropserver` process on idex;
- one `quicinterop` process on tinyman;
- one QUIC connection;
- five sequential 8 GiB streams/downloads by default;
- four 5-second idle gaps by default;
- one continuous RAPL, board-power, frequency and C-state recording window.

The client and server processes are not restarted between the five downloads.
The DPDK datapath and QUIC connection remain alive during all four gaps.

The matrix repeats the complete workload five times for OFF, five times for
BASIC and five times for PLUS. Those independent repetitions are restarted on
purpose to provide separate statistical samples and to initialize each mode
cleanly.

## Primary comparison

The gaps are part of the workload. P4 therefore defaults to:

```bash
GQ_POST_TRANSFER_WAIT_S=0
```

The primary common metric is client whole-test RAPL because it is available in
OFF, BASIC and PLUS and covers exactly:

```text
startup + connection + five downloads + four configured gaps + teardown
```

BASIC/PLUS also report the first-RX-to-last-TX workload window, which naturally
contains the inter-download gaps. Strict OFF leaves that packet-window field as
`N/A` by design.

P4 reports both:

- aggregate goodput excluding the configured gaps;
- aggregate goodput including the configured gaps.

## Files installed beside P3

Copy this folder to both machines:

```text
greenquic_test_suite_v22/test_cases/pretests/P4_repeated_8GiB_downloads
```

## One-time client build on tinyman

Run:

```bash
cd /root/greenquic_snapshot/greenquic_test_suite_v22/test_cases/pretests/P4_repeated_8GiB_downloads
./build_p4_client.sh
```

This creates a separate source copy and binary:

```text
/root/greenquic_snapshot/msquic-p4-source
/root/greenquic_snapshot/msquic/build-greenquic-p4/bin/Release/quicinterop
```

It does not edit the main MsQuic source and does not overwrite the known-good
`build-greenquic` binary.

## Run the complete matrix from idex

After the one-time build, run only this command on idex:

```bash
cd /root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P4_repeated_8GiB_downloads
./run_matrix_from_idex.sh \
  --downloads 5 \
  --gap-seconds 5 \
  --runs 5 \
  --env ENABLE_RECORD=1 \
  --env GQ_LOG_LEVEL=0
```

The idex controller:

1. starts the local idex server;
2. waits until the DPDK server is ready;
3. starts the tinyman client over SSH;
4. prints TEST, MODE, DOWNLOAD, GAP and server GET progress live;
5. stops the server after the client completes;
6. repeats OFF, BASIC and PLUS;
7. creates full per-run and averaged tables.

No second manual server/client command is required.

## Switches

```text
--downloads N
--gap-seconds N
--runs N
--between-runs-seconds N
--client-host HOST
--client-dir PATH
--output-dir PATH
--env KEY=VALUE
```

Every repeated `--env KEY=VALUE` applies to every server and client workload.
For example:

```bash
./run_matrix_from_idex.sh \
  --downloads 3 \
  --gap-seconds 2.5 \
  --runs 2 \
  --env ENABLE_RECORD=0 \
  --env GQ_LOG_LEVEL=1
```

With `ENABLE_RECORD=0`, trace-dependent fields become `N/A`. Download counts,
timing and goodput remain available.

## Output

```text
matrix_results/<timestamp>/
├── client_rep01_off.log
├── client_rep01_basic.log
├── client_rep01_plus.log
├── server_rep01_off.log
├── ...
├── matrix_config.json
└── tables/
    ├── client_all_runs.csv
    ├── client_mode_averages.csv
    ├── client_key_comparison.md
    ├── server_all_runs.csv
    └── server_mode_averages.csv
```

The CSV tables include every `- Field: value` printed by the run summaries.
Missing fields are written as `N/A`. Numeric cells are averaged over the
configured independent repetitions. Compound numeric fields are averaged
component by component when their formats match.
