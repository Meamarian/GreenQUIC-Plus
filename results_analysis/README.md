# GreenQUIC+ results, analysis, and paper reproduction

This directory is the evaluation/reproduction reference for **“Sleep Tight, QUIC Fast: Energy-Efficient QUIC with DPDK.”** It contains the final paper configuration, the original tuning workbooks and SVG/chart material, dependency/version records, result helpers, and the supported reproduction workflow.

---
# 1. Dependencies and versions

The dependency record distinguishes **source-pinned versions** from Debian packages whose exact package revisions are resolved at setup time.

## Software

| Component | Version | How it is fixed |
|---|---|---|
| Modified MsQuic source | `2.4.8` source version | vendored under `msquic/`; exact experiment source is the GreenQUIC+ Git commit SHA |
| DPDK | `21.11.9` | vendored under `msquic/deps/dpdk/` |
| CMake | `>= 3.20` for the current static MsQuic build | required by `msquic/CMakeLists.txt` when `QUIC_BUILD_SHARED=OFF` |
| TLS | OpenSSL | P5/P7 configure `QUIC_TLS=openssl` |
| Build type | Release | P5/P7 build scripts |

The MsQuic tree is **modified**, so stock upstream MsQuic 2.4.8 is not an equivalent source checkout. Reproducibility uses the exact GreenQUIC+ `main` SHA transferred to both endpoints.

## Endpoint OS and packages

The supported setup requires **Debian Trixie** on SERVER and CLIENT and verifies `ID=debian` and `VERSION_CODENAME=trixie` before provisioning. The setup installs the compiler/build/network/measurement packages listed in `configuration/dependencies.json`, including GCC/G++, CMake, Meson, Ninja, OpenSSL development headers, Python 3, NumPy, Matplotlib, `ethtool`, `msr-tools`, `lm-sensors`, and `irqbalance`.

Exact Debian package revisions and the kernel patch version are **not individually pinned by the current setup**. They come from the configured Debian Trixie repositories at setup time. Do not claim a package revision unless it was actually recorded from that run.

Paper hardware assumptions include the Intel E810 test NIC at PCI `0000:18:00.0`, Linux `ice` for link/P7 operation, `igb_uio` or `vfio-pci` for DPDK binding, `16384 × 2 MiB` hugepages on the test-NIC NUMA node, CPU19 for the DPDK/Linux dataplane side, and CPUs21-24 for MsQuic workers.

Machine-readable dependency policy:

```text
results_analysis/configuration/dependencies.json
```

After setup, **RUN ON: CONTROL HOST** to print the actual CONTROL/SERVER/CLIENT versions used by the current environment:

```bash
bash results_analysis/print_dependency_versions.sh
```
---

# 2. Original analysis artifacts

The supplied analysis files are committed in the private repository:

```text
results_analysis/
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

The chart set contains **SVG files**. `artifact_files.sha256.json` stores the expected sizes/SHA-256 hashes for the supplied workbook/chart artifacts. `SOURCE_REFERENCE.txt` intentionally preserves the original archive names, including earlier intermediate runs; those names are provenance, not the definition of the final 6×5 paper experiment.

---

# 3. Result locations and download

The SERVER role stores controller artifacts. For tag `<TAG>`:

```text
/root/GQ_FAIR_REPRO_<TAG>.log
/root/GQ_FAIR_REPRO_<TAG>/config.env
/root/GQ_FAIR_REPRO_<TAG>/RESULT_ZIPS.txt
/root/GQ_FAIR_REPRO_<TAG>/DONE
/root/GQ_FAIR_REPRO_<TAG>/FAILED

/root/P5_FAIR_OPT_PINNED_6r_5d_<TAG>.zip
/root/P7_FAIR_PAPER_PINNED_6r_5d_<TAG>.zip
```

`config.env` records the exact Git SHA, selected role endpoints, run shape, TOP3 values, and critical P7 settings.

