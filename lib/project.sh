#!/usr/bin/env bash

check_project_directory() {
    local project_path="$1"

    if [ -e "$project_path" ] || [ -L "$project_path" ]; then
        echo "[ERROR] Project path already exists: $project_path"
        return 1
    fi

    echo "[OK] Project path is available: $project_path"
    return 0
}

build_composer_project_command() {
    local drupal_version="$1"
    local project_path="$2"

    printf 'composer create-project drupal/recommended-project:%s %s\n' \
        "$drupal_version" \
        "$project_path"
}

create_drupal_project() {
    local drupal_version="$1"
    local project_path="$2"

    if ! check_project_directory "$project_path"; then
        return 1
    fi

    composer create-project \
        "drupal/recommended-project:$drupal_version" \
        "$project_path"
}

provision_drupal_project() {
    local drupal_version="$1"
    local project_path="$2"

    if ! create_drupal_project "$drupal_version" "$project_path"; then
        echo "[ERROR] Drupal project creation failed."
        return 1
    fi

    echo "[SUCCESS] Drupal project files created."
    return 0
}