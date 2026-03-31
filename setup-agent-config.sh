#!/bin/bash

# Paths to agent config and cursor directories relative to the home of the user
AGENT_CONFIG_DIR="$HOME/.agent-config"
CURSOR_SKILLS_DIR="$HOME/.cursor/skills"
CURSOR_AGENTS_DIR="$HOME/.cursor/agents"

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

print_blank() {
    printf "\n"
}

print_section() {
    print_blank
    printf "${COLOR_GREEN}--------------------------------${COLOR_RESET}\n"
    print_blank
}

# symlink helper functions

symlink_skills() {
    for skill in "$AGENT_CONFIG_DIR/skills"/*; do
        print_info "Skill directory: $skill"
    done
}

symlink_agents() {
    print_info "todo: symlink agents"
}


# entry point
main() {
    if [ -d "$AGENT_CONFIG_DIR" ]; then
        print_info "Agent config directory already exists at $AGENT_CONFIG_DIR"
    else
        mkdir -p "$AGENT_CONFIG_DIR"
        print_info "Agent config directory created at $AGENT_CONFIG_DIR"
    fi

    print_section

    print_info "Setting up agent skills from $AGENT_CONFIG_DIR/skills to $CURSOR_SKILLS_DIR"
    symlink_skills

    print_section

    print_info "Setting up agent agents from $AGENT_CONFIG_DIR/agents to $CURSOR_AGENTS_DIR"
    symlink_agents
}

# run the script
main


