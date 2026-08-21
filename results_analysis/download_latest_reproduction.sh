#!/usr/bin/env bash
set -Eeuo pipefail

DEST_ROOT="${1:-$PWD/reproduced_results}"
HOST="${GREENQUIC_RESULT_HOST:-idex}"

command -v ssh >/dev/null 2>&1 || { echo "ERROR: ssh is required" >&2; exit 2; }
command -v scp >/dev/null 2>&1 || { echo "ERROR: scp is required" >&2; exit 2; }

ART="$(ssh "$HOST" '
find /root -maxdepth 1 -type d \
  -name "GQ_FAIR_REPRO_*" \
  -printf "%T@ %p\n" 2>/dev/null | \
  sort -nr | sed -n "1p" | cut -d" " -f2-
')"

[[ -n "$ART" ]] || { echo "ERROR: no GQ_FAIR_REPRO artifact directory found on $HOST" >&2; exit 1; }
ssh "$HOST" "test -f '$ART/DONE'" || {
    echo "ERROR: latest reproduction is not marked DONE: $ART" >&2
    echo "Check its log/status before downloading." >&2
    exit 1
}
ssh "$HOST" "test -s '$ART/RESULT_ZIPS.txt' && test -s '$ART/config.env'" || {
    echo "ERROR: completed artifact is missing RESULT_ZIPS.txt or config.env: $ART" >&2
    exit 1
}

BASE="$(basename "$ART")"
TAG="${BASE#GQ_FAIR_REPRO_}"
DEST="$DEST_ROOT/$TAG"
mkdir -p "$DEST"

echo "REMOTE_ARTIFACT_DIR=$ART"
echo "TAG=$TAG"
echo "DEST=$DEST"

scp "$HOST:$ART/config.env" "$DEST/config.env"
scp "$HOST:$ART/RESULT_ZIPS.txt" "$DEST/RESULT_ZIPS.txt"
scp "$HOST:$ART/DONE" "$DEST/DONE"

while IFS= read -r z; do
    [[ -n "$z" ]] || continue
    scp "$HOST:$z" "$DEST/"
done < "$DEST/RESULT_ZIPS.txt"

REMOTE_LOG="/root/GQ_FAIR_REPRO_${TAG}.log"
if ssh "$HOST" "test -f '$REMOTE_LOG'"; then
    scp "$HOST:$REMOTE_LOG" "$DEST/"
else
    echo "WARNING: remote log not found at expected sibling path: $REMOTE_LOG" >&2
fi

for expected in \
    'branch=main' \
    'runs=6' \
    'downloads=5' \
    'P5_profile=optimized_Performance2_V2_TOP3_idle_monitor_normal' \
    'P5_power_profile=TOP3' \
    'P5_pressure_up=450' \
    'P5_rx_queue_high=48' \
    'P5_active_transfer_sleep_min_level=16' \
    'P5_freq_period_us=10000' \
    'P7_profile=paper_linux' \
    'P7_nic_offloads=paper' \
    'P7_udp_rmem=6815744' \
    'P7_udp_wmem=6815744' \
    'P7_combined_channels=1'
do
    grep -qxF -- "$expected" "$DEST/config.env" || {
        echo "ERROR: downloaded config.env does not match final paper profile: $expected" >&2
        exit 1
    }
done

echo
echo "DOWNLOAD + PAPER CONFIG VERIFICATION: PASS"
echo "Results saved under: $DEST"
echo "Exact run commit: $(awk -F= '$1=="commit" {print $2}' "$DEST/config.env")"
