#!/usr/bin/env bash

# ==================================================
# Project directory and Drupal code (Composer)
#
# Layout of a new project:
#   /var/www/<name>          owner: developer, group: www-data, mode 2750
#                            (setgid: new files keep the www-data group,
#                             so Nginx can read them; others have no access)
# Composer runs as the developer, with the PHP version chosen for the
# project, so dependencies are resolved for that PHP and never for the
# system default.
# ==================================================

check_project_directory() {
    local project_path="$1"

    if [ -e "$project_path" ] || [ -L "$project_path" ]; then
        echo "[ERROR] Project path already exists: $project_path"
        return 1
    fi

    echo "[OK] Project path is available: $project_path"
    return 0
}

# Accept only paths that get_project_path would produce:
# <projects base dir>/<valid machine name>. Protects mkdir and rm -rf.
is_managed_project_path() {
    local project_path="$1"
    local machine_name
    local expected_path

    machine_name="$(basename -- "$project_path")"
    expected_path="$(get_project_path "$machine_name" 2>/dev/null)" || return 1

    [[ "$project_path" == "$expected_path" ]]
}

# Runs a command as the developer who owns the project.
run_as_project_user() {
    local run_user="$1"
    shift

    if [[ "$(id -un)" == "$run_user" ]]; then
        "$@"
    else
        sudo -u "$run_user" -- "$@"
    fi
}

create_project_directory() {
    local project_path="$1"
    local run_user="$2"

    if ! is_managed_project_path "$project_path"; then
        echo "[ERROR] Refusing to create an unmanaged path: $project_path"
        return 1
    fi

    if [[ ! "$run_user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        echo "[ERROR] Invalid project owner: $run_user"
        return 1
    fi

    if ! check_project_directory "$project_path"; then
        return 1
    fi

    if ! sudo install -d -o "$run_user" -g www-data -m 2750 "$project_path"; then
        echo "[ERROR] Could not create project directory: $project_path"
        return 1
    fi

    echo "[OK] Project directory created: $project_path (owner $run_user, group www-data)"
}

# Only used for rollback of a directory this installer just created.
remove_project_directory() {
    local project_path="$1"

    if ! is_managed_project_path "$project_path"; then
        echo "[ERROR] Refusing to remove an unmanaged path: $project_path"
        return 1
    fi

    sudo rm -rf -- "$project_path"
}

create_drupal_project() {
    local drupal_version="$1"
    local project_path="$2"
    local php_version="$3"
    local run_user="$4"
    local composer_path

    if [[ ! "$drupal_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "[ERROR] Invalid Drupal version: $drupal_version"
        return 1
    fi

    if [[ ! "$php_version" =~ ^[0-9]+\.[0-9]+$ ]]; then
        echo "[ERROR] Invalid PHP version: $php_version"
        return 1
    fi

    if ! composer_path="$(command -v composer)"; then
        echo "[ERROR] Composer is not installed."
        return 1
    fi

    if ! command -v "php${php_version}" >/dev/null 2>&1; then
        echo "[ERROR] PHP ${php_version} CLI is not installed."
        return 1
    fi

    echo "Creating Drupal $drupal_version with PHP $php_version..."

    run_as_project_user "$run_user" \
        "php${php_version}" "$composer_path" create-project \
        --no-interaction \
        "drupal/recommended-project:$drupal_version" \
        "$project_path"
}

provision_drupal_project() {
    local drupal_version="$1"
    local project_path="$2"
    local php_version="$3"
    local run_user="$4"

    if ! create_project_directory "$project_path" "$run_user"; then
        echo "[ERROR] Drupal project creation failed."
        return 1
    fi

    if ! create_drupal_project \
        "$drupal_version" "$project_path" "$php_version" "$run_user"; then
        echo "[ERROR] Drupal project creation failed."
        echo "Rolling back: removing $project_path..."

        if remove_project_directory "$project_path"; then
            echo "[OK] Rollback completed."
        else
            echo "[WARNING] Rollback failed. Remove the directory manually:"
            echo "  sudo rm -rf -- '$project_path'"
        fi

        return 1
    fi

    echo "[SUCCESS] Drupal project files created."
    return 0
}
