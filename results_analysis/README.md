# GreenQUIC+ results, analysis, and paper reproduction

This directory is the evaluation reference for **“Sleep Tight, QUIC Fast: Energy-Efficient QUIC with DPDK.”** It contains the final paper configuration, supplied tuning workbooks and SVG/chart material, dependency/version records, high-level setup/run/download helpers, and the final repository audit.

# Dependencies

The exact modified source is fixed by the GreenQUIC+ Git SHA. The current tree records MsQuic source version `2.4.8` and vendored DPDK `21.11.9`. P5/P7 use OpenSSL and Release builds.

SERVER and CLIENT must run Debian Trixie. Exact Debian package revisions and the kernel patch level are resolved from the configured Trixie repositories at setup time and are not individually pinned.

Paper hardware assumptions include Intel E810 at PCI `0000:18:00.0`, Linux `ice` for link/P7 operation, `igb_uio` or `vfio-pci` for DPDK, `16384 × 2 MiB` hugepages, CPU19 for dataplane work, and CPUs21-24 for MsQuic workers.

# Original analysis artifacts

The private repository contains the supplied artifacts directly:

```text
results_analysis/
├── configuration/
├── tuning/
│   ├── GreenQUIC_DPDK_Path_Perf_Tunning_v2.xlsx
│   ├── GreenQUIC_Power_Mng_Tuning_v1.xlsx
│   ├── README.md
│   └── summary.json
├── charts/
│   ├── chart_v2.py
│   ├── SOURCE_REFERENCE.txt
│   ├── manifest.json
│   └── svg/
│       ├── timeseries/
│       ├── with_values/
│       └── without_values/
└── artifact_files.sha256.json
```

The expected supplied set is two XLSX workbooks, `chart_v2.py`, and 41 SVG files. `artifact_files.sha256.json` records expected sizes/SHA-256 values. `SOURCE_REFERENCE.txt` preserves original archive names as provenance and does not redefine the final 6×5 experiment.


# Final result paths

On SERVER, for tag `<TAG>`:

```text
/root/GQ_FAIR_REPRO_<TAG>.log
/root/GQ_FAIR_REPRO_<TAG>/config.env
/root/GQ_FAIR_REPRO_<TAG>/RESULT_DIRS.env
/root/GQ_FAIR_REPRO_<TAG>/RESULT_ZIPS.txt
/root/GQ_FAIR_REPRO_<TAG>/RESULT_ZIPS.sha256
/root/GQ_FAIR_REPRO_<TAG>/p5_recorder_evidence.json
/root/GQ_FAIR_REPRO_<TAG>/DONE
/root/GQ_FAIR_REPRO_<TAG>/FAILED

/root/P5_FAIR_OPT_PINNED_6r_5d_<TAG>.zip
/root/P7_FAIR_PAPER_PINNED_6r_5d_<TAG>.zip
```
