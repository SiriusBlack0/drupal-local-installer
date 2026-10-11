#!/usr/bin/env bash

verify_composer_ready() {
    if is_composer_installed; then
        echo "[READY] Composer"
        return 0
    fi

    echo "[NOT READY] Composer is missing."
    return 1
}

verify_nginx_ready() {
    if ! is_nginx_installed; then
        echo "[NOT READY] Nginx is not installed."
        return 1
    fi

    if ! is_nginx_running; then
        echo "[NOT READY] Nginx service is not running."
        return 1
    fi

    echo "[READY] Nginx"
    return 0
}

verify_php_cli_ready() {
    local php_version="$1"

    if ! is_php_cli_installed "$php_version"; then
        echo "[NOT READY] PHP $php_version CLI is not installed."
        return 1
    fi

    echo "[READY] PHP $php_version CLI"
    return 0
}

verify_php_fpm_ready() {
    local php_version="$1"

    if ! is_php_fpm_installed "$php_version"; then
        echo "[NOT READY] PHP $php_version FPM is not installed."
        return 1
    fi

    if ! is_php_fpm_running "$php_version"; then
        echo "[NOT READY] PHP $php_version FPM service is not running."
        return 1
    fi

    echo "[READY] PHP $php_version FPM"
    return 0
}

verify_php_extensions_ready() {
    local php_version="$1"
    shift

    if ! check_php_extensions "$php_version" "$@"; then
        echo "[NOT READY] Required PHP extensions are missing."
        return 1
    fi

    echo "[READY] PHP $php_version extensions"
    return 0
}

verify_database_ready() {
    local database_engine="$1"

    if [ "$database_engine" = "sqlite" ]; then
        echo "[READY] SQLite - no database service required."
        return 0
    fi

    if ! is_database_service_running "$database_engine"; then
        echo "[NOT READY] $database_engine service is not running."
        return 1
    fi

    echo "[READY] $database_engine service"
    return 0
}

verify_environment_ready() {
    local failed=0

    echo
    echo "Verifying environment readiness..."

    # shellcheck disable=SC2153
    verify_composer_ready || failed=1
    # shellcheck disable=SC2153
    verify_nginx_ready || failed=1
    # shellcheck disable=SC2153
    verify_php_cli_ready "$PHP_VERSION" || failed=1
    # shellcheck disable=SC2153
    verify_php_fpm_ready "$PHP_VERSION" || failed=1

    # shellcheck disable=SC2153
    verify_php_extensions_ready \
        "$PHP_VERSION" \
        "${REQUIRED_PHP_EXTENSIONS[@]}" || failed=1

    # shellcheck disable=SC2153
    verify_database_ready "$DATABASE_ENGINE" || failed=1

    if [ "$failed" -ne 0 ]; then
        echo "[ERROR] Environment is not ready."
        return 1
    fi

    echo "[SUCCESS] Environment is ready."
    return 0
}