#!/usr/bin/env bash
set -Eeuo pipefail

ROLE="${1:?usage: verify_p5_parallel_multicore_binary.sh client|server BINARY}"
BIN="${2:?usage: verify_p5_parallel_multicore_binary.sh client|server BINARY}"

case "$ROLE" in
    client|server) ;;
    *) echo "ERROR: role must be client or server, got '$ROLE'" >&2; exit 2 ;;
esac

[[ -x "$BIN" ]] || {
    echo "ERROR: P5 $ROLE multicore binary is missing or not executable: $BIN" >&2
    exit 2
}

# These strings are emitted by compiled runtime/config/error paths. Do not add
# source-only comment markers here: comments are removed by the compiler and
# therefore cannot be used as ELF evidence.
COMMON_RUNTIME_EVIDENCE=(
    GreenQuicEnableMultiCore
    GreenQuicPartitionDpdkMap
    greenquic-mc-queue-v1
    'GreenQUIC multicore TX queue topology invalid'
    'GreenQUIC multicore TX requires one TX queue per DPDK RX owner'
    GREENQUIC-P5-PERFORMANCE2-V1
    GREENQUIC-P5-PERFORMANCE2-V2
)

for marker in "${COMMON_RUNTIME_EVIDENCE[@]}"; do
    grep -aFq -- "$marker" "$BIN" || {
        echo "ERROR: compiled P5 $ROLE multicore evidence '$marker' missing from $BIN" >&2
        exit 2
    }
done

if [[ "$ROLE" == client ]]; then
    CLIENT_RUNTIME_EVIDENCE=(
        GREENQUIC-P5-PARALLEL-CONNECTIONS-V1
        GQ_INTEROP_P5_LOCAL_PORT_BASE
        ready_for_start_gate_us=
    )
    for marker in "${CLIENT_RUNTIME_EVIDENCE[@]}"; do
        grep -aFq -- "$marker" "$BIN" || {
            echo "ERROR: compiled P5 parallel-client evidence '$marker' missing from $BIN" >&2
            exit 2
        }
    done
fi

echo "P5 PARALLEL MULTICORE COMPILED-RUNTIME CONTRACT PASS role=$ROLE bin=$BIN"
