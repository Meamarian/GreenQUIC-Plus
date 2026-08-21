#!/usr/bin/env python3
"""Static preflight for the final GreenQUIC+ paper evaluation.

RUN ON: control host, from any GreenQUIC-Plus clone.

This does not contact the experiment nodes. It verifies that the machine-readable
paper configuration, dependency/source versions, authoritative launcher,
compatibility wrappers, durable recorder validation, automatic result-copy path,
role-based runtime defaults, P7 network tuning, and setup interface still agree
on the critical settings.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
P5_JSON = ROOT / "results_analysis/configuration/p5_paper_evaluation.json"
P7_JSON = ROOT / "results_analysis/configuration/p7_paper_evaluation.json"
DEPS_JSON = ROOT / "results_analysis/configuration/dependencies.json"
MSQUIC_CMAKE = ROOT / "msquic/CMakeLists.txt"
DPDK_VERSION = ROOT / "msquic/deps/dpdk/VERSION"
SUITE_ENV = ROOT / "greenquic_test_suite_v22/suite.env"
P5_DIR = ROOT / "greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
FINAL = P5_DIR / "mac_run_p5_p7_fair_repro_6x5.sh"
V2 = P5_DIR / "mac_run_p5_p7_fair_repro_6x5_v2.sh"
V3 = P5_DIR / "mac_run_p5_p7_fair_repro_6x5_v3.sh"
P5_RECORDER_VALIDATOR = P5_DIR / "validate_p5_recorder_evidence.py"
P7_DIR = ROOT / "greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline"
P7_TUNER = P7_DIR / "p7_network_tuning.sh"
TUM_SETUP = ROOT / "tum_testbed_setup/greenquic_fresh_setup.sh"
DOWNLOADER = ROOT / "results_analysis/download_latest_reproduction.sh"
RUN_WRAPPER = ROOT / "results_analysis/run_paper_evaluation.sh"


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
    return json.loads(path.read_text(encoding="utf-8"))


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
        deps = load_json(DEPS_JSON)

        # Source/dependency anchors. These are repository-backed versions; Debian
        # package patch versions remain intentionally runtime-resolved from Trixie.
        require_equal(deps["source_pinned"]["msquic"]["version"], "2.4.8", "dependency MsQuic version")
        require_equal(deps["source_pinned"]["dpdk"]["version"], "21.11.9", "dependency DPDK version")
        require_equal(deps["source_pinned"]["cmake_minimum_for_current_static_msquic_build"], "3.20", "dependency CMake minimum")
        require_equal(deps["source_pinned"]["tls_backend"], "OpenSSL", "dependency TLS backend")
        require_equal(deps["operating_system"]["required_distribution"], "Debian", "dependency OS")
        require_equal(deps["operating_system"]["required_codename"], "trixie", "dependency OS codename")
        require_equal(DPDK_VERSION.read_text(encoding="utf-8").strip(), "21.11.9", "vendored DPDK VERSION")
        msquic_cmake = require_tokens(MSQUIC_CMAKE, [
            "set(QUIC_FULL_VERSION 2.4.8)",
            "cmake_minimum_required(VERSION 3.20)",
        ], "MsQuic CMake version anchors")
        require("set(QUIC_FULL_VERSION 2.4.8)" in msquic_cmake, "MsQuic version anchor changed")

        w5 = p5["workload"]
        for key, expected in {
            "runs": 6,
            "downloads_per_run": 5,
            "payload_bytes_per_download": 8589934592,
            "gap_seconds": 5,
            "server_cooldown_seconds": 5,
            "between_tests_seconds": 5,
            "mode_order": "balanced",
            "seed": 20260806,
            "execution_profile": "max_throughput",
        }.items():
            require_equal(w5[key], expected, f"P5 {key}")

        topo = p5["endpoint_topology"]
        require_equal(topo["enable_multicore"], False, "P5 multicore")
        for side in ("server", "client"):
            require_equal(topo[side]["dpdk_lcores"], [19], f"P5 {side} DPDK lcores")
            require_equal(topo[side]["tx_owner_lcore"], 19, f"P5 {side} TX owner")
            require_equal(topo[side]["quic_worker_cpus"], [21, 22, 23, 24], f"P5 {side} QUIC CPUs")

        marker = "GREENQUIC-P5-PERFORMANCE2-V2 txalloc=8 txenqcounter=0 txmetazero=1 rxpipe=2 shardmask=0"
        require_equal(p5["datapath_build"]["binary_marker"], marker, "P5 binary marker")
        p2 = p5["datapath_build"]["performance2_v2"]
        require_equal(p2["tx_alloc_batch"], 8, "P5 txalloc")
        require_equal(p2["tx_enqueue_counter"], False, "P5 tx enqueue counter")
        require_equal(p2["full_safe_tx_metadata_zeroing"], True, "P5 TX metadata zeroing")
        require_equal(p2["rx_pipeline_prefetch_distance"], 2, "P5 RX prefetch")
        require_equal(p2["sharded_active_mask"], False, "P5 shard mask")

        overrides = p5["selected_power_policy"]["explicit_overrides"]
        require_equal(overrides, {
            "PRESSURE_UP": 450,
            "RX_QUEUE_HIGH": 48,
            "ACTIVE_TRANSFER_SLEEP_MIN_LEVEL": 16,
        }, "P5 TOP3 overrides")
        effective = p5["selected_power_policy"]["effective_parameters"]
        for key, expected in {
            "FREQ_PERIOD_US": 10000,
            "PRESSURE_UP": 450,
            "RX_QUEUE_HIGH": 48,
            "ACTIVE_TRANSFER_SLEEP_MIN_LEVEL": 16,
        }.items():
            require_equal(effective[key], expected, f"P5 effective {key}")
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

        # Runtime role guards must not silently force the paper hostnames.
        suite_text = require_tokens(SUITE_ENV, [
            'GQ_LOCAL_SHORT_HOST=',
            'SERVER_NAME="${SERVER_NAME:-$GQ_LOCAL_SHORT_HOST}"',
            'CLIENT_NAME="${CLIENT_NAME:-$GQ_LOCAL_SHORT_HOST}"',
        ], "role-based suite.env")
        require('SERVER_NAME="${SERVER_NAME:-idex}"' not in suite_text,
                "suite.env still hard-codes idex as SERVER hostname")
        require('CLIENT_NAME="${CLIENT_NAME:-tinyman}"' not in suite_text,
                "suite.env still hard-codes tinyman as CLIENT hostname")

        # Durable P5 recorder validation. The 2026-08-21 failure was caused by
        # requiring *_affinity.txt sidecars after bundling although the durable
        # run logs already contained the actual recorder CPU. Prevent regression.
        require_tokens(P5_RECORDER_VALIDATOR, [
            'matrix_integrity.json',
            'whole-system power1 trace',
            'C RAPL powercap trace',
            'Linux cpu_idle trace',
            'CPU-frequency trace',
            'affinity_sidecars_required',
            'P5 RECORDER EVIDENCE VALIDATION: PASS',
        ], "P5 durable recorder validator")

        final_text = require_tokens(FINAL, [
            'BRANCH=main',
            '--server-host',
            '--client-host',
            '--bastion',
            '--ssh-key',
            '--download-dest',
            '--no-auto-download',
            'AUTO_DOWNLOAD=',
            "git fetch origin '+refs/heads/main:refs/remotes/origin/main'",
            '--env PRESSURE_UP=450',
            '--env RX_QUEUE_HIGH=48',
            '--env ACTIVE_TRANSFER_SLEEP_MIN_LEVEL=16',
            '--env FREQ_PERIOD_US=10000',
            '--env GQ_IDLE_MODE_OVERRIDE=monitor',
            '--env GQ_IDLE_FALLBACK_OVERRIDE=short',
            '--env GQ_ENABLE_ACPI_POWER_TRACE=1',
            '--env GQ_ENABLE_MSR_TRACE=1',
            '--env GQ_ENABLE_FREQ_TRACE=1',
            'validate_p5_recorder_evidence.py',
            'P5_recorder_validation=durable_per_run_log_evidence',
            'RESULT_DIRS.env',
            'RESULT_ZIPS.sha256',
            'FINAL REMOTE RESULT PATHS (before archive/SCP)',
            'download_latest_reproduction.sh',
            '--expect-runs',
            '--expect-downloads',
            'P5_power_profile=TOP3',
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
            'server_role_host=',
            'client_role_host=',
        ], "authoritative final launcher")
        require("p5_affinity_files.txt" not in final_text,
                "obsolete P5 affinity-sidecar validation was reintroduced")
        require("find \"$P5OUT/runs\" -type f -name '*_affinity.txt'" not in final_text,
                "obsolete P5 *_affinity.txt requirement was reintroduced")

        require_tokens(DOWNLOADER, [
            'FINAL RESULT PATHS — BEFORE SCP',
            'REMOTE RESULT PATHS:',
            'REMOTE ZIP PATHS:',
            'LOCAL FINAL RESULT DIRECTORY:',
            'STARTING AUTOMATIC SCP...',
            'RESULT_ZIPS.sha256',
            'P5_recorder_validation=durable_per_run_log_evidence',
            '--expect-runs',
            '--expect-downloads',
        ], "automatic result downloader")
        require_tokens(RUN_WRAPPER, [
            '--download-dest',
            '--no-auto-download',
            'AUTO_DOWNLOAD=',
            'run_paper_evaluation.sh',
        ], "high-level paper run wrapper")

        # Old names remain only as compatibility entrypoints, not separate logic.
        wrapper_token = 'exec bash "$HERE/mac_run_p5_p7_fair_repro_6x5.sh" "$@"'
        require_tokens(V2, [wrapper_token], "V2 compatibility wrapper")
        require_tokens(V3, [wrapper_token], "V3 compatibility wrapper")

        require_tokens(TUM_SETUP, [
            '--server-host',
            '--client-host',
            '--server-to-client-host',
            '--bastion',
            '--ssh-key',
            'SERVER -> CLIENT: required',
            "git fetch origin '+refs/heads/main:refs/remotes/origin/main'",
            'prepare_host "$SERVER_HOST"',
            'prepare_host "$CLIENT_HOST"',
            'build_paper_binaries "$SERVER_HOST"',
            'build_paper_binaries "$CLIENT_HOST"',
        ], "role-based TUM setup")

        require_tokens(P7_TUNER, [
            'p7_tune_set_offload "$iface" tso on 1',
            'p7_tune_set_offload "$iface" gso on 1',
            'p7_tune_set_offload "$iface" tx on 1',
            'p7_tune_set_offload "$iface" gro on 1',
        ], "P7 paper offload tuner")

        require(not (ROOT / "power_mng_tunning").exists(), "obsolete power_mng_tunning/ unexpectedly exists")
        require(not (ROOT / "greenquic_test_suite").exists(), "legacy greenquic_test_suite/ unexpectedly exists")

    except (CheckError, KeyError, TypeError, ValueError, json.JSONDecodeError, OSError) as exc:
        print(f"PAPER CONFIGURATION PREFLIGHT: FAIL\n{exc}", file=sys.stderr)
        return 1

    print("PAPER CONFIGURATION PREFLIGHT: PASS")
    print("Dependencies: modified MsQuic 2.4.8 source + DPDK 21.11.9 + Debian Trixie policy")
    print("P5: Performance2 V2 + TOP3, 6x5, CPU19 + QUIC CPUs21-24")
    print("P5 recorder validation: durable per-run log evidence; affinity sidecars not required")
    print("P7: isolated Linux paper profile, 6x5, CPU19 + QUIC CPUs21-24")
    print("Results: final paths printed before automatic SCP; ZIP SHA-256 verified")
    print("Hosts: role-based; paper defaults are server=idex, client=tinyman")
    print("Runtime hostname guards: portable; no idex/tinyman requirement")
    print("Launcher: mac_run_p5_p7_fair_repro_6x5.sh")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
