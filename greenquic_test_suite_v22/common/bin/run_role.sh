#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
source "$HERE/gq_common.sh"

role="${1:?usage: run_role.sh server|client TEST_DIR [mode] [approximate]}"
test_dir="${2:?missing TEST_DIR}"
mode_arg="${3:-}"
approx="${4:-0}"

test_dir="$(cd "$test_dir" && pwd)"

test_id="$(basename "$test_dir")"
effective_mode="${GQ_MODE_OVERRIDE:-${mode_arg:-basic}}"
requested_log_level="${GQ_LOG_LEVEL:-0}"

if [[ -f "$test_dir/config.env" ]]; then
    while IFS='=' read -r key value; do
        case "$key" in
            TEST_ID)
                test_id="${value//\"/}"
                ;;
            DEFAULT_MODE)
                if [[ -z "${GQ_MODE_OVERRIDE:-}" && -z "$mode_arg" ]]; then
                    effective_mode="${value//\"/}"
                fi
                ;;
            TEST_GQ_LOG_LEVEL)
                requested_log_level="${value//\"/}"
                ;;
        esac
    done < <(
        grep -E '^(TEST_ID|DEFAULT_MODE|TEST_GQ_LOG_LEVEL)=' \
            "$test_dir/config.env" 2>/dev/null || true
    )
fi

case "$requested_log_level" in
    0|1|2) ;;
    *) requested_log_level=0 ;;
esac

run_selected_role() {
    case "$role" in
        server)
            run_server "$test_dir" "$mode_arg"
            ;;
        client)
            run_client "$test_dir" "$mode_arg" "$approx"
            ;;
        *)
            echo "ERROR: unknown role: $role" >&2
            return 2
            ;;
    esac
}

recording_enabled=1
if declare -F gq_recording_enabled >/dev/null 2>&1; then
    if ! gq_recording_enabled; then
        recording_enabled=0
    fi
elif [[ "${ENABLE_RECORD:-1}" == 0 ]]; then
    recording_enabled=0
fi

# Normal recorded runs already generate their complete report.
if [[ "$recording_enabled" == 1 ]]; then
    run_selected_role
    exit $?
fi

capture="$(mktemp)"
trap 'rm -f "$capture"' EXIT

normal_server_stop() {
    local rc="$1"

    case "$rc" in
        0|130|141|143)
            return 0
            ;;
    esac

    # Nested shell pipelines may return 1 after a normal Ctrl+C.
    if [[ "$rc" == 1 ]] &&
       grep -qF 'Waiting forever.' "$capture" &&
       ! grep -Eqi \
           'GreenQUIC-Test:ERROR|(^|[[:space:]])ERROR:|segmentation fault|aborted|core dumped|failed to start' \
           "$capture"; then
        return 0
    fi

    return 1
}

if [[ "$role" == server ]]; then
    if (( requested_log_level > 0 )); then
        # Show requested server diagnostics immediately.
        run_selected_role
        rc=$?

        if normal_server_stop "$rc"; then
            exit 0
        fi

        exit "$rc"
    fi

    # Quiet server: always show GET requests live.
    set +e
    ( run_selected_role ) 2>&1 |
        tee "$capture" |
        grep --line-buffered -E \
            "^[[:space:]]*\[[^]]+\][[:space:]]+GET[[:space:]]+'"
    statuses=("${PIPESTATUS[@]}")
    set -e

    rc="${statuses[0]}"

    if normal_server_stop "$rc"; then
        exit 0
    fi

    cat "$capture" >&2
    exit "$rc"
fi

# Client: capture output so goodput can always be produced.
if (( requested_log_level > 0 )); then
    set +e
    ( run_selected_role ) 2>&1 | tee "$capture"
    statuses=("${PIPESTATUS[@]}")
    set -e
    rc="${statuses[0]}"
else
    set +e
    ( run_selected_role ) >"$capture" 2>&1
    rc=$?
    set -e
fi

if [[ "$rc" != 0 ]]; then
    if (( requested_log_level == 0 )); then
        cat "$capture" >&2
    fi
    exit "$rc"
fi

# Some client paths already print the goodput summary.
if grep -q '^=== GreenQUIC Goodput Summary ===$' "$capture"; then
    if (( requested_log_level == 0 )); then
        awk '
            /^=== GreenQUIC Goodput Summary ===$/ {
                printing=1
            }
            printing {
                print
            }
            printing && NF==0 {
                exit
            }
        ' "$capture"
    fi
    exit 0
fi

# Otherwise calculate and print it directly from the completed client output.
python3 - \
    "$capture" \
    "$test_dir" \
    "$effective_mode" \
    "$test_id" <<'PY'
from pathlib import Path
import re
import sys

capture = Path(sys.argv[1])
test_dir = Path(sys.argv[2])
mode = sys.argv[3]
test_id = sys.argv[4]

text = capture.read_text(encoding="utf-8", errors="replace")

transmission_us = [
    int(value)
    for value in re.findall(
        r"(?mi)^\s*transmission time \[us\]:\s*(\d+)\s*$",
        text,
    )
]

completion_ms = [
    int(value)
    for value in re.findall(
        r"(?m)^.*Completed download!\s*\((\d+)\s*ms\)\s*$",
        text,
    )
]

if transmission_us and transmission_us[-1] > 0:
    duration_s = transmission_us[-1] / 1_000_000.0
    timing_source = "client transmission timer, microsecond resolution"
elif completion_ms and completion_ms[-1] > 0:
    duration_s = completion_ms[-1] / 1000.0
    timing_source = "MsQuic completion timer, millisecond resolution"
else:
    print(text, file=sys.stderr)
    raise SystemExit(
        "ERROR: the client completed without a positive download timer"
    )

requests = re.findall(
    r"Sending request:\s*GET\s+/([^\s]+)",
    text,
)

payload_name = requests[-1] if requests else ""

common = (test_dir / "../../../common").resolve()
candidates = [
    common / "files" / "server_root" / payload_name,
    common / "downloads" / payload_name,
]

payload_bytes = 0

for candidate in candidates:
    if payload_name and candidate.is_file():
        payload_bytes = candidate.stat().st_size
        break

if payload_bytes <= 0:
    logical = re.findall(r"logical_bytes=(\d+)", text)
    if logical:
        payload_bytes = int(logical[-1])

if payload_bytes <= 0:
    explicit = re.findall(
        r"Payload:.*?\((\d+)\s+bytes\)",
        text,
    )
    if explicit:
        payload_bytes = int(explicit[-1])

if payload_bytes <= 0:
    print(text, file=sys.stderr)
    raise SystemExit(
        f"ERROR: cannot determine payload size for {payload_name!r}"
    )

goodput_bps = payload_bytes * 8.0 / duration_s

crosscheck = None
if completion_ms and completion_ms[-1] > 0:
    crosscheck = (
        payload_bytes * 8.0 /
        (completion_ms[-1] / 1000.0) /
        1e9
    )

# Preferred final cleanup counters.
per_cpu = {}

for cpu, rx_packets, tx_packets in re.findall(
    r"(?m)^\[CPU\s+(\d+)\]\s+GreenQUIC\s+PACKETS\s+"
    r"source=policy_counters\s+"
    r"rx_pkts=(\d+)\s+tx_pkts=(\d+)\s*$",
    text,
):
    per_cpu[int(cpu)] = (
        int(rx_packets),
        int(tx_packets),
    )

# Fallback to the latest stats line for each CPU.
if not per_cpu:
    for line in text.splitlines():
        cpu_match = re.search(
            r"^\[CPU\s+(\d+)\]\s+GreenQUIC\s+lcore=",
            line,
        )
        rx_match = re.search(r"\brx_pkts=(\d+)\b", line)
        tx_match = re.search(r"\btx_pkts=(\d+)\b", line)

        if cpu_match and rx_match and tx_match:
            per_cpu[int(cpu_match.group(1))] = (
                int(rx_match.group(1)),
                int(tx_match.group(1)),
            )

print()
print("=== GreenQUIC Goodput Summary ===")
print(f"- Test: {test_id}")
print(f"- GreenQUIC mode: {mode}")
print(
    f"- Payload: {payload_bytes / (1024 ** 3):.3f} GiB "
    f"({payload_bytes} bytes)"
)
print(f"- Download duration: {duration_s:.6f} s")
print(f"- Goodput: {goodput_bps / 1e9:.6f} Gbit/s")
print(f"- Goodput: {goodput_bps / 1e6:.3f} Mbit/s")
print(f"- Timing source: {timing_source}")

if crosscheck is not None:
    print(
        "- MsQuic completion cross-check: "
        f"{crosscheck:.6f} Gbit/s"
    )

if per_cpu:
    total_rx = sum(values[0] for values in per_cpu.values())
    total_tx = sum(values[1] for values in per_cpu.values())

    print(f"- Client DPDK RX packets: {total_rx}")
    print(f"- Client DPDK TX packets: {total_tx}")
else:
    print("- Client DPDK RX packets: unavailable")
    print("- Client DPDK TX packets: unavailable")

print(
    "- Scope: payload bytes only; protocol headers and "
    "retransmissions are excluded"
)
print()
PY
