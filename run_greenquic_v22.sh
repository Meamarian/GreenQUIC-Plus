#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="/root/mohsen"
REPO="$ROOT/msquic"
PATCH="$ROOT/greenquic_autopatch_v22.py"
SUITE="$ROOT/greenquic_test_suite"
BASE="origin/25.02-optimizations/dpdk"
BRANCH="greenquic-v22-private-split-dpdk"
BUILD_DIR="build-greenquic"
DPDK_SRC="$REPO/deps/dpdk"
DPDK_PREFIX="$REPO/deps/dpdk-install"
HOST_NAME="$(hostname -s)"
JOBS="${GREENQUIC_JOBS:-$(nproc)}"
STAMP="$(date +%Y%m%d_%H%M%S)"
LOG="$ROOT/greenquic_v22_${HOST_NAME}_${STAMP}.log"
SAVE_DIR="$ROOT/.greenquic-v22-saved-${HOST_NAME}"

case "$HOST_NAME" in
    idex)
        ROLE="server"
        ;;
    tinyman)
        ROLE="client"
        ;;
    *)
        echo "ERROR: expected hostname idex or tinyman, got: $HOST_NAME" >&2
        exit 1
        ;;
esac

mkdir -p "$ROOT"
exec > >(tee -a "$LOG") 2>&1

restore_configs() {
    local name
    for name in dpdk.ini powermng.ini; do
        if [[ -f "$SAVE_DIR/$name" ]]; then
            cp -a "$SAVE_DIR/$name" "$REPO/$name"
            echo "Restored $REPO/$name"
        fi
    done
}
trap restore_configs EXIT

echo "============================================================"
echo "GreenQUIC V22 clean reproducible build"
echo "Host:       $HOST_NAME"
echo "Role:       $ROLE"
echo "Repository: $REPO"
echo "Branch:     $BRANCH"
echo "Log:        $LOG"
echo "============================================================"

for tool in git cmake python3 pkg-config clang; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: missing required tool: $tool" >&2
        exit 1
    }
done

[[ -f "$PATCH" ]] || {
    echo "ERROR: missing autopatcher: $PATCH" >&2
    exit 1
}
[[ -d "$REPO/.git" ]] || {
    echo "ERROR: missing Git repository: $REPO" >&2
    exit 1
}
[[ -d "$DPDK_SRC" ]] || {
    echo "ERROR: missing DPDK source: $DPDK_SRC" >&2
    exit 1
}
[[ -d "$DPDK_PREFIX" ]] || {
    echo "ERROR: missing DPDK installation: $DPDK_PREFIX" >&2
    exit 1
}

python3 -m py_compile "$PATCH"
echo "Autopatcher SHA-256: $(shasum -a 256 "$PATCH" | awk '{print $1}')"

rm -rf "$SAVE_DIR"
mkdir -p "$SAVE_DIR"
for name in dpdk.ini powermng.ini; do
    if [[ -f "$REPO/$name" ]]; then
        cp -a "$REPO/$name" "$SAVE_DIR/$name"
        echo "Saved existing $name to $SAVE_DIR/$name"
    fi
done

echo
echo "Restoring a clean private-branch source tree..."
git -C "$REPO" fetch --all --tags --prune
git -C "$REPO" reset --hard
git -C "$REPO" checkout -f "$BASE"
git -C "$REPO" reset --hard "$BASE"
git -C "$REPO" submodule update --init --recursive

# Remove only prior GreenQUIC-generated files/build output. Keep deps/dpdk and
# deps/dpdk-install untouched.
rm -rf "$REPO/$BUILD_DIR"
rm -f \
    "$REPO/greenquic_patch_manifest.txt" \
    "$REPO/dpdk.greenquic.example.ini" \
    "$REPO/powermng.example.ini" \
    "$REPO/src/inc/greenquic_plus.h" \
    "$REPO/src/platform/greenquic_plus.c"
find "$REPO/src" -type f \
    \( -name '*.greenquic.bak' -o -name '*.before_*' \) \
    -print -delete
find "$REPO" -maxdepth 1 -type f -name '*.greenquic.bak' -print -delete

echo
echo "Confirming the original active backend..."
grep -n "datapath_raw_dpdk_linux.c" "$REPO/src/platform/CMakeLists.txt"
if grep -Eq '\bdatapath_raw_dpdk\.c\b' "$REPO/src/platform/CMakeLists.txt"; then
    echo "ERROR: the legacy and split DPDK backends appear together in CMakeLists.txt" >&2
    exit 1
fi

echo
echo "Activating only the local DPDK 21.11.9 installation..."
export PKG_CONFIG_PATH="$DPDK_PREFIX/lib/x86_64-linux-gnu/pkgconfig:$DPDK_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="$DPDK_PREFIX/lib/x86_64-linux-gnu:$DPDK_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LIBRARY_PATH="$DPDK_PREFIX/lib/x86_64-linux-gnu:$DPDK_PREFIX/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"

DPDK_VERSION="$(pkg-config --modversion libdpdk 2>/dev/null || true)"
[[ -n "$DPDK_VERSION" ]] || {
    echo "ERROR: pkg-config cannot find libdpdk under $DPDK_PREFIX" >&2
    exit 1
}
[[ "$DPDK_VERSION" == "21.11.9" ]] || {
    echo "ERROR: expected DPDK 21.11.9, found $DPDK_VERSION" >&2
    exit 1
}
echo "DPDK version: $DPDK_VERSION"

PATCH_ARGS=(
    --repo-dir "$REPO"
    --checkout "$BASE"
    --branch "$BRANCH"
    --yes
    --enable-multi-core
    --dpdk-mode local
    --dpdk-dir "$DPDK_SRC"
    --dpdk-install-dir "$DPDK_PREFIX"
    --dpdk-checkout v21.11.9
    --no-dpdk-build
    --build-dir "$BUILD_DIR"
    --build-type Release
    --tls openssl
    --jobs "$JOBS"
)

if [[ -f "$SUITE/common/bin/gq_common.sh" ]]; then
    PATCH_ARGS+=(--test-suite-dir "$SUITE")
else
    echo "WARNING: test suite not found at $SUITE; suite marker patch is skipped."
fi

echo
echo "Running GreenQUIC V22 autopatcher..."
python3 "$PATCH" "${PATCH_ARGS[@]}"

echo
echo "Final verification..."
ACTIVE="$REPO/src/platform/datapath_raw_dpdk_linux.c"
CMAKE_FILE="$REPO/src/platform/CMakeLists.txt"
SERVER_BIN="$REPO/$BUILD_DIR/bin/Release/quicinteropserver"
CLIENT_BIN="$REPO/$BUILD_DIR/bin/Release/quicinterop"

for required in \
    'GREENQUIC-V22-SPLIT-LINUX-DPDK-PORT' \
    'ALLOW_EXPERIMENTAL_API' \
    'GreenQuicEnableMultiCore' \
    'GreenQuicPartitionDpdkMap' \
    'GreenQuicIdleMode'; do
    grep -Fq "$required" "$ACTIVE" || {
        echo "ERROR: missing source marker: $required" >&2
        exit 1
    }
done

if grep -Eq '\bdatapath_raw_dpdk\.c\b' "$CMAKE_FILE"; then
    echo "ERROR: CMake still includes the incompatible legacy backend" >&2
    exit 1
fi
[[ -f "$SERVER_BIN" ]] || { echo "ERROR: missing $SERVER_BIN" >&2; exit 1; }
[[ -f "$CLIENT_BIN" ]] || { echo "ERROR: missing $CLIENT_BIN" >&2; exit 1; }

# The macro must precede the first DPDK include in the active translation unit.
MACRO_LINE="$(grep -n -m1 '^#define ALLOW_EXPERIMENTAL_API 1$' "$ACTIVE" | cut -d: -f1)"
DPDK_INCLUDE_LINE="$(grep -n -m1 '^#include <rte_' "$ACTIVE" | cut -d: -f1)"
[[ -n "$MACRO_LINE" && -n "$DPDK_INCLUDE_LINE" && "$MACRO_LINE" -lt "$DPDK_INCLUDE_LINE" ]] || {
    echo "ERROR: ALLOW_EXPERIMENTAL_API is not before the first DPDK header" >&2
    exit 1
}

echo "Server binary: $SERVER_BIN"
echo "Client binary: $CLIENT_BIN"
echo "Active object: $REPO/$BUILD_DIR/src/platform/CMakeFiles/msquic_platform.dir/datapath_raw_dpdk_linux.c.o"
echo "Manifest:      $REPO/greenquic_patch_manifest.txt"
echo "Saved config:  $SAVE_DIR"
echo "Log:           $LOG"
echo "GreenQUIC V22 completed successfully on $HOST_NAME ($ROLE)."
