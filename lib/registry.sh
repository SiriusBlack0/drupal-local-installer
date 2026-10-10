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