#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
CORE="$HERE/run_matrix_from_idex_core.sh"
PUBLIC="$HERE/run_matrix_from_idex.sh"
PATCH="$HERE/make_p5_single_mode_controller.py"

MODE=off
RUNS=1
DOWNLOADS=3
GAP=5
COOLDOWN=5
BETWEEN=0
OUTPUT=""
CLIENT_BIN="/root/mohsen/msquic/build-greenquic-p5/bin/Release/quicinterop"
ENV_ARGS=()

while (($#)); do
    case "$1" in
        --mode) MODE="${2:?}"; shift 2;;
        --runs) RUNS="${2:?}"; shift 2;;
        --downloads) DOWNLOADS="${2:?}"; shift 2;;
        --gap-seconds) GAP="${2:?}"; shift 2;;
        --server-cooldown-seconds) COOLDOWN="${2:?}"; shift 2;;
        --between-tests-seconds) BETWEEN="${2:?}"; shift 2;;
        --output-dir) OUTPUT="${2:?}"; shift 2;;
        --client-bin) CLIENT_BIN="${2:?}"; shift 2;;
        --env)
            [[ "${2:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]] || { echo "ERROR: --env requires KEY=VALUE" >&2; exit 2; }
            ENV_ARGS+=(--env "$2"); shift 2;;
        -h|--help)
            echo "usage: $0 --mode off|basic|plus --output-dir DIR [--runs N --downloads N --env K=V ...]"
            exit 0;;
        *) echo "ERROR: unknown option $1" >&2; exit 2;;
    esac
done

case "$MODE" in off|basic|plus) ;; *) echo "ERROR: invalid --mode $MODE" >&2; exit 2;; esac
[[ "$RUNS" =~ ^[1-9][0-9]*$ && "$DOWNLOADS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: invalid runs/downloads" >&2; exit 2; }
[[ -n "$OUTPUT" ]] || { echo "ERROR: --output-dir required" >&2; exit 2; }
for f in "$CORE" "$PUBLIC" "$PATCH"; do [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 2; }; done
python3 -m py_compile "$PATCH"
python3 "$PATCH" --self-test

TMP_CORE="$(mktemp "$HERE/.p5_single_mode_core.XXXXXX.sh")"
TMP_PUBLIC="$(mktemp "$HERE/.p5_single_mode_public.XXXXXX.sh")"
cleanup(){ rm -f "$TMP_CORE" "$TMP_PUBLIC"; }
trap cleanup EXIT INT TERM

python3 "$PATCH" \
    --core "$CORE" --public "$PUBLIC" --mode "$MODE" \
    --out-core "$TMP_CORE" --out-public "$TMP_PUBLIC"

mkdir -p "$OUTPUT"
bash "$TMP_PUBLIC" \
    --runs "$RUNS" \
    --downloads "$DOWNLOADS" \
    --gap-seconds "$GAP" \
    --server-cooldown-seconds "$COOLDOWN" \
    --between-tests-seconds "$BETWEEN" \
    --mode-order "$MODE" \
    --seed 20260818 \
    --client-host tinyman \
    --client-dir "$HERE" \
    --client-bin "$CLIENT_BIN" \
    --cstate-cpu 19 \
    --output-dir "$OUTPUT" \
    "${ENV_ARGS[@]}"

echo "P5 SINGLE-CORE SINGLE-MODE TRAFFIC PASS mode=$MODE results=$OUTPUT"
