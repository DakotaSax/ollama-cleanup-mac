#!/usr/bin/env bash
#
# ollama-cleanup.sh
#
# Identifies orphaned Ollama model blobs and manifests that are no longer
# referenced by any model visible in `ollama list`, then generates a
# removal script (ollama-clean-delete.sh) for human review before deletion.
#
# Usage: ./ollama-cleanup.sh [--models-dir <path>] [--output <path>]
#
# Options:
#   --models-dir <path>   Path to Ollama models directory
#                         (default: ~/.ollama/models)
#   --output <path>       Path for generated removal script
#                         (default: ./ollama-clean-delete.sh)
#   --dry-run             Show summary only, don't generate script
#   -h, --help            Show this help message

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
MODELS_DIR="${HOME}/.ollama/models"
OUTPUT_SCRIPT="./ollama-clean-delete.sh"
DRY_RUN=false

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --models-dir)
            if [[ $# -lt 2 ]]; then echo "ERROR: --models-dir requires a path." >&2; exit 1; fi
            MODELS_DIR="$2"; shift 2 ;;
        --output)
            if [[ $# -lt 2 ]]; then echo "ERROR: --output requires a path." >&2; exit 1; fi
            OUTPUT_SCRIPT="$2"; shift 2 ;;
        --dry-run)
            DRY_RUN=true; shift ;;
        -h|--help)
            sed -n '3,17p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *)
            echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

BLOBS_DIR="${MODELS_DIR}/blobs"
MANIFESTS_DIR="${MODELS_DIR}/manifests"

# Use temporary newline-delimited files for membership checks. This avoids
# Bash 4-only associative arrays and lets the script run with macOS Bash 3.2.
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ollama-cleanup.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
trap 'exit 1' HUP INT TERM
REFERENCED_BLOBS_FILE="${TMP_DIR}/referenced-blobs"
ACTIVE_MANIFEST_DIRS_FILE="${TMP_DIR}/active-manifest-dirs"
ACTIVE_MANIFEST_FILES_FILE="${TMP_DIR}/active-manifest-files"
ORPHAN_MANIFEST_BLOBS_FILE="${TMP_DIR}/orphan-manifest-blobs"
: > "$REFERENCED_BLOBS_FILE"
: > "$ACTIVE_MANIFEST_DIRS_FILE"
: > "$ACTIVE_MANIFEST_FILES_FILE"
: > "$ORPHAN_MANIFEST_BLOBS_FILE"

contains_line() {
    grep -Fqx "$1" "$2"
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
if ! command -v ollama >/dev/null 2>&1; then
    echo "ERROR: 'ollama' command not found. Is Ollama installed?" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: 'jq' is required but not installed." >&2
    echo "       Install it with: brew install jq" >&2
    exit 1
fi

if [[ ! -d "$MODELS_DIR" ]]; then
    echo "ERROR: Models directory not found: ${MODELS_DIR}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 1: Get whitelisted models from `ollama list`
# ---------------------------------------------------------------------------
echo "=== Ollama Orphan Cleanup ==="
echo ""
echo "Models directory: ${MODELS_DIR}"
echo ""
echo "--- Active models (from 'ollama list') ---"

# ollama list output: NAME ID SIZE MODIFIED
# Bash 3.2 has no mapfile, so read the model names into an indexed array.
ACTIVE_MODELS=()
while IFS= read -r model_name; do
    [[ -n "$model_name" ]] && ACTIVE_MODELS+=("$model_name")
done < <(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}')

if [[ ${#ACTIVE_MODELS[@]} -eq 0 ]]; then
    echo "(none)"
    echo ""
    echo "WARNING: ollama list returned no models. This would mark everything"
    echo "         for removal. Aborting as a safety measure."
    exit 1
fi

for m in "${ACTIVE_MODELS[@]}"; do
    echo "  ${m}"
done
echo ""

# ---------------------------------------------------------------------------
# Step 2: Collect blob hashes referenced by active models
# ---------------------------------------------------------------------------
# Active model names are like "llama3:latest". The manifest lives at:
#   manifests/registry.ollama.ai/library/<model>/<tag>
# Namespaced models map to:
#   manifests/registry.ollama.ai/<user>/<model>/<tag>

declare -a ACTIVE_MANIFEST_DIRS=()
declare -a ACTIVE_MANIFEST_FILES=()

for model_tag in "${ACTIVE_MODELS[@]}"; do
    model="${model_tag%%:*}"
    tag="${model_tag##*:}"
    if [[ "$model" == "$tag" ]]; then
        tag="latest"
    fi

    if [[ "$model" == */* ]]; then
        namespace="${model%%/*}"
        name="${model##*/}"
        manifest_file="${MANIFESTS_DIR}/registry.ollama.ai/${namespace}/${name}/${tag}"
    else
        manifest_file="${MANIFESTS_DIR}/registry.ollama.ai/library/${model}/${tag}"
    fi

    if [[ ! -f "$manifest_file" ]]; then
        echo "WARNING: Manifest not found for '${model_tag}': ${manifest_file}"
        echo "         This model will still be protected (it's in ollama list)."
        continue
    fi

    ACTIVE_MANIFEST_FILES+=("$manifest_file")
    printf '%s\n' "$manifest_file" >> "$ACTIVE_MANIFEST_FILES_FILE"
    model_dir="$(dirname "$manifest_file")"
    ACTIVE_MANIFEST_DIRS+=("$model_dir")
    printf '%s\n' "$model_dir" >> "$ACTIVE_MANIFEST_DIRS_FILE"

    while IFS= read -r digest; do
        blob_name="${digest/:/-}"
        printf '%s\n' "$blob_name" >> "$REFERENCED_BLOBS_FILE"
    done < <(jq -r '
        [ .config.digest // empty ] +
        [ .layers[]?.digest // empty ] |
        .[]
    ' "$manifest_file" 2>/dev/null)
done

REFERENCED_BLOB_COUNT="$(sort -u "$REFERENCED_BLOBS_FILE" | wc -l | tr -d '[:space:]')"
echo "Referenced blobs (in use): ${REFERENCED_BLOB_COUNT}"
echo ""

# ---------------------------------------------------------------------------
# Step 3: Find orphaned manifests
# ---------------------------------------------------------------------------
declare -a ORPHANED_MANIFEST_FILES=()
declare -a ORPHANED_MANIFEST_DIRS=()

if [[ -d "$MANIFESTS_DIR" ]]; then
    while IFS= read -r mf; do
        if ! contains_line "$mf" "$ACTIVE_MANIFEST_FILES_FILE"; then
            ORPHANED_MANIFEST_FILES+=("$mf")
        fi
    done < <(find "$MANIFESTS_DIR" -type f 2>/dev/null)

    # macOS/BSD find does not support GNU find's -maxdepth option. Inspect
    # directories portably and only consider directories containing files
    # directly (the model/tag-directory level of Ollama's manifest tree).
    while IFS= read -r mdir; do
        if ! contains_line "$mdir" "$ACTIVE_MANIFEST_DIRS_FILE"; then
            has_direct_file=false
            for entry in "$mdir"/*; do
                if [[ -f "$entry" ]]; then
                    has_direct_file=true
                    break
                fi
            done
            if [[ "$has_direct_file" == true ]]; then
                ORPHANED_MANIFEST_DIRS+=("$mdir")
            fi
        fi
    done < <(find "$MANIFESTS_DIR" -type d 2>/dev/null)
fi

# ---------------------------------------------------------------------------
# Step 4: Collect blobs referenced by orphaned manifests
# ---------------------------------------------------------------------------
for mf in "${ORPHANED_MANIFEST_FILES[@]}"; do
    while IFS= read -r digest; do
        blob_name="${digest/:/-}"
        printf '%s\n' "$blob_name" >> "$ORPHAN_MANIFEST_BLOBS_FILE"
    done < <(jq -r '
        [ .config.digest // empty ] +
        [ .layers[]?.digest // empty ] |
        .[]
    ' "$mf" 2>/dev/null)
done

# ---------------------------------------------------------------------------
# Step 5: Find orphaned blobs and classify them
# ---------------------------------------------------------------------------
declare -a ORPHANED_BLOBS=()
declare -a FULLY_ORPHANED_BLOBS=()
ORPHANED_BYTES=0
FULLY_ORPHANED_BYTES=0

if [[ -d "$BLOBS_DIR" ]]; then
    while IFS= read -r blob_path; do
        blob_name="$(basename "$blob_path")"
        if ! contains_line "$blob_name" "$REFERENCED_BLOBS_FILE"; then
            # macOS stat uses -f (unlike GNU stat's --printf).
            size="$(stat -f%z "$blob_path" 2>/dev/null || echo 0)"
            if contains_line "$blob_name" "$ORPHAN_MANIFEST_BLOBS_FILE"; then
                ORPHANED_BLOBS+=("$blob_path")
                ORPHANED_BYTES=$((ORPHANED_BYTES + size))
            else
                FULLY_ORPHANED_BLOBS+=("$blob_path")
                FULLY_ORPHANED_BYTES=$((FULLY_ORPHANED_BYTES + size))
            fi
        fi
    done < <(find "$BLOBS_DIR" -type f 2>/dev/null)
fi

# ---------------------------------------------------------------------------
# Step 6: Summary
# ---------------------------------------------------------------------------
human_size() {
    local bytes=$1
    if (( bytes >= 1073741824 )); then
        printf "%.1f GB" "$(echo "scale=1; $bytes / 1073741824" | bc)"
    elif (( bytes >= 1048576 )); then
        printf "%.1f MB" "$(echo "scale=1; $bytes / 1048576" | bc)"
    elif (( bytes >= 1024 )); then
        printf "%.1f KB" "$(echo "scale=1; $bytes / 1024" | bc)"
    else
        printf "%d bytes" "$bytes"
    fi
}

TOTAL_BLOB_BYTES=$((ORPHANED_BYTES + FULLY_ORPHANED_BYTES))

echo "--- Orphaned items found ---"
echo "  Orphaned blobs:       ${#ORPHANED_BLOBS[@]}  (referenced by orphaned manifests)"
echo "  Fully orphaned blobs: ${#FULLY_ORPHANED_BLOBS[@]}  (not in any manifest)"
echo "  Orphaned manifests:   ${#ORPHANED_MANIFEST_FILES[@]}"
echo "  Orphaned model dirs:  ${#ORPHANED_MANIFEST_DIRS[@]}"
echo "  Reclaimable space:    $(human_size "$TOTAL_BLOB_BYTES") (blobs only)"
echo ""

TOTAL_ORPHANS=$(( ${#ORPHANED_BLOBS[@]} + ${#FULLY_ORPHANED_BLOBS[@]} + ${#ORPHANED_MANIFEST_FILES[@]} + ${#ORPHANED_MANIFEST_DIRS[@]} ))

if [[ $TOTAL_ORPHANS -eq 0 ]]; then
    echo "No orphaned files found. Your models directory is clean!"
    exit 0
fi

if [[ "$DRY_RUN" == true ]]; then
    echo "(Dry run — no removal script generated)"
    exit 0
fi

# ---------------------------------------------------------------------------
# Step 7: Generate removal script
# ---------------------------------------------------------------------------
cat > "$OUTPUT_SCRIPT" << 'HEADER'
#!/usr/bin/env bash
#
# ollama-clean-delete.sh — Auto-generated by ollama-cleanup.sh
#
# Review the commands below, then run this script to remove orphaned
# Ollama model files. This is a destructive operation — make sure you
# are satisfied with what will be deleted before running.
#
# Usage: bash ollama-clean-delete.sh
#

set -euo pipefail

echo "=== Ollama Legacy Model Removal ==="
echo ""
echo "This will permanently delete orphaned model files."
echo "You MUST review this generated file before running."
read -rp "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo ""
REMOVED=0
ERRORS=0

safe_rm() {
    local target="$1"
    if [[ -e "$target" ]]; then
        if rm -f "$target" 2>/dev/null; then
            echo "  Removed: $target"
            ((++REMOVED))
        else
            echo "  ✗ Failed:  $target" >&2
            ((++ERRORS))
        fi
    else
        echo "  - Skipped (already gone): $target"
    fi
}

safe_rmdir() {
    local target="$1"
    if [[ -d "$target" ]]; then
        if rm -rf "$target" 2>/dev/null; then
            echo "  Removed dir: $target"
            ((++REMOVED))
        else
            echo "  ✗ Failed dir:  $target" >&2
            ((++ERRORS))
        fi
    else
        echo "  - Skipped (already gone): $target"
    fi
}

HEADER

if [[ ${#ORPHANED_BLOBS[@]} -gt 0 ]]; then
    {
        echo ""
        echo "# --- Orphaned blobs ---"
        for blob in "${ORPHANED_BLOBS[@]}"; do
            size="$(stat -f%z "$blob" 2>/dev/null || echo 0)"
            echo "safe_rm \"${blob}\"  # $(human_size "$size")"
        done
    } >> "$OUTPUT_SCRIPT"
fi

if [[ ${#ORPHANED_MANIFEST_FILES[@]} -gt 0 ]]; then
    {
        echo ""
        echo "# --- Orphaned manifest files ---"
        for mf in "${ORPHANED_MANIFEST_FILES[@]}"; do
            echo "safe_rm \"${mf}\""
        done
    } >> "$OUTPUT_SCRIPT"
fi

if [[ ${#ORPHANED_MANIFEST_DIRS[@]} -gt 0 ]]; then
    {
        echo ""
        echo "# --- Orphaned model directories ---"
        for mdir in "${ORPHANED_MANIFEST_DIRS[@]}"; do
            echo "safe_rmdir \"${mdir}\""
        done
    } >> "$OUTPUT_SCRIPT"
fi

if [[ ${#FULLY_ORPHANED_BLOBS[@]} -gt 0 ]]; then
    {
        echo ""
        echo "# --- Fully orphaned blobs (not referenced by any manifest) ---"
        echo "echo \"\""
        echo "echo \"=== Fully Orphaned Blobs ===\""
        echo "echo \"The following ${#FULLY_ORPHANED_BLOBS[@]} blob(s) ($(human_size "$FULLY_ORPHANED_BYTES")) are not referenced\""
        echo "echo \"by any manifest file — active or orphaned. These may be leftover\""
        echo "echo \"from interrupted downloads or previous cleanup.\""
        echo "echo \"\""
        echo "read -rp \"Delete fully orphaned blobs? [y/N] \" confirm_fully"
        echo "if [[ \"\$confirm_fully\" =~ ^[Yy]\$ ]]; then"
        for blob in "${FULLY_ORPHANED_BLOBS[@]}"; do
            size="$(stat -f%z "$blob" 2>/dev/null || echo 0)"
            echo "    safe_rm \"${blob}\"  # $(human_size "$size")"
        done
        echo "else"
        echo "    echo \"Skipped fully orphaned blobs.\""
        echo "fi"
    } >> "$OUTPUT_SCRIPT"
fi

cat >> "$OUTPUT_SCRIPT" << 'FOOTER'

echo ""
echo "--- Done ---"
echo "  Removed: ${REMOVED}"
echo "  Errors:  ${ERRORS}"

# Clean up empty directories left behind
MODELS_DIR_CLEANUP="${HOME}/.ollama/models/manifests"
if [[ -d "$MODELS_DIR_CLEANUP" ]]; then
    find "$MODELS_DIR_CLEANUP" -type d -empty -delete 2>/dev/null || true
    echo "  Cleaned up empty directories."
fi

echo "You can now safely delete this script."
FOOTER

chmod +x "$OUTPUT_SCRIPT"

echo "Removal script generated: ${OUTPUT_SCRIPT}"
echo ""
echo "Next steps:"
echo "  1. Review the script:  less ${OUTPUT_SCRIPT}"
echo "  2. Run it:             bash ${OUTPUT_SCRIPT}"
echo ""
