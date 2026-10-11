#!/usr/bin/env bash

# --------------------------------------------------
# Check project registry
# --------------------------------------------------

echo
echo "Checking project registry..."

if is_project_registered "$PROJECT_MACHINE_NAME"; then
    echo "ERROR: Project '$PROJECT_MACHINE_NAME' is already registered."
    echo "Installation stopped."
    exit 1
fi

echo "Project '$PROJECT_MACHINE_NAME' is not registered."

# --------------------------------------------------
# Check project directory
# --------------------------------------------------

PROJECT_PATH="/var/www/$PROJECT_MACHINE_NAME"

echo
echo "Checking project directory..."

if is_project_directory_taken "$PROJECT_PATH"; then
    echo "ERROR: Project directory '$PROJECT_PATH' already exists."
    echo "Installation stopped."
    exit 1
fi

echo "Project directory '$PROJECT_PATH' is available."

# --------------------------------------------------
# Check Nginx configuration
# --------------------------------------------------

echo
echo "Checking Nginx configuration..."

if is_nginx_config_taken "$PROJECT_MACHINE_NAME"; then
    echo "ERROR: Nginx configuration for '$PROJECT_MACHINE_NAME' already exists."
    echo "Installation stopped."
    exit 1
fi

echo "Nginx configuration for '$PROJECT_MACHINE_NAME' is available."

# --------------------------------------------------
# Check Composer
# --------------------------------------------------

echo
echo "Checking Composer..."

if is_composer_installed; then
    echo "[OK] Composer is installed."
else
    echo "[MISSING] Composer"
    add_install_package "composer"
fi
# --------------------------------------------------
# Check Nginx
# --------------------------------------------------

echo
echo "Checking Nginx..."

if is_nginx_installed; then
    echo "[OK] Nginx is installed."
else
    echo "[MISSING] Nginx"
    add_install_package "nginx"
fi

# --------------------------------------------------
# Check selected PHP-FPM
# --------------------------------------------------

echo
echo "Checking PHP-FPM..."

if is_php_fpm_installed "$PHP_VERSION"; then
    echo "[OK] PHP $PHP_VERSION FPM is installed."
else
    echo "[MISSING] PHP $PHP_VERSION FPM"
    add_install_package "php${PHP_VERSION}-fpm"
    add_service_after_install "php${PHP_VERSION}-fpm"
fi

# --------------------------------------------------
# Check selected PHP CLI
# --------------------------------------------------

echo
echo "Checking PHP CLI..."
if is_php_cli_installed "$PHP_VERSION"; then
    echo "[OK] PHP $PHP_VERSION CLI is installed."
else
    echo "[MISSING] PHP $PHP_VERSION CLI"
    add_install_package "php${PHP_VERSION}-cli"
fi

# --------------------------------------------------
# Check PHP extensions
# --------------------------------------------------

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
    echo "All checked PHP extensions are available."

else
    echo "[MISSING] Some required PHP extensions."
    echo "Planning PHP extension packages..."

    plan_php_extension_packages \
        "$PHP_VERSION" \
        "${REQUIRED_PHP_EXTENSIONS[@]}" || true
fi

# --------------------------------------------------
# Check service status
# --------------------------------------------------

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

if [ "$DATABASE_ENGINE" != "sqlite" ]; then
    if [ "$DATABASE_NEEDS_INSTALL" = "yes" ]; then
        echo "[MISSING] $DATABASE_ENGINE - installation required"
        add_service_after_install "$DATABASE_ENGINE"
    elif is_database_service_running "$DATABASE_ENGINE"; then
        echo "[RUNNING] $DATABASE_ENGINE"
    else
        echo "[STOPPED] $DATABASE_ENGINE - start required"
        add_service_to_start "$DATABASE_ENGINE"
    fi
fi

