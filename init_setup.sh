#!/usr/bin/env bash
set -euo pipefail

log() {
    printf '[*] %s\n' "$*"
}

warn() {
    printf '[!] %s\n' "$*" >&2
}

OS="$(uname -s 2>/dev/null || echo Windows)"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FLUTTER_HOME="${FLUTTER_HOME:-$HOME/flutter}"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5:7b-instruct}"
IS_WINDOWS=false

case "$OS" in
    MINGW*|MSYS*|CYGWIN*|Windows_NT*|Windows)
        IS_WINDOWS=true
        ;;
esac

to_posix_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$1"
    else
        printf '%s' "$1"
    fi
}

find_git() {
    if command -v git >/dev/null 2>&1; then
        printf 'git'
        return 0
    fi

    if [ "$IS_WINDOWS" = true ]; then
        local program_files local_app_data candidate
        program_files="$(to_posix_path "${PROGRAMFILES:-C:/Program Files}")"
        local_app_data="$(to_posix_path "${LOCALAPPDATA:-}")"
        for candidate in \
            "$program_files/Git/cmd/git.exe" \
            "$local_app_data/Programs/Git/cmd/git.exe"; do
            if [ -x "$candidate" ]; then
                printf '%s' "$candidate"
                return 0
            fi
        done
    fi

    return 1
}

find_ollama() {
    if command -v ollama >/dev/null 2>&1; then
        printf 'ollama'
        return 0
    fi

    if [ "$IS_WINDOWS" = true ]; then
        local program_files local_app_data candidate
        program_files="$(to_posix_path "${PROGRAMFILES:-C:/Program Files}")"
        local_app_data="$(to_posix_path "${LOCALAPPDATA:-}")"
        for candidate in \
            "$local_app_data/Programs/Ollama/ollama.exe" \
            "$program_files/Ollama/ollama.exe"; do
            if [ -x "$candidate" ]; then
                printf '%s' "$candidate"
                return 0
            fi
        done
    fi

    return 1
}

wait_for_ollama_service() {
    local ollama_cmd="$1"
    local attempt=0
    local log_dir="$PROJECT_ROOT/.maxima"
    local log_file="$log_dir/ollama-serve.log"

    if "$ollama_cmd" list >/dev/null 2>&1; then
        return 0
    fi

    mkdir -p "$log_dir"
    log "Waiting for the Ollama service to initialize..."
    if command -v nohup >/dev/null 2>&1; then
        nohup "$ollama_cmd" serve >"$log_file" 2>&1 &
    else
        "$ollama_cmd" serve >"$log_file" 2>&1 &
    fi

    while [ "$attempt" -lt 30 ]; do
        if "$ollama_cmd" list >/dev/null 2>&1; then
            log "Ollama service is operational."
            return 0
        fi
        sleep 1
        attempt=$((attempt + 1))
    done

    warn "Ollama service did not become ready. See $log_file"
    return 1
}

write_flutter_local_properties() {
    local flutter_bin flutter_root sdk_path

    if command -v flutter >/dev/null 2>&1; then
        flutter_bin="$(command -v flutter)"
    elif [ -x "$FLUTTER_HOME/bin/flutter" ]; then
        flutter_bin="$FLUTTER_HOME/bin/flutter"
    else
        return 0
    fi

    flutter_root="$(cd "$(dirname "$flutter_bin")/.." && pwd -P)"
    sdk_path="$flutter_root"
    if [ "$IS_WINDOWS" = true ] && command -v cygpath >/dev/null 2>&1; then
        sdk_path="$(cygpath -m "$flutter_root")"
    fi

    printf 'flutter.sdk=%s\n' "$sdk_path" > "$PROJECT_ROOT/android/local.properties"
    log "Wrote android/local.properties for Flutter SDK at $sdk_path"
}

install_linux_dependencies() {
    local sudo_cmd=""
    if command -v sudo >/dev/null 2>&1; then
        sudo_cmd="sudo"
    fi

    if [ -f /etc/debian_version ]; then
        $sudo_cmd apt-get update
        $sudo_cmd apt-get install -y build-essential ca-certificates cmake curl git
    elif [ -f /etc/fedora-release ]; then
        $sudo_cmd dnf groupinstall -y "Development Tools"
        $sudo_cmd dnf install -y ca-certificates cmake curl git
    elif [ -f /etc/arch-release ]; then
        $sudo_cmd pacman -Syu --noconfirm base-devel ca-certificates cmake curl git
    else
        warn "Unsupported Linux distribution. Install CMake, curl, Git, and a C++ toolchain manually."
    fi
}

install_macos_dependencies() {
    if ! command -v brew >/dev/null 2>&1; then
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    brew install cmake curl git
}

install_windows_dependencies() {
    if ! command -v winget >/dev/null 2>&1; then
        warn "winget is unavailable. Install CMake, Git, and Ollama manually."
        return 0
    fi

    winget install --id Git.Git --exact --silent --accept-source-agreements --accept-package-agreements
    winget install --id Kitware.CMake --exact --silent --accept-source-agreements --accept-package-agreements
    winget install --id Ollama.Ollama --exact --silent --accept-source-agreements --accept-package-agreements
}

install_flutter() {
    if command -v flutter >/dev/null 2>&1; then
        log "Flutter is already available."
    else
        local git_cmd
        if ! git_cmd="$(find_git)"; then
            warn "Git is unavailable; Flutter could not be downloaded automatically."
            return 0
        fi

        if [ ! -d "$FLUTTER_HOME" ]; then
            log "Installing Flutter stable to $FLUTTER_HOME"
            "$git_cmd" clone --depth 1 --branch stable https://github.com/flutter/flutter.git "$FLUTTER_HOME"
        elif [ ! -x "$FLUTTER_HOME/bin/flutter" ]; then
            warn "$FLUTTER_HOME exists but does not contain a Flutter installation."
            return 0
        fi

        export PATH="$FLUTTER_HOME/bin:$PATH"
    fi

    if command -v flutter >/dev/null 2>&1; then
        flutter channel stable
        flutter upgrade
        flutter precache --android
        write_flutter_local_properties
        flutter doctor
    else
        warn "Flutter was installed but is not on PATH. Add $FLUTTER_HOME/bin to PATH."
    fi
}

install_ollama() {
    local ollama_cmd=""

    if ollama_cmd="$(find_ollama)"; then
        log "Ollama is already available."
    elif [ "$IS_WINDOWS" = true ]; then
        warn "Ollama was requested through winget."
    elif [ "$OS" = "Darwin" ]; then
        brew install ollama || brew install --cask ollama
    else
        curl -fsSL https://ollama.com/install.sh | sh
    fi

    if [ -z "$ollama_cmd" ]; then
        ollama_cmd="$(find_ollama || true)"
    fi

    if [ -n "$ollama_cmd" ]; then
        if wait_for_ollama_service "$ollama_cmd"; then
            "$ollama_cmd" pull "$OLLAMA_MODEL"
        else
            warn "Skipping $OLLAMA_MODEL pull because Ollama is not operational."
        fi
    else
        warn "Ollama is installed but not on PATH in this shell."
    fi
}

log "Initializing Maxima Master Key Core cross-platform bootstrapper..."

case "$OS" in
    Linux)
        install_linux_dependencies
        ;;
    Darwin)
        install_macos_dependencies
        ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT*|Windows)
        install_windows_dependencies
        ;;
    *)
        warn "Unsupported operating system: $OS"
        ;;
esac

install_flutter
install_ollama

log "Bootstrap complete. Secure offline mode can now be configured by the application."
