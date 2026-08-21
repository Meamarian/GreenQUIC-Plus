#!/usr/bin/env python3
"""Static preflight for the final GreenQUIC+ paper-evaluation configuration.

This does not contact the TUM testbed. It verifies that the machine-readable
configuration and the supported Mac launcher still agree on the critical
settings that define the final 6x5 paper evaluation.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
P5_JSON = ROOT / "results_analysis/configuration/p5_paper_evaluation.json"
P7_JSON = ROOT / "results_analysis/configuration/p7_paper_evaluation.json"
P5_DIR = ROOT / "greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
V3 = P5_DIR / "mac_run_p5_p7_fair_repro_6x5_v3.sh"
V2 = P5_DIR / "mac_run_p5_p7_fair_repro_6x5_v2.sh"
BASE = P5_DIR / "mac_run_p5_p7_fair_repro_6x5.sh"
P7_DIR = ROOT / "greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline"
P7_TUNER = P7_DIR / "p7_network_tuning.sh"
TUM_SETUP = ROOT / "tum_testbed_setup/greenquic_fresh_setup.sh"


class CheckError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise CheckError(message)


def require_equal(actual, expected, label: str) -> None:
    if actual != expected:
        raise CheckError(f"{label}: expected {expected!r}, found {actual!r}")


def load_json(path: Path):
    require(path.is_file(), f"missing JSON: {path.relative_to(ROOT)}")
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def require_tokens(path: Path, tokens: list[str], label: str) -> str:
    require(path.is_file(), f"missing {label}: {path.relative_to(ROOT)}")
    text = path.read_text(encoding="utf-8")
    for token in tokens:
        require(token in text, f"{label} missing required token: {token}")
    return text


def main() -> int:
    try:
        p5 = load_json(P5_JSON)
        p7 = load_json(P7_JSON)

        # Final P5 workload/topology.
        w5 = p5["workload"]
        require_equal(w5["runs"], 6, "P5 runs")
        require_equal(w5["downloads_per_run"], 5, "P5 downloads/run")
        require_equal(w5["payload_bytes_per_download"], 8589934592, "P5 payload bytes")
        require_equal(w5["gap_seconds"], 5, "P5 gap")
        require_equal(w5["server_cooldown_seconds"], 5, "P5 server cooldown")
        require_equal(w5["between_tests_seconds"], 5, "P5 between-tests")
        require_equal(w5["mode_order"], "balanced", "P5 mode order")
        require_equal(w5["seed"], 20260806, "P5 seed")
        require_equal(w5["execution_profile"], "max_throughput", "P5 execution profile")

        topo = p5["endpoint_topology"]
        require_equal(topo["enable_multicore"], False, "P5 multicore")
        for side in ("server", "client"):
            require_equal(topo[side]["dpdk_lcores"], [19], f"P5 {side} DPDK lcores")
            require_equal(topo[side]["tx_owner_lcore"], 19, f"P5 {side} TX owner")
            require_equal(topo[side]["quic_worker_cpus"], [21, 22, 23, 24], f"P5 {side} QUIC CPUs")

        marker = "GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0"
        require_equal(p5["datapath_build"]["binary_marker"], marker, "P5 binary marker")
        require_equal(p5["datapath_build"]["performance2_v2"]["tx_alloc_batch"], 8, "P5 txalloc")
        require_equal(p5["datapath_build"]["performance2_v2"]["tx_enqueue_counter"], False, "P5 tx enqueue counter")
        require_equal(p5["datapath_build"]["performance2_v2"]["full_safe_tx_metadata_zeroing"], True, "P5 TX metadata zeroing")
        require_equal(p5["datapath_build"]["performance2_v2"]["rx_pipeline_prefetch_distance"], 2, "P5 RX prefetch")
        require_equal(p5["datapath_build"]["performance2_v2"]["sharded_active_mask"], False, "P5 shard mask")

        overrides = p5["selected_power_policy"]["explicit_overrides"]
        require_equal(overrides, {
            "PRESSURE_UP": 450,
            "RX_QUEUE_HIGH": 48,
            "ACTIVE_TRANSFER_SLEEP_MIN_LEVEL": 16,
        }, "P5 TOP3 overrides")
        effective = p5["selected_power_policy"]["effective_parameters"]
        require_equal(effective["FREQ_PERIOD_US"], 10000, "P5 FREQ_PERIOD_US")
        require_equal(effective["PRESSURE_UP"], 450, "P5 pressure-up effective")
        require_equal(effective["RX_QUEUE_HIGH"], 48, "P5 RX queue high effective")
        require_equal(effective["ACTIVE_TRANSFER_SLEEP_MIN_LEVEL"], 16, "P5 active-transfer sleep level")
        require_equal(effective["IDLE_MODE"], "monitor (override)", "P5 idle mode")
        require_equal(effective["IDLE_FALLBACK"], "short (override)", "P5 idle fallback")

        runtime = p5["runtime_common"]
        for key, expected in {
            "GQ_ENABLE_ACPI_POWER_TRACE": 1,
            "GQ_POWER_SAMPLE_INTERVAL_MS": 1000,
            "GQ_ENABLE_MSR_TRACE": 1,
            "GQ_MSR_SAMPLE_INTERVAL_MS": 6,
            "GQ_MSR_SMOOTH_SAMPLES": 3,
            "ENABLE_CSTATE_RECORD": 1,
            "GQ_ENABLE_FREQ_TRACE": 1,
            "GQ_FREQ_SAMPLE_INTERVAL_MS": 1,
        }.items():
            require_equal(runtime[key], expected, f"P5 runtime {key}")

        # Final P7 workload/network/CPU settings.
        w7 = p7["workload"]
        for key, expected in {
            "runs": 6,
            "downloads_per_run": 5,
            "payload_bytes_per_download": 8589934592,
            "gap_seconds": 5,
            "pre_cooldown_seconds": 5,
            "post_cooldown_seconds": 5,
            "between_runs_seconds": 5,
        }.items():
            require_equal(w7[key], expected, f"P7 {key}")

        net = p7["network"]
        require_equal(net["mtu"], 1500, "P7 MTU")
        require_equal(net["combined_channels"], 1, "P7 combined channels")
        require_equal(net["disable_rps"], True, "P7 RPS")
        require_equal(net["disable_rdma_aux_for_test_nic"], True, "P7 RDMA aux")
        for key in ("net.core.rmem_default", "net.core.rmem_max", "net.core.wmem_default", "net.core.wmem_max"):
            require_equal(net["udp_socket_buffers_bytes"][key], 6815744, f"P7 {key}")
        require_equal(net["nic_offload_profile"]["requested"], "paper", "P7 offload profile")
        require_equal(net["nic_offload_profile"]["required_on"], ["tso", "gso", "tx-checksumming", "gro"], "P7 required offloads")

        cpu7 = p7["cpu_topology"]
        require_equal(cpu7["dataplane_cpu"], 19, "P7 dataplane CPU")
        require_equal(cpu7["quic_worker_cpus"], [21, 22, 23, 24], "P7 QUIC CPUs")
        require_equal(cpu7["pin_irq"], True, "P7 IRQ pinning")
        require_equal(cpu7["pin_quic"], True, "P7 QUIC pinning")
        require_equal(cpu7["stop_irqbalance"], True, "P7 irqbalance")
        require_equal(cpu7["record_quic_cpus"], False, "P7 QUIC CPU recording")

        # Supported launch path must explicitly inject the final settings.
        require_tokens(V2, [
            '--env PRESSURE_UP=450',
            '--env RX_QUEUE_HIGH=48',
            '--env ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16',
            '--env FREQ_PERIOD_US=10000',
            '--env GQ_IDLE_MODE_OVERRIDE=monitor',
            '--env GQ_IDLE_FALLBACK_OVERRIDE=short',
            '--env GQ_ENABLE_ACPI_POWER_TRACE=1',
            '--env GQ_ENABLE_MSR_TRACE=1',
            '--env GQ_ENABLE_FREQ_TRACE=1',
            'P5_power_profile=TOP3',
            'BRANCH="${GQ_FAIR_BRANCH:-main}"',
        ], "P5/P7 V2 transformer")

        require_tokens(V3, [
            'GQ_FAIR_BRANCH="${GQ_FAIR_BRANCH:-main}"',
            '--env PRESSURE_UP=450',
            '--env RX_QUEUE_HIGH=48',
            '--env ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16',
            'P5_power_profile=TOP3',
            'exec bash "$V2" "$@"',
        ], "supported V3 launcher")

        # Base runner carries the explicit P7 comparison settings that V2/V3 retain.
        require_tokens(BASE, [
            '--nic-offloads paper',
            '--udp-rmem 6815744',
            '--udp-wmem 6815744',
            '--combined-channels 1',
            '--disable-rps 1',
            '--disable-rdma 1',
            '--dataplane-cpu 19',
            '--quic-cpus 21,22,23,24',
            '--rapl-interval-ms 6',
            '--freq-interval-ms 1',
            '--mtu 1500',
        ], "base P7 paper runner")

        require_tokens(P7_TUNER, [
            'p7_tune_set_offload "$iface" tso on 1',
            'p7_tune_set_offload "$iface" gso on 1',
            'p7_tune_set_offload "$iface" tx on 1',
            'p7_tune_set_offload "$iface" gro on 1',
        ], "P7 paper offload tuner")

        require(TUM_SETUP.is_file(), "missing consolidated TUM setup script")
        require(not (ROOT / "power_mng_tunning").exists(), "obsolete power_mng_tunning/ unexpectedly exists")
        require(not (ROOT / "greenquic_test_suite").exists(), "legacy greenquic_test_suite/ unexpectedly exists")

    except (CheckError, KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
        print(f"PAPER CONFIGURATION PREFLIGHT: FAIL\n{exc}", file=sys.stderr)
        return 1

    print("PAPER CONFIGURATION PREFLIGHT: PASS")
    print("P5: Performance2 V2 + TOP3, 6x5, CPU19 + QUIC CPUs21-24")
    print("P7: isolated Linux paper profile, 6x5, CPU19 + QUIC CPUs21-24")
    print("Launcher: mac_run_p5_p7_fair_repro_6x5_v3.sh")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
