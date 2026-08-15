#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
STAMP="${STAMP:-$(date +%Y%m%d_%H%M%S)}"
CLIENT_HOST="${CLIENT_HOST:-tinyman}"
DOWNLOADS="${P5_RING_DOWNLOADS:-3}"
TESTS="${P5_RING_TESTS:-control,hts_generic,mp_classic,rts_generic,deq_generic,ring1024,ring2048,ring8192,txburst16,txburst64,txburst128}"
RESULT_ROOT="${RESULT_ROOT:-/tmp/P5_RING_SWEEP_${STAMP}}"
MATRIX_ROOT="$HERE/matrix_results/P5_RING_SWEEP_${STAMP}"
SUMMARY="$RESULT_ROOT/goodput_summary.tsv"
TABLE="$RESULT_ROOT/comparison_table.tsv"
CONFIGS="$RESULT_ROOT/configs.tsv"
MASTER="$RESULT_ROOT/master.log"
TOPOLOGY="$RESULT_ROOT/numa_topology.txt"
BUILD_HELPER="$HERE/build_p5_cache128_ring.sh"
mkdir -p "$RESULT_ROOT/logs" "$MATRIX_ROOT"

cat > "$CONFIGS" <<'EOF'
index	profile	kind	ring_size	tx_burst	enqueue	producer_sync	dequeue
00	control	control	4096	32	explicit_mp	configured_hts_but_explicit_mp	explicit_sc
01	hts_generic	sync	4096	32	generic	hts	explicit_sc
02	mp_classic	sync	4096	32	explicit_mp	classic_mp	explicit_sc
03	rts_generic	sync	4096	32	generic	rts	explicit_sc
04	deq_generic	consumer_api	4096	32	explicit_mp	configured_hts_but_explicit_mp	generic_sc
05	ring1024	size	1024	32	explicit_mp	configured_hts_but_explicit_mp	explicit_sc
06	ring2048	size	2048	32	explicit_mp	configured_hts_but_explicit_mp	explicit_sc
07	ring8192	size	8192	32	explicit_mp	configured_hts_but_explicit_mp	explicit_sc
08	txburst16	drain	4096	16	explicit_mp	configured_hts_but_explicit_mp	explicit_sc
09	txburst64	drain	4096	64	explicit_mp	configured_hts_but_explicit_mp	explicit_sc
10	txburst128	drain	4096	128	explicit_mp	configured_hts_but_explicit_mp	explicit_sc
EOF

printf 'index\tprofile\tmode\tgoodput_gbps\trc\n' > "$SUMMARY"
exec > >(tee -a "$MASTER") 2>&1
FAILURES=0

selected() {
    local name="$1"
    case ",$TESTS," in
        *,"$name",*) return 0 ;;
        *) return 1 ;;
    esac
}

clean_local() {
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
        echo "CPU topology"
        lscpu -e=CPU,NODE,SOCKET,CORE 2>/dev/null || true
        echo "NIC PCI/NUMA"
        for d in /sys/bus/pci/devices/*; do
            drv=$(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null || true)
            if [[ "$drv" == vfio-pci || "$drv" == ice ]]; then
                printf '%s driver=%s numa=' "$(basename "$d")" "$drv"
                cat "$d/numa_node" 2>/dev/null || echo '?'
            fi
        done
        echo
        echo "=== TINYMAN ==="
        ssh -n root@"$CLIENT_HOST" 'hostname; echo "CPU topology"; lscpu -e=CPU,NODE,SOCKET,CORE 2>/dev/null || true; echo "NIC PCI/NUMA"; for d in /sys/bus/pci/devices/*; do drv=$(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null || true); if [ "$drv" = vfio-pci ] || [ "$drv" = ice ]; then printf "%s driver=%s numa=" "$(basename "$d")" "$drv"; cat "$d/numa_node" 2>/dev/null || echo "?"; fi; done'
    } > "$TOPOLOGY" 2>&1
}

append_na() {
    local idx="$1" profile="$2" rc="$3"
    for mode in off basic plus; do
        printf '%s\t%s\t%s\tNA\t%s\n' "$idx" "$profile" "$mode" "$rc" >> "$SUMMARY"
    done
}

build_both() {
    local idx="$1" profile="$2"
    local l1="$RESULT_ROOT/logs/build_idex_${idx}_${profile}.log"
    local l2="$RESULT_ROOT/logs/build_tinyman_${idx}_${profile}.log"
    local p1 p2 r1=0 r2=0

    echo "BUILD $idx $profile on idex + tinyman"
    (cd "$HERE" && P5_BUILD_REUSE=1 bash "$BUILD_HELPER" "$profile" >"$l1" 2>&1) &
    p1=$!
    ssh -n root@"$CLIENT_HOST" "cd '$HERE' && P5_BUILD_REUSE=1 bash '$BUILD_HELPER' '$profile'" >"$l2" 2>&1 &
    p2=$!
    wait "$p1" || r1=$?
    wait "$p2" || r2=$?

    if (( r1 != 0 || r2 != 0 )); then
        echo "BUILD FAILED $idx $profile: idex=$r1 tinyman=$r2"
        echo "--- IDEX BUILD TAIL ---"
        tail -100 "$l1" || true
        echo "--- TINYMAN BUILD TAIL ---"
        tail -100 "$l2" || true
        return 20
    fi

    echo "BUILD PASS $idx $profile"
    grep -E 'P5 ring build:|P5 RING BUILD PASS|BASE:|RING_PROFILE:' "$l1" | tail -10 || true
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
    if m:
        results[m.group(1).lower()] = float(m.group(2))
with open(out, "a") as f:
    for mode in ("off", "basic", "plus"):
        value = results.get(mode)
        f.write(f"{idx}\t{profile}\t{mode}\t{'NA' if value is None else f'{value:.6f}'}\t{rc}\n")
print(f"{idx} {profile}")
for mode in ("off", "basic", "plus"):
    value = results.get(mode)
    print(f"  {mode.upper():5s}: {'NA' if value is None else f'{value:.6f} Gbit/s'}")
PY
}

run_one() {
    local idx="$1" profile="$2"
    local out="$MATRIX_ROOT/${idx}_${profile}"
    local log="$RESULT_ROOT/logs/run_${idx}_${profile}.log"
    local brc=0 rrc=0

    if ! selected "$profile"; then
        echo "SKIP $idx $profile (disabled by P5_RING_TESTS=$TESTS)"
        return 0
    fi

    echo
    echo "======================================================================"
    echo "RUN $idx $profile"
    echo "BASE: cache128 ONLY"
    echo "ONE RING EXPERIMENT: $profile"
    echo "======================================================================"

    clean_local
    clean_remote

    set +e
    build_both "$idx" "$profile"
    brc=$?
    set -e
    if (( brc != 0 )); then
        append_na "$idx" "$profile" "$brc"
        FAILURES=$((FAILURES + 1))
        return 0
    fi

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
    if (( rrc != 0 )); then
        echo "RUN FAILED $idx $profile rc=$rrc"
        tail -100 "$log" || true
        FAILURES=$((FAILURES + 1))
    fi
}

echo "======================================================================"
echo "P5 CACHE128 TX-RING INVESTIGATION"
echo "Fixed baseline: cache128, native pools/descriptors, no retry/checksum/lockfree/counters/rxalloc feature."
echo "Exactly one ring property is changed per profile."
echo "GreenQUIC and GreenQUIC+ policy is unchanged."
echo "P5_RING_TESTS=$TESTS"
echo "downloads/mode=$DOWNLOADS, gap=5 s, old charts, GQ_LOG_LEVEL=0"
echo "======================================================================"
column -t -s $'\t' "$CONFIGS" 2>/dev/null || cat "$CONFIGS"

capture_topology

echo
echo "NUMA/topology captured in $TOPOLOGY"

echo
echo "REFERENCE cache128 from previous isolated run: OFF=8.978374 BASIC=8.649898 PLUS=9.190881 Gbit/s"

while IFS=$'\t' read -r idx profile kind ring_size tx_burst enqueue producer_sync dequeue; do
    [[ "$idx" == index ]] && continue
    run_one "$idx" "$profile"
    if selected "$profile"; then
        echo "COOLDOWN BETWEEN CONFIGS: 10 s"
        sleep 10
    fi
done < "$CONFIGS"

python3 - "$SUMMARY" "$TABLE" <<'PY'
import csv, sys
summary, out = sys.argv[1:]
rows = list(csv.DictReader(open(summary), delimiter="\t"))
configs = {}
for r in rows:
    key = (r["index"], r["profile"])
    try:
        v = float(r["goodput_gbps"])
    except Exception:
        v = None
    configs.setdefault(key, {})[r["mode"]] = (v, r["rc"])

control = None
for (idx, profile), d in configs.items():
    if profile == "control":
        control = {m: d.get(m, (None, ""))[0] for m in ("off", "basic", "plus")}
        break

fields = ["index", "profile", "off_gbps", "basic_gbps", "plus_gbps", "avg_gbps", "worst_gbps", "off_delta_pct", "basic_delta_pct", "plus_delta_pct", "avg_delta_pct", "rc"]
records = []
for (idx, profile), d in sorted(configs.items()):
    vals = {m: d.get(m, (None, ""))[0] for m in ("off", "basic", "plus")}
    rcs = {d.get(m, (None, "NA"))[1] for m in ("off", "basic", "plus")}
    good = [v for v in vals.values() if v is not None]
    avg = sum(good) / 3.0 if len(good) == 3 else None
    worst = min(good) if len(good) == 3 else None
    def delta(mode):
        if not control or vals[mode] is None or control.get(mode) in (None, 0): return None
        return (vals[mode] / control[mode] - 1.0) * 100.0
    control_avg = None
    if control and all(control.get(m) is not None for m in ("off", "basic", "plus")):
        control_avg = sum(control[m] for m in ("off", "basic", "plus")) / 3.0
    avg_delta = None if avg is None or control_avg in (None, 0) else (avg / control_avg - 1.0) * 100.0
    def fmt(v): return "NA" if v is None else f"{v:.6f}"
    records.append({
        "index": idx, "profile": profile,
        "off_gbps": fmt(vals["off"]), "basic_gbps": fmt(vals["basic"]), "plus_gbps": fmt(vals["plus"]),
        "avg_gbps": fmt(avg), "worst_gbps": fmt(worst),
        "off_delta_pct": fmt(delta("off")), "basic_delta_pct": fmt(delta("basic")), "plus_delta_pct": fmt(delta("plus")),
        "avg_delta_pct": fmt(avg_delta), "rc": ",".join(sorted(rcs)),
    })
with open(out, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=fields, delimiter="\t")
    w.writeheader(); w.writerows(records)

valid = []
for r in records:
    try:
        valid.append((float(r["avg_gbps"]), float(r["worst_gbps"]), r["profile"]))
    except Exception:
        pass
if valid:
    best_avg = max(valid)
    best_worst = max(valid, key=lambda x: (x[1], x[0]))
    print(f"BEST_AVG profile={best_avg[2]} avg={best_avg[0]:.6f} worst={best_avg[1]:.6f}")
    print(f"BEST_WORST profile={best_worst[2]} avg={best_worst[0]:.6f} worst={best_worst[1]:.6f}")
PY

echo
echo "======================================================================"
echo "FINAL RING COMPARISON TABLE"
echo "Deltas are versus this run's cache128/current-ring control."
echo "======================================================================"
column -t -s $'\t' "$TABLE" 2>/dev/null || cat "$TABLE"

echo
echo "======================================================================"
echo "RAW GOODPUT"
echo "======================================================================"
column -t -s $'\t' "$SUMMARY" 2>/dev/null || cat "$SUMMARY"

echo
echo "RESULT_ROOT=$RESULT_ROOT"
echo "MATRIX_ROOT=$MATRIX_ROOT"
echo "TOPOLOGY=$TOPOLOGY"
echo "SUMMARY=$SUMMARY"
echo "TABLE=$TABLE"
echo "FAILURES=$FAILURES"
echo "======================================================================"

if (( FAILURES != 0 )); then
    exit 1
fi
