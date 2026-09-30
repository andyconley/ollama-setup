#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Local LLM Dev Setup: Ollama + Gemma 4 + OpenCode / Goose
# Works on macOS (Apple Silicon) and Linux (x86_64)
#
# Re-run safe: detects existing installation and offers to
# add models, change context, or do a fresh install.
#
# Usage:
#   ./setup-local-llm.sh                              # show help
#   ./setup-local-llm.sh --install                    # interactive install / manage
#   ./setup-local-llm.sh --install gemma4:e4b         # install specific model
#   ./setup-local-llm.sh --install --context 64k      # custom context
#   ./setup-local-llm.sh --install --frontend goose   # install with specific frontend
#   ./setup-local-llm.sh --status                     # health check
#
# SECTIONS (search for "§" to jump):
#   §HELPERS       Output formatting, JSON parsing, version compare, RAM detect
#   §CLI           Argument parsing + help text
#   §DETECT        Detect existing install, show returning-user menu
#   §OLLAMA        Install, version check, update, start server
#   §MODELS        Registry check, model menu, library browser, tag browser
#   §FRONTEND      Frontend picker (OpenCode, Goose, or both)
#   §OPENCODE      Install, PATH setup, config write, config update
#   §GOOSE         Install, PATH setup, config write, config update, version check
#   §ACTIONS       Change context, switch model, fresh install, add model
#   §STATUS        Health check (--status)
#   §MAIN          Entry point + dispatch
# ============================================================

OPENCODE_IN_PATH_AT_START=false  # snapshot to detect if we added opencode during run
if command -v opencode &>/dev/null; then
  OPENCODE_IN_PATH_AT_START=true
fi
GOOSE_IN_PATH_AT_START=false  # snapshot to detect if we added goose during run
if command -v goose &>/dev/null; then
  GOOSE_IN_PATH_AT_START=true
fi
NUM_CTX=""  # set via --context flag, auto-detected from RAM if not provided
MODEL=""
MODEL_ALIAS=""
INSTALL_OPENCODE=true   # default: install both frontends
INSTALL_GOOSE=true      # overridden by --frontend flag or interactive picker
FRONTEND_SET=false      # true if --frontend flag was used (skip picker)

# §HELPERS =====================================================

# -- Output formatting --
info()  { printf "\033[1;34m=> %s\033[0m\n" "$1"; }
ok()    { printf "\033[1;32m=> %s\033[0m\n" "$1"; }
warn()  { printf "\033[1;33m=> %s\033[0m\n" "$1"; }
fail()  { printf "\033[1;31m=> %s\033[0m\n" "$1"; exit 1; }
dim()   { printf "\033[0;90m   %s\033[0m\n" "$1"; }
bold()  { printf "\033[1m%s\033[0m" "$1"; }

# -- Human-readable context size --
format_ctx() {
  local val="$1"
  if [ "$val" -ge 1024 ]; then
    echo "$((val / 1024))K"
  else
    echo "$val"
  fi
}

# -- Detect system RAM in GB --
get_system_ram_gb() {
  case "$(uname -s)" in
    Darwin)
      sysctl -n hw.memsize 2>/dev/null | awk '{printf "%d", $1 / 1073741824}'
      ;;
    Linux)
      awk '/MemTotal/ {printf "%d", $2 / 1048576}' /proc/meminfo 2>/dev/null
      ;;
    *)
      echo "0"
      ;;
  esac
}

# -- Strip JSONC comments: // line and /* block */, preserving strings --
strip_jsonc() {
  python3 -c "
import sys, re
text = sys.stdin.read()
# Match quoted strings (keep), block comments (remove), line comments (remove)
pattern = r'\"(?:[^\"\\\\]|\\\\.)*\"|/\*[\s\S]*?\*/|//.*'
print(re.sub(pattern, lambda m: m.group() if m.group().startswith('\"') else '', text))
" 2>/dev/null || true
}

# -- Read a key from the OpenCode JSONC config --
#    Usage: read_config_key "model"  -> prints value
read_config_key() {
  local key="$1"
  local config_dir="\${XDG_CONFIG_HOME:-\$HOME/.config}/opencode"
  local config_file
  config_file="$(eval echo "$config_dir/opencode.jsonc")"
  [ -f "$config_file" ] || return 0
  cat "$config_file" | strip_jsonc | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    val = data
    for k in '${key}'.split('.'):
        val = val[k] if isinstance(val, dict) else val[int(k)]
    print(val)
except:
    pass
" 2>/dev/null || true
}

# -- Read context window from active model in OpenCode config --
read_config_context() {
  local config_dir="\${XDG_CONFIG_HOME:-\$HOME/.config}/opencode"
  local config_file
  config_file="$(eval echo "$config_dir/opencode.jsonc")"
  [ -f "$config_file" ] || return 0
  cat "$config_file" | strip_jsonc | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    # New schema: provider.*.models.*.limit.context
    for prov in data.get('provider', {}).values():
        if not isinstance(prov, dict): continue
        for m in prov.get('models', {}).values():
            ctx = m.get('limit', {}).get('context', '') if isinstance(m, dict) else ''
            if ctx:
                print(ctx)
                sys.exit(0)
    # Legacy schema fallback: providers.*.models.*.contextWindow
    for prov in data.get('providers', {}).values():
        if not isinstance(prov, dict): continue
        for m in prov.get('models', {}).values():
            ctx = m.get('contextWindow', '') if isinstance(m, dict) else ''
            if ctx:
                print(ctx)
                sys.exit(0)
except:
    pass
" 2>/dev/null || true
}

# -- Compare two semver strings. Prints "newer" if $2 > $1 --
version_is_newer() {
  local current="$1"
  local candidate="$2"
  if [ "$current" = "$candidate" ]; then
    echo "same"
    return
  fi
  local lower
  lower=$(printf '%s\n%s' "$current" "$candidate" | sort -V | head -1)
  if [ "$lower" = "$current" ]; then
    echo "newer"
  else
    echo "same"
  fi
}

# -- Fetch latest stable Ollama version from GitHub --
fetch_latest_ollama_version() {
  curl -sf --max-time 5 "https://api.github.com/repos/ollama/ollama/releases" < /dev/null 2>/dev/null \
    | python3 -c "
import sys, json
try:
    for r in json.load(sys.stdin):
        if r.get('prerelease', False):
            continue
        tag = r.get('tag_name', '')
        if 'rc' in tag.lower() or 'beta' in tag.lower() or 'alpha' in tag.lower():
            continue
        ver = tag.lstrip('v')
        if ver:
            print(ver)
            break
except:
    pass
" 2>/dev/null || true
}

# -- Print "getting started" instructions, with PATH hint if needed --
print_getting_started() {
  # If tools weren't in PATH when the script started, user needs to reload
  local need_reload=false
  if $INSTALL_OPENCODE && ! $OPENCODE_IN_PATH_AT_START; then
    need_reload=true
  fi
  if $INSTALL_GOOSE && ! $GOOSE_IN_PATH_AT_START; then
    need_reload=true
  fi

  local shell_rc=""
  case "$(basename "$SHELL")" in
    zsh)  shell_rc="~/.zshrc" ;;
    bash) shell_rc="~/.bashrc" ;;
    *)    shell_rc="your shell profile" ;;
  esac

  echo "  To get started (CLI):"
  if $need_reload; then
    echo "    source $shell_rc    # or open a new terminal"
  fi
  echo "    cd your-project"
  $INSTALL_OPENCODE && echo "    opencode          # terminal TUI"
  $INSTALL_GOOSE && echo "    goose             # agent with MCP extensions"
  echo ""
  $INSTALL_OPENCODE && echo "  Inside OpenCode, run /models to verify the active model."
  echo ""
  if $INSTALL_GOOSE; then
    dim "Goose desktop app: re-run this script to install, or grab it from"
    dim "  https://github.com/block/goose/releases"
    echo ""
  fi
}

# §CLI ===========================================================

# ----------------------------------------------------------
# Help
# ----------------------------------------------------------
show_help() {
  echo ""
  echo "  Local LLM Dev Environment: Ollama + Gemma 4 + OpenCode / Goose"
  echo ""
  echo "  Usage: $0 <command> [options]"
  echo ""
  echo "  Commands:"
  echo "    --install, -i         Install or manage the local LLM environment (interactive)"
  echo "    --status, -s          Health check — verify everything is installed and working"
  echo "    --help, -h            Show this help"
  echo ""
  echo "  Install options:"
  echo "    MODEL                 Ollama model name (e.g. gemma4:e4b). Interactive picker if omitted."
  echo "    --context, -c SIZE    Context window size: tokens (32768) or shorthand (16k, 32k, 64k)."
  echo "                          Auto-detected from system RAM if omitted."
  echo "    --frontend TOOL       Which AI coding tool(s) to install: opencode, goose, or both."
  echo "                          Interactive picker if omitted."
  echo "    --fresh               Ignore existing install, do a full fresh setup."
  echo ""
  echo "  Examples:"
  echo "    $0 --install                        # interactive install / manage"
  echo "    $0 --install gemma4:26b             # install specific model"
  echo "    $0 --install --context 64k          # install with custom context"
  echo "    $0 --install --frontend goose       # install Goose only"
  echo "    $0 --install gemma4:e4b -c 16k      # model + context"
  echo "    $0 --install --fresh                # wipe config, start over"
  echo "    $0 --status                         # check install health"
  echo ""
  echo "  Browse available models:"
  echo "    Gemma 4:   https://ollama.com/library/gemma4/tags"
  echo "    All models: https://ollama.com/library"
  echo ""
  echo "  Any model from the Ollama library works — choose 'Other' in the"
  echo "  model picker or pass the name directly (e.g. qwen3:8b, llama4:8b)."
  echo ""
}

# ----------------------------------------------------------
# Parse CLI arguments
# ----------------------------------------------------------
POSITIONAL_MODEL=""
FORCE_FRESH=false
RUN_STATUS=false
RUN_INSTALL=false

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --context|-c)
        shift
        [ $# -eq 0 ] && fail "--context requires a value (e.g. 32768, 16k, 64k)"
        NUM_CTX="$1"
        ;;
      --context=*|-c=*)
        NUM_CTX="${1#*=}"
        ;;
      --install|-i)
        RUN_INSTALL=true
        ;;
      --frontend)
        shift
        [ $# -eq 0 ] && fail "--frontend requires a value (opencode, goose, or both)"
        case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
          opencode)  INSTALL_OPENCODE=true;  INSTALL_GOOSE=false ;;
          goose)     INSTALL_OPENCODE=false; INSTALL_GOOSE=true ;;
          both)      INSTALL_OPENCODE=true;  INSTALL_GOOSE=true ;;
          *) fail "Invalid --frontend value: $1 (expected opencode, goose, or both)" ;;
        esac
        FRONTEND_SET=true
        ;;
      --frontend=*)
        case "$(echo "${1#*=}" | tr '[:upper:]' '[:lower:]')" in
          opencode)  INSTALL_OPENCODE=true;  INSTALL_GOOSE=false ;;
          goose)     INSTALL_OPENCODE=false; INSTALL_GOOSE=true ;;
          both)      INSTALL_OPENCODE=true;  INSTALL_GOOSE=true ;;
          *) fail "Invalid --frontend value: ${1#*=} (expected opencode, goose, or both)" ;;
        esac
        FRONTEND_SET=true
        ;;
      --fresh)
        FORCE_FRESH=true
        RUN_INSTALL=true
        ;;
      --status|-s)
        RUN_STATUS=true
        ;;
      --help|-h)
        show_help
        exit 0
        ;;
      -*)
        fail "Unknown flag: $1 (try --help)"
        ;;
      *)
        POSITIONAL_MODEL="$1"
        ;;
    esac
    shift
  done

  # Normalize shorthand context values: 16k -> 16384, 32k -> 32768, etc.
  if [ -n "$NUM_CTX" ]; then
    NUM_CTX=$(echo "$NUM_CTX" | tr '[:upper:]' '[:lower:]')
    case "$NUM_CTX" in
      *k)
        NUM_CTX=$(( ${NUM_CTX%k} * 1024 ))
        ;;
      *m)
        NUM_CTX=$(( ${NUM_CTX%m} * 1048576 ))
        ;;
    esac
    if ! [[ "$NUM_CTX" =~ ^[0-9]+$ ]]; then
      fail "Invalid context window value: $NUM_CTX (expected a number or shorthand like 32k)"
    fi
  fi
}

# ----------------------------------------------------------
# Auto-detect context window from system RAM
# ----------------------------------------------------------
auto_detect_context() {
  local ram_gb
  ram_gb=$(get_system_ram_gb)

  # Calculate recommended default based on RAM
  local recommended
  if [ "$ram_gb" -ge 64 ]; then
    recommended=65536
  elif [ "$ram_gb" -ge 32 ]; then
    recommended=32768
  elif [ "$ram_gb" -ge 16 ]; then
    recommended=16384
  else
    recommended=8192
  fi

  # If already set via --context flag, just confirm it
  if [ -n "$NUM_CTX" ]; then
    ok "Context window: $(format_ctx "$NUM_CTX") (set via --context)"
    return
  fi

  echo ""
  echo "  Context window size"
  echo "  -------------------"
  dim "Larger context = more code visible to the model, but uses more RAM."
  dim "Recommended for your ${ram_gb}GB RAM: $(format_ctx $recommended)"
  echo ""
  echo "  1) 8K     — minimal, for low-RAM machines"
  echo "  2) 16K    — good for most tasks"
  echo "  3) 32K    — recommended for agentic coding"
  echo "  4) 64K    — large projects, needs 32GB+ RAM"
  echo "  5) Custom — enter a specific value"
  echo ""

  # Pre-select the recommended option
  local default_choice
  case $recommended in
    8192)  default_choice=1 ;;
    16384) default_choice=2 ;;
    32768) default_choice=3 ;;
    65536) default_choice=4 ;;
    *)     default_choice=3 ;;
  esac

  local pick
  while true; do
    printf "  Choose [1-5] (default: %d): " "$default_choice"
    read -r pick < /dev/tty
    pick="${pick:-$default_choice}"

    case "$pick" in
      1) NUM_CTX=8192; break ;;
      2) NUM_CTX=16384; break ;;
      3) NUM_CTX=32768; break ;;
      4) NUM_CTX=65536; break ;;
      5)
        printf "  Enter token count (e.g. 16k, 32k, 49152): "
        read -r NUM_CTX < /dev/tty
        NUM_CTX=$(echo "$NUM_CTX" | tr '[:upper:]' '[:lower:]')
        case "$NUM_CTX" in
          *k) NUM_CTX=$(( ${NUM_CTX%k} * 1024 )) ;;
          *m) NUM_CTX=$(( ${NUM_CTX%m} * 1048576 )) ;;
        esac
        if [[ "$NUM_CTX" =~ ^[0-9]+$ ]]; then
          break
        else
          warn "Invalid value, try again."
          NUM_CTX=""
        fi
        ;;
      *) warn "Invalid choice, try again." ;;
    esac
  done

  ok "Context window: $(format_ctx "$NUM_CTX")"
}

# §DETECT ========================================================

# ----------------------------------------------------------
# Detect existing installation
# ----------------------------------------------------------
detect_existing() {
  HAVE_OLLAMA=false
  HAVE_OPENCODE=false
  HAVE_GOOSE=false
  HAVE_CONFIG=false
  HAVE_GOOSE_CONFIG=false
  INSTALLED_MODELS=()
  INSTALLED_DEV_MODELS=()
  CURRENT_CONFIG_MODEL=""
  CURRENT_CONFIG_CTX=""
  GOOSE_CONFIG_MODEL=""

  if command -v ollama &>/dev/null; then
    HAVE_OLLAMA=true
  fi

  if command -v opencode &>/dev/null \
     || [ -x "$HOME/.opencode/bin/opencode" ] \
     || [ -x "$HOME/.local/bin/opencode" ]; then
    HAVE_OPENCODE=true
  fi

  if command -v goose &>/dev/null \
     || [ -x "$HOME/.goose/bin/goose" ] \
     || [ -x "$HOME/.local/bin/goose" ]; then
    HAVE_GOOSE=true
  fi

  local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
  local config_file="$config_dir/opencode.jsonc"

  if [ -f "$config_file" ]; then
    HAVE_CONFIG=true
    CURRENT_CONFIG_MODEL=$(read_config_key "model")
    CURRENT_CONFIG_CTX=$(read_config_context)
  fi

  local goose_config="$HOME/.config/goose/config.yaml"
  if [ -f "$goose_config" ]; then
    HAVE_GOOSE_CONFIG=true
    GOOSE_CONFIG_MODEL=$(grep '^GOOSE_MODEL:' "$goose_config" 2>/dev/null | awk '{print $2}' || true)
  fi

  # Get installed Ollama models (if server is reachable)
  if $HAVE_OLLAMA && curl -sf http://localhost:11434/api/version < /dev/null &>/dev/null; then
    while IFS= read -r line; do
      local name
      name=$(echo "$line" | awk '{print $1}')
      [ -n "$name" ] && INSTALLED_MODELS+=("$name")
      if [[ "$name" == *-dev* ]]; then
        INSTALLED_DEV_MODELS+=("$name")
      fi
    done < <(ollama list 2>/dev/null | tail -n +2)
  fi
}

# ----------------------------------------------------------
# Show existing installation status and ask what to do
# Returns: action to take (fresh_install, add_model,
#          change_context, reconfigure, nothing)
# ----------------------------------------------------------
ACTION=""

prompt_existing_user() {
  echo ""
  echo "  Existing installation detected:"
  echo ""

  if $HAVE_OLLAMA; then
    ok "Ollama: installed ($(ollama --version 2>/dev/null || echo 'unknown'))"
  fi

  if $HAVE_OPENCODE; then
    ok "OpenCode: installed ($(opencode --version 2>/dev/null || echo 'unknown'))"
  fi

  if $HAVE_GOOSE; then
    ok "Goose: installed ($(goose --version 2>/dev/null || echo 'unknown'))"
  fi

  if [ ${#INSTALLED_DEV_MODELS[@]} -gt 0 ]; then
    echo ""
    echo "  Configured dev models (with extended context):"
    for m in "${INSTALLED_DEV_MODELS[@]}"; do
      echo "    - $m"
    done
  fi

  if [ ${#INSTALLED_MODELS[@]} -gt 0 ] && [ ${#INSTALLED_DEV_MODELS[@]} -eq 0 ]; then
    echo ""
    echo "  Downloaded models (no dev variants yet):"
    for m in "${INSTALLED_MODELS[@]}"; do
      echo "    - $m"
    done
  fi

  if $HAVE_CONFIG && [ -n "$CURRENT_CONFIG_MODEL" ]; then
    echo ""
    echo "  OpenCode active model: $CURRENT_CONFIG_MODEL"
    [ -n "$CURRENT_CONFIG_CTX" ] && echo "  Context window: $(format_ctx "$CURRENT_CONFIG_CTX") tokens"
  fi

  if $HAVE_GOOSE_CONFIG && [ -n "$GOOSE_CONFIG_MODEL" ]; then
    echo "  Goose active model: $GOOSE_CONFIG_MODEL"
  fi

  # Determine if we can offer to install another tool
  local can_add_tool=false
  local missing_tool=""
  if $HAVE_OPENCODE && ! $HAVE_GOOSE; then
    can_add_tool=true
    missing_tool="Goose"
  elif $HAVE_GOOSE && ! $HAVE_OPENCODE; then
    can_add_tool=true
    missing_tool="OpenCode"
  elif ! $HAVE_OPENCODE && ! $HAVE_GOOSE; then
    can_add_tool=true
    missing_tool="OpenCode and/or Goose"
  fi

  echo ""
  echo "  What would you like to do?"
  echo ""
  echo "  1) Add a new model          Pull + configure an additional model"
  echo "  2) Change context window     Update context size for an existing model"
  echo "  3) Switch active model       Change which model the tools use by default"
  echo "  4) Full reinstall            Wipe config and start fresh"
  if $can_add_tool; then
    echo "  5) Install another tool      Add $missing_tool"
    echo "  6) Nothing, exit"
  else
    echo "  5) Nothing, exit"
  fi
  echo ""

  local max_choice=5
  $can_add_tool && max_choice=6

  local choice
  while true; do
    printf "  Choose [1-%d]: " "$max_choice"
    read -r choice < /dev/tty
    case "$choice" in
      1) ACTION="add_model"; return ;;
      2) ACTION="change_context"; return ;;
      3) ACTION="switch_model"; return ;;
      4) ACTION="fresh_install"; return ;;
      5)
        if $can_add_tool; then
          ACTION="add_tool"; return
        else
          ACTION="nothing"; return
        fi
        ;;
      6)
        if $can_add_tool; then
          ACTION="nothing"; return
        fi
        warn "Invalid choice, try again."
        ;;
      *) warn "Invalid choice, try again." ;;
    esac
  done
}

# §OLLAMA ========================================================

# ----------------------------------------------------------
# Install Ollama
# ----------------------------------------------------------
install_ollama() {
  if command -v ollama &>/dev/null; then
    ok "Ollama already installed: $(ollama --version)"
    check_ollama_version
    return
  fi

  info "Installing Ollama..."
  case "$(uname -s)" in
    Darwin)
      if command -v brew &>/dev/null; then
        brew install ollama
      else
        fail "Homebrew not found. Install it first: https://brew.sh"
      fi
      ;;
    Linux)
      curl -fsSL https://ollama.com/install.sh | sh
      ;;
    *)
      fail "Unsupported OS: $(uname -s)"
      ;;
  esac
  ok "Ollama installed"
}

# ----------------------------------------------------------
# Check Ollama version against latest release
# ----------------------------------------------------------
check_ollama_version() {
  local local_version
  local_version=$(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)

  if [ -z "$local_version" ]; then
    warn "Could not determine local Ollama version"
    return
  fi

  info "Checking for Ollama updates..."
  local latest_version
  latest_version=$(fetch_latest_ollama_version)

  if [ -z "$latest_version" ]; then
    dim "Could not check latest version (offline?)"
    return
  fi

  if [ "$(version_is_newer "$local_version" "$latest_version")" != "newer" ]; then
    ok "Ollama is up to date (v${local_version})"
    return
  fi

  warn "Ollama update available: v${local_version} -> v${latest_version}"
  echo ""
  echo "  Some newer models (like gemma4:26b) may require the latest version."
  echo ""

  printf "  Update now? [Y/n]: "
  read -r answer < /dev/tty
  answer="${answer:-Y}"
  answer=$(echo "$answer" | tr '[:upper:]' '[:lower:]')

  case "$answer" in
    y|yes)
      update_ollama
      ;;
    *)
      warn "Skipping update — some models may fail to pull"
      ;;
  esac
}

# ----------------------------------------------------------
# Update Ollama (detects install method)
# ----------------------------------------------------------
update_ollama() {
  local local_version
  local_version=$(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)

  info "Updating Ollama..."

  case "$(uname -s)" in
    Darwin)
      # Check if installed via Homebrew
      if brew list ollama &>/dev/null 2>&1; then
        brew upgrade ollama
      elif [ -d "/Applications/Ollama.app" ]; then
        # Installed as macOS app — download and replace
        info "Ollama was installed as a macOS app. Downloading latest..."
        local tmpdir
        tmpdir=$(mktemp -d)
        local zip_path="$tmpdir/Ollama.zip"

        curl -fSL --progress-bar -o "$zip_path" "https://ollama.com/download/Ollama-darwin.zip"
        info "Extracting..."
        unzip -qo "$zip_path" -d "$tmpdir"

        if [ -d "$tmpdir/Ollama.app" ]; then
          # Quit the running app and wait for server to fully stop
          info "Stopping Ollama..."
          osascript -e 'quit app "Ollama"' 2>/dev/null || true
          # Also kill any lingering ollama processes
          pkill -f "Ollama" 2>/dev/null || true
          # Wait for the server to actually go away
          for i in $(seq 1 15); do
            if ! curl -sf http://localhost:11434/api/version < /dev/null &>/dev/null; then
              break
            fi
            sleep 1
          done
          sleep 1  # extra beat for file handles to release

          info "Replacing /Applications/Ollama.app..."
          # Safe swap: move old aside first, restore on failure
          local backup="/Applications/Ollama.app.old"
          rm -rf "$backup"
          mv /Applications/Ollama.app "$backup"
          if mv "$tmpdir/Ollama.app" /Applications/Ollama.app; then
            rm -rf "$backup"
          else
            warn "Failed to install new Ollama.app — restoring previous version"
            mv "$backup" /Applications/Ollama.app
            rm -rf "$tmpdir"
            fail "Update failed. Check disk space and permissions."
          fi

          # Relaunch and wait for the NEW server to come up
          info "Restarting Ollama..."
          open /Applications/Ollama.app
          for i in $(seq 1 30); do
            if curl -sf http://localhost:11434/api/version < /dev/null &>/dev/null; then
              break
            fi
            sleep 1
          done

          # Verify the CLI binary matches the new version
          local new_ver
          new_ver=$(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
          if [ -n "$new_ver" ] && [ "$new_ver" != "$local_version" ]; then
            ok "CLI updated: v${new_ver}"
          else
            warn "CLI still reports v${new_ver:-unknown}. You may need to restart your terminal."
          fi
        else
          rm -rf "$tmpdir"
          fail "Download succeeded but Ollama.app not found in archive"
        fi
        rm -rf "$tmpdir"
      else
        fail "Could not determine how Ollama was installed. Update manually: https://ollama.com/download"
      fi
      ;;
    Linux)
      curl -fsSL https://ollama.com/install.sh | sh
      ;;
  esac

  ok "Ollama updated to $(ollama --version 2>/dev/null || echo 'latest')"
}

# ----------------------------------------------------------
# Start Ollama server
# ----------------------------------------------------------
start_ollama() {
  if curl -sf http://localhost:11434/api/version < /dev/null &>/dev/null; then
    ok "Ollama server already running"
    return
  fi

  info "Starting Ollama server..."
  case "$(uname -s)" in
    Darwin)
      ollama serve &>/dev/null &
      ;;
    Linux)
      if systemctl is-active --quiet ollama 2>/dev/null; then
        ok "Ollama systemd service is active"
        return
      fi
      sudo systemctl start ollama 2>/dev/null || ollama serve &>/dev/null &
      ;;
  esac

  for i in $(seq 1 30); do
    if curl -sf http://localhost:11434/api/version < /dev/null &>/dev/null; then
      ok "Ollama server ready"
      return
    fi
    sleep 1
  done
  fail "Ollama server did not start within 30 seconds"
}

# §MODELS ========================================================

# ----------------------------------------------------------
# Gemma 4 model registry + menu
# ----------------------------------------------------------
FALLBACK_MODELS=(
  "gemma4:e2b|7.2 GB|2.3B params|Lightweight — runs on any machine (8GB+ RAM)"
  "gemma4:e4b|9.6 GB|4.5B params|Balanced — good for most dev work (16GB+ RAM)"
  "gemma4:26b|18 GB|3.8B active (MoE, 128 experts)|Most capable per watt (32GB+ RAM)"
  "gemma4:31b|20 GB|30.7B dense|Flagship dense model (32GB+ RAM)"
)

verify_model_available() {
  # Quick check that a model tag actually exists in the Ollama registry
  # Uses the OCI manifest endpoint (the only reliable public API)
  local model_tag="$1"
  local tag="${model_tag#*:}"  # gemma4:e4b -> e4b
  curl -sf --max-time 3 "https://registry.ollama.ai/v2/library/gemma4/manifests/${tag}" < /dev/null &>/dev/null
}

build_model_menu() {
  MENU_MODELS=()
  MENU_DISPLAY=()

  local ram_gb
  ram_gb=$(get_system_ram_gb)

  # Verify curated list is still valid by spot-checking one model
  info "Checking model availability..."
  if verify_model_available "gemma4:e4b"; then
    ok "Ollama registry reachable"
  else
    dim "Could not reach registry — model list may be outdated"
  fi

  local i=1
  for entry in "${FALLBACK_MODELS[@]}"; do
    IFS='|' read -r tag size params desc <<< "$entry"
    MENU_MODELS+=("$tag")

    local rec=""
    if [ "$ram_gb" -ge 32 ] && [ "$tag" = "gemma4:26b" ]; then
      rec=" ★ recommended for your ${ram_gb}GB RAM"
    elif [ "$ram_gb" -ge 16 ] && [ "$ram_gb" -lt 32 ] && [ "$tag" = "gemma4:e4b" ]; then
      rec=" ★ recommended for your ${ram_gb}GB RAM"
    elif [ "$ram_gb" -gt 0 ] && [ "$ram_gb" -lt 16 ] && [ "$tag" = "gemma4:e2b" ]; then
      rec=" ★ recommended for your ${ram_gb}GB RAM"
    fi

    MENU_DISPLAY+=("$(printf "  %d) %-16s  %-10s  %-34s %s" "$i" "$tag" "$size" "$desc" "$rec")")
    ((i++))
  done

  MENU_MODELS+=("CUSTOM")
  MENU_DISPLAY+=("$(printf "  %d) %-16s  %s" "$i" "Other" "Enter any Ollama model name")")
}

# ----------------------------------------------------------
# Browse Ollama library or type a model name
# ----------------------------------------------------------
browse_or_type_model() {
  MODEL=""

  echo ""
  echo "  1) Browse the Ollama model library"
  echo "  2) Type a model name directly"
  echo ""

  local how
  while true; do
    printf "  Choose [1-2]: "
    read -r how < /dev/tty
    case "$how" in
      1) browse_ollama_library; return ;;
      2)
        printf "  Enter model name (e.g. qwen3:8b, llama4:scout): "
        read -r MODEL < /dev/tty
        return
        ;;
      *) warn "Invalid choice, try again." ;;
    esac
  done
}

browse_ollama_library() {
  info "Fetching model families from ollama.com/library..."

  local families
  families=$(curl -sf --max-time 10 "https://ollama.com/library" < /dev/null 2>/dev/null | python3 -c "
import sys, re
html = sys.stdin.read()
seen = set()
for name in re.findall(r'href=\"/library/([a-z0-9._-]+)\"', html):
    if name not in seen:
        seen.add(name)
        print(name)
" 2>/dev/null || true)

  if [ -z "$families" ]; then
    warn "Could not fetch model list. Enter a name manually."
    printf "  Model name: "
    read -r MODEL < /dev/tty
    return
  fi

  # Convert to array
  local family_list=()
  while IFS= read -r f; do
    family_list+=("$f")
  done <<< "$families"

  local total=${#family_list[@]}
  local page=0
  local page_size=15

  while true; do
    local start=$((page * page_size))
    local end=$((start + page_size))
    if [ "$end" -gt "$total" ]; then end=$total; fi

    echo ""
    echo "  Model families ($(( start + 1 ))-${end} of ${total}):"
    echo ""
    local i=$((start + 1))
    for idx in $(seq $start $((end - 1))); do
      printf "  %3d) %s\n" "$i" "${family_list[$idx]}"
      ((i++))
    done
    echo ""

    local nav_hint=""
    if [ "$end" -lt "$total" ]; then
      nav_hint="n=next page, "
    fi
    if [ "$page" -gt 0 ]; then
      nav_hint="${nav_hint}p=prev, "
    fi
    printf "  Pick a number, ${nav_hint}or q to type manually: "
    read -r pick < /dev/tty

    case "$pick" in
      n|N)
        if [ "$end" -lt "$total" ]; then
          ((page++))
        else
          warn "Already on last page"
        fi
        continue
        ;;
      p|P)
        if [ "$page" -gt 0 ]; then
          ((page--))
        else
          warn "Already on first page"
        fi
        continue
        ;;
      q|Q)
        printf "  Model name: "
        read -r MODEL < /dev/tty
        return
        ;;
    esac

    if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "$total" ]; then
      local family="${family_list[$((pick - 1))]}"
      browse_model_tags "$family"
      return
    else
      warn "Invalid choice, try again."
    fi
  done
}

browse_model_tags() {
  local family="$1"

  info "Fetching tags for ${family}..."

  local tags
  tags=$(curl -sf --max-time 10 "https://ollama.com/library/${family}/tags" < /dev/null 2>/dev/null | python3 -c "
import sys, re
html = sys.stdin.read()
blocks = re.findall(
    r'href=\"/library/(${family}:[^\"]+)\".*?(\d+(?:\.\d+)?[GMKT]B).*?(\d+K)\s*context',
    html, re.DOTALL
)
seen = set()
for tag, size, ctx in blocks:
    if tag in seen:
        continue
    seen.add(tag)
    base = tag.split(':')[1]
    if any(q in base for q in ['q4_','q8_','q2_','q5_','q6_','fp16','fp8','latest']):
        continue
    print(f'{tag}|{size}|{ctx}')
" 2>/dev/null || true)

  if [ -z "$tags" ]; then
    warn "Could not fetch tags for ${family}. Enter the full model:tag manually."
    printf "  Model name (e.g. ${family}:8b): "
    read -r MODEL < /dev/tty
    return
  fi

  local tag_names=()
  local tag_display=()
  local i=1
  while IFS='|' read -r name size ctx; do
    tag_names+=("$name")
    tag_display+=("$(printf "  %2d) %-28s  %8s   %s" "$i" "$name" "$size" "$ctx")")
    ((i++))
  done <<< "$tags"

  echo ""
  echo "  Available ${family} tags:"
  echo ""
  printf "  %s  %-28s  %8s   %s\n" "  " "MODEL" "SIZE" "CONTEXT"
  printf "  %s  %-28s  %8s   %s\n" "  " "-----" "----" "-------"
  for line in "${tag_display[@]}"; do
    echo "$line"
  done
  echo ""

  local pick
  while true; do
    printf "  Pick a tag [1-%d]: " "${#tag_names[@]}"
    read -r pick < /dev/tty

    if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#tag_names[@]}" ]; then
      MODEL="${tag_names[$((pick - 1))]}"
      return
    else
      warn "Invalid choice, try again."
    fi
  done
}

# ----------------------------------------------------------
# Interactive model picker
# ----------------------------------------------------------
pick_model() {
  if [ -n "${1:-}" ]; then
    MODEL="$1"
    ok "Using model from argument: $MODEL"
    return
  fi

  build_model_menu

  local ram_gb
  ram_gb=$(get_system_ram_gb)

  echo ""
  echo "  Available Gemma 4 models:"
  if [ "$ram_gb" -gt 0 ]; then
    dim "Detected ${ram_gb}GB system RAM"
  fi
  echo ""
  for line in "${MENU_DISPLAY[@]}"; do
    echo "$line"
  done
  echo ""
  dim "Browse all models: https://ollama.com/library"
  echo ""

  local choice
  while true; do
    printf "  Pick a model [1-%d]: " "${#MENU_MODELS[@]}"
    read -r choice < /dev/tty

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#MENU_MODELS[@]}" ]; then
      local idx=$((choice - 1))
      if [ "${MENU_MODELS[$idx]}" = "CUSTOM" ]; then
        browse_or_type_model
        if [ -z "$MODEL" ]; then
          warn "No model selected, try again."
          continue
        fi
      else
        MODEL="${MENU_MODELS[$idx]}"
      fi
      break
    else
      warn "Invalid choice, try again."
    fi
  done

  ok "Selected: $MODEL"
}

# ----------------------------------------------------------
# Pull model
# ----------------------------------------------------------
pull_model() {
  # Check if model is already downloaded
  if ollama list 2>/dev/null | awk '{print $1}' | grep -qxF "${MODEL}"; then
    ok "Model $MODEL already downloaded"
    return
  fi

  info "Pulling $MODEL (this may take a while on first run)..."
  ollama pull "$MODEL"
  ok "Model $MODEL downloaded"
}

# ----------------------------------------------------------
# Create a variant with larger context window
# ----------------------------------------------------------
create_model_variant() {
  MODEL_ALIAS="${MODEL//[:\/]/-}-dev"

  info "Creating model variant '$MODEL_ALIAS' with ${NUM_CTX} context window..."

  local modelfile
  modelfile=$(mktemp)
  cat > "$modelfile" <<EOF
FROM $MODEL
PARAMETER num_ctx $NUM_CTX
EOF

  ollama create "$MODEL_ALIAS" -f "$modelfile"
  rm -f "$modelfile"
  ok "Model variant '$MODEL_ALIAS' ready ($(format_ctx "$NUM_CTX") context)"
}

# §OPENCODE ======================================================

# ----------------------------------------------------------
# Install OpenCode
# ----------------------------------------------------------
install_opencode() {
  # Check common install locations in case it's not in PATH
  local opencode_bin=""
  if command -v opencode &>/dev/null; then
    opencode_bin="opencode"
  elif [ -x "$HOME/.opencode/bin/opencode" ]; then
    opencode_bin="$HOME/.opencode/bin/opencode"
  elif [ -x "$HOME/.local/bin/opencode" ]; then
    opencode_bin="$HOME/.local/bin/opencode"
  fi

  if [ -n "$opencode_bin" ]; then
    ok "OpenCode already installed: $($opencode_bin --version 2>/dev/null || echo 'unknown version')"
    ensure_opencode_in_path
    return
  fi

  info "Installing OpenCode..."
  curl -fsSL https://opencode.ai/install | bash
  ensure_opencode_in_path
  ok "OpenCode installed"
}

ensure_opencode_in_path() {
  # If opencode is already in PATH, nothing to do
  if command -v opencode &>/dev/null; then
    return
  fi

  # Find the binary
  local bin_dir=""
  if [ -x "$HOME/.opencode/bin/opencode" ]; then
    bin_dir="$HOME/.opencode/bin"
  elif [ -x "$HOME/.local/bin/opencode" ]; then
    bin_dir="$HOME/.local/bin"
  else
    warn "Could not find opencode binary to add to PATH"
    return
  fi

  # Add to current session
  export PATH="$bin_dir:$PATH"

  # Add to shell profile for future sessions
  local shell_rc=""
  case "$(basename "$SHELL")" in
    zsh)  shell_rc="$HOME/.zshrc" ;;
    bash) shell_rc="$HOME/.bashrc" ;;
    *)    shell_rc="$HOME/.profile" ;;
  esac

  if [ -n "$shell_rc" ] && ! grep -q "$bin_dir" "$shell_rc" 2>/dev/null; then
    echo "" >> "$shell_rc"
    echo "# Added by setup-local-llm.sh" >> "$shell_rc"
    echo "export PATH=\"$bin_dir:\$PATH\"" >> "$shell_rc"
    ok "Added $bin_dir to PATH in $shell_rc"
    warn "Run 'source $shell_rc' or open a new terminal for this to take effect"
  fi
}

# ----------------------------------------------------------
# Write OpenCode config (fresh or update)
# ----------------------------------------------------------
write_opencode_config() {
  local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
  local config_file="$config_dir/opencode.jsonc"
  local auth_file="$config_dir/auth.json"

  mkdir -p "$config_dir"

  info "Writing OpenCode config..."

  local display_name="${MODEL} ($(format_ctx "$NUM_CTX") ctx)"

  cat > "$config_file" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "ollama/${MODEL_ALIAS}",
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama (local)",
      "options": {
        "baseURL": "http://localhost:11434/v1"
      },
      "models": {
        "${MODEL_ALIAS}": {
          "name": "${display_name}",
          "tool_call": true,
          "limit": {
            "context": ${NUM_CTX},
            "output": $((NUM_CTX / 2))
          }
        }
      }
    }
  }
}
EOF

  if [ ! -f "$auth_file" ]; then
    cat > "$auth_file" <<'EOF'
{
  "ollama": {
    "key": "ollama"
  }
}
EOF
  fi

  ok "OpenCode configured: $MODEL_ALIAS ($(format_ctx "$NUM_CTX") context)"
}

# ----------------------------------------------------------
# Add model to existing OpenCode config (preserves other models)
# ----------------------------------------------------------
add_model_to_config() {
  local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
  local config_file="$config_dir/opencode.jsonc"

  if [ ! -f "$config_file" ]; then
    write_opencode_config
    return
  fi

  info "Adding $MODEL_ALIAS to OpenCode config..."

  local display_name="${MODEL} ($(format_ctx "$NUM_CTX") ctx)"

  cat "$config_file" | strip_jsonc | python3 -c "
import sys, json
data = json.load(sys.stdin)
data.setdefault('provider', {})
if isinstance(data['provider'], str):
    data['provider'] = {}
data['provider'].setdefault('ollama', {
    'npm': '@ai-sdk/openai-compatible',
    'name': 'Ollama (local)',
    'options': {'baseURL': 'http://localhost:11434/v1'},
    'models': {}
})
data['provider']['ollama'].setdefault('models', {})
data['provider']['ollama']['models']['$MODEL_ALIAS'] = {
    'name': '$display_name',
    'tool_call': True,
    'limit': {'context': $NUM_CTX, 'output': $((NUM_CTX / 2))}
}
data['model'] = 'ollama/$MODEL_ALIAS'
with open('$config_file', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null

  ok "Added $MODEL_ALIAS to config and set as active model"
}

# §FRONTEND ======================================================

# ----------------------------------------------------------
# Frontend picker: OpenCode, Goose, or both
# ----------------------------------------------------------
pick_frontend() {
  # Skip if --frontend flag was used
  if $FRONTEND_SET; then
    local chosen=""
    $INSTALL_OPENCODE && chosen="OpenCode"
    $INSTALL_GOOSE && { [ -n "$chosen" ] && chosen="$chosen + Goose" || chosen="Goose"; }
    ok "Frontend: $chosen (set via --frontend)"
    return
  fi

  echo ""
  echo "  Which AI coding tool(s) would you like to install?"
  echo ""
  echo "  1) OpenCode       Terminal TUI — beautiful interface, vim keybindings"
  echo "  2) Goose          Agent with MCP extensions, desktop app, subagents"
  echo "  3) Both           Install OpenCode and Goose"
  echo ""

  local pick
  while true; do
    printf "  Choose [1-3] (default: 3): "
    read -r pick < /dev/tty
    pick="${pick:-3}"
    case "$pick" in
      1) INSTALL_OPENCODE=true;  INSTALL_GOOSE=false; break ;;
      2) INSTALL_OPENCODE=false; INSTALL_GOOSE=true;  break ;;
      3) INSTALL_OPENCODE=true;  INSTALL_GOOSE=true;  break ;;
      *) warn "Invalid choice, try again." ;;
    esac
  done

  local chosen=""
  $INSTALL_OPENCODE && chosen="OpenCode"
  $INSTALL_GOOSE && { [ -n "$chosen" ] && chosen="$chosen + Goose" || chosen="Goose"; }
  ok "Frontend: $chosen"
}

# §GOOSE =========================================================

# ----------------------------------------------------------
# Fetch latest stable Goose version from GitHub
# ----------------------------------------------------------
fetch_latest_goose_version() {
  curl -sf --max-time 5 "https://api.github.com/repos/block/goose/releases" < /dev/null 2>/dev/null \
    | python3 -c "
import sys, json
try:
    for r in json.load(sys.stdin):
        if r.get('prerelease', False):
            continue
        tag = r.get('tag_name', '')
        if 'rc' in tag.lower() or 'beta' in tag.lower() or 'alpha' in tag.lower():
            continue
        ver = tag.lstrip('v')
        if ver:
            print(ver)
            break
except:
    pass
" 2>/dev/null || true
}

# ----------------------------------------------------------
# Install Goose
# ----------------------------------------------------------
install_goose() {
  local goose_bin=""
  if command -v goose &>/dev/null; then
    goose_bin="goose"
  elif [ -x "$HOME/.goose/bin/goose" ]; then
    goose_bin="$HOME/.goose/bin/goose"
  elif [ -x "$HOME/.local/bin/goose" ]; then
    goose_bin="$HOME/.local/bin/goose"
  fi

  if [ -n "$goose_bin" ]; then
    local local_ver
    local_ver=$($goose_bin --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    ok "Goose already installed: v${local_ver:-unknown}"

    # Check for updates
    local latest_ver
    latest_ver=$(fetch_latest_goose_version)
    if [ -n "$latest_ver" ] && [ -n "$local_ver" ]; then
      if [ "$(version_is_newer "$local_ver" "$latest_ver")" = "newer" ]; then
        echo ""
        warn "Goose update available: v${local_ver} -> v${latest_ver}"
        printf "  Update now? [Y/n]: "
        local do_update
        read -r do_update < /dev/tty
        do_update="${do_update:-Y}"
        if [[ "$do_update" =~ ^[Yy] ]]; then
          info "Updating Goose..."
          if command -v brew &>/dev/null && brew list block-goose-cli &>/dev/null 2>&1; then
            brew upgrade block-goose-cli
          else
            goose update 2>/dev/null || {
              warn "goose update failed, re-running installer..."
              curl -fsSL https://github.com/block/goose/releases/download/stable/download_cli.sh | CONFIGURE=false bash
            }
          fi
          ok "Goose updated"
        fi
      fi
    fi

    ensure_goose_in_path
    return
  fi

  info "Installing Goose..."
  curl -fsSL https://github.com/block/goose/releases/download/stable/download_cli.sh | CONFIGURE=false bash
  ensure_goose_in_path
  ok "Goose installed"
}

ensure_goose_in_path() {
  if command -v goose &>/dev/null; then
    return
  fi

  local bin_dir=""
  if [ -x "$HOME/.goose/bin/goose" ]; then
    bin_dir="$HOME/.goose/bin"
  elif [ -x "$HOME/.local/bin/goose" ]; then
    bin_dir="$HOME/.local/bin"
  else
    warn "Could not find goose binary to add to PATH"
    return
  fi

  export PATH="$bin_dir:$PATH"

  local shell_rc=""
  case "$(basename "$SHELL")" in
    zsh)  shell_rc="$HOME/.zshrc" ;;
    bash) shell_rc="$HOME/.bashrc" ;;
    *)    shell_rc="$HOME/.profile" ;;
  esac

  if [ -n "$shell_rc" ] && ! grep -q "$bin_dir" "$shell_rc" 2>/dev/null; then
    echo "" >> "$shell_rc"
    echo "# Added by setup-local-llm.sh (Goose)" >> "$shell_rc"
    echo "export PATH=\"$bin_dir:\$PATH\"" >> "$shell_rc"
    ok "Added $bin_dir to PATH in $shell_rc"
    warn "Run 'source $shell_rc' or open a new terminal for this to take effect"
  fi
}

# ----------------------------------------------------------
# Offer to install Goose desktop app (Linux only, requires sudo)
# ----------------------------------------------------------
offer_goose_desktop() {
  local os
  os="$(uname -s)"

  # Only macOS and Linux supported
  [ "$os" = "Darwin" ] || [ "$os" = "Linux" ] || return

  # Skip if already installed
  local desktop_installed=false
  if [ "$os" = "Darwin" ]; then
    # Check Homebrew cask or /Applications
    if brew list --cask block-goose &>/dev/null 2>&1 || [ -d "/Applications/Goose.app" ]; then
      desktop_installed=true
    fi
  else
    # Linux: check dpkg or rpm
    if dpkg -l 2>/dev/null | grep -q goose || rpm -q goose &>/dev/null 2>&1; then
      desktop_installed=true
    fi
  fi

  if $desktop_installed; then
    ok "Goose desktop app: already installed"
    return
  fi

  echo ""
  echo "  Goose also has a desktop app with a native chat interface."
  if [ "$os" = "Linux" ]; then
    warn "Installing the desktop app requires sudo (system package install)."
  fi
  printf "  Install Goose desktop app? [y/N]: "
  local do_desktop
  read -r do_desktop < /dev/tty
  if ! [[ "$do_desktop" =~ ^[Yy] ]]; then
    dim "Skipped. You can always grab it later from https://github.com/block/goose/releases"
    return
  fi

  # macOS: use Homebrew cask
  if [ "$os" = "Darwin" ]; then
    if command -v brew &>/dev/null; then
      info "Installing Goose desktop via Homebrew..."
      brew install --cask block-goose
      ok "Goose desktop app installed"
    else
      warn "Homebrew not found — cannot auto-install desktop app."
      dim "Install Homebrew first (https://brew.sh) or download from:"
      dim "  https://github.com/block/goose/releases"
    fi
    return
  fi

  # Linux: download .deb or .rpm from GitHub releases
  info "Fetching latest Goose desktop release..."

  local pkg_type=""
  if command -v dpkg &>/dev/null; then
    pkg_type="deb"
  elif command -v rpm &>/dev/null; then
    pkg_type="rpm"
  else
    warn "Could not detect dpkg or rpm — skipping desktop install."
    dim "Download manually from https://github.com/block/goose/releases"
    return
  fi

  # Find the download URL for the right package
  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64)  arch="amd64" ;;
    aarch64) arch="arm64" ;;
  esac

  local download_url
  download_url=$(curl -sf --max-time 10 "https://api.github.com/repos/block/goose/releases" < /dev/null 2>/dev/null \
    | python3 -c "
import sys, json
try:
    for r in json.load(sys.stdin):
        if r.get('prerelease', False):
            continue
        for a in r.get('assets', []):
            name = a.get('name', '')
            if name.endswith('.${pkg_type}') and '${arch}' in name:
                print(a['browser_download_url'])
                sys.exit(0)
        break  # only check latest non-prerelease
except:
    pass
" 2>/dev/null || true)

  if [ -z "$download_url" ]; then
    warn "Could not find a .${pkg_type} package for ${arch} in the latest release."
    dim "Download manually from https://github.com/block/goose/releases"
    return
  fi

  local tmp_pkg
  tmp_pkg=$(mktemp /tmp/goose-desktop.XXXXXX.${pkg_type})

  info "Downloading $(basename "$download_url")..."
  if ! curl -fL --max-time 120 -o "$tmp_pkg" "$download_url" < /dev/null 2>/dev/null; then
    warn "Download failed."
    rm -f "$tmp_pkg"
    return
  fi

  info "Installing (will prompt for sudo password)..."
  case "$pkg_type" in
    deb)
      sudo dpkg -i "$tmp_pkg" 2>/dev/null || sudo apt-get install -f -y 2>/dev/null
      ;;
    rpm)
      sudo rpm -i "$tmp_pkg" 2>/dev/null || sudo dnf install -y "$tmp_pkg" 2>/dev/null
      ;;
  esac

  rm -f "$tmp_pkg"
  ok "Goose desktop app installed"
}

# ----------------------------------------------------------
# Write Goose config (fresh)
# ----------------------------------------------------------
write_goose_config() {
  local config_dir="$HOME/.config/goose"
  local config_file="$config_dir/config.yaml"

  mkdir -p "$config_dir"

  info "Writing Goose config..."

  cat > "$config_file" <<EOF
GOOSE_PROVIDER: ollama
GOOSE_MODEL: ${MODEL_ALIAS}
OLLAMA_HOST: http://localhost:11434
EOF

  ok "Goose configured: ${MODEL_ALIAS} via local Ollama"
}

# ----------------------------------------------------------
# Update Goose config model (preserves other settings)
# ----------------------------------------------------------
update_goose_model() {
  local config_dir="$HOME/.config/goose"
  local config_file="$config_dir/config.yaml"

  if [ ! -f "$config_file" ]; then
    write_goose_config
    return
  fi

  info "Updating Goose active model to ${MODEL_ALIAS}..."

  # Update the model line in-place, preserving other config
  if grep -q '^GOOSE_MODEL:' "$config_file" 2>/dev/null; then
    python3 -c "
import re, sys
with open('$config_file', 'r') as f:
    content = f.read()
content = re.sub(r'^GOOSE_MODEL:.*$', 'GOOSE_MODEL: $MODEL_ALIAS', content, flags=re.MULTILINE)
with open('$config_file', 'w') as f:
    f.write(content)
" 2>/dev/null
  else
    echo "GOOSE_MODEL: ${MODEL_ALIAS}" >> "$config_file"
  fi

  ok "Goose active model: ${MODEL_ALIAS}"
}

# §ACTIONS =======================================================

# ----------------------------------------------------------
# Action: Change context window on existing dev model
# ----------------------------------------------------------
do_change_context() {
  if [ ${#INSTALLED_DEV_MODELS[@]} -eq 0 ]; then
    warn "No dev model variants found. Running fresh install..."
    do_fresh_install
    return
  fi

  echo ""
  echo "  Which model's context window do you want to change?"
  echo ""
  local i=1
  for m in "${INSTALLED_DEV_MODELS[@]}"; do
    echo "  $i) $m"
    ((i++))
  done
  echo ""

  local choice
  while true; do
    printf "  Choose [1-%d]: " "${#INSTALLED_DEV_MODELS[@]}"
    read -r choice < /dev/tty
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#INSTALLED_DEV_MODELS[@]}" ]; then
      break
    fi
    warn "Invalid choice, try again."
  done

  local target="${INSTALLED_DEV_MODELS[$((choice - 1))]}"
  MODEL_ALIAS="$target"

  # Extract the base model from Ollama's modelfile (the FROM line)
  # This is the only reliable way — alias names are lossy
  MODEL=$(ollama show "$target" --modelfile 2>/dev/null | grep -m1 '^FROM ' | awk '{print $2}' || true)
  if [ -z "$MODEL" ]; then
    warn "Could not determine base model for $target"
    printf "  Enter the base model name (e.g. gemma4:26b, deepseek-r1:8b): "
    read -r MODEL < /dev/tty
    if [ -z "$MODEL" ]; then
      fail "No base model provided."
    fi
  fi
  ok "Base model: $MODEL"

  auto_detect_context

  if [ -z "$NUM_CTX" ]; then
    echo ""
    printf "  New context window size (e.g. 16k, 32k, 64k, or raw number): "
    read -r NUM_CTX < /dev/tty
    # Normalize
    NUM_CTX=$(echo "$NUM_CTX" | tr '[:upper:]' '[:lower:]')
    case "$NUM_CTX" in
      *k) NUM_CTX=$(( ${NUM_CTX%k} * 1024 )) ;;
      *m) NUM_CTX=$(( ${NUM_CTX%m} * 1048576 )) ;;
    esac
    if ! [[ "$NUM_CTX" =~ ^[0-9]+$ ]]; then
      fail "Invalid context value: $NUM_CTX"
    fi
  fi

  info "Recreating $MODEL_ALIAS with $(format_ctx "$NUM_CTX") context..."

  local modelfile
  modelfile=$(mktemp)
  cat > "$modelfile" <<EOF
FROM $MODEL
PARAMETER num_ctx $NUM_CTX
EOF

  ollama create "$MODEL_ALIAS" -f "$modelfile"
  rm -f "$modelfile"

  # Update frontend configs
  $HAVE_OPENCODE && add_model_to_config
  $HAVE_GOOSE && update_goose_model

  ok "Done! $MODEL_ALIAS now has $(format_ctx "$NUM_CTX") context window"
  echo ""
  echo "  Restart your coding tools to pick up the change."
  echo ""
}

# ----------------------------------------------------------
# Action: Switch active model (from already-installed ones)
# ----------------------------------------------------------
do_switch_model() {
  if [ ${#INSTALLED_DEV_MODELS[@]} -eq 0 ]; then
    warn "No dev model variants found. Use 'Add a new model' instead."
    return
  fi

  echo ""
  echo "  Which model should OpenCode use by default?"
  echo ""
  local i=1
  for m in "${INSTALLED_DEV_MODELS[@]}"; do
    local marker=""
    if [ "ollama/$m" = "$CURRENT_CONFIG_MODEL" ]; then
      marker=" (current)"
    fi
    echo "  $i) ${m}${marker}"
    ((i++))
  done
  echo ""

  local choice
  while true; do
    printf "  Choose [1-%d]: " "${#INSTALLED_DEV_MODELS[@]}"
    read -r choice < /dev/tty
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#INSTALLED_DEV_MODELS[@]}" ]; then
      break
    fi
    warn "Invalid choice, try again."
  done

  local target="${INSTALLED_DEV_MODELS[$((choice - 1))]}"

  local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
  local config_file="$config_dir/opencode.jsonc"

  # Update OpenCode config if it exists
  if $HAVE_OPENCODE && [ -f "$config_file" ]; then
    cat "$config_file" | strip_jsonc | python3 -c "
import sys, json
data = json.load(sys.stdin)
data['model'] = 'ollama/$target'
with open('$config_file', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null
    ok "OpenCode active model switched to: $target"
  fi

  # Update Goose config if installed
  if $HAVE_GOOSE; then
    MODEL_ALIAS="$target"
    update_goose_model
  fi

  echo ""
  echo "  Restart your coding tools to use the new model."
  echo ""
}

# ----------------------------------------------------------
# Fresh install flow
# ----------------------------------------------------------
do_fresh_install() {
  install_ollama
  start_ollama
  pick_frontend
  auto_detect_context
  pick_model "${POSITIONAL_MODEL:-}"
  pull_model
  create_model_variant

  if $INSTALL_OPENCODE; then
    install_opencode
    write_opencode_config
  fi

  if $INSTALL_GOOSE; then
    install_goose
    write_goose_config
    offer_goose_desktop
  fi

  echo ""
  ok "Setup complete!"
  echo ""
  echo "  Model:    $MODEL -> $MODEL_ALIAS ($(format_ctx "$NUM_CTX") ctx)"
  local tools=""
  $INSTALL_OPENCODE && tools="OpenCode"
  $INSTALL_GOOSE && { [ -n "$tools" ] && tools="$tools + Goose" || tools="Goose"; }
  echo "  Tools:    $tools"
  echo ""
  print_getting_started
}

# ----------------------------------------------------------
# Add model flow
# ----------------------------------------------------------
do_add_model() {
  start_ollama
  auto_detect_context
  pick_model "${POSITIONAL_MODEL:-}"
  pull_model
  create_model_variant

  $HAVE_OPENCODE && add_model_to_config
  $HAVE_GOOSE && update_goose_model

  echo ""
  ok "Model added!"
  echo ""
  echo "  Model:    $MODEL -> $MODEL_ALIAS ($(format_ctx "$NUM_CTX") ctx)"
  echo "  Set as active model in installed tools."
  echo ""
}

# ----------------------------------------------------------
# Add another coding tool (for returning users)
# ----------------------------------------------------------
do_add_tool() {
  start_ollama

  # Determine what model to use from existing config
  if [ -n "$CURRENT_CONFIG_MODEL" ]; then
    MODEL_ALIAS="${CURRENT_CONFIG_MODEL#ollama/}"
  elif [ -n "$GOOSE_CONFIG_MODEL" ]; then
    MODEL_ALIAS="$GOOSE_CONFIG_MODEL"
  elif [ ${#INSTALLED_DEV_MODELS[@]} -gt 0 ]; then
    MODEL_ALIAS="${INSTALLED_DEV_MODELS[0]}"
  else
    warn "No configured model found. Run 'Add a new model' first."
    return
  fi

  # Get context from existing config
  if [ -z "$NUM_CTX" ]; then
    NUM_CTX=$(read_config_context)
    [ -z "$NUM_CTX" ] && NUM_CTX=32768
  fi

  # Determine base model from the alias
  MODEL=$(ollama show "$MODEL_ALIAS" --modelfile 2>/dev/null | grep -m1 '^FROM ' | awk '{print $2}' || true)
  [ -z "$MODEL" ] && MODEL="$MODEL_ALIAS"

  # Reset install flags to reflect what we actually install here
  INSTALL_OPENCODE=$HAVE_OPENCODE
  INSTALL_GOOSE=$HAVE_GOOSE

  if ! $HAVE_OPENCODE; then
    echo ""
    printf "  Install OpenCode (terminal TUI)? [Y/n]: "
    local do_oc
    read -r do_oc < /dev/tty
    do_oc="${do_oc:-Y}"
    if [[ "$do_oc" =~ ^[Yy] ]]; then
      install_opencode
      write_opencode_config
      INSTALL_OPENCODE=true
      ok "OpenCode installed and configured with $MODEL_ALIAS"
    fi
  fi

  if ! $HAVE_GOOSE; then
    echo ""
    printf "  Install Goose (agent with MCP extensions)? [Y/n]: "
    local do_goose
    read -r do_goose < /dev/tty
    do_goose="${do_goose:-Y}"
    if [[ "$do_goose" =~ ^[Yy] ]]; then
      install_goose
      write_goose_config
      offer_goose_desktop
      INSTALL_GOOSE=true
      ok "Goose installed and configured with $MODEL_ALIAS"
    fi
  fi

  echo ""
  print_getting_started
}

# §STATUS ========================================================

# ----------------------------------------------------------
# Status / health check
# ----------------------------------------------------------
do_status() {
  local issues=0
  local ram_gb
  ram_gb=$(get_system_ram_gb)

  echo ""
  echo "  ┌──────────────────────────────────────┐"
  echo "  │  System Health Check                   │"
  echo "  └──────────────────────────────────────┘"
  echo ""

  # -- System info --
  echo "  System"
  echo "  ------"
  dim "OS:  $(uname -s) $(uname -m)"
  dim "RAM: ${ram_gb}GB"
  echo ""

  # -- Ollama binary --
  echo "  Ollama"
  echo "  ------"
  if command -v ollama &>/dev/null; then
    local local_ver
    local_ver=$(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    ok "Installed: v${local_ver:-unknown}"

    # Check for updates
    local latest_ver
    latest_ver=$(fetch_latest_ollama_version)

    if [ -n "$latest_ver" ] && [ -n "$local_ver" ]; then
      if [ "$(version_is_newer "$local_ver" "$latest_ver")" = "newer" ]; then
        warn "Update available: v${local_ver} -> v${latest_ver}"
        echo "    Fix: re-run ./setup-local-llm.sh --install (will offer to update)"
        ((issues++))
      else
        ok "Up to date (v${local_ver})"
      fi
    else
      dim "Could not check for updates (offline?)"
    fi
  else
    warn "NOT INSTALLED"
    echo "    Fix: run this script without --status to install"
    ((issues++))
  fi

  # -- Ollama server --
  if curl -sf http://localhost:11434/api/version < /dev/null &>/dev/null; then
    local server_version
    server_version=$(curl -sf http://localhost:11434/api/version < /dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','unknown'))" 2>/dev/null || echo "unknown")
    ok "Server running (v${server_version}) at localhost:11434"
  else
    warn "Server NOT RUNNING"
    echo "    Fix (macOS):  ollama serve"
    echo "    Fix (Linux):  sudo systemctl start ollama"
    ((issues++))
  fi

  # -- Downloaded models --
  echo ""
  echo "  Models"
  echo "  ------"
  if curl -sf http://localhost:11434/api/version < /dev/null &>/dev/null; then
    local model_count=0
    local dev_count=0
    while IFS= read -r line; do
      local name size
      name=$(echo "$line" | awk '{print $1}')
      size=$(echo "$line" | awk '{print $3, $4}')
      [ -z "$name" ] && continue
      ((model_count++))
      if [[ "$name" == *-dev ]]; then
        ((dev_count++))
        ok "$name  ($size) — dev variant with extended context"
      else
        dim "  $name  ($size)"
      fi
    done < <(ollama list 2>/dev/null | tail -n +2)

    if [ "$model_count" -eq 0 ]; then
      warn "No models downloaded"
      echo "    Fix: run this script to pull a model"
      ((issues++))
    elif [ "$dev_count" -eq 0 ]; then
      warn "Models found but no -dev variants (missing extended context)"
      echo "    Fix: run this script to create a dev variant"
      ((issues++))
    fi
  else
    warn "Cannot check models — server not running"
    ((issues++))
  fi

  # -- OpenCode --
  echo ""
  echo "  OpenCode"
  echo "  --------"
  if command -v opencode &>/dev/null; then
    ok "Installed: $(opencode --version 2>/dev/null || echo 'unknown')"
  else
    dim "Not installed (run script with --frontend opencode to add)"
  fi

  # -- OpenCode config --
  local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
  local config_file="$config_dir/opencode.jsonc"
  local auth_file="$config_dir/auth.json"

  if command -v opencode &>/dev/null; then
    if [ -f "$config_file" ]; then
      ok "Config found: $config_file"

      # Parse and show active model
      local active_model
      active_model=$(read_config_key "model")
      active_model="${active_model:-none}"

      dim "Active model: $active_model"

      # Check that the active model actually exists in Ollama
      if curl -sf http://localhost:11434/api/version < /dev/null &>/dev/null; then
        local model_name="${active_model#ollama/}"  # strip ollama/ prefix
        if ollama list 2>/dev/null | awk '{print $1}' | grep -qxF "$model_name"; then
          ok "Active model exists in Ollama"
        else
          warn "Active model '$model_name' NOT FOUND in Ollama"
          echo "    Fix: run this script to pull/configure the model"
          ((issues++))
        fi
      fi
    else
      warn "No config file at $config_file"
      echo "    Fix: run this script without --status to configure"
      ((issues++))
    fi

    if [ -f "$auth_file" ]; then
      ok "Auth file found: $auth_file"
    else
      warn "No auth file at $auth_file"
      echo "    Fix: run this script without --status to configure"
      ((issues++))
    fi
  fi

  # -- Goose --
  echo ""
  echo "  Goose"
  echo "  -----"
  if command -v goose &>/dev/null; then
    local goose_ver
    goose_ver=$(goose --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    ok "Installed: v${goose_ver:-unknown}"

    # Check for updates
    local goose_latest
    goose_latest=$(fetch_latest_goose_version)
    if [ -n "$goose_latest" ] && [ -n "$goose_ver" ]; then
      if [ "$(version_is_newer "$goose_ver" "$goose_latest")" = "newer" ]; then
        warn "Update available: v${goose_ver} -> v${goose_latest}"
        echo "    Fix: run 'goose update' or re-run this script"
        ((issues++))
      else
        ok "Up to date (v${goose_ver})"
      fi
    else
      dim "Could not check for updates (offline?)"
    fi

    # -- Goose config --
    local goose_config="$HOME/.config/goose/config.yaml"
    if [ -f "$goose_config" ]; then
      ok "Config found: $goose_config"
      local goose_model
      goose_model=$(grep '^GOOSE_MODEL:' "$goose_config" 2>/dev/null | awk '{print $2}' || true)
      dim "Active model: ${goose_model:-none}"

      # Check that the active model actually exists in Ollama
      if [ -n "$goose_model" ] && curl -sf http://localhost:11434/api/version < /dev/null &>/dev/null; then
        if ollama list 2>/dev/null | awk '{print $1}' | grep -qxF "$goose_model"; then
          ok "Active model exists in Ollama"
        else
          warn "Active model '$goose_model' NOT FOUND in Ollama"
          echo "    Fix: run this script to pull/configure the model"
          ((issues++))
        fi
      fi
    else
      warn "No config file at $goose_config"
      echo "    Fix: run this script without --status to configure"
      ((issues++))
    fi
  else
    dim "Not installed (run script with --frontend goose to add)"
  fi

  # -- Connectivity test: can Ollama actually run inference? --
  echo ""
  echo "  Inference Test"
  echo "  --------------"
  if curl -sf http://localhost:11434/api/version < /dev/null &>/dev/null; then
    local test_model=""
    if [ -f "$config_file" ]; then
      test_model=$(read_config_key "model")
      test_model="${test_model#ollama/}"  # strip prefix
    fi

    if [ -n "$test_model" ] && ollama list 2>/dev/null | awk '{print $1}' | grep -qxF "$test_model"; then
      info "Sending test prompt to $test_model..."
      local response
      response=$(curl -sf --max-time 30 http://localhost:11434/api/generate < /dev/null \
        -d "{\"model\": \"$test_model\", \"prompt\": \"Say hello in exactly 3 words.\", \"stream\": false}" 2>/dev/null || true)

      if [ -n "$response" ] && echo "$response" | grep -q '"response"'; then
        local reply
        reply=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('response','').strip()[:80])" 2>/dev/null || echo "")
        if [ -n "$reply" ]; then
          ok "Model responded: \"$reply\""
        else
          warn "Model returned empty response"
          ((issues++))
        fi
      else
        warn "Inference request failed or timed out"
        echo "    This could mean the model is too large for your RAM"
        ((issues++))
      fi
    else
      warn "Skipped — no active model available to test"
      ((issues++))
    fi
  else
    warn "Skipped — server not running"
  fi

  # -- Summary --
  echo ""
  echo "  ────────────────────────────────────────"
  if [ "$issues" -eq 0 ]; then
    ok "All checks passed — everything looks healthy!"
    echo ""
    echo "  Ready to use:"
    echo "    cd your-project"
    command -v opencode &>/dev/null && echo "    opencode          # terminal TUI"
    command -v goose &>/dev/null && echo "    goose             # agent with MCP extensions"
  else
    warn "$issues issue(s) found — see 'Fix' hints above"
    echo ""
    echo "  To fix most issues, re-run:"
    echo "    ./setup-local-llm.sh"
  fi
  echo ""
}

# §MAIN ==========================================================

# ----------------------------------------------------------
# Main
# ----------------------------------------------------------
main() {
  parse_args "$@"

  # A positional model name implies --install
  if [ -n "$POSITIONAL_MODEL" ]; then
    RUN_INSTALL=true
  fi

  # No command given — show help
  if ! $RUN_INSTALL && ! $RUN_STATUS; then
    show_help
    exit 0
  fi

  echo ""
  echo "  ┌──────────────────────────────────────────┐"
  echo "  │  Local LLM Dev Environment Setup          │"
  echo "  │  Ollama + Gemma 4 + OpenCode / Goose      │"
  echo "  └──────────────────────────────────────────┘"

  # Health check mode
  if $RUN_STATUS; then
    do_status
    return
  fi

  # If --fresh flag, skip detection
  if $FORCE_FRESH; then
    do_fresh_install
    return
  fi

  # Check for existing installation
  detect_existing

  local is_installed=false
  if $HAVE_OLLAMA && ( $HAVE_OPENCODE || $HAVE_GOOSE ); then
    is_installed=true
  fi

  if $is_installed; then
    # Returning user — ask what they want to do
    # But if they passed a model arg, treat it as "add model"
    if [ -n "$POSITIONAL_MODEL" ]; then
      info "Existing install detected. Adding model: $POSITIONAL_MODEL"
      ACTION="add_model"
    else
      prompt_existing_user
    fi

    case "$ACTION" in
      add_model)       do_add_model ;;
      change_context)  do_change_context ;;
      switch_model)    do_switch_model ;;
      fresh_install)   do_fresh_install ;;
      add_tool)        do_add_tool ;;
      nothing)         ok "Nothing to do. Bye!"; exit 0 ;;
    esac
  else
    # First-time user
    do_fresh_install
  fi
}

main "$@"
