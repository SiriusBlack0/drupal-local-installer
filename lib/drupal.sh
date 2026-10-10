#!/usr/bin/env bash

get_drupal_versions() {
    local major="$1"

    composer show drupal/recommended-project --all 2>/dev/null \
        | grep "^versions" \
        | cut -d ':' -f 2- \
        | tr ',' '\n' \
        | sed 's/^[[:space:]]*//' \
        | grep -E "^${major}\.[0-9]+\.[0-9]+$"
}

get_drupal_minor_versions() {
    local major="$1"

    get_drupal_versions "$major" \
        | cut -d '.' -f 1,2 \
        | awk '!seen[$0]++'
}

drupal_version_exists() {
    local version="$1"
    local major

    major="${version%%.*}"

    get_drupal_versions "$major" | grep -Fxq "$version"
}

get_drupal_php_constraint() {
    local version="$1"

    composer show drupal/core "$version" --all 2>/dev/null \
        | awk '$1 == "php" {print $2; exit}'
}

get_drupal_minor() {
    local version="$1"

    echo "$version" | cut -d'.' -f1,2
}