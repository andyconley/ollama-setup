# `setup-local-llm.sh` — Local LLM Dev Environment Setup

Single script that installs and configures a local AI coding stack: Ollama + Gemma 4 + OpenCode / Goose. macOS (Apple Silicon) and Linux (x86_64). ~2,000 lines of bash, no external dependencies beyond `curl` and `python3`.

## Quick Start

```bash
chmod +x setup-local-llm.sh
./setup-local-llm.sh --install
```

## Usage

```bash
./setup-local-llm.sh --install                     # interactive
./setup-local-llm.sh --install gemma4:e4b -c 32k   # specific model + context
./setup-local-llm.sh --install --frontend goose     # install Goose only
./setup-local-llm.sh --install --frontend both      # install OpenCode + Goose
./setup-local-llm.sh --install --fresh              # wipe and start over
./setup-local-llm.sh --status                       # health check
```

## Install Flow (`--install`)

- Installs Ollama via Homebrew (macOS) or the official install script (Linux)
- Checks installed Ollama version against the latest stable GitHub release; prompts to upgrade if behind. Detects install method (Homebrew vs. macOS app vs. Linux script) and updates accordingly
- Starts the Ollama server if not already running (macOS: background process, Linux: systemd or background)
- Presents a model picker with four curated Gemma 4 variants (e2b through 31b), with RAM-based recommendations. Also supports browsing the full Ollama library with paginated tag selection, or typing any model name directly
- Pulls the selected model
- Creates a `-dev` model variant via `ollama create` with an extended context window. Context size is auto-detected from system RAM (8K/16K/32K/64K tiers) or set manually with `--context`
- Presents a frontend picker: **OpenCode** (terminal TUI), **Goose** (agent with MCP extensions), or **both**. Use `--frontend` to skip the picker.
- Installs the selected tool(s), handles PATH setup across zsh/bash/profile
- Writes config for each tool pointing at the local Ollama instance with the dev variant as the active model

## Frontend Tools

| Tool | Best For | Key Features |
|------|----------|-------------|
| **OpenCode** | Terminal-native coding | Beautiful TUI, vim keybindings, LSP integration, session management |
| **Goose** | Extensible AI agent | MCP extensions (70+), desktop app, subagents, prompt injection detection |

Both tools connect to the same local Ollama server and models. You can install one or both.

### Goose Desktop App (Optional)

Goose also has a desktop app with a native chat interface and full MCP extension support. The script offers to install it after the Goose CLI. It shares the same config — no extra setup needed.

| Platform | How the script installs it |
|----------|---------------------------|
| **macOS** | `brew install --cask block-goose` |
| **Linux** | Downloads `.deb`/`.rpm` from GitHub releases, installs via `dpkg`/`rpm` (requires sudo) |

Ollama runs as a CLI server on Linux (no desktop GUI). On macOS, the [Ollama app](https://ollama.com/download) adds a menu bar icon that runs the server in the background.

## Re-run Behavior

- Detects existing Ollama, OpenCode, Goose, and config state on every run
- Returning users get a menu: add a model, change context window on an existing model, switch the active model, install another coding tool, or full reinstall
- Passing a model name as a positional arg on re-run skips the menu and goes straight to add-model
- `--fresh` wipes config and runs from scratch

## Health Check (`--status`)

- Reports OS, RAM, Ollama version (with update-available check), server status, downloaded models, dev variants
- Shows install status and version for OpenCode and Goose (with update-available check for each)
- Validates config files and active model references for each installed tool
- Runs an actual inference test against the active model
- Flags issues with fix hints
