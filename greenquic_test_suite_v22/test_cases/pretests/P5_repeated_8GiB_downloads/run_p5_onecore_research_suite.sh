#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "$0")" && pwd)"
TAG="${P5_ONECORE_TAG:-$(date +%Y%m%d_%H%M%S)}"
ROOT="${P5_ONECORE_OUTPUT_ROOT:-$HERE/matrix_results/P5_ONECORE_RESEARCH_${TAG}}"
STAGES="${P5_ONECORE_STAGES:-claim,gap,pacing,11g}"
mkdir -p "$ROOT"

stage_selected() {
    local name="$1"
    case ",$STAGES," in
        *,$name,*) return 0 ;;
        *) return 1 ;;
    esac
}

run_stage() {
    local name="$1"
    shift
    if stage_selected "$name"; then
        echo "===== ONECORE STAGE $name ====="
        "$@"
    else
        echo "SKIP stage=$name"
    fi
}

CLAIM_RC=skipped
CLAIM_NONPASS_CONTINUED=0
if stage_selected claim; then
    echo "===== ONECORE STAGE claim ====="
    set +e
    env \
        P5_CLAIM_OUTPUT_ROOT="$ROOT/01_claim" \
        P5_CLAIM_RUNS="${P5_CLAIM_RUNS:-2}" \
        P5_CLAIM_DOWNLOADS="${P5_CLAIM_DOWNLOADS:-3}" \
        bash "$HERE/run_p5_claim_proof_suite.sh"
    CLAIM_RC=$?
    set -e
    case "$CLAIM_RC" in
        0)
            ;;
        2)
            CLAIM_NONPASS_CONTINUED=1
            echo "ONECORE CLAIM NON-PASS rc=2; preserving the claim result and continuing with gap/pacing/11g."
            ;;
        *)
            echo "ERROR: claim stage failed rc=$CLAIM_RC; refusing to continue after a hard execution error." >&2
            exit "$CLAIM_RC"
            ;;
    esac
else
    echo "SKIP stage=claim"
fi

run_stage gap env P5_GAP_OUTPUT_ROOT="$ROOT/02_gap" P5_GAP_RUNS="${P5_GAP_RUNS:-1}" P5_GAP_DOWNLOADS="${P5_GAP_DOWNLOADS:-3}" bash "$HERE/run_p5_gap_causality_suite.sh"
run_stage pacing env P5_PACING_OUTPUT_ROOT="$ROOT/03_pacing" P5_PACING_RUNS="${P5_PACING_RUNS:-1}" P5_PACING_DOWNLOADS="${P5_PACING_DOWNLOADS:-3}" bash "$HERE/run_p5_tx_pacing_probe_suite.sh"
run_stage 11g env P5_11G_OUTPUT_ROOT="$ROOT/04_11g" P5_11G_SCREEN_RUNS="${P5_11G_SCREEN_RUNS:-1}" P5_11G_SCREEN_DOWNLOADS="${P5_11G_SCREEN_DOWNLOADS:-3}" P5_11G_VALIDATE_RUNS="${P5_11G_VALIDATE_RUNS:-6}" P5_11G_VALIDATE_DOWNLOADS="${P5_11G_VALIDATE_DOWNLOADS:-6}" bash "$HERE/run_p5_11g_target_suite.sh"

printf 'stages=%s\ntag=%s\nclaim_rc=%s\nclaim_nonpass_continued=%s\n' \
    "$STAGES" "$TAG" "$CLAIM_RC" "$CLAIM_NONPASS_CONTINUED" >"$ROOT/MASTER_STATUS.env"
echo "P5 ONE-CORE RESEARCH SUITE COMPLETE: $ROOT"
