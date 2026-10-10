#!/usr/bin/env bash

get_supported_php_versions() {
    local drupal_minor="$1"

    case "$drupal_minor" in
        11.1|11.2)
            printf '%s\n' "8.3" "8.4"
            ;;

        11.3|11.4)
            printf '%s\n' "8.3" "8.4" "8.5"
            ;;

        10.4|10.5|10.6)
            printf '%s\n' "8.1" "8.2" "8.3" "8.4"
            ;;

        *)
            return 1
            ;;
    esac
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

get_database_minimum_version() {
    local drupal_major="$1"
    local database_engine="$2"

    case "$drupal_major:$database_engine" in

        10:mariadb)
            echo "10.3.7"
            ;;

        10:mysql)
            echo "5.7.8"
            ;;

        10:postgresql)
            echo "12"
            ;;

        10:sqlite)
            echo "3.26"
            ;;

        11:mariadb)
            echo "10.6"
            ;;

        11:mysql)
            echo "8.0"
            ;;

        11:postgresql)
            echo "16"
            ;;

        11:sqlite)
            echo "3.45"
            ;;

        *)
            return 1
            ;;
    esac
}

database_version_meets_minimum() {
    local installed_version="$1"
    local minimum_version="$2"

    php -r "
        exit(
            version_compare('$installed_version', '$minimum_version', '>=')
            ? 0
            : 1
        );
    "
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
        else
            status="available"
        fi

        echo "$engine|$version|$status"

    done < <(get_database_engines)
}