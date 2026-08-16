# P5 Performance2 runbook

For copy-paste operational commands (start, live status, build logs, active processes, completion markers, verified SCP, and safe stale-PID checks), see [`P5_COMMAND_GUIDE.md`](P5_COMMAND_GUIDE.md).

Use `mac_chain_p1_p2_latest.sh` for the Mac-side chain. It points to V4. Do not use V3 for new runs.

V4 fixes the failures seen during the 2026-08-16 run:

- excludes `SHA256SUMS.tmp` from generated manifests;
- uses a macOS-compatible timestamp for `SCP_DONE`;
- only selects prior export directories that contain `DONE`;
- keeps long remote stages detached from the Mac SSH session;
- keeps SHA256-verified `.part` SCP behavior;
- uses `run_p5_performance2_selected_profiles.sh` for a selected P2 configuration instead of misusing the one-run screening sweep for a 6-run final test;
- no longer silently assumes `sharded_udp4` is the best P2 configuration. `P5_P2_BEST_PROFILE` must be set explicitly after screening evidence is reviewed.

## Performance2 methodology

`run_p5_performance2_sweep.sh` is the broad screening sweep. The intended use is 1 repetition × 3 downloads for each candidate configuration.

For focused comparison of the configurations that remain meaningful on the current E810/PMD setup, use `mac_run_p2_idle_power_screen_v2.sh`. It wraps the original focused runner and adds explicit retry behavior for transient idex-to-tinyman bundle-copy failures. It tests exactly these six configurations:

- `baseline`
- `sharded_512`
- `sharded_1024`
- `sharded_2048`
- `rx_prefetch`
- `sharded_rxprefetch`

The focused screen runs only two external workload profiles first:

1. `idle_monitor_normal`: monitor idle mode, short fallback;
2. `power_friendly`: frequency scaling + sleep enabled, epoll idle mode, short fallback.

Its default is 1 repetition × 3 downloads per configuration/workload, `--chart-style both`, `GQ_LOG_LEVEL=0`, `ENABLE_RECORD=1`, and seed `20260806`. It writes `idle_power_summary.tsv` from the matrix all-runs tables using aggregate goodput excluding gaps. The Mac wrapper syncs the exact Performance2 branch SHA to both nodes, refuses to collide with a live P1/P2 chain, launches the remote test detached with `nohup`/`setsid`, and copies the result back with SHA256 verification.

After reviewing the focused screen, choose the best one or two candidates and validate them with `run_p5_performance2_selected_profiles.sh`. The default final validation is 6 repetitions × 5 downloads and runs the same three workload profiles as Performance1:

1. `idle_monitor_normal`: monitor idle mode, short fallback;
2. `power_friendly`: frequency scaling + sleep enabled, epoll idle mode, short fallback;
3. `normal_short_8GiB`: short idle mode and `/file_8G.bin`.

The selected-profile runner uses `--chart-style both`, `GQ_LOG_LEVEL=0`, `ENABLE_RECORD=1`, seed `20260806`, and writes a per-profile 6-run mean/standard-deviation summary from `tables/client_all_runs.csv`.

Do not rank a multi-run experiment from the legacy `goodput_summary.tsv` produced by the screening script: that file is based on the last matching run in the controller log, not the six-run mean. Use the matrix all-runs tables, `idle_power_summary.tsv`, or `selected_profiles_summary.tsv`.

## UDP segmentation capability

The Performance2 transform enables experimental UDP segmentation only if the PMD advertises UDP TSO, multi-segment TX, IPv4 checksum, and UDP checksum capability. Always inspect `[P5-PERF2-USO]` at runtime.

Run `summarize_p5_performance2_sweep.py <RESULT_ROOT>` after a broad screening sweep. It writes `effective_comparison.tsv` and `effective_ranking.tsv`. If USO was requested but inactive, the result is mapped to the configuration that actually ran, so an inactive UDP-seg row is not credited as a UDP-seg improvement.
