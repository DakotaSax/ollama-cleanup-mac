#!/usr/bin/env bash
# Uninstalls the ollama-cleanup terminal command and removes its PATH entry.
set -euo pipefail

BIN_DIR="${HOME}/.local/bin"
INSTALLED_COMMAND="${BIN_DIR}/ollama-cleanup"
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
PATH_COMMENT='# Added by ollama-cleanup installer'

rm -f "$INSTALLED_COMMAND"
echo "Removed ${INSTALLED_COMMAND} (if it was installed)."

case "${SHELL##*/}" in
    zsh) SHELL_CONFIG="${HOME}/.zshrc" ;;
    bash) SHELL_CONFIG="${HOME}/.bash_profile" ;;
    *) SHELL_CONFIG="" ;;
esac

if [[ -n "$SHELL_CONFIG" && -f "$SHELL_CONFIG" ]]; then
    TEMP_FILE="$(mktemp "${TMPDIR:-/tmp}/ollama-cleanup-uninstall.XXXXXX")"
    trap 'rm -f "$TEMP_FILE"' EXIT
    awk -v path_line="$PATH_LINE" -v path_comment="$PATH_COMMENT" \
        '$0 != path_line && $0 != path_comment' "$SHELL_CONFIG" > "$TEMP_FILE"
    cat "$TEMP_FILE" > "$SHELL_CONFIG"
    echo "Removed the ollama-cleanup PATH entry from ${SHELL_CONFIG} (if present)."
elif [[ -z "$SHELL_CONFIG" ]]; then
    echo "Could not identify your shell configuration file. If you added this PATH entry manually, remove it yourself:"
    echo "  ${PATH_LINE}"
fi

echo "Open a new Terminal window (or restart your shell) to finish uninstalling."
