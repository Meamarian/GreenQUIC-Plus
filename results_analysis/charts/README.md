# Paper charts and chart-generation artifact

This directory is the home for the **actual chart artifact supplied for the GreenQUIC+ paper analysis**, not only a prose summary.

After importing `Charts (2).zip`, the directory contains:

```text
results_analysis/charts/
├── README.md
├── SOURCE_REFERENCE.txt
├── chart_v2.py
├── manifest.json
└── svg/
    ├── timeseries/
    │   ├── 23_server_cpu_pkg_dram_power_over_time.svg
    │   ├── 24_client_cpu_pkg_dram_power_over_time.svg
    │   └── 25_combined_cpu_pkg_dram_power_over_time.svg
    ├── with_values/
    │   └── 19 SVG paper-analysis charts
    └── without_values/
        └── 19 SVG paper-analysis charts
```

`SOURCE_REFERENCE.txt` is the original file from the supplied ZIP. It records which result archives/files were used to produce each chart. `chart_v2.py` is the original chart-generation script from the supplied artifact. The SVG files are retained byte-for-byte. macOS `.DS_Store` metadata is intentionally excluded.

The exact expected byte sizes and SHA-256 hashes for every source artifact are stored in:

```text
results_analysis/artifact_files.sha256.json
```

To import or verify the original ZIP contents from a local clone, use:

```bash
python3 results_analysis/import_attached_artifacts.py \
  --charts-zip "$HOME/Downloads/Charts (2).zip" \
  --tuning-zip "$HOME/Downloads/Tunning.zip"
```

To import, commit, and push the exact files to `main` in one step, first make sure the worktree is clean and then add `--commit --push`.

## Provenance versus final configuration

Some source names in `SOURCE_REFERENCE.txt` refer to earlier result archives, including an earlier P7 6×6 archive. That provenance is intentionally preserved because it describes the supplied chart bundle. It must not be used to redefine the final experiment configuration.

The authoritative final **6×5** paper-evaluation settings are in:

```text
results_analysis/configuration/p5_paper_evaluation.json
results_analysis/configuration/p7_paper_evaluation.json
```
