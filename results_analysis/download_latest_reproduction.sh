#!/usr/bin/env bash
set -Eeuo pipefail

# RUN ON: CONTROL HOST.
SERVER_HOST="${GQ_SERVER_HOST:-idex}"
BASTION="${GQ_BASTION:-}"
SSH_KEY="${GQ_SSH_KEY:-}"
DEST_ROOT="$PWD/reproduced_results"
REQUESTED_TAG=""
EXPECT_RUNS=""
EXPECT_DOWNLOADS=""

usage(){
    cat <<'USAGE'
Download a completed GreenQUIC+ paper reproduction.

RUN ON: CONTROL HOST

By default the latest completed/selected artifact directory on SERVER is used.
Use --tag to fetch one exact run without guessing by modification time.

  --server-host HOST   SERVER/controller endpoint as seen from CONTROL
                       (paper default: idex)
  --bastion USER@HOST  optional ProxyJump; use 'none' for direct SSH
  --ssh-key PATH       optional CONTROL private key
  --tag TAG            exact GQ_FAIR_REPRO_<TAG> run to download
  --dest DIR           destination root (default: ./reproduced_results)
  --expect-runs N      optional expected repetition count
  --expect-downloads N optional expected downloads per repetition
  -h, --help

The script ALWAYS prints the final remote result directories/ZIP paths and the
final local destination BEFORE starting SCP. It verifies SHA-256 after copying.
USAGE
}
need_arg(){ [[ $# -ge 2 && -n "$2" ]] || { echo "ERROR: $1 needs a value" >&2; exit 2; }; }
while (($#)); do
    case "$1" in
        --server-host) need_arg "$@"; SERVER_HOST="$2"; shift 2 ;;
        --bastion) need_arg "$@"; BASTION="$2"; shift 2 ;;
        --ssh-key) need_arg "$@"; SSH_KEY="$2"; shift 2 ;;
        --tag) need_arg "$@"; REQUESTED_TAG="$2"; shift 2 ;;
        --dest) need_arg "$@"; DEST_ROOT="$2"; shift 2 ;;
        --expect-runs) need_arg "$@"; EXPECT_RUNS="$2"; shift 2 ;;
        --expect-downloads) need_arg "$@"; EXPECT_DOWNLOADS="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -z "$REQUESTED_TAG" || "$REQUESTED_TAG" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "ERROR: --tag may contain only letters, digits, dot, underscore and dash" >&2
    exit 2
}
[[ -z "$EXPECT_RUNS" || "$EXPECT_RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --expect-runs must be positive" >&2; exit 2; }
[[ -z "$EXPECT_DOWNLOADS" || "$EXPECT_DOWNLOADS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --expect-downloads must be positive" >&2; exit 2; }
command -v ssh >/dev/null 2>&1 || { echo "ERROR: ssh is required" >&2; exit 2; }
command -v scp >/dev/null 2>&1 || { echo "ERROR: scp is required" >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || {
    # macOS normally provides shasum instead of sha256sum. Use a tiny wrapper.
    if command -v shasum >/dev/null 2>&1; then
        sha256sum(){ shasum -a 256 "$@"; }
    else
        echo "ERROR: sha256sum or shasum is required" >&2
        exit 2
    fi
}
[[ -z "$SSH_KEY" || -f "$SSH_KEY" ]] || { echo "ERROR: SSH key not found: $SSH_KEY" >&2; exit 2; }

SSH_OPTS=(-o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o StrictHostKeyChecking=accept-new)
[[ -n "$SSH_KEY" ]] && SSH_OPTS+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
if [[ -n "$BASTION" && "$BASTION" != none ]]; then SSH_OPTS+=(-J "$BASTION"); fi
TARGET="root@$SERVER_HOST"
remote(){ ssh "${SSH_OPTS[@]}" "$TARGET" "$@"; }
copy_from(){ local src="$1" dst="$2"; scp "${SSH_OPTS[@]}" "$TARGET:$src" "$dst"; }

if [[ -n "$REQUESTED_TAG" ]]; then
    ART="/root/GQ_FAIR_REPRO_${REQUESTED_TAG}"
    remote "test -d '$ART'" || {
        echo "ERROR: requested reproduction does not exist on SERVER role $SERVER_HOST: $ART" >&2
        exit 1
    }
else
    ART="$(remote '
find /root -maxdepth 1 -type d \
  -name "GQ_FAIR_REPRO_*" \
  -printf "%T@ %p\n" 2>/dev/null | \
  sort -nr | sed -n "1p" | cut -d" " -f2-
')"
    [[ -n "$ART" ]] || { echo "ERROR: no GQ_FAIR_REPRO artifact directory found on SERVER role $SERVER_HOST" >&2; exit 1; }
fi

remote "test -f '$ART/DONE'" || {
    echo "ERROR: reproduction is not marked DONE: $ART" >&2
    echo "Use results_analysis/live_monitor_run.sh with the same --tag to follow an active run." >&2
    exit 1
}
remote "test -s '$ART/RESULT_ZIPS.txt' && test -s '$ART/config.env' && test -s '$ART/RESULT_DIRS.env' && test -s '$ART/RESULT_ZIPS.sha256'" || {
    echo "ERROR: completed artifact is missing result metadata: $ART" >&2
    exit 1
}

BASE="$(basename "$ART")"
TAG="${BASE#GQ_FAIR_REPRO_}"
DEST="$DEST_ROOT/$TAG"
REMOTE_LOG="/root/GQ_FAIR_REPRO_${TAG}.log"
RESULT_DIRS="$(remote "cat '$ART/RESULT_DIRS.env'")"
ZIP_LIST="$(remote "cat '$ART/RESULT_ZIPS.txt'")"

while IFS= read -r z; do
    [[ -n "$z" ]] || continue
    remote "test -s '$z'" || { echo "ERROR: result ZIP listed by SERVER is missing/empty: $z" >&2; exit 1; }
done <<< "$ZIP_LIST"

# Requirement: paths are printed BEFORE any SCP starts.
echo
echo "======================================================================"
echo "FINAL RESULT PATHS — BEFORE SCP"
echo "RUN ON: CONTROL HOST"
echo "SERVER_ROLE=$SERVER_HOST"
echo "TAG=$TAG"
echo
echo "REMOTE RESULT PATHS:"
printf '%s\n' "$RESULT_DIRS"
echo
echo "REMOTE ZIP PATHS:"
printf '%s\n' "$ZIP_LIST"
echo
echo "LOCAL FINAL RESULT DIRECTORY:"
echo "$DEST"
echo "======================================================================"
echo

echo "STARTING AUTOMATIC SCP..."
mkdir -p "$DEST"
copy_from "$ART/config.env" "$DEST/config.env"
copy_from "$ART/RESULT_DIRS.env" "$DEST/RESULT_DIRS.env"
copy_from "$ART/RESULT_ZIPS.txt" "$DEST/RESULT_ZIPS.txt"
copy_from "$ART/RESULT_ZIPS.sha256" "$DEST/RESULT_ZIPS.sha256"
copy_from "$ART/DONE" "$DEST/DONE"
if remote "test -s '$ART/p5_recorder_evidence.json'"; then
    copy_from "$ART/p5_recorder_evidence.json" "$DEST/p5_recorder_evidence.json"
fi
if remote "test -s '$ART/p7_affinity_files.txt'"; then
    copy_from "$ART/p7_affinity_files.txt" "$DEST/p7_affinity_files.txt"
fi
while IFS= read -r z; do
    [[ -n "$z" ]] || continue
    copy_from "$z" "$DEST/"
done <<< "$ZIP_LIST"

if remote "test -f '$REMOTE_LOG'"; then
    copy_from "$REMOTE_LOG" "$DEST/"
else
    echo "WARNING: remote log not found: $REMOTE_LOG" >&2
fi

# Verify the downloaded archive bytes against hashes produced on SERVER.
(
    cd "$DEST"
    while read -r expected name; do
        [[ -n "${expected:-}" && -n "${name:-}" ]] || continue
        [[ -s "$name" ]] || { echo "ERROR: downloaded ZIP missing: $DEST/$name" >&2; exit 1; }
        actual="$(sha256sum "$name" | awk '{print $1}')"
        [[ "$actual" == "$expected" ]] || {
            echo "ERROR: SHA-256 mismatch for $name" >&2
            echo "expected=$expected" >&2
            echo "actual=$actual" >&2
            exit 1
        }
    done < RESULT_ZIPS.sha256
)

EXPECTED=(
    'branch=main'
    'P5_profile=optimized_Performance2_V2_TOP3_idle_monitor_normal'
    'P5_power_profile=TOP3'
    'P5_pressure_up=450'
    'P5_rx_queue_high=48'
    'P5_active_transfer_sleep_min_level=16'
    'P5_freq_period_us=10000'
    'P5_recorder_validation=durable_per_run_log_evidence'
    'P7_profile=paper_linux'
    'P7_nic_offloads=paper'
    'P7_udp_rmem=6815744'
    'P7_udp_wmem=6815744'
    'P7_combined_channels=1'
)
[[ -z "$EXPECT_RUNS" ]] || EXPECTED+=("runs=$EXPECT_RUNS")
[[ -z "$EXPECT_DOWNLOADS" ]] || EXPECTED+=("downloads=$EXPECT_DOWNLOADS")
for expected in "${EXPECTED[@]}"; do
    grep -qxF -- "$expected" "$DEST/config.env" || {
        echo "ERROR: downloaded config.env does not match expected final profile: $expected" >&2
        exit 1
    }
done

echo
echo "DOWNLOAD + PAPER CONFIG + SHA-256 VERIFICATION: PASS"
echo "FINAL LOCAL RESULT DIRECTORY: $DEST"
echo "Exact run commit: $(awk -F= '$1=="commit" {print $2}' "$DEST/config.env")"
echo "Downloaded ZIPs:"
while IFS= read -r z; do
    [[ -n "$z" ]] || continue
    echo "  $DEST/$(basename "$z")"
done <<< "$ZIP_LIST"
