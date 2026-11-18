# ollama-cleanup-mac

A macOS utility that identifies orphaned Ollama model blobs and manifests left behind after an Ollama upgrade.

## The problem

When Ollama is upgraded, older models may disappear from `ollama list` while their blobs and manifest files remain on disk. These files can consume significant storage.

## What this does

`ollama-cleanup`:

1. Queries `ollama list` to build a whitelist of active models.
2. Parses active and orphaned manifest JSON files.
3. Identifies orphaned blobs and manifests that are no longer needed.
4. Distinguishes fully orphaned blobs from blobs referenced only by orphaned manifests.
5. Generates a human-reviewable `ollama-clean-delete.sh` script. Nothing is deleted automatically.

## Requirements

- macOS
- Ollama installed and running
- `jq` — `brew install jq`
- `bc` — `brew install bc`
- Homebrew, recommended for installing dependencies

The script is compatible with macOS's default Bash 3.2. Bash 4.0 or newer is not required.

## Install as a terminal command

```bash
git clone https://github.com/DakotaSax/ollama-cleanup-mac.git
cd ollama-cleanup-mac
chmod +x install.sh
./install.sh
```

The installer copies the utility to `~/.local/bin/ollama-cleanup` and adds `~/.local/bin` to `PATH` in your shell configuration when needed.

Open a new Terminal window, or reload your shell configuration, then run:

```bash
ollama-cleanup
```

## Run without installing

```bash
cd ollama-cleanup-mac
chmod +x ollama-cleanup.sh
./ollama-cleanup.sh
```

## Review and execute cleanup

The utility creates `ollama-clean-delete.sh` in the current directory. Review it before deleting anything:

```bash
less ollama-clean-delete.sh
bash ollama-clean-delete.sh
```

**IMPORTANT: Review the generated script.** It is only created as a separate, explicit cleanup step.

## Options

| Flag | Description | Default |
|---|---|---|
| `--models-dir <path>` | Path to the Ollama models directory | `~/.ollama/models` |
| `--output <path>` | Path for the generated removal script | `./ollama-clean-delete.sh` |
| `--dry-run` | Show the summary without generating a script | — |
| `-h, --help` | Show help | — |

## Examples

```bash
# Run as an installed terminal command
ollama-cleanup

# Just see what is orphaned
ollama-cleanup --dry-run

# Use a custom models directory
ollama-cleanup --models-dir /data/ollama/models

# Write the removal script to a custom location
ollama-cleanup --output ~/cleanup-2026-02-27.sh
```

The installed command accepts the same options as `ollama-cleanup.sh`.

## How it works

Ollama stores models in a content-addressable layout:

```text
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

Each manifest JSON file contains a `config.digest` and a `layers[].digest` array. These digests map to filenames in the `blobs` directory, with `:` replaced by `-`.

The utility parses every active model manifest to build a whitelist of referenced blobs, then flags everything outside that set as orphaned:

- **Orphaned blobs** — referenced by an orphaned manifest but not by an active model.
- **Fully orphaned blobs** — not referenced by any manifest (active or orphaned). These may be remnants of interrupted downloads or previous partial cleanup.

## Safety

- Nothing is deleted directly.
- The utility generates a separate removal script for review.
- The generated script prompts for confirmation before removal.
- Fully orphaned blobs require a separate additional confirmation.
- If `ollama list` returns no models, the utility aborts rather than marking everything for removal.
- Each removal is wrapped in a safe helper that handles missing files gracefully.

## License

MIT
