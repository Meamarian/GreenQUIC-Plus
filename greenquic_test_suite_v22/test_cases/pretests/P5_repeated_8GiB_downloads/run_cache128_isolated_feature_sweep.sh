#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
STAMP="${STAMP:-$(date +%Y%m%d_%H%M%S)}"
CLIENT_HOST="${CLIENT_HOST:-tinyman}"
RESULT_ROOT="${RESULT_ROOT:-/tmp/P5_CACHE128_ISOLATED_${STAMP}}"
MATRIX_ROOT="$HERE/matrix_results/P5_CACHE128_ISOLATED_${STAMP}"
SUMMARY="$RESULT_ROOT/goodput_summary.tsv"
TABLE="$RESULT_ROOT/comparison_table.tsv"
CONFIGS="$RESULT_ROOT/configs.tsv"
MASTER="$RESULT_ROOT/master.log"
COUNTERS_OUT="$RESULT_ROOT/counter_diagnostics.txt"
BUILD_HELPER="$HERE/build_p5_cache128_feature.sh"
mkdir -p "$RESULT_ROOT/logs" "$MATRIX_ROOT"

cat > "$CONFIGS" <<'EOF'
index	profile	feature	cache	rxpool	txpool	rxd	txd	rxb	txb	ring
00	cache128_control	control	128	16383	16383	4096	4096	32	32	4096
01	cache128_txretry1	txretry1	128	16383	16383	4096	4096	32	32	4096
02	cache128_udpcksum	udpcksum	128	16383	16383	4096	4096	32	32	4096
03	cache128_lockfree	lockfree	128	16383	16383	4096	4096	32	32	4096
04	cache128_counters	counters	128	16383	16383	4096	4096	32	32	4096
05	cache128_rxalloc4	rxalloc4	128	16383	16383	4096	4096	32	32	4096
EOF
printf 'index\tprofile\tfeature\tmode\tgoodput_gbps\trc\n' > "$SUMMARY"
: > "$COUNTERS_OUT"
exec > >(tee -a "$MASTER") 2>&1

FAILURES=0

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

append_na() {
    local idx="$1" profile="$2" feature="$3" rc="$4"
    for mode in off basic plus; do
        printf '%s\t%s\t%s\t%s\tNA\t%s\n' "$idx" "$profile" "$feature" "$mode" "$rc" >> "$SUMMARY"
    done
}

build_both() {
    local idx="$1" profile="$2" feature="$3"
    local l1="$RESULT_ROOT/logs/build_idex_${idx}_${profile}.log"
    local l2="$RESULT_ROOT/logs/build_tinyman_${idx}_${profile}.log"
    local p1 p2 r1=0 r2=0

    echo
    echo "BUILD $idx $profile feature=$feature on idex + tinyman"
    (cd "$HERE" && P5_BUILD_REUSE=1 bash "$BUILD_HELPER" "$feature" >"$l1" 2>&1) &
    p1=$!
    ssh -n root@"$CLIENT_HOST" \
        "cd '$HERE' && P5_BUILD_REUSE=1 bash '$BUILD_HELPER' '$feature'" \
        >"$l2" 2>&1 &
    p2=$!
    wait "$p1" || r1=$?
    wait "$p2" || r2=$?

    if (( r1 != 0 || r2 != 0 )); then
        echo "BUILD FAILED $idx $profile: idex=$r1 tinyman=$r2"
        echo "--- IDEX BUILD TAIL ---"
        tail -80 "$l1" || true
        echo "--- TINYMAN BUILD TAIL ---"
        tail -80 "$l2" || true
        return 20
    fi

    echo "BUILD PASS $idx $profile"
    grep -E 'P5 isolated build:|P5 ISOLATED BUILD PASS|BASE:|FEATURE:' "$l1" | tail -10 || true
    return 0
}

extract_run() {
    local idx="$1" profile="$2" feature="$3" log="$4" rc="$5"
    python3 - "$idx" "$profile" "$feature" "$log" "$rc" "$SUMMARY" <<'PY'
import re, sys
from pathlib import Path
idx, profile, feature, log, rc, out = sys.argv[1:]
text = Path(log).read_text(errors="replace") if Path(log).exists() else ""
results = {}
for line in text.splitlines():
    m = re.search(
        r"\[MODE=(off|basic|plus)\].*?Aggregate goodput excluding gaps:\s*([0-9.]+)\s*Gbit/s",
        line,
        re.I,
    )
    if m:
        results[m.group(1).lower()] = float(m.group(2))
with open(out, "a") as f:
    for mode in ("off", "basic", "plus"):
        value = results.get(mode)
        f.write(
            f"{idx}\t{profile}\t{feature}\t{mode}\t"
            f"{'NA' if value is None else f'{value:.6f}'}\t{rc}\n"
        )
print(f"{idx} {profile} feature={feature}")
for mode in ("off", "basic", "plus"):
    value = results.get(mode)
    print(f"  {mode.upper():5s}: {'NA' if value is None else f'{value:.6f} Gbit/s'}")
PY
}

run_one() {
    local idx="$1" profile="$2" feature="$3"
    local out="$MATRIX_ROOT/${idx}_${profile}"
    local log="$RESULT_ROOT/logs/run_${idx}_${profile}.log"
    local brc=0 rrc=0

    echo
    echo "======================================================================"
    echo "RUN $idx $profile"
    echo "BASE: cache128 ONLY"
    echo "ONLY ADDITIONAL FEATURE: $feature"
    echo "======================================================================"

    clean_local
    clean_remote

    set +e
    build_both "$idx" "$profile" "$feature"
    brc=$?
    set -e

    if (( brc != 0 )); then
        append_na "$idx" "$profile" "$feature" "$brc"
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
    rrc=$?
    set -e

    extract_run "$idx" "$profile" "$feature" "$log" "$rrc"

    if [[ "$feature" == counters ]]; then
        {
            echo "=== $idx $profile COUNTER DIAGNOSTICS ==="
            grep -F '[GreenQUIC-P5-ISO-COUNTERS]' "$log" || true
            echo
        } >> "$COUNTERS_OUT"
    fi

    if (( rrc != 0 )); then
        echo "RUN FAILED $idx $profile rc=$rrc"
        tail -100 "$log" || true
        FAILURES=$((FAILURES + 1))
    fi
}

echo "======================================================================"
echo "P5 CACHE128 — ONE FEATURE AT A TIME"
echo "NO static combination: pool remains native 16383/16383."
echo "Each optional feature is built separately and NEVER combined with another."
echo "GreenQUIC and GreenQUIC+ policy is unchanged."
echo "3 downloads/mode; 5 s gaps; old charts; GQ_LOG_LEVEL=0"
echo "6 configs x 3 modes x 3 downloads = 54 downloads"
echo "======================================================================"
column -t -s $'\t' "$CONFIGS" 2>/dev/null || cat "$CONFIGS"

echo
echo "REFERENCE FROM PREVIOUS STATIC SWEEP"
echo "cache128: OFF=8.956036 BASIC=8.813568 PLUS=9.743661 Gbit/s"

while IFS=$'\t' read -r idx profile feature cache rxpool txpool rxd txd rxb txb ring; do
    [[ "$idx" == index ]] && continue
    run_one "$idx" "$profile" "$feature"
    if [[ "$idx" != 05 ]]; then
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
    key = (r["index"], r["profile"], r["feature"])
    try:
        v = float(r["goodput_gbps"])
    except Exception:
        v = None
    configs.setdefault(key, {})[r["mode"]] = (v, r["rc"])

control = None
for (idx, profile, feature), d in configs.items():
    if feature == "control":
        control = {m: d.get(m, (None, ""))[0] for m in ("off", "basic", "plus")}
        break

fields = [
    "index", "profile", "feature",
    "off_gbps", "basic_gbps", "plus_gbps", "avg_gbps", "worst_gbps",
    "off_delta_pct", "basic_delta_pct", "plus_delta_pct", "avg_delta_pct", "rc",
]
with open(out, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=fields, delimiter="\t")
    w.writeheader()
    for (idx, profile, feature), d in sorted(configs.items()):
        vals = {m: d.get(m, (None, ""))[0] for m in ("off", "basic", "plus")}
        rcs = {d.get(m, (None, "NA"))[1] for m in ("off", "basic", "plus")}
        rc = ",".join(sorted(rcs))
        good = [v for v in vals.values() if v is not None]
        avg = sum(good) / 3.0 if len(good) == 3 else None
        worst = min(good) if len(good) == 3 else None
        def fmt(v): return "NA" if v is None else f"{v:.6f}"
        def delta(mode):
            if not control or vals[mode] is None or control.get(mode) in (None, 0): return None
            return (vals[mode] / control[mode] - 1.0) * 100.0
        control_avg = None
        if control and all(control.get(m) is not None for m in ("off", "basic", "plus")):
            control_avg = sum(control[m] for m in ("off", "basic", "plus")) / 3.0
        avg_delta = None if avg is None or control_avg in (None, 0) else (avg / control_avg - 1.0) * 100.0
        w.writerow({
            "index": idx,
            "profile": profile,
            "feature": feature,
            "off_gbps": fmt(vals["off"]),
            "basic_gbps": fmt(vals["basic"]),
            "plus_gbps": fmt(vals["plus"]),
            "avg_gbps": fmt(avg),
            "worst_gbps": fmt(worst),
            "off_delta_pct": fmt(delta("off")),
            "basic_delta_pct": fmt(delta("basic")),
            "plus_delta_pct": fmt(delta("plus")),
            "avg_delta_pct": fmt(avg_delta),
            "rc": rc,
        })
PY

echo
echo "======================================================================"
echo "FINAL COMPARISON TABLE"
echo "Deltas are versus this run's cache128 control."
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
echo "SUMMARY=$SUMMARY"
echo "TABLE=$TABLE"
echo "COUNTERS=$COUNTERS_OUT"
echo "FAILURES=$FAILURES"
echo "======================================================================"

if (( FAILURES != 0 )); then
    exit 1
fi
