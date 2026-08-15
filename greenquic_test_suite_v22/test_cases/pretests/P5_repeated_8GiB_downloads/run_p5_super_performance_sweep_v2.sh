#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
STAMP="${STAMP:-$(date +%Y%m%d_%H%M%S)}"
CLIENT_HOST="${CLIENT_HOST:-tinyman}"
DOWNLOADS="${P5_SUPER_DOWNLOADS:-3}"
PLAN="${P5_SUPER_PLAN:-screen}"
CUSTOM_TESTS="${P5_SUPER_TESTS:-}"
RESULT_ROOT="${RESULT_ROOT:-/tmp/P5_SUPER_SWEEP_${STAMP}}"
MATRIX_ROOT="$HERE/matrix_results/P5_SUPER_SWEEP_${STAMP}"
SUMMARY="$RESULT_ROOT/goodput_summary.tsv"
TABLE="$RESULT_ROOT/comparison_table.tsv"
CONFIGS="$RESULT_ROOT/configs.tsv"
MASTER="$RESULT_ROOT/master.log"
TOPOLOGY="$RESULT_ROOT/numa_topology.txt"
CAPS="$RESULT_ROOT/dpdk_capabilities.txt"
BUILD_HELPER="$HERE/build_p5_super_performance.sh"

mkdir -p "$RESULT_ROOT/logs" "$MATRIX_ROOT"

cat > "$CONFIGS" <<'EOF'
index	profile	group	cache	rxb	txb	ring	sync	drain	threshold	mtu	skipoff	debug	window	trace	txmeta	rxmeta
00	measured_default	screen	128	32	16	4096	legacy	1	0	0	0	1	1	1	pool	pool
01	classic_mp	screen	128	32	16	4096	mp	1	0	0	0	1	1	1	pool	pool
02	drain2	screen	128	32	16	4096	legacy	2	0	0	0	1	1	1	pool	pool
03	drain4	screen	128	32	16	4096	legacy	4	0	0	0	1	1	1	pool	pool
04	drain8	screen	128	32	16	4096	legacy	8	0	0	0	1	1	1	pool	pool
05	adaptive64	screen	128	32	16	4096	legacy	8	64	0	0	1	1	1	pool	pool
06	mtu1500	screen	128	32	16	4096	legacy	1	0	1500	0	1	1	1	pool	pool
07	skipoffcount	screen	128	32	16	4096	legacy	1	0	0	1	1	1	1	pool	pool
08	no_debug_counters	screen	128	32	16	4096	legacy	1	0	0	0	0	1	1	pool	pool
09	no_transfer_window	screen	128	32	16	4096	legacy	1	0	0	0	1	0	1	pool	pool
10	no_trace_ringcount	screen	128	32	16	4096	legacy	1	0	0	0	1	1	0	pool	pool
11	txmeta_mbuf	screen	128	32	16	4096	legacy	1	0	0	0	1	1	1	mbuf	pool
12	rxmeta_mbuf	screen	128	32	16	4096	legacy	1	0	0	0	1	1	1	pool	mbuf
13	classic_mp_drain4	combo	128	32	16	4096	mp	4	0	0	0	1	1	1	pool	pool
14	clean_hotpath	combo	128	32	16	4096	legacy	1	0	0	1	0	0	0	pool	pool
15	meta_both	combo	128	32	16	4096	legacy	1	0	0	0	1	1	1	mbuf	mbuf
16	drain4_txmeta	combo	128	32	16	4096	legacy	4	0	0	0	1	1	1	mbuf	pool
17	drain4_meta_both	combo	128	32	16	4096	legacy	4	0	0	0	1	1	1	mbuf	mbuf
18	classic_mp_drain4_meta_both	combo	128	32	16	4096	mp	4	0	0	0	1	1	1	mbuf	mbuf
19	clean_hotpath_meta_both	combo	128	32	16	4096	legacy	1	0	0	1	0	0	0	mbuf	mbuf
20	mtu1500_classic_mp_drain4	combo	128	32	16	4096	mp	4	0	1500	0	1	1	1	pool	pool
21	super_combo	combo	128	32	16	4096	mp	4	0	1500	1	0	0	0	mbuf	mbuf
EOF

printf 'index\tprofile\tmode\tgoodput_gbps\trc\n' > "$SUMMARY"
: > "$CAPS"
exec > >(tee -a "$MASTER") 2>&1
FAILURES=0

selected() {
    local profile="$1" group="$2"
    if [[ -n "$CUSTOM_TESTS" ]]; then
        case ",$CUSTOM_TESTS," in *,"$profile",*) return 0;; *) return 1;; esac
    fi
    case "$PLAN" in
        screen) [[ "$group" == screen ]] ;;
        combo) [[ "$group" == combo || "$profile" == measured_default ]] ;;
        all) return 0 ;;
        *) echo "ERROR: P5_SUPER_PLAN must be screen|combo|all" >&2; exit 2 ;;
    esac
}

clean_local() {
    local p exe
    for p in /proc/[0-9]*; do
        exe="$(readlink -f "$p/exe" 2>/dev/null || true)"
        case "$exe" in */quicinterop|*/quicinteropserver) kill -TERM "${p##*/}" 2>/dev/null || true;; esac
    done
    sleep 1
    for p in /proc/[0-9]*; do
        exe="$(readlink -f "$p/exe" 2>/dev/null || true)"
        case "$exe" in */quicinterop|*/quicinteropserver) kill -KILL "${p##*/}" 2>/dev/null || true;; esac
    done
    sleep 1
    if ! fuser /var/run/dpdk/rte/config >/dev/null 2>&1; then rm -rf /var/run/dpdk/rte; fi
}

clean_remote() {
    ssh -n root@"$CLIENT_HOST" 'bash -s' <<'CLEAN'
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
}

restore_native() {
    echo
    echo "RESTORING NATIVE P5 BINARIES ON IDEX + TINYMAN"
    local r1=0 r2=0 p1 p2
    (cd "$HERE" && P5_STATIC_PROFILE=native P5_BUILD_REUSE=1 bash ./build_p5_client.sh >"$RESULT_ROOT/restore_idex.log" 2>&1) &
    p1=$!
    ssh -n root@"$CLIENT_HOST" "cd '$HERE' && P5_STATIC_PROFILE=native P5_BUILD_REUSE=1 bash ./build_p5_client.sh" >"$RESULT_ROOT/restore_tinyman.log" 2>&1 &
    p2=$!
    wait "$p1" || r1=$?
    wait "$p2" || r2=$?
    echo "NATIVE RESTORE RC: idex=$r1 tinyman=$r2"
}

on_exit() {
    rc=$?
    trap - EXIT INT TERM
    restore_native || true
    exit "$rc"
}
trap on_exit EXIT INT TERM

capture_topology() {
    {
        echo "=== IDEX ==="
        hostname
        lscpu -e=CPU,NODE,SOCKET,CORE 2>/dev/null || true
        echo "NIC PCI/NUMA"
        for d in /sys/bus/pci/devices/*; do
            drv="$(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null || true)"
            if [[ "$drv" == vfio-pci || "$drv" == ice ]]; then
                printf '%s driver=%s numa=' "$(basename "$d")" "$drv"
                cat "$d/numa_node" 2>/dev/null || echo '?'
            fi
        done
        echo
        echo "=== TINYMAN ==="
        ssh -n root@"$CLIENT_HOST" 'hostname; lscpu -e=CPU,NODE,SOCKET,CORE 2>/dev/null || true; echo "NIC PCI/NUMA"; for d in /sys/bus/pci/devices/*; do drv=$(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null || true); if [ "$drv" = vfio-pci ] || [ "$drv" = ice ]; then printf "%s driver=%s numa=" "$(basename "$d")" "$drv"; cat "$d/numa_node" 2>/dev/null || echo "?"; fi; done'
    } > "$TOPOLOGY" 2>&1
}

append_na() {
    local idx="$1" profile="$2" rc="$3"
    for mode in off basic plus; do printf '%s\t%s\t%s\tNA\t%s\n' "$idx" "$profile" "$mode" "$rc" >> "$SUMMARY"; done
}

build_both() {
    local idx="$1" profile="$2" cache="$3" rxb="$4" txb="$5" ring="$6" sync="$7" drain="$8" threshold="$9"
    shift 9
    local mtu="$1" skipoff="$2" debug="$3" window="$4" trace="$5" txmeta="$6" rxmeta="$7"
    local l1="$RESULT_ROOT/logs/build_idex_${idx}_${profile}.log"
    local l2="$RESULT_ROOT/logs/build_tinyman_${idx}_${profile}.log"
    local p1 p2 r1=0 r2=0
    local envs="P5_BUILD_REUSE=1 P5_SUPER_CACHE=$cache P5_SUPER_RX_BURST=$rxb P5_SUPER_TX_BURST=$txb P5_SUPER_RING_SIZE=$ring P5_SUPER_RING_SYNC=$sync P5_SUPER_DRAIN_BURSTS=$drain P5_SUPER_DRAIN_THRESHOLD=$threshold P5_SUPER_MTU=$mtu P5_SUPER_SKIP_OFF_RINGCOUNT=$skipoff P5_SUPER_DEBUG_COUNTERS=$debug P5_SUPER_TRANSFER_WINDOW=$window P5_SUPER_TRACE_RINGCOUNT=$trace P5_SUPER_TX_META=$txmeta P5_SUPER_RX_META=$rxmeta P5_SUPER_CAP_DIAG=1"

    echo "BUILD $idx $profile on idex + tinyman"
    (cd "$HERE" && env $envs bash "$BUILD_HELPER" >"$l1" 2>&1) &
    p1=$!
    ssh -n root@"$CLIENT_HOST" "cd '$HERE' && env $envs bash '$BUILD_HELPER'" >"$l2" 2>&1 &
    p2=$!
    wait "$p1" || r1=$?
    wait "$p2" || r2=$?
    if (( r1 != 0 || r2 != 0 )); then
        echo "BUILD FAILED $idx $profile: idex=$r1 tinyman=$r2"
        echo "--- IDEX BUILD TAIL ---"; tail -120 "$l1" || true
        echo "--- TINYMAN BUILD TAIL ---"; tail -120 "$l2" || true
        return 20
    fi
    echo "BUILD PASS $idx $profile"
    grep -E 'P5 SUPER PERFORMANCE BUILD|P5 SUPER BUILD PASS|GREENQUIC-P5-SUPER-PERF-V1' "$l1" | tail -8 || true
}

extract_run() {
    local idx="$1" profile="$2" log="$3" rc="$4"
    python3 - "$idx" "$profile" "$log" "$rc" "$SUMMARY" <<'PY'
import re, sys
from pathlib import Path
idx, profile, log, rc, out = sys.argv[1:]
text = Path(log).read_text(errors="replace") if Path(log).exists() else ""
results = {}
for line in text.splitlines():
    m = re.search(r"\[MODE=(off|basic|plus)\].*?Aggregate goodput excluding gaps:\s*([0-9.]+)\s*Gbit/s", line, re.I)
    if m: results[m.group(1).lower()] = float(m.group(2))
with open(out, "a") as f:
    for mode in ("off", "basic", "plus"):
        v = results.get(mode)
        f.write(f"{idx}\t{profile}\t{mode}\t{'NA' if v is None else f'{v:.6f}'}\t{rc}\n")
print(f"{idx} {profile}")
for mode in ("off", "basic", "plus"):
    v = results.get(mode)
    print(f"  {mode.upper():5s}: {'NA' if v is None else f'{v:.6f} Gbit/s'}")
PY
    grep -F '[GreenQUIC-P5-SUPER-CAPS]' "$log" >> "$CAPS" 2>/dev/null || true
}

run_one() {
    local idx="$1" profile="$2" group="$3" cache="$4" rxb="$5" txb="$6" ring="$7" sync="$8" drain="$9"
    shift 9
    local threshold="$1" mtu="$2" skipoff="$3" debug="$4" window="$5" trace="$6" txmeta="$7" rxmeta="$8"
    local out="$MATRIX_ROOT/${idx}_${profile}"
    local log="$RESULT_ROOT/logs/run_${idx}_${profile}.log"
    local brc=0 rrc=0

    if ! selected "$profile" "$group"; then echo "SKIP $idx $profile"; return 0; fi

    echo
    echo "======================================================================"
    echo "RUN $idx $profile"
    echo "cache=$cache rxb=$rxb txb=$txb ring=$ring sync=$sync drain=$drain threshold=$threshold mtu=$mtu skipoff=$skipoff debug=$debug window=$window trace=$trace txmeta=$txmeta rxmeta=$rxmeta"
    echo "======================================================================"

    clean_local
    clean_remote
    set +e
    build_both "$idx" "$profile" "$cache" "$rxb" "$txb" "$ring" "$sync" "$drain" "$threshold" "$mtu" "$skipoff" "$debug" "$window" "$trace" "$txmeta" "$rxmeta"
    brc=$?
    set -e
    if (( brc != 0 )); then append_na "$idx" "$profile" "$brc"; FAILURES=$((FAILURES + 1)); return 0; fi

    clean_local
    clean_remote
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
        --runs 1 \
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
    if (( rrc != 0 )); then echo "RUN FAILED $idx $profile rc=$rrc"; tail -120 "$log" || true; FAILURES=$((FAILURES + 1)); fi
}

echo "======================================================================"
echo "P5 SUPER PERFORMANCE SWEEP V2"
echo "PLAN=$PLAN CUSTOM_TESTS=${CUSTOM_TESTS:-none}"
echo "CONTROL=measured_default: cache128 + TX burst16; all new switches disabled."
echo "Screen changes one datapath property at a time; combo profiles are separate."
echo "GreenQUIC / GreenQUIC+ policy internals remain unchanged."
echo "======================================================================"
column -t -s $'\t' "$CONFIGS" 2>/dev/null || cat "$CONFIGS"
capture_topology

while IFS=$'\t' read -r idx profile group cache rxb txb ring sync drain threshold mtu skipoff debug window trace txmeta rxmeta; do
    [[ "$idx" == index ]] && continue
    run_one "$idx" "$profile" "$group" "$cache" "$rxb" "$txb" "$ring" "$sync" "$drain" "$threshold" "$mtu" "$skipoff" "$debug" "$window" "$trace" "$txmeta" "$rxmeta"
    if selected "$profile" "$group"; then echo "COOLDOWN BETWEEN CONFIGS: 10 s"; sleep 10; fi
done < "$CONFIGS"

python3 - "$SUMMARY" "$TABLE" <<'PY'
import csv, sys
summary, out = sys.argv[1:]
rows = list(csv.DictReader(open(summary), delimiter="\t"))
configs = {}
for r in rows:
    key=(r["index"],r["profile"])
    try: v=float(r["goodput_gbps"])
    except Exception: v=None
    configs.setdefault(key,{})[r["mode"]]=(v,r["rc"])
base=None
for (idx,p),d in configs.items():
    if p=="measured_default": base={m:d.get(m,(None,""))[0] for m in ("off","basic","plus")}; break
base_avg=None
if base and all(base.get(m) is not None for m in ("off","basic","plus")): base_avg=sum(base.values())/3.0
fields=["index","profile","off_gbps","basic_gbps","plus_gbps","avg_gbps","worst_gbps","off_delta_pct","basic_delta_pct","plus_delta_pct","avg_delta_pct","rc"]
def fmt(v): return "NA" if v is None else f"{v:.6f}"
records=[]
for (idx,p),d in sorted(configs.items()):
    vals={m:d.get(m,(None,""))[0] for m in ("off","basic","plus")}
    good=[v for v in vals.values() if v is not None]
    avg=sum(good)/3.0 if len(good)==3 else None
    worst=min(good) if len(good)==3 else None
    def delta(m):
        b=base.get(m) if base else None; v=vals[m]
        return None if b in (None,0) or v is None else (v/b-1.0)*100.0
    avgd=None if avg is None or base_avg in (None,0) else (avg/base_avg-1.0)*100.0
    rc=",".join(sorted({d.get(m,(None,"NA"))[1] for m in ("off","basic","plus")}))
    records.append({"index":idx,"profile":p,"off_gbps":fmt(vals["off"]),"basic_gbps":fmt(vals["basic"]),"plus_gbps":fmt(vals["plus"]),"avg_gbps":fmt(avg),"worst_gbps":fmt(worst),"off_delta_pct":fmt(delta("off")),"basic_delta_pct":fmt(delta("basic")),"plus_delta_pct":fmt(delta("plus")),"avg_delta_pct":fmt(avgd),"rc":rc})
with open(out,"w",newline="") as f:
    w=csv.DictWriter(f,fieldnames=fields,delimiter="\t"); w.writeheader(); w.writerows(records)
complete=[r for r in records if r["avg_gbps"]!="NA" and r["worst_gbps"]!="NA"]
complete.sort(key=lambda r:(float(r["avg_gbps"]),float(r["worst_gbps"])),reverse=True)
print("\nRANKING BY 3-MODE AVG, THEN WORST MODE")
for i,r in enumerate(complete,1): print(f"{i:2d}. {r['profile']:<32} avg={r['avg_gbps']} worst={r['worst_gbps']} delta={r['avg_delta_pct']}%")
if complete: print(f"\nBEST COMMON: {complete[0]['profile']}")
PY

echo
echo "======================================================================"
echo "FINAL TABLE"
echo "======================================================================"
column -t -s $'\t' "$TABLE" 2>/dev/null || cat "$TABLE"
echo
echo "DPDK CAPABILITY LINES:"
sort -u "$CAPS" || true
echo
echo "RESULT_ROOT=$RESULT_ROOT"
echo "MATRIX_ROOT=$MATRIX_ROOT"
echo "FAILURES=$FAILURES"
if (( FAILURES != 0 )); then exit 1; fi
