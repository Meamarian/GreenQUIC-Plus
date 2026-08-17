#!/usr/bin/env bash
set -Eeuo pipefail

BRANCH=performance2/p5-multicore
RUNS="${P5_MC_RUNS:-2}"
CONNECTIONS="${P5_MC_CONNECTIONS:-4}"
TAG="${P5_MC_TAG:-$(date +%Y%m%d_%H%M%S)}"
ROOT=/root/mohsen/greenquic_test_suite_v22/test_cases/pretests
P5="$ROOT/P5_repeated_8GiB_downloads"
P7="$ROOT/P7_linux_udp_baseline"
P5_MATRIX="$P5/matrix_results/P5_PARALLEL_MC_${CONNECTIONS}c_${RUNS}r_${TAG}"
P7_MATRIX="$P7/matrix_results/P7_PARALLEL_MC_${CONNECTIONS}c_${RUNS}r_${TAG}"
REMOTE_RUNNER="/tmp/P5_P7_MC_${TAG}.sh"
REMOTE_LOG="/root/P5_P7_MC_${TAG}.log"
REMOTE_STATE="/tmp/P5_P7_MC_${TAG}.state"
REMOTE_SUMMARY="/tmp/P5_P7_MC_${TAG}_goodput_all_cases.tsv"
LOCAL_LOG="$HOME/Downloads/P5_P7_MC_${TAG}.mac.log"
LOCAL_EXPORT="$HOME/Downloads/P5_P7_MC_EXPORT_${TAG}"
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
    echo "STARTED P5+P7 PARALLEL MULTICORE V4 PID=$pid"
    echo "TAG=$TAG"
    echo "MAC_LOG=$LOCAL_LOG"
    echo "FINAL_EXPORT=$LOCAL_EXPORT"
    echo "The long experiment runs detached on idex; Mac->idex SSH loss cannot kill it after remote launch."
    exit 0
fi
[[ "${1:-}" == "--foreground" ]] && shift || true
[[ $# -eq 0 ]] || { echo "ERROR: unknown arguments: $*" >&2; exit 2; }

# The Mac checkout is the source of truth. Neither idex nor tinyman needs GitHub credentials.
LOCAL_REPO="$(git rev-parse --show-toplevel)"
LOCAL_SHA="$(git -C "$LOCAL_REPO" rev-parse HEAD)"
LOCAL_BRANCH="$(git -C "$LOCAL_REPO" branch --show-current)"
[[ "$LOCAL_BRANCH" == "$BRANCH" ]] || { echo "ERROR: local branch is $LOCAL_BRANCH, expected $BRANCH" >&2; exit 2; }
[[ -z "$(git -C "$LOCAL_REPO" status --porcelain --untracked-files=no)" ]] || { echo "ERROR: tracked local changes present; commit/stash them before running" >&2; exit 2; }

BUNDLE="$(mktemp "${TMPDIR:-/tmp}/greenquic_mc.XXXXXX.bundle")"
REMOTE_BUNDLE="/tmp/greenquic_mc_${TAG}.bundle"
trap 'rm -f "$BUNDLE" "${TMP:-}"' EXIT
git -C "$LOCAL_REPO" bundle create "$BUNDLE" "$BRANCH"

sync_idex(){
    retry scp "${SSH[@]}" "$BUNDLE" "idex:$REMOTE_BUNDLE"
    retry ssh "${SSH[@]}" idex "cd /root/mohsen && git reset --hard && git fetch '$REMOTE_BUNDLE' '$BRANCH' && git checkout -B '$BRANCH' FETCH_HEAD && git reset --hard FETCH_HEAD"
}
sync_tinyman(){
    retry ssh "${SSH[@]}" idex "scp -o ConnectTimeout=15 '$REMOTE_BUNDLE' root@tinyman:'$REMOTE_BUNDLE'"
    retry ssh "${SSH[@]}" idex "ssh -o ConnectTimeout=15 root@tinyman \"cd /root/mohsen && git reset --hard && git fetch '$REMOTE_BUNDLE' '$BRANCH' && git checkout -B '$BRANCH' FETCH_HEAD && git reset --hard FETCH_HEAD\""
}
sync_idex
sync_tinyman
IDEX_SHA="$(ssh "${SSH[@]}" idex 'cd /root/mohsen && git rev-parse HEAD')"
TINY_SHA="$(ssh "${SSH[@]}" idex "ssh -o ConnectTimeout=15 root@tinyman 'cd /root/mohsen && git rev-parse HEAD'")"
[[ "$IDEX_SHA" == "$LOCAL_SHA" && "$TINY_SHA" == "$LOCAL_SHA" ]] || { echo "ERROR: commit mismatch local=$LOCAL_SHA idex=$IDEX_SHA tinyman=$TINY_SHA" >&2; exit 2; }
log "Mac + idex + tinyman synced to $BRANCH @ $LOCAL_SHA"

retry ssh "${SSH[@]}" idex "cd '$P5' && bash ./run_parallel_multicore_matrix.sh --controller-preflight --runs '$RUNS' --connections '$CONNECTIONS'"
retry ssh "${SSH[@]}" idex "cd '$P7' && bash ./run_parallel_multicore_matrix.sh --controller-preflight --runs '$RUNS' --connections '$CONNECTIONS'"
log "P5 + P7 multicore controller preflight PASS"

TMP="$(mktemp "${TMPDIR:-/tmp}/p5_p7_mc_remote.XXXXXX")"
cat >"$TMP" <<'REMOTE'
#!/usr/bin/env bash
set +e
P5="$1"; P7="$2"; P5_MATRIX="$3"; P7_MATRIX="$4"; RUNS="$5"; CONNECTIONS="$6"; STATE="$7"; SUMMARY="$8"
rm -f "$STATE.DONE" "$STATE.FAIL" "$SUMMARY"
cd "$P5" || exit 90
bash ./run_parallel_multicore_matrix.sh --runs "$RUNS" --connections "$CONNECTIONS" --output-dir "$P5_MATRIX"
P5RC=$?
if [[ $P5RC -ne 0 ]]; then echo "P5:$P5RC" > "$STATE.FAIL"; exit "$P5RC"; fi
sleep 10
cd "$P7" || exit 91
bash ./run_parallel_multicore_matrix.sh --runs "$RUNS" --connections "$CONNECTIONS" --output-dir "$P7_MATRIX"
P7RC=$?
if [[ $P7RC -ne 0 ]]; then echo "P7:$P7RC" > "$STATE.FAIL"; exit "$P7RC"; fi
python3 - "$P5_MATRIX/parallel_tables/parallel_goodput_summary.csv" "$P7_MATRIX/parallel_tables/parallel_goodput_summary.csv" "$SUMMARY" <<'PY'
import csv,sys
p5,p7,out=sys.argv[1:]
rows=list(csv.DictReader(open(p7,newline='',encoding='utf-8'))) + list(csv.DictReader(open(p5,newline='',encoding='utf-8')))
by={r['mode'].lower():r for r in rows}
order=('linux','off','basic','plus')
missing=[m for m in order if m not in by]
if missing: raise SystemExit('missing cases: '+','.join(missing))
linux=float(by['linux']['mean_goodput_gbps']); off=float(by['off']['mean_goodput_gbps'])
fields=['case','n','mean_goodput_gbps','stdev_goodput_gbps','variance_goodput_gbps2','min_goodput_gbps','max_goodput_gbps','delta_vs_linux_pct','delta_vs_off_pct']
with open(out,'w',newline='',encoding='utf-8') as f:
 w=csv.DictWriter(f,fieldnames=fields,delimiter='\t'); w.writeheader()
 for mode in order:
  r=by[mode]; mean=float(r['mean_goodput_gbps'])
  w.writerow({'case':mode.upper(),'n':r['n'],'mean_goodput_gbps':f'{mean:.6f}','stdev_goodput_gbps':f"{float(r['stdev_goodput_gbps']):.6f}",'variance_goodput_gbps2':f"{float(r['variance_goodput_gbps2']):.6f}",'min_goodput_gbps':f"{float(r['min_goodput_gbps']):.6f}",'max_goodput_gbps':f"{float(r['max_goodput_gbps']):.6f}",'delta_vs_linux_pct':f'{((mean/linux)-1)*100:.3f}' if linux else 'nan','delta_vs_off_pct':f'{((mean/off)-1)*100:.3f}' if off else 'nan'})
print('\nFINAL GOODPUT SUMMARY: LINUX vs OFF vs BASIC vs PLUS')
print(open(out,encoding='utf-8').read(),end='')
PY
SRC=$?
if [[ $SRC -ne 0 ]]; then echo "SUMMARY:$SRC" > "$STATE.FAIL"; exit "$SRC"; fi
touch "$STATE.DONE"
REMOTE
bash -n "$TMP"
retry scp "${SSH[@]}" "$TMP" "idex:$REMOTE_RUNNER"
retry ssh "${SSH[@]}" idex "chmod +x '$REMOTE_RUNNER'; nohup setsid bash '$REMOTE_RUNNER' '$P5' '$P7' '$P5_MATRIX' '$P7_MATRIX' '$RUNS' '$CONNECTIONS' '$REMOTE_STATE' '$REMOTE_SUMMARY' >'$REMOTE_LOG' 2>&1 </dev/null & echo REMOTE_PID=\$!"
log "detached P5+P7 multicore suite started on idex"
while true; do
    if ssh "${SSH[@]}" idex "test -f '$REMOTE_STATE.DONE'" >/dev/null 2>&1; then break; fi
    if ssh "${SSH[@]}" idex "test -f '$REMOTE_STATE.FAIL'" >/dev/null 2>&1; then
        echo "ERROR: remote suite failed" >&2
        ssh "${SSH[@]}" idex "cat '$REMOTE_STATE.FAIL'; tail -160 '$REMOTE_LOG'" >&2 || true
        exit 1
    fi
    log "waiting; temporary Mac->idex SSH loss is harmless"
    sleep 60
done
mkdir -p "$LOCAL_EXPORT/P5" "$LOCAL_EXPORT/P7"
retry scp "${SSH[@]}" "idex:$REMOTE_SUMMARY" "$LOCAL_EXPORT/goodput_all_cases.tsv"
for rel in parallel_tables/parallel_goodput_summary.csv parallel_tables/parallel_goodput_all_runs.csv parallel_tables/parallel_active_summary.csv parallel_queue_activity.json PARALLEL_MULTICORE_CONFIG.txt; do retry scp "${SSH[@]}" "idex:$P5_MATRIX/$rel" "$LOCAL_EXPORT/P5/$(basename "$rel")"; done
for rel in parallel_tables/parallel_goodput_summary.csv parallel_tables/parallel_goodput_all_runs.csv parallel_tables/parallel_active_summary.csv PARALLEL_MULTICORE_CONFIG.txt; do retry scp "${SSH[@]}" "idex:$P7_MATRIX/$rel" "$LOCAL_EXPORT/P7/$(basename "$rel")"; done
retry scp "${SSH[@]}" "idex:$REMOTE_LOG" "$LOCAL_EXPORT/remote.log"
log "COMPLETE"
log "P5_MATRIX=$P5_MATRIX"
log "P7_MATRIX=$P7_MATRIX"
log "EXPORT=$LOCAL_EXPORT"
echo
echo "FINAL GOODPUT SUMMARY"
cat "$LOCAL_EXPORT/goodput_all_cases.tsv"
echo
python3 - "$LOCAL_EXPORT/P5/parallel_queue_activity.json" <<'PY'
import json,sys
j=json.load(open(sys.argv[1],encoding='utf-8'))
print('P5 DPDK MULTICORE VALIDATION:',j.get('status','UNKNOWN'))
if j.get('status')!='PASS': raise SystemExit(1)
PY
