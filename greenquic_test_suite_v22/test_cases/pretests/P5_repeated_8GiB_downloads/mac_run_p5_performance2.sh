#!/usr/bin/env bash
set -Eeuo pipefail

BRANCH="performance2/p5-max-goodput"
DOWNLOADS="${P5_P2_DOWNLOADS:-3}"
RUNS="${P5_P2_RUNS:-1}"
TESTS="${P5_P2_TESTS:-}"

usage() {
    cat <<'EOF'
Usage:
  bash ./mac_run_p5_performance2.sh [--downloads N] [--runs N] [--tests comma,list]

Defaults: 1 run, 3 downloads, all performance2 profiles.
Examples:
  bash ./mac_run_p5_performance2.sh
  bash ./mac_run_p5_performance2.sh --tests baseline,sharded_1024,rx_prefetch,udp_seg4,all_p2
  bash ./mac_run_p5_performance2.sh --runs 3 --downloads 3
EOF
}

while (($#)); do
    case "$1" in
        --downloads) DOWNLOADS="${2:?missing value}"; shift 2 ;;
        --runs) RUNS="${2:?missing value}"; shift 2 ;;
        --tests) TESTS="${2:?missing value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
[[ "$DOWNLOADS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: downloads must be positive" >&2; exit 2; }
[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: runs must be positive" >&2; exit 2; }

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$HERE/../../../.." && pwd)"
P5="/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
STAMP="$(date +%Y%m%d_%H%M%S)"
BUNDLE="/tmp/GreenQUIC_P5_PERFORMANCE2_${STAMP}.bundle"
REMOTE_BUNDLE="$BUNDLE"
RESULT="/tmp/P5_PERFORMANCE2_${STAMP}"
LOCAL="$HOME/Downloads/P5_PERFORMANCE2_${STAMP}"
RUNNER="run_p5_performance2_sweep.sh"

cd "$REPO_ROOT"
trap 'rm -f "$BUNDLE"' EXIT

echo "======================================================================"
echo "P5 PERFORMANCE2"
echo "BRANCH=$BRANCH"
echo "RUNS=$RUNS DOWNLOADS=$DOWNLOADS TESTS=${TESTS:-all}"
echo "======================================================================"

if [ -n "$(git status --porcelain)" ]; then
    echo "Saving local Mac working-tree changes..."
    git stash push -u -m "pre-p5-performance2-${STAMP}"
fi

git fetch origin "$BRANCH"
EXPECTED="$(git rev-parse "origin/$BRANCH")"
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git checkout "$BRANCH"
else
    git checkout -b "$BRANCH" "origin/$BRANCH"
fi
git reset --hard "origin/$BRANCH"
git log -1 --format='MAC HEAD=%H%nSUBJECT=%s'

IDEX_HEAD="$(ssh idex 'git -C /root/mohsen rev-parse HEAD 2>/dev/null || true')"
TINY_HEAD="$(ssh idex 'ssh root@tinyman "git -C /root/mohsen rev-parse HEAD 2>/dev/null || true"' 2>/dev/null || true)"
BASE=""
if [ -n "$IDEX_HEAD" ] && [ "$IDEX_HEAD" = "$TINY_HEAD" ] && git cat-file -e "$IDEX_HEAD^{commit}" 2>/dev/null && git merge-base --is-ancestor "$IDEX_HEAD" "$EXPECTED"; then
    BASE="$IDEX_HEAD"
fi
rm -f "$BUNDLE"
if [ -n "$BASE" ]; then
    git bundle create "$BUNDLE" "$BRANCH" "^$BASE" || git bundle create "$BUNDLE" "$BRANCH"
else
    git bundle create "$BUNDLE" "$BRANCH"
fi
ls -lh "$BUNDLE"
scp "$BUNDLE" "idex:$REMOTE_BUNDLE"
ssh idex "scp '$REMOTE_BUNDLE' root@tinyman:'$REMOTE_BUNDLE'"

ssh idex "EXPECTED='$EXPECTED' BRANCH='$BRANCH' BUNDLE='$REMOTE_BUNDLE' bash -s" <<'REMOTE'
set -euo pipefail
cd /root/mohsen
git reset --hard
git fetch "$BUNDLE" "refs/heads/$BRANCH"
git checkout -B "$BRANCH" FETCH_HEAD
test "$(git rev-parse HEAD)" = "$EXPECTED"
git log -1 --format='IDEX HEAD=%H%nSUBJECT=%s'
REMOTE
ssh idex "ssh root@tinyman \"EXPECTED='$EXPECTED' BRANCH='$BRANCH' BUNDLE='$REMOTE_BUNDLE' bash -s\"" <<'REMOTE'
set -euo pipefail
cd /root/mohsen
git reset --hard
git fetch "$BUNDLE" "refs/heads/$BRANCH"
git checkout -B "$BRANCH" FETCH_HEAD
test "$(git rev-parse HEAD)" = "$EXPECTED"
git log -1 --format='TINYMAN HEAD=%H%nSUBJECT=%s'
REMOTE

ssh idex "cd '$P5' && bash -n ./build_p5_performance2.sh && bash -n ./$RUNNER && python3 -m py_compile ./apply_p5_performance2.py ./test_p5_performance2_transform.py && python3 ./test_p5_performance2_transform.py && echo 'IDEX P2 PREFLIGHT PASS'"
ssh idex "ssh root@tinyman \"cd '$P5' && bash -n ./build_p5_performance2.sh && python3 -m py_compile ./apply_p5_performance2.py ./test_p5_performance2_transform.py && python3 ./test_p5_performance2_transform.py && echo 'TINYMAN P2 PREFLIGHT PASS'\""

set +e
ssh idex "cd '$P5' && STAMP='$STAMP' P5_P2_DOWNLOADS='$DOWNLOADS' P5_P2_RUNS='$RUNS' P5_P2_TESTS='$TESTS' bash ./$RUNNER"
RUN_RC=$?
set -e

mkdir -p "$LOCAL"
scp -r "idex:${RESULT}/." "$LOCAL/" || true

echo "======================================================================"
echo "P5 PERFORMANCE2 DONE"
echo "RUN RC=$RUN_RC"
echo "Mac folder: $LOCAL"
echo "Table: $LOCAL/comparison_table.tsv"
echo "Master: $LOCAL/master.log"
echo "======================================================================"
exit "$RUN_RC"
