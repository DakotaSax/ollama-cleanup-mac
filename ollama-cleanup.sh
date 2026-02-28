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
            MODELS_DIR="$2"; shift 2 ;;
        --output)
            OUTPUT_SCRIPT="$2"; shift 2 ;;
        --dry-run)
            DRY_RUN=true; shift ;;
        -h|--help)
            sed -n '3,14p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *)
            echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

BLOBS_DIR="${MODELS_DIR}/blobs"
MANIFESTS_DIR="${MODELS_DIR}/manifests"

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
if ! command -v ollama &>/dev/null; then
    echo "ERROR: 'ollama' command not found. Is Ollama installed?" >&2
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "ERROR: 'jq' is required but not installed." >&2
    echo "       Install it with: sudo apt install jq" >&2
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
# The NAME column is like "llama3:latest" or "mymodel:v2"
mapfile -t ACTIVE_MODELS < <(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}')

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
#
# Some models may use a custom registry or namespace, e.g. "user/model:tag",
# which maps to: manifests/registry.ollama.ai/<user>/<model>/<tag>
#
# We also need to handle the default registry if the name has no slash.

declare -A REFERENCED_BLOBS   # set of blob filenames we want to keep
declare -A ACTIVE_MANIFEST_DIRS  # set of manifest directories to keep
declare -A ACTIVE_MANIFEST_FILES # set of manifest files to keep

for model_tag in "${ACTIVE_MODELS[@]}"; do
    # Split model_tag into model and tag
    model="${model_tag%%:*}"
    tag="${model_tag##*:}"
    # If no tag was specified (no colon), default to "latest"
    if [[ "$model" == "$tag" ]]; then
        tag="latest"
    fi

    # Determine manifest path
    if [[ "$model" == */* ]]; then
        # Has a namespace: user/modelname
        namespace="${model%%/*}"
        name="${model##*/}"
        manifest_file="${MANIFESTS_DIR}/registry.ollama.ai/${namespace}/${name}/${tag}"
    else
        # Default library namespace
        manifest_file="${MANIFESTS_DIR}/registry.ollama.ai/library/${model}/${tag}"
    fi

    if [[ ! -f "$manifest_file" ]]; then
        echo "WARNING: Manifest not found for '${model_tag}': ${manifest_file}"
        echo "         This model will still be protected (it's in ollama list)."
        continue
    fi

    # Track the manifest file and its parent directory
    ACTIVE_MANIFEST_FILES["${manifest_file}"]=1
    model_dir="$(dirname "$manifest_file")"
    ACTIVE_MANIFEST_DIRS["${model_dir}"]=1

    # Parse the manifest JSON to extract all referenced digests
    # Manifests have: config.digest, and layers[].digest
    while IFS= read -r digest; do
        # Convert "sha256:abc123..." to blob filename "sha256-abc123..."
        blob_name="${digest/:/-}"
        REFERENCED_BLOBS["${blob_name}"]=1
    done < <(jq -r '
        [ .config.digest // empty ] +
        [ .layers[]?.digest // empty ] |
        .[]
    ' "$manifest_file" 2>/dev/null)
done

echo "Referenced blobs (in use): ${#REFERENCED_BLOBS[@]}"
echo ""

# ---------------------------------------------------------------------------
# Step 3: Find orphaned manifests
# ---------------------------------------------------------------------------
declare -a ORPHANED_MANIFEST_FILES=()
declare -a ORPHANED_MANIFEST_DIRS=()

if [[ -d "$MANIFESTS_DIR" ]]; then
    # Find all manifest files (they're the leaf files in the tree)
    while IFS= read -r mf; do
        if [[ -z "${ACTIVE_MANIFEST_FILES[$mf]+_}" ]]; then
            ORPHANED_MANIFEST_FILES+=("$mf")
        fi
    done < <(find "$MANIFESTS_DIR" -type f 2>/dev/null)

    # Find model directories that can be removed entirely
    # These are directories at the model-name level (parent of tag files)
    # that contain no active manifests
    while IFS= read -r mdir; do
        if [[ -z "${ACTIVE_MANIFEST_DIRS[$mdir]+_}" ]]; then
            # Verify this looks like a model dir (has files, not just subdirs)
            if find "$mdir" -maxdepth 1 -type f | grep -q .; then
                ORPHANED_MANIFEST_DIRS+=("$mdir")
            fi
        fi
    done < <(find "$MANIFESTS_DIR" -mindepth 3 -maxdepth 4 -type d 2>/dev/null)
fi

# ---------------------------------------------------------------------------
# Step 4: Collect blobs referenced by orphaned manifests
# ---------------------------------------------------------------------------
declare -A ORPHAN_MANIFEST_BLOBS  # blobs referenced by orphaned manifests

for mf in "${ORPHANED_MANIFEST_FILES[@]}"; do
    while IFS= read -r digest; do
        blob_name="${digest/:/-}"
        ORPHAN_MANIFEST_BLOBS["${blob_name}"]=1
    done < <(jq -r '
        [ .config.digest // empty ] +
        [ .layers[]?.digest // empty ] |
        .[]
    ' "$mf" 2>/dev/null)
done

# ---------------------------------------------------------------------------
# Step 5: Find orphaned blobs and classify them
# ---------------------------------------------------------------------------
declare -a ORPHANED_BLOBS=()        # referenced by orphaned manifests only
declare -a FULLY_ORPHANED_BLOBS=()  # not referenced by any manifest
ORPHANED_BYTES=0
FULLY_ORPHANED_BYTES=0

if [[ -d "$BLOBS_DIR" ]]; then
    while IFS= read -r blob_path; do
        blob_name="$(basename "$blob_path")"
        if [[ -z "${REFERENCED_BLOBS[$blob_name]+_}" ]]; then
            size=$(stat --printf="%s" "$blob_path" 2>/dev/null || echo 0)
            if [[ -n "${ORPHAN_MANIFEST_BLOBS[$blob_name]+_}" ]]; then
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
echo "  Reclaimable space:    $(human_size $TOTAL_BLOB_BYTES) (blobs only)"
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

# Write orphaned blob removals
if [[ ${#ORPHANED_BLOBS[@]} -gt 0 ]]; then
    {
        echo ""
        echo "# --- Orphaned blobs ---"
        for blob in "${ORPHANED_BLOBS[@]}"; do
            size=$(stat --printf="%s" "$blob" 2>/dev/null || echo 0)
            echo "safe_rm \"${blob}\"  # $(human_size $size)"
        done
    } >> "$OUTPUT_SCRIPT"
fi

# Write orphaned manifest file removals
if [[ ${#ORPHANED_MANIFEST_FILES[@]} -gt 0 ]]; then
    {
        echo ""
        echo "# --- Orphaned manifest files ---"
        for mf in "${ORPHANED_MANIFEST_FILES[@]}"; do
            echo "safe_rm \"${mf}\""
        done
    } >> "$OUTPUT_SCRIPT"
fi

# Write orphaned manifest directory removals
if [[ ${#ORPHANED_MANIFEST_DIRS[@]} -gt 0 ]]; then
    {
        echo ""
        echo "# --- Orphaned model directories ---"
        for mdir in "${ORPHANED_MANIFEST_DIRS[@]}"; do
            echo "safe_rmdir \"${mdir}\""
        done
    } >> "$OUTPUT_SCRIPT"
fi

# Write fully orphaned blobs section (separate confirmation)
if [[ ${#FULLY_ORPHANED_BLOBS[@]} -gt 0 ]]; then
    {
        echo ""
        echo "# --- Fully orphaned blobs (not referenced by any manifest) ---"
        echo "echo \"\""
        echo "echo \"=== Fully Orphaned Blobs ===\""
        echo "echo \"The following ${#FULLY_ORPHANED_BLOBS[@]} blob(s) ($(human_size $FULLY_ORPHANED_BYTES)) are not referenced\""
        echo "echo \"by any manifest file — active or orphaned. These may be leftover\""
        echo "echo \"from interrupted downloads or previous cleanup.\""
        echo "echo \"\""
        echo "read -rp \"Delete fully orphaned blobs? [y/N] \" confirm_fully"
        echo "if [[ \"\$confirm_fully\" =~ ^[Yy]\$ ]]; then"
        for blob in "${FULLY_ORPHANED_BLOBS[@]}"; do
            size=$(stat --printf="%s" "$blob" 2>/dev/null || echo 0)
            echo "    safe_rm \"${blob}\"  # $(human_size $size)"
        done
        echo "else"
        echo "    echo \"Skipped fully orphaned blobs.\""
        echo "fi"
    } >> "$OUTPUT_SCRIPT"
fi

# Write footer
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
