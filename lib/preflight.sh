#!/usr/bin/env bash

# ==================================================
# PHASE 2 — PREFLIGHT
#
# Sourcing this file only defines functions.
# Nothing runs until install.sh calls run_preflight.
# Preflight only checks and plans; it changes nothing.
# ==================================================

# --------------------------------------------------
# Existing project, directory or Nginx configuration
# --------------------------------------------------

check_project_conflicts() {
    echo
    echo "Checking project registry..."

    if is_project_registered "$PROJECT_MACHINE_NAME"; then
        echo "ERROR: Project '$PROJECT_MACHINE_NAME' is already registered."
        return 1
    fi

    echo "Project '$PROJECT_MACHINE_NAME' is not registered."

    echo
    echo "Checking project directory..."

    if is_project_directory_taken "$PROJECT_PATH"; then
        echo "ERROR: Project directory '$PROJECT_PATH' already exists."
        return 1
    fi

    echo "Project directory '$PROJECT_PATH' is available."

    echo
    echo "Checking Nginx configuration..."

    if is_nginx_config_taken "$PROJECT_MACHINE_NAME"; then
        echo "ERROR: Nginx configuration for '$PROJECT_MACHINE_NAME' already exists."
        return 1
    fi

    echo "Nginx configuration for '$PROJECT_MACHINE_NAME' is available."
}

# --------------------------------------------------
# Composer, Nginx, PHP-FPM and PHP CLI
# --------------------------------------------------

plan_required_packages() {
    echo
    echo "Checking Composer..."

    if is_composer_installed; then
        echo "[OK] Composer is installed."
    else
        echo "[MISSING] Composer"
        add_install_package "composer"
    fi

    # curl checks that the site answers over HTTP (installation, --update,
    # --php, ./start). Without it only Drush could be checked.
    echo
    echo "Checking curl..."

    if command -v curl > /dev/null 2>&1; then
        echo "[OK] curl is installed."
    else
        echo "[MISSING] curl"
        add_install_package "curl"
    fi

    # git only when the project gets a repository (phase 1 question).
    if [[ "${GIT_SETUP:-no}" == "yes" ]]; then
        echo
        echo "Checking git..."

        if command -v git > /dev/null 2>&1; then
            echo "[OK] git is installed."
        else
            echo "[MISSING] git"
            add_install_package "git"
        fi
    fi

    echo
    echo "Checking Nginx..."

    if is_nginx_installed; then
        echo "[OK] Nginx is installed."
    else
        echo "[MISSING] Nginx"
        add_install_package "nginx"
    fi

    echo
    echo "Checking PHP-FPM..."

    if is_php_fpm_installed "$PHP_VERSION"; then
        echo "[OK] PHP $PHP_VERSION FPM is installed."
    else
        echo "[MISSING] PHP $PHP_VERSION FPM"
        add_install_package "php${PHP_VERSION}-fpm"
        add_service_after_install "php${PHP_VERSION}-fpm"
    fi

    echo
    echo "Checking PHP CLI..."

    if is_php_cli_installed "$PHP_VERSION"; then
        echo "[OK] PHP $PHP_VERSION CLI is installed."
    else
        echo "[MISSING] PHP $PHP_VERSION CLI"
        add_install_package "php${PHP_VERSION}-cli"
    fi
}

# --------------------------------------------------
# PHP extensions
# --------------------------------------------------

# REQUIRED_PHP_EXTENSIONS is also used by lib/readiness.sh.
plan_php_extensions() {
    local extension
    local package

    echo
    echo "Checking PHP extensions..."

    REQUIRED_PHP_EXTENSIONS=(
        ctype
        curl
        dom
        fileinfo
        filter
        gd
        hash
        iconv
        json
        mbstring
        openssl
        pdo
        session
        simplexml
        tokenizer
        xml
    )

    # Database-specific extension.
    case "$DATABASE_ENGINE" in
        mariadb|mysql)
            REQUIRED_PHP_EXTENSIONS+=(pdo_mysql)
            ;;
        postgresql)
            REQUIRED_PHP_EXTENSIONS+=(pdo_pgsql)
            ;;
        sqlite)
            REQUIRED_PHP_EXTENSIONS+=(pdo_sqlite)
            ;;
    esac

    if ! is_php_cli_installed "$PHP_VERSION"; then
        echo "[PENDING] PHP extensions cannot be checked yet."
        echo "PHP $PHP_VERSION CLI must be installed first."

        echo "Planning required PHP extension packages..."

        for extension in "${REQUIRED_PHP_EXTENSIONS[@]}"; do
            if package="$(get_php_extension_package "$PHP_VERSION" "$extension")"; then
                add_install_package "$package"
            fi
        done
    elif check_php_extensions "$PHP_VERSION" "${REQUIRED_PHP_EXTENSIONS[@]}"; then
        echo "[OK] PHP $PHP_VERSION extensions (${#REQUIRED_PHP_EXTENSIONS[@]} checked)"
    else
        echo "[MISSING] Some required PHP extensions."
        echo "Planning PHP extension packages..."

        plan_php_extension_packages \
            "$PHP_VERSION" \
            "${REQUIRED_PHP_EXTENSIONS[@]}" || true
    fi
}

# --------------------------------------------------
# Services
# --------------------------------------------------

plan_service_startup() {
    echo
    echo "Checking services..."

    if ! is_nginx_installed; then
        echo "[MISSING] Nginx - installation required"
    elif is_nginx_running; then
        echo "[RUNNING] Nginx"
    else
        echo "[STOPPED] Nginx - start required"
        add_service_to_start "nginx"
    fi

    if ! is_php_fpm_installed "$PHP_VERSION"; then
        echo "[MISSING] PHP $PHP_VERSION FPM - installation required"
    elif is_php_fpm_running "$PHP_VERSION"; then
        echo "[RUNNING] PHP $PHP_VERSION FPM"
    else
        echo "[STOPPED] PHP $PHP_VERSION FPM - start required"
        add_service_to_start "php${PHP_VERSION}-fpm"
    fi

    plan_database_service
}

plan_database_service() {
    if [ "$DATABASE_ENGINE" = "sqlite" ]; then
        return 0
    fi

    if [ "$DATABASE_NEEDS_INSTALL" = "yes" ]; then
        local package

        if ! package="$(get_database_server_package "$DATABASE_ENGINE")"; then
            echo "[ERROR] No server package known for $DATABASE_ENGINE"
            return 1
        fi

        echo "[MISSING] $DATABASE_ENGINE - installation required ($package)"
        add_install_package "$package"
        add_service_after_install "$(get_database_service_name "$DATABASE_ENGINE")"
    elif is_database_service_running "$DATABASE_ENGINE"; then
        echo "[RUNNING] $DATABASE_ENGINE"
    else
        echo "[STOPPED] $DATABASE_ENGINE - start required"
        add_service_to_start "$DATABASE_ENGINE"
    fi
}

# ==================================================
# Phase 2 entry point
# ==================================================

run_preflight() {
    if ! check_project_conflicts; then
        return 1
    fi

    plan_required_packages
    plan_php_extensions
    plan_service_startup
}
