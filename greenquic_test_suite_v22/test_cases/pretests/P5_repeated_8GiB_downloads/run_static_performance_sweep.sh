#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
STAMP="${STAMP:-$(date +%Y%m%d_%H%M%S)}"
SWEEP_ROOT="${SWEEP_ROOT:-/tmp/P5_STATIC_SWEEP_${STAMP}}"
MATRIX_ROOT="$HERE/matrix_results/P5_STATIC_SWEEP_${STAMP}"
CONFIGS="$SWEEP_ROOT/configs.tsv"
SUMMARY="$SWEEP_ROOT/goodput_summary.tsv"
MASTER="$SWEEP_ROOT/master.log"
CLIENT_HOST="${CLIENT_HOST:-tinyman}"

mkdir -p "$SWEEP_ROOT/logs" "$MATRIX_ROOT"

cat > "$CONFIGS" <<'EOF'
index	profile	cache	rxd	txd	rxpool	txpool	rxb	txb	ring
00	native	256	4096	4096	16383	16383	32	32	4096
01	burst64	256	4096	4096	16383	16383	64	64	4096
02	rx64	256	4096	4096	16383	16383	64	32	4096
03	tx64	256	4096	4096	16383	16383	32	64	4096
04	burst128	256	4096	4096	16383	16383	128	128	4096
05	cache128	128	4096	4096	16383	16383	32	32	4096
06	cache512	512	4096	4096	16383	16383	32	32	4096
07	desc2048	256	2048	2048	16383	16383	32	32	4096
08	ring2048	256	4096	4096	16383	16383	32	32	2048
09	ring8192	256	4096	4096	16383	16383	32	32	8192
10	pool8191	256	4096	4096	8191	8191	32	32	4096
EOF

printf 'index\tprofile\tmode\tgoodput_gbps\trc\n' > "$SUMMARY"

exec > >(tee -a "$MASTER") 2>&1

echo "======================================================================"
echo "P5 STATIC PERFORMANCE SWEEP"
echo "Known-good native smoke + 10 build-time-only DPDK configurations"
echo "3 downloads per mode, 5 s gaps, old charts, GQ_LOG_LEVEL=0"
echo "No runtime performance hooks; GreenQUIC/PLUS policy is unchanged"
echo "Results root: $MATRIX_ROOT"
echo "Summary root: $SWEEP_ROOT"
echo "======================================================================"
column -t -s $'\t' "$CONFIGS" 2>/dev/null || cat "$CONFIGS"

clean_host() {
    local host="$1"
    if [[ "$host" == local ]]; then
        bash -s <<'CLEAN'
for p in /proc/[0-9]*; do
    exe=$(readlink -f "$p/exe" 2>/dev/null || true)
    case "$exe" in */quicinterop|*/quicinteropserver) kill -TERM "${p##*/}" 2>/dev/null || true;; esac
done
sleep 1
for p in /proc/[0-9]*; do
    exe=$(readlink -f "$p/exe" 2>/dev/null || true)
    case "$exe" in */quicinterop|*/quicinteropserver) kill -KILL "${p##*/}" 2>/dev/null || true;; esac
done
sleep 1
if ! fuser /var/run/dpdk/rte/config >/dev/null 2>&1; then rm -rf /var/run/dpdk/rte; fi
CLEAN
    else
        ssh -n root@"$host" 'bash -s' <<'CLEAN'
for p in /proc/[0-9]*; do
    exe=$(readlink -f "$p/exe" 2>/dev/null || true)
    case "$exe" in */quicinterop|*/quicinteropserver) kill -TERM "${p##*/}" 2>/dev/null || true;; esac
done
sleep 1
for p in /proc/[0-9]*; do
    exe=$(readlink -f "$p/exe" 2>/dev/null || true)
    case "$exe" in */quicinterop|*/quicinteropserver) kill -KILL "${p##*/}" 2>/dev/null || true;; esac
done
sleep 1
if ! fuser /var/run/dpdk/rte/config >/dev/null 2>&1; then rm -rf /var/run/dpdk/rte; fi
CLEAN
    fi
}

build_profile() {
    local profile="$1" tag="$2"
    local l1="$SWEEP_ROOT/logs/build_idex_${tag}_${profile}.log"
    local l2="$SWEEP_ROOT/logs/build_tinyman_${tag}_${profile}.log"

    echo
    echo "=== BUILD profile=$profile on idex + tinyman in parallel ==="

    (
        cd "$HERE"
        P5_STATIC_PROFILE="$profile" bash ./build_p5_client.sh >"$l1" 2>&1
    ) &
    local p1=$!

    ssh -n root@"$CLIENT_HOST" \
        "cd '$HERE' && P5_STATIC_PROFILE='$profile' bash ./build_p5_client.sh" \
        >"$l2" 2>&1 &
    local p2=$!

    local r1=0 r2=0
    wait "$p1" || r1=$?
    wait "$p2" || r2=$?

    if (( r1 != 0 || r2 != 0 )); then
        echo "ERROR: build failed profile=$profile idex_rc=$r1 tinyman_rc=$r2"
        echo "IDEX build tail:"; tail -40 "$l1" || true
        echo "TINYMAN build tail:"; tail -40 "$l2" || true
        return 1
    fi

    echo "BUILD PASS profile=$profile"
    grep -E 'P5 build profile:|P5 static performance profile:|PROFILE:|PATH:' "$l1" | tail -12 || true
}

extract_goodput() {
    local idx="$1" profile="$2" log="$3" rc="$4"
    python3 - "$idx" "$profile" "$log" "$rc" "$SUMMARY" <<'PY'
import re, sys
from pathlib import Path
idx, profile, logfile, rc, summary = sys.argv[1:]
text = Path(logfile).read_text(errors='replace')
res = {}
for line in text.splitlines():
    m = re.search(r'\[MODE=(off|basic|plus)\].*?Aggregate goodput excluding gaps:\s*([0-9.]+)\s*Gbit/s', line, re.I)
    if m:
        res[m.group(1).lower()] = float(m.group(2))
with open(summary, 'a') as f:
    for mode in ('off','basic','plus'):
        v = res.get(mode)
        f.write(f"{idx}\t{profile}\t{mode}\t{'NA' if v is None else f'{v:.6f}'}\t{rc}\n")
print(f"{idx} {profile}")
for mode in ('off','basic','plus'):
    v = res.get(mode)
    print(f"  {mode.upper():5s}: {'NA' if v is None else f'{v:.6f} Gbit/s'}")
PY
}

run_profile() {
    local idx="$1" profile="$2" label="$3"
    local out="$MATRIX_ROOT/${idx}_${profile}"
    local log="$SWEEP_ROOT/logs/run_${idx}_${profile}.log"

    echo
    echo "======================================================================"
    echo "$label : $idx $profile"
    echo "======================================================================"

    clean_host local
    clean_host "$CLIENT_HOST"

    build_profile "$profile" "$idx" || return 20

    clean_host local
    clean_host "$CLIENT_HOST"

    cd "$HERE"
    set +e
    bash ./run_matrix_with_sheet.sh \
        --chart-style old \
        --client-host "$CLIENT_HOST" \
        --client-dir "$HERE" \
        --client-bin /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop \
        --downloads 3 \
        --gap-seconds 5 \
        --server-cooldown-seconds 5 \
        --between-tests-seconds 0 \
        --cstate-cpu 19 \
        --runs 1 \
        --mode-order balanced \
        --seed 20260813 \
        --output-dir "$out" \
        --env ENABLE_RECORD=1 \
        --env GQ_LOG_LEVEL=0 \
        --env GQ_IDLE_MODE_OVERRIDE=monitor \
        --env GQ_IDLE_FALLBACK_OVERRIDE=short \
        >"$log" 2>&1
    local rc=$?
    set -e

    extract_goodput "$idx" "$profile" "$log" "$rc"

    if (( rc != 0 )); then
        echo "ERROR: matrix failed profile=$profile rc=$rc"
        tail -80 "$log" || true
        return "$rc"
    fi

    return 0
}

run_profile 00 native "SMOKE / KNOWN-GOOD BASELINE"

echo
echo "======================================================================"
echo "SMOKE GOODPUT"
echo "======================================================================"
awk -F '\t' 'NR==1 || $1=="00"' "$SUMMARY" | column -t -s $'\t' 2>/dev/null || true

echo
echo "SMOKE PASSED. STARTING 10 STATIC CONFIGURATIONS."

for row in \
    '01 burst64' \
    '02 rx64' \
    '03 tx64' \
    '04 burst128' \
    '05 cache128' \
    '06 cache512' \
    '07 desc2048' \
    '08 ring2048' \
    '09 ring8192' \
    '10 pool8191'
do
    read -r idx profile <<<"$row"
    run_profile "$idx" "$profile" "TUNING"
    sleep 10
done

echo
echo "======================================================================"
echo "ALL RESULTS"
echo "======================================================================"
column -t -s $'\t' "$SUMMARY" 2>/dev/null || cat "$SUMMARY"

echo
echo "======================================================================"
echo "PER-CONFIG AVERAGE + WORST MODE"
echo "======================================================================"
python3 - "$SUMMARY" <<'PY'
import csv, sys
rows=list(csv.DictReader(open(sys.argv[1]), delimiter='\t'))
groups={}
for r in rows:
    try:v=float(r['goodput_gbps'])
    except:continue
    groups.setdefault((r['index'],r['profile']),{})[r['mode']]=v
print(f"{'IDX':<4} {'PROFILE':<12} {'OFF':>9} {'BASIC':>9} {'PLUS':>9} {'AVG':>9} {'WORST':>9}")
valid=[]
for (idx,p),d in groups.items():
    if len(d)!=3:continue
    avg=sum(d.values())/3
    worst=min(d.values())
    valid.append((avg,worst,idx,p,d))
    print(f"{idx:<4} {p:<12} {d['off']:9.3f} {d['basic']:9.3f} {d['plus']:9.3f} {avg:9.3f} {worst:9.3f}")
if valid:
    avg,worst,idx,p,d=max(valid,key=lambda x:(x[0],x[1]))
    print(f"\nBEST COMMON: {idx} {p} avg={avg:.6f} worst={worst:.6f} Gbit/s")
PY

echo
echo "=== RESTORING KNOWN-GOOD NATIVE BINARIES ON BOTH HOSTS ==="
build_profile native final

echo
echo "======================================================================"
echo "FINISHED"
echo "SUMMARY=$SUMMARY"
echo "CONFIGS=$CONFIGS"
echo "MASTER=$MASTER"
echo "MATRIX_ROOT=$MATRIX_ROOT"
echo "Native known-good binaries restored after sweep."
echo "======================================================================"
