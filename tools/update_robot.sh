#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
STAGE_DIR="$PROJECT_ROOT/.maxima/update-staging"
MODE="${1:-check}"
COMPONENT="${2:-}"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5:7b-instruct}"

mkdir -p "$STAGE_DIR"

log() {
    printf '[update-robot] %s\n' "$*"
}

fail() {
    printf '[update-robot] ERROR: %s\n' "$*" >&2
    exit 1
}

version_of() {
    if command -v "$1" >/dev/null 2>&1; then
        "$1" --version 2>/dev/null | head -n 1 || true
    else
        printf 'missing\n'
    fi
}

write_environment_report() {
    {
        printf 'generated_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'flutter=%s\n' "$(version_of flutter)"
        printf 'cmake=%s\n' "$(version_of cmake)"
        printf 'ollama=%s\n' "$(version_of ollama)"
        printf 'git=%s\n' "$(version_of git)"
    } > "$STAGE_DIR/environment.txt"
}

run_sandbox_checks() {
    if command -v flutter >/dev/null 2>&1; then
        (
            cd "$PROJECT_ROOT"
            flutter pub get
            flutter analyze
        ) > "$STAGE_DIR/flutter-check.log" 2>&1
    else
        printf 'flutter missing\n' > "$STAGE_DIR/flutter-check.log"
    fi

    if command -v cmake >/dev/null 2>&1; then
        cmake -S "$PROJECT_ROOT/src" -B "$STAGE_DIR/cmake-check" \
            > "$STAGE_DIR/cmake-check.log" 2>&1
    else
        printf 'cmake missing\n' > "$STAGE_DIR/cmake-check.log"
    fi
}

stage_component() {
    case "$COMPONENT" in
        flutter|cmake|ollama)
            ;;
        *)
            fail "Unknown component '$COMPONENT'. Use flutter, cmake, or ollama."
            ;;
    esac

    {
        printf 'component=%s\n' "$COMPONENT"
        printf 'created_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'approval=required\n'
    } > "$STAGE_DIR/$COMPONENT.plan"

    log "Staged $COMPONENT update plan at $STAGE_DIR/$COMPONENT.plan"
}

apply_component() {
    case "$COMPONENT" in
        flutter)
            command -v flutter >/dev/null 2>&1 || fail "flutter is not installed"
            flutter channel stable
            flutter upgrade
            flutter precache --android
            ;;
        ollama)
            command -v ollama >/dev/null 2>&1 || fail "ollama is not installed"
            ollama pull "$OLLAMA_MODEL"
            ;;
        cmake)
            local sudo_cmd=""
            if command -v sudo >/dev/null 2>&1; then
                sudo_cmd="sudo"
            fi
            case "$(uname -s 2>/dev/null || echo Windows)" in
                Linux)
                    if [ -f /etc/debian_version ]; then
                        $sudo_cmd apt-get update
                        $sudo_cmd apt-get install -y cmake
                    elif [ -f /etc/fedora-release ]; then
                        $sudo_cmd dnf install -y cmake
                    elif [ -f /etc/arch-release ]; then
                        $sudo_cmd pacman -Syu --noconfirm cmake
                    else
                        fail "Unsupported Linux distribution"
                    fi
                    ;;
                Darwin)
                    command -v brew >/dev/null 2>&1 || fail "Homebrew is unavailable"
                    brew upgrade cmake || brew install cmake
                    ;;
                MINGW*|MSYS*|CYGWIN*|Windows_NT*|Windows)
                    command -v winget >/dev/null 2>&1 || fail "winget is unavailable"
                    winget upgrade --id Kitware.CMake --exact --silent \
                        --accept-source-agreements --accept-package-agreements || \
                    winget install --id Kitware.CMake --exact --silent \
                        --accept-source-agreements --accept-package-agreements
                    ;;
                *)
                    fail "Unsupported operating system"
                    ;;
            esac
            ;;
        *)
            fail "Unknown component '$COMPONENT'. Use flutter, cmake, or ollama."
            ;;
    esac
}

case "$MODE" in
    check)
        write_environment_report
        run_sandbox_checks
        log "Environment report and sandbox checks written to $STAGE_DIR"
        ;;
    stage)
        write_environment_report
        run_sandbox_checks
        stage_component
        ;;
    approve)
        [ -n "$COMPONENT" ] || fail "Missing component name"
        [ -f "$STAGE_DIR/$COMPONENT.plan" ] || \
            fail "No staged plan exists for $COMPONENT"
        [ "${MAXIMA_MASTER_APPROVAL:-}" = "approved" ] || \
            fail "Set MAXIMA_MASTER_APPROVAL=approved to apply a staged plan"
        apply_component
        log "Approved component applied: $COMPONENT"
        ;;
    *)
        fail "Usage: $0 [check|stage <component>|approve <component>]"
        ;;
esac
