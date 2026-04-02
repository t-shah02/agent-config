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
CLI_PROFILE_MARKER_START="# >>> agent-config cli >>>"
CLI_PROFILE_MARKER_END="# <<< agent-config cli <<<"
COMPLETION_PROFILE_MARKER_START="# >>> agent-config completion >>>"
COMPLETION_PROFILE_MARKER_END="# <<< agent-config completion <<<"
PYTHON_VERSION="${PYTHON_VERSION:-3.12.12}"
NON_INTERACTIVE=0
FRESH_INSTALL=0
# Set by prepare_auto_updates_preference (0 = false, 1 = true)
AUTO_UPDATES_BOOL=0
# Prior install had .version but no config.json (migration); skip auto-update prompt
NEED_CONFIG_LEGACY_UPGRADE=0
# Deferred .version commit (see agent_config_revert_version_on_exit)
PREVIOUS_VERSION_SNAPSHOT=""
REMOTE_SYNC_TMP_DIR=""
SETUP_COMPLETED=0

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

agent_config_revert_version_on_exit() {
    rm -rf "${REMOTE_SYNC_TMP_DIR:-}" 2>/dev/null || true
    if [ "${SETUP_COMPLETED:-0}" = 1 ]; then
        rm -f "${PREVIOUS_VERSION_SNAPSHOT:-}" 2>/dev/null || true
        return 0
    fi
    rm -f "$AGENT_CONFIG_DIR/.version.pending" 2>/dev/null || true
    if [ -n "${PREVIOUS_VERSION_SNAPSHOT:-}" ] && [ -f "$PREVIOUS_VERSION_SNAPSHOT" ] && [ -s "$PREVIOUS_VERSION_SNAPSHOT" ]; then
        cp "$PREVIOUS_VERSION_SNAPSHOT" "$AGENT_CONFIG_DIR/.version"
        print_info "Restored previous .version after setup did not complete successfully." >&2
    fi
    rm -f "${PREVIOUS_VERSION_SNAPSHOT:-}" 2>/dev/null || true
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
    cp "$local_root/.version" "$AGENT_CONFIG_DIR/.version.pending"
    cp "$local_root/agent-config-utils.sh" "$AGENT_CONFIG_DIR/agent-config-utils.sh"
    if [ -d "$local_root/completions" ]; then
        mkdir -p "$AGENT_CONFIG_DIR/completions"
        cp "$local_root/completions/agent-config.bash" "$AGENT_CONFIG_DIR/completions/agent-config.bash"
        cp "$local_root/completions/_agent_config" "$AGENT_CONFIG_DIR/completions/_agent_config"
        cp "$local_root/completions/agent-config.fish" "$AGENT_CONFIG_DIR/completions/agent-config.fish"
    fi
    print_success "Synced local config, packages, and pending version into $AGENT_CONFIG_DIR"
}

sync_from_remote_source() {
    require_cmd curl
    mkdir -p "$AGENT_CONFIG_DIR"
    curl -fsSL "${BASE_URL}.version" -o "$AGENT_CONFIG_DIR/.version.pending"
    print_info "Downloaded pending version file from ${BASE_URL}.version"

    REMOTE_SYNC_TMP_DIR="$(mktemp -d)"
    local tmp_dir="$REMOTE_SYNC_TMP_DIR"

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
    rm -rf "$REMOTE_SYNC_TMP_DIR"
    REMOTE_SYNC_TMP_DIR=""
    curl -fsSL "${BASE_URL}agent-config-utils.sh" -o "$AGENT_CONFIG_DIR/agent-config-utils.sh"
    curl -fsSL "${BASE_URL}agent-config" -o "$AGENT_CONFIG_DIR/agent-config"
    chmod 755 "$AGENT_CONFIG_DIR/agent-config"
    mkdir -p "$AGENT_CONFIG_DIR/completions"
    curl -fsSL "${BASE_URL}completions/agent-config.bash" -o "$AGENT_CONFIG_DIR/completions/agent-config.bash"
    curl -fsSL "${BASE_URL}completions/_agent_config" -o "$AGENT_CONFIG_DIR/completions/_agent_config"
    curl -fsSL "${BASE_URL}completions/agent-config.fish" -o "$AGENT_CONFIG_DIR/completions/agent-config.fish"
    print_success "Synced remote config, packages, and pending version into $AGENT_CONFIG_DIR"
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

agent_config_cli_share_dir() {
    printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/agent-config"
}

extract_agent_config_cli_alias_name() {
    local profile="$1"
    awk -v start="$CLI_PROFILE_MARKER_START" -v end="$CLI_PROFILE_MARKER_END" '
        $0 == start { inb=1; next }
        $0 == end { inb=0; next }
        inb && /^alias / {
            line=$0
            sub(/^alias */, "", line)
            sub(/=.*/, "", line)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            print line
            exit
        }
        inb && /^function / {
            print $2
            exit
        }
    ' "$profile"
}

install_agent_config_cli() {
    local share
    share="$(agent_config_cli_share_dir)"
    local bin_link="$HOME/.local/bin/agent-config"
    mkdir -p "$share" "$HOME/.local/bin"
    if [ "$SOURCE_MODE" = "local" ]; then
        if [ ! -f "$SCRIPT_DIR/agent-config" ] || [ ! -f "$SCRIPT_DIR/agent-config-utils.sh" ]; then
            print_error "Missing agent-config or agent-config-utils.sh in $SCRIPT_DIR"
            exit 1
        fi
        cp "$SCRIPT_DIR/agent-config" "$share/agent-config"
        cp "$SCRIPT_DIR/agent-config-utils.sh" "$share/agent-config-utils.sh"
    else
        if [ ! -f "$AGENT_CONFIG_DIR/agent-config" ] || [ ! -f "$AGENT_CONFIG_DIR/agent-config-utils.sh" ]; then
            print_error "Missing downloaded CLI files under $AGENT_CONFIG_DIR"
            exit 1
        fi
        cp "$AGENT_CONFIG_DIR/agent-config" "$share/agent-config"
        cp "$AGENT_CONFIG_DIR/agent-config-utils.sh" "$share/agent-config-utils.sh"
    fi
    chmod 755 "$share/agent-config"
    chmod 644 "$share/agent-config-utils.sh"
    if [ -e "$bin_link" ] && [ ! -L "$bin_link" ]; then
        local backup_path="${bin_link}.backup.$(date +%s)"
        mv "$bin_link" "$backup_path"
        print_info "Backed up existing $bin_link to $backup_path"
    fi
    ln -sf "$share/agent-config" "$bin_link"
    print_success "Installed agent-config CLI to $bin_link (-> $share/agent-config)"
}

install_cli_shell_alias() {
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        print_info "Skipping agent-config CLI shell alias (non-interactive / --yes)."
        return 0
    fi
    local profile
    profile="$(get_shell_profile_path)"
    mkdir -p "$(dirname "$profile")"
    touch "$profile"
    local name="agent-config"
    if awk -v start="$CLI_PROFILE_MARKER_START" '$0 == start {found=1} END{exit found?0:1}' "$profile"; then
        local prev
        prev="$(extract_agent_config_cli_alias_name "$profile")"
        if [ -n "$prev" ]; then
            name="$prev"
        fi
    else
        local reply=""
        read -r -p "Shell command name for agent-config CLI [agent-config]: " reply || true
        if [ -n "$reply" ]; then
            name="$reply"
        fi
    fi
    local share_bin share_bin_abs
    share_bin="$(agent_config_cli_share_dir)/agent-config"
    if [ -f "$share_bin" ]; then
        share_bin_abs="$(readlink -f "$share_bin")"
    else
        share_bin_abs="$share_bin"
    fi
    local helper_block
    local esc_rhs
    esc_rhs="${share_bin_abs//\'/\'\\\'\'}"
    case "$(basename "${SHELL:-bash}")" in
        fish)
            helper_block=$(printf '%s\nfunction %s\n    %s $argv\nend\n%s\n' \
                "$CLI_PROFILE_MARKER_START" "$name" "$share_bin_abs" "$CLI_PROFILE_MARKER_END")
            ;;
        *)
            helper_block=$(printf "%s\nalias %s='%s'\n%s\n" \
                "$CLI_PROFILE_MARKER_START" "$name" "$esc_rhs" "$CLI_PROFILE_MARKER_END")
            ;;
    esac
    if awk -v start="$CLI_PROFILE_MARKER_START" '$0 == start {found=1} END{exit found?0:1}' "$profile"; then
        local tmp_file
        tmp_file="$(mktemp)"
        awk -v start="$CLI_PROFILE_MARKER_START" -v end="$CLI_PROFILE_MARKER_END" '
            $0 == start {in_block=1; next}
            $0 == end {in_block=0; next}
            in_block == 0 {print}
        ' "$profile" > "$tmp_file"
        mv "$tmp_file" "$profile"
    fi
    print_blank >> "$profile"
    printf "%s\n" "$helper_block" >> "$profile"
    print_success "Installed agent-config CLI shell alias '$name' in $profile"
}

install_agent_config_completion_profile_snippets() {
    local profile
    profile="$(get_shell_profile_path)"
    mkdir -p "$(dirname "$profile")"
    touch "$profile"

    case "$(basename "${SHELL:-bash}")" in
        fish)
            return 0
            ;;
        zsh)
            local zsh_block
            zsh_block=$(cat <<'EOF'
# >>> agent-config completion >>>
fpath=("$HOME/.local/share/zsh/site-functions" $fpath)
# <<< agent-config completion <<<
EOF
)
            if awk -v start="$COMPLETION_PROFILE_MARKER_START" '$0 == start {found=1} END{exit found?0:1}' "$profile"; then
                local tmp_file
                tmp_file="$(mktemp)"
                awk -v start="$COMPLETION_PROFILE_MARKER_START" -v end="$COMPLETION_PROFILE_MARKER_END" '
                    $0 == start {in_block=1; next}
                    $0 == end {in_block=0; next}
                    in_block == 0 {print}
                ' "$profile" > "$tmp_file"
                mv "$tmp_file" "$profile"
            fi
            print_blank >> "$profile"
            printf "%s\n" "$zsh_block" >> "$profile"
            print_success "Added zsh fpath for agent-config completions in $profile (run compinit if needed)"
            ;;
        *)
            local bash_block
            bash_block=$(cat <<'EOF'
# >>> agent-config completion >>>
[ -f "$HOME/.local/share/agent-config/completions/agent-config.bash" ] && . "$HOME/.local/share/agent-config/completions/agent-config.bash"
# <<< agent-config completion <<<
EOF
)
            if awk -v start="$COMPLETION_PROFILE_MARKER_START" '$0 == start {found=1} END{exit found?0:1}' "$profile"; then
                local tmp_file
                tmp_file="$(mktemp)"
                awk -v start="$COMPLETION_PROFILE_MARKER_START" -v end="$COMPLETION_PROFILE_MARKER_END" '
                    $0 == start {in_block=1; next}
                    $0 == end {in_block=0; next}
                    in_block == 0 {print}
                ' "$profile" > "$tmp_file"
                mv "$tmp_file" "$profile"
            fi
            print_blank >> "$profile"
            printf "%s\n" "$bash_block" >> "$profile"
            print_success "Added bash completion hook for agent-config in $profile"
            ;;
    esac
}

install_agent_config_completions() {
    local src=""
    if [ "$SOURCE_MODE" = "local" ]; then
        src="$SCRIPT_DIR/completions"
    else
        src="$AGENT_CONFIG_DIR/completions"
    fi
    if [ ! -f "$src/agent-config.bash" ] || [ ! -f "$src/_agent_config" ] || [ ! -f "$src/agent-config.fish" ]; then
        print_info "agent-config shell completions not found under $src; skipping."
        return 0
    fi

    local share
    share="$(agent_config_cli_share_dir)"
    mkdir -p "$share/completions"
    cp "$src/agent-config.bash" "$share/completions/agent-config.bash"
    cp "$src/_agent_config" "$share/completions/_agent_config"
    cp "$src/agent-config.fish" "$share/completions/agent-config.fish"
    chmod 644 "$share/completions/agent-config.bash" "$share/completions/_agent_config" "$share/completions/agent-config.fish"

    local bcu="${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions"
    mkdir -p "$bcu"
    cp "$src/agent-config.bash" "$bcu/agent-config"

    local zsh_sf="${XDG_DATA_HOME:-$HOME/.local/share}/zsh/site-functions"
    mkdir -p "$zsh_sf"
    cp "$src/_agent_config" "$zsh_sf/_agent_config"

    mkdir -p "$HOME/.config/fish/completions"
    cp "$src/agent-config.fish" "$HOME/.config/fish/completions/agent-config.fish"

    print_success "Installed agent-config tab completions (bash, zsh, fish)"
    install_agent_config_completion_profile_snippets
}

# True if PLAYWRIGHT_BROWSERS_PATH already contains a chromium build (this setup's layout).
playwright_chromium_present_in() {
    local root="${1:?}"
    [ -d "$root" ] || return 1
    local c
    for c in "$root"/chromium-*; do
        [ -d "$c" ] || continue
        if [ -d "$c/chrome-linux" ]; then
            return 0
        fi
    done
    return 1
}

install_packages() {
    local packages_dir="$AGENT_CONFIG_DIR/packages"
    local browsers_dir="$AGENT_CONFIG_DIR/browsers"

    if [ ! -d "$packages_dir" ]; then
        print_error "Packages directory not found: $packages_dir"
        return 1
    fi

    mkdir -p "$browsers_dir"

    local skip_playwright_install=0
    if playwright_chromium_present_in "$browsers_dir"; then
        print_info "Playwright chromium already present under $browsers_dir; skipping browser download."
        skip_playwright_install=1
    fi

    print_info "Installing packages in $packages_dir with uv"
    (
        cd "$packages_dir"
        # Avoid inheriting an unrelated virtualenv from the caller shell.
        unset VIRTUAL_ENV
        uv sync
        if [ "$skip_playwright_install" -eq 0 ]; then
            PLAYWRIGHT_BROWSERS_PATH="$browsers_dir" uv run playwright install chromium
        fi
    )
    if [ "$skip_playwright_install" -eq 1 ]; then
        print_success "Synced Python dependencies; reused existing Playwright chromium at $browsers_dir"
    else
        print_success "Installed Python dependencies and Playwright chromium browser at $browsers_dir"
    fi
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

    PREVIOUS_VERSION_SNAPSHOT="$(mktemp)"
    trap 'agent_config_revert_version_on_exit' EXIT
    if [ -f "$AGENT_CONFIG_DIR/.version" ]; then
        cp "$AGENT_CONFIG_DIR/.version" "$PREVIOUS_VERSION_SNAPSHOT"
    else
        : > "$PREVIOUS_VERSION_SNAPSHOT"
    fi

    sync_sources

    if [ ! -f "$AGENT_CONFIG_DIR/agent-config-utils.sh" ]; then
        print_error "Missing $AGENT_CONFIG_DIR/agent-config-utils.sh (sync or download failed)."
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$AGENT_CONFIG_DIR/agent-config-utils.sh"

    print_section

    print_info "Installing agent-config CLI to $(agent_config_cli_share_dir) and $HOME/.local/bin"
    install_agent_config_cli
    install_cli_shell_alias
    install_agent_config_completions

    print_section

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

    if [ -f "$AGENT_CONFIG_DIR/.version.pending" ]; then
        mv -f "$AGENT_CONFIG_DIR/.version.pending" "$AGENT_CONFIG_DIR/.version"
    fi
    SETUP_COMPLETED=1
}

# run the script
main "$@"


