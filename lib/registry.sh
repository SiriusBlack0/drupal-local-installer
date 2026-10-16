#!/usr/bin/env bash

# --------------------------------------------------
# Project Registry
# --------------------------------------------------

get_registry_directory() {
    printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/drupal-local-installer/projects"
}

# --------------------------------------------------
# Check whether a project is registered
# --------------------------------------------------

is_project_registered() {
    local machine_name="$1"
    local registry_directory

    [[ "$machine_name" =~ ^[a-z0-9_]+$ ]] || return 2

    registry_directory="$(get_registry_directory)"

    [ -f "$registry_directory/${machine_name}.conf" ]
}

# --------------------------------------------------
# Project location
# --------------------------------------------------

# Base directory for all projects. Defaults to /var/www and can be
# overridden with DRUPAL_PROJECTS_DIR (absolute path).
get_projects_base_dir() {
    local base_dir="${DRUPAL_PROJECTS_DIR:-/var/www}"

    if [[ "$base_dir" != /* ]]; then
        echo "[ERROR] DRUPAL_PROJECTS_DIR must be an absolute path: $base_dir" >&2
        return 1
    fi

    printf '%s\n' "${base_dir%/}"
}

get_project_path() {
    local machine_name="$1"
    local base_dir

    if [[ ! "$machine_name" =~ ^[a-z0-9_]+$ ]]; then
        echo "[ERROR] Invalid project machine name: $machine_name" >&2
        return 1
    fi

    base_dir="$(get_projects_base_dir)" || return 1

    printf '%s/%s\n' "$base_dir" "$machine_name"
}

# --------------------------------------------------
# Check whether a project directory already exists
# --------------------------------------------------

is_project_directory_taken() {
    local project_path="$1"

    [ -e "$project_path" ] || [ -L "$project_path" ]
}

# --------------------------------------------------
# Check whether an Nginx configuration already exists
# --------------------------------------------------

is_nginx_config_taken() {
    local machine_name="$1"

    [[ "$machine_name" =~ ^[a-z0-9_]+$ ]] || return 2

    [ -e "/etc/nginx/sites-available/${machine_name}.conf" ] ||
    [ -L "/etc/nginx/sites-available/${machine_name}.conf" ] ||
    [ -e "/etc/nginx/sites-enabled/${machine_name}.conf" ] ||
    [ -L "/etc/nginx/sites-enabled/${machine_name}.conf" ]
}