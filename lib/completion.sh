#!/usr/bin/env bash

# ==================================================
# Tab completion (--install-completion)
#
# Installs completion/drupal-local-installer.bash for the current user
# only (no sudo): bash-completion loads it from the user's completions
# folder the first time ./install.sh is completed in a new terminal.
# ==================================================

get_completion_target() {
    printf '%s/completions/install.sh\n' \
        "${BASH_COMPLETION_USER_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion}"
}

# Where bash-completion itself is (it loads the user's completions).
get_bash_completion_script() {
    printf '%s\n' "${BASH_COMPLETION_SCRIPT:-/usr/share/bash-completion/bash_completion}"
}

run_install_completion() {
    local source_file="$SCRIPT_DIR/completion/drupal-local-installer.bash"
    local target
    local content

    if [[ "$(id -u)" -eq 0 ]]; then
        echo "[ERROR] Run --install-completion as your normal user (without sudo):"
        echo "        Tab completion is set up for that user only."
        return 1
    fi

    if [[ ! -f "$source_file" ]]; then
        echo "[ERROR] Completion file not found: $source_file"
        return 1
    fi

    target="$(get_completion_target)"
    content="$(< "$source_file")"
    # Quoted replacement: "&" in the folder name stays literal.
    content="${content//__DLI_DIR__/"$SCRIPT_DIR"}"

    if ! mkdir -p "$(dirname "$target")" ||
       ! printf '%s\n' "$content" > "$target"; then
        echo "[ERROR] Could not write $target"
        return 1
    fi

    chmod 644 "$target"
    echo "[OK] Tab completion installed: $target"
    echo

    if [[ -f "$(get_bash_completion_script)" ]]; then
        echo "It works in every new terminal. In this one, load it once with:"
        echo "  source $target"
    else
        echo "bash-completion is not installed, so it is not loaded automatically."
        echo "Either install it (sudo apt-get install bash-completion) or add this"
        echo "line to ~/.bashrc:"
        echo "  source $target"
    fi

    echo
    echo "Try it: ./install.sh --<Tab><Tab>, ./install.sh --update <Tab>,"
    echo "        ./install.sh --php <project> <Tab>"
    echo "Remove it: rm $target"
}
