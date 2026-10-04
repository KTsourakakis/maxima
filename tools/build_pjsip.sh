#!/usr/bin/env bash
# ============================================================================
# Maxima PJSIP / PJSUA2 Android build pipeline
#
# Fetches a pinned pjproject release and cross-compiles the pjsua2 stack
# (plus the Java bindings, when SWIG is present) for each Android ABI.
#
# Prerequisites:
#   - ANDROID_NDK_HOME pointing at a side-by-side NDK (e.g. 27.0.12077973)
#   - bash, make, gcc toolchain deps (see init_setup.sh)
#   - Optional: SWIG 4.x + a JDK for the Java (pjsua2) bindings
#
# Output:
#   third_party/pjsip/lib/<abi>/libpjsua2.so
#   third_party/pjsip/java/org/pjsip/pjsua2/**     (when SWIG is available)
#
# To activate the native link afterwards:
#   -DMAXIMA_WITH_PJSIP=ON  (see src/CMakeLists.txt)
#
# Usage:
#   ./tools/build_pjsip.sh [pjproject-version]        Android ABIs (NDK required)
#   ./tools/build_pjsip.sh --host [version]           Native desktop pjsua build
#                                                    (linux-x86_64 / macos / mingw)
#
# --host produces a PJSIP_ROOT layout consumed by src/CMakeLists.txt:
#   third_party/pjsip/host/<os>/include
#   third_party/pjsip/host/<os>/lib
# and then builds a desktop libnative_core with the SIP bridge enabled.
# On Windows run it from a MinGW/MSYS2 shell (the portable WinLibs GCC
# toolchain works); the pjsua output is a static .a linked into
# native_core.dll.
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE_DIR="${ROOT}/third_party/pjsip"
BUILD_DIR="${ROOT}/.build/pjsip"

if [[ "${1:-}" == "--host" ]]; then
    PJSIP_VERSION="${2:-2.15.1}"
    PJSIP_DIR="pjproject-${PJSIP_VERSION}"
    PJSIP_TARBALL="${PJSIP_DIR}.tar.bz2"
    PJSIP_URL="https://github.com/pjsip/pjproject/releases/download/${PJSIP_VERSION}/${PJSIP_TARBALL}"

    case "$(uname -s)" in
        Linux)  HOST_OS=linux ;;
        Darwin) HOST_OS=macos ;;
        CYGWIN*|MINGW*|MSYS*) HOST_OS=windows ;;
        *) echo "[x] unsupported host OS: $(uname -s)" >&2; exit 1 ;;
    esac

    HOST_PREFIX="${STAGE_DIR}/host/${HOST_OS}"
    mkdir -p "$HOST_PREFIX" "$BUILD_DIR"
    cd "$BUILD_DIR"

    if [[ ! -d "$PJSIP_DIR" ]]; then
        echo "[*] Downloading $PJSIP_URL"
        curl -fSL -o "$PJSIP_TARBALL" "$PJSIP_URL"
        tar xf "$PJSIP_TARBALL"
    fi

    pushd "$PJSIP_DIR" >/dev/null
    make distclean >/dev/null 2>&1 || true
    echo "[*] Configuring pjsua for host ($HOST_OS)"
    ./configure \
        --prefix="$HOST_PREFIX" \
        --disable-video \
        --disable-ffmpeg \
        2>&1 | tail -3
    make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)" dep >/dev/null
    make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)" >/dev/null
    make install >/dev/null
    popd >/dev/null

    echo "[*] Building libnative_core with the SIP bridge"
    cmake -S "${ROOT}/src" -B "${BUILD_DIR}/native-${HOST_OS}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DMAXIMA_WITH_PJSIP=ON \
        -DPJSIP_ROOT="$HOST_PREFIX"
    cmake --build "${BUILD_DIR}/native-${HOST_OS}" --parallel

    echo
    echo "[+] Done. Desktop artifacts:"
    echo "    ${HOST_PREFIX}/include, ${HOST_PREFIX}/lib"
    echo "    ${BUILD_DIR}/native-${HOST_OS}/libnative_core.* "
    echo "[+] Ship the native_core binary next to the Flutter executable and"
    echo "    link/copy the pjsua static archives per your packaging step."
    exit 0
fi

PJSIP_VERSION="${1:-2.15.1}"
PJSIP_DIR="pjproject-${PJSIP_VERSION}"
PJSIP_TARBALL="${PJSIP_DIR}.tar.bz2"
PJSIP_URL="https://github.com/pjsip/pjproject/releases/download/${PJSIP_VERSION}/${PJSIP_TARBALL}"

ABIS="${MAXIMA_PJSIP_ABIS:-arm64-v8a armeabi-v7a x86_64}"
TARGET_API="${MAXIMA_ANDROID_API:-26}"

NDK="${ANDROID_NDK_HOME:-${ANDROID_SDK_ROOT:-}/ndk/27.0.12077973}"
if [[ ! -d "$NDK" ]]; then
    echo "[x] ANDROID_NDK_HOME is not set and no default NDK was found." >&2
    exit 1
fi

mkdir -p "$STAGE_DIR" "$BUILD_DIR"
cd "$BUILD_DIR"

if [[ ! -d "$PJSIP_DIR" ]]; then
    echo "[*] Downloading $PJSIP_URL"
    curl -fSL -o "$PJSIP_TARBALL" "$PJSIP_URL"
    tar xf "$PJSIP_TARBALL"
fi

HOST_TAG=linux-x86_64
case "$(uname -s)" in
    Darwin) HOST_TAG=darwin-x86_64 ;;
    CYGWIN*|MINGW*|MSYS*) HOST_TAG=windows-x86_64 ;;
esac

build_abi() {
    local abi="$1"
    local target
    case "$abi" in
        arm64-v8a)    target=aarch64-linux-android ;;
        armeabi-v7a)  target=armv7a-linux-androideabi ;;
        x86_64)       target=x86_64-linux-android ;;
        x86)          target=i686-linux-android ;;
        *) echo "[x] unsupported ABI: $abi"; return 1 ;;
    esac

    local out="${BUILD_DIR}/install/${abi}"
    echo "[*] Building pjsua2 for ${abi} (target ${target})"

    pushd "$PJSIP_DIR" >/dev/null
    make distclean >/dev/null 2>&1 || true

    export PATH="${NDK}/toolchains/llvm/prebuilt/${HOST_TAG}/bin:$PATH"
    ./configure \
        --host="${target}" \
        --prefix="$out" \
        --disable-video \
        --disable-sound \
        --enable-shared \
        CFLAGS="-fPIC" \
        APP_PLATFORM="android-${TARGET_API}" 2>&1 | tail -3
    make -j"$(nproc 2>/dev/null || echo 4)" dep >/dev/null
    make -j"$(nproc 2>/dev/null || echo 4)" >/dev/null
    make install >/dev/null

    # pjsua2 Java bindings (optional - requires SWIG)
    if command -v swig >/dev/null 2>&1; then
        (
            cd pjsip-apps/src/swig
            make 2>&1 | tail -3 || true
        )
        mkdir -p "${STAGE_DIR}/java"
        cp -r pjsip-apps/src/swig/java/android/app/src/main/java/* \
            "${STAGE_DIR}/java/" 2>/dev/null || true
    else
        echo "[!] SWIG not found - skipping pjsua2 Java bindings."
    fi
    popd >/dev/null

    mkdir -p "${STAGE_DIR}/lib/${abi}"
    find "$out" -name 'libpjsua2*.so' -exec cp {} "${STAGE_DIR}/lib/${abi}/" \;
    find "${PJSIP_DIR}" -name 'libpjsua2.so' \
        -exec cp {} "${STAGE_DIR}/lib/${abi}/" \; 2>/dev/null || true
}

for abi in $ABIS; do
    build_abi "$abi"
done

echo
echo "[+] Done. Artifacts:"
echo "    ${STAGE_DIR}/lib/<abi>/libpjsua2.so   -> android/app/src/main/jniLibs/<abi>/"
echo "    ${STAGE_DIR}/java/                  -> package into a pjsua2 Android library module"
echo "[+] Rebuild the app with CMake flag -DMAXIMA_WITH_PJSIP=ON to link the native core."
