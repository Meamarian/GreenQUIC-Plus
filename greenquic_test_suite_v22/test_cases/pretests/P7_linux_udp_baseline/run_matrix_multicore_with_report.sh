#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
BASE="$HERE/run_matrix_from_idex.sh"
IRQ_HELPER="$HERE/p7_multicore_irq.py"
REPORTER="$HERE/build_p7_report_multicore.py"
VALIDATOR="$HERE/validate_p7_multicore_matrix.py"

RUNS=""
OUTPUT_DIR=""
USER_ARGS=()

while (($#)); do
    case "$1" in
        --runs)
            RUNS="${2:?missing value for --runs}"
            USER_ARGS+=("$1" "$2")
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="${2:?missing value for --output-dir}"
            USER_ARGS+=("$1" "$2")
            shift 2
            ;;
        -h|--help)
            cat <<'EOF'
P7 two-CPU Linux baseline matched to P5 multicore topology.

Fixed controls:
  Linux dataplane CPUs  19,20
  combined queues       2
  QUIC worker CPUs      21,22,23,24
  queue IRQs            round-robin, one CPU per TxRx queue IRQ
  RPS                    disabled
  irqbalance             stopped
  TUM/paper offloads     enabled
  UDP rmem/wmem          6815744
  RAPL/frequency/C-state recording enabled

Other P7 options may be supplied; fixed topology/control options are appended
last and therefore win.
EOF
            exit 0
            ;;
        *)
            USER_ARGS+=("$1")
            shift
            ;;
    esac
done

[[ -f "$BASE" ]] || { echo "ERROR: missing $BASE" >&2; exit 2; }
[[ -f "$IRQ_HELPER" ]] || { echo "ERROR: missing $IRQ_HELPER" >&2; exit 2; }
[[ -f "$REPORTER" ]] || { echo "ERROR: missing $REPORTER" >&2; exit 2; }
[[ -f "$VALIDATOR" ]] || { echo "ERROR: missing $VALIDATOR" >&2; exit 2; }

if [[ -z "$RUNS" ]]; then RUNS=5; fi
[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --runs must be positive" >&2; exit 2; }

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$HERE/matrix_results/P7_LINUX_MULTICORE_${RUNS}r_$(date +%Y%m%d_%H%M%S)"
    USER_ARGS+=("--output-dir" "$OUTPUT_DIR")
fi

TMP="$(mktemp "$HERE/.run_matrix_multicore.XXXXXX.sh")"
cleanup_tmp(){ rm -f -- "$TMP"; }
trap cleanup_tmp EXIT

python3 - "$BASE" "$TMP" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text(encoding="utf-8")
old = r'''env "${P7_ENV[@]}" bash -c 'source "$1/p7_common.sh"; iface="$(cat "$2/iface")"; p7_pin_irqs "$iface" "$P7_DATAPLANE_CPU"; p7_disable_rps "$iface"' _ "$HERE" "$LOCAL_STATE"
remote_env "bash -c 'source \"$CLIENT_DIR/p7_common.sh\"; iface=\"\$(cat \"$REMOTE_STATE/iface\")\"; p7_pin_irqs \"\$iface\" \"\$P7_DATAPLANE_CPU\"; p7_disable_rps \"\$iface\"'"
'''
new = old + r'''
# GREENQUIC-P7-MULTICORE-IRQ-V1
# p7_pin_irqs above puts all queue vectors inside the allowed CPU set. After
# channel tuning, map each ice TxRx queue IRQ to one dataplane CPU round-robin.
local_multicore_iface="$(cat "$LOCAL_STATE/iface")"
python3 "$HERE/p7_multicore_irq.py" \
    --iface "$local_multicore_iface" \
    --cpus "$P7_DATAPLANE_CPU" \
    --state-dir "$LOCAL_STATE" \
    --expected-queues 2

remote "python3 '$CLIENT_DIR/p7_multicore_irq.py' \
    --iface \"\$(cat '$REMOTE_STATE/iface')\" \
    --cpus '$P7_DATAPLANE_CPU' \
    --state-dir '$REMOTE_STATE' \
    --expected-queues 2"

cp "$LOCAL_STATE/multicore_irq_map.json" \
    "$OUTPUT_DIR/setup/server_multicore_irq_map.json"
remote "cat '$REMOTE_STATE/multicore_irq_map.json'" \
    > "$OUTPUT_DIR/setup/client_multicore_irq_map.json"

python3 - "$OUTPUT_DIR/setup/server_multicore_irq_map.json" \
          "$OUTPUT_DIR/setup/client_multicore_irq_map.json" <<'PYIRQ'
import json,sys
for name in sys.argv[1:]:
    data=json.load(open(name))
    cpus={int(row["cpu"]) for row in data.get("mappings",[])}
    if cpus != {19,20}:
        raise SystemExit(f"ERROR: {name} does not use both CPUs 19,20: {sorted(cpus)}")
print("P7 local+remote multicore IRQ maps verified before traffic")
PYIRQ
'''
count = src.count(old)
if count != 1:
    raise SystemExit(f"ERROR: expected one post-channel IRQ/RPS block in base P7 runner, found {count}")
src = src.replace(old, new, 1)
Path(sys.argv[2]).write_text(src, encoding="utf-8")
PY

chmod 0700 "$TMP"
bash -n "$TMP"

FIXED_ARGS=(
    --dataplane-cpu 19,20
    --quic-cpus 21,22,23,24
    --pin-irq 1
    --pin-quic 1
    --disable-rps 1
    --disable-rdma 1
    --combined-channels 2
    --stop-irqbalance 1
    --nic-offloads paper
    --udp-rmem 6815744
    --udp-wmem 6815744
    --network-diagnostics 1
    --record-quic-cpus 0
    --enable-record 1
    --rapl-interval-ms 6
    --freq-interval-ms 1
    --require-rapl 1
    --mtu 1500
    --restore-dpdk 1
)

echo "======================================================================"
echo "P7 LINUX MULTICORE BASELINE"
echo "dataplane=19,20 combined=2 QUIC=21,22,23,24"
echo "IRQ queue mapping=round-robin RPS=off irqbalance=stopped"
echo "TUM/paper offloads + rmem/wmem=6815744"
echo "======================================================================"

bash "$TMP" "${USER_ARGS[@]}" "${FIXED_ARGS[@]}"

[[ -d "$OUTPUT_DIR" ]] || {
    echo "ERROR: matrix output directory missing: $OUTPUT_DIR" >&2
    exit 1
}

python3 "$VALIDATOR" --matrix "$OUTPUT_DIR" --runs "$RUNS"

rm -rf -- "$OUTPUT_DIR/the_sheet_rules_all"
python3 "$REPORTER" \
    --matrix-dir "$OUTPUT_DIR" \
    --output "$OUTPUT_DIR/the_sheet_rules_all"

python3 "$VALIDATOR" \
    --matrix "$OUTPUT_DIR" \
    --runs "$RUNS" \
    --report-dir "$OUTPUT_DIR/the_sheet_rules_all"

cat > "$OUTPUT_DIR/MULTICORE_TOPOLOGY.txt" <<EOF
branch=performance2/p5-multicore
dataplane_cpus=19,20
combined_channels=2
quic_cpus=21,22,23,24
pin_irq=1
irq_mapping=ice_TxRx_round_robin_single_cpu_per_queue
disable_rps=1
stop_irqbalance=1
disable_rdma=1
nic_offloads=paper
udp_rmem_bytes=6815744
udp_wmem_bytes=6815744
rss_caveat=single QUIC connection may hash to one RX queue; two-queue topology is not RX scaling proof
EOF

echo "P7 LINUX MULTICORE MATRIX PASS"
echo "RESULTS: $OUTPUT_DIR"
