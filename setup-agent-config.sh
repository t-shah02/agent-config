#!/bin/bash

set -euo pipefail

# Paths to agent config and cursor directories relative to the home of the user
AGENT_CONFIG_DIR="$HOME/.agent-config"
CONFIG_JSON="$AGENT_CONFIG_DIR/config.json"
CURSOR_SKILLS_DIR="$HOME/.cursor/skills"
CURSOR_AGENTS_DIR="$HOME/.cursor/agents"
DEFAULT_BASE_URL="https://agent-config.neetbyte.fun/"
SOURCE_MODE="local"
BASE_URL="$DEFAULT_BASE_URL"
if [ -n "${BASH_SOURCE[0]-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR="$(pwd)"
fi
PROFILE_MARKER_START="# >>> agent-config helper >>>"
PROFILE_MARKER_END="# <<< agent-config helper <<<"
PYTHON_VERSION="${PYTHON_VERSION:-3.12.12}"
NON_INTERACTIVE=0
FRESH_INSTALL=0
# Set by prepare_auto_updates_preference (0 = false, 1 = true)
AUTO_UPDATES_BOOL=0
# Prior install had .version but no config.json (migration); skip auto-update prompt
NEED_CONFIG_LEGACY_UPGRADE=0

# Colors for printing to the standard output
COLOR_RESET="\033[0m"
COLOR_RED="\033[0;31m"
COLOR_GREEN="\033[0;32m"
COLOR_BLUE="\033[0;34m"

# logging helper functions
print_info() {
    printf "${COLOR_BLUE}[INFO]${COLOR_RESET} %s\n" "$1"
}

print_error() {
    printf "${COLOR_RED}[ERROR]${COLOR_RESET} %s\n" "$1" >&2
}

print_success() {
    printf "${COLOR_GREEN}[OK]${COLOR_RESET} %s\n" "$1"
}

print_blank() {
    printf "\n"
}

print_section() {
    print_blank
    printf "${COLOR_GREEN}--------------------------------${COLOR_RESET}\n"
    print_blank
}

prompt_yes_no() {
    local prompt_text="$1"
    local reply=""

    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        print_info "$prompt_text [auto-yes due to --yes]"
        return 0
    fi

    while true; do
        read -r -p "$prompt_text [y/N]: " reply
        case "$reply" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO|"") return 1 ;;
            *) print_info "Please answer y or n." ;;
        esac
    done
}

usage() {
    cat <<EOF
Usage: $0 [--source local|remote] [--base-url URL]

Options:
  --source    Set asset source mode (default: local)
  --base-url  Base URL used in remote mode and update helper
  --yes       Non-interactive mode, auto-approve prompts
  --fresh     Remove ~/.agent-config before setup
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --source)
                SOURCE_MODE="$2"
                shift 2
                ;;
            --base-url)
                BASE_URL="$2"
                shift 2
                ;;
            --yes)
                NON_INTERACTIVE=1
                shift
                ;;
            --fresh)
                FRESH_INSTALL=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                print_error "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done
}

normalize_base_url() {
    BASE_URL="${BASE_URL%/}/"
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        print_error "Required command not found: $1"
        exit 1
    fi
}

ensure_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        print_error "jq is required to manage ~/.agent-config/config.json (e.g. pacman -S jq, apt install jq)."
        exit 1
    fi
}

prepare_auto_updates_preference() {
    ensure_jq
    if [ -f "$CONFIG_JSON" ]; then
        if jq -e '.auto_updates_enabled == true' "$CONFIG_JSON" >/dev/null 2>&1; then
            AUTO_UPDATES_BOOL=1
        else
            AUTO_UPDATES_BOOL=0
        fi
        return
    fi
    if [ "$NEED_CONFIG_LEGACY_UPGRADE" -eq 1 ]; then
        AUTO_UPDATES_BOOL=0
        print_info "Existing install without config.json: using auto_updates_enabled=false (default)."
        return
    fi
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        AUTO_UPDATES_BOOL=0
        print_info "Non-interactive mode: auto_updates_enabled=false"
        return
    fi
    if prompt_yes_no "Enable automatic agent-config update check on every shell startup?"; then
        AUTO_UPDATES_BOOL=1
    else
        AUTO_UPDATES_BOOL=0
    fi
}

write_agent_config_json() {
    local browsers_dir="$1"
    ensure_jq
    browsers_dir="$(cd "$browsers_dir" && pwd)"
    local tmp_file
    tmp_file="$(mktemp)"
    if [ -f "$CONFIG_JSON" ]; then
        jq --arg path "$browsers_dir" \
            '.playwright_browsers_path = $path | .auto_updates_enabled //= false' \
            "$CONFIG_JSON" > "$tmp_file"
    else
        if [ "$AUTO_UPDATES_BOOL" -eq 1 ]; then
            jq -n --arg path "$browsers_dir" \
                '{auto_updates_enabled: true, playwright_browsers_path: $path}' > "$tmp_file"
        else
            jq -n --arg path "$browsers_dir" \
                '{auto_updates_enabled: false, playwright_browsers_path: $path}' > "$tmp_file"
        fi
    fi
    mv "$tmp_file" "$CONFIG_JSON"
    print_success "Wrote $CONFIG_JSON"
}

sync_dir() {
    local src_dir="$1"
    local dst_dir="$2"

    mkdir -p "$dst_dir"

    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete "$src_dir/" "$dst_dir/"
    else
        rm -rf "$dst_dir"
        mkdir -p "$dst_dir"
        cp -a "$src_dir/." "$dst_dir/"
    fi
}

ensure_python_and_uv() {
    if command -v python3 >/dev/null 2>&1; then
        print_info "Python found: $(python3 --version 2>/dev/null || echo "python3")"
    else
        print_info "Python not found. Installing with pyenv..."
        require_cmd curl
        require_cmd git

        export PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"
        export PATH="$PYENV_ROOT/bin:$PATH"

        if ! command -v pyenv >/dev/null 2>&1; then
            curl -fsSL https://pyenv.run | bash
        fi

        export PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"
        export PATH="$PYENV_ROOT/bin:$PATH"
        eval "$(pyenv init -)"

        if ! pyenv versions --bare | awk -v v="$PYTHON_VERSION" '$0 == v {found=1} END {exit found?0:1}'; then
            pyenv install "$PYTHON_VERSION"
        fi

        export PYENV_VERSION="$PYTHON_VERSION"
        print_success "Python installed with pyenv: $PYTHON_VERSION"
    fi

    if command -v uv >/dev/null 2>&1; then
        print_info "uv already installed: $(uv --version)"
    else
        print_info "uv not found. Installing uv..."
        require_cmd curl
        curl -LsSf https://astral.sh/uv/install.sh | sh
        export PATH="$HOME/.local/bin:$PATH"
        print_success "uv installed: $(uv --version)"
    fi
}

get_shell_profile_path() {
    case "$(basename "${SHELL:-}")" in
        zsh) echo "$HOME/.zshrc" ;;
        bash) echo "$HOME/.bashrc" ;;
        fish) echo "$HOME/.config/fish/config.fish" ;;
        *) echo "$HOME/.profile" ;;
    esac
}

sync_from_local_source() {
    local local_root="$SCRIPT_DIR"

    if [ ! -d "$local_root/config" ]; then
        print_error "Expected config directory at $local_root/config"
        exit 1
    fi

    if [ ! -d "$local_root/packages" ]; then
        print_error "Expected packages directory at $local_root/packages"
        exit 1
    fi

    mkdir -p "$AGENT_CONFIG_DIR"
    sync_dir "$local_root/config/skills" "$AGENT_CONFIG_DIR/skills"
    if [ -d "$local_root/config/agents" ]; then
        sync_dir "$local_root/config/agents" "$AGENT_CONFIG_DIR/agents"
    fi
    sync_dir "$local_root/packages" "$AGENT_CONFIG_DIR/packages"
    cp "$local_root/.version" "$AGENT_CONFIG_DIR/.version"
    print_success "Synced local config, packages, and version into $AGENT_CONFIG_DIR"
}

sync_from_remote_source() {
    require_cmd curl
    mkdir -p "$AGENT_CONFIG_DIR"
    curl -fsSL "${BASE_URL}.version" -o "$AGENT_CONFIG_DIR/.version"
    print_info "Downloaded version file from ${BASE_URL}.version"

    local tmp_dir
    tmp_dir="$(mktemp -d)"

    cleanup_remote_tmp() {
        rm -rf "${tmp_dir:-}"
    }
    trap cleanup_remote_tmp EXIT

    print_info "Downloading remote directories from ${BASE_URL}"

    if command -v wget >/dev/null 2>&1; then
        wget -q -r -np -nH --reject "index.html*" -P "$tmp_dir" "${BASE_URL}config/skills/"
        wget -q -r -np -nH --reject "index.html*" -P "$tmp_dir" "${BASE_URL}packages/"

        if wget --spider -q "${BASE_URL}config/agents/"; then
            wget -q -r -np -nH --reject "index.html*" -P "$tmp_dir" "${BASE_URL}config/agents/"
        fi
    else
        require_cmd python3
        require_cmd curl
        local mirror_py="$tmp_dir/remote_mirror_download.py"
        if [ -f "$SCRIPT_DIR/scripts/remote_mirror_download.py" ]; then
            cp "$SCRIPT_DIR/scripts/remote_mirror_download.py" "$mirror_py"
        else
            curl -fsSL "${BASE_URL}scripts/remote_mirror_download.py" -o "$mirror_py"
        fi
        python3 "$mirror_py" "$BASE_URL" "$tmp_dir"
    fi

    sync_dir "$tmp_dir/config/skills" "$AGENT_CONFIG_DIR/skills"

    if [ -d "$tmp_dir/config/agents" ]; then
        sync_dir "$tmp_dir/config/agents" "$AGENT_CONFIG_DIR/agents"
    fi

    sync_dir "$tmp_dir/packages" "$AGENT_CONFIG_DIR/packages"
    print_success "Synced remote config, packages, and version into $AGENT_CONFIG_DIR"
}

sync_sources() {
    if [ "$SOURCE_MODE" = "local" ]; then
        sync_from_local_source
    elif [ "$SOURCE_MODE" = "remote" ]; then
        sync_from_remote_source
    else
        print_error "Invalid --source value: $SOURCE_MODE (expected local|remote)"
        exit 1
    fi
}

ensure_symlink() {
    local source_path="$1"
    local target_path="$2"

    if [ -L "$target_path" ]; then
        local current_link
        current_link="$(readlink "$target_path")"
        if [ "$current_link" = "$source_path" ]; then
            print_info "Already linked: $target_path"
            return
        fi
        rm -f "$target_path"
    elif [ -e "$target_path" ]; then
        local backup_path="${target_path}.backup.$(date +%s)"
        mv "$target_path" "$backup_path"
        print_info "Backed up existing path to $backup_path"
    fi

    ln -s "$source_path" "$target_path"
    print_success "Linked $target_path -> $source_path"
}

symlink_skills() {
    local source_dir="$AGENT_CONFIG_DIR/skills"
    mkdir -p "$CURSOR_SKILLS_DIR"

    if [ ! -d "$source_dir" ]; then
        print_error "Skills source directory not found: $source_dir"
        return
    fi

    for category in "$source_dir"/*; do
        [ -d "$category" ] || continue
        local category_name
        category_name="$(basename "$category")"
        local target_category_dir="$CURSOR_SKILLS_DIR/$category_name"
        mkdir -p "$target_category_dir"

        for skill in "$category"/*; do
            [ -d "$skill" ] || continue
            if [ ! -f "$skill/SKILL.md" ]; then
                print_info "Skipping non-skill directory: $skill"
                continue
            fi

            local skill_name
            skill_name="$(basename "$skill")"
            ensure_symlink "$skill" "$target_category_dir/$skill_name"
        done
    done
}

symlink_agents() {
    local source_dir="$AGENT_CONFIG_DIR/agents"
    mkdir -p "$CURSOR_AGENTS_DIR"

    if [ ! -d "$source_dir" ]; then
        print_info "Agents source directory not found, skipping: $source_dir"
        return
    fi

    for agent in "$source_dir"/*; do
        [ -e "$agent" ] || continue
        local name
        name="$(basename "$agent")"
        ensure_symlink "$agent" "$CURSOR_AGENTS_DIR/$name"
    done
}

install_shell_update_helper() {
    local profile_file
    profile_file="$(get_shell_profile_path)"
    mkdir -p "$(dirname "$profile_file")"
    touch "$profile_file"

    local helper_block
    helper_block=$(cat <<EOF
$PROFILE_MARKER_START
agent_config_update() {
  local base_url="${BASE_URL}"
  local local_version_file="\$HOME/.agent-config/.version"
  local local_version=""
  local remote_version=""
  local auto_yes="\$1"

  if [ -f "\$local_version_file" ]; then
    local_version="\$(tr -d '[:space:]' < "\$local_version_file")"
  fi

  remote_version="\$(curl -fsSL "\${base_url}.version" | tr -d '[:space:]')" || {
    echo "[agent-config] Unable to fetch remote version from \${base_url}.version" >&2
    return 1
  }

  if [ "\$local_version" = "\$remote_version" ]; then
    echo "[agent-config] Up to date (\$local_version)."
    return 0
  fi

  echo "[agent-config] Update available: \${local_version:-none} -> \$remote_version"
  if [ "\$auto_yes" = "--yes" ]; then
    echo "[agent-config] Auto-approving update due to --yes"
  else
    printf "[agent-config] Run update now? [y/N]: "
    read -r confirm_update
    case "\$confirm_update" in
      y|Y|yes|YES) ;;
      *) echo "[agent-config] Update skipped."; return 0 ;;
    esac
  fi

  echo "[agent-config] Running update..."
  if [ "\$auto_yes" = "--yes" ]; then
    curl -fsSL "\${base_url}setup-agent-config.sh" | bash -s -- --source remote --base-url "\$base_url" --yes
  else
    curl -fsSL "\${base_url}setup-agent-config.sh" | bash -s -- --source remote --base-url "\$base_url"
  fi
}
agent_config_maybe_auto_update() {
  local cfg="\$HOME/.agent-config/config.json"
  [ -f "\$cfg" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -e '.auto_updates_enabled == true' "\$cfg" >/dev/null 2>&1 || return 0
  agent_config_update --yes
}
agent_config_maybe_auto_update
$PROFILE_MARKER_END
EOF
)

    if awk -v start="$PROFILE_MARKER_START" '$0 == start {found=1} END{exit found?0:1}' "$profile_file"; then
        local tmp_file
        tmp_file="$(mktemp)"
        awk -v start="$PROFILE_MARKER_START" -v end="$PROFILE_MARKER_END" '
            $0 == start {in_block=1; next}
            $0 == end {in_block=0; next}
            in_block == 0 {print}
        ' "$profile_file" > "$tmp_file"
        mv "$tmp_file" "$profile_file"
    fi

    print_blank >> "$profile_file"
    printf "%s\n" "$helper_block" >> "$profile_file"
    print_success "Installed shell helper 'agent_config_update' in $profile_file"
}

detect_package_manager() {
    if command -v pacman >/dev/null 2>&1; then
        echo "pacman"
    elif command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v zypper >/dev/null 2>&1; then
        echo "zypper"
    elif command -v snap >/dev/null 2>&1; then
        echo "snap"
    else
        echo "unknown"
    fi
}

install_system_browser_deps() {
    local pkg_manager
    pkg_manager="$(detect_package_manager)"
    local cmd=""

    case "$pkg_manager" in
        pacman)
            cmd="sudo pacman -S --needed nss atk at-spi2-atk cups libdrm gtk3 libxcomposite libxdamage libxfixes libxrandr alsa-lib pango cairo libxkbcommon libx11 libxext libxrender libxcb freetype2 harfbuzz"
            ;;
        apt)
            cmd="sudo apt-get update && sudo apt-get install -y libnss3 libatk-bridge2.0-0 libcups2 libdrm2 libgtk-3-0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libasound2t64 libpangocairo-1.0-0 libxkbcommon0 libx11-6 libxext6 libxrender1 libxcb1 libfreetype6 libharfbuzz0b"
            ;;
        dnf)
            cmd="sudo dnf install -y nss atk at-spi2-atk cups-libs libdrm gtk3 libXcomposite libXdamage libXfixes libXrandr alsa-lib pango cairo libxkbcommon libX11 libXext libXrender libxcb freetype harfbuzz"
            ;;
        zypper)
            cmd="sudo zypper install -y mozilla-nss atk at-spi2-atk cups-libs libdrm2 gtk3 libXcomposite1 libXdamage1 libXfixes3 libXrandr2 alsa-lib pango cairo libxkbcommon0 libX11-6 libXext6 libXrender1 libxcb1 libfreetype6 harfbuzz"
            ;;
        snap)
            cmd="sudo snap install chromium"
            ;;
        *)
            print_info "Could not detect supported package manager for auto-install."
            return 0
            ;;
    esac

    print_info "Detected package manager: $pkg_manager"
    print_info "Playwright may need system dependencies for browser runtime."
    if prompt_yes_no "Run system dependency install command now?"; then
        print_info "Running: $cmd"
        eval "$cmd"
        print_success "System dependency install command completed."
    else
        print_info "Skipped system dependency install command."
    fi
}

install_packages() {
    local packages_dir="$AGENT_CONFIG_DIR/packages"
    local browsers_dir="$AGENT_CONFIG_DIR/browsers"

    if [ ! -d "$packages_dir" ]; then
        print_error "Packages directory not found: $packages_dir"
        return 1
    fi

    mkdir -p "$browsers_dir"

    print_info "Installing packages in $packages_dir with uv"
    (
        cd "$packages_dir"
        # Avoid inheriting an unrelated virtualenv from the caller shell.
        unset VIRTUAL_ENV
        uv sync
        PLAYWRIGHT_BROWSERS_PATH="$browsers_dir" uv run playwright install chromium
    )
    print_success "Installed Python dependencies and Playwright chromium browser at $browsers_dir"
    print_info "Arch Linux uses Playwright fallback browser builds (expected warning)."
    install_system_browser_deps
}


# entry point
main() {
    parse_args "$@"
    normalize_base_url

    if [ "$FRESH_INSTALL" -eq 1 ]; then
        if [ -d "$AGENT_CONFIG_DIR" ]; then
            print_info "Fresh install requested; removing $AGENT_CONFIG_DIR"
            rm -rf "$AGENT_CONFIG_DIR"
            print_success "Removed $AGENT_CONFIG_DIR"
        else
            print_info "Fresh install requested; no existing directory at $AGENT_CONFIG_DIR"
        fi
    fi

    if [ -d "$AGENT_CONFIG_DIR" ]; then
        print_info "Agent config directory already exists at $AGENT_CONFIG_DIR"
    else
        mkdir -p "$AGENT_CONFIG_DIR"
        print_info "Agent config directory created at $AGENT_CONFIG_DIR"
    fi

    print_section

    print_info "Source mode: $SOURCE_MODE"
    print_info "Base URL: $BASE_URL"

    NEED_CONFIG_LEGACY_UPGRADE=0
    if [ -d "$AGENT_CONFIG_DIR" ] && [ -f "$AGENT_CONFIG_DIR/.version" ] && [ ! -f "$CONFIG_JSON" ]; then
        NEED_CONFIG_LEGACY_UPGRADE=1
    fi

    sync_sources

    prepare_auto_updates_preference

    print_section

    ensure_python_and_uv

    print_section

    install_packages

    write_agent_config_json "$AGENT_CONFIG_DIR/browsers"

    print_section

    print_info "Setting up agent skills from $AGENT_CONFIG_DIR/skills to $CURSOR_SKILLS_DIR"
    symlink_skills

    print_section

    print_info "Setting up agent agents from $AGENT_CONFIG_DIR/agents to $CURSOR_AGENTS_DIR"
    symlink_agents

    print_section

    install_shell_update_helper
}

# run the script
main "$@"


