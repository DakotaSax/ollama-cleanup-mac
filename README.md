# ollama-cleanup

Identify and remove orphaned model files left behind after an Ollama upgrade.

## The problem

When Ollama is upgraded, some older models may become unsupported and disappear from `ollama list` but their blobs and manifest files remain on disk, consuming significant storage. Since `ollama rm` only removes active models, it cannot clean up these orphaned files.

## What this does

`ollama-cleanup.sh` bridges that gap:

1. Queries `ollama list` to build a whitelist of active models.
2. Parses manifest JSON files to determine which blobs are still referenced.
3. Identifies orphaned blobs and manifests that are no longer needed.
4. Distinguishes **fully orphaned blobs** (not referenced by any manifest) from blobs referenced only by orphaned manifests.
5. Generates a **human-reviewable** `ollama-clean-delete.sh` script, nothing is deleted automatically.

## Requirements

- **macOS**
- **Ollama** (installed and running)
- **jq** — for parsing manifest JSON (`brew install jq`)
- **Bash 4.0+** — macOS includes Bash 3.2 by default, so install a newer Bash with Homebrew (`brew install bash`)
- **bc** — for human-readable size calculations (`brew install bc`)
- **Homebrew** — used to install the macOS command-line dependencies

## Usage

```bash
# Clone or download
git clone https://github.com/DakotaSax/ollama-cleanup-mac.git
cd ollama-cleanup-mac

# Make executable
chmod +x ollama-cleanup.sh

# Run it
./ollama-cleanup.sh
```

This produces a `ollama-clean-delete.sh` script. Review it, then run it. **IMPORTANT: REVIEW IT.**

```bash
# Review what will be deleted
less ollama-clean-delete.sh

# Execute the cleanup
bash ollama-clean-delete.sh
```

### Options

| Flag | Description | Default |
|---|---|---|
| `--models-dir <path>` | Path to Ollama models directory | `~/.ollama/models` |
| `--output <path>` | Path for the generated removal script | `./ollama-clean-delete.sh` |
| `--dry-run` | Show summary only, don't generate a script | — |
| `-h, --help` | Show help | — |

### Examples

```bash
# Custom models directory
./ollama-cleanup.sh --models-dir /data/ollama/models

# Just see what's orphaned without generating a script
./ollama-cleanup.sh --dry-run

# Custom output path
./ollama-cleanup.sh --output ~/cleanup-2026-02-27.sh
```

## How it works

Ollama stores models in a content-addressable layout:

```
~/.ollama/models/
├── blobs/
│   ├── sha256-aabbcc...    large model weight files
│   └── sha256-ddeeff...
└── manifests/
    └── registry.ollama.ai/
        └── library/
            ├── llama3/
            │   └── latest   JSON manifest referencing blobs by digest
            └── oldmodel/
                └── latest   orphaned if not in `ollama list`
```

Each manifest file is JSON containing a `config.digest` and a `layers[].digest` array. These digests map to filenames in the `blobs/` directory (with `:` replaced by `-`).

The script parses every active model's manifest to build the set of referenced blobs, then flags anything outside that set as orphaned. Orphaned blobs are further classified:

- **Orphaned blobs** - referenced by an orphaned manifest but not by any active model.
- **Fully orphaned blobs** - not referenced by any manifest at all (active or orphaned). These may be remnants of interrupted downloads or previous partial cleanup.

## Safety

- **Nothing is deleted directly.** The tool generates a removal script for your review.
- The generated script prompts for confirmation before executing.
- **Fully orphaned blobs** (not in any manifest) require a separate, additional confirmation before deletion.
- If `ollama list` returns no models, the script aborts rather than marking everything for deletion.
- Each removal is wrapped in a safe helper that handles missing files gracefully.

## License

MIT
