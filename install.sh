#!/usr/bin/env bash



set -e



SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"



source "$SCRIPT_DIR/lib/drupal.sh"

source "$SCRIPT_DIR/lib/php.sh"

source "$SCRIPT_DIR/lib/database.sh"

source "$SCRIPT_DIR/lib/compatibility.sh"

source "$SCRIPT_DIR/lib/system.sh"

source "$SCRIPT_DIR/lib/registry.sh"

source "$SCRIPT_DIR/lib/packages.sh"


# --------------------------------------------------
# Operating system compatibility
# --------------------------------------------------

echo
echo "Checking operating system..."

if is_ubuntu_system; then
    echo "[SUPPORTED] Ubuntu detected."
    get_linux_distribution
else
    echo "[UNSUPPORTED] Only Ubuntu is supported."
    exit 1
fi

echo

echo "======================================"

echo "        Drupal Local Installer"

echo "======================================"

echo






source "$SCRIPT_DIR/lib/ui.sh"

# ==================================================

# PHASE 2 — PREFLIGHT / INSTALLATION

# ==================================================


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
    elif is_database_service_running "$DATABASE_ENGINE"; then
        echo "[RUNNING] $DATABASE_ENGINE"
    else
        echo "[STOPPED] $DATABASE_ENGINE - start required"
        add_service_to_start "$DATABASE_ENGINE"
    fi
fi

# --------------------------------------------------
# Installation plan summary
# --------------------------------------------------

echo
echo "======================================"
echo "          Installation Plan"
echo "======================================"
echo

if [ "${#INSTALL_PACKAGES[@]}" -eq 0 ]; then
    echo "No additional packages required."
else
    echo "Packages to install:"

    for package in "${INSTALL_PACKAGES[@]}"; do
        echo "  - $package"
    done
fi

echo

if [ "${#INSTALL_SERVICES_TO_START[@]}" -eq 0 ]; then
    echo "No installed services need to be started."
else
    echo "Services to start:"

    for service in "${INSTALL_SERVICES_TO_START[@]}"; do
        echo "  - $service"
    done
fi

echo

if [ "${#INSTALL_SERVICES_AFTER_INSTALL[@]}" -eq 0 ]; then
    echo "No services need to be started after installation."
else
    echo "Services to start after installation:"

    for service in "${INSTALL_SERVICES_AFTER_INSTALL[@]}"; do
        echo "  - $service"
    done
fi

echo
echo "======================================"

echo
echo "Checking APT repository compatibility..."

if check_apt_repository_compatibility; then
    APT_REPOSITORIES_COMPATIBLE=true
else
    APT_REPOSITORIES_COMPATIBLE=false
fi

# --------------------------------------------------
# Check installation package availability
# --------------------------------------------------

PACKAGES_AVAILABLE=true

if [ "${#INSTALL_PACKAGES[@]}" -gt 0 ]; then
    echo
    echo "Checking package availability..."

    if check_install_packages_availability; then
        echo "[OK] All planned packages are available."
    else
        PACKAGES_AVAILABLE=false
        echo
        echo "[PENDING] Additional repositories may be required."

        if [ "${#UNAVAILABLE_PACKAGES[@]}" -gt 0 ]; then
            echo
            echo "Packages requiring additional sources:"

            for package in "${UNAVAILABLE_PACKAGES[@]}"; do
                echo "  - $package"
            done
        fi
    fi
fi
# --------------------------------------------------
# Package installation readiness
# --------------------------------------------------

echo
echo "Checking package installation readiness..."

if [ "$APT_REPOSITORIES_COMPATIBLE" = false ]; then
    echo "[WARNING] Some APT repositories target another Ubuntu release."
fi

if [ "$PACKAGES_AVAILABLE" = false ]; then
    echo "[ACTION REQUIRED] Some packages are unavailable."
fi

if [ "$APT_REPOSITORIES_COMPATIBLE" = false ] || \
   [ "$PACKAGES_AVAILABLE" = false ]; then

    echo
    read -r -p "Continue despite these warnings? [y/N]: " CONTINUE_ANYWAY

    case "$CONTINUE_ANYWAY" in
        y|Y|yes|YES)
            echo "[OK] User accepted the warnings."
            ;;
        *)
            echo "[CANCELLED] Installation cancelled by user."
            exit 0
            ;;
    esac
else
    echo "[READY] Package availability and repository checks passed."
fi

echo
echo "Preparing package installation..."

if [ "$PACKAGES_AVAILABLE" = false ]; then
    echo "[SKIPPED] Package installation cannot proceed."
    echo "Some required packages are unavailable."

elif [ "${#INSTALL_PACKAGES[@]}" -eq 0 ]; then
    echo "[OK] No additional packages need installation."

else
    echo "[READY] Required packages are available."
    echo

    read -r -p "Install required APT packages? [y/N]: " INSTALL_CHOICE

    case "$INSTALL_CHOICE" in
        y|Y|yes|YES)
            echo "[APPROVED] Package installation approved."
            echo

            if simulate_apt_package_installation; then
                echo
                echo "[OK] APT installation simulation completed successfully."
                echo

                read -r -p "Proceed with actual package installation? [y/N]: " CONFIRM_INSTALL

                case "$CONFIRM_INSTALL" in
                    y|Y|yes|YES)
                        if execute_apt_package_installation; then
                            echo "[OK] Package installation completed."
                        else
                            echo "[ERROR] Package installation failed."
                            exit 1
                        fi
                        ;;
                    *)
                        echo "[SKIPPED] Actual package installation cancelled."
                        ;;
                esac

            else
                echo
                echo "[ERROR] APT installation simulation failed."
                exit 1
            fi
            ;;
        *)
            echo "[SKIPPED] Package installation declined."
            ;;
    esac
fi
#echo

#echo "======================================"

#echo "     Preflight / Installation"

#echo "======================================"

#echo

#echo "Phase 1 configuration completed successfully."

#echo

#echo "No system changes have been made yet."

#echo "The next implementation step will add:"

#echo "  - Administrator authentication"

#echo "  - Preflight checks"

#echo "  - Database engine installation when required"

#echo "  - Database and database user provisioning"