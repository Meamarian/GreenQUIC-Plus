#!/usr/bin/env bash
set -Eeuo pipefail

if (( $# != 10 )); then
    echo "Usage: $0 STAMP SHA BRANCH RUNS DOWNLOADS GAP EDGE BETWEEN BUNDLE BUNDLE_REF" >&2
    exit 2
fi

STAMP="$1"
SHA="$2"
BRANCH="$3"
RUNS="$4"
DOWNLOADS="$5"
GAP="$6"
EDGE="$7"
BETWEEN="$8"
BUNDLE="$9"
BUNDLE_REF="${10}"

ROOT=/root/mohsen
P5="$ROOT/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
P7="$ROOT/greenquic_test_suite_v22/test_cases/pretests/P7_linux_udp_baseline"
SEQTAG="P7_PAPER_FAIR_${STAMP}"
ART="/root/$SEQTAG"
P7_OUT="$P7/matrix_results/P7_${STAMP}"
P7_ZIP="/root/P7_${STAMP}.zip"

mkdir -p "$ART"
rm -f "$ART/DONE" "$ART/FAILED" "$ART/RESULT_ZIPS.txt"

log(){ printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

wait_tinyman(){
    local n=0
    while ! ssh -n -o BatchMode=yes -o ConnectTimeout=5 root@tinyman true >/dev/null 2>&1; do
        n=$((n+1))
        log "Tinyman unreachable; waiting 10s ($n)"
        sleep 10
    done
    log "Tinyman SSH reachable"
}

scp_tinyman_retry(){
    local src="$1" dst="$2"
    while ! scp -q -o ConnectTimeout=10 "$src" "$dst"; do
        log "Tinyman SCP unavailable; retrying in 10s"
        sleep 10
        wait_tinyman
    done
}

on_exit(){
    local rc=$?
    trap - EXIT INT TERM
    rm -f "$BUNDLE" >/dev/null 2>&1 || true
    if ssh -n -o BatchMode=yes -o ConnectTimeout=5 root@tinyman true >/dev/null 2>&1; then
        ssh -n root@tinyman "rm -f '$BUNDLE'" >/dev/null 2>&1 || true
    fi
    if (( rc != 0 )); then
        printf 'rc=%s\nline=%s\n' "$rc" "${BASH_LINENO[0]:-unknown}" > "$ART/FAILED"
        log "FAILED rc=$rc"
    fi
    exit "$rc"
}
trap on_exit EXIT INT TERM

cleanup_both(){
    cd "$P5"
    python3 ./safe_cleanup_p5_bottleneck_processes.py || true
    python3 ./safe_cleanup_p5_bottleneck_processes.py --check
    wait_tinyman
    ssh -n root@tinyman "cd '$P5' && python3 ./safe_cleanup_p5_bottleneck_processes.py || true; python3 ./safe_cleanup_p5_bottleneck_processes.py --check"
}

is_network_failure(){
    local rc="$1" logfile="$2"
    (( rc == 255 )) && return 0
    grep -Eqi 'No route to host|Connection timed out|Connection reset|Connection refused|Connection closed|Host is down|Network is unreachable|ssh: connect to host tinyman' "$logfile" 2>/dev/null
}

[[ "$(git -C "$ROOT" rev-parse HEAD)" == "$SHA" ]] || {
    echo "ERROR: IDEX repo is not at requested SHA=$SHA" >&2
    exit 2
}

log "sync exact SHA on Tinyman"
wait_tinyman
scp_tinyman_retry "$BUNDLE" root@tinyman:"$BUNDLE"
ssh -n root@tinyman "cd '$ROOT' && git reset --hard && git fetch '$BUNDLE' '$BUNDLE_REF' && git checkout -B '$BRANCH' FETCH_HEAD && test \"\$(git rev-parse HEAD)\" = '$SHA'"

cleanup_both

log "build stock Linux P7 binaries on both endpoints"
(cd "$P7" && bash ./build_p7_linux.sh >"$ART/build_p7_idex.log" 2>&1) & p1=$!
ssh -n root@tinyman "cd '$P7' && bash ./build_p7_linux.sh" >"$ART/build_p7_tinyman.log" 2>&1 & p2=$!
wait "$p1"; wait "$p2"

log "P7 paper+fair run"
log "paper: max_throughput, paper GSO/GRO profile, rmem/wmem=6815744"
log "fair: runs=$RUNS downloads=$DOWNLOADS gap=$GAP edge=$EDGE between=$BETWEEN CPU19 vs QUIC21-24"

P7_LOG="$ART/p7.log"
for attempt in 1 2 3; do
    wait_tinyman
    cleanup_both
    rm -rf "$P7_OUT"
    log "P7 attempt $attempt/3"
    cd "$P7"
    set +e
    MSQUIC_EXECUTION_PROFILE=max_throughput \
    P7_RECORDER_CPU=auto \
    bash ./run_matrix_with_report.sh \
        --chart-style both \
        --log-level 0 \
        --client-host tinyman \
        --client-dir "$P7" \
        --downloads "$DOWNLOADS" \
        --gap-seconds "$GAP" \
        --runs "$RUNS" \
        --pre-cooldown-seconds "$EDGE" \
        --post-cooldown-seconds "$EDGE" \
        --between-runs-seconds "$BETWEEN" \
        --dataplane-cpu 19 \
        --quic-cpus 21,22,23,24 \
        --pin-irq 1 \
        --pin-quic 1 \
        --disable-rps 1 \
        --disable-rdma 1 \
        --nic-offloads paper \
        --udp-rmem 6815744 \
        --udp-wmem 6815744 \
        --combined-channels 1 \
        --network-diagnostics 0 \
        --record-quic-cpus 0 \
        --enable-record 1 \
        --rapl-interval-ms 6 \
        --freq-interval-ms 1 \
        --require-rapl 1 \
        --stop-irqbalance 1 \
        --mtu 1500 \
        --output-dir "$P7_OUT" \
        2>&1 | tee "$P7_LOG"
    rc=${PIPESTATUS[0]}
    set -e

    if (( rc == 0 )); then
        log "P7 completed successfully"
        break
    fi
    if (( attempt < 3 )) && is_network_failure "$rc" "$P7_LOG"; then
        log "P7 SSH/network failure rc=$rc; discard incomplete matrix and retry"
        cleanup_both
        rm -rf "$P7_OUT"
        sleep 10
        continue
    fi
    echo "ERROR: P7 failed rc=$rc" >&2
    exit "$rc"
done

# Require the normal matrix + report output before advertising DONE.
test -d "$P7_OUT/runs/server"
test -d "$P7_OUT/runs/client"
test -d "$P7_OUT/the_sheet_rules_all"
find "$P7_OUT/the_sheet_rules_all" -type f -print -quit | grep -q .

cat > "$ART/config.env" <<CFG
branch=$BRANCH
commit=$SHA
case=P7_paper_fair
matrix=$P7_OUT
runs=$RUNS
downloads_per_run=$DOWNLOADS
payload_per_download_bytes=8589934592
gap_seconds=$GAP
pre_cooldown_seconds=$EDGE
post_cooldown_seconds=$EDGE
between_runs_seconds=$BETWEEN
msquic_execution_profile=max_throughput
linux_datapath=kernel_udp
xdp=disabled
dpdk=disabled
nic_offloads=paper
paper_required_offloads=TSO,GSO,TX_CHECKSUM,GRO
paper_optional_offloads=TX_UDP_SEGMENTATION,RX_CHECKSUM,RX_GRO_HW
udp_rmem_bytes=6815744
udp_wmem_bytes=6815744
combined_channels=1
disable_rdma_aux=1
mtu=1500
dataplane_irq_napi_cpu=19
quic_cpus=21,22,23,24
pin_irq=1
pin_quic=1
disable_rps=1
stop_irqbalance=1
record_quic_cpus=0
rapl_interval_ms=6
frequency_interval_ms=1
cstate_frequency_cpu=19
chart_style=both
network_diagnostics=0
CFG

log "zip P7 result"
rm -f "$P7_ZIP"
(cd "$(dirname "$P7_OUT")" && zip -qr "$P7_ZIP" "$(basename "$P7_OUT")")
printf '%s\n' "$P7_ZIP" > "$ART/RESULT_ZIPS.txt"
touch "$ART/DONE"
log "DONE"
echo "$P7_ZIP"
