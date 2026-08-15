#!/usr/bin/env bash
set -Eeuo pipefail

BRANCH="performance/p5-max-goodput"
PLAN="screen"
TESTS=""
DOWNLOADS=3

usage() {
    cat <<'EOF'
Usage:
  bash ./mac_run_p5_super_performance.sh [--plan screen|combo|all] [--tests comma,list] [--downloads N]

Default next experiment:
  --plan screen

Examples:
  bash ./mac_run_p5_super_performance.sh
  bash ./mac_run_p5_super_performance.sh --plan combo
  bash ./mac_run_p5_super_performance.sh --plan all
  bash ./mac_run_p5_super_performance.sh --tests measured_default,classic_mp,drain4
EOF
}

while (($#)); do
    case "$1" in
        --plan) PLAN="${2:?missing value}"; shift 2 ;;
        --tests) TESTS="${2:?missing value}"; shift 2 ;;
        --downloads) DOWNLOADS="${2:?missing value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$PLAN" in screen|combo|all) ;; *) echo "ERROR: --plan must be screen|combo|all" >&2; exit 2;; esac
[[ "$DOWNLOADS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: --downloads must be positive" >&2; exit 2; }

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(cd -- "$HERE/../../../.." && pwd)"
P5="/root/mohsen/greenquic_test_suite_v22/test_cases/pretests/P5_repeated_8GiB_downloads"
STAMP="$(date +%Y%m%d_%H%M%S)"
BUNDLE="/tmp/GreenQUIC_P5_SUPER_${STAMP}.bundle"
REMOTE_BUNDLE="/tmp/GreenQUIC_P5_SUPER_${STAMP}.bundle"
RESULT="/tmp/P5_SUPER_SWEEP_${STAMP}"
MATRIX="$P5/matrix_results/P5_SUPER_SWEEP_${STAMP}"
CHARTS="/tmp/P5_SUPER_SWEEP_CHARTS_${STAMP}.tar.gz"
LOCAL="$HOME/Downloads/P5_SUPER_SWEEP_${STAMP}"

cd "$REPO_ROOT"
cleanup_local_bundle() { rm -f "$BUNDLE"; }
trap cleanup_local_bundle EXIT

echo "======================================================================"
echo "P5 SUPER PERFORMANCE"
echo "PLAN=$PLAN"
echo "TESTS=${TESTS:-plan-default}"
echo "DOWNLOADS=$DOWNLOADS"
echo "======================================================================"

if [ -n "$(git status --porcelain)" ]; then
    echo "Saving local Mac working-tree changes..."
    git stash push -u -m "pre-p5-super-${STAMP}"
fi

git fetch origin main "$BRANCH"
EXPECTED="$(git rev-parse "origin/$BRANCH")"

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git checkout "$BRANCH"
else
    git checkout -b "$BRANCH" "origin/$BRANCH"
fi
git reset --hard "origin/$BRANCH"

echo
git log -1 --format='MAC HEAD=%H%nSUBJECT=%s'

IDEX_HEAD="$(ssh idex 'git -C /root/mohsen rev-parse HEAD 2>/dev/null || true')"
TINY_HEAD="$(ssh idex 'ssh root@tinyman "git -C /root/mohsen rev-parse HEAD 2>/dev/null || true"' 2>/dev/null || true)"

BASE=""
if [ -n "$IDEX_HEAD" ] && [ "$IDEX_HEAD" = "$TINY_HEAD" ] && git cat-file -e "$IDEX_HEAD^{commit}" 2>/dev/null && git merge-base --is-ancestor "$IDEX_HEAD" "$EXPECTED"; then
    BASE="$IDEX_HEAD"
fi

rm -f "$BUNDLE"
if [ -n "$BASE" ]; then
    echo "Creating incremental bundle from server HEAD $BASE"
    git bundle create "$BUNDLE" "$BRANCH" "^$BASE"
else
    echo "Server HEADs are not a common known ancestor; creating full branch bundle."
    git bundle create "$BUNDLE" "$BRANCH"
fi
ls -lh "$BUNDLE"

if ssh idex 'ps -eo args= | grep -Eq "[r]un_p5_super_performance_sweep.sh|[r]un_cache128_ring_sweep.sh|[r]un_cache128_isolated_feature_sweep.sh"'; then
    echo "ERROR: an old P5 performance sweep is still running on idex."
    ssh idex 'ps -eo pid=,args= | grep -E "[r]un_p5_super_performance_sweep.sh|[r]un_cache128_ring_sweep.sh|[r]un_cache128_isolated_feature_sweep.sh"'
    exit 40
fi

scp "$BUNDLE" "idex:$REMOTE_BUNDLE"
ssh idex "scp '$REMOTE_BUNDLE' root@tinyman:'$REMOTE_BUNDLE'"

ssh idex "EXPECTED='$EXPECTED' BRANCH='$BRANCH' BUNDLE='$REMOTE_BUNDLE' STAMP='$STAMP' bash -s" <<'REMOTE'
set -euo pipefail
cd /root/mohsen
PATCH="/tmp/GreenQUIC_before_p5_super_${STAMP}_idex.patch"
git diff HEAD > "$PATCH" || true
[ -s "$PATCH" ] || rm -f "$PATCH"
git reset --hard
git fetch "$BUNDLE" "refs/heads/$BRANCH"
git checkout -B "$BRANCH" FETCH_HEAD
test "$(git rev-parse HEAD)" = "$EXPECTED"
echo "IDEX:"
git log -1 --format='HEAD=%H%nSUBJECT=%s'
REMOTE

ssh idex "ssh root@tinyman \"EXPECTED='$EXPECTED' BRANCH='$BRANCH' BUNDLE='$REMOTE_BUNDLE' STAMP='$STAMP' bash -s\"" <<'REMOTE'
set -euo pipefail
cd /root/mohsen
PATCH="/tmp/GreenQUIC_before_p5_super_${STAMP}_tinyman.patch"
git diff HEAD > "$PATCH" || true
[ -s "$PATCH" ] || rm -f "$PATCH"
git reset --hard
git fetch "$BUNDLE" "refs/heads/$BRANCH"
git checkout -B "$BRANCH" FETCH_HEAD
test "$(git rev-parse HEAD)" = "$EXPECTED"
echo "TINYMAN:"
git log -1 --format='HEAD=%H%nSUBJECT=%s'
REMOTE

ssh idex "cd '$P5' && bash -n ./build_p5_super_performance.sh && bash -n ./run_p5_super_performance_sweep.sh && python3 -m py_compile ./apply_p5_super_performance.py && echo 'IDEX SUPER PREFLIGHT PASS'"
ssh idex "ssh root@tinyman \"cd '$P5' && bash -n ./build_p5_super_performance.sh && bash -n ./run_p5_super_performance_sweep.sh && python3 -m py_compile ./apply_p5_super_performance.py && echo 'TINYMAN SUPER PREFLIGHT PASS'\""

echo
echo "======================================================================"
echo "STARTING REMOTE SWEEP"
echo "======================================================================"
set +e
ssh idex "cd '$P5' && STAMP='$STAMP' P5_SUPER_PLAN='$PLAN' P5_SUPER_TESTS='$TESTS' P5_SUPER_DOWNLOADS='$DOWNLOADS' bash ./run_p5_super_performance_sweep.sh"
RUN_RC=$?
set -e

echo
echo "======================================================================"
echo "COPYING RESULTS TO MAC"
echo "======================================================================"
mkdir -p "$LOCAL"
scp -r "idex:${RESULT}/." "$LOCAL/" || true

ssh idex "rm -f '$CHARTS'; if [ -d '$MATRIX' ]; then cd '$MATRIX'; find . -type f -path '*/tables/charts/*' -print0 | tar --null -T - -czf '$CHARTS' 2>/dev/null || true; fi"
if ssh idex "test -s '$CHARTS'"; then
    scp "idex:$CHARTS" "$LOCAL/P5_SUPER_OLD_CHARTS_${STAMP}.tar.gz" || true
fi

echo
echo "======================================================================"
echo "FINAL TABLE"
echo "======================================================================"
if [ -f "$LOCAL/comparison_table.tsv" ]; then column -t -s $'\t' "$LOCAL/comparison_table.tsv" 2>/dev/null || cat "$LOCAL/comparison_table.tsv"; else echo "comparison_table.tsv missing"; fi

echo
echo "======================================================================"
echo "DPDK CAPABILITIES"
echo "======================================================================"
if [ -f "$LOCAL/dpdk_capabilities.txt" ]; then sort -u "$LOCAL/dpdk_capabilities.txt"; fi

echo
echo "======================================================================"
echo "NUMA"
echo "======================================================================"
if [ -f "$LOCAL/numa_topology.txt" ]; then cat "$LOCAL/numa_topology.txt"; fi

echo
echo "======================================================================"
echo "RESULTS"
echo "======================================================================"
echo "Mac folder: $LOCAL"
echo "Table:      $LOCAL/comparison_table.tsv"
echo "Raw:        $LOCAL/goodput_summary.tsv"
echo "Caps:       $LOCAL/dpdk_capabilities.txt"
echo "Topology:   $LOCAL/numa_topology.txt"
echo "Master:     $LOCAL/master.log"
echo "Logs:       $LOCAL/logs/"
echo "Charts:     $LOCAL/P5_SUPER_OLD_CHARTS_${STAMP}.tar.gz"
echo "Matrix:     $MATRIX"
echo "RUN RC=$RUN_RC"
echo "Native P5 binaries are restored automatically by the remote runner."
echo "======================================================================"

exit "$RUN_RC"
