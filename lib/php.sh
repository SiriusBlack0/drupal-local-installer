#!/usr/bin/env bash

get_installed_php_versions() {
    dpkg-query -W -f='${binary:Package} ${db:Status-Abbrev}\n' 'php*-fpm' 2>/dev/null \
        | awk '$2 == "ii" {print $1}' \
        | sed -nE 's/^php([0-9]+\.[0-9]+)-fpm(:.*)?$/\1/p' \
        | sort -Vu
}

get_available_php_versions() {
    apt-cache search '^php[0-9]+\.[0-9]+-fpm$' \
        | sed -E 's/^php([0-9]+\.[0-9]+)-fpm.*/\1/' \
        | sort -Vu
}

get_php_candidate_versions() {
    {
        get_installed_php_versions
        get_available_php_versions
    } | sort -Vu
}

php_version_meets_minimum() {
    local php_version="$1"
    local constraint="$2"

    local minimum_version="${constraint#>=}"

    php -r "
        exit(
            version_compare('$php_version', '$minimum_version', '>=')
            ? 0
            : 1
        );
    "
}

get_compatible_php_versions() {
    local constraint="$1"
    local version

    while read -r version; do
        if php_version_meets_minimum "$version" "$constraint"; then
            echo "$version"
        fi
    done < <(get_php_candidate_versions)
}

get_php_version_status() {
    local version="$1"

    if get_installed_php_versions | grep -Fxq "$version"; then
        echo "installed"
        return 0
    fi

    if get_available_php_versions | grep -Fxq "$version"; then
        echo "available"
        return 0
    fi

    echo "not_available"
}