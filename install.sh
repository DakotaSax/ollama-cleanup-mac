#!/usr/bin/env bash
# Installs ollama-cleanup as a command in ~/.local/bin.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_SCRIPT="${SCRIPT_DIR}/ollama-cleanup.sh"
BIN_DIR="${HOME}/.local/bin"

if [[ ! -f "$SOURCE_SCRIPT" ]]; then
    echo "ERROR: Could not find ${SOURCE_SCRIPT}" >&2
    exit 1
fi

mkdir -p "$BIN_DIR"
cp "$SOURCE_SCRIPT" "${BIN_DIR}/ollama-cleanup"
chmod +x "${BIN_DIR}/ollama-cleanup"

PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
case "${SHELL##*/}" in
    zsh) SHELL_CONFIG="${HOME}/.zshrc" ;;
    bash) SHELL_CONFIG="${HOME}/.bash_profile" ;;
    *) SHELL_CONFIG="" ;;
esac

if [[ -n "$SHELL_CONFIG" ]]; then
    touch "$SHELL_CONFIG"
    if ! grep -Fqx "$PATH_LINE" "$SHELL_CONFIG"; then
        printf '\n# Added by ollama-cleanup installer\n%s\n' "$PATH_LINE" >> "$SHELL_CONFIG"
        echo "Added ~/.local/bin to PATH in ${SHELL_CONFIG}."
    fi
fi

echo "Installed command: ${BIN_DIR}/ollama-cleanup"
if [[ ":${PATH}:" != *":${BIN_DIR}:"* ]]; then
    echo "Open a new Terminal window (or run: source ${SHELL_CONFIG:-your-shell-config}) to load the PATH change."
else
    echo "Run it with: ollama-cleanup"
fi
