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

# Commands for the developer, shown in messages. Projects with launchers
# (made by the installer, or --launchers) have ./drush and ./composer;
# others need the project's PHP named. "phpX vendor/bin/drush" works only
# when Drush's own entry is a PHP file: some releases start with a shell
# script, which PHP would just print. Their drush.php is the PHP entry.
get_drush_with_php() {
    local php_version="${1:-$RECORD_PHP_VERSION}"
    local path="${2:-$RECORD_PROJECT_PATH}"
    local entry="$path/vendor/drush/drush/drush"

    if [[ -f "$entry" ]] && head -n 1 "$entry" 2>/dev/null | grep -qv php && [[ -f "$entry.php" ]]; then
        printf 'php%s vendor/drush/drush/drush.php\n' "$php_version"
    else
        printf 'php%s vendor/bin/drush\n' "$php_version"
    fi
}

get_project_drush_hint() {
    local path="${2:-$RECORD_PROJECT_PATH}"

    if [[ -f "$path/drush" && -x "$path/drush" ]]; then
        echo "./drush"
    else
        get_drush_with_php "${1:-$RECORD_PHP_VERSION}" "$path"
    fi
}

get_project_composer_hint() {
    local path="${2:-$RECORD_PROJECT_PATH}"

    if [[ -f "$path/composer" && -x "$path/composer" ]]; then
        echo "./composer"
    else
        printf 'php%s %s\n' "${1:-$RECORD_PHP_VERSION}" "$(get_composer_path || echo composer)"
    fi
}

# The tip for projects without ./drush (adopted projects before
# --launchers): one line, after the commands above.
print_launchers_tip() {
    local path="${2:-$RECORD_PROJECT_PATH}"

    [[ -f "$path/drush" || -d "$path/drush" ]] && return 0
    echo "${3:-}(Shorter: ./install.sh --launchers $1 writes ./drush and ./composer for this project.)"
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
