# Bash programmable completion for agent-config.
# Installed to ~/.local/share/bash-completion/completions/agent-config (lazy load)
# and ~/.local/share/agent-config/completions/agent-config.bash (explicit source).

_agent_config_list_sections_words() {
    {
        [ -d "${HOME}/.agent-config/skills" ] && command ls -1 "${HOME}/.agent-config/skills" 2>/dev/null
        [ -d "${HOME}/.agent-config/agents" ] && command ls -1 "${HOME}/.agent-config/agents" 2>/dev/null
    } | command sort -u | command tr '\n' ' '
}

_agent_config_completion() {
    COMPREPLY=()
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local cmd_idx=-1 i

    for ((i = 1; i < COMP_CWORD; i++)); do
        case "${COMP_WORDS[i]}" in
            --yes | -h | --help) ;;
            list-sections | remove-section | reinstall-all | remove-all)
                cmd_idx=$i
                break
                ;;
        esac
    done

    if [ "$cmd_idx" -lt 0 ]; then
        COMPREPLY=($(compgen -W "--yes -h --help list-sections remove-section reinstall-all remove-all" -- "$cur"))
        return
    fi

    local cmd="${COMP_WORDS[cmd_idx]}"
    case "$cmd" in
        remove-section)
            if [ "$COMP_CWORD" -eq $((cmd_idx + 1)) ]; then
                local sections
                sections="$(_agent_config_list_sections_words)"
                COMPREPLY=($(compgen -W "$sections" -- "$cur"))
            fi
            ;;
        list-sections | reinstall-all | remove-all) ;;
    esac
}

complete -F _agent_config_completion agent-config
