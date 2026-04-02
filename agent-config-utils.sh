#!/usr/bin/env bash
# shellcheck shell=bash
# Sourced by setup-agent-config.sh and the agent-config CLI (not executed alone).

AGENT_CONFIG_DIR="${AGENT_CONFIG_DIR:-$HOME/.agent-config}"
CURSOR_SKILLS_DIR="${CURSOR_SKILLS_DIR:-$HOME/.cursor/skills}"
CURSOR_AGENTS_DIR="${CURSOR_AGENTS_DIR:-$HOME/.cursor/agents}"

# Set to 1 so collision resolution always proceeds to ensure_symlink (reinstall-all).
AGENT_CONFIG_SYMLINK_FORCE="${AGENT_CONFIG_SYMLINK_FORCE:-0}"

if ! declare -F print_info >/dev/null 2>&1; then
    COLOR_RESET="\033[0m"
    COLOR_RED="\033[0;31m"
    COLOR_GREEN="\033[0;32m"
    COLOR_BLUE="\033[0;34m"
    print_info() { printf "${COLOR_BLUE}[INFO]${COLOR_RESET} %s\n" "$1"; }
    print_error() { printf "${COLOR_RED}[ERROR]${COLOR_RESET} %s\n" "$1" >&2; }
    print_success() { printf "${COLOR_GREEN}[OK]${COLOR_RESET} %s\n" "$1"; }
    print_blank() { printf "\n"; }
fi

agent_config_is_skill_bundle() {
    [ -d "$1" ] && [ -f "$1/SKILL.md" ]
}

agent_config_is_agent_bundle() {
    [ -d "$1" ] && [ -f "$1/AGENTS.md" ]
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

# Returns: 0 = run ensure_symlink (vacant path or user approved override)
#          1 = skip this entry (user declined, non-interactive collision)
#          2 = already correct symlink (nothing to do)
prompt_resolve_symlink_collision() {
    local kind_label="$1"
    local entry_name="$2"
    local target_link="$3"
    local source_path="$4"
    local source_abs
    source_abs="$(readlink -f "$source_path" 2>/dev/null || true)"
    if [ -z "$source_abs" ] && [ -d "$source_path" ]; then
        source_abs="$(cd "$source_path" && pwd -P)"
    fi

    if [ "${AGENT_CONFIG_SYMLINK_FORCE:-0}" -eq 1 ]; then
        if [ ! -L "$target_link" ] && [ ! -e "$target_link" ]; then
            return 0
        fi
        if [ -L "$target_link" ]; then
            local existing_abs
            existing_abs="$(readlink -f "$target_link" 2>/dev/null || true)"
            if [ -n "$existing_abs" ] && [ -n "$source_abs" ] && [ "$existing_abs" = "$source_abs" ]; then
                return 2
            fi
        fi
        return 0
    fi

    if [ ! -L "$target_link" ] && [ ! -e "$target_link" ]; then
        return 0
    fi

    if [ -L "$target_link" ]; then
        local existing_abs
        existing_abs="$(readlink -f "$target_link" 2>/dev/null || true)"
        if [ -n "$existing_abs" ] && [ -n "$source_abs" ] && [ "$existing_abs" = "$source_abs" ]; then
            return 2
        fi
    fi

    local target_desc
    if [ -L "$target_link" ]; then
        target_desc="symbolic link -> $(readlink "$target_link")"
    elif [ -d "$target_link" ]; then
        target_desc="directory (not installed by this setup)"
    else
        target_desc="existing file"
    fi

    print_blank
    print_info "${kind_label} name conflict for '${entry_name}': ${target_link} already exists."
    print_info "  Current: ${target_desc}"
    print_info "  This setup would link to: ${source_abs}"

    if [ "${NON_INTERACTIVE:-0}" -eq 1 ]; then
        print_info "Skipping (non-interactive / --yes). Re-run setup interactively to replace this path."
        return 1
    fi

    if ! declare -F prompt_yes_no >/dev/null 2>&1; then
        print_info "Skipping (no prompt_yes_no). Re-run setup interactively to replace this path."
        return 1
    fi

    if prompt_yes_no "Replace the existing entry with that symlink (backed up first)?"; then
        return 0
    fi

    print_info "Skipped: ${entry_name} (left ${target_link} unchanged)."
    return 1
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

        for skill in "$category"/*; do
            [ -d "$skill" ] || continue
            if ! agent_config_is_skill_bundle "$skill"; then
                print_info "Skipping non-skill directory: $skill"
                continue
            fi

            local skill_name
            skill_name="$(basename "$skill")"
            local target_link="$CURSOR_SKILLS_DIR/$skill_name"
            prompt_resolve_symlink_collision "Skill" "$skill_name" "$target_link" "$skill"
            case $? in
                0) ensure_symlink "$skill" "$target_link" ;;
                1) ;;
                2) print_info "Already linked: $target_link" ;;
            esac
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

    for item in "$source_dir"/*; do
        [ -e "$item" ] || continue
        if agent_config_is_agent_bundle "$item"; then
            local name
            name="$(basename "$item")"
            local target_link="$CURSOR_AGENTS_DIR/$name"
            prompt_resolve_symlink_collision "Agent" "$name" "$target_link" "$item"
            case $? in
                0) ensure_symlink "$item" "$target_link" ;;
                1) ;;
                2) print_info "Already linked: $target_link" ;;
            esac
            continue
        fi
        if [ ! -d "$item" ]; then
            continue
        fi
        for agent in "$item"/*; do
            [ -d "$agent" ] || continue
            if ! agent_config_is_agent_bundle "$agent"; then
                print_info "Skipping non-agent directory: $agent"
                continue
            fi
            local agent_name
            agent_name="$(basename "$agent")"
            local target_link="$CURSOR_AGENTS_DIR/$agent_name"
            prompt_resolve_symlink_collision "Agent" "$agent_name" "$target_link" "$agent"
            case $? in
                0) ensure_symlink "$agent" "$target_link" ;;
                1) ;;
                2) print_info "Already linked: $target_link" ;;
            esac
        done
    done
}

agent_config_realpath_or_empty() {
    readlink -f "$1" 2>/dev/null || true
}

agent_config_path_under_dir() {
    local path="${1:?}"
    local dir="${2:?}"
    local rp dirp
    rp="$(agent_config_realpath_or_empty "$path")"
    dirp="$(agent_config_realpath_or_empty "$dir")"
    [ -n "$rp" ] && [ -n "$dirp" ] || return 1
    case "$rp" in
        "$dirp" | "$dirp"/*) return 0 ;;
        *) return 1 ;;
    esac
}

agent_config_remove_symlinks_under() {
    local cursor_parent="$1"
    local prefix_dir="$2"
    [ -d "$cursor_parent" ] || return 0
    local entry target
    for entry in "$cursor_parent"/*; do
        [ -e "$entry" ] || continue
        if [ ! -L "$entry" ]; then
            continue
        fi
        target="$(readlink -f "$entry" 2>/dev/null || true)"
        [ -n "$target" ] || continue
        if agent_config_path_under_dir "$target" "$prefix_dir"; then
            rm -f "$entry"
            print_info "Removed symlink $entry"
        fi
    done
}

agent_config_list_sections() {
    agent_config_require_agent_config_dir
    local lines s
    lines="$(
        {
            if [ -d "$AGENT_CONFIG_DIR/skills" ]; then
                for s in "$AGENT_CONFIG_DIR/skills"/*; do
                    [ -d "$s" ] || continue
                    printf '%s\n' "$(basename "$s")"
                done
            fi
            if [ -d "$AGENT_CONFIG_DIR/agents" ]; then
                for s in "$AGENT_CONFIG_DIR/agents"/*; do
                    [ -d "$s" ] || continue
                    printf '%s\n' "$(basename "$s")"
                done
            fi
        } | sort -u
    )"
    if [ -z "$lines" ]; then
        print_info "No sections found under $AGENT_CONFIG_DIR/skills or $AGENT_CONFIG_DIR/agents."
        return 0
    fi
    printf '%s\n' "$lines"
}

agent_config_remove_section() {
    local name="${1:?}"
    agent_config_require_agent_config_dir
    local skill_sec="$AGENT_CONFIG_DIR/skills/$name"
    local agent_sec="$AGENT_CONFIG_DIR/agents/$name"
    if [ ! -d "$skill_sec" ] && [ ! -d "$agent_sec" ]; then
        print_error "No section '$name' under skills or agents."
        return 1
    fi
    if [ -d "$skill_sec" ]; then
        agent_config_remove_symlinks_under "$CURSOR_SKILLS_DIR" "$skill_sec"
        rm -rf "$skill_sec"
        print_success "Removed skills section: $name"
    fi
    if [ -d "$agent_sec" ]; then
        agent_config_remove_symlinks_under "$CURSOR_AGENTS_DIR" "$agent_sec"
        rm -rf "$agent_sec"
        print_success "Removed agents section: $name"
    fi
}

agent_config_reinstall_all() {
    agent_config_require_agent_config_dir
    local prev_force="${AGENT_CONFIG_SYMLINK_FORCE:-0}"
    local prev_ni="${NON_INTERACTIVE:-0}"
    AGENT_CONFIG_SYMLINK_FORCE=1
    NON_INTERACTIVE=1
    print_info "Re-linking skills and agents (symlinks only; packages unchanged)."
    symlink_skills
    symlink_agents
    AGENT_CONFIG_SYMLINK_FORCE="$prev_force"
    NON_INTERACTIVE="$prev_ni"
    print_success "Reinstall complete."
}

agent_config_remove_all() {
    agent_config_require_agent_config_dir
    local skills_root="$AGENT_CONFIG_DIR/skills"
    local agents_root="$AGENT_CONFIG_DIR/agents"
    agent_config_remove_symlinks_under "$CURSOR_SKILLS_DIR" "$skills_root"
    agent_config_remove_symlinks_under "$CURSOR_AGENTS_DIR" "$agents_root"
    rm -rf "$skills_root" "$agents_root"
    print_success "Removed all skill/agent trees under $AGENT_CONFIG_DIR and matching Cursor symlinks."
}

agent_config_require_agent_config_dir() {
    if [ ! -d "$AGENT_CONFIG_DIR" ]; then
        print_error "Missing $AGENT_CONFIG_DIR — run setup-agent-config.sh first."
        exit 1
    fi
}

agent_config_usage() {
    cat <<'EOF'
Usage: agent-config [--yes] <command> [args]

Manage Cursor symlinks for agent-config content under ~/.agent-config.
Symlinks live in ~/.cursor/skills and ~/.cursor/agents. Packages, browsers,
config.json, and .version under ~/.agent-config are not modified by these
commands except where noted.

Commands:
  list-sections              List section names (top-level dirs under skills/ and agents/).
  remove-section <name>      Remove symlinks and ~/.agent-config/skills/<name> and/or
                             agents/<name>. Prompts unless --yes.
  reinstall-all              Recreate all skill and agent symlinks from ~/.agent-config
                             (non-interactive; backs up conflicting paths). Does not run
                             uv sync or Playwright.
  remove-all                 Remove every symlink into ~/.agent-config/skills or agents,
                             then delete those two trees under ~/.agent-config.
                             Prompts unless --yes.

Global options:
  -h, --help                 Print this help and exit.
  --yes                      Non-interactive: skip confirmation for destructive commands.

Examples:
  agent-config list-sections
  agent-config remove-section personal
  agent-config --yes reinstall-all

EOF
}

agent_config_cli_prompt_yes_no() {
    local prompt_text="$1"
    local reply=""
    if [ "${AGENT_CONFIG_CLI_YES:-0}" -eq 1 ]; then
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

agent_config_cli_die_usage() {
    printf "%s\n" "$1" >&2
    agent_config_usage >&2
    exit 2
}

agent_config_cli_main() {
    AGENT_CONFIG_CLI_YES=0
    local args=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --yes)
                AGENT_CONFIG_CLI_YES=1
                shift
                ;;
            -h|--help)
                agent_config_usage
                exit 0
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done
    set -- "${args[@]}"

    if [ $# -eq 0 ]; then
        agent_config_cli_die_usage "Error: missing command."
    fi

    local cmd="$1"
    shift

    case "$cmd" in
        -h|--help)
            agent_config_usage
            exit 0
            ;;
        list-sections)
            if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
                agent_config_usage
                exit 0
            fi
            if [ $# -gt 0 ]; then
                agent_config_cli_die_usage "Error: list-sections takes no arguments."
            fi
            agent_config_list_sections
            ;;
        remove-section)
            if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
                agent_config_usage
                exit 0
            fi
            if [ $# -ne 1 ]; then
                agent_config_cli_die_usage "Error: remove-section requires exactly one <name>."
            fi
            if [ -z "$1" ]; then
                agent_config_cli_die_usage "Error: section name must be non-empty."
            fi
            if [ "$AGENT_CONFIG_CLI_YES" -ne 1 ]; then
                print_info "This will remove section '$1' from ~/.agent-config and unlink matching entries in ~/.cursor/skills and ~/.cursor/agents."
                if ! agent_config_cli_prompt_yes_no "Continue?"; then
                    print_info "Cancelled."
                    exit 0
                fi
            fi
            agent_config_remove_section "$1"
            ;;
        reinstall-all)
            if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
                agent_config_usage
                exit 0
            fi
            if [ $# -gt 0 ]; then
                agent_config_cli_die_usage "Error: reinstall-all takes no arguments."
            fi
            agent_config_reinstall_all
            ;;
        remove-all)
            if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
                agent_config_usage
                exit 0
            fi
            if [ $# -gt 0 ]; then
                agent_config_cli_die_usage "Error: remove-all takes no arguments."
            fi
            if [ "$AGENT_CONFIG_CLI_YES" -ne 1 ]; then
                print_info "This removes all agent-config skill/agent trees and matching Cursor symlinks (not packages or config.json)."
                if ! agent_config_cli_prompt_yes_no "Continue?"; then
                    print_info "Cancelled."
                    exit 0
                fi
            fi
            agent_config_remove_all
            ;;
        *)
            agent_config_cli_die_usage "Error: unknown command '$cmd'."
            ;;
    esac
}
