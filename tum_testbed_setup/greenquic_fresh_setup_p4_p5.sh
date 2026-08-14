#!/usr/bin/env bash
set -Eeuo pipefail

# =============================================================================
# GreenQUIC TUM/LRZ fresh setup: normal + P4 + P5
# RUN THIS SCRIPT ON THE MAC.
# =============================================================================

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE="$HERE/greenquic_fresh_setup_base.sh"
BASTION="mohsen@coinbase"
ROOT="/root/mohsen"
P5_REL="greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
P5="$ROOT/$P5_REL"
P5_BUILD="$ROOT/msquic/build-greenquic-p5"
P5_SOURCE="$ROOT/msquic-p5