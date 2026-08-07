#!/usr/bin/env bash
set -Eeuo pipefail

missing=()

python3 -c 'import matplotlib' >/dev/null 2>&1 || missing+=(python3-matplotlib)

if ((${#missing[@]} == 0)); then
    echo "GreenQUIC Python test/report dependencies: PASS"
    exit 0
fi

((EUID == 0)) || {
    echo "ERROR: missing Python test/report dependencies: ${missing[*]}" >&2
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

echo "GreenQUIC Python test/report dependencies: PASS"
