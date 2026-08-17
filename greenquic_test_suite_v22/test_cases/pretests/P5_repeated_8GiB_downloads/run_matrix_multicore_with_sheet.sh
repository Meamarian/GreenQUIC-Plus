#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
BASE_RUNNER="$HERE/run_matrix_from_idex.sh"
REPORTER="$HERE/build_sheet_rules_all_multicore.py"
VALIDATOR="$HERE/validate_p5_multicore_matrix.py"

RUNS=""
OUTPUT_DIR=""
ARGS=()

while (($#)); do
    case "$1" in
        --runs)
            RUNS="${2:?missing value for --runs}"
            ARGS+=("$1" "$2")
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="${2:?missing value for --output-dir}"
            ARGS+=("$1" "$2")
            shift 2
            ;;
        -h|--help)
            cat <<'EOF'
P5 Performance2 two-DPDK-core matrix.

Fixed multicore topology on both endpoints:
  DPDK lcores        19,20
  QUIC worker CPUs   21,22,23,24
  partition map      0:19,1:19,2:20,3:20
  dedicated TX owner 19
  TX owner also RX   1

All normal P5 matrix options are forwarded.
EOF
            "$BASE_RUNNER" --help || true
            exit 0
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

[[ -f "$BASE_RUNNER" ]] || { echo "ERROR: missing $BASE_RUNNER" >&2; exit 2; }
[[ -f "$REPORTER" ]] || { echo "ERROR: missing $REPORTER" >&2; exit 2; }
[[ -f "$VALIDATOR" ]] || { echo "ERROR: missing $VALIDATOR" >&2; exit 2; }
python3 -c 'import matplotlib, numpy' >/dev/null 2>&1 || {
    echo "ERROR: matplotlib and numpy are required for P5 multicore reporting" >&2
    exit 2
}

if [[ -z "$RUNS" ]]; then
    RUNS=5
fi
[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --runs must be positive" >&2; exit 2; }

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$HERE/matrix_results/P5_PERFORMANCE2_MULTICORE_${RUNS}r_$(date +%Y%m%d_%H%M%S)"
    ARGS+=("--output-dir" "$OUTPUT_DIR")
fi

TOPOLOGY_ENV=(
    --env ENABLE_MULTICORE=1
    --env SERVER_DPDK_LCORES=19,20
    --env CLIENT_DPDK_LCORES=19,20
    --env SERVER_QUIC_CPUS=21,22,23,24
    --env CLIENT_QUIC_CPUS=21,22,23,24
    --env SERVER_PARTITION_MAP=0:19,1:19,2:20,3:20
    --env CLIENT_PARTITION_MAP=0:19,1:19,2:20,3:20
    --env SERVER_TX_OWNER_LCORE=19
    --env CLIENT_TX_OWNER_LCORE=19
    --env GREENQUIC_TX_OWNER_ALSO_RX=1
)

echo "======================================================================"
echo "P5 PERFORMANCE2 MULTICORE MATRIX"
echo "DPDK=19,20 QUIC=21,22,23,24 TX-owner=19 TX-owner-also-RX=1"
echo "NOTE: one QUIC connection may remain on one RSS RX queue."
echo "======================================================================"

"$BASE_RUNNER" "${ARGS[@]}" "${TOPOLOGY_ENV[@]}"

[[ -d "$OUTPUT_DIR" ]] || {
    echo "ERROR: matrix output directory missing: $OUTPUT_DIR" >&2
    exit 1
}

python3 "$VALIDATOR" --matrix "$OUTPUT_DIR" --runs "$RUNS"

rm -rf -- "$OUTPUT_DIR/the_sheet_rules_all"
python3 "$REPORTER" \
    --input "$OUTPUT_DIR" \
    --output "$OUTPUT_DIR/the_sheet_rules_all" \
    --expected-charts 62

python3 "$VALIDATOR" \
    --matrix "$OUTPUT_DIR" \
    --runs "$RUNS" \
    --report-dir "$OUTPUT_DIR/the_sheet_rules_all"

cat > "$OUTPUT_DIR/MULTICORE_TOPOLOGY.txt" <<EOF
branch=performance2/p5-multicore
enable_multicore=1
server_dpdk_lcores=19,20
client_dpdk_lcores=19,20
server_quic_cpus=21,22,23,24
client_quic_cpus=21,22,23,24
server_partition_map=0:19,1:19,2:20,3:20
client_partition_map=0:19,1:19,2:20,3:20
tx_owner_lcore=19
tx_owner_also_rx=1
rss_caveat=single QUIC connection may hash to one RX queue; topology validation is not RX scaling proof
EOF

echo "P5 PERFORMANCE2 MULTICORE MATRIX PASS"
echo "RESULTS: $OUTPUT_DIR"
