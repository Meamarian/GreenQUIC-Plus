# Results and analysis

This directory is the GreenQUIC+ paper-evaluation reference. It is deliberately separate from `tum_testbed_setup/`: TUM setup provisions fresh machines, while this directory records the **final experiment configuration, tuning decisions, chart provenance, and exact reproduction procedure** for our paper evaluation.

## Layout

| Directory / file | Contents |
|---|---|
| `configuration/` | Exact final P5 OFF/BASIC/PLUS and P7 Linux paper-evaluation configuration, in JSON plus a readable explanation. |
| `tuning/` | Power-management and DPDK-path tuning summaries reconstructed from the reviewed tuning workbooks. |
| `charts/` | Chart/source-provenance material corresponding to the attached chart bundle. |
| `verify_paper_configuration.py` | Static preflight that checks the JSON configuration against the supported paper launcher and critical P7 network settings. |
| `download_latest_reproduction.sh` | Downloads the latest completed P5/P7 reproduction package from IDEX and verifies its saved `config.env`. |

## Final paper comparison

The final P5 configuration is **TOP3** on the optimized Performance2 V2 datapath:

```text
PRESSURE_UP=450
RX_QUEUE_HIGH=48
ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16
FREQ_PERIOD_US=10000
GQ_IDLE_MODE_OVERRIDE=monitor
GQ_IDLE_FALLBACK_OVERRIDE=short
```

The final datapath marker is:

```text
GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0
```

P5 OFF, BASIC and PLUS use that same datapath and the same 6-run × 5-download workload. OFF bypasses GreenQUIC policy actions, BASIC uses the physical DPDK policy, and PLUS uses the same physical policy plus QUIC semantic hints and PLUS-specific guards. `PRESSURE_UP=450` and `RX_QUEUE_HIGH=48` affect BASIC and PLUS; `ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16` is PLUS-only.

P7 is the isolated normal-Linux MsQuic baseline with CPU19 for IRQ/NAPI/softirq processing, MsQuic workers on CPUs21-24, IRQ and QUIC pinning enabled, RPS disabled, the test NIC's RDMA auxiliary child temporarily disabled, the paper GSO/GRO profile, 6,815,744-byte UDP receive/send buffers, one combined channel, MTU 1500, and the same 6 × 5 / 5-second-gap workload.

The authoritative machine-readable records are:

```text
results_analysis/configuration/p5_paper_evaluation.json
results_analysis/configuration/p7_paper_evaluation.json
```

## Reproduce the final paper evaluation

### 1. Update the private GreenQUIC+ repository on the Mac

```bash
cd ~/Downloads/GreenQUIC-Plus && \
git fetch origin main && \
git checkout main && \
git reset --hard origin/main
```

Expected repository/branch:

```text
git@github.com:Meamarian/GreenQUIC-Plus.git
main
```

### 2. Run the static paper-configuration preflight

This step does not contact IDEX or Tinyman. It checks that the JSON files, TOP3 injection, P5 datapath identity, P7 paper network settings, and supported launcher still agree.

```bash
cd ~/Downloads/GreenQUIC-Plus && \
python3 results_analysis/verify_paper_configuration.py
```

Expected final line:

```text
PAPER CONFIGURATION PREFLIGHT: PASS
```

Do not start a paper measurement if this check fails.

### 3. Fresh Debian only: prepare IDEX and Tinyman

If the hosts were reimaged, first install/reset **Debian Trixie** through the TUM/POS environment and wait until both machines are reachable. Then run the single supported setup entrypoint from the Mac:

```bash
cd ~/Downloads/GreenQUIC-Plus && \
git fetch origin main && \
git checkout main && \
git reset --hard origin/main && \
bash tum_testbed_setup/greenquic_fresh_setup.sh
```

Immediately monitor the setup from another Mac terminal:

```bash
while true; do
  clear
  date
  echo
  ssh -J mohsen@coinbase root@idex \
    'echo "===== IDEX ====="; hostname; git -C /root/mohsen branch --show-current 2>/dev/null || true; git -C /root/mohsen rev-parse --short HEAD 2>/dev/null || true'
  echo
  ssh -J mohsen@coinbase root@tinyman \
    'echo "===== TINYMAN ====="; hostname; git -C /root/mohsen branch --show-current 2>/dev/null || true; git -C /root/mohsen rev-parse --short HEAD 2>/dev/null || true'
  sleep 10
done
```

Successful provisioning ends with:

```text
GREENQUIC+ MAIN READY ON BOTH TUM NODES
```

The setup stage prepares the machines and builds the paper binaries. It does **not** define the TOP3 experiment configuration; the supported evaluation launcher below injects the final paper settings explicitly.

### 4. Launch the exact final 6 × 5 evaluation

From the Mac:

```bash
cd ~/Downloads/GreenQUIC-Plus && \
git fetch origin main && \
git checkout main && \
git reset --hard origin/main && \
python3 results_analysis/verify_paper_configuration.py && \
bash greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads/mac_run_p5_p7_fair_repro_6x5_v3.sh
```

Immediately monitor the run from another Mac terminal:

```bash
ssh idex '
log=$(find /root -maxdepth 1 -type f \
    -name "GQ_FAIR_REPRO_*.log" \
    -printf "%T@ %p\n" 2>/dev/null | \
    sort -nr | sed -n "1p" | cut -d" " -f2-)
echo "FOLLOWING: $log"
echo
if [ -z "$log" ]; then
    echo "No GQ_FAIR_REPRO log found yet"
else
    tail -n +1 -F "$log"
fi
'
```

The launcher prints `TAG`, exact Git `SHA`, and `REMOTE_LOG`. Prefer the exact `REMOTE_LOG` printed for that invocation when several runs exist.

The supported launcher synchronizes the exact `origin/main` commit to IDEX and Tinyman through a Git bundle, rebuilds/verifies the Performance2 V2 P5 binaries, rebuilds the isolated P7 Linux binaries, applies recorder-affinity isolation, runs P5 OFF/BASIC/PLUS with the exact TOP3 settings, then runs P7 with the exact Linux paper profile.

### 5. Check completion/status

From the Mac:

```bash
ssh idex '
art=$(find /root -maxdepth 1 -type d \
    -name "GQ_FAIR_REPRO_*" \
    -printf "%T@ %p\n" 2>/dev/null | \
    sort -nr | sed -n "1p" | cut -d" " -f2-)
echo "ARTIFACT_DIR=$art"
if [ -z "$art" ]; then
    echo "No fair-reproduction artifact directory found"
elif [ -f "$art/DONE" ]; then
    echo "DONE"
    cat "$art/config.env"
    echo
    cat "$art/RESULT_ZIPS.txt"
elif [ -f "$art/FAILED" ]; then
    echo "FAILED"
    cat "$art/FAILED"
else
    echo "RUNNING"
fi
'
```

A successful run must have `DONE`, `config.env`, and `RESULT_ZIPS.txt`. The generated `config.env` must identify `P5_power_profile=TOP3` and record the critical TOP3/DVFS/recorder settings.

### 6. Download and verify the completed result package

Use the repository helper instead of manually reconstructing remote paths:

```bash
cd ~/Downloads/GreenQUIC-Plus && \
bash results_analysis/download_latest_reproduction.sh
```

It downloads the latest completed reproduction into:

```text
reproduced_results/<TAG>/
```

including:

```text
config.env
RESULT_ZIPS.txt
DONE
P5_FAIR_OPT_PINNED_<...>.zip
P7_FAIR_PAPER_PINNED_<...>.zip
GQ_FAIR_REPRO_<TAG>.log    # when present at the expected sibling path
```

The helper refuses an unfinished latest run and checks the downloaded `config.env` for the final paper values. A successful download ends with:

```text
DOWNLOAD + PAPER CONFIG VERIFICATION: PASS
```

To choose another local destination root:

```bash
cd ~/Downloads/GreenQUIC-Plus && \
bash results_analysis/download_latest_reproduction.sh /path/to/output
```

### 7. Inspect the saved run identity

```bash
cd ~/Downloads/GreenQUIC-Plus && \
latest=$(find reproduced_results -mindepth 1 -maxdepth 1 -type d -print | sort | tail -1) && \
echo "RESULT_DIR=$latest" && \
grep -E '^(branch|commit|runs|downloads|P5_profile|P5_power_profile|P5_pressure_up|P5_rx_queue_high|P5_active_transfer_sleep_min_level|P5_freq_period_us|P7_profile|P7_nic_offloads|P7_udp_rmem|P7_udp_wmem|P7_combined_channels)=' "$latest/config.env"
```

For the default final paper run, the important values are:

```text
branch=main
runs=6
downloads=5
P5_profile=optimized_Performance2_V2_TOP3_idle_monitor_normal
P5_power_profile=TOP3
P5_pressure_up=450
P5_rx_queue_high=48
P5_active_transfer_sleep_min_level=16
P5_freq_period_us=10000
P7_profile=paper_linux
P7_nic_offloads=paper
P7_udp_rmem=6815744
P7_udp_wmem=6815744
P7_combined_channels=1
```

The `commit=` value is intentionally not hard-coded in this README; it must equal the exact `origin/main` SHA bundled by the launcher for that reproduction run.

## Provenance and analysis material

The chart bundle retains its original source names. Some chart references point to earlier result archives, including an earlier P7 6×6 archive. Those names are provenance for the attached charts and are not used to redefine the final experiment. The JSON files under `configuration/` and the supported 6×5 launcher above are the reference for the final paper evaluation.

The former top-level `power_mng_tunning/` directory is obsolete. Its useful tuning information is consolidated under `results_analysis/tuning/`, while the exact final evaluation settings are under `results_analysis/configuration/`.
