#!/usr/bin/env bash

# Phase 1: a git repository for the new project.

# --------------------------------------------------
# Git repository
# --------------------------------------------------

# "yes" or "no". Used by lib/preflight.sh and lib/git.sh.
GIT_SETUP="yes"

# GIT_SETUP is read by other modules.
# shellcheck disable=SC2034
prompt_git_setup() {
    local choice

    while true; do
        echo
        echo "Git repository for the project:"
        echo "  git init in the project folder and a first commit with the project's"
        echo "  own files: composer.json, composer.lock, settings.php, config/ and"
        echo "  custom code. Downloaded code (vendor/, core, contrib) and uploaded"
        echo "  files stay out (.gitignore). The database password and the hash salt"
        echo "  are kept in settings.local.php, which is never committed."
        echo

        if ! read -r -p "Create a git repository with an initial commit? [Y/n]: " choice; then
            echo
            echo "Input cancelled."
            exit 0
        fi

        case "$choice" in
            y|Y|"")
                GIT_SETUP="yes"
                return 0
                ;;
            n|N)
                GIT_SETUP="no"
                return 0
                ;;
            *)
                echo "Please enter y or n."
                ;;
        esac
    done
}
