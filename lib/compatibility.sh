#!/usr/bin/env bash

# --------------------------------------------------
# Compatibility matrix (config/compatibility.conf)
# --------------------------------------------------

# Resolved once, when the module is loaded, so later "cd" calls do not
# break the path. DRUPAL_COMPATIBILITY_FILE can override it (tests).
COMPATIBILITY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

get_compatibility_file() {
    printf '%s\n' "${DRUPAL_COMPATIBILITY_FILE:-$COMPATIBILITY_LIB_DIR/../config/compatibility.conf}"
}

# Prints the matrix rows without comments or blank lines.
get_compatibility_rows() {
    local file

    file="$(get_compatibility_file)"

    if [[ ! -r "$file" ]]; then
        echo "[ERROR] Compatibility file not found: $file" >&2
        return 1
    fi

    grep -Ev '^[[:space:]]*(#|$)' "$file"
}

get_compatibility_row() {
    local drupal_minor="$1"

    [[ "$drupal_minor" =~ ^[0-9]+\.[0-9]+$ ]] || return 1

    get_compatibility_rows | awk -F'|' -v minor="$drupal_minor" '
        $1 == minor { print; found = 1; exit }
        END { exit !found }
    '
}

get_supported_drupal_minors() {
    get_compatibility_rows | cut -d'|' -f1
}

get_supported_php_versions() {
    local drupal_minor="$1"
    local row

    row="$(get_compatibility_row "$drupal_minor")" || return 1

    printf '%s\n' "$row" | cut -d'|' -f2 | tr ',' '\n'
}

# True when version $1 is greater than or equal to version $2.
# Uses sort -V, so it works before PHP is installed.
version_at_least() {
    local version="$1"
    local minimum="$2"

    [[ -n "$version" && -n "$minimum" ]] || return 1

    [[ "$(printf '%s\n%s\n' "$minimum" "$version" | sort -V | head -n 1)" == "$minimum" ]]
}

get_supported_system_php_versions() {
    local drupal_minor="$1"
    local system_version
    local supported_version

    while read -r system_version; do

        while read -r supported_version; do

            if [ "$system_version" = "$supported_version" ]; then
                echo "$system_version"                
                break
            fi

        done < <(get_supported_php_versions "$drupal_minor")

    done < <(get_php_candidate_versions)
}

has_php_support_policy() {
    local drupal_minor="$1"

    get_supported_php_versions "$drupal_minor" >/dev/null 2>&1
}

# Database minimums are defined per Drupal major version.
get_database_minimum_version() {
    local drupal_major="$1"
    local database_engine="$2"
    local field
    local row

    case "$database_engine" in
        mariadb) field=3 ;;
        mysql) field=4 ;;
        postgresql) field=5 ;;
        sqlite) field=6 ;;
        *) return 1 ;;
    esac

    [[ "$drupal_major" =~ ^[0-9]+$ ]] || return 1

    row="$(get_compatibility_rows | grep -m 1 "^${drupal_major}\.")" || return 1

    printf '%s\n' "$row" | cut -d'|' -f"$field"
}

database_version_meets_minimum() {
    local installed_version="$1"
    local minimum_version="$2"

    version_at_least "$installed_version" "$minimum_version"
}

is_installed_database_compatible() {
    local drupal_major="$1"
    local database_engine="$2"

    local installed_version
    local minimum_version

    installed_version="$(
        get_installed_database_version "$database_engine"
    )" || return 1

    minimum_version="$(
        get_database_minimum_version "$drupal_major" "$database_engine"
    )" || return 1

    database_version_meets_minimum \
        "$installed_version" \
        "$minimum_version"
}

is_database_version_compatible() {
    local drupal_major="$1"
    local database_engine="$2"
    local database_version="$3"

    local minimum_version

    minimum_version="$(
        get_database_minimum_version "$drupal_major" "$database_engine"
    )" || return 1

    database_version_meets_minimum \
        "$database_version" \
        "$minimum_version"
}

get_compatible_database_options() {
    local drupal_major="$1"
    local engine
    local version
    local status

    while read -r engine; do

        version="$(get_available_database_version "$engine")"

        if [ -z "$version" ] || [ "$version" = "(none)" ]; then
            continue
        fi

        if ! is_database_version_compatible \
            "$drupal_major" \
            "$engine" \
            "$version"; then
            continue
        fi

        if is_database_engine_installed "$engine"; then
            status="installed"
        elif get_installed_conflicting_engine "$engine" > /dev/null; then
            status="conflict"
        else
            status="available"
        fi

        echo "$engine|$version|$status"

    done < <(get_database_engines)
}