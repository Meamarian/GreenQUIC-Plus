#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
BRANCH=performance2/p5-multicore
RUNS="${P5_MC_RUNS:-2}"
CONNECTIONS="${P5_MC_CONNECTIONS:-4}"
TAG="${P5_MC_TAG:-$(date +%Y%m%d_%H%M%S)}"
P5=/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads
MATRIX="$P5/matrix_results/P5_PARALLEL_MC_${CONNECTIONS}c_${RUNS}r_${TAG}"
REMOTE_RUNNER="/tmp/P5_MC_${TAG}.sh"
REMOTE_LOG="/root/P5_MC_${TAG}.log"
REMOTE_STATE="/tmp/P5_MC_${TAG}.state"
LOCAL_LOG="$HOME/Downloads/P5_MC_${TAG}.mac.log"
LOCAL_EXPORT="$HOME/Downloads/P5_MC_EXPORT_${TAG}"
SSH=(-o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3)

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
retry(){ local rc; while true; do if "$@"; then return 0; else rc=$?; fi; if ((rc==255)); then log "SSH/SCP transport lost; retrying in 30 s"; sleep 30; else return "$rc"; fi; done; }

[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: P5_MC_RUNS must be positive" >&2; exit 2; }
[[ "$CONNECTIONS" =~ ^[2-9][0-9]*$ ]] || { echo "ERROR: P5_MC_CONNECTIONS must be >=2" >&2; exit 2; }

if [[ "${1:-}" == "--detach" ]]; then
    shift
    nohup caffeinate -dimsu env P5_MC_RUNS="$RUNS" P5_MC_CONNECTIONS="$CONNECTIONS" P5_MC_TAG="$TAG" \
        bash "$0" --foreground >"$LOCAL_LOG" 2>&1 </dev/null &
    pid=$!; disown "$pid" 2>/dev/null || true
    echo "STARTED P5 MULTICORE V4 PID=$pid"
    echo "TAG=$TAG"
    echo "MAC_LOG=$LOCAL_LOG"
    echo "FINAL_EXPORT=$LOCAL_EXPORT"
    echo "Remote experiment is detached on idex; Mac->idex SSH loss cannot kill it."
    exit 0
fi
[[ "${1:-}" == "--foreground" ]] && shift || true
[[ $# -eq 0 ]] || { echo "ERROR: unknown arguments: $*" >&2; exit 2; }

# Put both hosts on the exact multicore branch before traffic.
retry ssh "${SSH[@]}" idex "cd /root/mohsen && git fetch origin '$BRANCH' && git checkout -B '$BRANCH' 'origin/$BRANCH' && git reset --hard 'origin/$BRANCH'"
retry ssh "${SSH[@]}" idex "ssh -o ConnectTimeout=15 root@tinyman \"cd /root/mohsen && git fetch origin '$BRANCH' && git checkout -B '$BRANCH' 'origin/$BRANCH' && git reset --hard 'origin/$BRANCH'\""
SHA="$(ssh "${SSH[@]}" idex 'cd /root/mohsen && git rev-parse HEAD')"
log "idex + tinyman synced to $BRANCH @ $SHA"

# Verify the nested controller patch before starting any NIC/traffic work.
retry ssh "${SSH[@]}" idex "cd '$P5' && bash ./run_parallel_multicore_matrix.sh --controller-preflight --runs '$RUNS' --connections '$CONNECTIONS'"
log "multicore controller preflight PASS"

TMP="$(mktemp -t p5_mc_remote.XXXXXX)"
trap 'rm -f "$TMP"' EXIT
cat >"$TMP" <<'REMOTE'
#!/usr/bin/env bash
set +e
P5="$1"; MATRIX="$2"; RUNS="$3"; CONNECTIONS="$4"; STATE="$5"
cd "$P5" || exit 90
rm -f "$STATE.DONE" "$STATE.FAIL"
bash ./run_parallel_multicore_matrix.sh --runs "$RUNS" --connections "$CONNECTIONS" --output-dir "$MATRIX"
rc=$?
if [[ $rc -eq 0 ]]; then
python3 - "$MATRIX/parallel_tables/parallel_goodput_summary.csv" "$MATRIX/parallel_tables/goodput_case_comparison.tsv" <<'PY'
import csv,sys
src,dst=sys.argv[1:]
rows=list(csv.DictReader(open(src,newline='',encoding='utf-8')))
by={r['mode']:r for r in rows}; off=float(by['off']['mean_goodput_gbps'])
fields=['case','n','mean_goodput_gbps','stdev_goodput_gbps','variance_goodput_gbps2','min_goodput_gbps','max_goodput_gbps','delta_vs_off_pct']
with open(dst,'w',newline='',encoding='utf-8') as f:
 w=csv.DictWriter(f,fieldnames=fields,delimiter='\t'); w.writeheader()
 for mode in ('off','basic','plus'):
  r=by[mode]; mean=float(r['mean_goodput_gbps'])
  w.writerow({'case':mode.upper(),'n':r['n'],'mean_goodput_gbps':f'{mean:.6f}','stdev_goodput_gbps':f"{float(r['stdev_goodput_gbps']):.6f}",'variance_goodput_gbps2':f"{float(r['variance_goodput_gbps2']):.6f}",'min_goodput_gbps':f"{float(r['min_goodput_gbps']):.6f}",'max_goodput_gbps':f"{float(r['max_goodput_gbps']):.6f}",'delta_vs_off_pct':f'{((mean/off)-1)*100:.3f}' if off else 'nan'})
print(open(dst,encoding='utf-8').read(),end='')
PY
 touch "$STATE.DONE"
else
 echo "$rc" > "$STATE.FAIL"
fi
exit "$rc"
REMOTE
bash -n "$TMP"
retry scp "${SSH[@]}" "$TMP" "idex:$REMOTE_RUNNER"

# The long-running matrix is a new session on idex, not a child of Mac SSH.
retry ssh "${SSH[@]}" idex "chmod +x '$REMOTE_RUNNER'; nohup setsid bash '$REMOTE_RUNNER' '$P5' '$MATRIX' '$RUNS' '$CONNECTIONS' '$REMOTE_STATE' >'$REMOTE_LOG' 2>&1 </dev/null & echo REMOTE_PID=\$!"
log "remote detached matrix started"

while true; do
    if ssh "${SSH[@]}" idex "test -f '$REMOTE_STATE.DONE'" >/dev/null 2>&1; then break; fi
    if ssh "${SSH[@]}" idex "test -f '$REMOTE_STATE.FAIL'" >/dev/null 2>&1; then
        echo "ERROR: remote matrix failed" >&2
        ssh "${SSH[@]}" idex "cat '$REMOTE_STATE.FAIL'; tail -120 '$REMOTE_LOG'" >&2 || true
        exit 1
    fi
    log "waiting; SSH loss from the Mac cannot kill the remote job"
    sleep 60
done

mkdir -p "$LOCAL_EXPORT"
for rel in \
 parallel_tables/parallel_goodput_summary.csv \
 parallel_tables/parallel_goodput_all_runs.csv \
 parallel_tables/goodput_case_comparison.tsv \
 parallel_tables/parallel_active_summary.csv \
 parallel_queue_activity.json \
 PARALLEL_MULTICORE_CONFIG.txt; do
    retry scp "${SSH[@]}" "idex:$MATRIX/$rel" "$LOCAL_EXPORT/$(basename "$rel")"
done
retry scp "${SSH[@]}" "idex:$REMOTE_LOG" "$LOCAL_EXPORT/remote.log"

log "COMPLETE"
log "MATRIX_ON_IDEX=$MATRIX"
log "EXPORT=$LOCAL_EXPORT"
echo
echo "FINAL GOODPUT COMPARISON"
cat "$LOCAL_EXPORT/goodput_case_comparison.tsv"
echo
python3 - "$LOCAL_EXPORT/parallel_queue_activity.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1],encoding='utf-8'))
print('MULTICORE VALIDATION:',j.get('status','UNKNOWN'))
if j.get('status')!='PASS': raise SystemExit(1)
for r in j.get('records',[]):
 print(f"{r['role']:6} rep{r['repetition']:02d} {r['mode']:5} rxq=({r['rxq0']},{r['rxq1']}) txq=({r['txq0']},{r['txq1']})")
PY
