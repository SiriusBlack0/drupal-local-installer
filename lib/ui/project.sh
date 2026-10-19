#!/usr/bin/env bash

# Phase 1 (configuration): the project name.

# ==================================================

# PHASE 1 — CONFIGURATION

# ==================================================


# --------------------------------------------------
# Project name
# --------------------------------------------------

prompt_project_name() {
    local conflict

    PROJECT_NAME_PATTERN='^[a-zA-Z0-9][a-zA-Z0-9 _-]*$'

    while true; do

        if ! read -r -p "Project name: " PROJECT_NAME; then
            echo "Input cancelled."
            exit 0
        fi

        if [ -z "$PROJECT_NAME" ]; then
            echo "Project name cannot be empty."
            continue
        fi

        if ! [[ "$PROJECT_NAME" =~ $PROJECT_NAME_PATTERN ]]; then
            echo "Invalid project name."
            echo "Use Latin letters, numbers, spaces, underscores or hyphens."
            echo "The name must start with a letter or number."
            continue
        fi

        PROJECT_MACHINE_NAME="$(get_project_machine_name "$PROJECT_NAME")"

        # shellcheck disable=SC2034  # Used by lib/preflight.sh and lib/workflow.sh
        if ! PROJECT_PATH="$(get_project_path "$PROJECT_MACHINE_NAME")"; then
            echo "Installation stopped."
            exit 1
        fi

        # Catch existing projects now, not after all other questions.
        # Preflight checks again later, in case something changed.
        if conflict="$(get_project_conflict "$PROJECT_MACHINE_NAME" "$PROJECT_PATH")"; then
            echo "$conflict"
            echo "Choose another project name."
            continue
        fi

        break

    done
}
