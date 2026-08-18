#!/usr/bin/env bash
set -Eeuo pipefail
BRANCH=performance2/p5-multicore
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
SHA="$(git -C "$REPO" rev-parse HEAD)"
CUR="$(git -C "$REPO" branch --show-current)"
RUNS="${P5_ARCH_RUNS:-2}"; CONNS="${P5_ARCH_CONNECTIONS:-4}"; TAG="${P5_ARCH_TAG:-$(date +%Y%m%d_%H%M%S)}"
P5=/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads
OUT="$P5/matrix_results/P5_ARCH_BOTTLENECK_${CONNS}c_${RUNS}r_${TAG}"
REMOTE_SCRIPT="/tmp/P5_ARCH_${TAG}.sh"; REMOTE_LOG="/root/P5_ARCH_${TAG}.log"
REMOTE_DONE="/tmp/P5_ARCH_${TAG}.DONE"; REMOTE_RC="/tmp/P5_ARCH_${TAG}.RC"
REMOTE_TAR="/root/P5_ARCH_${TAG}.tar.gz"
SSH=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=20 -o ServerAliveCountMax=3)
[[ "$CUR" == "$BRANCH" ]] || { echo "ERROR: branch=$CUR expected=$BRANCH" >&2; exit 2; }
[[ "$RUNS" =~ ^[1-9][0-9]*$ && "$CONNS" =~ ^[2-9][0-9]*$ ]] || { echo 'ERROR: invalid P5_ARCH_RUNS/P5_ARCH_CONNECTIONS' >&2; exit 2; }
[[ -z "$(git -C "$REPO" status --porcelain --untracked-files=no)" ]] || { echo 'ERROR: tracked local changes present' >&2; exit 2; }
case "${1:-}" in ''|--detach|--foreground) ;; *) echo "ERROR: unknown option $1" >&2; exit 2;; esac

BASE_CLEAN="$HERE/safe_cleanup_greenquic_processes.py"; BN_CLEAN="$HERE/safe_cleanup_p5_bottleneck_processes.py"
for f in "$BASE_CLEAN" "$BN_CLEAN"; do [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 2; }; done

# Safe cleanup before remote checkout changes.
CDIR="/tmp/gq_arch_clean_${TAG}"; ssh "${SSH[@]}" idex "mkdir -p '$CDIR'"
scp "${SSH[@]}" "$BASE_CLEAN" "$BN_CLEAN" "idex:$CDIR/"
ssh "${SSH[@]}" idex "ssh -o BatchMode=yes root@tinyman 'mkdir -p $CDIR'; scp -q '$CDIR/'*.py root@tinyman:'$CDIR/'"
ssh "${SSH[@]}" idex "python3 '$CDIR/safe_cleanup_p5_bottleneck_processes.py' && python3 '$CDIR/safe_cleanup_p5_bottleneck_processes.py' --check"
ssh "${SSH[@]}" idex "ssh -o BatchMode=yes root@tinyman \"python3 '$CDIR/safe_cleanup_p5_bottleneck_processes.py' && python3 '$CDIR/safe_cleanup_p5_bottleneck_processes.py' --check\""

# Exact local branch bytes to both endpoints.
BUNDLE="$(mktemp "${TMPDIR:-/tmp}/gq_arch.XXXXXX.bundle")"; trap 'rm -f "$BUNDLE"' EXIT
RB="/tmp/gq_arch_${TAG}.bundle"; git -C "$REPO" bundle create "$BUNDLE" "$BRANCH"; scp "${SSH[@]}" "$BUNDLE" "idex:$RB"
ssh "${SSH[@]}" idex "cd /root/mohsen && git reset --hard && git fetch '$RB' '$BRANCH' && git checkout -B '$BRANCH' FETCH_HEAD && git reset --hard FETCH_HEAD && scp -q '$RB' root@tinyman:'$RB'"
ssh "${SSH[@]}" idex "ssh -o BatchMode=yes root@tinyman \"cd /root/mohsen && git reset --hard && git fetch '$RB' '$BRANCH' && git checkout -B '$BRANCH' FETCH_HEAD && git reset --hard FETCH_HEAD\""
ISHA="$(ssh "${SSH[@]}" idex 'cd /root/mohsen && git rev-parse HEAD')"; TSHA="$(ssh "${SSH[@]}" idex 'ssh -o BatchMode=yes root@tinyman "cd /root/mohsen && git rev-parse HEAD"')"
[[ "$ISHA" == "$SHA" && "$TSHA" == "$SHA" ]] || { echo "ERROR: SHA local=$SHA idex=$ISHA tinyman=$TSHA" >&2; exit 2; }
echo "SYNC PASS both endpoints @ $SHA"

# Traffic-free static preflight only. The sweep itself now prebuilds/caches all
# five binary profiles before A, so duplicating those full builds here would add
# no validation and would only waste time.
PREFLIGHT="cd '$P5' && bash -n ./run_p5_arch_bottleneck_sweep.sh ./run_p5_arch_case_diag.sh ./run_p5_arch_off_case.sh ./build_p5_arch_profile.sh && python3 -m py_compile ./enable_p5_arch_runtime_config.py ./enable_p5_arch_single_owner_validation.py ./apply_p5_arch_mbuf_pool.py ./verify_p5_arch_effective_config.py ./test_p5_performance2_transform.py ./test_p5_performance2_v2_transform.py && python3 ./test_p5_performance2_transform.py && python3 ./test_p5_performance2_v2_transform.py && python3 ./enable_p5_arch_runtime_config.py --self-test && python3 ./enable_p5_arch_single_owner_validation.py --self-test && python3 ./apply_p5_arch_mbuf_pool.py --self-test && bash ./run_p5_arch_off_case.sh --self-test"
ssh "${SSH[@]}" idex "$PREFLIGHT"
ssh "${SSH[@]}" idex "ssh -o BatchMode=yes root@tinyman $(printf '%q' "$PREFLIGHT")"
COUNT="$(ssh "${SSH[@]}" idex "cd '$P5' && grep -Ec '^run_case [A-P]_' ./run_p5_arch_bottleneck_sweep.sh")"
[[ "$COUNT" == 16 ]] || { echo "ERROR: expected 16 A-P cases, got $COUNT" >&2; exit 2; }
echo 'ARCH STATIC PREFLIGHT PASS: source-level mbuf pool + one-owner validation + 16 cases'

cat > /tmp/P5_ARCH_REMOTE_$$.sh <<'REMOTE'
#!/usr/bin/env bash
set +e
P5="$1"; RUNS="$2"; CONNS="$3"; TAG="$4"; OUT="$5"; DONE="$6"; RCFILE="$7"; TAR="$8"
rm -f "$DONE" "$RCFILE" "$TAR"
cd "$P5" || { echo 98 >"$RCFILE"; touch "$DONE"; exit 0; }
env P5_ARCH_RUNS="$RUNS" P5_ARCH_CONNECTIONS="$CONNS" P5_ARCH_TAG="$TAG" P5_ARCH_OUTPUT_ROOT="$OUT" bash ./run_p5_arch_bottleneck_sweep.sh
rc=$?; echo "$rc" >"$RCFILE"
[[ -d "$OUT" ]] && tar -C "$(dirname "$OUT")" -czf "$TAR" "$(basename "$OUT")"
touch "$DONE"; echo "P5 ARCH REMOTE COMPLETE rc=$rc out=$OUT"; exit 0
REMOTE
bash -n /tmp/P5_ARCH_REMOTE_$$.sh; scp "${SSH[@]}" /tmp/P5_ARCH_REMOTE_$$.sh "idex:$REMOTE_SCRIPT"; rm -f /tmp/P5_ARCH_REMOTE_$$.sh
LAUNCH="$(ssh "${SSH[@]}" idex "chmod 0700 '$REMOTE_SCRIPT'; nohup setsid bash '$REMOTE_SCRIPT' '$P5' '$RUNS' '$CONNS' '$TAG' '$OUT' '$REMOTE_DONE' '$REMOTE_RC' '$REMOTE_TAR' >'$REMOTE_LOG' 2>&1 </dev/null & echo REMOTE_PID=\$!")"
echo "$LAUNCH"; echo "TAG=$TAG"; echo "COMMIT=$SHA"; echo "REMOTE_LOG=$REMOTE_LOG"; echo "REMOTE_RESULTS=$OUT"; echo "REMOTE_ARCHIVE=$REMOTE_TAR"
echo 'All profile compilation happens inside the sweep before A; no compiler runs are allowed A-P. P reuses B baseline bytes.'
echo "MONITOR: ssh idex \"tail -n +1 -F '$REMOTE_LOG'\""
echo "STATUS:  ssh idex \"cat '$REMOTE_RC' 2>/dev/null; test -f '$REMOTE_DONE' && echo DONE || echo RUNNING\""
echo "COPY:    scp idex:'$REMOTE_TAR' ~/Downloads/"
