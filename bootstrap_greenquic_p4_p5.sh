#!/usr/bin/env bash
set -Eeuo pipefail

# Full GreenQUIC bootstrap for fresh hosts.
#
# This wrapper intentionally leaves the established bootstrap_greenquic.sh
# behavior unchanged. It first performs the normal GreenQUIC + isolated P4
# bootstrap, then recreates and builds the isolated P5 source/build trees from
# the committed repository source and verifies the last-successful P5 markers.
#
# Generated directories are intentionally NOT tracked in Git:
#   msquic-p5-source/
#   msquic/build-greenquic-p4/
#   msquic/build-greenquic-p5/

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE_BOOTSTRAP="$ROOT_DIR/bootstrap_greenquic.sh"
P5_DIR="$ROOT_DIR/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
P5_BUILD_SCRIPT="$P5_DIR/build_p5_client.sh"
P5_BUILD="$ROOT_DIR/msquic/build-greenquic-p5"
P5_SOURCE="$ROOT_DIR/msquic-p5-source"
P5_CLIENT="$P5_BUILD/bin/Release/quicinterop"
P5_SERVER="$P5_BUILD/bin/Release/quicinteropserver"
PLOTTER="$ROOT_DIR/greenquic_test_suite_v22/common/bin/plot_greenquic_counter_histograms.py"

[[ -x "$BASE_BOOTSTRAP" ]] || {
    echo "ERROR: missing executable base bootstrap: $BASE_BOOTSTRAP" >&2
    exit 1
}
[[ -f "$P5_BUILD_SCRIPT" ]] || {
    echo "ERROR: missing P5 build script: $P5_BUILD_SCRIPT" >&2
    exit 1
}

printf '\n============================================================\n'
printf ' GREENQUIC FULL BOOTSTRAP: NORMAL + P4 + P5\n'
printf '============================================================\n\n'

# Preserve every existing bootstrap option and behavior.
"$BASE_BOOTSTRAP" "$@"

printf '\n============================================================\n'
printf ' BUILD ISOLATED P5\n'
printf '============================================================\n\n'

chmod 0755 "$P5_BUILD_SCRIPT"
"$P5_BUILD_SCRIPT"

printf '\n============================================================\n'
printf ' VERIFY P5 LAST-SUCCESSFUL CODE + BINARIES\n'
printf '============================================================\n\n'

[[ -d "$P5_SOURCE" ]] || {
    echo "ERROR: P5 isolated source tree was not created: $P5_SOURCE" >&2
    exit 1
}
[[ -x "$P5_CLIENT" ]] || {
    echo "ERROR: P5 client binary missing: $P5_CLIENT" >&2
    exit 1
}
[[ -x "$P5_SERVER" ]] || {
    echo "ERROR: P5 server binary missing: $P5_SERVER" >&2
    exit 1
}

# Sequential single-connection P5 client + start gate.
grep -aFq -- 'GreenQUIC-P5-SEQUENCE-V2' "$P5_CLIENT" || {
    echo "ERROR: P5 client lacks GreenQUIC-P5-SEQUENCE-V2" >&2
    exit 1
}
grep -aFq -- 'ready_for_start_gate_us=' "$P5_CLIENT" || {
    echo "ERROR: P5 client lacks start-gate marker" >&2
    exit 1
}

# Final process-end telemetry used by the successful debug run.
grep -aFq -- 'GreenQUIC COUNTERS schema=greenquic-counters-v1' "$P5_CLIENT" || {
    echo "ERROR: P5 client lacks final GreenQUIC counter schema" >&2
    exit 1
}
grep -aFq -- 'GreenQUIC COUNTERS schema=greenquic-counters-v1' "$P5_SERVER" || {
    echo "ERROR: P5 server lacks final GreenQUIC counter schema" >&2
    exit 1
}

# Source-level fixes that must survive regeneration of msquic-p5-source.
grep -Fq -- 'GREENQUIC-P5-ASYNC-SIGNAL-SAFE-EXIT-V1' \
    "$P5_SOURCE/src/tools/interopserver/InteropServer.cpp" || {
    echo "ERROR: P5 source lacks graceful async-signal-safe server shutdown fix" >&2
    exit 1
}
grep -Fq -- 'GREENQUIC-COUNTERS-RECOVERY-END-SUCCESS-V1' \
    "$P5_SOURCE/src/platform/greenquic_plus.c" || {
    echo "ERROR: P5 source lacks corrected recovery-end counter semantics" >&2
    exit 1
}

# P5 controller must use graceful signal-driven shutdown so MsQuicClose() and
# GreenQuicPowerCleanup() emit the final server counter record.
grep -Fq -- 'GREENQUIC-P5-GRACEFUL-SERVER-EXIT-V1' \
    "$P5_DIR/gq_common_p5.sh" || {
    echo "ERROR: P5 controller lacks graceful server-exit marker" >&2
    exit 1
}
grep -Fq -- '-exitonsig' "$P5_DIR/gq_common_p5.sh" || {
    echo "ERROR: P5 server launcher is not using -exitonsig" >&2
    exit 1
}

# Additional counter charts committed with the last successful P5 changes.
[[ -f "$PLOTTER" ]] || {
    echo "ERROR: P5 counter histogram plotter missing: $PLOTTER" >&2
    exit 1
}
grep -Fq -- 'GREENQUIC-P5-COUNTER-HISTOGRAM-PLOTTER-V1' "$PLOTTER" || {
    echo "ERROR: counter histogram plotter marker missing" >&2
    exit 1
}
grep -Fq -- 'GREENQUIC-P5-COUNTER-HISTOGRAMS-V1' \
    "$P5_DIR/p5_finalize_matrix.py" || {
    echo "ERROR: P5 finalizer lacks additional counter-histogram hook" >&2
    exit 1
}
python3 "$PLOTTER" --self-test

printf '\nP5 client binary:\n'
printf '  %s\n' "$(readlink -f "$P5_CLIENT")"
sha256sum "$P5_CLIENT"
printf '\nP5 server binary:\n'
printf '  %s\n' "$(readlink -f "$P5_SERVER")"
sha256sum "$P5_SERVER"

printf '\n============================================================\n'
printf ' GREENQUIC FULL BOOTSTRAP: SUCCESS\n'
printf ' NORMAL BUILD: READY\n'
printf ' P4 ISOLATED BUILD: READY\n'
printf ' P5 ISOLATED CLIENT+SERVER BUILD: READY\n'
printf ' P5 FINAL COUNTERS + GRACEFUL CLEANUP: VERIFIED\n'
printf ' P5 COUNTER HISTOGRAMS: VERIFIED\n'
printf '============================================================\n'
