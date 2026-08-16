#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
V3="$HERE/mac_chain_p1_resume_p2_best_and_sweep_v3.sh"
[[ -f "$V3" ]] || { echo "ERROR: missing $V3" >&2; exit 2; }
[[ -f "$HERE/run_p5_performance2_selected_profiles.sh" ]] || { echo "ERROR: missing selected-profile P2 runner" >&2; exit 2; }

if [[ "${1:-}" == "--detach" ]]; then
    shift
    TAG="${CHAIN_TAG:-$(date +%Y%m%d_%H%M%S)}"
    LOG="$HOME/Downloads/P5_P1_P2_CHAIN_V4_${TAG}.log"
    PIDFILE="$HOME/Downloads/P5_P1_P2_CHAIN_V4_${TAG}.pid"
    if [[ -f "$PIDFILE" ]]; then
        old="$(cat "$PIDFILE" 2>/dev/null || true)"
        if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
            echo "ERROR: V4 already alive PID=$old" >&2
            exit 70
        fi
    fi
    nohup caffeinate -dimsu env \
        GREENQUIC_REPO="${GREENQUIC_REPO:-$(git -C "$HERE" rev-parse --show-toplevel)}" \
        CHAIN_TAG="$TAG" \
        P5_P2_BEST_PROFILE="${P5_P2_BEST_PROFILE:-sharded_udp4}" \
        CHAIN_START_DELAY_SECONDS="${CHAIN_START_DELAY_SECONDS:-10}" \
        CHAIN_INTER_STAGE_DELAY_SECONDS="${CHAIN_INTER_STAGE_DELAY_SECONDS:-300}" \
        bash "$0" --foreground "$@" >"$LOG" 2>&1 </dev/null &
    pid=$!
    echo "$pid" > "$PIDFILE"
    disown "$pid" 2>/dev/null || true
    echo "STARTED V4 PID=$pid"
    echo "TAG=$TAG"
    echo "LOG=$LOG"
    exit 0
fi

[[ "${1:-}" == "--foreground" ]] && shift || true

TMP="${TMPDIR:-/tmp}/greenquic_chain_v4_${CHAIN_TAG:-$$}_$$.sh"
cp "$V3" "$TMP"

python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()

def once(old: str, new: str, label: str) -> None:
    global s
    n = s.count(old)
    if n != 1:
        raise SystemExit(f"ERROR: V4 patch {label}: expected one match, got {n}")
    s = s.replace(old, new, 1)

once(
    "! -name SHA256SUMS -printf",
    "! -name SHA256SUMS ! -name SHA256SUMS.tmp -printf",
    "manifest temp exclusion",
)
once(
    'date -Is > "$localdir/SCP_DONE"',
    'date "+%Y-%m-%dT%H:%M:%S%z" > "$localdir/SCP_DONE"',
    "portable Mac date",
)
once(
    "for d in /tmp/P5_RESUME_EXPORT_* /tmp/P5_P7_FINAL_EXPORT_*; do [ -d \"$d\" ] && printf",
    "for d in /tmp/P5_RESUME_EXPORT_* /tmp/P5_P7_FINAL_EXPORT_* /tmp/P5_PERFORMANCE2_EXPORT_*; do [ -d \"$d\" ] && [ -f \"$d/DONE\" ] && printf",
    "completed previous export selection",
)

old_proc = "cmd=$(tr '\\\\0' ' ' < \"$p/cmdline\" 2>/dev/null || true)"
new_proc = "cmd=$(cat \"$p/cmdline\" 2>/dev/null | tr '\\\\0' ' ' || true)"
n = s.count(old_proc)
if n not in (0, 2):
    raise SystemExit(f"ERROR: V4 proc patch unexpected count={n}")
if n:
    s = s.replace(old_proc, new_proc)

lines = s.splitlines()
out = []
replaced_runner = 0
for line in lines:
    if 'P5_P2_TESTS=' in line and 'bash ./run_p5_performance2_sweep.sh' in line and 'RRC=' in line:
        replaced_runner += 1
        out.extend(r'''if [ "\$S1" -eq 0 ] && [ "\$S2" -eq 0 ] && [ "\$S3" -eq 0 ] && [ "\$S4" -eq 0 ]; then
    if [ "\$PHASE" = "BEST_\${PROFILE}" ]; then
        STAMP="\$STAMP" RESULT_ROOT="\$RESULT" MATRIX_ROOT="\$MATRIX" P5_P2_PROFILE="\$PROFILE" P5_P2_RUNS="\$RUNS" P5_P2_DOWNLOADS="\$DOWNLOADS" P5_P2_CHART_STYLE=both bash ./run_p5_performance2_selected_profiles.sh "\$PROFILE"
        RRC=\$?
    else
        STAMP="\$STAMP" RESULT_ROOT="\$RESULT" P5_P2_DOWNLOADS="\$DOWNLOADS" P5_P2_RUNS="\$RUNS" P5_P2_TESTS="\$PROFILE" bash ./run_p5_performance2_sweep.sh
        RRC=\$?
    fi
    printf 'RUNNER_RC=%s\nPROFILE=%s\nRUNS=%s\nDOWNLOADS=%s\n' "\$RRC" "\${PROFILE:-ALL_12}" "\$RUNS" "\$DOWNLOADS" >> "\$EX/result_rc.txt"
fi'''.replace('\\"', '"').replace('\\\\$', '\\$').splitlines())
    else:
        out.append(line)
if replaced_runner != 1:
    raise SystemExit(f"ERROR: V4 P2 runner patch expected one line, got {replaced_runner}")
s = "\n".join(out) + "\n"
p.write_text(s)
print("V4 PATCH PASS")
PY

bash -n "$TMP"
echo "V4 SYNTAX PASS"

cleanup(){ rm -f "$TMP"; }
trap cleanup EXIT INT TERM
exec bash "$TMP" "$@"
