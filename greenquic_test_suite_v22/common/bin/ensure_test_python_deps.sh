#!/usr/bin/env bash
set -Eeuo pipefail

missing=()

python3 -c 'import matplotlib' >/dev/null 2>&1 || missing+=(python3-matplotlib)
command -v sensors >/dev/null 2>&1 || missing+=(lm-sensors)

if ((${#missing[@]} == 0)); then
    echo "GreenQUIC test/report dependencies: PASS (matplotlib + lm-sensors)"
    exit 0
fi

((EUID == 0)) || {
    echo "ERROR: missing GreenQUIC test/report dependencies: ${missing[*]}" >&2
    echo "Run bootstrap as root so they can be installed." >&2
    exit 1
}

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

apt-get update
apt-get -y --no-install-recommends --no-remove --no-upgrade install "${missing[@]}"

python3 -c 'import matplotlib' >/dev/null 2>&1 || {
    echo "ERROR: matplotlib is still unavailable after package installation" >&2
    exit 1
}
command -v sensors >/dev/null 2>&1 || {
    echo "ERROR: sensors command is still unavailable after installing lm-sensors" >&2
    exit 1
}

echo "GreenQUIC test/report dependencies: PASS (matplotlib + lm-sensors)"
