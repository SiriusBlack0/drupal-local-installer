#!/usr/bin/env bash

# Composer and Drush of a project, run as the project user with its PHP
# (used by --update, --php and --remove).

get_composer_path() {
    command -v composer
}

# Runs Composer for the project with the project's PHP, as the developer.
run_project_composer() {
    local project_path="$1"
    local php_version="$2"
    shift 2

    run_as_project_user "$PROJECT_USER" "php${php_version}" "$(get_composer_path)" \
        --working-dir="$project_path" --no-interaction "$@"
}

# Runs the project's Drush: the ./drush launcher of projects made by the
# installer, or vendor/bin/drush with the project's PHP first in PATH.
run_project_drush() {
    local project_path="$1"
    local php_version="$2"
    shift 2
    local shim
    local status=0

    if [[ -x "$project_path/drush" && ! -d "$project_path/drush" ]]; then
        run_as_project_user "$PROJECT_USER" "$project_path/drush" "$@"
        return
    fi

    [[ -x "$project_path/vendor/bin/drush" ]] || return 127

    # Drush starts "php" from PATH: put the project's PHP first.
    shim="$(mktemp -d)"
    chmod 755 "$shim"
    ln -s "$(command -v "php${php_version}")" "$shim/php"
    (cd "$project_path" && run_as_project_user "$PROJECT_USER" \
        env PATH="$shim:$PATH" "$project_path/vendor/bin/drush" "$@") || status=$?
    rm -rf "$shim"
    return "$status"
}
