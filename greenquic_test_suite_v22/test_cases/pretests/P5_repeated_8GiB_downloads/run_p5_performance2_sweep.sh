#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
STAMP="${STAMP:-$(date +%Y%m%d_%H%M%S)}"
CLIENT_HOST="${CLIENT_HOST:-tinyman}"
DOWNLOADS="${P5_P2_DOWNLOADS:-3}"
RUNS="${P5_P2_RUNS:-1}"
CUSTOM_TESTS="${P5_P2_TESTS:-}"
RESULT_ROOT="${RESULT_ROOT:-/tmp/P5_PERFORMANCE2_${STAMP}}"
MATRIX_ROOT="$HERE/matrix_results/P5_PERFORMANCE2_${STAMP}"
SUMMARY="$RESULT_ROOT/goodput_summary.tsv"
TABLE="$RESULT_ROOT/comparison_table.tsv"
MASTER="$RESULT_ROOT/master.log"
BUILD_HELPER="$HERE/build_p5_performance2.sh"

[[ "$DOWNLOADS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: P5_P2_DOWNLOADS must be positive" >&2; exit 2; }
[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: P5_P2_RUNS must be positive" >&2; exit 2; }
mkdir -p "$RESULT_ROOT/logs" "$MATRIX_ROOT"
printf 'index\tprofile\tmode\taggregate_gbps\td1_gbps\tsteady_gbps\trc\n' > "$SUMMARY"
exec > >(tee -a "$MASTER") 2>&1
FAILURES=0

restore_native() {
    local r1=0 r2=0 p1 p2
    echo "RESTORING NATIVE P5 BINARIES ON IDEX + $CLIENT_HOST"
    (cd "$HERE" && P5_STATIC_PROFILE=native P5_BUILD_REUSE=1 bash ./build_p5_client.sh >"$RESULT_ROOT/restore_idex.log" 2>&1) & p1=$!
    ssh -n root@"$CLIENT_HOST" "cd '$HERE' && P5_STATIC_PROFILE=native P5_BUILD_REUSE=1 bash ./build_p5_client.sh" >"$RESULT_ROOT/restore_client.log" 2>&1 & p2=$!
    wait "$p1" || r1=$?
    wait "$p2" || r2=$?
    echo "NATIVE RESTORE RC: idex=$r1 client=$r2"
}

on_exit() {
    local rc=$?
    trap - EXIT INT TERM
    restore_native || true
    exit "$rc"
}
trap on_exit EXIT INT TERM

cat > "$RESULT_ROOT/configs.tsv" <<'EOF'
index	profile	handoff	pring	rxpref	udpseg	udpmax	diag_us
00	baseline	shared	1024	0	0	4	0
01	diag_100ms	shared	1024	0	0	4	100000
02	sharded_512	sharded	512	0	0	4	0
03	sharded_1024	sharded	1024	0	0	4	0
04	sharded_2048	sharded	2048	0	0	4	0
05	rx_prefetch	shared	1024	1	0	4	0
06	udp_seg2	shared	1024	0	1	2	0
07	udp_seg4	shared	1024	0	1	4	0
08	udp_seg8	shared	1024	0	1	8	0
09	sharded_rxprefetch	sharded	1024	1	0	4	0
10	sharded_udp4	sharded	1024	0	1	4	0
11	all_p2	sharded	1024	1	1	4	0
EOF

selected() {
    local profile="$1"
    if [[ -z "$CUSTOM_TESTS" ]]; then return 0; fi
    case ",$CUSTOM_TESTS," in *,"$profile",*) return 0;; *) return 1;; esac
}

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
if ! fuser /var/run/dpdk/rte/config >/dev/null 2>&1; then rm -rf /var/run/dpdk/rte; fi
CLEAN
    fi
}

build_both() {
    local idx="$1" profile="$2" handoff="$3" pring="$4" rxpref="$5" udpseg="$6" udpmax="$7" diag="$8"
    local l1="$RESULT_ROOT/logs/build_idex_${idx}_${profile}.log"
    local l2="$RESULT_ROOT/logs/build_tinyman_${idx}_${profile}.log"
    local envs="P5_BUILD_REUSE=1 P5_P2_TX_HANDOFF=$handoff P5_P2_TX_PRODUCER_RING_SIZE=$pring P5_P2_RX_PREFETCH=$rxpref P5_P2_UDP_SEG=$udpseg P5_P2_UDP_SEG_MAX=$udpmax P5_P2_DIAG_INTERVAL_US=$diag P5_P2_DIAG_DURATION_MS=3000"
    local p1 p2 r1=0 r2=0
    (cd "$HERE" && env $envs bash "$BUILD_HELPER" >"$l1" 2>&1) & p1=$!
    ssh -n root@"$CLIENT_HOST" "cd '$HERE' && env $envs bash '$BUILD_HELPER'" >"$l2" 2>&1 & p2=$!
    wait "$p1" || r1=$?
    wait "$p2" || r2=$?
    if (( r1 != 0 || r2 != 0 )); then
        echo "BUILD FAILED $profile idex=$r1 tinyman=$r2"
        tail -100 "$l1" || true
        tail -100 "$l2" || true
        return 20
    fi
    echo "BUILD PASS $profile"
    grep -E 'P5 PERFORMANCE2 BUILD PASS|GREENQUIC-P5-PERFORMANCE2-V1|P5-PERF2-USO' "$l1" | tail -10 || true
}

extract_run() {
    local idx="$1" profile="$2" log="$3" rc="$4"
    python3 - "$idx" "$profile" "$log" "$rc" "$SUMMARY" <<'PY'
import re, sys
from pathlib import Path
idx, profile, log, rc, out = sys.argv[1:]
text = Path(log).read_text(errors='replace') if Path(log).exists() else ''
aggregate = {}
durations = {m:{} for m in ('off','basic','plus')}
for line in text.splitlines():
    m = re.search(r'\[MODE=(off|basic|plus)\].*?Aggregate goodput excluding gaps:\s*([0-9.]+)\s*Gbit/s', line, re.I)
    if m: aggregate[m.group(1).lower()] = float(m.group(2))
    d = re.search(r'\[MODE=(off|basic|plus)\].*?\[DOWNLOAD\s+(\d+)/(\d+)\s+COMPLETE\].*?duration_us=(\d+)', line, re.I)
    if d: durations[d.group(1).lower()][int(d.group(2))] = int(d.group(4))
BITS = 8589934592 * 8
def gbps(us): return BITS / (us/1_000_000.0) / 1e9
def steady(mode):
    vals=[us for n,us in sorted(durations[mode].items()) if n>=2]
    return None if not vals else (BITS*len(vals))/(sum(vals)/1_000_000.0)/1e9
with open(out,'a') as f:
    for mode in ('off','basic','plus'):
        a=aggregate.get(mode); d1=gbps(durations[mode][1]) if 1 in durations[mode] else None; st=steady(mode)
        fmt=lambda v:'NA' if v is None else f'{v:.6f}'
        f.write(f'{idx}\t{profile}\t{mode}\t{fmt(a)}\t{fmt(d1)}\t{fmt(st)}\t{rc}\n')
PY
}

while IFS=$'\t' read -r idx profile handoff pring rxpref udpseg udpmax diag; do
    [[ "$idx" == index ]] && continue
    selected "$profile" || { echo "SKIP $profile"; continue; }
    echo "======================================================================"
    echo "RUN $idx $profile handoff=$handoff pring=$pring rxpref=$rxpref udpseg=$udpseg udpmax=$udpmax diag_us=$diag"
    echo "======================================================================"
    clean_host local || true
    clean_host "$CLIENT_HOST" || true
    brc=0; build_both "$idx" "$profile" "$handoff" "$pring" "$rxpref" "$udpseg" "$udpmax" "$diag" || brc=$?
    if (( brc != 0 )); then
        for mode in off basic plus; do printf '%s\t%s\t%s\tNA\tNA\tNA\t%s\n' "$idx" "$profile" "$mode" "$brc" >> "$SUMMARY"; done
        FAILURES=$((FAILURES+1))
        continue
    fi
    log="$RESULT_ROOT/logs/run_${idx}_${profile}.log"
    out="$MATRIX_ROOT/${idx}_${profile}"
    set +e
    bash "$HERE/run_matrix_with_sheet.sh" \
        --chart-style old \
        --client-host "$CLIENT_HOST" \
        --client-dir "$HERE" \
        --client-bin /root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop \
        --downloads "$DOWNLOADS" \
        --gap-seconds 5 \
        --server-cooldown-seconds 5 \
        --between-tests-seconds 0 \
        --cstate-cpu 19 \
        --runs "$RUNS" \
        --mode-order balanced \
        --seed 20260813 \
        --output-dir "$out" \
        --env ENABLE_RECORD=1 \
        --env GQ_LOG_LEVEL=0 \
        --env GQ_IDLE_MODE_OVERRIDE=monitor \
        --env GQ_IDLE_FALLBACK_OVERRIDE=short \
        >"$log" 2>&1
    rrc=$?
    set -e
    extract_run "$idx" "$profile" "$log" "$rrc"
    if (( rrc != 0 )); then
        echo "RUN FAILED $profile rc=$rrc"
        tail -100 "$log" || true
        FAILURES=$((FAILURES+1))
    fi
    sleep 10
done < "$RESULT_ROOT/configs.tsv"

python3 - "$SUMMARY" "$TABLE" <<'PY'
import csv, sys
src,out=sys.argv[1:]
rows=list(csv.DictReader(open(src),delimiter='\t'))
d={}
for r in rows:
    key=(r['index'],r['profile']); d.setdefault(key,{})[r['mode']]=r
fields=['index','profile','off_gbps','basic_gbps','plus_gbps','avg_gbps','off_steady','basic_steady','plus_steady','avg_steady','worst_steady','rc']
rec=[]
def num(x):
    try:return float(x)
    except:return None
def fmt(x):return 'NA' if x is None else f'{x:.6f}'
for (idx,p),m in sorted(d.items()):
    agg=[num(m.get(k,{}).get('aggregate_gbps')) for k in ('off','basic','plus')]
    st=[num(m.get(k,{}).get('steady_gbps')) for k in ('off','basic','plus')]
    ok=all(x is not None for x in agg); sok=all(x is not None for x in st)
    rec.append(dict(index=idx,profile=p,off_gbps=fmt(agg[0]),basic_gbps=fmt(agg[1]),plus_gbps=fmt(agg[2]),avg_gbps=fmt(sum(agg)/3 if ok else None),off_steady=fmt(st[0]),basic_steady=fmt(st[1]),plus_steady=fmt(st[2]),avg_steady=fmt(sum(st)/3 if sok else None),worst_steady=fmt(min(st) if sok else None),rc=','.join(sorted({m.get(k,{}).get('rc','NA') for k in ('off','basic','plus')}))))
with open(out,'w',newline='') as f:
    w=csv.DictWriter(f,fieldnames=fields,delimiter='\t'); w.writeheader(); w.writerows(rec)
rank=[r for r in rec if r['avg_steady']!='NA' and r['profile']!='diag_100ms']
rank.sort(key=lambda r:(float(r['plus_steady']),float(r['avg_steady']),float(r['worst_steady'])),reverse=True)
print('\nRANKING: PLUS steady first, then 3-mode steady average')
for i,r in enumerate(rank,1): print(f"{i:2d}. {r['profile']:<22} PLUS={r['plus_steady']} avg={r['avg_steady']} worst={r['worst_steady']}")
PY

column -t -s $'\t' "$TABLE" 2>/dev/null || cat "$TABLE"
echo "RESULT_ROOT=$RESULT_ROOT"
echo "MATRIX_ROOT=$MATRIX_ROOT"
echo "FAILURES=$FAILURES"
exit 0
