#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CORE_BOOTSTRAP="$ROOT_DIR/bootstrap_greenquic_core.sh"
MSR_CHECK="$ROOT_DIR/greenquic_test_suite_v22/common/bin/check_msr_pstate.sh"

MSR_PSTATE_CHECK=1
MSR_CHECK_CPU=19
FORWARD_ARGS=()

while (($#)); do
    case "$1" in
        --skip-msr-pstate-check)
            MSR_PSTATE_CHECK=0
            shift
            ;;
        --msr-pstate-check)
            MSR_PSTATE_CHECK=1
            shift
            ;;
        --lcores)
            [[ $# -ge 2 ]] || { echo "ERROR: --lcores needs a value" >&2; exit 2; }
            LCORE_VALUE="$2"
            FIRST_LCORE="${LCORE_VALUE%%[,-]*}"
            if [[ "$FIRST_LCORE" =~ ^[0-9]+$ ]]; then
                MSR_CHECK_CPU="$FIRST_LCORE"
            fi
            FORWARD_ARGS+=("$1" "$2")
            shift 2
            ;;
        -h|--help)
            cat <<'EOF'
Additional GreenQUIC host-readiness options:
  --msr-pstate-check       Run local MSR/P-state readiness check (default)
  --skip-msr-pstate-check  Skip the local MSR/P-state readiness check

The check runs only on the current server. It uses the first CPU from --lcores;
if --lcores is omitted, CPU 19 is used.
EOF
            exec "$CORE_BOOTSTRAP" "$@"
            ;;
        *)
            FORWARD_ARGS+=("$1")
            shift
            ;;
    esac
done

[[ -x "$CORE_BOOTSTRAP" ]] || {
    echo "ERROR: missing executable core bootstrap: $CORE_BOOTSTRAP" >&2
    exit 1
}

if ((MSR_PSTATE_CHECK)); then
    [[ -f "$MSR_CHECK" ]] || {
        echo "ERROR: missing MSR/P-state check helper: $MSR_CHECK" >&2
        exit 1
    }

    if ! command -v rdmsr >/dev/null 2>&1; then
        ((EUID == 0)) || {
            echo "ERROR: rdmsr is missing and msr-tools installation requires root" >&2
            exit 1
        }
        echo "Installing msr-tools for local MSR/P-state readiness check..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get -y --no-install-recommends --no-remove --no-upgrade install msr-tools
    fi

    bash "$MSR_CHECK" "$MSR_CHECK_CPU"
else
    echo "Local MSR/P-state readiness check disabled by --skip-msr-pstate-check."
fi

exec "$CORE_BOOTSTRAP" "${FORWARD_ARGS[@]}"
