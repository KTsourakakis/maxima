#!/usr/bin/env bash
# ============================================================================
# Builds the native core as a desktop shared library.
#
#   Linux   -> libnative_core.so
#   macOS   -> libnative_core.dylib
#   Windows -> native_core.dll   (from a MinGW/MSYS2 shell; on cmd/PowerShell
#                                use tools/build_native_desktop.ps1 instead)
#
# The output library is placed in ./native/<os>/ next to the repository
# root. Ship it beside the Flutter executable (or the platform-appropriate
# bundle location) so NativeBridge.openNativeLibrary() can dlopen it.
#
# Optional flags:
#   --with-pjsip <PJSIP_ROOT>   enables the SIP bridge against a desktop
#                               pjsua install produced by
#                               tools/build_pjsip.sh --host
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PJSIP_ROOT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-pjsip) PJSIP_ROOT="$2"; shift 2 ;;
        *) echo "[x] unknown argument: $1" >&2; exit 1 ;;
    esac
done

case "$(uname -s)" in
    Linux)  HOST_OS=linux ;;
    Darwin) HOST_OS=macos ;;
    CYGWIN*|MINGW*|MSYS*) HOST_OS=windows ;;
    *) echo "[x] unsupported host OS: $(uname -s)" >&2; exit 1 ;;
esac

OUT_DIR="${ROOT}/native/${HOST_OS}"
BUILD_DIR="${ROOT}/.build/native-${HOST_OS}"
mkdir -p "$OUT_DIR"

CMAKE_ARGS=(
    -S "${ROOT}/src"
    -B "${BUILD_DIR}"
    -DCMAKE_BUILD_TYPE=Release
)
if [[ -n "$PJSIP_ROOT" ]]; then
    CMAKE_ARGS+=(-DMAXIMA_WITH_PJSIP=ON "-DPJSIP_ROOT=${PJSIP_ROOT}")
fi

cmake "${CMAKE_ARGS[@]}"
cmake --build "${BUILD_DIR}" --parallel

case "$HOST_OS" in
    windows) LIB_NAME="native_core.dll" ;;
    macos)   LIB_NAME="libnative_core.dylib" ;;
    *)       LIB_NAME="libnative_core.so" ;;
esac

cp "${BUILD_DIR}/${LIB_NAME}" "${OUT_DIR}/" 2>/dev/null \
    || find "${BUILD_DIR}" -name "${LIB_NAME}" -exec cp {} "${OUT_DIR}/" \;

echo "[+] Built ${OUT_DIR}/${LIB_NAME}"
