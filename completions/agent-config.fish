# Fish completion for agent-config (~/.config/fish/completions/agent-config.fish).

function __agent_config_sections
    for d in $HOME/.agent-config/skills $HOME/.agent-config/agents
        test -d $d
        or continue
        command ls -1 $d
    end | sort -u
end

complete -c agent-config -f

complete -c agent-config -s h -l help -d 'Show help'

complete -c agent-config -l yes -d 'Skip confirmations (non-interactive)'

complete -c agent-config -n '__fish_use_subcommand' -a 'list-sections' -d 'List section names'
complete -c agent-config -n '__fish_use_subcommand' -a 'remove-section' -d 'Remove a section'
complete -c agent-config -n '__fish_use_subcommand' -a 'reinstall-all' -d 'Recreate all symlinks'
complete -c agent-config -n '__fish_use_subcommand' -a 'remove-all' -d 'Remove all sections'

complete -c agent-config -n '__fish_seen_subcommand_from remove-section' -a '(__agent_config_sections)'
