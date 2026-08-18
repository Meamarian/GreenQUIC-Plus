#!/usr/bin/env bash
set -Eeuo pipefail
BRANCH=performance2/p5-multicore
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
SHA="$(git -C "$REPO" rev-parse HEAD)"
CUR="$(git -C "$REPO" branch --show-current)"
TAG="${P5_ONECORE_TAG:-$(date +%Y%m%d_%H%M%S)}"
P5=/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads
OUT="$P5/matrix_results/P5_ONECORE_RESEARCH_${TAG}"
REMOTE_SCRIPT="/tmp/P5_ONECORE_${TAG}.sh"
REMOTE_LOG="/root/P5_ONECORE_${TAG}.log"
REMOTE_DONE="/tmp/P5_ONECORE_${TAG}.DONE"
REMOTE_RC="/tmp/P5_ONECORE_${TAG}.RC"
REMOTE_TAR="/root/P5_ONECORE_${TAG}.tar.gz"
SSH=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3)
[[ "$CUR" == "$BRANCH" ]] || { echo "ERROR: branch=$CUR expected=$BRANCH" >&2; exit 2; }
[[ -z "$(git -C "$REPO" status --porcelain --untracked-files=no)" ]] || { echo 'ERROR: tracked local changes present' >&2; exit 2; }

BASE_CLEAN="$HERE/safe_cleanup_greenquic_processes.py"; BN_CLEAN="$HERE/safe_cleanup_p5_bottleneck_processes.py"
for f in "$BASE_CLEAN" "$BN_CLEAN"; do [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 2; }; done

# Safe cleanup before changing remote refs.
CDIR="/tmp/gq_onecore_clean_${TAG}"
ssh "${SSH[@]}" idex "mkdir -p '$CDIR'"
scp "${SSH[@]}" "$BASE_CLEAN" "$BN_CLEAN" "idex:$CDIR/"
ssh "${SSH[@]}" idex "ssh -o BatchMode=yes root@tinyman 'mkdir -p $CDIR'; scp -q '$CDIR/'*.py root@tinyman:'$CDIR/'"
ssh "${SSH[@]}" idex "python3 '$CDIR/safe_cleanup_p5_bottleneck_processes.py' && python3 '$CDIR/safe_cleanup_p5_bottleneck_processes.py' --check"
ssh "${SSH[@]}" idex "ssh -o BatchMode=yes root@tinyman \"python3 '$CDIR/safe_cleanup_p5_bottleneck_processes.py' && python3 '$CDIR/safe_cleanup_p5_bottleneck_processes.py' --check\""

# Exact Mac commit -> IDEX -> Tinyman via git bundle.
BUNDLE="$(mktemp "${TMPDIR:-/tmp}/gq_onecore.XXXXXX.bundle")"; trap 'rm -f "$BUNDLE"' EXIT
RB="/tmp/gq_onecore_${TAG}.bundle"
git -C "$REPO" bundle create "$BUNDLE" "$BRANCH"
scp "${SSH[@]}" "$BUNDLE" "idex:$RB"
ssh "${SSH[@]}" idex "cd /root/mohsen && git reset --hard && git fetch '$RB' '$BRANCH' && git checkout -B '$BRANCH' FETCH_HEAD && git reset --hard FETCH_HEAD && scp -q '$RB' root@tinyman:'$RB'"
ssh "${SSH[@]}" idex "ssh -o BatchMode=yes root@tinyman \"cd /root/mohsen && git reset --hard && git fetch '$RB' '$BRANCH' && git checkout -B '$BRANCH' FETCH_HEAD && git reset --hard FETCH_HEAD\""
ISHA="$(ssh "${SSH[@]}" idex 'cd /root/mohsen && git rev-parse HEAD')"
TSHA="$(ssh "${SSH[@]}" idex 'ssh -o BatchMode=yes root@tinyman "cd /root/mohsen && git rev-parse HEAD"')"
[[ "$ISHA" == "$SHA" && "$TSHA" == "$SHA" ]] || { echo "ERROR: SHA local=$SHA idex=$ISHA tinyman=$TSHA" >&2; exit 2; }
echo "SYNC PASS both endpoints @ $SHA"

PREFLIGHT="cd '$P5' && bash -n ./run_p5_claim_proof_suite.sh ./run_p5_gap_causality_suite.sh ./run_p5_tx_pacing_probe_suite.sh ./build_p5_11g_candidate.sh ./run_p5_11g_target_suite.sh ./run_p5_onecore_research_suite.sh && python3 -m py_compile ./enable_p5_claim_recording_gate.py ./analyze_p5_claim_proof.py ./analyze_p5_gap_causality.py ./apply_p5_tx_pacing_probe.py ./summarize_p5_tx_pacing_probe.py ./analyze_p5_11g_target.py ./make_p5_single_mode_controller.py && python3 ./enable_p5_claim_recording_gate.py --self-test && python3 ./apply_p5_tx_pacing_probe.py --self-test && python3 ./make_p5_single_mode_controller.py --self-test"
ssh "${SSH[@]}" idex "$PREFLIGHT"
ssh "${SSH[@]}" idex "ssh -o BatchMode=yes root@tinyman $(printf '%q' "$PREFLIGHT")"
echo 'ONE-CORE STATIC PREFLIGHT PASS on IDEX + Tinyman'

cat > /tmp/P5_ONECORE_REMOTE_$$.sh <<'REMOTE'
#!/usr/bin/env bash
set +e
P5="$1"; OUT="$2"; DONE="$3"; RCFILE="$4"; TAR="$5"; TAG="$6"; shift 6
rm -f "$DONE" "$RCFILE" "$TAR"
cd "$P5" || { echo 98 >"$RCFILE"; touch "$DONE"; exit 0; }
env P5_ONECORE_TAG="$TAG" P5_ONECORE_OUTPUT_ROOT="$OUT" "$@" bash ./run_p5_onecore_research_suite.sh
rc=$?
echo "$rc" >"$RCFILE"
[[ -d "$OUT" ]] && tar -C "$(dirname "$OUT")" -czf "$TAR" "$(basename "$OUT")"
touch "$DONE"
echo "P5 ONECORE REMOTE COMPLETE rc=$rc out=$OUT"
exit 0
REMOTE
bash -n /tmp/P5_ONECORE_REMOTE_$$.sh
scp "${SSH[@]}" /tmp/P5_ONECORE_REMOTE_$$.sh "idex:$REMOTE_SCRIPT"
rm -f /tmp/P5_ONECORE_REMOTE_$$.sh

ENVV=(
  "P5_ONECORE_STAGES=${P5_ONECORE_STAGES:-claim,gap,pacing,11g}"
  "P5_CLAIM_RUNS=${P5_CLAIM_RUNS:-2}" "P5_CLAIM_DOWNLOADS=${P5_CLAIM_DOWNLOADS:-3}"
  "P5_GAP_RUNS=${P5_GAP_RUNS:-1}" "P5_GAP_DOWNLOADS=${P5_GAP_DOWNLOADS:-3}"
  "P5_PACING_RUNS=${P5_PACING_RUNS:-1}" "P5_PACING_DOWNLOADS=${P5_PACING_DOWNLOADS:-3}"
  "P5_11G_SCREEN_RUNS=${P5_11G_SCREEN_RUNS:-1}" "P5_11G_SCREEN_DOWNLOADS=${P5_11G_SCREEN_DOWNLOADS:-3}"
  "P5_11G_VALIDATE_RUNS=${P5_11G_VALIDATE_RUNS:-6}" "P5_11G_VALIDATE_DOWNLOADS=${P5_11G_VALIDATE_DOWNLOADS:-6}"
  "P5_11G_TARGET_GBPS=${P5_11G_TARGET_GBPS:-11.0}"
)
QENV=''; printf -v QENV '%q ' "${ENVV[@]}"
LAUNCH="$(ssh "${SSH[@]}" idex "chmod 0700 '$REMOTE_SCRIPT'; nohup setsid bash '$REMOTE_SCRIPT' '$P5' '$OUT' '$REMOTE_DONE' '$REMOTE_RC' '$REMOTE_TAR' '$TAG' $QENV >'$REMOTE_LOG' 2>&1 </dev/null & echo REMOTE_PID=\$!")"
echo "$LAUNCH"
echo "TAG=$TAG"
echo "COMMIT=$SHA"
echo "REMOTE_LOG=$REMOTE_LOG"
echo "REMOTE_RESULTS=$OUT"
echo "REMOTE_ARCHIVE=$REMOTE_TAR"
echo
echo 'Remote experiment is detached; closing the Mac or this SSH session will not stop it.'
echo "MONITOR: ssh idex \"tail -n +1 -F '$REMOTE_LOG'\""
echo "STATUS:  ssh idex \"cat '$REMOTE_RC' 2>/dev/null; test -f '$REMOTE_DONE' && echo DONE || echo RUNNING\""
echo "COPY:    scp idex:'$REMOTE_TAR' ~/Downloads/"
