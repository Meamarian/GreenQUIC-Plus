#!/usr/bin/env python3
"""Build-time-only P5 DPDK tuning.

This transformer deliberately changes only existing DPDK default constants in the
isolated P5 source copy. It adds no runtime branches, counters, retries, checksum
logic, locks, or GreenQUIC policy changes to the datapath hot path.

The native profile must not invoke this file at all; build_p5_client.sh preserves
the exact known-good d699f06 P5 build path for that case.
"""

from pathlib import Path
import re
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: apply_p5_static_performance.py PROFILE datapath_raw_dpdk_linux.c")

profile = sys.argv[1].strip().lower()
path = Path(sys.argv[2])

PROFILES = {
    "burst64": {"rx_burst": 64, "tx_burst": 64},
    "rx64": {"rx_burst": 64},
    "tx64": {"tx_burst": 64},
    "burst128": {"rx_burst": 128, "tx_burst": 128},
    "cache128": {"mbuf_cache": 128},
    "cache512": {"mbuf_cache": 512},
    "desc2048": {"rx_desc": 2048, "tx_desc": 2048},
    "ring2048": {"tx_ring": 2048},
    "ring8192": {"tx_ring": 8192},
    "pool8191": {"rx_pool": 8191, "tx_pool": 8191},
}

if profile not in PROFILES:
    raise SystemExit(
        "ERROR: unknown P5 static performance profile %r; choose one of: %s"
        % (profile, ", ".join(sorted(PROFILES)))
    )

cfg = {
    "mbuf_cache": 256,
    "rx_desc": 4096,
    "tx_desc": 4096,
    "rx_pool": 16383,
    "tx_pool": 16383,
    "rx_burst": 32,
    "tx_burst": 32,
    "tx_ring": 4096,
}
cfg.update(PROFILES[profile])

if cfg["rx_burst"] not in (32, 64, 128) or cfg["tx_burst"] not in (32, 64, 128):
    raise SystemExit("ERROR: unsupported burst size")
if cfg["mbuf_cache"] not in (128, 256, 512):
    raise SystemExit("ERROR: unsupported mbuf cache")
if cfg["rx_desc"] not in (2048, 4096) or cfg["tx_desc"] not in (2048, 4096):
    raise SystemExit("ERROR: unsupported descriptor count")
if cfg["rx_pool"] not in (8191, 16383) or cfg["tx_pool"] not in (8191, 16383):
    raise SystemExit("ERROR: unsupported mbuf pool size")
if cfg["tx_ring"] not in (2048, 4096, 8192):
    raise SystemExit("ERROR: unsupported TX ring size")

text = path.read_text(encoding="utf-8")

replacements = {
    "DEFAULT_MBUF_CACHE_SIZE": cfg["mbuf_cache"],
    "DEFAULT_NUM_RX_DESCRIPTORS": cfg["rx_desc"],
    "DEFAULT_NUM_TX_DESCRIPTORS": cfg["tx_desc"],
    "DEFAULT_RX_MBUF_POOL_SIZE": cfg["rx_pool"],
    "DEFAULT_TX_MBUF_POOL_SIZE": cfg["tx_pool"],
    "DEFAULT_RX_BURST_SIZE": cfg["rx_burst"],
    "DEFAULT_TX_BURST_SIZE": cfg["tx_burst"],
    "DEFAULT_TX_RING_SIZE": cfg["tx_ring"],
}

for macro, value in replacements.items():
    pattern = rf"(?m)^#define\s+{re.escape(macro)}\s+.*$"
    matches = re.findall(pattern, text)
    if len(matches) != 1:
        raise SystemExit(f"ERROR: expected exactly one {macro}, found {len(matches)}")
    text = re.sub(pattern, f"#define {macro:<28} {value}", text, count=1)

marker = (
    f"/* GREENQUIC-P5-STATIC-PERF-V2 profile={profile} "
    f"cache={cfg['mbuf_cache']} rxd={cfg['rx_desc']} txd={cfg['tx_desc']} "
    f"rxpool={cfg['rx_pool']} txpool={cfg['tx_pool']} "
    f"rxb={cfg['rx_burst']} txb={cfg['tx_burst']} ring={cfg['tx_ring']} */\n"
)
text = marker + text
path.write_text(text, encoding="utf-8")

print(
    "P5 static performance profile: "
    f"name={profile} cache={cfg['mbuf_cache']} "
    f"rxd={cfg['rx_desc']} txd={cfg['tx_desc']} "
    f"rxpool={cfg['rx_pool']} txpool={cfg['tx_pool']} "
    f"rxb={cfg['rx_burst']} txb={cfg['tx_burst']} ring={cfg['tx_ring']}"
)
