# P4 matrix V4 additions

V4 keeps the validated one-process, one-connection sequential download client.
It changes only the matrix controller and reporting.

## New behavior

- Every live server/client line receives an idex wall-clock timestamp and an
  elapsed timestamp.
- The default mode schedule is a reproducible randomized balanced schedule,
  not permanent `off,basic,plus` ordering.
- `--seed N` reproduces the exact schedule.
- Aligned RAPL snapshots are taken on both idex and tinyman around the same
  client-command window. These are the values used for server, client, and
  server+client totals.
- Existing detailed client/server reports remain available.
- Final CSV/Markdown tables include server, client, and combined energy and
  savings versus OFF, alongside goodput reduction.
- Final SVG charts are generated under `tables/charts/`.

## Recommended run

```bash
./run_matrix_from_idex.sh \
  --downloads 5 \
  --gap-seconds 5 \
  --runs 6 \
  --mode-order balanced \
  --seed 20260806 \
  --env ENABLE_RECORD=1 \
  --env GQ_LOG_LEVEL=0
```

Six repetitions use all six mode permutations once. Five repetitions are also
supported, but six gives complete position/carry-over balancing.

## Main final artifacts

```text
matrix_results/<timestamp>/tables/
├── combined_endpoint_all_runs.csv
├── combined_endpoint_mode_averages.csv
├── combined_endpoint_comparison.md
├── client_all_runs.csv
├── client_mode_averages.csv
├── server_all_runs.csv
├── server_mode_averages.csv
└── charts/
    ├── aligned_rapl_energy_by_endpoint.svg
    ├── aligned_average_power_by_endpoint.svg
    ├── goodput_by_mode.svg
    ├── combined_energy_saving_vs_goodput_cost.svg
    └── energy_saving_vs_off_by_endpoint.svg
```

The aligned RAPL window starts just before the remote client command and ends
immediately after it. The JSON files record endpoint start/end wall times and
the final table reports the observed start/end skew. A warning is printed when
that skew exceeds 250 ms.
