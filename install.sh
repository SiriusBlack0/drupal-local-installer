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






# ==================================================

# PHASE 1 — CONFIGURATION

# ==================================================



# --------------------------------------------------
# Project name
# --------------------------------------------------

PROJECT_NAME_PATTERN='^[a-zA-Z0-9][a-zA-Z0-9 _-]*$'

while true; do

    read -r -p "Project name: " PROJECT_NAME

    if [ -z "$PROJECT_NAME" ]; then
        echo "Project name cannot be empty."
        continue
    fi

    if ! [[ "$PROJECT_NAME" =~ $PROJECT_NAME_PATTERN ]]; then
        echo "Invalid project name."
        echo "Use Latin letters, numbers, spaces, underscores or hyphens."
        echo "The name must start with a letter or number."
        continue
    fi

    break

done

PROJECT_MACHINE_NAME="$(get_project_machine_name "$PROJECT_NAME")"


# --------------------------------------------------

# Drupal version selection

# --------------------------------------------------



while true; do



    echo

    echo "Select Drupal version:"

    echo

    echo "1) Latest stable"

    echo "2) Choose major / minor / patch"

    echo "3) Enter exact version"

    echo



    read -r -p "Select [1-3]: " VERSION_MODE



    case "$VERSION_MODE" in



        1)

            echo

            echo "Detecting latest Drupal version..."



            DRUPAL_VERSION="$(

                get_drupal_versions 11 | head -n 1

            )"



            if [ -z "$DRUPAL_VERSION" ]; then

                echo "Could not determine latest Drupal version."

                exit 1

            fi



            break

            ;;





        2)

            # ------------------------------------------

            # Major version

            # ------------------------------------------



            while true; do



                echo

                echo "Select Drupal major version:"

                echo

                echo "1) Drupal 11"

                echo "2) Drupal 10"

                echo



                read -r -p "Select [1-2]: " DRUPAL_CHOICE



                case "$DRUPAL_CHOICE" in

                    1)

                        DRUPAL_MAJOR="11"

                        break

                        ;;

                    2)

                        DRUPAL_MAJOR="10"

                        break

                        ;;

                    *)

                        echo "Invalid selection. Please choose 1 or 2."

                        ;;

                esac



            done





            # ------------------------------------------

            # Minor version

            # ------------------------------------------



            mapfile -t DRUPAL_MINORS < <(

                get_drupal_minor_versions "$DRUPAL_MAJOR"

            )



            if [ "${#DRUPAL_MINORS[@]}" -eq 0 ]; then

                echo "No Drupal releases found."

                exit 1

            fi



            while true; do



                echo

                echo "Available Drupal $DRUPAL_MAJOR releases:"

                echo



                for i in "${!DRUPAL_MINORS[@]}"; do

                    echo "$((i + 1))) ${DRUPAL_MINORS[$i]}"

                done



                echo

                read -r -p "Select release: " MINOR_CHOICE



                if ! [[ "$MINOR_CHOICE" =~ ^[0-9]+$ ]] ||

                   (( MINOR_CHOICE < 1 ||

                      MINOR_CHOICE > ${#DRUPAL_MINORS[@]} )); then



                    echo "Invalid selection. Try again."

                    continue



                fi



                DRUPAL_MINOR="${DRUPAL_MINORS[$((MINOR_CHOICE - 1))]}"

                break



            done





            # ------------------------------------------

            # Patch version

            # ------------------------------------------



            mapfile -t DRUPAL_PATCHES < <(

                get_drupal_versions "$DRUPAL_MAJOR" |

                grep "^${DRUPAL_MINOR}\\."

            )



            if [ "${#DRUPAL_PATCHES[@]}" -eq 0 ]; then

                echo "No patch releases found for Drupal $DRUPAL_MINOR."

                exit 1

            fi



            while true; do



                echo

                echo "Available Drupal $DRUPAL_MINOR versions:"

                echo



                echo "1) Latest (${DRUPAL_PATCHES[0]})"



                for i in "${!DRUPAL_PATCHES[@]}"; do

                    echo "$((i + 2))) ${DRUPAL_PATCHES[$i]}"

                done



                echo

                read -r -p "Select version: " PATCH_CHOICE



                if ! [[ "$PATCH_CHOICE" =~ ^[0-9]+$ ]]; then

                    echo "Invalid selection. Try again."

                    continue

                fi



                if [ "$PATCH_CHOICE" -eq 1 ]; then



                    DRUPAL_VERSION="${DRUPAL_PATCHES[0]}"

                    break



                elif (( PATCH_CHOICE >= 2 &&

                        PATCH_CHOICE <= ${#DRUPAL_PATCHES[@]} + 1 )); then



                    DRUPAL_VERSION="${DRUPAL_PATCHES[$((PATCH_CHOICE - 2))]}"

                    break



                else



                    echo "Invalid selection. Try again."



                fi



            done



            break

            ;;





        3)

            while true; do



                echo

                read -r -p "Enter Drupal version (example 11.0.11): " DRUPAL_VERSION



                if ! [[ "$DRUPAL_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then

                    echo "Invalid Drupal version format."

                    continue

                fi



                echo

                echo "Checking Drupal $DRUPAL_VERSION..."



                if drupal_version_exists "$DRUPAL_VERSION"; then

                    echo "Drupal $DRUPAL_VERSION exists."

                    break

                fi



                echo "Drupal $DRUPAL_VERSION does not exist."



            done



            break

            ;;





        *)

            echo "Invalid selection. Please choose 1, 2 or 3."

            ;;



    esac



done





# --------------------------------------------------

# PHP compatibility

# --------------------------------------------------



echo

echo "Detecting PHP requirements..."



PHP_CONSTRAINT="$(get_drupal_php_constraint "$DRUPAL_VERSION")"



if [ -z "$PHP_CONSTRAINT" ]; then

    echo "Could not determine PHP requirements for Drupal $DRUPAL_VERSION."

    exit 1

fi



DRUPAL_MINOR="$(get_drupal_minor "$DRUPAL_VERSION")"



if has_php_support_policy "$DRUPAL_MINOR"; then



    mapfile -t PHP_VERSIONS < <(

        get_supported_php_versions "$DRUPAL_MINOR"

    )



else



    echo

    echo "WARNING:"

    echo "Drupal $DRUPAL_MINOR is not listed in the current PHP support policy."

    echo "This may be an older or unsupported Drupal release."

    echo

    echo "The installer can fall back to the Composer requirement:"

    echo "PHP $PHP_CONSTRAINT"



    while true; do



        echo

        read -r -p "Continue using Composer compatibility? [y/N]: " LEGACY_CHOICE



        case "$LEGACY_CHOICE" in

            y|Y)

                break

                ;;

            n|N|"")

                echo "Installation cancelled."

                exit 0

                ;;

            *)

                echo "Please enter y or n."

                ;;

        esac



    done



    mapfile -t PHP_VERSIONS < <(

        get_compatible_php_versions "$PHP_CONSTRAINT"

    )



fi





echo

echo "Drupal $DRUPAL_VERSION requires PHP $PHP_CONSTRAINT"



if [ "${#PHP_VERSIONS[@]}" -eq 0 ]; then

    echo

    echo "No compatible PHP-FPM version was found on this system."

    exit 1

fi





while true; do



    echo

    echo "Compatible PHP versions:"

    echo



    for i in "${!PHP_VERSIONS[@]}"; do

        php_version="${PHP_VERSIONS[$i]}"
        php_status="$(get_php_version_status "$php_version")"

        echo "$((i + 1))) PHP $php_version [$php_status]"

    done



    echo

    read -r -p "Select PHP version: " PHP_CHOICE



    if ! [[ "$PHP_CHOICE" =~ ^[0-9]+$ ]] ||

       (( PHP_CHOICE < 1 ||

          PHP_CHOICE > ${#PHP_VERSIONS[@]} )); then



        echo "Invalid selection. Try again."

        continue



    fi



    PHP_VERSION="${PHP_VERSIONS[$((PHP_CHOICE - 1))]}"
    PHP_STATUS="$(get_php_version_status "$PHP_VERSION")"

    break

done


# --------------------------------------------------

# Database compatibility

# --------------------------------------------------



echo

echo "Detecting compatible databases..."



DRUPAL_MAJOR="${DRUPAL_VERSION%%.*}"



mapfile -t DATABASE_OPTIONS < <(

    get_compatible_database_options "$DRUPAL_MAJOR"

)



if [ "${#DATABASE_OPTIONS[@]}" -eq 0 ]; then

    echo "No compatible database options were found."

    exit 1

fi





while true; do



    echo

    echo "Compatible databases:"

    echo



    for i in "${!DATABASE_OPTIONS[@]}"; do

        IFS='|' read -r engine version status <<< "${DATABASE_OPTIONS[$i]}"
        echo "$((i + 1))) $engine $version [$status]"

    done



    echo

    read -r -p "Select database: " DATABASE_CHOICE



    if ! [[ "$DATABASE_CHOICE" =~ ^[0-9]+$ ]] ||

       (( DATABASE_CHOICE < 1 ||

          DATABASE_CHOICE > ${#DATABASE_OPTIONS[@]} )); then



        echo "Invalid selection. Try again."

        continue



    fi

    IFS='|' read -r DATABASE_ENGINE DATABASE_VERSION DATABASE_STATUS <<< "${DATABASE_OPTIONS[$((DATABASE_CHOICE - 1))]}"
    
    break

done





# --------------------------------------------------

# Database installation state

#

# PHASE 1 only records whether the selected database

# engine still needs to be installed.

# No installation or conflict checks happen here.

# --------------------------------------------------



DATABASE_NEEDS_INSTALL="no"



if [ "$DATABASE_STATUS" != "installed" ]; then

    DATABASE_NEEDS_INSTALL="yes"

fi



# --------------------------------------------------

# Database name

# --------------------------------------------------



SUGGESTED_DATABASE_NAME="$(

    get_project_database_name "$PROJECT_NAME"

)"



if [ "$DATABASE_ENGINE" = "sqlite" ]; then

    DATABASE_NAME=""
    DATABASE_USER=""
    DATABASE_PASSWORD=""
    SQLITE_DATABASE_PATH="sites/default/files/.ht.sqlite"

    echo
    echo "SQLite selected."
    echo "SQLite does not require a database server, user, or password."

else

    while true; do

        echo
        echo "Database name:"
        echo
        echo "1) Use suggested name: $SUGGESTED_DATABASE_NAME"
        echo "2) Enter custom database name"
        echo

        read -r -p "Select [1-2]: " DATABASE_NAME_CHOICE

        case "$DATABASE_NAME_CHOICE" in

            1)
                DATABASE_NAME="$SUGGESTED_DATABASE_NAME"
                break
                ;;

            2)
                read -r -p "Enter database name: " DATABASE_NAME

                if ! is_valid_database_name "$DATABASE_NAME"; then
                    echo "Invalid database name."
                    echo "Use only letters, numbers and underscores."
                    continue
                fi

                break
                ;;

            *)
                echo "Invalid selection. Please choose 1 or 2."
                ;;

        esac

    done

fi



# --------------------------------------------------

# Database user

# --------------------------------------------------



if [ "$DATABASE_ENGINE" != "sqlite" ]; then

    SUGGESTED_DATABASE_USER="$(
        get_project_database_user "$PROJECT_NAME"
    )"

    while true; do

        echo
        echo "Database user:"
        echo
        echo "1) Use suggested user: $SUGGESTED_DATABASE_USER"
        echo "2) Enter custom database user"
        echo

        read -r -p "Select [1-2]: " DATABASE_USER_CHOICE

        case "$DATABASE_USER_CHOICE" in

            1)
                DATABASE_USER="$SUGGESTED_DATABASE_USER"
                break
                ;;

            2)
                read -r -p "Enter database user: " DATABASE_USER

                if ! is_valid_database_user "$DATABASE_USER"; then
                    echo "Invalid database user."
                    echo "Use only letters, numbers and underscores."
                    continue
                fi

                break
                ;;

            *)
                echo "Invalid selection. Please choose 1 or 2."
                ;;

        esac

    done

fi



# --------------------------------------------------

# Database password

# --------------------------------------------------


if [ "$DATABASE_ENGINE" != "sqlite" ]; then

    while true; do

        echo
        read -r -s -p "Database password: " DATABASE_PASSWORD
        echo

        # Validate the first password before asking
        # the user to type it again.

        if [ -z "$DATABASE_PASSWORD" ]; then
            echo "Database password cannot be empty."
            continue
        fi

        if ! is_valid_database_password "$DATABASE_PASSWORD"; then
            echo "Invalid database password."
            echo "Use only letters, numbers and these characters: _ @ # % + = . -"
            continue
        fi

        read -r -s -p "Confirm database password: " DATABASE_PASSWORD_CONFIRM
        echo

        if [ "$DATABASE_PASSWORD" != "$DATABASE_PASSWORD_CONFIRM" ]; then
            echo "Passwords do not match. Try again."
            continue
        fi

        break

    done

fi

# --------------------------------------------------
# Final configuration summary
# --------------------------------------------------

while true; do
    echo
    echo "======================================"
    echo "        Project configuration"
    echo "======================================"
    echo
    echo "Project:  $PROJECT_NAME"
    echo "Machine:  $PROJECT_MACHINE_NAME"
    echo "Drupal:   $DRUPAL_VERSION"
    echo "PHP:      $PHP_VERSION [$PHP_STATUS]"
    echo "Database: $DATABASE_ENGINE $DATABASE_VERSION [$DATABASE_STATUS]"

    if [ "$DATABASE_ENGINE" = "sqlite" ]; then
        echo "DB File:  $SQLITE_DATABASE_PATH"
    else
        echo "DB Name:  $DATABASE_NAME"
        echo "DB User:  $DATABASE_USER"
    fi

    echo
    echo "======================================"
    echo

    read -r -p "Proceed with installation? [Y/n]: " PROCEED_CHOICE
    case "$PROCEED_CHOICE" in
        y|Y|"")
            break
            ;;
        n|N)
            echo "Installation cancelled."
            exit 0
            ;;
        *)
            echo "Please enter y or n."
            ;;
    esac
done


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