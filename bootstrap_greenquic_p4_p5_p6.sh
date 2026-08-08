#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE="$ROOT/bootstrap_greenquic_p4_p5.sh"
P6="$ROOT/greenquic_test_suite_v22/test_cases/pretests/P6_cubic_block_recovery"
BUILD="$ROOT/msquic/build-greenquic-p6"
SOURCE="$ROOT/msquic-p6-source"
CLIENT="$BUILD/bin/Release/quicinterop"
SERVER="$BUILD/bin/Release/quicinteropserver"

[[ -x "$BASE" ]] || { echo "ERROR: missing P4/P5 bootstrap: $BASE" >&2; exit 1; }
[[ -f "$P6/build_p6_client.sh" ]] || { echo "ERROR: missing P6 build script" >&2; exit 1; }

"$BASE" "$@"

printf '\n============================================================\n'
printf ' BUILD ISOLATED P6: CUBIC BLOCK + RECOVERY\n'
printf '============================================================\n\n'
chmod 0755 "$P6/build_p6_client.sh" "$P6/run_p6_matrix.sh"
"$P6/build_p6_client.sh"

[[ -d "$SOURCE" ]] || { echo "ERROR: P6 isolated source missing" >&2; exit 1; }
[[ -x "$CLIENT" && -x "$SERVER" ]] || { echo "ERROR: P6 binaries missing" >&2; exit 1; }
grep -Fq -- 'GREENQUIC-P6-DETERMINISTIC-LOSS-V2' "$SOURCE/src/platform/datapath_raw_dpdk_linux.c"
grep -aFq -- 'GREENQUIC-P6-DETERMINISTIC-LOSS-V2' "$CLIENT"
grep -aFq -- 'GREENQUIC-P6-DETERMINISTIC-LOSS-V2' "$SERVER"
grep -aFq -- 'hint_cubic_cwnd_blocked=' "$SERVER"
grep -aFq -- 'hint_cubic_recovery=' "$SERVER"
grep -aFq -- 'GreenQUIC-P5-SEQUENCE-V2' "$CLIENT"

printf '\nP6 client: %s\n' "$(readlink -f "$CLIENT")"
sha256sum "$CLIENT"
printf 'P6 server: %s\n' "$(readlink -f "$SERVER")"
sha256sum "$SERVER"
printf '\nGREENQUIC FULL BOOTSTRAP: NORMAL + P4 + P5 + P6 READY\n'
