#!/usr/bin/env bash
set -Eeuo pipefail

# RUN ON: CONTROL HOST.
SERVER_HOST="${GQ_SERVER_HOST:-idex}"
BASTION="${GQ_BASTION:-}"
SSH_KEY="${GQ_SSH_KEY:-}"
DEST_ROOT="$PWD/reproduced_results"
REQUESTED_TAG=""

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
  -h, --help
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
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -z "$REQUESTED_TAG" || "$REQUESTED_TAG" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "ERROR: --tag may contain only letters, digits, dot, underscore and dash" >&2
    exit 2
}
command -v ssh >/dev/null 2>&1 || { echo "ERROR: ssh is required" >&2; exit 2; }
command -v scp >/dev/null 2>&1 || { echo "ERROR: scp is required" >&2; exit 2; }
[[ -z "$SSH_KEY" || -f "$SSH_KEY" ]] || { echo "ERROR: SSH key not found: $SSH_KEY" >&2; exit 2; }

SSH_OPTS=(-o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new)
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
remote "test -s '$ART/RESULT_ZIPS.txt' && test -s '$ART/config.env'" || {
    echo "ERROR: completed artifact is missing RESULT_ZIPS.txt or config.env: $ART" >&2
    exit 1
}

BASE="$(basename "$ART")"; TAG="${BASE#GQ_FAIR_REPRO_}"; DEST="$DEST_ROOT/$TAG"
mkdir -p "$DEST"
printf 'RUN ON: CONTROL HOST\nSERVER_ROLE=%s\nREMOTE_ARTIFACT_DIR=%s\nTAG=%s\nDEST=%s\n' "$SERVER_HOST" "$ART" "$TAG" "$DEST"

copy_from "$ART/config.env" "$DEST/config.env"
copy_from "$ART/RESULT_ZIPS.txt" "$DEST/RESULT_ZIPS.txt"
copy_from "$ART/DONE" "$DEST/DONE"
while IFS= read -r z; do
    [[ -n "$z" ]] || continue
    remote "test -s '$z'" || { echo "ERROR: result ZIP listed by SERVER is missing/empty: $z" >&2; exit 1; }
    copy_from "$z" "$DEST/"
done < "$DEST/RESULT_ZIPS.txt"

REMOTE_LOG="/root/GQ_FAIR_REPRO_${TAG}.log"
if remote "test -f '$REMOTE_LOG'"; then
    copy_from "$REMOTE_LOG" "$DEST/"
else
    echo "WARNING: remote log not found: $REMOTE_LOG" >&2
fi

for expected in \
    'branch=main' 'runs=6' 'downloads=5' \
    'P5_profile=optimized_Performance2_V2_TOP3_idle_monitor_normal' \
    'P5_power_profile=TOP3' 'P5_pressure_up=450' 'P5_rx_queue_high=48' \
    'P5_active_transfer_sleep_min_level=16' 'P5_freq_period_us=10000' \
    'P7_profile=paper_linux' 'P7_nic_offloads=paper' \
    'P7_udp_rmem=6815744' 'P7_udp_wmem=6815744' 'P7_combined_channels=1'
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
